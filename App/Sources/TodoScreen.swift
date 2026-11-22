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
    /// The tap target (the header's tick is smaller: the navigation bar is 44 pt high).
    var size: CGFloat = 44
    var body: some View {
        BusyButton {
            model.todo(t, in: group, t.done ? "undone" : "done")
        } label: {
            Image(systemName: t.done ? "checkmark.circle.fill" : t.assignee != nil ? "circle.dotted.circle" : "circle")
                .font(size < 44 ? .title3 : .title2)
                .foregroundStyle(t.done ? Color.green : t.assignee != nil ? Color.orange : Color.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.locked(group) || model.guestReading)
        .accessibilityLabel(t.done ? "Done. Mark as not done" : "Mark as done")
        .accessibilityIdentifier("todo-tick")
    }
}

/// One to-do in one shape (canvas one-shape/todo-mid, todo-conversation, todo-pulled, todo-done,
/// 2026-11-22). The header is the tick and the title, then one icon row: who is on it (a person
/// icon and a name, or "Unassigned"), comments, files, photos; no due date. Three levels: folded
/// (the header, then the conversation), mid (the default while it needs me, i.e. open and on me
/// or on nobody: the due line and two lines of the description + More) and pulled (tap the
/// header or More: the due line, the whole description, the message it came from). The
/// conversation weaves the quiet lines (made, took it, assigned, done, set the due date) into the
/// comments; "Comment" is at the bottom. Done = the tick, no Done button. Claim, assign, the due
/// date and delete are in •••.
struct TodoScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let key: TodoKey
    /// Back to the channel at its message's thread (from a channel's To-dos); nil elsewhere.
    var go: ((LogGo) -> Void)? = nil
    @State private var comment = ""
    @State private var askDelete = false
    @State private var picking = false
    @State private var dueOpen = false
    @State private var editOpen = false
    /// nil = the default for this to-do (mid while it needs me, else folded).
    @State private var level: TodoLevel?
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
        let lv = level ?? TodoLevel.start(t, me: model.me)
        let lines = d.todoLines(key.group, t.id)
        let about = d.todoDescription(key.group, t)
        ScrollViewReader { proxy in
            List {
                if lv == .pulled || (lv == .mid && (t.due != nil || about != nil)) {
                    TodoTop(t: t, group: key.group, about: about, pulled: lv == .pulled, mayEdit: t.author == model.me && !locked, go: go,
                            more: { withAnimation(.snappy) { level = .pulled } }, due: { hideKeyboard(); dueOpen = true },
                            edit: { hideKeyboard(); editOpen = true })
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color(uiColor: .secondarySystemBackground))
                }
                if t.pending {
                    Label("Not sent yet", systemImage: "clock").font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
                ForEach(Array(TodoDay.group(lines).enumerated()), id: \.offset) { _, day in
                    Text(day.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                    ForEach(day.lines) { l in
                        TodoLineRow(line: l, group: key.group).listRowSeparator(.hidden).id(l.id)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 10)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: lines.count) { _, _ in if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !locked { commentBar(t) }
        }
        .navigationTitle(t.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TodoHeader(t: t, group: key.group, open: lv == .pulled) {
                    withAnimation(.snappy) { level = lv == .pulled ? (TodoLevel.start(t, me: model.me) == .mid ? .mid : .folded) : .pulled }
                }
            }
            if !locked { ToolbarItem(placement: .topBarTrailing) { moreMenu(t) } }
        }
        .confirmationDialog("Delete this to-do?", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.todo(t, in: key.group, "delete")
                dismiss()
            }
        } message: { Text("It goes for everyone in \(channelName).") }
        .navigationDestination(isPresented: $picking) { AssignPicker(key: key).overRoot() }
        .navigationDestination(isPresented: $dueOpen) { TodoDueScreen(key: key).overRoot() }
        .navigationDestination(isPresented: $editOpen) { TodoEditScreen(key: key).overRoot() }
        .onAppear {
            if model.launch.screen == "todoassign" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { picking = true } }
            // screenshots: -todo pulled | folded
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-todo"), i + 1 < args.count, level == nil {
                level = args[i + 1] == "pulled" ? .pulled : args[i + 1] == "folded" ? .folded : nil
            }
        }
    }

    /// Claim / take over, assign, unassign, the due date (its author), delete (its author).
    private func moreMenu(_ t: TodoTask) -> some View {
        let mine = t.assignee == model.me
        return Menu {
            if !t.done {
                if !mine {
                    Button { model.assignTodo(t, in: key.group, to: model.me) } label: {
                        Label(t.assignee == nil ? "Claim it" : "Take it over", systemImage: "hand.raised")
                    }
                }
                Button { hideKeyboard(); picking = true } label: { Label("Assign to…", systemImage: "person.badge.plus") }
                if t.assignee != nil {
                    Button { model.assignTodo(t, in: key.group, to: nil) } label: {
                        Label(mine ? "Let it go" : "Unassign", systemImage: "person.crop.circle.badge.minus")
                    }
                }
            }
            if t.author == model.me {
                Button { hideKeyboard(); dueOpen = true } label: {
                    Label(t.due == nil ? "Add a due date" : "Change the due date", systemImage: "calendar")
                }
                Divider()
                Button(role: .destructive) { askDelete = true } label: { Label("Delete the to-do", systemImage: "trash") }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("More")
        .accessibilityIdentifier("todo-more")
    }

    private func commentBar(_ t: TodoTask) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Comment", text: $comment, axis: .vertical).font(.body).lineLimit(1...5)
                .focused($commentFocused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("todo-comment")
            BusyButton {
                let text = comment.jsTrim()
                guard !text.isEmpty else { return }
                model.commentTodo(t, in: key.group, text: text)
                comment = ""
            } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
            .buttonStyle(.borderless)
            .disabled(comment.jsTrim().isEmpty)
            .accessibilityLabel("Send the comment")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private var channelName: String {
        model.derive.label(key.group)
    }
}

enum TodoLevel {
    case folded, mid, pulled
    /// Mid while it needs me (open, on me or on nobody), else folded.
    static func start(_ t: TodoTask, me: String) -> TodoLevel {
        !t.done && (t.assignee == nil || t.assignee == me) ? .mid : .folded
    }
}

/// "Due Sat 28 Nov, 9 AM", "Done Sat 28 Nov", the feed's day titles.
enum TodoFormat {
    static func day(_ at: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(at))).replacingOccurrences(of: ",", with: "")
    }

    static func time(_ at: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        let min = Calendar.current.component(.minute, from: date)
        return date.formatted(min == 0 ? .dateTime.hour() : .dateTime.hour().minute())
    }

    static func due(_ at: Int) -> String { day(at) + ", " + time(at) }

    /// The spoken date: "Saturday 28 November, 9 AM".
    static func spoken(_ at: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(at)).formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
    }
}

