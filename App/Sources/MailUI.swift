import BelfryCore
import SwiftUI
import UIKit

// E-mail threads in a channel (SPEC 19.33, web MailPost.tsx / Chat.tsx). Round 6 (the owner's
// mock-ups Mail-A / Mail-B, 2026-11-18: "It should look more like a regular message from a guest.
// Make it more clear the switch between commenting and responding. Default should be responding
// as the address of the channel"): one row per thread in the feed, shaped like a message; in the
// thread every e-mail and every team message is an ordinary message row with a small tag
// ("guest, by e-mail", "sent as hello@", "team only"); the composer has two segments,
// "Reply to <first name>" (the default, blue: an e-mail from the channel's address) and
// "Comment" (yellow: only the channel's members see it), with one line saying who sees it.
// 8 s to Undo an e-mail.

/// A pointer to a whole e-mail on Blossom ("Full e-mail").
struct FullMailRef: Identifiable, Hashable {
    let subject: String
    let original: MailOriginal
    var id: String { original.url }
}

extension CardStatus {
    var tint: Color { self == .open ? .orange : self == .waiting ? .green : .secondary }
}

/// The two modes' colours: an e-mail goes out (blue), a comment stays with the team (yellow).
enum MailTint {
    static let mail = Color(uiColor: .systemBlue)
    static let team = Color(uiColor: .systemYellow)
    /// Yellow text that reads on white too.
    static let teamText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemYellow : UIColor(red: 0.62, green: 0.45, blue: 0, alpha: 1) })
    static let mailText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.39, green: 0.71, blue: 1, alpha: 1) : .systemBlue })
}

/// Initials in a circle for someone known only by name and address (an outsider's e-mail): "MD".
struct NameAvatar: View {
    let name: String
    let seed: String
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .systemGray3))
            Text(NameAvatar.initials(name)).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Two letters from the first and last words ("Marie Dubois" → "MD"); one word → its first two.
    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let first = words.first else { return "?" }
        if words.count == 1 { return String(first.prefix(2)).capitalized }
        return (String(first.prefix(1)) + String(words.last!.prefix(1))).uppercased()
    }
}

/// The small tag after a name in an e-mail thread.
enum MailTag {
    case guest, sentAs(String), team
    var text: String {
        switch self {
        case .guest: return "guest, by e-mail"
        case .sentAs(let a): return "sent as \(a)@"
        case .team: return "team only"
        }
    }
    var icon: String {
        switch self {
        case .guest: return "envelope"
        case .sentAs: return "paperplane"
        case .team: return "lock"
        }
    }
    var color: Color {
        switch self {
        case .guest: return .secondary
        case .sentAs: return MailTint.mailText
        case .team: return MailTint.teamText
        }
    }
}

struct MailTagView: View {
    let tag: MailTag
    var body: some View {
        Label(tag.text, systemImage: tag.icon)
            .labelStyle(TightLabel())
            .font(.caption)
            .foregroundStyle(tag.color)
            .lineLimit(1)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.imageScale(.small); configuration.title }
    }
}

/// The feed's row for one e-mail thread, shaped like a message: the sender's initials, name,
/// "guest, by e-mail", time; the subject; a line of the latest e-mail; its state and counts. A tap
/// opens the thread.
struct MailThreadRow: View {
    @EnvironmentObject var model: AppModel
    let t: InboxThread
    let group: String
    let open: () -> Void

