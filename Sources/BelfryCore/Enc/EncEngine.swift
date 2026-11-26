import Foundation

// Encrypted conversations, format 3, on this device (docs/encrypted.md §1–§28; SPEC 19.70). A port of
// the web's src/core/enc/runtime.ts (chat c8703b4): the device lists of the people I talk to, the
// conversation keys this device holds, opening 8572s, encrypting what it sends (people conversations
// and private groups), and a new device's flow (ask, the card, share, answer).
//
// The device key is the session's client key, already on this device (nothing new is generated).
// Keys are kept in this account's own database (kv "enc-keys"), never logged, never shown.
// Writing format 3 only when belfry.json says so (or this device once saw it say so: one way, §17.13);
// reading always. A guest's session does not run it (§25).

public final class EncEngine: @unchecked Sendable {
    public struct KeyRec: Codable, Equatable, Sendable {
        public var held: Enc.HeldKey
        /// the people of a people key (accounts)
        public var people: [String]?
        /// a people key's rumor as received or made (what a key pack hands on), as JSON
        public var rumor: String?
        /// my key's envelopes not confirmed out yet (P2.1): their ids, and what rebuilds them
        public var unconfirmed: [String]?
        public var madePer: [Per]?
        /// a group key's entry set as its maker claims it (adopted only while the entries add up)
        public var claimed: String?
        /// a group key I made whose envelopes aren't confirmed out (P2.2)
        public var unconfirmedGroup: [Tmpl]?
    }
    public struct Per: Codable, Equatable, Sendable { public var account: String; public var devices: [String] }
    public struct Tmpl: Codable, Equatable, Sendable {
        public var kind: Int; public var content: String; public var tags: [Tag]; public var createdAt: Int
        var template: EventTemplate { EventTemplate(kind: kind, content: content, tags: tags, createdAt: createdAt) }
        init(_ t: EventTemplate) { kind = t.kind; content = t.content; tags = t.tags; createdAt = t.createdAt }
    }

    /// Why a message could not be encrypted now: held on the device with its text kept (§9, §17).
    public enum Held: Error, Equatable, LocalizedError {
        public var errorDescription: String? { text { _ in "This person" } }
        case noList(String?), notListed, noDevice(String), tooMany, full, fork(String), guest, cantCheckGroup, mail, format
        public func text(_ name: (String) -> String) -> String {
            switch self {
            case .noDevice(let who): return "\(name(who)) isn’t signed in on any device · It will be sent when they are"
            case .notListed: return "This device isn’t set up for encrypted messages yet"
            case .full: return "You have 20 devices signed in · Remove one to send encrypted messages here"
            case .tooMany: return "Too many devices to encrypt for everyone here"
            case .guest: return "Not sent: this encrypted conversation now includes a guest, and guests can’t read encrypted messages yet"
            case .cantCheckGroup: return "Not sent: couldn’t check who can read this group"
            case .mail: return "E-mail from the chat waits for this belfry’s update"
            default: return "Not sent: couldn’t check who can read this conversation"
            }
        }
    }

    public enum Opened: Equatable {
        case rumor(NostrEvent, conv: String)
        /// its key or the author's lists aren't here yet: kept, tried again (never marked seen)
        case keep(unreadable: Bool)
        case drop
    }

    let engine: SyncEngine
    let device: Data
    public let devicePub: String
    private let lock = NSLock()
    private var keys = [String: KeyRec]()
    private var byAlias = [String: String]()
    /// conversations known to be encrypted here, with their first key's date (people id, or "g:<id>")
    private var convs = [String: Int]()
    private var envSeen = Set<String>()
    private var packSeen = Set<String>()
    private var opened = Set<String>()
    private var listsRead = [String: Int]()
    private var wanted = Set<String>()
    public private(set) var partners = [String]()
    private var dRead = [String: (at: Date, found: Bool)]()
    private var cantCheck = Set<String>()
    private var strangeEntries = Set<String>()
    private let startedAt = Date()
    /// What the app knows of the groups and people (set on every change of its snapshot): the
    /// private groups (closed + private), their members (39002), and who is a guest.
    public struct World: Sendable {
        public var privateIds: Set<String> = []
        public var members: [String: Set<String>] = [:]
        public var guests: Set<String> = []
        /// groups whose metadata this device has (a group not known yet: its writes wait)
        public var known: Set<String> = []
        /// keys that came by a link whose guest status the register hasn't answered yet: a send to a
        /// conversation with one of them waits (never Notes, never anyone else)
        public var unanswered: Set<String> = []
        public init(privateIds: Set<String> = [], members: [String: Set<String>] = [:], guests: Set<String> = [], known: Set<String> = [], unanswered: Set<String> = []) {
            self.privateIds = privateIds; self.members = members; self.guests = guests; self.known = known; self.unanswered = unanswered
        }
    }
    private var world = World()
    public func setWorld(_ w: World) {
        lock.lock(); let changed = w.privateIds != world.privateIds; world = w; lock.unlock()
        if changed { engine.refreshFilters() }
    }
    public func isPrivate(_ h: String) -> Bool { lock.withLock { world.privateIds.contains(h) } }
    /// §26: private now, or ever encrypted on this device (a key of the group seen here).
    public func encryptedGroup(_ h: String) -> Bool { lock.withLock { world.privateIds.contains(h) || convs["g:" + h] != nil } }

