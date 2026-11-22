import Foundation

// E-mail threads in a channel (SPEC 19.33; web src/core/mailthreads.ts, collective-belfry
// docs/mail.md, Xavier 2026-11-16: "don't pollute the channel"). Nothing new on the wire: the
// bridge posts each e-mail from outside as a kind 9 by the groups key (`client belfry-mail`,
// `mail-from`, `message-id`, `in-reply-to`, `references`) and what went out as a kind 9
// `client belfry-mail-out` with `e` = the e-mail it answers. Each device joins them:
// - an e-mail naming (In-Reply-To / References, newest first) one already in a thread joins it;
// - else the same sender with the same subject (Re:, Fwd: … aside) joins theirs;
// - else it starts one and is its root (the id of its route, labels and NIP-22 replies);
// - what went out joins the thread of the e-mail it answers.
// The channel's feed shows one row per thread, where its latest activity is.

public struct MailItem: Hashable, Sendable {
    public enum Dir: String, Sendable { case incoming = "in", outgoing = "out" }
    public let m: Message
    public let dir: Dir
    /// in: the sender's address; out: the address it went to
    public let address: String
    /// in: the sender's name as their mail gave it
    public let name: String
    public let subject: String
    public let messageId: String?
    /// in: DKIM or SPF aligned with the From domain
    public let verified: Bool
    /// out: the member who sent it
    public let by: String?
    /// the whole e-mail on Blossom (in only)
    public let original: MailOriginal?
}

public struct InboxThread: Hashable, Sendable, Identifiable {
    /// the first e-mail's event id: the thread's id everywhere (route, labels, replies)
    public let id: String
    public var mails: [MailItem] = []
    public var ids: [String] = []
    public var address: String
    public var name: String
    public var subject: String
    /// the latest e-mail received (what a reply answers)
    public var lastIn: MailItem?
    /// latest activity: an e-mail either way or a team reply
    public var last = 0
    public var replies = 0
    public var who: [String] = []
    public var state = CardState()
    /// every Message-ID in it, oldest first (References of an answer)
    public var refs: [String] = []

    public var root: Message? { mails.first?.m }
    public var latest: MailItem? { mails.last }
}

extension Derive {
    /// An e-mail from outside, when the groups key posted it.
    public func mailIn(_ m: Message) -> MailItem? {
        let e = m.ev
        guard let key = ctx.groupsKey, e.pubkey == key, let from = e.tag("mail-from"), !from.isEmpty, e.hasTag("client", "belfry-mail") else { return nil }
        var original: MailOriginal?
        if let o = e.tags.first(where: { $0.count >= 4 && $0[0] == "mail-original" && $0[1].hasPrefix("https://") && !$0[2].isEmpty && !$0[3].isEmpty }) {
            original = MailOriginal(url: o[1], key: o[2], nonce: o[3])
        }
        let mid = e.tag("message-id").flatMap { $0.isEmpty ? nil : $0 }
        return MailItem(m: m, dir: .incoming, address: from.lowercased(), name: e.tag("mail-name") ?? "", subject: e.tag("subject") ?? "",
                        messageId: mid, verified: e.tag("belfry-auth") == "pass", by: nil, original: original)
    }

    /// What went out as the channel (only the bridge posts these, with the groups key).
    public func mailOut(_ m: Message) -> MailItem? {
        let e = m.ev
        guard let key = ctx.groupsKey, e.pubkey == key, e.hasTag("client", "belfry-mail-out") else { return nil }
        let mid = e.tag("message-id").flatMap { $0.isEmpty ? nil : $0 }
        let by = e.tag("sent-by").flatMap { $0.isEmpty ? nil : $0 }
        return MailItem(m: m, dir: .outgoing, address: e.tag("mail-to") ?? "", name: "", subject: e.tag("subject") ?? "",
                        messageId: mid, verified: true, by: by, original: nil)
    }

    static func mailSubjectKey(_ address: String, _ s: String) -> String {
        address.lowercased() + "|" + MailThreads.spaces.replace(MailThreads.baseSubject(s).lowercased(), with: " ")
    }

