import Foundation

// Direct messages and e-mail (SPEC 10): unwraps gift wraps as they arrive, keeps the decrypted
// messages on this device (Database kv), sends NIP-17 messages and Nostr Mail through the outbox,
// follows delivery reports. From src/core/dm.ts.

public struct DmThread: Hashable, Sendable, Identifiable {
    public let conv: String
    public let last: Dm
    public let unread: Int
    public let count: Int
    public var id: String { conv }
}

public final class DirectMessages: @unchecked Sendable {
    let engine: SyncEngine
    let db: Database
    private let lock = NSLock()
    private var items = [String: Dm]()
    private var seen = Set<String>()
    private var read = [String: Int]()
    private var reports = [String: DeliveryReport]()
    /// Reactions to direct messages (SPEC 19.50): never messages, never unread.
    private var reactions = DmReactions()
    private var busy = false
    public var myAddress: String?
    /// Sealed conversations (docs/sealed.md): set by the app for a member's session. From that
    /// moment every queued wrap is checked before it leaves (also the ones a restart found queued).
    public var sealed: SealedEngine? {
        didSet {
            guard let s = sealed else { return }
            engine.reseal = { [weak self] item in try await self?.reseal(item) }
            s.holdRumor = { [weak self] r in self?.hold(r) }
        }
    }
    /// Wraps kept because this device has no secret for their letterbox (the banner).
    public private(set) var lockedWraps = 0
    /// The rumors of sealed wraps still in the outbox (to seal them again if a head changes).
    private var queued = [String: NostrEvent]()
    /// Reactions that came with a shared history (their take-backs may remove only these).
    private var sharedReactions = Set<String>()
    /// The first pass over a store that holds no message yet (a new device reading its history):
    /// old-style messages from before a conversation sealed are history, not "not sealed".
    private var catchingUp = false
    public private(set) var bridge: String?
    public var onChange: (() -> Void)?

    public init(engine: SyncEngine) {
        self.engine = engine
        self.db = engine.db
        for d in db.get("dm-items", as: [Dm].self) ?? [] { items[d.rid] = d }
        seen = Set(db.get("dm-seen", as: [String].self) ?? [])
        read = db.get("dm-read", as: [String: Int].self) ?? [:]
        reports = db.get("dm-reports", as: [String: DeliveryReport].self) ?? [:]
        bridge = db.get("dm-bridge", as: String.self)
        reactions = db.get("dm-reactions", as: DmReactions.self) ?? DmReactions()
        for (rid, json) in db.get("dm-queued", as: [String: String].self) ?? [:] { if let r = NostrEvent.from(json: json) { queued[rid] = r } }
    }

    var me: String { engine.me }

    private func save() {
        lock.lock()
        let list = Array(items.values), s = Array(seen), rp = reports, rx = reactions
        lock.unlock()
        db.set("dm-reactions", rx)
        db.set("dm-items", list)
        db.set("dm-seen", s)
        db.set("dm-reports", rp)
        onChange?()
    }

    /// The mail bridge key (`_smtp@<domain>`), cached.
    public func loadBridge() async {
        if engine.localOnly { return }
        if let k = await Discovery.nip05(name: "_smtp", domain: engine.config.domain) {
            bridge = k
            db.set("dm-bridge", k)
        }
    }

    /// Demo mode: a stand-in bridge key.
    public func setBridge(_ k: String) { bridge = k }

    // ---- reading ----------------------------------------------------------------------------------