    /// How a write of T in its group goes (the web's groupWriteMode): a group with a key seen here is
    /// always encrypted; on format 3 a private one is encrypted and one not known yet waits; with the
    /// format unknown on a device that saw it, private or unknown groups wait. §16.9's kinds go plain.
    public func groupMode(_ t: EventTemplate) -> SyncEngine.GroupMode {
        guard let h = t.tags.first(where: { $0.count > 1 && $0[0] == "h" })?[1], !h.isEmpty else { return .plain }
        if t.kind == Enc.key || t.kind == Enc.msg || clearInGroup(kind: t.kind, pubkey: me, tags: t.tags) { return .plain }
        let (here, priv, known) = lock.withLock { (convs["g:" + h] != nil, world.privateIds.contains(h), world.known.contains(h)) }
        if here { return .enc }
        if formatNow == 3 { return priv ? .enc : known ? .plain : .hold }
        if formatNow == nil && seenEncrypted { return priv || !known ? .hold : .plain }
        return .plain
    }
    func isGuest(_ a: String) -> Bool { lock.withLock { world.guests.contains(a) } }
    func membersOf(_ h: String) -> Set<String>? { lock.withLock { world.members[h] } }
    func privateGroups() -> [String] { lock.withLock { world.privateIds.filter { world.members[$0]?.contains(me) == true }.sorted() } }
    public var onKeys: (() -> Void)?
    public var onV1Secrets: (([(lb: String, secret: String)]) -> Void)?
    public var v1Provider: () -> [(lb: String, secret: String)] = { [] }

    public init(engine: SyncEngine, deviceSecret: Data) {
        self.engine = engine
        self.device = deviceSecret
        self.devicePub = Enc.pub(deviceSecret)
        for r in engine.db.get("enc-keys", as: [KeyRec].self) ?? [] where Enc.isKey(r.held.K) && Enc.isKey(r.held.k) { _ = holdKey(r) }
        for (c, at) in engine.db.get("enc-convs", as: [String: Int].self) ?? [:] { noteConv(c, at) }
        firstN = engine.db.get("enc-first-n", as: Int.self) ?? 0
        answeredHere = engine.db.get("enc-answered", as: [String: String].self) ?? [:]
        asked = engine.db.get("enc-asked", as: AskedRec.self)
        if engine.config.encryptedFormat == 3 { engine.db.set("enc-format3", true) }
    }

    var me: String { engine.me }
    var belfry: String? { engine.config.belfryKey }
    var groupsKey: String? { engine.config.groupsKeyHex }

    /// §12 + §17.13: format 3 is what this belfry writes (belfry.json, or this device once saw it).
    public var writes3: Bool {
        if engine.db.get("enc-format3", as: Bool.self) == true { return true }
        if engine.config.encryptedFormat == 3 || configFormat() == 3 { engine.db.set("enc-format3", true); return true }
        return false
    }
    /// The app's belfry.json as it has it now (it may be newer than the engine's copy).
    private var cfgFormat: Int?
    public func setConfigFormat(_ f: Int?) {
        lock.withLock { cfgFormat = f }
        if f != nil { engine.db.set("enc-seen", true) }
        if f == 3 { engine.db.set("enc-format3", true) }
    }
    func configFormat() -> Int? { lock.withLock { cfgFormat } }
    /// The format to write now (the web's freshFormat): 3 for good, or a 1 read in the last 5 minutes
    /// (read again first when older); nil: unknown or a stale 1 (the caller holds).
    public var freshFormat: (() async -> Int?)?
    /// 3 when this device writes format 3; 1 when belfry.json says 1; nil when it says nothing.
    var formatNow: Int? { writes3 ? 3 : (configFormat() ?? engine.config.encryptedFormat) }
    /// This device saw an "encrypted" object in belfry.json once (then an unknown format holds).
    public var seenEncrypted: Bool { EncEngine.expected(db: engine.db, config: engine.config) }
    /// Format 3 is, or was, seen for this account (DirectMessages and the outbox hold without an engine).
    public static func expected(db: Database, config: BelfryConfig) -> Bool {
        if config.encryptedFormat != nil { db.set("enc-seen", true) }
        return config.encryptedFormat == 3 || db.get("enc-format3", as: Bool.self) == true || db.get("enc-seen", as: Bool.self) == true
    }
    /// The format a send uses now, awaited when this device ever saw format 3 or "encrypted".
    public func sendFormat() async -> Int? {
        if writes3 { return 3 }
        if !seenEncrypted { return 1 }
        return await freshFormat?() ?? nil
    }

    private func save() {
        lock.lock(); let ks = Array(keys.values); let cs = convs; lock.unlock()
        engine.db.set("enc-keys", ks)
        engine.db.set("enc-convs", cs)
    }
    private func noteConv(_ c: String, _ at: Int) {
        if let was = convs[c], was <= at { return }
        convs[c] = at
        // a group's first key: clear events after it go (§17.2)
        if c.hasPrefix("g:") { let e = engine; DispatchQueue.global().async { e.recheckRefused() } }
    }
    /// §17.12: the first valid declaration of a K stays; only "unconfirmed" may clear.
    @discardableResult
    private func holdKey(_ r: KeyRec) -> Bool {
        if var had = keys[r.held.K] {
            if had.unconfirmed != nil && r.unconfirmed == nil { had.unconfirmed = nil; keys[r.held.K] = had }
            return false
        }
        keys[r.held.K] = r
        byAlias[Enc.alias(r.held.K, me)] = r.held.K
        noteConv(r.held.conv, r.held.at)
        return true
    }
    public var keyCount: Int { lock.lock(); defer { lock.unlock() }; return keys.count }

    // ---- device lists ------------------------------------------------------------------------

    /// §17.1 + §20: an account's devices: its chain; the service keys their own device; unknown otherwise.
    public func devices(_ account: String) -> Enc.Devices {
        if !account.isEmpty, account == belfry || account == groupsKey { return .service }
        guard let b = belfry else { return .unknown }
        let lists = engine.snapshot().filter { $0.kind == Enc.list && $0.pubkey == b }
        return Enc.chainOf(lists, belfry: b, account: account).map { .chain($0) } ?? .unknown
    }
    func chain(_ a: String) -> Enc.Chain? { if case .chain(let c) = devices(a) { return c }; return nil }

