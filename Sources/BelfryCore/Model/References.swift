import Foundation

// References in a message (SPEC 19.49 = Android 19.44; vectors/references.json, whose generator
// tools/vectors/references.mjs in belfry-android is the reference implementation): this belfry's
// chat link to a channel, its event pages, and nostr:naddr of a group, an event or a proposal.
// Inside the text a reference reads as its name; the last one, when the text ends with it, comes
// out of the text and shows as a preview box under it.

/// What a reference points to.
public enum RefTarget: Hashable, Sendable {
    /// A NIP-29 group by its id (a channel, a group, an event's chat, a proposal's chat).
    case group(String)
    /// An event by its page's link (slug or d) or by its coord.
    case event(link: String?, coord: String?)
    /// A proposal by its coord.
    case proposal(String)
}

public enum RefPart: Hashable, Sendable {
    case text(String)
    /// Inside the text: shown as its name.
    case ref(RefTarget)
    /// The last reference, at the very end: a preview box under the text.
    case box(RefTarget)
}

public enum References {
    static let urlRx = Rx("https?://[^\\s<>()]+[^\\s<>().,;:!?'\"]")
    static let naddrRx = Rx("nostr:(naddr1[02-9ac-hj-np-z]{20,400})")

    static func channelRx(_ domain: String) -> Rx {
        let d = NSRegularExpression.escapedPattern(for: domain)
        return Rx("^https://(?:chat\\.\(d)|\(d)/chat)/#/c/([^/?#]{1,120})/?$")
    }

    static func eventRx(_ domain: String) -> Rx {
        let d = NSRegularExpression.escapedPattern(for: domain)
        return Rx("^https://(?:chat\\.\(d)/(?:#/)?events|\(d)/events)/([A-Za-z0-9_-]{1,80})/?$")
    }

    /// What TOKEN (an address, or `nostr:naddr1…`) points to; nil when it isn't a reference: it
    /// stays as written.
    public static func target(_ token: String, domain: String) -> RefTarget? {
        if token.hasPrefix("nostr:") {
            guard let a = Nip19.decodeNaddr(String(token.dropFirst(6))) else { return nil }
            switch a.kind {
            case 39000: return .group(a.identifier)
            case 31922, 31923: return .event(link: nil, coord: "\(a.kind):\(a.pubkey):\(a.identifier)")
            case 30023: return .proposal("\(a.kind):\(a.pubkey):\(a.identifier)")
            default: return nil
            }
        }
        guard !domain.isEmpty else { return nil }
        if let m = channelRx(domain).first(token), let raw = m[1] {
            guard let id = raw.removingPercentEncoding else { return nil }
            return .group(id)
        }
        if let m = eventRx(domain).first(token), let link = m[1] { return .event(link: link, coord: nil) }
        return nil
    }

    /// TEXT as parts: text, a reference inside the text, and the box (the last reference, when
    /// the text trimmed of trailing white space ends with it).
    public static func parts(_ text: String, domain: String) -> [RefPart] {
        let ns = text as NSString
        var found = [(start: Int, end: Int, t: RefTarget)]()
        for re in [naddrRx, urlRx] {
            for m in re.matches(text) {
                if let t = target(m.whole, domain: domain) { found.append((m.range.location, m.range.location + m.range.length, t)) }
            }
        }
        found.sort { $0.start < $1.start }
        var out = [RefPart]()
        func push(_ s: String) {
            if s.isEmpty { return }
            if case .text(let l)? = out.last { out[out.count - 1] = .text(l + s) } else { out.append(.text(s)) }
        }
        let trimmedEnd = (trimEnd(text) as NSString).length
        var last = 0
        for (i, f) in found.enumerated() {
            if f.start < last { continue }
            push(ns.substring(with: NSRange(location: last, length: f.start - last)))
            if i == found.count - 1 && f.end == trimmedEnd {
                if case .text(let l)? = out.last {
                    let t = trimEnd(l)
                    if t.isEmpty { out.removeLast() } else { out[out.count - 1] = .text(t) }
                }
                out.append(.box(f.t))
            } else {
                out.append(.ref(f.t))
            }
            last = f.end
        }
        if case .box? = out.last { return out }
        push(ns.substring(from: last))
        return out
    }