/// The lines of one day.
struct TodoDay {
    let title: String
    let lines: [TodoEntry]

    static func group(_ lines: [TodoEntry]) -> [TodoDay] {
        var out = [TodoDay]()
        let cal = Calendar.current
        for l in lines {
            let date = Date(timeIntervalSince1970: TimeInterval(l.at))
            let title = cal.isDateInToday(date) ? "Today" : cal.isDateInYesterday(date) ? "Yesterday" : TodoFormat.day(l.at)
            if let last = out.last, last.title == title { out[out.count - 1] = TodoDay(title: title, lines: last.lines + [l]) }
            else { out.append(TodoDay(title: title, lines: [l])) }
        }
        return out
    }
}

/// The header in the navigation bar: the tick (its own button) and the title, then the icon row.
/// A tap on the title opens or closes the pulled level.
struct TodoHeader: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    let open: Bool
    let tap: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            TodoTick(t: t, group: group, size: 30)
            Button(action: tap) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(MarkdownText.plainLinks(t.title)).font(.headline).strikethrough(t.done).foregroundStyle(.primary).lineLimit(1)
                        .accessibilityIdentifier("todo-title")
                    IconRow(items: items, font: .caption2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Shows less" : "Shows the to-do")
            .accessibilityIdentifier("todo-header")
        }
    }

    private var items: [HeaderItem] {
        var out = [HeaderItem]()
        let who = t.assignee.map { $0 == model.me ? "You" : model.name($0) }
        if t.done {
            let at = t.doneAt ?? Int.now
            out.append(HeaderItem(key: "lead", icon: "checkmark", text: "Done " + TodoFormat.day(at), label: "Done on " + TodoFormat.spoken(at), tint: .green))
            if let who { out.append(HeaderItem(key: "owner", icon: "person", text: who, label: "Done by " + who)) }
        } else if let who {
            out.append(HeaderItem(key: "lead", icon: "person", text: who, label: "Assigned to " + who, tint: .primary))
        } else {
            out.append(HeaderItem(key: "lead", icon: "person", text: "Unassigned", label: "Unassigned"))
        }
        if let c = HeaderItem.count("comments", "bubble.left", t.comments.count, "comment", "comments") { out.append(c) }
        return out
    }
}