    /// GROUP's e-mail threads, oldest first, and which thread (index) each e-mail is in.
    public func mailThreads(_ groupId: String) -> (list: [InboxThread], of: [String: Int]) {
        if let c = mailThreadsCache[groupId] { return c }
        var list = [InboxThread]()
        var of = [String: Int]()
        guard ctx.groupsKey != nil else { mailThreadsCache[groupId] = (list, of); return (list, of) }
        var byMsgId = [String: Int]()
        var bySubject = [String: Int]()
        for m in messages(groupId) { // oldest first
            guard let it = mailIn(m) ?? mailOut(m) else { continue }
            var t: Int?
            if it.dir == .incoming {
                let refs = MailThreads.ids(m.ev.tag("references")) + MailThreads.ids(m.ev.tag("in-reply-to"))
                for r in refs.reversed() { if let x = byMsgId[r] { t = x; break } }
                if t == nil { t = bySubject[Derive.mailSubjectKey(it.address, it.subject)] }
            } else if let answered = m.ev.tag("e") {
                t = of[answered]
            }
            let i: Int
            if let t { i = t } else {
                let base = MailThreads.baseSubject(it.subject)
                list.append(InboxThread(id: m.id, address: it.address, name: it.name, subject: base.isEmpty ? it.subject : base))
                i = list.count - 1
            }
            list[i].mails.append(it)
            list[i].ids.append(m.id)
            of[m.id] = i
            if let mid = it.messageId {
                byMsgId[mid] = i
                if !list[i].refs.contains(mid) { list[i].refs.append(mid) }
            }
            if it.dir == .incoming {
                list[i].lastIn = it
                bySubject[Derive.mailSubjectKey(it.address, it.subject)] = i
                if list[i].name.isEmpty && !it.name.isEmpty { list[i].name = it.name }
            }
            list[i].last = max(list[i].last, m.at)
        }
        if !list.isEmpty {
            // the team's replies, under any of the thread's e-mails
            let th = threadsOf(groupId)
            for i in list.indices {
                for id in list[i].ids {
                    guard let r = th[id] else { continue }
                    list[i].replies += r.count
                    list[i].last = max(list[i].last, r.last)
                    for w in r.who where !list[i].who.contains(w) { list[i].who.append(w) }
                }
            }
            // state: Open → Answered once something went out → Open again when they write back;
            // Closed and who has it are NIP-32 labels (belfry/inbox) on any of its e-mails, latest wins
            let labels = inGroupSorted(groupId).filter { e in
                e.kind == 1985 && !deleted().contains(e.id) && e.tags.contains { $0.count >= 2 && $0[0] == "L" && $0[1] == Derive.inboxNS }
            }
            for i in list.indices {
                // one shape (vectors/one-shape.json threadState): the newest open / answered /
                // closed label, open again when a newer e-mail came in; what went out counts as an
                // answered label (older apps label nothing). Who has it: the newest "assigned".
                let ids = Set(list[i].ids)
                var s = CardState()
                var marks = [MailThreadState.Label]()
                var owner: (at: Int, id: String, p: String?)?
                for l in labels where ids.contains(l.tag("e") ?? "") {
                    guard let v = l.tags.first(where: { $0.count >= 3 && $0[0] == "l" && $0[2] == Derive.inboxNS })?[1] else { continue }
                    if v == "assigned" {
                        if owner == nil || (l.createdAt, l.id) > (owner!.at, owner!.id) {
                            owner = (l.createdAt, l.id, l.tag("p").flatMap { $0.isEmpty ? nil : $0 })
                        }
                    } else {
                        marks.append(.init(id: l.id, at: l.createdAt, value: v))
                    }
                }
                var received = [Int]()
                for mail in list[i].mails {
                    if mail.dir == .outgoing {
                        s.answered += 1
                        marks.append(.init(id: mail.m.id, at: mail.m.at, value: "answered"))
                    } else {
                        received.append(mail.m.at)
                    }
                }
                switch MailThreadState.state(received: received, labels: marks) {
                case "answered": s.status = .waiting
                case "closed": s.status = .closed
                default: s.status = .open
                }
                s.assignee = owner?.p
                list[i].state = s
            }
        }
        mailThreadsCache[groupId] = (list, of)
        return (list, of)
    }

    /// The e-mail thread an event belongs to (an e-mail's id or the root's).
    public func mailThread(_ groupId: String, of id: String) -> InboxThread? {
        let t = mailThreads(groupId)
        return t.of[id].map { t.list[$0] }
    }

    /// The team's replies in a thread (NIP-22 under any of its e-mails), oldest first.
    public func mailThreadReplies(_ groupId: String, _ t: InboxThread) -> [Message] {
        t.ids.flatMap { threadReplies(groupId, $0) }.filter { !MailDrafts.isDraft($0.ev) }.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    // ---- the channel's address (web model.ts mailLocal) -------------------------------------------

    /// web slugify: lower case, accents folded, runs of anything else → "-", 40 at most.
    public static func slugify(_ s: String) -> String {
        let folded = s.lowercased().decomposedStringWithCompatibilityMapping
        var out = Rx("[\\u0300-\\u036f]").replace(folded, with: "")
        out = Rx("[^a-z0-9]+").replace(out, with: "-")
        out = Rx("^-+|-+$").replace(out, with: "")
        return String(out.prefix(40))
    }

    static let idSuffix = Rx("-[0-9a-z]{3,8}$")

    /// Did a belfry admin (or the relay's own key) make G? Not known (no 9007 here): yes.
    func madeByAdmin(_ g: Group) -> Bool {
        let make = inGroupSorted(g.id).first { $0.kind == 9007 }
        guard let make else { return true }
        let relayKey = events.first { $0.kind == 39000 && $0.tag("d") == g.id }?.pubkey
        return make.pubkey == relayKey || communityAdmins.contains(make.pubkey)
    }

    /// The left part of a channel's e-mail address: its plain alias (`hello` for `hello-79f0`) when
    /// a belfry admin made it and no other channel answers to it, else its id (mail.channel_by_slug).
    public func mailLocal(_ groupId: String) -> String {
        guard let g = group(groupId) else { return groupId }
        let plainId = Derive.idSuffix.replace(g.id, with: "")
        let want = Derive.slugify(g.rawName).isEmpty ? plainId : Derive.slugify(g.rawName)
        if want.isEmpty || want == g.id { return g.id }
        if !madeByAdmin(g) { return g.id }
        let answering = allGroups().filter { x in
            [Derive.idSuffix.replace(x.id, with: ""), Derive.slugify(x.rawName)].contains(want)
        }
        return answering.count == 1 ? want : g.id
    }

    /// `<local>@<domain>`: what answers go out from.
    public func channelAddress(_ groupId: String) -> String { mailLocal(groupId) + "@" + ctx.domain }
}
