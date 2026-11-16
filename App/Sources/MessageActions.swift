import BelfryCore
import SwiftUI

// The message menu (a Discord-style list: quick reactions, then grouped rows with line icons),
// the in-app delete confirmation showing the message (SPEC 19.2), the edit sheet (19.1) and
// the shared inbox's "Reply by e-mail" with its 8 s Undo.

struct MessageActions: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let m: Message
    let group: String
    let onReply: () -> Void
    let onOpenThread: () -> Void
    let onEdit: () -> Void
    @State private var confirmDelete = false
    @State private var moreEmoji = false
    @State private var copied = false

    var body: some View {
        let d = model.derive
        let pending = model.pending(m.id) != nil
        let isReply = m.ev.kind == 1111
        VStack(spacing: 0) {
            if confirmDelete {
                DeleteConfirm(m: m, group: group, cancel: { withAnimation { confirmDelete = false } }) { dismiss() }
            } else {
                List {
                    if !pending && !isReply {
                        Section {
                            HStack(spacing: 0) {
                                ForEach(EmojiUsage.top(6), id: \.self) { e in
                                    Button {
                                        model.toggleReaction(e, on: m, in: group)
                                        dismiss()
                                    } label: { Text(e).font(.title2).frame(maxWidth: .infinity, minHeight: 44) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("React with \(e)")
                                }
                                Button { moreEmoji = true } label: {
                                    Image(systemName: "face.smiling").font(.title3).frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("More reactions")
                            }
                        }
                    }
                    Section {
                        if !pending {
                            Button { dismiss(); onReply() } label: { ActionRow(icon: "arrowshape.turn.up.left", title: "Reply") }
                            if !isReply {
                                Button { dismiss(); onOpenThread() } label: { ActionRow(icon: "bubble.left.and.bubble.right", title: "Open thread") }
                            }
                        }
                        if d.canEdit(m) {
                            Button { dismiss(); onEdit() } label: { ActionRow(icon: "pencil", title: "Edit message") }
                        }
                        if !m.text.isEmpty {
                            Button {
                                UIPasteboard.general.string = d.plainRefs(m.text, npub: "@…")
                                copied = true
                                dismiss()
                            } label: { ActionRow(icon: "doc.on.doc", title: "Copy text") }
                        }
                        Button {
                            UIPasteboard.general.string = d.channelURL(group)
                            dismiss()
                        } label: { ActionRow(icon: "link", title: "Copy link to the channel") }
                        if m.pubkey != model.me && !d.isGuest(model.me) {
                            Button {
                                dismiss()
                                model.messageAuthor = m.pubkey
                            } label: { ActionRow(icon: "envelope", title: "Message \(model.realNameOrKey(m.pubkey))") }
                        }
                    }
                    if !pending {
                        Section {
                            if !isReply && d.canPin(group) {
                                let on = d.isPinned(group, m.id)
                                ActionButtonRow(icon: on ? "pin.slash" : "pin", title: on ? "Unpin from the channel" : "Pin to the channel") {
                                    model.pin(m, in: group, !on)
                                    dismiss()
                                }
                            }
                            if !isReply && d.canMakeTodo(group, m) {
                                ActionButtonRow(icon: "checklist", title: "Turn into a todo", detail: d.todoTitle(m)) {
                                    model.makeTodo(m, in: group)
                                    dismiss()
                                }
                            }
                        }
                    }
                    if d.canDelete(m) || pending && m.pubkey == model.me {
                        Section {
                            Button { withAnimation { confirmDelete = true } } label: {
                                ActionRow(icon: "trash", title: pending ? "Discard" : "Delete message", destructive: true)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .presentationDetents(confirmDelete ? Set([PresentationDetent.medium]) : Set([PresentationDetent.medium, .large]))
        .solidSheet()
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $moreEmoji) {
            EmojiPicker { e in
                model.toggleReaction(e, on: m, in: group)
                moreEmoji = false
                dismiss()
            }
        }
        .onAppear {
            if model.launchDelete { model.launchDelete = false; confirmDelete = true }
        }
    }

    /// An nsite link in a message: nsite:<npub>[/<name>] (SPEC: "Make this the website").
    func nsiteRef(_ text: String) -> String? { MessageActions.nsiteRef(text) }

    static func nsiteRef(_ text: String) -> String? {
        Rx("nsite:(npub1[02-9ac-hj-np-z]{58}(?:/[a-z0-9-]{1,40})?)").first(text)?[1]
    }
}

/// "Delete this message?" inside the menu, showing the message (SPEC 19.2).
struct DeleteConfirm: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        let pending = model.pending(m.id)
        VStack(alignment: .leading, spacing: 14) {
            Text(pending == nil ? "Delete this message?" : "Discard this message?").font(.title3.bold())
            HStack(alignment: .top, spacing: 10) {
                Avatar(pubkey: m.pubkey, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.derive.nameOver(m)).font(.subheadline.weight(.semibold))
                    Text(model.derive.deletePreview(m)).font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text(pending == nil ? "It disappears for everyone, with its reactions. This can't be undone." : "It was never sent: it disappears from this phone.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.bordered).frame(maxWidth: .infinity)
                BusyButton(role: .destructive) {
                    model.delete(m, in: group)
                    done()
                } label: { Text(pending == nil ? "Delete" : "Discard").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(20)
    }
}

struct EmojiPicker: View {
    let pick: (String) -> Void
    static let all = ["👍", "❤️", "😂", "🎉", "🙏", "👀", "🔥", "👏", "😍", "🤔", "😮", "😢",
                      "😅", "🙌", "💪", "✅", "❌", "💯", "🚀", "✨", "🌱", "☕", "🍕", "🍻",
                      "😊", "😎", "🤗", "🥳", "😴", "🤯", "😬", "🙈", "👋", "🤝", "👌", "✌️",
                      "💡", "📌", "📅", "⏰", "🎶", "📷", "🌞", "🌧️", "❄️", "🌈", "🐝", "🌻"]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(EmojiPicker.all, id: \.self) { e in
                    Button { pick(e) } label: { Text(e).font(.largeTitle) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .presentationDetents([.medium])
        .solidSheet()
    }
}

/// Edit my message: the text as I wrote it, channel references back as "#name".
struct EditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let m: Message
    let group: String
    @State private var text = ""
    @State private var picked = [(label: String, ref: String)]()
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(3...12)
                    .font(.body)
                    .focused($focused)
            }
            .navigationTitle("Edit message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Save") {
                        let sent = ChannelRefs.substitute(text.jsTrim(), picked: picked)
                        model.edit(m, in: group, text: sent)
                        dismiss()
                    }
                    .disabled(text.jsTrim().isEmpty || text.jsTrim() == initial)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let back = model.derive.unsubstituteChannels(m.text)
                text = back.text
                picked = back.picked
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }

    var initial: String { model.derive.unsubstituteChannels(m.text).text }
}

struct MessageMenuHandlers {
    var reply: (Message) -> Void
    var openThread: (Message) -> Void
    var edit: (Message) -> Void
    /// The full list (more reactions, the delete confirmation showing the message).
    var sheet: (Message, _ delete: Bool) -> Void
    /// "Propose as the website" on a message with an nsite link.
    var proposeSite: ((Message) -> Void)? = nil
}

struct MessageMenuKey: EnvironmentKey { static let defaultValue: MessageMenuHandlers? = nil }
extension EnvironmentValues {
    var messageMenu: MessageMenuHandlers? {
        get { self[MessageMenuKey.self] }
        set { self[MessageMenuKey.self] = newValue }
    }
}

/// The native menu of a held message (iMessage / WhatsApp): quick reactions in a row, then the
/// web's message menu as rows with icons, Delete last.
struct MessageMenu: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String
    let h: MessageMenuHandlers

    var body: some View {
        let d = model.derive
        let pending = model.pending(m.id) != nil
        let isReply = m.ev.kind == 1111
        if !pending && !isReply {
            ControlGroup {
                ForEach(EmojiUsage.top(4), id: \.self) { e in
                    Button { model.toggleReaction(e, on: m, in: group) } label: { Text(e) }
                        .accessibilityLabel("React with \(e)")
                }
                Button { h.sheet(m, false) } label: { Label("More reactions", systemImage: "face.smiling") }
            }
            .controlGroupStyle(.compactMenu)
        }
        Section {
            if !pending {
                Button { h.reply(m) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                if !isReply {
                    Button { h.openThread(m) } label: { Label("Open thread", systemImage: "bubble.left.and.bubble.right") }
                }
            }
            if d.canEdit(m) {
                Button { h.edit(m) } label: { Label("Edit message", systemImage: "pencil") }
            }
            if !m.text.isEmpty {
                Button {
                    UIPasteboard.general.string = d.plainRefs(m.text, npub: "@…")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: { Label("Copy text", systemImage: "doc.on.doc") }
            }
            Button {
                UIPasteboard.general.string = d.channelURL(group)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: { Label("Copy link to the channel", systemImage: "link") }
            if case .memberMail(let subject, let original?) = m.special {
                Button { model.fullMail = FullMailRef(subject: subject, original: original) } label: { Label("Full e-mail", systemImage: "envelope.open") }
            }
            if m.pubkey != model.me && !d.isGuest(model.me) {
                Button { model.messageAuthor = m.pubkey } label: { Label("Message \(model.realNameOrKey(m.pubkey))", systemImage: "envelope") }
            }
        }
        if !pending {
            Section {
                if !isReply && d.canPin(group) {
                    let on = d.isPinned(group, m.id)
                    Button { model.pin(m, in: group, !on) } label: { Label(on ? "Unpin from the channel" : "Pin to the channel", systemImage: on ? "pin.slash" : "pin") }
                }
                if !isReply && d.canMakeTodo(group, m) {
                    Button { model.makeTodo(m, in: group) } label: { Label("Turn into a todo", systemImage: "checklist") }
                }
                if MessageActions.nsiteRef(m.text) != nil, !d.amGuest, let propose = h.proposeSite {
                    Button { propose(m) } label: { Label("Propose as the website", systemImage: "globe") }
                }
            }
        }
        if d.canDelete(m) || pending && m.pubkey == model.me {
            Section {
                Button(role: .destructive) { h.sheet(m, true) } label: { Label(pending ? "Discard" : "Delete message", systemImage: "trash") }
            }
        }
    }
}

extension View {
    /// Holding a message: the native menu (signed in), or the Join sheet (guest mode).
    @ViewBuilder func messageMenu(_ m: Message, group: String, handlers: MessageMenuHandlers?, guest: Bool, hold: @escaping () -> Void) -> some View {
        if let handlers, !guest {
            self.contextMenu { MessageMenu(m: m, group: group, h: handlers) }
                .accessibilityAction(named: "Actions") { hold() }
        } else {
            self.onLongPressGesture(minimumDuration: 0.35) { hold() }
                .accessibilityAction(named: "Actions") { hold() }
        }
    }
}
