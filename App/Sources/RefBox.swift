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

/// The preview box of a reference: a channel or group (name, "Channel · N members", its about),
/// an event (its card), a proposal (title, "Proposal in #parent"); a lock when I can't open it.
struct RefBox: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let target: RefTarget
    var shownEvents: [EventRef] = []

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
            Button { if case .channel(let id)? = s.open { openChannel(id, nil) } } label: {
                CardFrame {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(s.kind)).font(.body).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.subheadline.weight(.semibold)).foregroundStyle(s.open == nil ? Color.secondary : Color.primary).lineLimit(2)
                            if !s.line.isEmpty { Text(s.line).font(.caption).foregroundStyle(.secondary) }
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
        }
    }

    private func icon(_ k: RefShown.Kind) -> String {
        switch k {
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
