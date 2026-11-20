import BelfryCore
import SwiftUI

// References in a message (SPEC 19.49; boards channels/link-preview-end, link-preview-inline;
// #issues c92a9f45): a message's text with its last reference, when the text ends with it, taken
// out and shown as a preview box under it. The names inside the text are MarkdownText's.

/// A message's text and, under it, the box of the reference it ends with.
struct MessageText: View {
    @EnvironmentObject var model: AppModel
    let text: String
    /// Event cards the message shows anyway (its event links): the box doesn't repeat them.
    var shownEvents: [EventRef] = []

    var body: some View {
        let s = References.split(text, domain: model.config.domain)
        if !s.text.isEmpty { MarkdownText(text: s.text) }
        if let box = s.box { RefBox(target: box, shownEvents: shownEvents) }
    }
}

/// The links the names inside a text carry for a message and a to-do (the app's own schemes, as
/// belfry-channel / belfry-event / belfry-user).
enum RefLink {
    static func message(_ group: String, _ id: String) -> URL? { URL(string: "belfry-message://open/" + MailThreads.encodeURIComponent(group) + "/" + id) }
    static func todo(_ group: String, _ task: String) -> URL? {
        URL(string: "belfry-todo://open/" + MailThreads.encodeURIComponent(group) + "/" + MailThreads.encodeURIComponent(task))
    }
}

extension AppModel {
    /// Opens what a reference points to; false for a page outside the app (a drop box).
    @discardableResult
    func open(_ o: RefOpen, openChannel: (String, String?) -> Void) -> Bool {
        switch o {
        case .channel(let id): openChannel(id, nil)
        case .event(let coord): openEvent = coord
        case .message(let g, let id): openChannel(g, id)
        case .todo(let g, let task): openTodo = TodoKey(group: g, task: task)
        case .person(let pk): openProfile = pk
        case .url: return false
        }
        return true
    }

    /// A tapped link that is a reference to something of this belfry (a name inside a text, or
    /// its address behind a label): opened here. False: not one, or nothing the app can open.
    func openRef(_ url: URL, openChannel: (String, String?) -> Void) -> Bool {
        if url.scheme == "belfry-message" || url.scheme == "belfry-todo" {
            let p = url.pathComponents
            guard p.count == 3 else { return false }
            return open(url.scheme == "belfry-todo" ? .todo(group: p[1], task: p[2]) : .message(group: p[1], id: p[2]), openChannel: openChannel)
        }
        guard url.scheme == "https", let t = References.target(url.absoluteString, domain: config.domain), let o = derive.refShown(t).open else { return false }
        return open(o, openChannel: openChannel)
    }
}

/// The preview box of a reference: a channel or group (name, "Channel · N members", its about),
/// an event (its card), a proposal (title, "Proposal in #parent"), a to-do (title, "To-do in
/// #channel · who is on it"), a message (its author, "Message in #channel", two lines of it), a
/// person, a drop box; a lock when I can't open it.
struct RefBox: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    @Environment(\.openURL) private var openURL
    let target: RefTarget
    var shownEvents: [EventRef] = []
    /// Not here yet: a grey bar first, the kind's word after 5 s.
    @State private var waited = false

    var body: some View {
        let d = model.derive
        let s = d.refShown(target)
        if let ev = s.event {
            // the message's own event card is already there for an event link
            let dup = shownEvents.contains { r in
                let a = r.coord.flatMap { d.calEvent($0) } ?? r.link.flatMap { d.eventByLink($0) }
                let b = ev.coord.flatMap { d.calEvent($0) } ?? ev.link.flatMap { d.eventByLink($0) }
                return (a != nil && a?.coord == b?.coord) || (r.link != nil && r.link == ev.link)
            }
            if !dup { EventCardView(ref: ev) }
        } else {
            Button {
                guard let o = s.open else { return }
                if !model.open(o, openChannel: openChannel), case .url(let u) = o, let url = URL(string: u) { openURL(url) }
            } label: {
                CardFrame {
                    HStack(alignment: .top, spacing: 10) {
                        if let pk = s.face {
                            Avatar(pubkey: pk, size: 32)
                        } else {
                            Image(systemName: s.done ? "checkmark.square" : icon(s.kind)).font(.body).foregroundStyle(.secondary).frame(width: 24)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if s.kind == .unknown && !waited {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.25)).frame(width: 120, height: 14)
                                    .accessibilityLabel("Loading")
                            } else {
                                Text(s.title).font(.subheadline.weight(.semibold)).foregroundStyle(s.open == nil ? Color.secondary : Color.primary).lineLimit(2)
                            }
                            if !s.line.isEmpty { Text(s.line + until(s.until)).font(.caption).foregroundStyle(.secondary) }
                            if !s.about.isEmpty { Text(s.about).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer(minLength: 0)
                        if s.open != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(s.open == nil)
            .accessibilityIdentifier("ref-box")
            .task { if !waited { try? await Task.sleep(nanoseconds: 5_000_000_000); waited = true } }
        }
    }

    /// " · until 12 Nov" for a drop box that ends.
    private func until(_ t: Int?) -> String {
        guard let t else { return "" }
        return " · until " + Date(timeIntervalSince1970: TimeInterval(t)).formatted(.dateTime.day().month(.abbreviated))
    }

    private func icon(_ k: RefShown.Kind) -> String {
        switch k {
        case .todo: return "square"
        case .message: return "bubble.left"
        case .person: return "person"
        case .drop: return "tray.and.arrow.down"
        case .channel: return "number"
        case .group: return "hexagon"
        case .event: return "calendar"
        case .proposal: return "doc.text"
        case .locked: return "lock"
        case .deleted: return "trash"
        case .unknown: return "ellipsis"
        }
    }
}
