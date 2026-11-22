import BelfryCore
import SwiftUI

// One shape's header for a channel, a group and a thread (canvas one-shape/anatomy,
// inbox-channel; 2026-11-22): line 1 the title, line 2 the icon row (OneShapeUI.swift). A
// channel's row: 👥 people · 📌 pinned · ✓ open to-dos · 📁 files · 📅 upcoming events, each left
// out at 0, no message count. A channel that takes e-mails from anyone leads in the accent colour
// with ✉ n open and 👤 n on me (only while some are open). A thread: 👥 people · 💬 replies.
// The pull-down of an inbox channel starts with the "E-mails · n open" row (EmailsScreen).

enum ChannelHeaderItems {
    @MainActor static func items(_ model: AppModel, _ id: String) -> [HeaderItem] {
        let d = model.derive
        let g = model.group(id)
        let c = ChannelCounts(model, id)
        var out = [HeaderItem]()
        if d.isInbox(g) {
            let open = d.mailThreads(id).list.filter { $0.state.status == .open }
            let mine = open.filter { $0.state.assignee == model.me }.count
            if !open.isEmpty {
                out.append(HeaderItem(key: "lead", icon: "envelope", text: "\(open.count) open",
                                      label: "\(open.count) open e-mail\(open.count == 1 ? "" : "s")", accent: true))
                if mine > 0 {
                    out.append(HeaderItem(key: "owner", icon: "person", text: "\(mine) on you",
                                          label: "\(mine) e-mail\(mine == 1 ? "" : "s") on you", accent: true))
                }
            }
        }
        let people = max(c.members, g?.admins.count ?? 0)
        if let p = HeaderItem.count("people", "person.2", people, "person", "people") { out.append(p) }
        if let p = HeaderItem.count("pinned", "pin", c.pins, "pinned", "pinned") { out.append(p) }
        if let p = HeaderItem.count("todos", "checkmark.circle", c.todos - c.todosDone, "open to-do", "open to-dos") { out.append(p) }
        if let p = HeaderItem.count("files", "folder", c.files, "file", "files") { out.append(p) }
        if let p = HeaderItem.count("events", "calendar", c.events, "upcoming event", "upcoming events") { out.append(p) }
        return out
    }

    /// A thread: the people in it and its replies.
    @MainActor static func thread(_ model: AppModel, group: String, root: String) -> [HeaderItem] {
        let d = model.derive
        let replies = d.threadReplies(group, root)
        var people = Set(replies.map(\.pubkey))
        if let r = d.message(group, root) { people.insert(r.pubkey) }
        return [HeaderItem.count("people", "person.2", people.count, "person", "people"),
                HeaderItem.count("comments", "bubble.left", replies.count, "reply", "replies")].compactMap { $0 }
    }

    /// A thread's title: the beginning of its first message (thread names: not in this version).
    @MainActor static func threadTitle(_ model: AppModel, group: String, root: String) -> String {
        guard let r = model.derive.message(group, root) else { return "Thread" }
        let s = model.derive.activitySnippet(r)
        return s.isEmpty ? "Thread" : s
    }
}

/// E-mails (pushed from an inbox channel's pull-down): its threads like to-dos, Open / Mine /
/// Answered / Closed; each row has the subject, sender, time and who has it; Claim takes one tap.
struct EmailsScreen: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let open: (String) -> Void
    @State private var tab: Tab = .open

    enum Tab: String, CaseIterable, Identifiable {
        case open = "Open", mine = "Mine", answered = "Answered", closed = "Closed"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = model.version
        let all = model.derive.mailThreads(id).list.sorted { $0.last > $1.last }
        let shown = all.filter { pick($0, tab) }
        List {
            Section {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        let n = all.filter { pick($0, t) }.count
                        Text(n > 0 && (t == .open || t == .mine) ? "\(t.rawValue) \(n)" : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                if shown.isEmpty {
                    Text("Nothing here.").foregroundStyle(.secondary)
                }
                ForEach(shown) { t in row(t) }
            }
        }
        .navigationTitle("E-mails")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ t: InboxThread, _ tab: Tab) -> Bool {
        switch tab {
        case .open: return t.state.status == .open
        case .mine: return t.state.status == .open && t.state.assignee == model.me
        case .answered: return t.state.status == .waiting
        case .closed: return t.state.status == .closed
        }
    }

    private func row(_ t: InboxThread) -> some View {
        let from = t.name.isEmpty ? t.address : t.name
        return HStack(alignment: .center, spacing: 10) {
            Button { open(t.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.subject.isEmpty ? "(no subject)" : t.subject).font(.body.weight(.semibold)).lineLimit(1)
                    Text(from + " · " + Format.short(t.last)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Text(owner(t)).font(.footnote).foregroundStyle(t.state.assignee == nil ? .secondary : .primary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if t.state.assignee == nil, t.state.status == .open, let root = t.root, !model.locked(id) {
                BusyButton { model.assignCard(root, in: id, to: model.me) } label: { Text("Claim").font(.footnote.weight(.semibold)) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("email-claim")
            }
        }
    }

    private func owner(_ t: InboxThread) -> String {
        guard let a = t.state.assignee else { return "Nobody has it yet" }
        return a == model.me ? "You have it" : "\(model.name(a)) has it"
    }
}