    /// The people I talk to: their lists are kept on the live subscription.
    public func setPartners(_ ps: [String]) {
        let next = Array(Set(ps)).sorted()
        lock.lock(); let same = next == partners; partners = next; lock.unlock()
        if !same { engine.refreshFilters() }
    }

    /// The subscription's filters for the community relay (lists, my keys, messages, packs, asks).
    public func mainFilters() -> [[String: Any]] {
        guard let b = belfry else { return [] }
        lock.lock(); let ps = Array(Set([me] + partners + wanted)); lock.unlock()
        return [
            ["kinds": [Enc.list], "authors": [b], "#p": ps, "limit": 2000],
            ["kinds": [Enc.key, Enc.msg, Enc.pack], "#p": [me], "limit": 2000],
            ["kinds": [Enc.ask, Enc.answer], "#p": [me], "limit": 200],
        ]
    }
    /// Once per connection to the community relay (after AUTH): everything of mine the live
    /// subscription's limit may have cut, paged (the relay answers 300 at most), since the last
    /// complete catch-up less an hour.
    private var caughtUpOn: Int?
    public func catchUp() async {
        guard let b = belfry, let conn = engine.connection(.main), lock.withLock({ caughtUpOn != conn }) else { return }
        lock.withLock { caughtUpOn = conn }
        let since = max(0, (engine.db.get("enc-caught-up", as: Int.self) ?? 0) - 3600)
        let started = Int(Date().timeIntervalSince1970)
        let ps = lock.withLock { Array(Set([me] + partners + wanted)) }
        guard let got = await engine.queryPaged(.main, [
            ["kinds": [Enc.list], "authors": [b], "#p": ps],
            ["kinds": [Enc.key, Enc.msg, Enc.pack, Enc.ask, Enc.answer], "#p": [me], "since": since],
        ], timeout: 8, maxPages: 1000, total: 60) else { lock.withLock { caughtUpOn = nil }; return }
        _ = engine.add(got)
        lock.withLock { for a in ps { listsRead[a] = conn } }
        engine.db.set("enc-caught-up", started)
        takeEnvelopes()
        onKeys?()
    }

    /// Per private group: its 8571 and 8572 on the groups relay.
    public func groupFilters() -> [[String: Any]] {
        let ids = privateGroups()
        return ids.isEmpty ? [] : [["kinds": [Enc.key, Enc.msg], "#h": ids, "limit": 2000]]
    }

    /// Tests: every list counts as read whole on this connection (a local-only engine has none).
    var assumeRead = false
    private func readOnThisConnection(_ a: String) -> Bool {
        if assumeRead { return true }
        guard let c = engine.connection(.main) else { return false }
        lock.lock(); defer { lock.unlock() }
        return listsRead[a] == c
    }
    /// Read ACCOUNTS' lists whole on this connection; true when the read completed (after AUTH only).
    func readLists(_ accounts: [String], timeout: TimeInterval) async -> Bool {
        guard let b = belfry, !accounts.isEmpty, let conn = engine.connection(.main) else { return false }
        guard let got = await engine.queryPaged(.main, [["kinds": [Enc.list], "authors": [b], "#p": accounts]], timeout: timeout, maxPages: 20, total: timeout) else { return false }
        _ = engine.add(got)
        lock.lock(); for a in accounts { listsRead[a] = conn }; lock.unlock()
        return true
    }
    private func want(_ accounts: [String]) {
        lock.lock()
        let fresh = accounts.filter { Enc.isKey($0) && !wanted.contains($0) && !partners.contains($0) }
        for a in fresh { wanted.insert(a) }
        lock.unlock()
        if !fresh.isEmpty { engine.refreshFilters(); Task { _ = await readLists(fresh, timeout: 5) } }
    }

    public enum Listed: String, Sendable { case yes, notYet, held, full }
    public var chatSessions = 0
    /// This device on its own account's current list; "full": twenty and not listed (§17.4).
    public func listedHere() -> Listed {
        let c = chain(me)
        if let c, c.current.devices.contains(devicePub) { return .yes }
        if let c, c.current.devices.count >= Enc.maxList, chatSessions >= Enc.maxList { return .full }
        return Date().timeIntervalSince(startedAt) < 60 ? .notYet : .held
    }
    /// How many devices my current list has (Notes' "Encrypted for your N devices").
    public func myListDevices() -> Int { chain(me)?.current.devices.count ?? 0 }

    // ---- receiving ---------------------------------------------------------------------------

    /// Envelopes for my account: my entries opened and judged; held when accepted (§5, §16.2). Then packs.
    public func takeEnvelopes() {
        let m = me
        var changed = false
        for e in engine.snapshot() where e.kind == Enc.key && e.hasTag("p", m) {
            lock.lock(); let seen = envSeen.contains(e.id); lock.unlock()
            if seen { continue }
            var o: (seal: NostrEvent, rumor: NostrEvent)?
            do { o = try Enc.openPeopleEnvelope(device: device, e) } catch { lock.lock(); envSeen.insert(e.id); lock.unlock(); continue }
            checkEntries(e)
            guard let o else { lock.lock(); envSeen.insert(e.id); lock.unlock(); continue }
            let v = Enc.acceptKeyRumor(o.rumor, receiver: m, devices: devices)
            if v == .wait { want(Enc.values(o.rumor.tags, "p")); continue }
            lock.lock(); envSeen.insert(e.id); lock.unlock()
            guard v == .ok, let K = o.rumor.tag("K") else { continue }
            let r = o.rumor
            let people = Enc.values(r.tags, "p")
            let named = r.tags.first { $0.count > 2 && $0[0] == "list" && $0[1] == m }?[2]
            let mine = named.flatMap { n in chain(m)?.list(n)?.devices.contains(r.pubkey) } ?? false
            let lists = Enc.peopleLists(r.tags.filter { $0.count > 2 && $0[0] == "list" }.map { (account: $0[1], id: $0[2]) })
            let held = Enc.HeldKey(K: K, k: r.content, conv: Enc.peopleId(people), mine: mine, service: r.pubkey == belfry || r.pubkey == groupsKey, lists: lists, at: r.createdAt)
            lock.lock(); let took = holdKey(KeyRec(held: held, people: people, rumor: Enc.rumorJSON(r))); lock.unlock()
            if took { changed = true }
        }
        if let c = chain(m), c.current.devices.contains(devicePub) {
            if firstN == 0 { firstN = c.current.n; engine.db.set("enc-first-n", firstN) }
            sayReads()
        }
        if takePacks() { changed = true }
        if changed { save(); onKeys?() }
    }