    var body: some View {
        let unread = model.readSync == nil ? 0 : t.ids.reduce(0) { $0 + model.derive.unreadInThread(group, $1, model.readState, now: Int.now) }
        let name = t.name.isEmpty ? t.address : t.name
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                NameAvatar(name: name, seed: t.address, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name).font(.body.weight(.semibold)).lineLimit(1)
                        MailTagView(tag: .guest)
                        Text(Format.short(t.last)).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if unread > 0 { CountBadge(n: unread) }
                    }
                    Text(t.subject.isEmpty ? "(no subject)" : t.subject).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let last = t.latest {
                        Text(snippet(last)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Chip(text: t.state.status.label, tint: t.state.status.tint)
                        if let a = t.state.assignee { Text(a == model.me ? "You have it" : "\(model.name(a)) has it").font(.caption2).foregroundStyle(.secondary) }
                        Text(counts).font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mail-thread-row")
    }

    private var counts: String {
        var parts = [t.mails.count == 1 ? "1 e-mail" : "\(t.mails.count) e-mails"]
        if t.replies > 0 { parts.append(t.replies == 1 ? "1 comment" : "\(t.replies) comments") }
        return parts.joined(separator: " · ")
    }

    private func snippet(_ it: MailItem) -> String {
        let s = model.derive.plainRefs(it.m.body.isEmpty ? it.m.text : it.m.body).replacingOccurrences(of: "\n", with: " ")
        return (it.dir == .outgoing ? "Answered: " : "") + (s.isEmpty ? "(empty)" : s)
    }
}

/// One e-mail in the thread as an ordinary message: an outsider's (initials, "guest, by e-mail")
/// or an answer that went out (the member who wrote it, "sent as <alias>@"). Holding it offers
/// "Full e-mail" (received ones) and Copy.
struct MailEntryRow: View {
    @EnvironmentObject var model: AppModel
    let it: MailItem
    let alias: String

    var body: some View {
        let out = it.dir == .outgoing
        let text = it.m.body.isEmpty ? it.m.text : it.m.body
        HStack(alignment: .top, spacing: 10) {
            if out, let by = it.by { Avatar(pubkey: by, size: 36) } else { NameAvatar(name: who, seed: it.address, size: 36) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(who).font(.body.weight(.semibold)).lineLimit(1)
                    MailTagView(tag: out ? .sentAs(alias) : .guest)
                    Text(Format.time(it.m.at)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if it.dir == .incoming && !it.verified {
                    Label("unverified sender", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                }
                if !text.isEmpty { MarkdownText(text: text) } else { Text("(empty)").foregroundStyle(.secondary) }
                ForEach(it.m.media, id: \.url) { media in MediaView(media: media, all: it.m.media) }
            }
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
        .contextMenu {
            if let o = it.original {
                Button { model.fullMail = FullMailRef(subject: it.subject, original: o) } label: { Label("Full e-mail", systemImage: "envelope.open") }
            }
            if !text.isEmpty {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(out ? "mail-entry-out" : "mail-entry-in")
    }

    private var who: String {
        if it.dir == .outgoing { return it.by.map { model.name($0) } ?? alias + "@" }
        return it.name.isEmpty ? it.address : it.name
    }
}

/// A team message in an e-mail thread (a NIP-22 reply): the member's message, "team only".
struct MailTeamRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.messageMenu) private var menu
    let group: String
    let r: Message
    let onHold: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(pubkey: r.ev.pubkey, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.name(r.ev.pubkey)).font(.body.weight(.semibold)).lineLimit(1)
                    MailTagView(tag: .team)
                    Text(Format.time(r.ev.createdAt)).font(.caption).foregroundStyle(.secondary)
                    if r.edited != nil { Text("edited").font(.caption2).foregroundStyle(.secondary) }
                    if let p = model.pending(r.id) { Text(p.stateText).font(.caption2).foregroundStyle(p.status == .failed ? .red : .secondary) }
                    Spacer(minLength: 0)
                }
                if !r.text.isEmpty { MarkdownText(text: r.text) }
                MessageButtonsView(m: r, group: group)
                ForEach(r.media, id: \.url) { MediaView(media: $0, all: r.media) }
            }
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mail-entry-team")
        .messageMenu(r, group: group, handlers: menu, guest: model.guestReading || model.locked(group), hold: onHold)
    }
}

/// An e-mail thread's own screen.
struct MailThreadView: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let threadId: String
    var focusReply = false
    @State private var feedPos = FeedPosition()
    /// nil until chosen: replying by e-mail when that is allowed (the owner's default), else Comment
    @State private var chosen: Mode?
    @State private var countdown = 0
    @State private var timer: Timer?
    @State private var pendingText = ""
    @State private var sentId: String?
    @State private var error: String?
    @State private var composerKey = 0
    @State private var actionsFor: Message?

    enum Mode { case comment, mail }
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

    /// Who may answer by e-mail: the channel's admins, while it takes e-mail from anyone, when
    /// there is an e-mail to answer.
    private func canMail(_ t: InboxThread, _ d: Derive) -> Bool {
        d.canAdmin(group) && d.isInbox(d.group(group)) && t.lastIn != nil && !model.locked(group)
    }

