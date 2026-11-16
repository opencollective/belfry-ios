import BelfryCore
import SwiftUI

// E-mail threads in a channel (SPEC 19.33, web MailPost.tsx / Chat.tsx; Xavier 2026-11-16):
// one compact row per thread in the feed; the thread shows each e-mail in a frame (received
// light, sent solid) and the team's replies, with ONE composer and a line above it that says
// where the message goes: "Message will be sent in this thread" / "Reply by e-mail instead",
// or "This will be sent to <name> by e-mail" / "Only send in this thread instead" (the composer
// takes the e-mail colour and shows From and the subject; 8 s to Undo; back to thread mode after).

/// A pointer to a whole e-mail on Blossom ("Full e-mail").
struct FullMailRef: Identifiable, Hashable {
    let subject: String
    let original: MailOriginal
    var id: String { original.url }
}

extension CardStatus {
    var tint: Color { self == .open ? .orange : self == .waiting ? .green : .secondary }
}

/// The feed's row for one e-mail thread: sender, subject, a line of the latest e-mail, state,
/// who has it, counts. A tap opens the thread.
struct MailThreadRow: View {
    @EnvironmentObject var model: AppModel
    let t: InboxThread
    let group: String
    let open: () -> Void

    var body: some View {
        let unread = model.readSync == nil ? 0 : t.ids.reduce(0) { $0 + model.derive.unreadInThread(group, $1, model.readState, now: Int.now) }
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.fill").font(.system(size: 15)).foregroundStyle(Color.brand)
                    .frame(width: 34, height: 34)
                    .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.name.isEmpty ? t.address : t.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.short(t.last)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(t.subject.isEmpty ? "(no subject)" : t.subject).font(.subheadline).lineLimit(1)
                    if let last = t.latest {
                        Text(snippet(last)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Chip(text: t.state.status.label, tint: t.state.status.tint)
                        if let a = t.state.assignee { Text(a == model.me ? "You have it" : "\(model.name(a)) has it").font(.caption2).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text(counts).font(.caption2).foregroundStyle(.secondary)
                        if unread > 0 { CountBadge(n: unread) }
                    }
                }
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .accessibilityIdentifier("mail-thread-row")
    }

    private var counts: String {
        var parts = [t.mails.count == 1 ? "1 e-mail" : "\(t.mails.count) e-mails"]
        if t.replies > 0 { parts.append(t.replies == 1 ? "1 reply" : "\(t.replies) replies") }
        return parts.joined(separator: " · ")
    }

    private func snippet(_ it: MailItem) -> String {
        let s = model.derive.plainRefs(it.m.body.isEmpty ? it.m.text : it.m.body).replacingOccurrences(of: "\n", with: " ")
        return (it.dir == .outgoing ? "Answered: " : "") + (s.isEmpty ? "(empty)" : s)
    }
}

/// One e-mail in the thread: received ones light, what went out solid.
struct MailFrame: View {
    @EnvironmentObject var model: AppModel
    let it: MailItem
    let from: String

    var body: some View {
        let out = it.dir == .outgoing
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: out ? "paperplane.fill" : "envelope")
                Text(header).lineLimit(2)
                Spacer(minLength: 4)
                Text(Format.time(it.m.at))
            }
            .font(.caption)
            .foregroundStyle(out ? Theme.onAccent.opacity(0.85) : Color.secondary)
            if it.dir == .incoming && !it.verified {
                Label("unverified sender", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
            if !it.subject.isEmpty { Text(it.subject).font(.subheadline.weight(.semibold)) }
            let text = it.m.body.isEmpty ? it.m.text : it.m.body
            if !text.isEmpty { MarkdownText(text: text) } else { Text("(empty)").foregroundStyle(.secondary) }
            ForEach(it.m.media, id: \.url) { media in MediaView(media: media, all: it.m.media) }
            if let o = it.original {
                Button { model.fullMail = FullMailRef(subject: it.subject, original: o) } label: { Text("Full e-mail").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brand)
            }
            if out, let by = it.by { Text("Written by \(model.name(by))").font(.caption2).foregroundStyle(Theme.onAccent.opacity(0.8)) }
        }
        .foregroundStyle(out ? Theme.onAccent : Color.primary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(out ? Theme.accent : Color.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(out ? Color.clear : Color.brand.opacity(0.25)))
        .padding(.horizontal)
    }

    private var header: String {
        if it.dir == .outgoing { return "From \(from) · to \(it.address)" }
        return "From " + (it.name.isEmpty ? it.address : "\(it.name) <\(it.address)>")
    }
}

/// An e-mail thread's own screen.
struct MailThreadView: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let threadId: String
    var focusReply = false
    @State private var feedPos = FeedPosition()
    @State private var mode = Mode.thread
    @State private var countdown = 0
    @State private var timer: Timer?
    @State private var pendingText = ""
    @State private var sentId: String?
    @State private var error: String?
    @State private var composerKey = 0
    @State private var actionsFor: Message?

