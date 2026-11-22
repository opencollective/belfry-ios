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
                MediaBlock(media: it.m.media)
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
                    Text(Format.time(r.ev.createdAt)).font(.caption).foregroundStyle(.secondary)
                    if r.edited != nil { Text("edited").font(.caption2).foregroundStyle(.secondary) }
                    if let p = model.pending(r.id) {
                        if p.status == .failed { Text(p.stateText).font(.caption2).foregroundStyle(.red) }
                        else { SendLineView(id: p.localId, tries: p.tries, font: .caption2, icon: false) }
                    }
                    Spacer(minLength: 0)
                }
                if !r.text.isEmpty { MarkdownText(text: r.text) }
                MessageButtonsView(m: r, group: group)
                MediaBlock(media: r.media)
            }
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mail-entry-team")
        .messageMenu(r, group: group, handlers: menu, guest: model.guestReading || model.locked(group), hold: onHold)
    }
}

/// An e-mail thread's own screen, in one shape (boards one-shape/email-thread-folded, email-thread,
/// email-thread-open, email-compose, email-draft, email-sent; 2026-11-22). The header is two lines:
/// the subject, then "✉ From Lou · Open · 👤 Ana · 👥 3 · 📁 1" (the owner leaves first on a narrow
/// phone). Pulled down (the default while it is open, tap the header to fold or unfold): the
/// e-mails on top (From / To / Cc folded in one line, a Cc line on each card, the round reply-all
/// icon), then Claim / Take it, Mark answered, Close. Under it, always: the team's conversation
/// with the e-mails as preview lines, who took it, Marked answered, internal drafts (dashed cards).
/// The composer is for the team only ("Comment for the team"); Reply all is the only e-mail reply,
/// a full compose sheet; it leaves after an 8 s Undo; Answered is set by itself once delivered.
struct MailThreadView: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let threadId: String
    var focusReply = false
    @State private var feedPos = FeedPosition()
    /// nil until the header is tapped: pulled while the thread is open (it needs someone)
    @State private var pulledChoice: Bool?
    @State private var fields = false
    @State private var expanded = Set<String>()
    @State private var composing: MailCompose?
    @State private var countdown = 0
    @State private var timer: Timer?
    @State private var pending: MailCompose.Out?
    @State private var sentId: String?
    @State private var error: String?
    @State private var actionsFor: Message?

    enum Entry: Identifiable {
        case mail(MailItem)
        case reply(Message)
        case draft(Message)
        case activity(MailActivity)
        var id: String {
            switch self {
            case .mail(let m): return m.m.id
            case .reply(let r), .draft(let r): return r.id
            case .activity(let a): return a.id
            }
        }
        var at: Int {
            switch self {
            case .mail(let m): return m.m.at
            case .reply(let r), .draft(let r): return r.at
            case .activity(let a): return a.at
            }
        }
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
        var list = t.mails.map { Entry.mail($0) } + d.mailThreadReplies(group, t).map { Entry.reply($0) }
        list += d.mailDrafts(group, t).map { Entry.draft($0) }
        list += d.mailActivity(group, t).map { Entry.activity($0) }
        return list.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    /// Who may answer by e-mail: the channel's admins, while it takes e-mail from anyone, when
    /// there is an e-mail to answer.
    private func canMail(_ t: InboxThread, _ d: Derive) -> Bool {
        d.canAdmin(group) && d.isInbox(d.group(group)) && t.lastIn != nil && !model.locked(group)
    }

    private func pulled(_ t: InboxThread) -> Bool { pulledChoice ?? (t.state.status == .open && model.launch.screen != "mailcomment") }

    private func content(_ t: InboxThread, _ d: Derive) -> some View {
        let may = canMail(t, d)
        let act = d.canAdmin(group) && !model.locked(group)
        let isPulled = pulled(t)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if isPulled { pulledPart(t, d, may: may, act: act) }
                    ForEach(entries(t, d)) { e in row(e, t, may: may).id(e.id) }
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
                if model.launch.screen == "mailreply", may {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { composing = MailCompose(thread: t.id, draft: nil) }
                }
            }
        }
        .bottomBar {
            if model.guestReading {
                GuestBar(group: group)
            } else if model.locked(group) {
                ArchivedFooter()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sendLine(t)
                    Composer(group: group, placeholder: "Comment for the team", autoFocus: focusReply, threadMode: true,
                             draftKey: "t:\(group):\(t.id)") { text, _, _ in
                        if let root = t.root { model.reply(text, in: group, to: root) }
                    }
                }
                .padding(.top, 4)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                OneHeader(title: t.subject.isEmpty ? "E-mail" : t.subject, items: headerItems(t, d), open: isPulled) {
                    withAnimation(.snappy(duration: 0.25)) { pulledChoice = !isPulled }
                }
                .accessibilityIdentifier("mail-header")
            }
        }
        .sheet(item: $actionsFor) { m in MessageActions(m: m, group: group, onReply: {}, onOpenThread: {}, onEdit: {}) }
        .sheet(item: $composing) { c in
            ReplyAllSheet(group: group, threadId: c.thread, draft: c.draft) { out in
                composing = nil
                startSend(t, out)
            }
        }
        .onDisappear {
            // leaving during the countdown sends at once: nobody should believe it went when it didn't
            if countdown > 0, let out = pending {
                timer?.invalidate(); countdown = 0
                Task { _ = await model.replyAllSend(t, in: group, text: out.text, subject: out.subject, draft: out.draft) }
            }
        }
    }

    // MARK: the header row

    private func headerItems(_ t: InboxThread, _ d: Derive) -> [HeaderItem] {
        let s = t.state
        var items = [HeaderItem(key: "lead", icon: "envelope", text: "From \(firstName(t))", label: "From \(fullName(t))", accent: true)]
        items.append(HeaderItem(key: "state", icon: nil, text: s.status.label, label: s.status.label, chip: true, tint: s.status.tint))
        if let a = s.assignee {
            let n = model.name(a)
            items.append(HeaderItem(key: "owner", icon: "person", text: a == model.me ? "You" : (n.components(separatedBy: " ").first ?? n),
                                    label: a == model.me ? "You have it" : "\(n) has it"))
        }
        var people = Set(t.who)
        people.insert(t.address)
        if let p = HeaderItem.count("people", "person.2", people.count, "person", "people") { items.append(p) }
        let files = t.mails.reduce(0) { $0 + $1.m.media.count } + d.mailThreadReplies(group, t).reduce(0) { $0 + $1.media.count }
        if let f = HeaderItem.count("files", "paperclip", files, "file", "files") { items.append(f) }
        return items
    }

    private func fullName(_ t: InboxThread) -> String {
        let n = t.lastIn?.name ?? t.name
        return n.isEmpty ? (t.lastIn?.address ?? t.address) : n
    }

    private func firstName(_ t: InboxThread) -> String {
        let n = t.lastIn?.name ?? t.name
        return n.isEmpty ? (t.lastIn?.address ?? t.address) : (n.components(separatedBy: " ").first ?? n)
    }

    // MARK: pulled down: the e-mails, then what can be done

    @ViewBuilder private func pulledPart(_ t: InboxThread, _ d: Derive, may: Bool, act: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldsLine(t, d)
            Text(t.mails.count == 1 ? "The e-mail" : "The e-mails · \(t.mails.count)")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(t.mails, id: \.m.id) { it in
                MailCard(it: it, alias: d.mailLocal(group), canReply: may && it.dir == .incoming && it.m.id == t.lastIn?.m.id) {
                    composing = MailCompose(thread: t.id, draft: nil)
                }
            }
            if act, let root = t.root { actions(t, root) }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .accessibilityIdentifier("mail-pulled")
        Divider().padding(.horizontal)
    }

    /// "From Lou · To hello@ · Cc 2", opening on tap into the three fields.
    @ViewBuilder private func fieldsLine(_ t: InboxThread, _ d: Derive) -> some View {
        let li = t.lastIn
        let to = li?.toList ?? []
        let cc = li?.ccList ?? []
        let from = fullName(t)
        Button { withAnimation(.snappy(duration: 0.2)) { fields.toggle() } } label: {
            if fields {
                VStack(alignment: .leading, spacing: 4) {
                    fieldRow("From", li.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" } ?? t.address)
                    fieldRow("To", to.isEmpty ? d.channelAddress(group) : to.map(party).joined(separator: ", "))
                    if !cc.isEmpty { fieldRow("Cc", cc.map(party).joined(separator: ", ")) }
                    Text("Hide").font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                }
            } else {
                HStack(spacing: 4) {
                    Text(foldedFields(from: from, to: to, cc: cc, d)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .font(.footnote)
        .accessibilityIdentifier("mail-fields")
    }

    private func foldedFields(from: String, to: [MailParty], cc: [MailParty], _ d: Derive) -> String {
        let local = d.mailLocal(group) + "@"
        var parts = ["From \(from)", "To \(to.first.map { $0.address.hasSuffix("@" + model.config.domain) ? $0.address.components(separatedBy: "@")[0] + "@" : $0.shown } ?? local)"]
        if !cc.isEmpty { parts.append("Cc \(cc.count)") }
        return parts.joined(separator: " · ")
    }

    private func party(_ p: MailParty) -> String { p.name.isEmpty ? p.address : "\(p.name) <\(p.address)>" }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(value).foregroundStyle(.primary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Claim (nobody has it) / Take it (someone else) / Mark answered / Close or Reopen.
    private func actions(_ t: InboxThread, _ root: Message) -> some View {
        let s = t.state
        return VStack(alignment: .leading, spacing: 8) {
            if s.assignee == nil {
                BusyButton { model.assignCard(root, in: group, to: model.me) } label: { Label("Claim", systemImage: "hand.raised") }
                    .buttonStyle(.brand).accessibilityIdentifier("mail-claim")
            } else if s.assignee != model.me {
                BusyButton { model.assignCard(root, in: group, to: model.me) } label: { Label("Take it", systemImage: "hand.raised") }
                    .buttonStyle(.bordered).accessibilityIdentifier("mail-take")
            }
            HStack(spacing: 8) {
                if s.status != .waiting {
                    BusyButton { model.markAnswered(t, in: group) } label: { Label("Mark answered", systemImage: "checkmark.circle") }
                        .accessibilityIdentifier("mail-answered")
                }
                BusyButton { model.setCard(root, in: group, closed: s.status != .closed) } label: {
                    Label(s.status == .closed ? "Reopen" : "Close", systemImage: s.status == .closed ? "arrow.uturn.backward" : "xmark.circle")
                }
                .accessibilityIdentifier("mail-close")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .font(.subheadline.weight(.semibold))
    }

    // MARK: the conversation

    @ViewBuilder private func row(_ e: Entry, _ t: InboxThread, may: Bool) -> some View {
        switch e {
        case .mail(let it):
            MailPreviewLine(it: it, alias: model.derive.mailLocal(group), open: expanded.contains(it.m.id),
                            canReply: may && it.dir == .incoming && it.m.id == t.lastIn?.m.id,
                            toggle: { withAnimation(.snappy(duration: 0.2)) { if expanded.contains(it.m.id) { expanded.remove(it.m.id) } else { expanded.insert(it.m.id) } } },
                            reply: { composing = MailCompose(thread: t.id, draft: nil) })
        case .reply(let r):
            MailTeamRow(group: group, r: r) { actionsFor = r }
        case .draft(let m):
            MailDraftCard(m: m, subject: AppModel.replySubject(t), mine: m.ev.pubkey == model.me && may) {
                composing = MailCompose(thread: t.id, draft: m.id)
            } delete: {
                model.delete(m, in: group)
            }
        case .activity(let a):
            if let text = activityText(a) { MailQuietLine(icon: activityIcon(a), text: text, at: a.at) }
        }
    }

    private func activityText(_ a: MailActivity) -> String? {
        let by = model.realNameOrKey(a.by)
        switch a.value {
        case "assigned":
            guard let p = a.assignee else { return "\(by) let it go" }
            return p == a.by ? "\(by) took it" : "\(by) gave it to \(model.realNameOrKey(p))"
        case "answered": return "Marked answered"
        case "closed": return "\(by) closed it"
        case "open": return "\(by) reopened it"
        default: return nil
        }
    }

    private func activityIcon(_ a: MailActivity) -> String {
        switch a.value {
        case "assigned": return "person"
        case "answered": return "checkmark.circle"
        case "closed": return "xmark.circle"
        default: return "arrow.uturn.backward"
        }
    }

    // MARK: sending: the 8 s Undo, then the report

    @ViewBuilder private func sendLine(_ t: InboxThread) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if countdown > 0, let out = pending {
                HStack {
                    Label("Sending to \(MailCompose.who(out.names))…", systemImage: "paperplane").lineLimit(1)
                    Spacer()
                    Button("Undo · \(countdown)") { undo() }.buttonStyle(.brand).controlSize(.small).monospacedDigit()
                        .accessibilityIdentifier("mail-undo")
                }
            } else if let id = sentId, let r = model.dms?.report(id) {
                HStack {
                    Text(r.status == "delivered" ? "E-mail delivered" : r.status == "failed" ? "Not delivered: \(r.details)" : r.status == "delayed" ? "Delayed, the provider retries" : "Sending…")
                    Spacer()
                    if r.status != "queued" { Button("OK") { sentId = nil }.font(.caption.weight(.semibold)) }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, (countdown > 0 || sentId != nil || error != nil) ? 6 : 0)
        .accessibilityIdentifier("mail-send-line")
    }

    private func startSend(_ t: InboxThread, _ out: MailCompose.Out) {
        error = nil
        pending = out
        countdown = 8
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { tm in
            Task { @MainActor in
                guard countdown > 0 else { tm.invalidate(); return }
                countdown -= 1
                if countdown == 0 {
                    tm.invalidate()
                    let r = await model.replyAllSend(t, in: group, text: out.text, subject: out.subject, draft: out.draft)
                    switch r {
                    case .success(let id): sentId = id.isEmpty ? nil : id; pending = nil
                    case .failure(let e): error = e.message; restore(out)
                    }
                }
            }
        }
    }

    private func undo() {
        timer?.invalidate()
        countdown = 0
        if let out = pending { restore(out) }
    }

    /// Undo or a failure: the compose sheet comes back with the text.
    private func restore(_ out: MailCompose.Out) {
        Drafts.set(MailCompose.key(group, threadId), out.text)
        pending = nil
        composing = MailCompose(thread: threadId, draft: out.draft)
    }
}

/// The compose sheet's subject (a thread, maybe an internal draft to continue).
struct MailCompose: Identifiable, Hashable {
    let thread: String
    let draft: String?
    var id: String { thread + (draft ?? "") }

    struct Out: Hashable {
        let text: String
        let subject: String
        let draft: String?
        let names: [String]
    }

    static func key(_ group: String, _ thread: String) -> String { "mail:\(group):\(thread)" }

    /// "Lou", "Lou and Dev", "Lou and 2 more".
    static func who(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        if names.count == 2 { return "\(first) and \(names[1])" }
        return "\(first) and \(names.count - 1) more"
    }

    /// "Lou, Dev Patel and 1 more" (the sent card).
    static func list(_ names: [String]) -> String {
        if names.count <= 2 { return who(names) }
        return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }
}

/// One e-mail as a card: who and when, the Cc line (only when there is one), the subject, the text,
/// the round reply-all icon top right (the latest received e-mail, for those who may answer).
struct MailCard: View {
    @EnvironmentObject var model: AppModel
    let it: MailItem
    let alias: String
    let canReply: Bool
    let reply: () -> Void

    var body: some View {
        let out = it.dir == .outgoing
        let text = it.m.body.isEmpty ? it.m.text : it.m.body
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: out ? "paperplane" : "envelope").imageScale(.small).foregroundStyle(out ? MailTint.mailText : .secondary)
                Text(headline).font(.footnote.weight(.semibold)).foregroundStyle(out ? MailTint.mailText : .secondary)
                Spacer(minLength: 4)
                if canReply {
                    Button(action: reply) {
                        Image(systemName: "arrowshape.turn.up.left.2").font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reply all")
                    .accessibilityIdentifier("mail-reply-all")
                }
            }
            if !it.ccList.isEmpty {
                Text("Cc " + it.ccList.map(\.shown).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !it.subject.isEmpty { Text(it.subject).font(.subheadline.weight(.semibold)) }
            if it.dir == .incoming && !it.verified {
                Label("unverified sender", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
            if !text.isEmpty { MarkdownText(text: text) } else { Text("(empty)").foregroundStyle(.secondary) }
            MediaBlock(media: it.m.media)
            if let o = it.original {
                Button { model.fullMail = FullMailRef(subject: it.subject, original: o) } label: {
                    Text("Show the whole e-mail").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brand)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(out ? MailTint.mail.opacity(0.10) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if !text.isEmpty { Button { UIPasteboard.general.string = text } label: { Label("Copy text", systemImage: "doc.on.doc") } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(out ? "mail-card-out" : "mail-card-in")
    }

    private var headline: String {
        if it.dir == .outgoing {
            var names = [it.address]
            names += it.ccList.map(\.shown)
            let to = it.toList.map(\.shown)
            if !to.isEmpty { names = to + it.ccList.map(\.shown) }
            return "Sent by e-mail to " + MailCompose.list(names)
        }
        let n = it.name.isEmpty ? it.address : (it.name.components(separatedBy: " ").first ?? it.name)
        return "E-mail from \(n) · \(Format.time(it.m.at))"
    }
}

/// An e-mail in the conversation, folded to one line ("Lou e-mailed: Park cleaning · 9:14 ⌄"; an
/// answer: "Ana replied all"), its card under it when opened.
struct MailPreviewLine: View {
    @EnvironmentObject var model: AppModel
    let it: MailItem
    let alias: String
    let open: Bool
    let canReply: Bool
    let toggle: () -> Void
    let reply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: it.dir == .outgoing ? "paperplane" : "envelope").imageScale(.small)
                        .foregroundStyle(it.dir == .outgoing ? MailTint.mailText : .secondary)
                    (Text(who).fontWeight(.semibold) + Text(verb) + Text(it.dir == .incoming ? it.subject : ""))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.time(it.m.at)).foregroundStyle(.secondary)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.footnote)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(who)\(verb)\(it.dir == .incoming ? it.subject : ""). \(open ? "Fold" : "Show")")
            if open { MailCard(it: it, alias: alias, canReply: canReply, reply: reply) }
        }
        .padding(.horizontal)
        .accessibilityIdentifier(it.dir == .outgoing ? "mail-line-out" : "mail-line-in")
    }

    private var who: String {
        if it.dir == .outgoing { return it.by.map { model.realNameOrKey($0).components(separatedBy: " ").first ?? "" } ?? alias + "@" }
        return it.name.isEmpty ? it.address : (it.name.components(separatedBy: " ").first ?? it.name)
    }

    private var verb: String { it.dir == .outgoing ? " replied all" : " e-mailed: " }
}

/// An internal draft in the conversation: a dashed card only the team sees; its author taps it to
/// continue in the compose sheet.
struct MailDraftCard: View {
    let m: Message
    let subject: String
    let mine: Bool
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        Button { if mine { open() } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label("Internal draft", systemImage: "lock").font(.caption.weight(.semibold)).foregroundStyle(MailTint.teamText)
                Text(subject).font(.subheadline.weight(.semibold))
                Text(m.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if mine { Text("Tap to continue").font(.caption.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if mine { Button(role: .destructive, action: delete) { Label("Delete draft", systemImage: "trash") } }
        }
        .padding(.horizontal)
        .accessibilityIdentifier("mail-draft")
    }
}

/// A quiet activity line: "Ana Silva took it · 9:20".
struct MailQuietLine: View {
    let icon: String
    let text: String
    let at: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).imageScale(.small)
            Text(text).lineLimit(1)
            Text(Format.time(at))
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

/// Reply all, the only e-mail reply: From fixed (the channel's address), To = the sender, Cc / Bcc
/// folded (prefilled with the original's Cc), "Re: …", the text, the quoted e-mail folded, Save
/// draft (an internal draft only the team sees) and Send (locks; the thread then counts 8 s).
struct ReplyAllSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let group: String
    let threadId: String
    let draft: String?
    let send: (MailCompose.Out) -> Void
    @State private var text = ""
    @State private var subject = ""
    @State private var quoted = false
    @State private var loaded = false
    @FocusState private var focus: Bool

    var body: some View {
        let d = model.derive
        NavigationStack {
            if let t = d.mailThread(group, of: threadId) {
                form(t, d)
            } else {
                ContentUnavailableView("This e-mail is gone", systemImage: "envelope")
            }
        }
    }

    private func names(_ t: InboxThread) -> [String] {
        let r = t.replyAll(domain: model.config.domain)
        let li = t.lastIn
        let known = (li?.toList ?? []) + (li?.ccList ?? [])
        return r.rcptTo.map { a in
            if a == li?.address { return (li?.name.isEmpty ?? true) ? a : li!.name }
            return known.first { $0.address == a }.map(\.shown) ?? a
        }
    }

    private func form(_ t: InboxThread, _ d: Derive) -> some View {
        let all = names(t)
        let draftMsg = draft.flatMap { id in d.mailDrafts(group, t).first { $0.id == id } }
        return Form {
            Section {
                LabeledContent("From") {
                    HStack(spacing: 4) { Text(d.channelAddress(group)); Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(.secondary) }
                }
                .accessibilityLabel("From \(d.channelAddress(group)), fixed")
                LabeledContent("To", value: all.first ?? "")
                LabeledContent("Cc/Bcc", value: all.count > 1 ? all.dropFirst().joined(separator: ", ") : "")
                TextField("Subject", text: $subject).font(.body)
            }
            Section {
                TextField("Write your e-mail", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(6...20)
                    .focused($focus)
                    .accessibilityIdentifier("mail-compose-text")
                if let li = t.lastIn {
                    DisclosureGroup(isExpanded: $quoted) {
                        Text(li.m.body.isEmpty ? li.m.text : li.m.body).font(.footnote).foregroundStyle(.secondary)
                    } label: {
                        Text("··· \(li.name.isEmpty ? li.address : (li.name.components(separatedBy: " ").first ?? li.name))’s e-mail").font(.footnote)
                    }
                }
            }
            Section {
                BusyButton {
                    model.saveMailDraft(t, in: group, text: text, editing: draftMsg)
                    Drafts.set(MailCompose.key(group, threadId), "")
                    dismiss()
                } label: { Label("Save draft", systemImage: "square.and.arrow.down") }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("mail-save-draft")
            } footer: {
                Text("A draft is internal: only the members of \(d.label(group)) see it.")
            }
        }
        .navigationTitle("Reply all")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { Drafts.set(MailCompose.key(group, threadId), text); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                BusyButton {
                    Drafts.set(MailCompose.key(group, threadId), "")
                    send(.init(text: text, subject: subject, draft: draft, names: all))
                } label: { Label("Send", systemImage: "paperplane.fill") }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || all.isEmpty)
                .accessibilityIdentifier("mail-send")
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            subject = AppModel.replySubject(t)
            let kept = Drafts.get(MailCompose.key(group, threadId)) ?? ""
            text = !kept.isEmpty ? kept : (draftMsg?.text ?? (model.launch.screen == "mailreply" ? "Hi \(firstName(t)), yes! We can lend you 12 rakes and a box of gloves. Pick them up Friday after 6 PM at the hall." : ""))
            if model.launch.screen != "mailreply" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus = true } }
        }
    }

    private func firstName(_ t: InboxThread) -> String {
        let n = t.lastIn?.name ?? t.name
        return n.isEmpty ? (t.lastIn?.address ?? t.address) : (n.components(separatedBy: " ").first ?? n)
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
