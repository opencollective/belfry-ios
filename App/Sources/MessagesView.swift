import BelfryCore
import SwiftUI

// Messages: NIP-17 conversations and e-mail threads (one per subject), SPEC 10.

struct ConvRoute: Hashable { let conv: String }

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var newOne = false
    @State private var path = [ConvRoute]()
    @State private var didLaunch = false

    var body: some View {
        let _ = model.version
        let threads = model.dms?.threads() ?? []
        List {
            if threads.isEmpty {
                ContentUnavailableView("No messages", systemImage: "envelope", description: Text("Write to anyone in the town with the pen."))
            }
            // "Your address: sam@demo.belfry.sh" (board home/messages)
            if let a = model.dms?.myAddress, !a.isEmpty {
                Text("Your address: \(a)").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("messages-address")
            }
            ForEach(threads) { t in
                // a row opens its conversation; no chevron (the board has none)
                Button { navigate(t.conv) } label: { ThreadRow(thread: t).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { DrawerButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newOne = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New message")
            }
        }
        .sheet(isPresented: $newOne) { NewConversation() }
        .onDisappear { model.messagesOpen = false }
        .onAppear {
            model.messagesOpen = true
            guard !didLaunch else { return }
            didLaunch = true
            if ["conversation", "mail", "sendstill", "sendnotyet", "dmfiles", "dmfilessending", "typingdm"].contains(model.launch.screen ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let list = model.dms?.threads() ?? []
                    let pick = model.launch.screen == "mail" ? list.first { MailThreads.isMail($0.conv) } : list.first { !MailThreads.isMail($0.conv) }
                    if let pick { navigate(pick.conv) }
                }
            }
        }
    }

    @Environment(\.openConversation) private var navigate
}