    /// An 8572 for me: its rumor when it opens and is accepted.
    public func open(_ e: NostrEvent) async -> Opened {
        guard let d = Enc.named(e) else { return .drop }
        lock.lock(); var K = byAlias[d]; lock.unlock()
        if K == nil { takeEnvelopes(); lock.lock(); K = byAlias[d]; lock.unlock() }
        guard let K, let key = (lock.withLock { keys[K] }) else {
            // its envelopes, asked by #d once a minute; "can't be read on this device" only after a
            // complete read found envelopes and none with my entry
            let r = lock.withLock { dRead[d] }
            if r == nil || Date().timeIntervalSince(r!.at) > 60 {
                lock.withLock { dRead[d] = (Date(), r?.found ?? false) }
                Task {
                    guard let got = await engine.queryPaged(.main, [["kinds": [Enc.key], "#p": [me], "#d": [d]]], timeout: 5) else { return }
                    _ = engine.add(got)
                    let mineIn = got.contains { env in ((try? Enc.openPeopleEnvelope(device: device, env)) ?? nil) != nil }
                    lock.withLock { dRead[d] = (Date(), !got.isEmpty && !mineIn) }
                    takeEnvelopes()
                }
            }
            return .keep(unreadable: r?.found ?? false)
        }
        guard let o = try? Enc.openPeopleMessage(k: key.held.k, e) else { return .drop }
        let v = Enc.acceptPeopleMessage(outer: e, seal: o.seal, rumor: o.rumor, keyPeople: key.held.conv, devices: devices(o.rumor.pubkey))
        if v == .wait {
            if readOnThisConnection(o.rumor.pubkey), let c = chain(o.rumor.pubkey), !c.gaps, !c.lists.contains(where: { $0.devices.contains(o.seal.pubkey) }) { return .drop }
            want([o.rumor.pubkey])
            return .keep(unreadable: false)
        }
        if v == .no { return .drop }
        lock.withLock { noteConv(key.held.conv, key.held.at) }
        return .rumor(o.rumor, conv: key.held.conv)
    }

    /// Is this people conversation encrypted here (§18.6), by its accounts.
    public func isEncrypted(_ accounts: [String]) -> Bool { lock.withLock { convs[Enc.peopleId(accounts)] != nil } }
    public func firstKeyAt(_ accounts: [String]) -> Int? { lock.withLock { convs[Enc.peopleId(accounts)] } }

    // ---- sending, people conversations -------------------------------------------------------

    /// §17.2 + §18.6: a conversation over 100 devices goes unencrypted only when it was never
    /// encrypted, known from a complete read of every envelope and message for me on this connection.
    private func neverEncrypted(_ conv: String) async -> Bool {
        if lock.withLock({ convs[conv] != nil }) { return false }
        guard let got = await engine.queryPaged(.main, [["kinds": [Enc.key, Enc.msg], "#p": [me]]], timeout: 8, maxPages: 100, total: 15) else { return false }
        _ = engine.add(got)
        takeEnvelopes()
        if got.contains(where: { e in Enc.named(e).map { d in lock.withLock { byAlias[d] == nil } } ?? false }) { return false }
        return lock.withLock { convs[conv] == nil }
    }