    enum Mode { case thread, mail }
    enum Entry: Identifiable {
        case mail(MailItem)
        case reply(Message)
        var id: String { switch self { case .mail(let m): return m.m.id; case .reply(let r): return r.id } }
        var at: Int { switch self { case .mail(let m): return m.m.at; case .reply(let r): return r.at } }
    }

    var body: some View {
        let _ = model.version
        let d = model.derive
        if let t = d.mailThread(group, of: threadId) {
            content(t, d)
        } else {
            ContentUnavailableView("This e-mail is gone", systemImage: "envelope")
        }
    }

    private func entries(_ t: InboxThread, _ d: Derive) -> [Entry] {
        let list = t.mails.map { Entry.mail($0) } + d.mailThreadReplies(group, t).map { Entry.reply($0) }
        return list.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    private func content(_ t: InboxThread, _ d: Derive) -> some View {
        let from = d.channelAddress(group)
        let canMail = d.canAdmin(group) && d.isInbox(d.group(group)) && t.lastIn != nil && !model.locked(group)
        let mail = mode == .mail && canMail
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    MailThreadHead(t: t, group: group, canAct: d.canAdmin(group) && !model.locked(group))
                    ForEach(entries(t, d)) { e in
                        switch e {
                        case .mail(let it): MailFrame(it: it, from: from).id(it.m.id)
                        case .reply(let r): ReplyRow(group: group, r: r) { actionsFor = r }.padding(.horizontal).id(r.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .initialScrollAnchorBottom()
            .feedScroll(feedPos, proxy)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in feedPos.settle { feedPos.toEnd() } }
            .onAppear {
                for id in t.ids { model.markThreadRead(group, id) }
                DispatchQueue.main.async { feedPos.toEnd() }
                if model.launch.screen == "mailreply" { mode = .mail }
            }
        }
        .bottomBar {
            if model.guestReading {
                GuestBar(group: group)
            } else if model.locked(group) {
                ArchivedFooter()
            } else {
                VStack(spacing: 6) {
                    sendLine(t, mail: mail, canMail: canMail, from: from)
                    Composer(group: group, placeholder: mail ? "E-mail to \(first(t))…" : "Reply in the thread", autoFocus: focusReply, threadMode: true,
                             draftKey: "t:\(group):\(t.id)") { text, _, _ in
                        if mail { startMail(t, text) } else if let root = t.root { model.reply(text, in: group, to: root) }
                    }
                    .id(composerKey)
                    .disabled(countdown > 0)
                }
                .padding(.top, 6)
                .background(mail ? Color.brand.opacity(0.10) : Color.clear)
            }
        }
        .navigationTitle(t.subject.isEmpty ? "E-mail" : t.subject)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $actionsFor) { m in MessageActions(m: m, group: group, onReply: {}, onOpenThread: {}, onEdit: {}) }
        .onDisappear {
            // leaving during the countdown sends at once: nobody should believe it went when it didn't
            if countdown > 0 { timer?.invalidate(); countdown = 0; let text = pendingText; Task { _ = await model.sendThreadMail(t, in: group, text: text) } }
        }
    }

    private func first(_ t: InboxThread) -> String {
        let n = t.lastIn?.name ?? t.name
        return n.isEmpty ? (t.lastIn?.address ?? t.address) : (n.components(separatedBy: " ").first ?? n)
    }

    @ViewBuilder private func sendLine(_ t: InboxThread, mail: Bool, canMail: Bool, from: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if countdown > 0 {
                HStack {
                    Label("Sending to \(first(t)) in \(countdown) s", systemImage: "paperplane")
                    Spacer()
                    Button("Undo") { undo() }.buttonStyle(.brand).controlSize(.small)
                }
            } else if let id = sentId, let r = model.dms?.report(id) {
                HStack {
                    Text(r.status == "delivered" ? "E-mail sent to \(first(t))" : r.status == "failed" ? "Not delivered: \(r.details)" : r.status == "delayed" ? "Delayed, the provider retries" : "Sending…")
                    Spacer()
                    if r.status != "queued" { Button("OK") { sentId = nil }.font(.caption.weight(.semibold)) }
                }
            } else if mail {
                HStack(alignment: .firstTextBaseline) {
                    Label("This will be sent to \(t.lastIn.map(who) ?? t.address) by e-mail", systemImage: "envelope.fill").fontWeight(.semibold)
                    Spacer(minLength: 4)
                }
                Text("From \(from) · \(subject(t))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Only send in this thread instead") { mode = .thread }.font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
            } else {
                HStack {
                    Text("Message will be sent in this thread")
                    Spacer(minLength: 4)
                    if canMail { Button("Reply by e-mail instead") { mode = .mail }.font(.caption.weight(.semibold)).foregroundStyle(Color.brand) }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
        }
        .font(.footnote)
        .padding(.horizontal)
        .accessibilityIdentifier("mail-send-line")
    }

    private func who(_ it: MailItem) -> String { it.name.isEmpty ? it.address : it.name }

    private func subject(_ t: InboxThread) -> String { AppModel.replySubject(t) }

    private func startMail(_ t: InboxThread, _ text: String) {
        error = nil
        pendingText = text
        countdown = 8
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { tm in
            Task { @MainActor in
                guard countdown > 0 else { tm.invalidate(); return }
                countdown -= 1
                if countdown == 0 {
                    tm.invalidate()
                    let r = await model.sendThreadMail(t, in: group, text: pendingText)
                    switch r {
                    case .success(let id): sentId = id; mode = .thread
                    case .failure(let e): error = e.message; restore()
                    }
                }
            }
        }
    }

    private func undo() {
        timer?.invalidate()
        countdown = 0
        restore()
    }

    /// The composer takes the text back (it was cleared on send).
    private func restore() {
        guard let t = model.derive.mailThread(group, of: threadId) else { return }
        Drafts.set("t:\(group):\(t.id)", pendingText)
        composerKey += 1
    }
}

/// Under the thread's title: who wrote, its state, who has it, Take / Close for the admins.
struct MailThreadHead: View {
    @EnvironmentObject var model: AppModel
    let t: InboxThread
    let group: String
    let canAct: Bool

    var body: some View {
        let s = t.state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "envelope").foregroundStyle(Color.brand)
                Text(t.name.isEmpty ? t.address : "\(t.name) <\(t.address)>").font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            if let li = t.lastIn, !li.verified {
                Label("unverified sender", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Chip(text: s.status.label, tint: s.status.tint)
                if canAct, let root = t.root {
                    BusyButton { model.assignCard(root, in: group, to: s.assignee == model.me ? "" : model.me) } label: {
                        Text(s.assignee.map { $0 == model.me ? "You have it" : "\(model.name($0)) has it" } ?? "Nobody yet · take it")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    BusyButton { model.setCard(root, in: group, closed: s.status != .closed) } label: { Text(s.status == .closed ? "Reopen" : "Close") }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Text(s.assignee.map { "\(model.name($0)) has it" } ?? "Nobody has it yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            Text("Team only: \(t.lastIn.map { $0.name.isEmpty ? $0.address : $0.name } ?? t.address) sees only what is sent by e-mail.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}

/// The whole e-mail (Blossom, AES-GCM): From, To, Date and the full text.
struct FullMailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ref: FullMailRef
    @State private var mail: ParsedMail?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if let mail {
                    Section {
                        LabeledContent("From", value: mail.from)
                        if let to = mail.headers["to"] { LabeledContent("To", value: to) }
                        if let date = mail.headers["date"] { LabeledContent("Date", value: date) }
                    }
                    Section { Text(mail.full).font(.callout).textSelection(.enabled) }
                    if !mail.attachments.isEmpty { Section { Text("\(mail.attachments.count) attachment(s), shown in the message.").font(.footnote).foregroundStyle(.secondary) } }
                } else if error == nil {
                    HStack(spacing: 10) { ProgressView(); Text("Opening…").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(ref.subject.isEmpty ? "E-mail" : ref.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        if model.isDemo {
            mail = MIME.parse("From: Ana X <a@x.org>\r\nTo: hello@demo.belfry.sh\r\nSubject: \(ref.subject)\r\nDate: Mon, 16 Nov 2026 09:12:00 +0100\r\n\r\nThe whole e-mail, as it came, quoted history included.\r\n\r\n> On Sunday someone wrote:\r\n> an earlier message")
            return
        }
        guard let u = URL(string: ref.original.url), ref.original.url.hasPrefix("https://"),
              let key = Data(base64Encoded: ref.original.key), let nonce = Data(base64Encoded: ref.original.nonce) else {
            error = "The e-mail could not be opened."
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: u)
            let plain = try Crypto.aesGCMOpen(key: key, nonce: nonce, sealed: data)
            mail = MIME.parse(String(decoding: plain, as: UTF8.self))
        } catch {
            self.error = "The e-mail could not be opened."
        }
    }
}