private struct OpenConversationKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var openConversation: (String) -> Void {
        get { self[OpenConversationKey.self] }
        set { self[OpenConversationKey.self] = newValue }
    }
}

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: DmThread

    var body: some View {
        let mail = MailThreads.isMail(thread.conv)
        HStack(alignment: .top, spacing: 12) {
            if mail {
                Image(systemName: "envelope.fill").font(.title3).foregroundStyle(Theme.onAccent)
                    .frame(width: 40, height: 40).background(Color.brand, in: Circle())
                    .accessibilityHidden(true)
            } else {
                Avatar(pubkey: MailThreads.peers(thread.conv).first ?? "", size: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.body.weight(thread.unread > 0 ? .semibold : .regular)).lineLimit(1)
                    Spacer()
                    Text(Format.brief(thread.last.at)).font(.caption).foregroundStyle(.secondary)
                }
                if mail { Text(model.dms?.threadName(thread.conv) ?? "").font(.subheadline.weight(.medium)).lineLimit(1) }
                // one to one: "typing…" with the dots in place of the preview (SPEC 19.66)
                if !mail, MailThreads.peers(thread.conv).filter({ $0 != model.me }).count == 1, !model.typing.typers(Typing.place(conv: thread.conv)).isEmpty {
                    HStack(spacing: 6) { TypingDots(); Text("typing…") }.font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("row-typing")
                } else {
                    Text((thread.last.mine ? "You: " : "") + lastLine(mail)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if thread.unread > 0 {
                Circle().fill(Color.brand).frame(width: 10, height: 10).padding(.top, 6).accessibilityLabel("Unread")
            }
        }
        .accessibilityElement(children: .combine)
    }

    var title: String { convName(model, thread.conv) }

    /// "Picture", "3 pictures", "File: Garden plan 2027.pdf", "Audio recording · 0:42"; else the text.
    private func lastLine(_ mail: Bool) -> String {
        let last = thread.last
        if mail { return last.text }
        if let g = last.group, last.kind == DmFiles.kind || last.kind == 14 {
            let files = (model.dms?.thread(thread.conv) ?? []).filter { $0.group == g && $0.from == last.from }.compactMap(\.file)
            if last.kind == 14 { return model.derive.plainRefs(last.text) }
            return DmFiles.lastLine(files)
        }
        return last.kind == DmFiles.kind ? last.text : model.derive.plainRefs(last.text)
    }
}

@MainActor func convName(_ model: AppModel, _ conv: String) -> String {
    if MailThreads.isMail(conv) {
        let a = MailThreads.address(conv)
        let named = model.dms?.threads().flatMap { model.dms?.thread($0.conv) ?? [] }.first { !$0.mine && $0.fromName != nil && MailThreads.isMail($0.conv) && MailThreads.address($0.conv) == a }?.fromName
        return named ?? a
    }
    return MailThreads.peers(conv).map(model.name).joined(separator: ", ")
}

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    let conv: String
    @State private var text = ""
    @State private var subject = ""
    @State private var error: String?
    @State private var sending = 0
    @State private var lastSending = 0

    var body: some View {
        let _ = model.version
        let list = model.dms?.thread(conv) ?? []
        let mail = MailThreads.isMail(conv)
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if list.isEmpty {
                    Text(mail ? "A new e-mail to \(MailThreads.address(conv)): its subject names the thread. It goes out from \(model.dms?.myAddress ?? "your address here"); answers land in the thread."
                         : "No messages yet. Only you two can read them.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
                ForEach(DmBlocks.of(list)) { b in
                    if !b.files.isEmpty { DmFilesBlock(files: b.files) }
                    if let c = b.caption { Bubble(dm: c) }
                }
            }
            .padding()
            // the end, outside the lazy stack: what arrives after the screen opened (files, my
            // own send) still ends the conversation above the composer
            Color.clear.frame(height: 1).id("conv-end")
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: list.count) { _, _ in DispatchQueue.main.async { withAnimation(.snappy) { proxy.scrollTo("conv-end", anchor: .bottom) } } }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("conv-end", anchor: .bottom) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(mail && !MailThreads.isNewMail(conv) ? (model.dms?.threadName(conv) ?? "") : convName(model, conv))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // a person: their face and name, a tap pushes their profile (board home/conversation)
            if !mail, MailThreads.peers(conv).count == 1, let peer = MailThreads.peers(conv).first, isHex64(peer) {
                ToolbarItem(placement: .principal) {
                    Button { model.openProfile = peer } label: {
                        VStack(spacing: 1) {
                            Avatar(pubkey: peer, size: 26)
                            HStack(spacing: 3) {
                                Text(convName(model, conv)).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(convName(model, conv))’s profile")
                    .accessibilityIdentifier("dm-header")
                }
            }
        }
        .onAppear { model.markConversationRead(conv); model.visibleConversation = conv }
        .onChange(of: text) { old, t in
            guard !mail else { return }
            let place = Typing.place(conv: conv)
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { if !old.isEmpty, sending == lastSending { model.typing.cleared(place: place) } }
            else { model.typing.key(place: place, text: t) }
            lastSending = sending
        }
        .onDisappear { if model.visibleConversation == conv { model.visibleConversation = nil } }
        .onChange(of: list.count) { _, _ in model.markConversationRead(conv) }
        .bottomBar {
            VStack(spacing: 6) {
                if !mail { TypingLine(center: model.typing, place: Typing.place(conv: conv)).padding(.top, -22).frame(height: 0, alignment: .bottom) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if MailThreads.isNewMail(conv) {
                    TextField("Subject", text: $subject).font(.body)
                        .padding(.horizontal, 14).frame(minHeight: 38)
                        .composerField()
                }
                // the channel composer's shape: a capsule field with Send inside it
                let can = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                HStack(alignment: .bottom, spacing: 8) {
                if !mail { DmAddMenu(conv: conv, error: $error) }
                HStack(alignment: .bottom, spacing: 0) {
                    TextField(mail ? "Write an e-mail" : "Message", text: $text, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...8)
                        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 8)
                        .frame(minHeight: 38)
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(can ? Theme.onAccent : Color.secondary)
                            .frame(width: 30, height: 30)
                            .background(can ? Theme.accent : Color.secondary.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .disabled(!can)
                    .accessibilityLabel("Send")
                }
                .composerField()
                }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            .composerBackground(compact: false)
            .sensoryFeedback(.impact(weight: .light), trigger: sending)
        }
    }

    func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let dms = model.dms else { return }
        if MailThreads.isNewMail(conv), subject.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "Give it a subject: it names the thread."
            return
        }
        error = nil
        model.typing.sent(place: Typing.place(conv: conv))
        sending += 1
        text = ""
        Task {
            do {
                if MailThreads.isMail(conv) {
                    try await dms.sendMail(t, in: conv, subject: subject, fromName: model.realName(model.me))
                } else {
                    try await dms.send(t, in: conv)
                }
            } catch {
                text = t
                self.error = (error as? BelfryError)?.errorDescription ?? "Not sent. Try again."
            }
        }
    }
}

struct Bubble: View {
    @EnvironmentObject var model: AppModel
    let dm: Dm
    @State private var moreEmoji = false

    /// A direct message that went out or came in (never an e-mail, never one still sending).
    private var canReact: Bool { dm.kind == 14 && dm.pending != true && dm.failed == nil && !model.guestReading }

    private func react(_ emoji: String) {
        EmojiUsage.used(emoji)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { try? await model.dms?.react(emoji, on: dm) }
    }

    var body: some View {
        let report = model.dms?.report(dm.emailId)
        VStack(alignment: dm.mine ? .trailing : .leading, spacing: 4) {
            if !dm.mine, dm.kind == 1301 {
                HStack(spacing: 4) {
                    Text(dm.fromName ?? dm.from).font(.caption.weight(.semibold))
                    if dm.verified == true { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green).accessibilityLabel("Verified sender") }
                }
            }
            if dm.kind == 1301, let s = dm.subject { Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            // a direct message ends with a reference: its box under the bubble's text (not in e-mails)
            VStack(alignment: .leading, spacing: 6) {
                if dm.kind == 1301 { MarkdownText(text: dm.text.isEmpty ? " " : dm.text) } else { MessageText(text: dm.text.isEmpty ? " " : dm.text) }
            }
                .padding(10)
                .background(dm.mine ? Color.brand.opacity(0.14) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu {
                    // the reactions row, then the menu (board home/conversation); not on e-mails
                    if canReact {
                        // as on a channel's message: the four I use most, then the larger choice
                        ControlGroup {
                            ForEach(EmojiUsage.top(4), id: \.self) { e in
                                Button { react(e) } label: { Text(e) }.accessibilityLabel("React with \(e)")
                            }
                            Button { moreEmoji = true } label: { Label("More reactions", systemImage: "face.smiling") }
                        }
                        .controlGroupStyle(.compactMenu)
                    }
                    Button {
                        UIPasteboard.general.string = dm.text
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: { Label("Copy text", systemImage: "doc.on.doc") }
                }
            // reactions under the bubble, on its side: the same chips as in channels
            if canReact {
                let chips = model.dms?.chips(dm.rid) ?? []
                if !chips.isEmpty {
                    ReactionBar(reactions: chips.map { Reaction(emoji: $0.emoji, who: $0.who, mine: $0.mine ? dm.rid : nil) }) { e in react(e) }
                        .accessibilityIdentifier("dm-reactions")
                }
            }
            HStack(spacing: 6) {
                Text(Format.time(dm.at)).font(.caption2).foregroundStyle(.secondary)
                if let f = dm.failed {
                    Label("Not sent", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.red).help(f)
                    Button("Retry") { model.dms?.retry(dm) }.font(.caption2.weight(.semibold))
                } else if dm.pending == true {
                    SendLineView(id: dm.rid, tries: model.dmTries(dm.rid), font: .caption2, icon: false)
                } else if dm.mine, let r = report {
                    Text(r.details).font(.caption2).foregroundStyle(r.status == "failed" ? .red : .secondary)
                }
            }
            if let atts = dm.attachments, !atts.isEmpty {
                ForEach(atts, id: \.name) { a in Label("\(a.name) · \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))", systemImage: "paperclip").font(.caption) }
            }
        }
        .frame(maxWidth: .infinity, alignment: dm.mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .sheet(isPresented: $moreEmoji) {
            ReactionPicker { e in
                moreEmoji = false
                react(e)
            }
        }
    }
}

struct NewConversation: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openConversation) private var navigate
    @State private var to = ""
    @State private var error: String?

    var body: some View {
        let people = model.profiles.filter { $0.key != model.me && ($0.value.name != nil || $0.value.nip05 != nil) }
            .map { (pubkey: $0.key, name: $0.value.name ?? "", nip05: $0.value.nip05) }
            .sorted { $0.name < $1.name }
        let q = to.lowercased()
        let matches = q.isEmpty ? Array(people.prefix(8)) : people.filter { $0.name.lowercased().contains(q) || ($0.nip05?.lowercased().contains(q) ?? false) }
        NavigationStack {
            List {
                Section {
                    TextField("A name, name@\(model.config.domain) or an e-mail address", text: $to)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                        .onSubmit(go)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("Members") {
                    ForEach(matches, id: \.pubkey) { p in
                        Button { open("n:" + p.pubkey) } label: {
                            HStack { Avatar(pubkey: p.pubkey, size: 30); VStack(alignment: .leading) { Text(p.name); if let n = p.nip05 { Text(n).font(.caption).foregroundStyle(.secondary) } } }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Next", action: go).disabled(to.isEmpty) }
            }
        }
    }

    func go() {
        let people = model.profiles.map { (pubkey: $0.key, name: $0.value.name ?? "", nip05: $0.value.nip05) }
        Task {
            if let c = await model.dms?.conv(for: to, people: people) { open(c) } else { error = "That's not a member nor an e-mail address." }
        }
    }

    func open(_ conv: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { navigate(conv) }
    }
}