    /// The events that carry RUMOR to PEOPLE encrypted: a new key's envelopes first (or its
    /// unconfirmed ones again), then one copy per person. nil: not encrypted (a conversation that
    /// starts over 100 devices: no lock). Throws Held when it can't be encrypted now. MISSING:
    /// people with no device (§17.5). Never another account's key (§17.8), never backdated (§17.11).
    public func encrypt(_ rumor: NostrEvent, people: [String]) async throws -> (events: [NostrEvent], missing: [String])? {
        let m = me
        let all = Array(Set([m] + people)).sorted()
        if lock.withLock({ all.contains(where: world.unanswered.contains) }) { throw Held.noList(nil) }
        if all.contains(where: { isGuest($0) }) { if await neverEncrypted(Enc.peopleId(all)) { return nil }; throw Held.guest }
        guard Enc.peopleOf(rumor) == Enc.peopleId(all) else { throw Enc.Failure.notAMessage }
        guard Enc.rumorJSON(Enc.withId(rumor)).utf8.count <= Enc.maxRumor else { throw Enc.Failure.tooLong }
        let toRead = all.filter { a in devices(a) != .service && (!readOnThisConnection(a) || devices(a) == .unknown) }
        if !toRead.isEmpty, !(await readLists(toRead, timeout: 3)) { throw Held.noList(nil) }
        switch listedHere() { case .yes: break; case .full: throw Held.full; default: throw Held.notListed }
        var per = [(account: String, list: String?, devices: [String])]()
        for a in all {
            switch devices(a) {
            case .unknown: throw Held.noList(a)
            case .service: per.append((a, nil, [a]))
            case .chain(let c):
                if c.fork || c.invalidAbove { throw Held.fork(a) }
                per.append((a, c.current.id, Enc.receivers(c.current)))
            }
        }
        let missing = per.filter { $0.account != m && $0.devices.isEmpty }.map(\.account)
        let others = per.filter { $0.account != m }
        if !others.isEmpty, missing.count == others.count { throw Held.noDevice(missing[0]) }
        let total = per.reduce(0) { $0 + $1.devices.count }
        let conv = Enc.peopleId(all)
        if total > Enc.maxPeopleDevices { if await neverEncrypted(conv) { return nil }; throw Held.tooMany }
        let lists = Enc.peopleLists(per.compactMap { p in p.list.map { (account: p.account, id: $0) } })
        var out = [NostrEvent]()
        var key = lock.withLock { Enc.pickKey(keys.values.map(\.held), conv: conv, lists: lists).flatMap { keys[$0.K] } }
        if key == nil {
            let nk = Enc.newKey()
            let r = Enc.keyRumor(maker: devicePub, k: nk.k, people: per.map { ($0.account, $0.list) })
            let made = per.filter { !$0.devices.isEmpty }.map { (account: $0.account, devices: $0.devices) }
            let envs = try Enc.peopleEnvelopes(maker: device, rumor: r, people: made)
            let rec = KeyRec(held: Enc.HeldKey(K: nk.K, k: nk.k, conv: conv, mine: true, lists: lists, at: r.createdAt), people: all, rumor: Enc.rumorJSON(r),
                             unconfirmed: envs.map(\.id), madePer: made.map { Per(account: $0.account, devices: $0.devices) })
            lock.withLock { _ = holdKey(rec) }
            save()
            key = rec
            out += envs
        } else if let k = key, let ids = k.unconfirmed, !ids.isEmpty {
            // its envelopes not confirmed out: the SAME key's envelopes again with a fresh date (N1)
            let live = Set(engine.outboxItems().filter { $0.status == .queued }.compactMap { $0.signed?.id })
            if ids.contains(where: { !live.contains($0) }), let per = k.madePer, let rj = k.rumor, let r = try? Enc.rumor(rj) {
                let fresh = try Enc.peopleEnvelopes(maker: device, rumor: r, people: per.map { (account: $0.account, devices: $0.devices) })
                lock.withLock { keys[k.held.K]?.unconfirmed = fresh.map(\.id) }
                save()
                out += fresh
            }
        }
        let to = all.filter { !missing.contains($0) }
        out += try Enc.peopleMessage(device: device, rumor: rumor, K: key!.held.K, people: to, me: m)
        lock.withLock { noteConv(conv, key!.held.at) }
        return (out, missing)
    }

    /// The outbox took one of my envelopes out: confirmed.
    public func confirmed(_ id: String) {
        var changed = false
        lock.lock()
        for (K, k) in keys where k.unconfirmed?.contains(id) == true {
            var x = k
            x.unconfirmed = k.unconfirmed!.filter { $0 != id }
            if x.unconfirmed!.isEmpty { x.unconfirmed = nil }
            keys[K] = x
            changed = true
        }
        lock.unlock()
        if changed { save() }
    }

    // ---- private groups ------------------------------------------------------------------------

    public func groupEncrypts(_ h: String) -> Bool { lock.withLock { convs["g:" + h] != nil } || (writes3 && isPrivate(h)) }
    /// A link preview's picture in this group is encrypted (§23).
    public func previewEncrypted(_ h: String) -> Bool { groupMode(EventTemplate(kind: 9, content: "", tags: [["h", h]], createdAt: 0)) != .plain }
    public func clearInGroup(kind: Int, pubkey: String, tags: [Tag]) -> Bool { Enc.clearInGroup(kind: kind, pubkey: pubkey, tags: tags, groupsKey: groupsKey ?? "") }
    public func groupFirstAt(_ h: String) -> Int? { lock.withLock { convs["g:" + h] } }
    public func groupCantCheck(_ h: String) -> Bool { lock.withLock { cantCheck.contains(h) } }

    private func envelopes(_ h: String, _ K: String) -> [NostrEvent] {
        engine.snapshot().filter { $0.kind == Enc.key && $0.tag("h") == h && $0.hasTag("d", K) && $0.isValid }
    }
    private func judgeSet(_ h: String, _ rec: inout KeyRec, _ envs: [NostrEvent]) {
        if rec.held.mine && envs.isEmpty { return }
        let match = Enc.deviceSet(Enc.entryKeys(envs)) == rec.claimed
        rec.held.lists = match ? (rec.claimed ?? "") : ""
        lock.withLock { if match { cantCheck.remove(h) } else { cantCheck.insert(h) } }
    }
    /// The group key named by an 8572: held, or opened from the group's envelopes.
    private func groupKey(_ h: String, _ K: String) -> KeyRec? {
        if let held = lock.withLock({ keys[K] }) { return held.held.conv == "g:" + h ? held : nil }
        // every envelope that opens is judged: a decoy with the same d never hides the real key (§17.12)
        var got: Enc.GroupKey?
        for env in envelopes(h, K) {
            guard let g = try? Enc.openGroupEnvelope(device: device, env, group: h) else { continue }
            let v = Enc.acceptGroupKey(g, devices: devices(g.account))
            if v == .wait { want([g.account]); continue }
            if v == .ok { got = g; break }
        }
        guard let g = got else { return nil }
        let mine = chain(me)?.lists.contains { $0.devices.contains(g.maker) } ?? false
        var rec = KeyRec(held: Enc.HeldKey(K: K, k: g.k, conv: "g:" + h, mine: mine, service: g.account == groupsKey || g.account == belfry, lists: "", group: true, at: g.at), claimed: g.set)
        judgeSet(h, &rec, envelopes(h, K))
        lock.withLock { _ = holdKey(rec) }
        save()
        return rec
    }

