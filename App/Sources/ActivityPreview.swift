import BelfryCore
import SwiftUI

// Activity previews (canvas one-shape/action-previews, -open; docs/one-shape.md §3): an action
// on an item shows in a channel's feed as one quiet line, the item's icon, "<first name> <verb>:
// <item>", the time and ⌄. Tapping it opens a small card of the item with its quick action (the
// to-do's tick; Going / Maybe; Vote); tapping the card opens the item. Collapsed by default; a
// preview that needs me starts open. Open or closed is remembered per item on this device only.

enum PreviewMemory {
    private static let key = "belfry-preview-open"
    /// Item id → open (true) / closed (false), set by a tap.
    static func get(_ id: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool])?[id]
    }
    static func set(_ id: String, _ open: Bool) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        d[id] = open
        if d.count > 2000 { d = [id: open] }
        UserDefaults.standard.set(d, forKey: key)
    }
}

struct ActivityPreviewRow: View {
    @EnvironmentObject var model: AppModel
    let a: Activity
    let group: String
    @State private var open: Bool?

    var body: some View {
        let d = model.derive
        let isOpen = open ?? PreviewMemory.get(a.id) ?? d.activityNeedsMe(a, groupId: group, now: Int.now)
        VStack(alignment: .leading, spacing: 6) {
            Button { toggle(isOpen) } label: {
                HStack(spacing: 8) {
                    Image(systemName: a.icon).font(.footnote).foregroundStyle(.secondary).frame(width: 20)
                    line(isOpen).font(.footnote).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Format.time(a.at)).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
            .accessibilityIdentifier("activity-line")
            if isOpen {
                card.padding(.leading, 28)
            }
        }
        .padding(.horizontal).padding(.vertical, 4)
    }

    private var who: String {
        let n = model.name(a.who)
        return n.split(separator: " ").first.map(String.init) ?? n
    }

    private func line(_ open: Bool) -> Text {
        let w = Text(who).fontWeight(.semibold).foregroundColor(.primary)
        let v = Text(" " + a.verb + (open ? "" : ": ")).foregroundColor(.secondary)
        return open ? w + v : w + v + Text(a.title).foregroundColor(.primary)
    }

    private var spoken: String { "\(model.name(a.who)) \(a.verb): \(a.title), \(Format.time(a.at))" }

    private func toggle(_ was: Bool) {
        withAnimation(.snappy(duration: 0.2)) { open = !was }
        PreviewMemory.set(a.id, !was)
    }

    @ViewBuilder private var card: some View {
        let d = model.derive
        switch a.item {
        case .todo(let tid):
            if let t = d.tasks(group).first(where: { $0.id == tid }) { TodoPreviewCard(t: t, group: group) }
        case .event(let coord):
            if let e = d.calendar.first(where: { $0.coord == coord }) { EventPreviewCard(e: e) }
        case .proposal(let coord):
            if let p = d.proposals.first(where: { $0.coord == coord }) { ProposalPreviewCard(p: p) }
        }
    }
}

/// The small card's frame: a rounded box. No tap gesture over it and no bordered buttons in it:
/// in the feed's lazy stack with the keyboard moving, an open card with `.bordered` buttons under
/// a tap gesture kept the main thread laying out (testKeyboardComposer hung, 2026-11-22).
private struct PreviewBox<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The card's text: opens the item.
private struct OpenArea<Content: View>: View {
    let open: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: open) {
            content().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens it")
    }
}

/// A quick action on the card: a small capsule, filled when it is my answer.
private struct QuickAction: View {
    let title: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(on ? Theme.onAccent : Color.primary)
                .background(on ? Color.brand : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct TodoPreviewCard: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    var body: some View {
        PreviewBox {
            HStack(alignment: .top, spacing: 10) {
                Button { model.todo(t, in: group, t.done ? "undone" : "done") } label: {
                    Image(systemName: t.done ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(t.done ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.done ? "Reopen" : "Mark done")
                OpenArea(open: { model.openTodo = TodoKey(group: group, task: t.id) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.subheadline.weight(.semibold)).strikethrough(t.done).lineLimit(2)
                        Text(t.assignee.map { model.name($0) } ?? "Unassigned").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct EventPreviewCard: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    var body: some View {
        let mine = e.rsvps[model.me]
        let going = e.rsvps.values.filter { $0 == .accepted }.count
        PreviewBox {
            VStack(alignment: .leading, spacing: 8) {
                OpenArea(open: { model.openEvent = e.coord }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(detail(going)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if (e.end ?? e.start) > Int.now {
                    HStack(spacing: 8) {
                        QuickAction(title: Rsvp.accepted.label, on: mine == .accepted) { model.rsvp(e, .accepted) }
                        QuickAction(title: Rsvp.tentative.label, on: mine == .tentative) { model.rsvp(e, .tentative) }
                    }
                }
            }
        }
    }

    private func detail(_ going: Int) -> String {
        var parts = [model.derive.lineDay(e.start, now: Int.now) + " · " + Format.time(e.start)]
        if let l = e.location, !l.isEmpty { parts.append(l) }
        if going > 0 { parts.append("\(going) going") }
        return parts.joined(separator: " · ")
    }
}

struct ProposalPreviewCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let p: Proposal
    var body: some View {
        let t = p.tally
        PreviewBox {
            HStack(alignment: .center, spacing: 10) {
                OpenArea(open: { openChannel(p.groupId, nil) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text("\(t["yes"] ?? 0) yes · \(t["no"] ?? 0) no · \(p.status.label)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if p.status == .voting {
                    QuickAction(title: model.derive.myVote(p) == nil ? "Vote" : "Voted") { openChannel(p.groupId, nil) }
                }
            }
        }
    }
}