    /// JavaScript's `s.replace(/\s+$/u, '')`.
    static func trimEnd(_ s: String) -> String { Rx("\\s+$").replace(s, with: "") }

    /// The text to draw (the box taken out, the references inside left as written: the text view
    /// names them) and the box, if any.
    public static func split(_ text: String, domain: String) -> (text: String, box: RefTarget?) {
        let ps = parts(text, domain: domain)
        guard case .box(let b)? = ps.last else { return (text, nil) }
        // everything before the box, as written
        let ns = text as NSString
        let trimmed = (trimEnd(text) as NSString).length
        // the box's token is the last reference token: find where it starts
        var start = trimmed
        for re in [naddrRx, urlRx] {
            for m in re.matches(text) where m.range.location + m.range.length == trimmed && target(m.whole, domain: domain) != nil {
                start = min(start, m.range.location)
            }
        }
        return (trimEnd(ns.substring(to: start)), b)
    }
}

/// Where a reference opens.
public enum RefOpen: Hashable, Sendable {
    case channel(String)
    case event(String)
}

/// A reference as it is shown: its name inside the text, and the lines of its box.
public struct RefShown: Hashable, Sendable {
    public enum Kind: String, Sendable { case channel, group, event, proposal, locked, deleted, unknown }
    public var kind: Kind
    /// Inside the text: "#Garden", "Repair café", "Quiet hours after 22:00"; never an id or a slug.
    public var name: String
    /// The box: its title and the line under it ("Channel · 12 members", "Proposal in #Townsquare").
    public var title: String
    public var line: String
    public var about: String = ""
    /// Nil: nothing to open (not here yet, can't open it, deleted).
    public var open: RefOpen?
    /// An event: the app's own event card is its box.
    public var event: EventRef?
}

public extension Derive {
    /// How reference T reads for me (SPEC 19.49): the name, the box's lines, where it opens.
    func refShown(_ t: RefTarget) -> RefShown {
        switch t {
        case .event(let link, let coord):
            let ref = EventRef(coord: coord, link: link)
            if let e = coord.flatMap({ calEvent($0) }) ?? link.flatMap({ eventByLink($0) }) {
                return RefShown(kind: .event, name: e.title, title: e.title, line: "Event", open: .event(e.coord), event: EventRef(coord: e.coord))
            }
            return RefShown(kind: .unknown, name: "Event", title: "Event", line: "", open: nil, event: ref)
        case .proposal(let coord):
            guard let p = proposals.first(where: { $0.coord == coord }) else {
                return RefShown(kind: .unknown, name: "Proposal", title: "Proposal", line: "")
            }
            return shown(p)
        case .group(let id):
            if isDeleted(id) {
                let w = "a deleted " + Group.kindWord(id)
                return RefShown(kind: .deleted, name: w, title: cap(w), line: "")
            }
            guard let g = group(id) else {
                // not here yet: the kind's word (vectors/channel-refs.json: "#channel")
                let w = "#" + Group.kindWord(id)
                return RefShown(kind: .unknown, name: w, title: w, line: "")
            }
            guard inChannel(g, me) else {
                let w = g.isPod ? "a closed group" : "a members-only channel"
                return RefShown(kind: .locked, name: w, title: cap(w), line: "Only members of \(ctx.communityName.isEmpty ? "this belfry" : ctx.communityName) can open it")
            }
            // an event's chat reads as its event, a proposal's chat as its proposal
            if g.isEvent, let e = eventOfGroup(id) { return refShown(.event(link: nil, coord: e.coord)) }
            if g.isProposal, let p = proposals.first(where: { $0.groupId == id }) { return shown(p) }
            let name = "#" + (g.named ? g.name : Group.kindWord(id))
            let word = g.isPod ? "Group" : "Channel"
            return RefShown(kind: g.isPod ? .group : .channel, name: name, title: name, line: word + " · " + membersWord(g.members.count),
                            about: g.about, open: .channel(id))
        }
    }

    private func shown(_ p: Proposal) -> RefShown {
        let parent = group(p.groupId)?.parent.map { label($0) }
        return RefShown(kind: .proposal, name: p.title, title: p.title, line: parent.map { "Proposal in " + $0 } ?? "Proposal", open: .channel(p.groupId))
    }
}