    /// The private groups' 8572s opened: their rumors are the group's events (§6). Clear-list kinds and
    /// privileged labels found inside are dropped (§26).
    public func openGroupMessages() -> [NostrEvent] {
        var add = [NostrEvent]()
        for e in engine.snapshot() where e.kind == Enc.msg && !e.sig.isEmpty {
            if lock.withLock({ opened.contains(e.id) }) { continue }
            guard let h = e.tag("h"), let K = Enc.named(e), encryptedGroup(h), let key = groupKey(h, K) else { continue }
            guard let o = try? Enc.openGroupMessage(k: key.held.k, e) else { lock.withLock { _ = opened.insert(e.id) }; continue }
            let v = Enc.acceptGroupMessage(outer: e, seal: o.seal, rumor: o.rumor, group: h, devices: devices(o.rumor.pubkey))
            if v == .wait { want([o.rumor.pubkey]); continue }
            lock.withLock { _ = opened.insert(e.id) }
            guard v == .ok, !privileged(o.rumor) else { continue }
            lock.withLock { noteConv("g:" + h, key.held.at) }
            add.append(o.rumor)
        }
        if !add.isEmpty { save() }
        return add
    }
    private func privileged(_ r: NostrEvent) -> Bool {
        let L = r.kind == 1985 ? Enc.values(r.tags, "L") : []
        let service = r.pubkey == groupsKey || r.pubkey == belfry
        if !L.isEmpty && L.allSatisfy({ $0 == "belfry/action-result" }) && service { return false }
        if clearInGroup(kind: r.kind, pubkey: r.pubkey, tags: r.tags) { return true }
        guard r.kind == 1985, L.contains(where: { $0.hasPrefix("belfry/") }) else { return false }
        if L.allSatisfy({ $0 == "belfry/action" }) { return false }
        if L.allSatisfy({ ["belfry/pin", "belfry/inbox", "belfry/event-status", "belfry/proposal-status"].contains($0) }) { return false }
        return true
    }
    /// §17.2: a clear event in a private group after its first key, outside §16.9's list: never counts.
    public func refuseClear(_ e: NostrEvent) -> Bool {
        guard e.kind != Enc.key, e.kind != Enc.msg, !e.sig.isEmpty, let h = e.tag("h"), encryptedGroup(h),
              !clearInGroup(kind: e.kind, pubkey: e.pubkey, tags: e.tags), let f = groupFirstAt(h) else { return false }
        return e.createdAt >= f
    }

    /// §5 + §16.1 + §18.7 sending in a private group: the members' devices, the newest key whose entry
    /// set is exactly that device set (mine, or another member's), else a new key and its envelopes
    /// (signed by my account through the signer, sent BEFORE the message). nil: not a group write to wrap.
    public func wrapForGroup(_ t: EventTemplate) async throws -> (before: [EventTemplate], event: EventTemplate)? {
        guard let h = t.tags.first(where: { $0.count > 1 && $0[0] == "h" })?[1], groupEncrypts(h),
              !clearInGroup(kind: t.kind, pubkey: me, tags: t.tags), t.kind != Enc.key, t.kind != Enc.msg else { return nil }
        guard let got = await engine.queryAuthed(.groups, [["kinds": [39002], "#d": [h]]], timeout: 5) else { throw Held.cantCheckGroup }
        _ = engine.add(got)
        // the members from the 39002 just read, signed by the groups relay's own key (its NIP-11
        // pubkey: 39000–39002 are the relay's, not the groups key's), never an older copy (§8)
        guard let rk = await groupsRelayKey(), let members = EncEngine.membersFrom(got, group: h, relayKey: rk), members.contains(me)
        else { throw Held.cantCheckGroup }
        let people = Array(members.union([me])).sorted()
        let toRead = people.filter { a in devices(a) != .service && (!readOnThisConnection(a) || devices(a) == .unknown) }
        if !toRead.isEmpty, !(await readLists(toRead, timeout: 5)) { throw Held.cantCheckGroup }
        let none = people.filter { devices($0) == .unknown }
        if !none.isEmpty, !(await readLists(none, timeout: 5)) { throw Held.cantCheckGroup }
        guard listedHere() == .yes else { throw Held.notListed }
        var devs = [String](), lines = [(account: String, id: String)]()
        for a in people {
            switch devices(a) {
            case .unknown: continue
            case .service: devs.append(a)
            case .chain(let c):
                if isGuest(a) { continue }
                if c.fork || c.invalidAbove { throw Held.cantCheckGroup }
                devs += Enc.receivers(c.current)
                lines.append((a, c.current.id))
            }
        }
        if devs.count > Enc.maxGroupDevices { throw BelfryError.relay("error: Too many devices in this group to encrypt for everyone.") }
        let set = Enc.deviceSet(devs)
        var key = lock.withLock { Enc.pickKey(keys.values.map(\.held), conv: "g:" + h, lists: set).flatMap { keys[$0.K] } }
        if var k = key, k.claimed != nil, k.unconfirmedGroup == nil {
            judgeSet(h, &k, envelopes(h, k.held.K))
            lock.withLock { keys[k.held.K] = k }
            if !k.held.mine && k.held.lists != set { key = nil }
        }
        let now = Int(Date().timeIntervalSince1970)
        if key == nil {
            let nk = Enc.newKey()
            let envs = try Enc.groupEnvelopes(maker: device, k: nk.k, group: h, devices: devs, lists: Enc.listsHash(lines))
            let rec = KeyRec(held: Enc.HeldKey(K: nk.K, k: nk.k, conv: "g:" + h, mine: true, lists: set, group: true, at: now), claimed: set, unconfirmedGroup: envs.map(Tmpl.init))
            lock.withLock { _ = holdKey(rec) }
            save()
            key = rec
        }
        let before = (key!.unconfirmedGroup ?? []).map { var x = $0.template; x.createdAt = now; return x }
        let rumor = Enc.withId(NostrEvent(pubkey: me, createdAt: t.createdAt, kind: t.kind, tags: t.tags, content: t.content))
        let mentions = EncEngine.npubsIn(t.content)
        return (before, try Enc.groupMessage(device: device, rumor: rumor, K: key!.held.K, group: h, mentions: mentions))
    }
    static let npubRx = Rx("nostr:(npub1[02-9ac-hj-np-z]{58})")
    /// §17.14: the accounts a text mentions (nostr:npub…), for the outer p of a group 8572.
    static func npubsIn(_ text: String) -> [String] {
        var out = [String]()
        for m in npubRx.matches(text) { if let n = m[1], let h = Bech32.pubkey(npub: n), !out.contains(h) { out.append(h) } }
        return out
    }

