import BelfryCore
import SwiftUI

// Messages: NIP-17 conversations and e-mail threads (one per subject), SPEC 10.

struct ConvRoute: Hashable { let conv: String }

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var newOne = false
    @State private var path = [ConvRoute]()
    @State private var didLaunch = false
    @State private var how = false

    var body: some View {
        let _ = model.version
        let threads = model.dms?.threads() ?? []
        List {
            // this device is not allowed yet (whether or not anything arrived), or holds messages
            // it has no key for: the banner says how many wait. My devices not read yet and
            // messages kept meanwhile: "Checking your devices…". Never "No messages" under it.
            let st = model.sealed
            let locked = st.notAllowed || st.missingKeys || threads.contains(where: { model.lockedHere($0.conv) })
            let checking = !locked && st.checkingCount > 0
            if locked || checking {
                LockedHereBanner(waiting: locked ? st.waitingCount : st.checkingCount, checking: checking) { how = true }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            }
            if threads.isEmpty && !locked && !checking {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { newOne = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New message")
            }
        }
        .drawerItem()
        .sheet(isPresented: $newOne) { NewConversation() }
        .navigationDestination(isPresented: $how) { UnlockHowScreen() }
        .onDisappear { model.messagesOpen = false }
        .onAppear {
            model.messagesOpen = true
            guard !didLaunch else { return }
            didLaunch = true
            let screen = model.launch.screen ?? ""
            if ["conversation", "mail", "encmail", "encmaildevices", "sendstill", "sendnotyet", "dmfiles", "dmfilessending", "typingdm"].contains(screen) {
                // the demo's e-mail may still be on its way in: look a few times
                Task { @MainActor in
                    for _ in 0..<6 {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        let list = model.dms?.threads() ?? []
                        let wantsMail = ["mail", "encmail", "encmaildevices"].contains(screen)
                        let pick = wantsMail ? list.first { MailThreads.isMail($0.conv) } : list.first { !MailThreads.isMail($0.conv) }
                        if let pick { navigate(pick.conv); return }
                    }
                }
            }
            // boards messages/encryption-*: Lina's conversation, the group's, the three steps
            if screen == "encshared" || screen == "encsharedwhy" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { navigate("n:" + Demo.signer("dev").pubkey) } }
            // board one-shape/dm-thread: Ana's conversation holds the demo's thread
            if screen == "dmthread" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { navigate("n:" + Demo.signer("ana").pubkey) } }
            if screen == "enclocked" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { navigate("n:" + Demo.signer("ana").pubkey) } }
            if ["encthread", "encdevices", "encshare", "encwaiting", "encheld"].contains(screen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { navigate("n:" + Demo.signer("lina").pubkey) }
            }
            if screen == "encgroup" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { navigate(Demo.groupConv(me: model.me)) } }
            if ["enchow", "encfresh", "encfreshconfirm"].contains(screen) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { how = true } }
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
                if mail, !model.lockedHere(thread.conv) { Text(model.dms?.threadName(thread.conv) ?? "").font(.subheadline.weight(.medium)).lineLimit(1) }
                if model.lockedHere(thread.conv) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.caption)
                        Text("Locked on this device").font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                } else if !mail, model.sealedConv(thread.conv) == nil, MailThreads.peers(thread.conv).filter({ $0 != model.me }).count == 1, !model.typing.typers(Typing.place(conv: thread.conv)).isEmpty {
                    // one to one: "typing…" with the dots in place of the preview (SPEC 19.66); never in a sealed conversation
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
    /// The Encryption screen, pushed by the lock and by a device line.
    @State private var encryption = false
    /// The amber line's sheet: share history with someone's new device.
    @State private var sharing: DeviceNotice?
    @State private var how = false
    /// A message's thread (one shape: Reply starts it), pushed.
    @State private var threadOf: DmThreadRoute?

    /// Messages and device lines, in the order they happened.
    private enum Row: Identifiable {
        case dm(Dm), files([Dm]), notice(DeviceNotice)
        var id: String {
            switch self {
            case .dm(let d): return d.rid
            case .files(let f): return "files:" + (f.first?.rid ?? "")
            case .notice(let n): return "notice:" + n.id
            }
        }
        var at: Int {
            switch self {
            case .dm(let d): return d.at
            case .files(let f): return f.first?.at ?? 0
            case .notice(let n): return n.at
            }
        }
    }

    /// The first message of each block of shared history (a block = one sharer's run of messages).
    static func blockStarts(_ list: [Dm]) -> Set<String> {
        var out = Set<String>()
        var last: String?
        for d in list {
            if let by = d.sharedBy, by != last { out.insert(d.rid) }
            last = d.sharedBy
        }
        return out
    }

    /// Files sent together are one row (vectors/dm-files.json "bubbles"), their caption the next.
    private func rows(_ list: [Dm], _ sealed: SealedConv?) -> [Row] {
        var out = [Row]()
        for b in DmBlocks.of(list) {
            if !b.files.isEmpty { out.append(.files(b.files)) }
            if let c = b.caption { out.append(.dm(c)) }
        }
        guard let sealed, !sealed.notices.isEmpty else { return out }
        return (out + sealed.notices.map { Row.notice($0) }).sorted { $0.at < $1.at }
    }
    @State private var lastSending = 0

    var body: some View {
        let _ = model.version
        // a device nobody allowed yet reads no sealed message, old or new: what was written before
        // the conversation was sealed, then the amber block; no composer
        let locked = model.lockedHere(conv)
        let since = model.sealedConv(conv)?.since
        // (my own messages held while locked stay, with the locked line's words: never sent, never lost)
        let list = (model.dms?.thread(conv) ?? []).filter { d in !locked || (d.mine && d.pending == true) || since.map { d.at < $0 } ?? false }
        let mail = MailThreads.isMail(conv)
        // a sealed conversation has the lock by its name; one that is not sealed has none
        let sealed = model.sealedConv(conv)
        let firstShared = ConversationView.blockStarts(list)
        // replies sit under their root (one-shape.md §3); one whose root isn't here shows in line
        let split = DmThreads.split(list)
        let canThread = !mail && !locked
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if list.isEmpty, !locked {
                    Text(mail ? "A new e-mail to \(MailThreads.address(conv)): its subject names the thread. It goes out from \(model.dms?.myAddress ?? "your address here"); answers land in the thread."
                         : "No messages yet. Only you two can read them.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
                ForEach(rows(split.main, locked ? nil : sealed)) { r in
                    switch r {
                    case .dm(let d):
                        if let by = d.sharedBy {
                            // shared history: one line per block, the block marked by a rule on its left
                            if firstShared.contains(d.rid) { SharedByLine(by: by) }
                            Bubble(dm: d)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2) }
                        } else {
                            Bubble(dm: d, reply: canThread ? ({ openThread(d) } as () -> Void) : nil)
                            if let replies = split.replies[d.rid], !replies.isEmpty {
                                RepliesLine(dm: d, replies: replies) { openThread(d) }
                            }
                        }
                    case .files(let f):
                        DmFilesBlock(files: f)
                    case .notice(let n):
                        // the amber line opens the sheet; every other line the Encryption screen
                        DeviceNoticeLine(notice: n) { hideKeyboard(); if n.what == .locked { sharing = n } else { encryption = true } }
                    }
                }
                if locked { LockedThreadBlock(since: since) { how = true } }
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
                    // the face and the name push the profile; the small lock by the name of a sealed
                    // conversation pushes the Encryption screen (board messages/encryption-thread)
                    VStack(spacing: 1) {
                        Button { model.openProfile = peer } label: { Avatar(pubkey: peer, size: 26) }
                            .buttonStyle(.plain)
                            .accessibilityHidden(true)
                        HStack(spacing: 0) {
                            // face, name, lock, ›: the same header sealed or not
                            Button { model.openProfile = peer } label: {
                                Text(convName(model, conv)).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(convName(model, conv))’s profile")
                            .accessibilityIdentifier("dm-header")
                            if sealed != nil { SealedLock { hideKeyboard(); encryption = true }.frame(width: 18, height: 16) }
                            Button { model.openProfile = peer } label: {
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                                    .padding(.leading, 3).frame(height: 16).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHidden(true)
                        }
                    }
                }
            } else if sealed != nil {
                // a group, an e-mail thread: its title with the lock
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 0) {
                        Text(mail && !MailThreads.isNewMail(conv) ? (model.dms?.threadName(conv) ?? "") : convName(model, conv))
                            .font(.headline).lineLimit(1)
                        SealedLock { hideKeyboard(); encryption = true }.frame(width: 24, height: 30)
                    }
                }
            }
        }
        .navigationDestination(item: $threadOf) { r in DmThreadView(conv: r.conv, root: r.root) }
        .navigationDestination(isPresented: $encryption) { EncryptionScreen(conv: conv) }
        .navigationDestination(isPresented: $how) { UnlockHowScreen() }
        .sheet(item: $sharing) { n in ShareHistorySheet(conv: conv, notice: n) }
        .task {
            // screenshots (boards messages/encryption-*)
            let screen = model.launch.screen ?? ""
            // a send that was refused (board messages/encryption-held): the text kept, the grey line
            if screen == "encheld" { text = "I'll bring the ladder at 8:30."; error = DirectMessages.cantCheck }
            // one shape (board one-shape/dm-thread): the first message with replies, its thread
            if screen == "dmthread" {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if let r = DmThreads.split(model.dms?.thread(conv) ?? []).replies.keys.sorted().first { threadOf = DmThreadRoute(conv: conv, root: r) }
                return
            }
            guard ["encdevices", "encgroup", "encmaildevices", "encshare"].contains(screen) else { return }
            try? await Task.sleep(nanoseconds: 700_000_000) // after the push: the picture is taken 6 s after launch
            if screen == "encshare" { sharing = sealed?.notices.first { $0.what == .locked } } else { encryption = true }
        }
        .onAppear { model.markConversationRead(conv); model.visibleConversation = conv }
        // a sealed conversation opened: its people's device lists as the relay has them now
        .task { if sealed != nil, let se = model.sealedEngine { await se.refresh(MailThreads.peers(conv)); model.refreshSealed() } }
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
            if locked || (sealed != nil && model.sealed.waitingForKey) {
                // not allowed yet: a plain grey line. Allowed, the key not here yet: the same line
                // with a small spinner (board messages/encryption-waiting); it clears by itself
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        if !locked { ProgressView().controlSize(.small) }
                        Text(locked ? "You can write here once this device is allowed." : "Waiting for another of your devices…")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    // after a day without an answer (the way out, starting fresh, is not built yet)
                    if !locked, model.sealed.waitingLong {
                        Text("None of your other devices has answered.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .composerBackground(compact: false)
            } else {
            VStack(spacing: 6) {
                if !mail, model.sealedConv(conv) == nil { TypingLine(center: model.typing, place: Typing.place(conv: conv)).padding(.horizontal, -12) }
                // a refusal to send unlocked is a quiet grey line, the text stays in the box; a failure is red
                if let error { Text(error).font(.caption).foregroundStyle([DirectMessages.cantCheck, Sealed.tooLong].contains(error) ? Color.secondary : Color.red).multilineTextAlignment(.center) }
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
                    TextField(mail ? (MailThreads.isNewMail(conv) ? "Write an e-mail" : "Reply by e-mail") : "Message", text: $text, axis: .vertical)
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
    }

    private func openThread(_ d: Dm) {
        hideKeyboard()
        threadOf = DmThreadRoute(conv: conv, root: d.rid)
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
    /// Reply (one shape): opens the message's thread. Nil where there is no thread (e-mail).
    var reply: (() -> Void)? = nil
    @State private var notSealed = false
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
                    // one shape, this build in a DM: Reply · Copy text (no to-do, no Pin: sealed
                    // rules first)
                    if let reply, canReact {
                        Button(action: reply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
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
                } else if dm.pending == true, model.lockedHere(dm.conv) {
                    // held while this device is out of my head: the locked line's words (board messages/encryption-locked-thread, v123)
                    Label("You can write here once this device is allowed.", systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                } else if dm.pending == true {
                    SendLineView(id: dm.rid, tries: model.dmTries(dm.rid), font: .caption2, icon: false)
                } else if dm.unsealed == true {
                    // it came the old way after the conversation was sealed (board messages/encryption-thread)
                    Button { notSealed = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.open").font(.caption2)
                            Text("Not sealed").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $notSealed) {
                        Text("This message was not sent with the lock. It may come from an old app version.")
                            .font(.footnote).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 250)
                            .padding(14)
                            .presentationCompactAdaptation(.popover)
                    }
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
            do {
                if let c = try await model.dms?.conv(for: to, people: people) { open(c) } else { error = "That's not a member nor an e-mail address." }
            } catch {
                // a name at this belfry whose lookup failed: never opened as e-mail; what was typed stays
                self.error = DirectMessages.cantLookUp
            }
        }
    }

    func open(_ conv: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { navigate(conv) }
    }
}