/// Mid: the due line, two lines of the description and More. Pulled: the due line (or "Add a due
/// date" for its author), the whole description, the message it came from.
struct TodoTop: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    let about: String?
    let pulled: Bool
    let mayEdit: Bool
    var go: ((LogGo) -> Void)?
    let more: () -> Void
    let due: () -> Void
    var edit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pulled {
                HStack {
                    Text("THE TO-DO").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    Spacer()
                    // its author edits the description (the lead's ruling, docs/one-shape.md)
                    if mayEdit {
                        Button("Edit", action: edit).font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                            .accessibilityLabel("Edit the description")
                            .accessibilityIdentifier("todo-edit")
                    }
                }
            }
            if let at = t.due {
                Button(action: due) {
                    Label("Due " + TodoFormat.due(at), systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!mayEdit)
                .accessibilityLabel("Due " + TodoFormat.spoken(at))
                .accessibilityIdentifier("todo-due")
            } else if pulled && mayEdit {
                Button(action: due) { Label("Add a due date", systemImage: "calendar.badge.plus").font(.subheadline) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("todo-due-add")
            }
            if let about {
                if pulled { MarkdownText(text: about) } else { Text(MarkdownText.plainLinks(about)).font(.body).lineLimit(2) }
                if !pulled {
                    Button("More", action: more).font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                        .accessibilityIdentifier("todo-more-text")
                }
            }
            if pulled && t.due == nil && about == nil && t.source == nil && !mayEdit {
                Text("No due date and no description.").font(.subheadline).foregroundStyle(.secondary)
            }
            if pulled, let src = t.source {
                let who = model.derive.message(group, src).map { model.name($0.ev.pubkey) }
                let title = who.map { "From \($0)'s message" } ?? "From a message"
                if let go {
                    Button { go(.thread(src)) } label: { sourceLabel(title) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("todo-thread")
                } else {
                    NavigationLink(value: ChatRoute(id: group, focus: src)) { sourceLabel(title) }
                        .accessibilityIdentifier("todo-thread")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func sourceLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
            Text(title)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
        }
        .font(.footnote).foregroundStyle(Color.brand)
    }
}

/// A comment (face, name, time, text) or a quiet line (icon, bold name, what happened, time).
struct TodoLineRow: View {
    @EnvironmentObject var model: AppModel
    let line: TodoEntry
    let group: String

    var body: some View {
        if case .comment(let text) = line.what {
            HStack(alignment: .top, spacing: 10) {
                Avatar(pubkey: line.author, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(who(line.author)).font(.subheadline.weight(.semibold))
                        Text(TodoFormat.time(line.at)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(MarkdownText.plainLinks(text)).font(.body)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).font(.footnote).foregroundStyle(tint).frame(width: 20)
                (Text(who(line.author)).fontWeight(.semibold) + Text(" " + words) + Text("  " + TodoFormat.time(line.at)).foregroundColor(.secondary))
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func who(_ pk: String) -> String { pk == model.me ? "You" : model.name(pk) }

    private var icon: String {
        switch line.what {
        case .made: return "checklist"
        case .claimed, .assigned: return "person"
        case .unassigned, .letGo: return "person.crop.circle.badge.minus"
        case .done: return "checkmark.circle.fill"
        case .reopened: return "arrow.uturn.backward.circle"
        case .due: return "calendar"
        case .comment: return "bubble.left"
        }
    }

    private var tint: Color { if case .done = line.what { return .green }; return .secondary }

    private var words: String {
        switch line.what {
        case .made(let from): return from.map { "made this to-do from " + ($0 == model.me ? "your" : model.name($0) + "'s") + " message" } ?? "made this to-do"
        case .claimed: return "took it"
        case .assigned(let to): return "assigned it to " + (to == model.me ? "you" : model.name(to))
        case .unassigned(let p): return "took it off " + (p == model.me ? "you" : model.name(p))
        case .letGo: return "let it go"
        case .done: return "marked it done"
        case .reopened: return "reopened it"
        case .due(let at): return at.map { "set the due date to " + TodoFormat.due($0) } ?? "removed the due date"
        case .comment: return ""
        }
    }
}

/// The description (its author): Markdown, up to 2000 characters; empty removes it.
struct TodoEditScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let key: TodoKey
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        let t = model.derive.tasks(key.group).first { $0.id == key.task }
        let over = text.jsTrim().utf16.count - TodoDue.descriptionLimit
        Form {
            Section {
                TextField("What needs doing, where, with what", text: $text, axis: .vertical)
                    .font(.body).lineLimit(6...20)
                    .accessibilityIdentifier("todo-edit-field")
            } header: { Text("Description") } footer: {
                Text(over > 0 ? "\(over) character\(over == 1 ? "" : "s") too long." : "Markdown works: **bold**, lists, links.")
                    .foregroundStyle(over > 0 ? Color.red : Color.secondary)
            }
            Section {
                BusyButton {
                    if let t { model.setTodoDescription(t, in: key.group, text) }
                    dismiss()
                } label: { Text("Save").frame(maxWidth: .infinity) }
                .buttonStyle(.brand)
                .disabled(over > 0 || t == nil)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("todo-edit-save")
            }
        }
        .navigationTitle(t?.title ?? "To-do")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = t?.about ?? ""
        }
    }
}

/// The due date (its author): a date and time, Save, Remove.
struct TodoDueScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let key: TodoKey
    @State private var date = Date()
    @State private var loaded = false

    var body: some View {
        let t = model.derive.tasks(key.group).first { $0.id == key.task }
        Form {
            Section {
                DatePicker("Due", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("todo-due-picker")
            }
            Section {
                BusyButton {
                    if let t { model.setTodoDue(t, in: key.group, due: Int(date.timeIntervalSince1970)) }
                    dismiss()
                } label: { Text("Save").frame(maxWidth: .infinity) }
                .buttonStyle(.brand)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("todo-due-save")
                if t?.due != nil {
                    BusyButton(role: .destructive) {
                        if let t { model.setTodoDue(t, in: key.group, due: nil) }
                        dismiss()
                    } label: { Text("Remove the due date").frame(maxWidth: .infinity) }
                    .accessibilityIdentifier("todo-due-remove")
                }
            }
        }
        .navigationTitle("Due date")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let at = t?.due { date = Date(timeIntervalSince1970: TimeInterval(at)) }
            else {
                // tomorrow at 9
                let cal = Calendar.current
                let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
                date = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            }
        }
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
                Section(g.map { "People in " + $0.label } ?? "People") {
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