    private func content(_ t: InboxThread, _ d: Derive) -> some View {
        let alias = d.mailLocal(group)
        let from = d.channelAddress(group)
        let may = canMail(t, d)
        let mail = may && (chosen ?? .mail) == .mail
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    MailThreadHead(t: t, group: group, canAct: d.canAdmin(group) && !model.locked(group))
                    ForEach(entries(t, d)) { e in
                        switch e {
                        case .mail(let it): MailEntryRow(it: it, alias: alias).id(it.m.id)
                        case .reply(let r): MailTeamRow(group: group, r: r) { actionsFor = r }.id(r.id)
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
                if model.launch.screen == "mailcomment" { chosen = .comment }
            }
        }
        .bottomBar {
            if model.guestReading {
                GuestBar(group: group)
            } else if model.locked(group) {
                ArchivedFooter()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if may { modePicker(t, mail: mail) }
                    sendLine(t, mail: mail, from: from)
                    Composer(group: group, placeholder: mail ? "Write your e-mail to \(first(t))" : "Write a comment for the team", autoFocus: focusReply, threadMode: true,
                             draftKey: "t:\(group):\(t.id)", tint: mail ? MailTint.mail : MailTint.team, onTint: mail ? .white : .black) { text, _, _ in
                        if mail { startMail(t, text) } else if let root = t.root { model.reply(text, in: group, to: root) }
                    }
                    .id(composerKey)
                    .disabled(countdown > 0)
                }
                .padding(.top, 8)
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

    /// "Reply to Marie" | "Comment": two segments, the chosen one filled with its colour.
    private func modePicker(_ t: InboxThread, mail: Bool) -> some View {
        HStack(spacing: 0) {
            segment("Reply to \(first(t))", icon: "envelope", on: mail, fill: MailTint.mail, text: .white, id: "mail-mode-reply") { chosen = .mail }
            segment("Comment", icon: "lock", on: !mail, fill: MailTint.team, text: .black, id: "mail-mode-comment") { chosen = .comment }
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 12)
        .disabled(countdown > 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What you are writing")
    }

    private func segment(_ title: String, icon: String, on: Bool, fill: Color, text: Color, id: String, pick: @escaping () -> Void) -> some View {
        Button {
            guard !on else { return }
            withAnimation(.snappy(duration: 0.2)) { pick() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).imageScale(.small)
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? text : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(on ? fill : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func first(_ t: InboxThread) -> String {
        let n = t.lastIn?.name ?? t.name
        return n.isEmpty ? (t.lastIn?.address ?? t.address) : (n.components(separatedBy: " ").first ?? n)
    }

    private func channelLabel() -> String {
        guard let g = model.group(group) else { return "#" + group }
        return PlaceNames.defaults[g.id] == g.name ? g.name : (g.isPod ? g.name : "#" + g.name)
    }

    @ViewBuilder private func sendLine(_ t: InboxThread, mail: Bool, from: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if countdown > 0 {
                HStack {
                    Label("Sending to \(first(t)) in \(countdown) s", systemImage: "paperplane")
                    Spacer()
                    Button("Undo") { undo() }.buttonStyle(.brand).controlSize(.small).accessibilityIdentifier("mail-undo")
                }
            } else if let id = sentId, let r = model.dms?.report(id) {
                HStack {
                    Text(r.status == "delivered" ? "E-mail sent to \(first(t))" : r.status == "failed" ? "Not delivered: \(r.details)" : r.status == "delayed" ? "Delayed, the provider retries" : "Sending…")
                    Spacer()
                    if r.status != "queued" { Button("OK") { sentId = nil }.font(.caption.weight(.semibold)) }
                }
            } else if mail {
                (Text("An e-mail from ") + Text(from).bold().foregroundColor(.primary) + Text(" to " + (t.lastIn.map(who) ?? t.address)))
                    .lineLimit(2)
            } else {
                (Text("Only members of \(channelLabel()) see this. ") + Text("\(first(t)) does not.").bold().foregroundColor(.primary))
                    .lineLimit(2)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .accessibilityIdentifier("mail-send-line")
    }

    private func who(_ it: MailItem) -> String { it.name.isEmpty ? it.address : it.name }

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
                    case .success(let id): sentId = id
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