    /// Unwraps every gift wrap (and kind 4) not read yet, newest first.
    public func process() async {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }
        let todo = engine.snapshot().filter { e in
            engine.pending(e.id) == nil && !seen.contains(e.id) &&
                ((e.kind == 1059 && e.tags.contains { $0.first == "p" && $0.count > 1 && $0[1] == me }) || e.kind == 4)
        }.sorted { $0.createdAt > $1.createdAt }
        var changed = false
        var done = 0
        var locked = 0
        lock.lock(); catchingUp = items.isEmpty; lock.unlock()
        for e in todo {
            // a sealed wrap opens on this device, never through the signer; one that can't be
            // opened yet (no key here, its author's chain not loaded) is kept and tried again
            if e.kind == 1059, Sealed.lb(of: e) != nil {
                guard let s = sealed else { continue }
                // kept for an author whose chain did not accept it: opened again only when a chain changed
                if !s.worthTrying(e) { continue }
                switch s.open(e) {
                case .keep:
                    // the banner: only a wrap to a letterbox of my own chain that this device has no key for
                    if s.isLocked(e) { locked += 1 }
                    continue
                case .drop: break
                case .rumor(let rumor): take(rumor, sharedBy: nil)
                case .shared(let list, let by): for r in list { take(r, sharedBy: by) }
                }
                lock.lock(); seen.insert(e.id); lock.unlock()
                changed = true
                continue
            }
            do {
                var d: Dm?
                if e.kind == 1059 {
                    if let opened = try await GiftWrap.unwrap(e, signer: engine.signer) {
                        lock.lock()
                        // a reaction or its taking back: under the bubble, never a message. One that
                        // comes the old way into a conversation already sealed here is ignored.
                        if opened.rumor.kind == 7 || opened.rumor.kind == 5 {
                            // the conversation is the one of the message it points at, as this
                            // device holds it (not what the rumor says about itself)
                            let target = opened.rumor.tagValues("e").last.flatMap { items[$0]?.conv }
                            let conv = target ?? MailThreads.nostrConv(author: opened.rumor.pubkey, pTags: opened.rumor.tagValues("p"), me: me)
                            if sealed?.sealedSince(conv) == nil || catchingUp { reactions.apply(opened.rumor) }
                        }
                        let known = items.values.map { (messageId: $0.messageId, conv: $0.conv) }
                        lock.unlock()
                        d = DmReader.dm(from: opened.rumor, me: me, bridge: bridge, known: known)
                        // the old way, in a conversation already sealed here: marked "not sealed"
                        // (a conversation sealed on this device: an old-style message new to it is
                        // marked whatever date it claims, unless this device held it before)
                        lock.lock(); let held = d.map { items[$0.rid] != nil } ?? false, history = catchingUp; lock.unlock()
                        if let x = d, x.kind == 14, sealed?.sealedSince(x.conv) != nil, !held, !history { d?.unsealed = true }
                    }
                } else if e.pubkey == me || e.hasTag("p", me), let bunker = engine.signer as? BunkerSigner {
                    let peer = e.pubkey == me ? (e.tag("p") ?? me) : e.pubkey
                    let text = (try? await bunker.nip04Decrypt(peer: peer, payload: e.content)) ?? "(an old-style message this app cannot read)"
                    d = Dm(rid: e.id, conv: "n:" + peer, from: e.pubkey, mine: e.pubkey == me, at: e.createdAt, kind: 4, text: text)
                }
                lock.lock()
                if let d {
                    // the old way never replaces a message this device holds, except my own while
                    // it is still on its way (its copy coming back)
                    if let old = items[d.rid] {
                        if old.rumor == nil, old.sharedBy == nil, old.kind == d.kind, old.conv == d.conv, old.from == d.from {
                            var n = d
                            n.mine = d.mine || old.mine; n.pending = old.pending; n.failed = old.failed; n.unsealed = old.unsealed ?? d.unsealed
                            items[d.rid] = n
                        }
                    } else {
                        items[d.rid] = d
                    }
                }
                seen.insert(e.id)
                done += 1
                lock.unlock()
                changed = true
                // kept as it goes: a restart never asks the signer again for what was opened
                if done % 20 == 0 { save() }
            } catch {
                if "\(error)".contains("timeout") { break } // the signer is away: next time
                lock.lock(); seen.insert(e.id); lock.unlock()
                changed = true
            }
        }
        lock.lock()
        let was = lockedWraps
        lockedWraps = locked
        lock.unlock()
        if changed { save() } else if was != locked { onChange?() }
    }

    /// A sealed rumor, opened: a message, a reaction, or (SHAREDBY) a piece of shared history,
    /// which never replaces a message this device already has.
    private func take(_ rumor: NostrEvent, sharedBy: String?) {
        lock.lock()
        defer { lock.unlock() }
        if rumor.kind == 7 || rumor.kind == 5 {
            // shared history is not proven: its reactions count only on messages that are themselves
            // shared, and its take-backs only for reactions that came the same way; they never
            // touch a real reaction
            guard sharedBy != nil else { reactions.apply(rumor); return }
            let targets = rumor.tagValues("e")
            if rumor.kind == 7 {
                guard let t = targets.last, items[t]?.sharedBy != nil else { return }
                sharedReactions.insert(rumor.id)
                reactions.apply(rumor)
            } else if !targets.isEmpty, targets.allSatisfy(sharedReactions.contains) {
                reactions.apply(rumor)
            }
            return
        }
        if sharedBy != nil, items[rumor.id] != nil { return }
        let known = items.values.map { (messageId: $0.messageId, conv: $0.conv) }
        guard var d = DmReader.dm(from: rumor, me: me, bridge: bridge, known: known) else { return }
        d.sharedBy = sharedBy
        if d.kind == 14 { d.rumor = Sealed.json(rumor) }
        if let old = items[d.rid] { d.mine = d.mine || old.mine; d.pending = old.pending; d.failed = old.failed }
        items[d.rid] = d
    }

    /// The sealed messages of CONV as rumors, oldest first (what Share history sends).
    public func rumors(_ conv: String) -> [NostrEvent] {
        thread(conv).compactMap { d in d.sharedBy == nil ? d.rumor.flatMap(NostrEvent.from(json:)) : nil }
    }

    // ---- views ------------------------------------------------------------------------------------

    public func threads() -> [DmThread] {
        lock.lock(); defer { lock.unlock() }
        var by = [String: [Dm]]()
        for d in items.values { by[d.conv, default: []].append(d) }
        return by.map { conv, list in
            let sorted = list.sorted { $0.at < $1.at }
            let r = max(read[conv] ?? 0, readFloor?(conv) ?? 0)
            return DmThread(conv: conv, last: sorted.last!, unread: sorted.filter { !$0.mine && $0.at > r }.count, count: sorted.count)
        }.sorted { $0.last.at > $1.last.at }
    }

    public func thread(_ conv: String) -> [Dm] {
        lock.lock(); defer { lock.unlock() }
        return items.values.filter { $0.conv == conv }.sorted { $0.at < $1.at }
    }

    public var unreadTotal: Int { threads().filter { $0.unread > 0 }.count }

    /// The shared read state's mark for a conversation (SPEC 19.27); the higher of it and this
    /// phone's own mark counts.
    public var readFloor: ((String) -> Int)?
    /// This phone's own marks (seeded once into the shared read state).
    public var readMarks: [String: Int] { lock.lock(); defer { lock.unlock() }; return read }

    public func report(_ emailId: String?) -> DeliveryReport? {
        guard let emailId else { return nil }
        lock.lock(); defer { lock.unlock() }
        return reports[emailId]
    }

    /// A mail thread's name: its subject without Re:/Fwd:.
    public func threadName(_ conv: String) -> String {
        let s = MailThreads.baseSubject(thread(conv).first { $0.subject != nil }?.subject)
        return s.isEmpty ? "(no subject)" : s
    }

    public func markRead(_ conv: String) {
        let last = thread(conv).last?.at ?? 0
        lock.lock()
        guard (read[conv] ?? 0) < last else { lock.unlock(); return }
        read[conv] = last
        let r = read
        lock.unlock()
        db.set("dm-read", r)
        onChange?()
    }

    // ---- sending ----------------------------------------------------------------------------------

    /// CONV: the Nostr conversation it belongs to; MAIL: it goes to the belfry's bridge.
    func deliver(_ rumor: NostrEvent, to: [String], selfCopy: Bool = true, conv: String? = nil, mail: Bool = false) async throws {
        try engine.guestMode.check()
        // the people's heads as the relay has them now (at most 3 s), then:
        // sealed (docs/sealed.md): made on this device, no signer call, never the old way again
        if let s = sealed, conv != nil || mail {
            await s.refresh(conv.map(MailThreads.peers) ?? [])
            // the old way only on knowledge, never on silence (sealed.md 6): refused, the text is kept
            let way = conv.map { s.way($0) } ?? s.mailWay()
            if way == .unknown { throw BelfryError.invalid("Not sent: the belfry did not answer in time to check the lock. Try again.") }
        }
        if let s = sealed, let conv, s.isSealed(conv) {
            hold(rumor)
            for w in try s.wraps(rumor, to: to, selfCopy: selfCopy) { engine.enqueueSigned(w, target: .main, dm: rumor.id) }
            return
        }
        if let s = sealed, mail, s.mailSealed, let b = to.first {
            guard s.mine == .inside else { throw BelfryError.invalid("You can write here once this device is allowed.") }
            var list = [try s.mailWrap(rumor, bridge: b)]
            if selfCopy { hold(rumor); list += try s.wraps(rumor, to: [], selfCopy: true) }
            for w in list { engine.enqueueSigned(w, target: .main, dm: rumor.id) }
            return
        }
        var targets = [String]()
        for p in to + (selfCopy ? [me] : []) where !targets.contains(p) { targets.append(p) }
        if sealed != nil, conv != nil { hold(rumor) }
        for p in targets {
            let w = try await GiftWrap.wrap(rumor, to: p, signer: engine.signer)
            if engine.localOnly, p == me { engine.add([w], verify: false) }
            engine.enqueueSigned(w, target: .main, dm: rumor.id)
        }
    }

    /// Kept with the device's other messages until its wraps have left (a restart finds it again).
    func hold(_ rumor: NostrEvent) {
        lock.lock()
        queued[rumor.id] = rumor
        let all = queued.mapValues(Sealed.json)
        lock.unlock()
        db.set("dm-queued", all)
    }

    /// A queued wrap, just before it leaves (sealed.md 9). A sealed one: its account's head is
    /// asked from the relay first (no complete answer: it waits for the next try), and it is
    /// sealed again when its letterbox is no longer that head. An old-style one whose conversation
    /// became sealed while it waited is sealed now instead: never the old way once sealed.
    func reseal(_ item: OutboxItem) async throws -> NostrEvent? {
        guard let s = sealed, let w = item.signed, w.kind == 1059, let account = w.tag("p"), let rid = item.dm else { return nil }
        lock.lock()
        let rumor = queued[rid] ?? items[rid]?.rumor.flatMap(NostrEvent.from(json:))
        lock.unlock()
        if let lb = Sealed.lb(of: w) {
            // "hold:": this wrap waits, the others in the outbox still go
            guard await s.refresh([account]) else { throw BelfryError.relay("hold: the lock could not be checked") }
            return rumor.flatMap { s.again($0, for: account, was: lb) }
        }
        // old-style: only messages, reactions and take-backs between people are ever sealed
        guard let rumor, [14, 7, 5].contains(rumor.kind) else { return nil }
        let conv = MailThreads.nostrConv(author: rumor.pubkey, pTags: rumor.tagValues("p"), me: me)
        guard s.isSealed(conv) else { return nil }
        guard await s.refresh([account]) else { throw BelfryError.relay("hold: the lock could not be checked") }
        return try s.wrapOne(rumor, to: account)
    }

    /// The chips under a direct message, for me.
    public func chips(_ rid: String) -> [DmChip] {
        lock.lock(); defer { lock.unlock() }
        return reactions.chips(rid, viewer: me)
    }

    /// Tap a chip or pick an emoji: adds my reaction to D, or takes it back when I gave it.
    /// Shown at once; wrapped to every participant and to me. Never on e-mail.
    public func react(_ emoji: String, on d: Dm) async throws {
        try engine.guestMode.check()
        guard d.kind == 14, d.pending != true else { return }
        let others = MailThreads.peers(d.conv).filter { $0 != me }
        guard !others.isEmpty, others.allSatisfy(isHex64) else { return }
        lock.lock()
        let mine = reactions.mine(d.rid, emoji: emoji, viewer: me)
        lock.unlock()
        let rumor: NostrEvent
        if let mine {
            rumor = GiftWrap.rumor(kind: 5, pubkey: me, tags: DmReactions.removeTags(reaction: mine, participants: others, me: me), content: "")
        } else {
            rumor = GiftWrap.rumor(kind: 7, pubkey: me, tags: DmReactions.addTags(message: d.rid, author: d.from, participants: others + [me], me: me), content: emoji)
        }
        // shown once it is on its way: a send that is refused leaves nothing behind
        try await deliver(rumor, to: others, conv: d.conv)
        lock.lock(); reactions.apply(rumor); lock.unlock()
        save()
    }

    /// Called when this device sends a DM or an e-mail (push: stay quiet for its own echo).
    public var onSend: (() -> Void)?

    /// A NIP-17 message in a Nostr conversation.
    public func send(_ text: String, in conv: String) async throws {
        try engine.guestMode.check()
        onSend?()
        let to = MailThreads.peers(conv).filter { $0 != me }
        guard to.allSatisfy(isHex64) else { throw BelfryError.invalid("This is not a valid Nostr key.") }
        let rumor = GiftWrap.rumor(kind: 14, pubkey: me, tags: to.map { ["p", $0] }, content: text)
        var d = Dm(rid: rumor.id, conv: conv, from: me, mine: true, at: rumor.createdAt, kind: 14, text: text)
        d.pending = engine.localOnly ? nil : true
        if sealed?.isSealed(conv) == true { d.rumor = Sealed.json(rumor) }
        lock.lock(); items[rumor.id] = d; lock.unlock()
        save()
        do {
            try await deliver(rumor, to: to, conv: conv)
        } catch {
            lock.lock(); items[rumor.id] = nil; lock.unlock()
            save()
            throw error
        }
    }

    /// An e-mail through the belfry's bridge. Returns the thread it lands in.
    @discardableResult
    public func sendMail(_ text: String, in conv: String, subject: String? = nil, fromName: String) async throws -> String {
        try engine.guestMode.check()
        onSend?()
        guard let b = bridge else { throw BelfryError.invalid("This belfry does not send e-mail yet.") }
        guard let from = myAddress else { throw BelfryError.invalid("You have no address here yet (name@domain).") }
        let to = MailThreads.address(conv)
        let fresh = MailThreads.isNewMail(conv)
        let before = fresh ? nil : thread(conv).last { $0.kind == 1301 }
        let base = fresh ? ((subject?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)")
            : (MailThreads.baseSubject(before?.subject).isEmpty ? "(no subject)" : MailThreads.baseSubject(before?.subject))
        let subj = fresh || before == nil ? base : "Re: " + base
        let (raw, messageId) = MIME.build(fromName: fromName.isEmpty ? String(from.split(separator: "@").first ?? "") : fromName,
                                          from: from, to: to, subject: subj, text: text,
                                          inReplyTo: before?.messageId, references: before?.references, domain: engine.config.domain)
        let target = fresh ? MailThreads.thread(address: to, subject: subj) : conv
        let emailId = UUID().uuidString.lowercased()
        let rumor = GiftWrap.rumor(kind: 1301, pubkey: me, tags: [["email-id", emailId], ["mail-from", from], ["rcpt-to", to], ["subject", subj]], content: raw)
        var d = Dm(rid: rumor.id, conv: target, from: me, mine: true, at: rumor.createdAt, kind: 1301, text: text)
        d.subject = subj
        d.emailId = emailId
        d.raw = raw
        d.messageId = messageId
        d.references = before.map { [$0.references, $0.messageId].compactMap { $0 }.joined(separator: " ") }
        d.pending = true
        lock.lock()
        items[rumor.id] = d
        reports[emailId] = DeliveryReport(status: "queued", details: "Waiting for the connection…")
        lock.unlock()
        save()
        do {
            try await deliver(rumor, to: [b], mail: true)
        } catch {
            lock.lock()
            reports[emailId] = DeliveryReport(status: "failed", details: "It could not be prepared. Try again.")
            items[rumor.id]?.pending = false
            items[rumor.id]?.failed = "not sent"
            lock.unlock()
        }
        if engine.localOnly {
            lock.lock()
            reports[emailId] = DeliveryReport(status: "failed", details: "Demo mode sends no e-mail.")
            items[rumor.id]?.pending = false
            lock.unlock()
        }
        save()
        return target
    }

    /// Shared inbox: an answer by e-mail as the channel (mail-from = <channel>@domain), to the
    /// sender of the inbox card CARDID (SPEC 19.6). Returns the e-mail's id (its delivery report).
    @discardableResult
    /// LOCAL: the channel's address before the @ (its plain alias when it has one, SPEC 19.33).
    /// REFERENCES: the thread's Message-IDs before In-Reply-To, oldest first, space-separated.
    public func sendAsChannel(channel: String, local: String? = nil, channelName: String, to: String, subject: String, text: String, inReplyTo: String?,
                              references: String? = nil, cardId: String, myName: String) async throws -> String {
        try engine.guestMode.check()
        guard let b = bridge else { throw BelfryError.invalid("This belfry does not send e-mail yet.") }
        // envelope (mail-from) and From header alike: the bridge checks they match
        let from = (local.flatMap { $0.isEmpty ? nil : $0 } ?? channel) + "@" + engine.config.domain
        let (raw, _) = MIME.build(fromName: myName.isEmpty ? channelName : "\(myName) for \(channelName)", from: from, to: to, subject: subject, text: text,
                                  inReplyTo: inReplyTo, references: references, domain: engine.config.domain)
        let emailId = UUID().uuidString.lowercased()
        let rumor = GiftWrap.rumor(kind: 1301, pubkey: me, tags: [["email-id", emailId], ["mail-from", from], ["rcpt-to", to], ["subject", subject], ["e", cardId]], content: raw)
        if engine.localOnly {
            lock.lock(); reports[emailId] = DeliveryReport(status: "failed", details: "Demo mode sends no e-mail."); lock.unlock()
            save()
            return emailId
        }
        lock.lock(); reports[emailId] = DeliveryReport(status: "queued", details: "Sending…"); lock.unlock()
        save()
        do {
            try await deliver(rumor, to: [b], selfCopy: false, mail: true)
        } catch {
            lock.lock(); reports[emailId] = DeliveryReport(status: "failed", details: "It could not be prepared. Try again."); lock.unlock()
            save()
            throw BelfryError.invalid("The e-mail could not be prepared. Try again.")
        }
        return emailId
    }

    /// Outbox news: a DM is out once no wrap for someone else waits any more.
    public func outboxSent(_ item: OutboxItem) {
        guard let rid = item.dm else { return }
        if !engine.outboxItems().contains(where: { $0.dm == rid }) {
            lock.lock()
            queued[rid] = nil
            let all = queued.mapValues(Sealed.json)
            lock.unlock()
            db.set("dm-queued", all)
        }
        let left = engine.outboxItems().filter { $0.dm == rid && $0.tags.contains { $0.first == "p" && $0.count > 1 && $0[1] != me } }
        guard left.isEmpty else { return }
        lock.lock()
        items[rid]?.pending = false
        items[rid]?.failed = nil
        let emailId = items[rid]?.kind == 1301 ? items[rid]?.emailId : nil
        if let emailId { reports[emailId] = DeliveryReport(status: "queued", details: "Sent: waiting for the delivery report…") }
        lock.unlock()
        save()
        if emailId != nil, !engine.localOnly {
            for wait in [3.0, 10, 30, 90] {
                DispatchQueue.global().asyncAfter(deadline: .now() + wait) { Task { await self.checkReports() } }
            }
        }
    }

    public func outboxFailed(_ item: OutboxItem) {
        guard let rid = item.dm, item.tags.contains(where: { $0.first == "p" && $0.count > 1 && $0[1] != me }) else { return }
        lock.lock()
        items[rid]?.failed = item.error ?? "The relay refused it."
        if let e = items[rid]?.emailId { reports[e] = DeliveryReport(status: "failed", details: "The relay refused it.") }
        lock.unlock()
        save()
    }

    public func retry(_ d: Dm) {
        for o in engine.outboxItems() where o.dm == d.rid { engine.retry(o.localId) }
        lock.lock()
        items[d.rid]?.failed = nil
        items[d.rid]?.pending = true
        if let e = d.emailId { reports[e] = DeliveryReport(status: "queued", details: "Waiting for the connection…") }
        lock.unlock()
        save()
    }

    /// Delivery reports (kind 7679) for my e-mails that have none yet.
    public func checkReports() async {
        guard let b = bridge, !engine.localOnly else { return }
        lock.lock()
        let open = items.values.filter { $0.mine && $0.emailId != nil && ["queued", nil].contains(reports[$0.emailId!]?.status) }.compactMap(\.emailId)
        lock.unlock()
        guard !open.isEmpty else { return }
        let found = await engine.query(.main, [["kinds": [7679], "authors": [b], "#r": Array(open.suffix(50))]])
        for e in found {
            // a report sealed to my letterbox opens here; an old-style one through the signer
            let opened: String?
            if e.tag("lb") != nil { opened = sealed?.openReport(e) }
            else if let eph = e.tag("ephemeral-pubkey") { opened = try? await engine.signer.nip44Decrypt(peer: eph, payload: e.content) }
            else { opened = nil }
            guard let r = e.tag("r"), let text = opened,
                  let obj = JSON.parse(text) as? [String: Any], let status = obj["status"] as? String,
                  ["delivered", "failed", "delayed", "queued"].contains(status) else { continue }
            let fixed: String
            switch status {
            case "delivered": fixed = "Delivered."
            case "failed": fixed = "Not delivered: the receiving server refused it."
            case "delayed": fixed = "Delayed: the receiving server will be tried again."
            default: fixed = "Sent: waiting for the delivery report…"
            }
            lock.lock(); reports[r] = DeliveryReport(status: status, details: fixed); lock.unlock()
        }
        save()
    }

    /// Where a new conversation goes: a member (name, nip05, hex key) or an e-mail address.
    public func conv(for input: String, people: [(pubkey: String, name: String, nip05: String?)]) async -> String? {
        let v = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = people.first(where: { $0.nip05?.lowercased() == v || $0.name.lowercased() == v }) { return "n:" + hit.pubkey }
        if isHex64(v) { return "n:" + v }
        if let pk = Bech32.pubkey(npub: v) { return "n:" + pk }
        guard let m = Rx("^([^@\\s]+)@([^@\\s]+\\.[^@\\s]+)$").first(v), let name = m[1], let domain = m[2] else { return nil }
        if domain == engine.config.domain, !engine.localOnly, let pk = await Discovery.nip05(name: name, domain: domain) { return "n:" + pk }
        return "m:" + v
    }

    /// Demo mode: an e-mail arrives from SENDER as the belfry would deliver it.
    public func demoMail(bridgeSecret: Data, sender: String, subject: String, text: String, at: Int) async throws {
        let bridgeSigner = try LocalSigner(secret: bridgeSecret)
        bridge = bridgeSigner.pubkey
        let raw = "From: \(sender)\r\nTo: \(myAddress ?? "me@demo")\r\nSubject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@example.org>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(text)\r\n"
        let rumor = GiftWrap.rumor(kind: 1301, pubkey: bridgeSigner.pubkey, tags: [["email-id", UUID().uuidString], ["mail-from", MIME.address(sender).address], ["p", me], ["subject", subject], ["belfry-auth", "pass"]], content: raw, createdAt: at)
        let w = try await GiftWrap.wrap(rumor, to: me, signer: bridgeSigner)
        engine.add([w], verify: false)
    }

    /// Demo mode: a NIP-17 message from FROM.
    @discardableResult
    public func demoDM(from: LocalSigner, text: String, at: Int, reaction: String? = nil, others: [String] = []) async throws -> String {
        let rumor = GiftWrap.rumor(kind: 14, pubkey: from.pubkey, tags: ([me] + others).map { ["p", $0] }, content: text, createdAt: at)
        let w = try await GiftWrap.wrap(rumor, to: me, signer: from)
        engine.add([w], verify: false)
        // the demo's own reaction to it (wrapped to me like any other)
        if let reaction {
            let r = GiftWrap.rumor(kind: 7, pubkey: me, tags: DmReactions.addTags(message: rumor.id, author: from.pubkey, participants: [from.pubkey, me], me: me), content: reaction, createdAt: at + 60)
            engine.add([try await GiftWrap.wrap(r, to: me, signer: engine.signer)], verify: false)
        }
        return rumor.id
    }

    /// Demo mode: the messages of CONV as history shared by BY.
    public func demoShared(conv: String, by: String) {
        lock.lock()
        for (k, d) in items where d.conv == conv { items[k]?.sharedBy = by }
        lock.unlock()
        save()
    }

    /// Demo mode: the message TEXT of CONV came the old way after the conversation was sealed.
    public func demoUnsealed(conv: String, text: String) {
        lock.lock()
        for (k, d) in items where d.conv == conv && d.text == text { items[k]?.unsealed = true }
        lock.unlock()
        save()
    }

    /// Demo mode: a NIP-17 message of mine to TO (my own copy of it).
    public func demoSent(to: String, text: String, at: Int) async throws {
        let rumor = GiftWrap.rumor(kind: 14, pubkey: me, tags: [["p", to]], content: text, createdAt: at)
        engine.add([try await GiftWrap.wrap(rumor, to: me, signer: engine.signer)], verify: false)
    }
}