    /// The members of group H from a read of 39002s: the newest valid one signed by RELAYKEY.
    public static func membersFrom(_ got: [NostrEvent], group h: String, relayKey: String) -> Set<String>? {
        guard let newest = got.filter({ $0.kind == 39002 && $0.tag("d") == h && $0.pubkey == relayKey && $0.isValid })
            .max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        return Set(Enc.values(newest.tags, "p").filter(Enc.isKey))
    }

    /// The groups relay's own key (NIP-11 `pubkey`), read once per relay address.
    private var relayKeys = [String: String]()
    public func setGroupsRelayKey(_ k: String) { lock.withLock { relayKeys[engine.config.groupsRelay] = k } }
    func groupsRelayKey() async -> String? {
        let url = engine.config.groupsRelay
        if let k = lock.withLock({ relayKeys[url] }) { return k }
        let http = url.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://")
        guard let u = URL(string: http) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 5)
        req.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let k = d["pubkey"] as? String, Enc.isKey(k) else { return nil }
        lock.withLock { relayKeys[url] = k }
        return k
    }

    /// The group key's envelopes went out: no longer sent again.
    public func groupBeforeOut(_ K: String) { lock.withLock { keys[K]?.unconfirmedGroup = nil }; save() }

    // ---- §7 a new device -----------------------------------------------------------------------

    private struct AskedRec: Codable { var at: Int; var devices: [String]; var id: String }
    private var asked: AskedRec?
    private var firstN = 0
    private var answeredHere = [String: String]()

    /// How many messages for me this device can't open (format-3 copies whose key it has no copy of).
    public func unresolvedCount() -> Int {
        engine.snapshot().filter { $0.kind == Enc.msg && $0.hasTag("p", me) }.filter { e in Enc.named(e).map { d in lock.withLock { byAlias[d] == nil } } ?? false }.count
    }
    public var askedAt: Int? { asked?.at }
    /// §7.3: ask my other devices for earlier messages. Again only after 24 h, or when another of my devices appeared.
    @discardableResult
    public func askForEarlier() throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        let mine = chain(me)?.current.devices ?? []
        if let a = asked, now - a.at < 86400, mine.allSatisfy({ a.devices.contains($0) }) { return false }
        let ev = try Enc.askEvent(device: device, account: me, at: now)
        engine.enqueueSigned(ev, target: .main, dm: nil)
        asked = AskedRec(at: now, devices: mine, id: ev.id)
        engine.db.set("enc-asked", asked)
        return true
    }

    /// §7.5: packs to this device from an older device of mine: keys kept to read with, never adopted for sending.
    private func takePacks() -> Bool {
        let m = me
        // a pack that arrives before this device is on my list waits (never marked seen before)
        guard let c = chain(m), !c.gaps, c.current.devices.contains(devicePub) else { return false }
        var changed = false
        var v1 = [(lb: String, secret: String)]()
        for e in engine.snapshot() where e.kind == Enc.pack && e.hasTag("d", devicePub) {
            if lock.withLock({ packSeen.contains(e.id) }) { continue }
            lock.withLock { _ = packSeen.insert(e.id) }
            guard let o = Enc.openPack(device: device, account: m, e, chain: c) else { continue }
            for k in o.keys {
                switch k {
                case .people(let r):
                    let people = Enc.values(r.tags, "p")
                    let held = Enc.HeldKey(K: r.tag("K") ?? "", k: r.content, conv: Enc.peopleId(people), mine: false,
                                           lists: Enc.peopleLists(r.tags.filter { $0.count > 2 && $0[0] == "list" }.map { (account: $0[1], id: $0[2]) }), at: r.createdAt)
                    if lock.withLock({ holdKey(KeyRec(held: held, people: people, rumor: Enc.rumorJSON(r))) }) { changed = true }
                case .group(let k, let K, let g):
                    if lock.withLock({ holdKey(KeyRec(held: Enc.HeldKey(K: K, k: k, conv: "g:" + g, mine: false, lists: "", group: true, at: e.createdAt))) }) { changed = true }
                case .v1(let s, let lb): v1.append((lb, s))
                }
            }
            changed = true
        }
        if !v1.isEmpty { onV1Secrets?(v1) }
        return changed
    }

    /// A device of mine that needs the card (§7.4, §17.6, §17.7, §17.9).
    public struct AddedDevice: Equatable, Sendable { public let device: String; public let at: Int; public let reader: Bool; public let ask: String?; public let gone: Bool }
    public func addedDevices() -> [AddedDevice] {
        guard let c = chain(me), firstN > 0, c.current.devices.contains(devicePub) else { return [] }
        let snap = engine.snapshot()
        var asks = [String: String]()
        for e in snap where e.kind == Enc.ask { if let a = Enc.readAsk(e, account: me, chain: c) { asks[a.device] = a.id } }
        for e in snap where e.kind == Enc.answer {
            let askId = e.tag("e")
            let about = askId.flatMap { id in asks.first { $0.value == id }?.key }
            if let a = Enc.readAnswer(e, account: me, chain: c, about: about), let d = a.device ?? about, answeredHere[d] == nil { answeredHere[d] = a.answer }
        }
        var out = [AddedDevice]()
        for ch in Enc.changes(c) where ch.n > firstN {
            let at = c.list(ch.list)?.createdAt ?? 0
            for d in ch.added where d != devicePub && c.current.devices.contains(d) && Enc.listedBefore(c, older: devicePub, device: d) && answeredHere[d] == nil {
                out.append(AddedDevice(device: d, at: at, reader: false, ask: asks[d], gone: false))
            }
            for d in ch.readersAdded where c.current.readers.contains(d) && answeredHere[d] == nil { out.append(AddedDevice(device: d, at: at, reader: true, ask: nil, gone: false)) }
        }
        return out
    }

    /// §7.5 Share: every key this device can open and its version-1 secrets, in packs; then the answer.
    public func share(with to: AddedDevice) async throws {
        // §17.9: only to a device still on my current list, and never to a reader
        guard await readLists([me], timeout: 5), let c = chain(me), c.current.devices.contains(to.device), !to.reader, !c.current.readers.contains(to.device) else {
            throw Held.noList(me)
        }
        if let got = await engine.queryPaged(.main, [["kinds": [Enc.key], "#p": [me]]], timeout: 8, maxPages: 100, total: 30) { _ = engine.add(got); takeEnvelopes() }
        var list = [Enc.PackKey]()
        for k in lock.withLock({ Array(keys.values) }) {
            if k.held.group { list.append(.group(k: k.held.k, K: k.held.K, group: String(k.held.conv.dropFirst(2)))) }
            else if let rj = k.rumor, let r = try? Enc.rumor(rj), Enc.values(r.tags, "p").contains(me) { list.append(.people(r)) }
        }
        for v in v1Provider() { list.append(.v1(secret: v.secret, lb: v.lb)) }
        for p in try Enc.packs(sharer: device, account: me, to: to.device, keys: list) { engine.enqueueSigned(p, target: .main, dm: nil) }
        try answer(to, "shared")
    }
    /// A reader's card seen (OK): gone on this device; no answer is sent.
    public func dismiss(_ device: String) {
        answeredHere[device] = "seen"
        engine.db.set("enc-answered", answeredHere)
    }

    /// §7.7 the answer, for every device of mine at once.
    public func answer(_ to: AddedDevice, _ what: String) throws {
        let ev = try Enc.answerEvent(device: device, account: me, to: to.ask.map { .ask($0) } ?? .device(to.device), what: what)
        engine.enqueueSigned(ev, target: .main, dm: nil)
        answeredHere[to.device] = what
        engine.db.set("enc-answered", answeredHere)
        onKeys?()
    }

    /// §17.7: warnings that don't go away: my lists forked, or an envelope holds an entry for a key never on my lists.
    public func listWarnings() -> (fork: Bool, strange: Int) {
        let c = chain(me)
        return ((c?.fork ?? false) || (c?.invalidAbove ?? false), lock.withLock { strangeEntries.count })
    }
    private func checkEntries(_ env: NostrEvent) {
        guard let c = chain(me), !c.gaps, let map = Enc.entries(env.content) else { return }
        let ever = Set(c.lists.flatMap { $0.devices + $0.readers })
        lock.withLock { for k in map.keys where Enc.isKey(k) && !ever.contains(k) { strangeEntries.insert(k) } }
    }

    /// §12: once on my list, this device says it reads format 3 (a 30078 signed by the device).
    private func sayReads() {
        guard engine.db.get("enc-said-reads", as: String.self) != devicePub,
              let ev = try? Enc.signWith(device, kind: 30078, createdAt: Int(Date().timeIntervalSince1970), tags: [["d", "belfry:device:reads"], ["v", "3"]], content: "") else { return }
        engine.enqueueSigned(ev, target: .main, dm: nil)
        engine.db.set("enc-said-reads", devicePub)
    }

    /// ACCOUNT's current list for the screens: devices and readers, when each first appeared.
    public func devicesOf(_ account: String) -> (devices: [String], readers: [String], since: [String: Int])? {
        switch devices(account) {
        case .unknown: return nil
        case .service: return ([account], [], [:])
        case .chain(let c):
            var since = [String: Int]()
            for l in c.lists { for d in l.devices + l.readers where since[d] == nil { since[d] = l.createdAt } }
            return (c.current.devices, c.current.readers, since)
        }
    }

    /// §16.6: removed by another device? GET /sessions/removed signed by this device's key; wiped
    /// only when also absent from my current list read on this connection. nil: not removed.
    public func checkRemoved() async -> (at: Int, by: String?)? {
        let url = engine.config.apiBase + "/sessions/removed"
        guard let auth = try? Enc.signWith(device, kind: 27235, createdAt: Int(Date().timeIntervalSince1970), tags: [["u", url], ["method", "GET"]], content: ""),
              let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.setValue("Nostr " + Data(auth.json.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], d["removed"] as? Bool == true else { return nil }
        guard await readLists([me], timeout: 5), let c = chain(me), !c.current.devices.contains(devicePub) else { return nil }
        let at = (d["at"] as? NSNumber)?.intValue ?? (d["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }.map { Int($0.timeIntervalSince1970) } ?? 0
        return (at, (d["by_name"] as? String).map { String($0.prefix(80)) })
    }
}
