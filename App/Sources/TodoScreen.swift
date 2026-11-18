import BelfryCore
import SwiftUI

// A to-do's own screen (2026-11-18, the owner: "a way to claim, assign and unassign a todo. Put a >
// on the right to open a todo to discuss it"). Every list of to-dos shows rows whose tick box is
// its own tap target and whose rest opens this screen (a chevron at the end); comments, delete,
// claiming and assigning live here. Assigning is SPEC 19.41 (2101 `assign` with `p`).

/// Which to-do to open: its channel and its 2100's id.
struct TodoKey: Hashable, Identifiable {
    let group: String
    let task: String
    var id: String { group + "|" + task }
}

/// A row of a to-do list: the tick box (its own button), then the title and who is on it, a
/// chevron; a tap on anything but the box opens the to-do (OPEN).
struct TodoRow: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    /// Under the title instead of who is on it (My to-dos: the channel's name).
    var subtitle: String? = nil
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            TodoTick(t: t, group: group)
            Button(action: open) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MarkdownText.plainLinks(t.title)).font(.body).foregroundStyle(.primary).strikethrough(t.done).lineLimit(3)
                        HStack(spacing: 6) {
                            if t.isWorking(now: Int.now), let since = t.workingSince { WorkingRing(since: since) }
                            Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if !t.comments.isEmpty {
                        Label("\(t.comments.count)", systemImage: "bubble.left").labelStyle(.titleAndIcon)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityLabel(t.comments.count == 1 ? "1 comment" : "\(t.comments.count) comments")
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the to-do")
            .accessibilityIdentifier("todo-open")
        }
    }

    private var line: String {
        let who = model.derive.todoWho(t)
        guard let subtitle else { return who }
        return t.assignee == nil ? subtitle : subtitle + " · " + who
    }
}

/// The box that ticks a to-do off (or back on): a 44 pt target of its own, locked while it goes.
struct TodoTick: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    var body: some View {
        BusyButton {
            model.todo(t, in: group, t.done ? "undone" : "done")
        } label: {
            Image(systemName: t.done ? "checkmark.circle.fill" : t.assignee != nil ? "circle.dotted.circle" : "circle")
                .font(.title2)
                .foregroundStyle(t.done ? Color.green : t.assignee != nil ? Color.orange : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.locked(group) || model.guestReading)
        .accessibilityLabel(t.done ? "Done. Mark as not done" : "Mark as done")
        .accessibilityIdentifier("todo-tick")
    }
}

