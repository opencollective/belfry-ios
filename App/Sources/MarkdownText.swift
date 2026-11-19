import BelfryCore
import SwiftUI

// The Markdown subset (SPEC 9) as native Text: never HTML, links only http(s) and mailto,
// @mentions as names, #topics highlighted. Dynamic Type follows the body font.

struct MarkdownText: View {
    @EnvironmentObject var model: AppModel
    let text: String

    var body: some View {
        let blocks = Markdown.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
    }

    @ViewBuilder
    func block(_ b: MDBlock) -> some View {
        switch b {
        case .paragraph(let lines):
            Text(joined(lines))
        case .heading(let level, let c):
            Text(attr(c)).font(level == 1 ? .title3.bold() : .headline)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(i + 1)." : "•").foregroundStyle(.secondary)
                        Text(attr(item))
                    }
                }
            }
        case .quote(let lines):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                Text(joined(lines)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let c):
            Text(c)
                .font(.callout.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    func joined(_ lines: [[MDInline]]) -> AttributedString {
        var out = AttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += attr(l)
        }
        return out
    }

    func attr(_ nodes: [MDInline]) -> AttributedString {
        var out = AttributedString()
        for n in nodes {
            switch n {
            case .text(let s): out += refs(s)
            case .bold(let c): out += adding(.stronglyEmphasized, attr(c))
            case .italic(let c): out += adding(.emphasized, attr(c))
            case .strike(let c): out += adding(.strikethrough, attr(c))
            case .code(let s): out += adding(.code, AttributedString(s))
            case .link(let href, let c):
                // this belfry's own link to a channel or an event, written bare: its name (SPEC 19.49)
                if c == [.text(href)], let t = References.target(href, domain: model.config.domain) {
                    out += refName(t)
                } else {
                    out += MarkdownText.linked(attr(c), href)
                }
            case .mention(let npub):
                let pk = Bech32.pubkey(npub: npub) ?? ""
                let name = pk.isEmpty ? "nostr:" + npub : "@" + (model.realName(pk).isEmpty ? model.name(pk) : model.realName(pk))
                var a = AttributedString(name)
                a.foregroundColor = .brand
                if !pk.isEmpty { a.link = URL(string: "belfry-user://open/" + pk) }
                a = adding(.stronglyEmphasized, a)
                out += a
            case .topic(let t):
                var a = AttributedString("#" + t)
                a.foregroundColor = .brand
                out += a
            }
        }
        return out
    }

    /// Channel references (SPEC 19.14): "#name" that opens the channel; "#channel" (muted) for one
    /// not known here, "Nostr address" for an naddr that is not a channel's. A raw naddr is never shown.
    func refs(_ s: String) -> AttributedString {
        let ms = ChannelRefs.naddrRx.matches(s)
        if ms.isEmpty { return AttributedString(s) }
        let ns = s as NSString
        var out = AttributedString()
        var at = 0
        for m in ms {
            out += AttributedString(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            let naddr = m[1] ?? ""
            if let t = References.target("nostr:" + naddr, domain: model.config.domain) {
                out += refName(t)
            } else {
                var a = AttributedString("Nostr address")
                a.foregroundColor = .secondary
                out += a
            }
            at = m.range.location + m.range.length
        }
        out += AttributedString(ns.substring(from: at))
        return out
    }

    /// A reference inside the text: its name, tappable when it can be opened; grey words when it
    /// isn't here yet, can't be opened or is deleted. Never an id or a slug.
    func refName(_ t: RefTarget) -> AttributedString {
        let s = model.derive.refShown(t)
        var a = AttributedString(s.name)
        switch s.open {
        case .channel(let id)?:
            a.foregroundColor = .brand
            a.link = URL(string: "belfry-channel://open/" + MailThreads.encodeURIComponent(id))
            return adding(.stronglyEmphasized, a)
        case .event(let coord)?:
            a.foregroundColor = .brand
            a.link = URL(string: "belfry-event://open/" + MailThreads.encodeURIComponent(coord))
            return adding(.stronglyEmphasized, a)
        case nil:
            a.foregroundColor = .secondary
            return a
        }
    }

    /// Plain text (a to-do's title, a comment) with its addresses as links, nothing else.
    static func plainLinks(_ text: String) -> AttributedString {
        let ns = text as NSString
        var out = AttributedString()
        var at = 0
        for m in Links.urlRx.matches(text) {
            out += AttributedString(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            out += linked(AttributedString(m.whole), m.whole)
            at = m.range.location + m.range.length
        }
        out += AttributedString(ns.substring(from: at))
        return out
    }

    /// A link as every text of the app shows it: tappable, underlined in the tint (the neutral
    /// look's ink, or the belfry's colour). Long addresses wrap like words.
    static func linked(_ s: AttributedString, _ href: String) -> AttributedString {
        guard let u = URL(string: href), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") else { return s }
        var a = s
        a.link = u
        a.underlineStyle = Text.LineStyle.single
        a.foregroundColor = .brand
        return a
    }

    func adding(_ intent: InlinePresentationIntent, _ s: AttributedString) -> AttributedString {
        var a = s
        for run in a.runs {
            var i = run.inlinePresentationIntent ?? []
            i.insert(intent)
            a[run.range].inlinePresentationIntent = i
        }
        return a
    }
}
