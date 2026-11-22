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

/// One line in the feed (0.8.0, the lead's ruling: collapsed only): the item's icon, "<first
/// name> <verb>: <item>", the time. Tapping it opens the item itself (the to-do, the event, the
/// proposal). The expanded card (below) and its remembered state wait for a later build.
struct ActivityPreviewRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let a: Activity
    let group: String

    var body: some View {
        Button(action: openItem) {
            HStack(spacing: 8) {
                Image(systemName: a.icon).font(.footnote).foregroundStyle(.secondary).frame(width: 20)
                line.font(.footnote).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Format.time(a.at)).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal).padding(.vertical, 4)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens it")
        .accessibilityIdentifier("activity-line")
    }

    private var who: String {
        let n = model.name(a.who)
        return n.split(separator: " ").first.map(String.init) ?? n
    }

    private var line: Text {
        Text(who).fontWeight(.semibold).foregroundColor(.primary)
            + Text(" " + a.verb + ": ").foregroundColor(.secondary)
            + Text(a.title).foregroundColor(.primary)
    }

    private var spoken: String { "\(model.name(a.who)) \(a.verb): \(a.title), \(Format.time(a.at))" }

    private func openItem() {
        switch a.item {
        case .todo(let tid): model.openTodo = TodoKey(group: group, task: tid)
        case .event(let coord): model.openEvent = coord
        case .proposal(let coord):
            if let p = model.derive.proposals.first(where: { $0.coord == coord }) { openChannel(p.groupId, nil) }
        }
    }
}

/// The small card's frame: a rounded box. Its parts answer taps with tap gestures, not Buttons:
/// an open card holding Buttons (any style) in the feed's lazy stack kept the main thread laying
/// out when the keyboard came up (testKeyboardComposer hung, 2026-11-22; a card of text and tap
/// gestures did not).
private struct PreviewBox<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        // sized by its content (no flexible frame: the feed's lazy stack measured nested flexible
        // children again and again while the keyboard moved)
        content()
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The card's text: opens the item.
private struct OpenArea<Content: View>: View {
    let open: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().multilineTextAlignment(.leading).contentShape(Rectangle())
            .frame(minHeight: 44)
            .onTapGesture(perform: open)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens it")
            .accessibilityAction { open() }
    }
}

/// A quick action on the card: a small capsule, filled when it is my answer. It behaves like
/// BusyButton: the first tap locks it and shows progress until the work is done (no double
/// send); 44 pt hit area; a button to VoiceOver.
private struct QuickAction: View {
    let title: String
    var on = false
    let action: () async -> Void
    @State private var busy = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.footnote.weight(.semibold))
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundStyle(on ? Theme.onAccent : Color.primary)
        .background(on ? Color.brand : Color.secondary.opacity(0.15), in: Capsule())
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: run)
        .opacity(busy ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { run() }
    }

    private func run() {
        guard !busy else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            await action()
            // held a moment at least, so a quick second tap never sends again (BusyButton's 0.6 s)
            try? await Task.sleep(for: .milliseconds(600))
            busy = false
        }
    }
}

/// The to-do's tick on the card, as a button (locks on the first tap, 44 pt, VoiceOver).
private struct QuickTick: View {
    let done: Bool
    let action: () -> Void
    @State private var busy = false
    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title3)
            .foregroundStyle(done ? Color.green : Color.secondary)
            .opacity(busy ? 0.5 : 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture(perform: run)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(done ? "Reopen" : "Mark done")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { run() }
            .onChange(of: done) { _, _ in busy = false }
    }
    private func run() {
        guard !busy else { return }
        busy = true
        action()
        // the snapshot follows the outbox at once; unlock if nothing changed after a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { busy = false }
    }
}

struct TodoPreviewCard: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    var body: some View {
        PreviewBox {
            HStack(alignment: .top, spacing: 10) {
                QuickTick(done: t.done) { model.todo(t, in: group, t.done ? "undone" : "done") }
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
                        QuickAction(title: Rsvp.declined.label, on: mine == .declined) { model.rsvp(e, .declined) }
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
            VStack(alignment: .leading, spacing: 8) {
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