/// One to-do: what it is, who is on it (claim, assign to someone, unassign), done or not, where it
/// came from, and its discussion (2103 comments). The ⋯ menu deletes it (its author only).
struct TodoScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let key: TodoKey
    /// Back to the channel at its message's thread (from a channel's To-dos); nil elsewhere.
    var go: ((LogGo) -> Void)? = nil
    @State private var comment = ""
    @State private var askDelete = false
    @State private var picking = false
    @FocusState private var commentFocused: Bool

    var body: some View {
        let _ = model.version
        let d = model.derive
        if let t = d.tasks(key.group).first(where: { $0.id == key.task }) {
            content(t, d)
        } else {
            ContentUnavailableView("This to-do is gone", systemImage: "checklist",
                                   description: Text("It was deleted, or it is not on this phone yet."))
                .navigationTitle("To-do")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private func content(_ t: TodoTask, _ d: Derive) -> some View {
        let locked = model.locked(key.group) || model.guestReading
        let mine = t.assignee == model.me
        List {
            Section {
                HStack(alignment: .top, spacing: 6) {
                    TodoTick(t: t, group: key.group)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MarkdownText.plainLinks(t.title)).font(.title3.weight(.semibold)).strikethrough(t.done)
                            .accessibilityIdentifier("todo-title")
                        Text("In \(channelName) · made by \(t.author == model.me ? "you" : model.name(t.author))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }
                if t.pending { Label("Not sent yet", systemImage: "clock").font(.footnote).foregroundStyle(.secondary) }
            }

            Section("Who is on it") {
                HStack(spacing: 12) {
                    if let a = t.assignee { Avatar(pubkey: a, size: 32) } else {
                        Image(systemName: "person.crop.circle.badge.questionmark").font(.title2).foregroundStyle(.secondary).frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.todoWho(t)).font(.body)
                        if t.isWorking(now: Int.now), let since = t.workingSince {
                            HStack(spacing: 6) { WorkingRing(since: since); Text("Working on it now").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("todo-who")
                if !locked && !t.done {
                    if !mine {
                        ActionButtonRow(icon: "hand.raised", title: t.assignee == nil ? "Claim it" : "Take it over",
                                        detail: t.assignee == nil ? "Put it on you" : nil) {
                            model.assignTodo(t, in: key.group, to: model.me)
                        }
                        .accessibilityIdentifier("todo-claim")
                    }
                    Button { hideKeyboard(); picking = true } label: {
                        HStack { ActionRow(icon: "person.badge.plus", title: "Assign to…"); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("todo-assign")
                    if t.assignee != nil {
                        ActionButtonRow(icon: "person.crop.circle.badge.minus", title: mine ? "Let it go" : "Unassign",
                                        detail: mine ? "Nobody is on it then" : "Take it off \(model.name(t.assignee!))") {
                            model.assignTodo(t, in: key.group, to: nil)
                        }
                        .accessibilityIdentifier("todo-unassign")
                    }
                }
            }

            if let src = t.source {
                Section {
                    if let go {
                        Button { go(.thread(src)) } label: { ActionRow(icon: "bubble.left.and.bubble.right", title: "Open its thread", detail: "Made from a message") }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("todo-thread")
                    } else {
                        NavigationLink(value: ChatRoute(id: key.group, focus: src)) {
                            ActionRow(icon: "bubble.left.and.bubble.right", title: "Open its message", detail: "Made from a message")
                        }
                        .accessibilityIdentifier("todo-thread")
                    }
                }
            }

            Section {
                if t.comments.isEmpty { Text("No comments yet. Ask, plan or report here.").foregroundStyle(.secondary) }
                ForEach(Array(t.comments.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(pubkey: c.author, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(c.author == model.me ? "You" : model.name(c.author)).font(.subheadline.weight(.semibold))
                                Text(Format.ago(c.at)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(MarkdownText.plainLinks(c.text)).font(.body)
                        }
                    }
                }
                if !locked {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Add a comment", text: $comment, axis: .vertical).font(.body).lineLimit(1...5)
                            .focused($commentFocused)
                            .accessibilityIdentifier("todo-comment")
                        BusyButton {
                            let text = comment.jsTrim()
                            guard !text.isEmpty else { return }
                            model.commentTodo(t, in: key.group, text: text)
                            comment = ""
                        } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(comment.jsTrim().isEmpty)
                        .accessibilityLabel("Send the comment")
                    }
                }
            } header: { Text(t.comments.isEmpty ? "Discussion" : "Discussion · \(t.comments.count)") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("To-do")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if t.author == model.me && !locked {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { askDelete = true } label: { Label("Delete the to-do", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("todo-more")
                }
            }
        }
        .confirmationDialog("Delete this to-do?", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.todo(t, in: key.group, "delete")
                dismiss()
            }
        } message: { Text("It goes for everyone in \(channelName).") }
        .navigationDestination(isPresented: $picking) { AssignPicker(key: key) }
        .onAppear {
            if model.launch.screen == "todoassign" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { picking = true } }
        }
    }

    private var channelName: String {
        guard let g = model.group(key.group) else { return "#" + BelfryCore.Group.fallbackName(key.group) }
        return g.type == .channel ? "#" + g.name : g.name
    }
}

/// "Assign to…": the people who can read the channel (me first), a search; a tap puts the to-do on
/// that person and goes back. The one it is on now has a checkmark; "Nobody" unassigns.
struct AssignPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let key: TodoKey
    @State private var query = ""

    var body: some View {
        let _ = model.version
        let d = model.derive
        let t = d.tasks(key.group).first { $0.id == key.task }
        let g = model.group(key.group)
        let q = query.jsTrim().lowercased()
        let people = d.people.filter { p in
            d.inChannel(g, p.pubkey) || p.pubkey == t?.assignee
        }.filter { p in q.isEmpty || p.name.lowercased().split(separator: " ").contains { $0.hasPrefix(q) } }
        List {
            if let t {
                Section {
                    if q.isEmpty || "me you".contains(q) {
                        row(t, model.me, title: "Me (" + model.name(model.me) + ")")
                    }
                    if t.assignee != nil && q.isEmpty {
                        BusyButton {
                            model.assignTodo(t, in: key.group, to: nil)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.badge.minus").font(.title2).foregroundStyle(.secondary).frame(width: 36, height: 36)
                                Text("Nobody").foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("assign-nobody")
                    }
                }
                Section(g.map { "People in " + ($0.type == .channel ? "#" + $0.name : $0.name) } ?? "People") {
                    if people.isEmpty { Text(q.isEmpty ? "Nobody else here yet." : "Nobody by that name here.").foregroundStyle(.secondary) }
                    ForEach(people, id: \.pubkey) { p in row(t, p.pubkey, title: p.name) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search people")
        .navigationTitle("Assign to")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ t: TodoTask, _ pk: String, title: String) -> some View {
        BusyButton {
            if t.assignee != pk { model.assignTodo(t, in: key.group, to: pk) }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Avatar(pubkey: pk, size: 36)
                Text(title).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                if t.assignee == pk { Image(systemName: "checkmark").foregroundStyle(Color.brand).accessibilityLabel("On it now") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("assign-person")
    }
}
