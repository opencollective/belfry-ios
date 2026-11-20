import Foundation

// Sealed conversations (collective-belfry docs/sealed.md, version 1), wired to the relay: this
// device's part in its account's roster, whose conversations are sealed, the wraps to send and
// how an arriving one opens. The letterbox secrets live in `SealedKeyStore` (the Keychain in the
// app), never in the database and never in a log.

public protocol SealedKeyStore: AnyObject, Sendable {
    func load() -> KeyChain
    func save(_ chain: KeyChain)
    func wipe()
}

public final class MemoryKeyStore: SealedKeyStore, @unchecked Sendable {
    private var chain = KeyChain()
    public init() {}
    public func load() -> KeyChain { chain }
    public func save(_ c: KeyChain) { chain = c }
    public func wipe() { chain = KeyChain() }
}

/// What this device remembers about sealed conversations (database kv `sealed-state`; no secret).
struct SealedMemory: Codable {
    /// Per person: the root first accepted.
    var pins = [String: String]()
    /// Per person: the last valid head seen (where to seal when their chain is not ready any more).
    var heads = [String: Head]()
    /// Sealed conversations → when this device first saw them sealed.
    var sealed = [String: Int]()
    /// People who started fresh: account → [root → when], for the amber line; `shared`: done.
    var resets = [String: [Reset]]()
    /// My account's roots before the pinned one (their devices may still hand keys over).
    var oldRoots = [String]()
    var lastRequest = 0
    /// The secret of the login link this device signed in from.
    var link: String?

    struct Head: Codable { var lb: String; var devices: [String] }
    struct Reset: Codable, Hashable { var root: String; var at: Int; var shared: Bool }
}

public final class SealedEngine: @unchecked Sendable {
    public enum Mine: Sendable { case none, inside, waiting }

    /// A new device asking to be let in (the Allow prompt).
    public struct Ask: Hashable, Sendable, Identifiable {
        public let id: String
        public let device: String
        public let name: String
        public let at: Int
    }

    let engine: SyncEngine
    let device: Data
    public let devicePub: String
    let store: SealedKeyStore
    private let lock = NSLock()
    private var keys: KeyChain
    private var memory: SealedMemory
    private var chains: (version: Int, anchors: [String: NostrEvent], rosters: [String: [NostrEvent]], cache: [String: RosterChain?])?
    private var shownLinks = [(secret: String, at: Int)]()
    private var denied = Set<String>()
    private var working = false
    private var sessionName: String?
    private var handled = Set<String>()
    /// The mail bridge's key: the one seal signer that is not a device (sealed.md 7).
    public var bridge: (() -> String?)?
    /// GET /api/me/sessions; nil when it could not be read.
    public var sessions: (() async -> [SessionInfo]?)?
    /// POST /api/me/sessions/revoke, by the session's bunker key.
    public var revoke: ((String) async -> Bool)?
    /// This device's own name and kind for `belfry:devices`.
    public var myName: (() -> Sealed.DeviceName)?
    public var onChange: (() -> Void)?
    /// New keys came: the wraps kept locked can be tried again.
    public var onKeys: (() -> Void)?

    public init?(engine: SyncEngine, deviceSecret: Data, store: SealedKeyStore) {
        guard let pub = try? Keys.publicKeyHex(secret: deviceSecret) else { return nil }
        self.engine = engine
        device = deviceSecret
        devicePub = pub
        self.store = store
        keys = store.load()
        memory = engine.db.get("sealed-state", as: SealedMemory.self) ?? SealedMemory()
        engine.sealedDevice = pub
    }

    var me: String { engine.me }

    /// Whether an arriving event is this engine's business (rosters, anchors, requests, my device
    /// names, key hand-overs).
    public static func concerns(_ e: NostrEvent) -> Bool {
        e.kind == SealedKind.roster || e.kind == SealedKind.request
            || (e.kind == 30078 && (e.tag("d") == SealedKind.anchorD || e.tag("d") == SealedKind.devicesD))
    }

    private func remember(_ change: (inout SealedMemory) -> Void) {
        lock.lock()
        change(&memory)
        let m = memory
        lock.unlock()
        engine.db.set("sealed-state", m)
    }

    public func setLink(_ secret: String?) { remember { $0.link = secret } }

    /// A fresh secret for the QR of "Link a phone or tablet": remembered for 15 minutes.
    public func newLinkSecret(now: Int = .now) -> String {
        let s = Crypto.random(32).hex
        lock.lock()
        shownLinks = shownLinks.filter { now - $0.at < 900 } + [(s, now)]
        lock.unlock()
        return s
    }

    // ---- chains --------------------------------------------------------------------------------------

    private func index() -> (anchors: [String: NostrEvent], rosters: [String: [NostrEvent]]) {
        let v = engine.version
        lock.lock()
        if let c = chains, c.version == v { lock.unlock(); return (c.anchors, c.rosters) }
        lock.unlock()
        var anchors = [String: NostrEvent](), rosters = [String: [NostrEvent]]()
        for e in engine.snapshot() {
            if e.kind == SealedKind.roster, let p = e.tag("p") { rosters[p, default: []].append(e) }
            else if e.kind == 30078, e.tag("d") == SealedKind.anchorD {
                if let old = anchors[e.pubkey], (old.createdAt, e.id) > (e.createdAt, old.id) { continue }
                anchors[e.pubkey] = e
            }
        }
        lock.lock(); chains = (v, anchors, rosters, [:]); lock.unlock()
        return (anchors, rosters)
    }

    /// ACCOUNT's valid chain, from the events held here (signatures were checked when stored).
    public func chain(_ account: String) -> RosterChain? {
        let (anchors, rosters) = index()
        lock.lock()
        if let hit = chains?.cache[account] { lock.unlock(); return hit }
        lock.unlock()
        let c = RosterChain.resolve(account: account, anchor: anchors[account], rosters: rosters[account] ?? [], verify: false)
        lock.lock(); chains?.cache[account] = .some(c); lock.unlock()
        return c
    }

    public var mine: Mine {
        guard let c = chain(me) else { return .none }
        return c.devices.contains(devicePub) ? .inside : .waiting
    }

    /// Every roster of my account's chains this device knows: the current one and the roots before it.
    private func myDevicesEver() -> Set<String> {
        let (_, rosters) = index()
        var out = Set(chain(me)?.rosters.flatMap(\.devices) ?? [])
        lock.lock(); let old = memory.oldRoots; lock.unlock()
        guard !old.isEmpty else { return out }
        let mineAll = rosters[me] ?? []
        for root in old {
            // the old chain, read from its root as if its anchor still stood
            var cur = mineAll.compactMap(Roster.init).first { $0.id == root }
            while let c = cur {
                out.formUnion(c.devices)
                cur = mineAll.compactMap(Roster.init).filter { $0.prev == c.id && c.devices.contains($0.signer) }.min { $0.id.lowercased() < $1.id.lowercased() }
            }
        }
        return out
    }

    /// Pins, last heads and fresh starts, from the chains as they are now. Call when rosters or
    /// anchors arrive.
    public func observe(_ accounts: [String], now: Int = .now) {
        var changed = false
        for a in Set(accounts) {
            guard let c = chain(a) else { continue }
            lock.lock()
            let pin = memory.pins[a], head = memory.heads[a]
            lock.unlock()
            if pin == nil {
                remember { $0.pins[a] = c.root.id }
            } else if pin != c.root.id {
                // the anchor names another root: the person started fresh
                remember { m in
                    m.pins[a] = c.root.id
                    if a == self.me, let pin { m.oldRoots.append(pin) }
                    else { m.resets[a, default: []].append(.init(root: c.root.id, at: c.root.createdAt, shared: false)) }
                }
                changed = true
            }
            if head?.lb != c.lb || head?.devices != c.devices {
                remember { $0.heads[a] = .init(lb: c.lb, devices: c.devices) }
                changed = true
            }
        }
        if changed { onChange?() }
    }

    // ---- which conversations are sealed -----------------------------------------------------------------

    /// The people of a Nostr conversation (never an e-mail thread), me included.
    static func people(_ conv: String, me: String) -> [String]? {
        let peers = MailThreads.peers(conv)
        guard !peers.isEmpty, peers.allSatisfy(isHex64) else { return nil }
        return Array(Set(peers + [me])).sorted()
    }

    /// Whether CONV is sealed: remembered once true; else true as soon as every participant, me
    /// included, has a ready chain (sealed.md 6).
    public func isSealed(_ conv: String, now: Int = .now) -> Bool {
        lock.lock(); let known = memory.sealed[conv] != nil; lock.unlock()
        if known { return true }
        guard let people = SealedEngine.people(conv, me: me), people.allSatisfy({ chain($0)?.ready == true }) else { return false }
        remember { $0.sealed[conv] = now }
        observe(people, now: now)
        return true
    }

    public func sealedSince(_ conv: String) -> Int? { lock.lock(); defer { lock.unlock() }; return memory.sealed[conv] }

    /// My own mail is sealed as soon as my chain is ready.
    public var mailSealed: Bool { chain(me)?.ready == true }

    /// Where to seal for ACCOUNT: its head, or the last valid head this device knew.
    func letterbox(_ account: String) -> String? {
        if let c = chain(account) { return c.lb }
        lock.lock(); defer { lock.unlock() }
        return memory.heads[account]?.lb
    }

    /// The wraps of RUMOR for a sealed conversation: one per participant's letterbox and one to my
    /// own. No signer call. Throws when this device may not write (it is not in my head).
    public func wraps(_ rumor: NostrEvent, to: [String], selfCopy: Bool = true) throws -> [NostrEvent] {
        guard mine == .inside else { throw BelfryError.invalid("You can write here once this device is allowed.") }
        var targets = [String]()
        for p in to + (selfCopy ? [me] : []) where !targets.contains(p) { targets.append(p) }
        return try targets.map { p in
            guard let lb = letterbox(p) else { throw BelfryError.invalid("This conversation can't be locked for everyone yet. Try again.") }
            return try Sealed.wrap(rumor, device: device, to: p, lb: lb)
        }
    }

    /// An e-mail on its way out: sealed by the device to the belfry's key (sealed.md 7).
    public func mailWrap(_ rumor: NostrEvent, bridge b: String) throws -> NostrEvent {
        let json = rumor.json
        guard json.utf8.count <= Sealed.maxRumorBytes else { throw BelfryError.invalid("This e-mail is too long to send.") }
        guard let bp = Data(hex: b) else { throw BelfryError.crypto("bad key") }
        let seal = try NostrEvent(pubkey: "", createdAt: GiftWrap.backdate(), kind: 13, tags: [],
                                  content: NIP44.encrypt(json, conversationKey: NIP44.conversationKey(secret: device, publicKey: bp))).signed(with: device)
        let one = Keys.generateSecret()
        return try NostrEvent(pubkey: "", createdAt: GiftWrap.backdate(), kind: 1059, tags: [["p", b]],
                              content: NIP44.encrypt(seal.json, conversationKey: NIP44.conversationKey(secret: one, publicKey: bp))).signed(with: one)
    }

    // ---- opening -------------------------------------------------------------------------------------------

    public enum Outcome: Sendable {
        case rumor(NostrEvent)
        /// Shared history: the rumors, and who shared them.
        case shared([NostrEvent], by: String)
        /// Locked here, or its author's chain is not loaded yet: keep the wrap, try again later.
        case keep
        case drop
    }

    /// Whether this device holds a wrap it has no secret for (the banner).
    public func isLocked(_ wrap: NostrEvent) -> Bool {
        guard let lb = Sealed.lb(of: wrap) else { return false }
        lock.lock(); defer { lock.unlock() }
        return keys.secret(lb) == nil
    }

    public func open(_ wrap: NostrEvent) -> Outcome {
        lock.lock(); let k = keys; lock.unlock()
        switch Sealed.open(wrap, keys: k) {
        case .invalid: return .drop
        case .locked: return .keep
        case .opened(let rumor, let seal):
            // a mail from the belfry: its seal is signed by the belfry's key
            if let b = bridge?(), seal == b, rumor.pubkey == b { return .rumor(rumor) }
            guard let c = chain(rumor.pubkey) else { return .keep }
            guard c.accepts(device: seal, rumorAt: rumor.createdAt) else { return .drop }
            if rumor.kind == SealedKind.history {
                // each rumor's conversation must have the sharer in it
                let sharer = rumor.pubkey
                let ok = Sealed.sharedRumors(rumor).filter { r in
                    r.kind == 14 && (r.pubkey == sharer || r.tagValues("p").contains(sharer)) && (r.pubkey == me || r.tagValues("p").contains(me))
                }
                return .shared(ok, by: sharer)
            }
            return .rumor(rumor)
        }
    }

    /// A delivery report sealed to my letterbox (7679 with `lb`): its text.
    public func openReport(_ e: NostrEvent) -> String? {
        guard let lb = e.tag("lb"), let eph = e.tag("ephemeral-pubkey"), let p = Data(hex: eph) else { return nil }
        lock.lock(); let s = keys.secret(lb); lock.unlock()
        guard let s, let k = try? NIP44.conversationKey(secret: s, publicKey: p) else { return nil }
        return try? NIP44.decrypt(e.content, conversationKey: k)
    }

    /// Key hand-overs addressed to this device (sealed.md 5.5). True when new keys came.
    @discardableResult
    public func takeKeys() -> Bool {
        let wraps = engine.snapshot().filter { $0.kind == 1059 && $0.hasTag("p", devicePub) }
        lock.lock(); let todo = wraps.filter { !handled.contains($0.id) }; lock.unlock()
        guard !todo.isEmpty else { return false }
        let mineEver = myDevicesEver()
        var got = false
        for w in todo {
            guard let h = Sealed.openKeys(w, device: device), h.account == me else { lock.lock(); handled.insert(w.id); lock.unlock(); continue }
            // its giver's roster may not be here yet: tried again next time
            guard mineEver.contains(h.giver) else { continue }
            lock.lock()
            if keys.merge(h.keys) { got = true }
            handled.insert(w.id)
            let k = keys
            lock.unlock()
            if got { store.save(k) }
        }
        if got { onKeys?(); onChange?() }
        return got
    }

    // ---- this device's part (sealed.md 5 and 6) ------------------------------------------------------------

    private func publish(_ t: EventTemplate) throws -> NostrEvent {
        let e = try t.event(pubkey: "").signed(with: device)
        engine.add([e], verify: false)
        engine.enqueueSigned(e, target: .main, dm: nil)
        return e
    }

    private func publishAsAccount(_ t: EventTemplate) async throws {
        let e = try await engine.signer.sign(t)
        engine.add([e], verify: false)
        engine.enqueueSigned(e, target: .main, dm: nil)
    }

    private static func counted(_ sessions: [SessionInfo], now: Int) -> [String] {
        // counted: a chat client last active less than 30 days ago (created, when never active)
        sessions.filter { s in s.chat && ((SessionInfo.time(s.lastActivity) ?? SessionInfo.time(s.createdAt)).map { now - $0 < 30 * 86400 } ?? false) }.compactMap(\.clientPubkey)
    }

    private func writeNames(_ c: RosterChain, gone: [String: Int] = [:]) async {
        guard var name = myName?() else { return }
        // its own name is the `device` of its own session row: what the Allow prompt showed
        lock.lock(); let listed = sessionName; lock.unlock()
        if let listed, !listed.isEmpty { name.name = String(listed.prefix(60)) }
        lock.lock(); let k = keys; lock.unlock()
        let old = engine.snapshot().filter { $0.kind == 30078 && $0.pubkey == me && $0.tag("d") == SealedKind.devicesD }.max { $0.createdAt < $1.createdAt }
        let doc = old.flatMap { Sealed.deviceNames($0, keys: k) }
        let has = Sealed.names(in: doc)[devicePub]
        if old?.tag("lb") == c.lb, has?.name == name.name, has?.kind == name.kind { return }
        let next = Sealed.deviceDoc(doc, device: devicePub, entry: name, gone: gone)
        if let t = try? Sealed.devicesTemplate(next, lb: c.lb, keys: k) { try? await publishAsAccount(t) }
    }

    /// My devices' names, from `belfry:devices`.
    public func deviceNames() -> [String: Sealed.DeviceName] {
        lock.lock(); let k = keys; lock.unlock()
        let e = engine.snapshot().filter { $0.kind == 30078 && $0.pubkey == me && $0.tag("d") == SealedKind.devicesD }.max { $0.createdAt < $1.createdAt }
        return Sealed.names(in: e.flatMap { Sealed.deviceNames($0, keys: k) })
    }

    /// The first device (5.1) or a fresh start (5.4): a new letterbox, a root with this device, the anchor.
    private func startChain(counted: [String]) async {
        lock.lock()
        var k = keys
        guard let lb = try? k.make() else { lock.unlock(); return }
        keys = k
        lock.unlock()
        store.save(k)
        let ready = counted.allSatisfy { $0 == devicePub }
        guard let root = try? publish(RosterChain.template(account: me, n: 1, prev: nil, lb: lb, devices: [devicePub], ready: ready)) else { return }
        try? await publishAsAccount(RosterChain.anchor(root: root.id))
        if let c = chain(me) { await writeNames(c) }
    }

    /// The upkeep of my account's chain. Call after the main relay answered, when rosters, anchors
    /// or requests arrive, and every 6 hours. `removing`: a device the user removes now.
    public func maintain(now: Int = .now) async {
        if engine.localOnly || engine.guestMode.reading { return }
        lock.lock()
        if working { lock.unlock(); return }
        working = true
        lock.unlock()
        defer { lock.lock(); working = false; lock.unlock() }
        takeKeys()
        observe([me], now: now)
        guard let sessions = await sessions?() else { return }
        let live = Set(sessions.compactMap(\.clientPubkey))
        lock.lock(); sessionName = sessions.first { $0.clientPubkey == devicePub }?.device; lock.unlock()
        // only a session the belfry lists as a chat client takes part
        guard sessions.contains(where: { $0.clientPubkey == devicePub && $0.chat }) else { return }
        let counted = SealedEngine.counted(sessions, now: now)
        guard let c = chain(me) else {
            // no anchor for my account, asked from the relay itself (never from a cold store)
            guard let found = await engine.queryComplete(.main, [["kinds": [30078], "authors": [me], "#d": [SealedKind.anchorD]]]), found.isEmpty else { return }
            await startChain(counted: counted)
            onChange?()
            return
        }
        if !c.devices.contains(devicePub) {
            // nobody of the head has a live session: start fresh (5.4); else ask (5.2), every 24 h
            if !c.devices.contains(where: live.contains) {
                await startChain(counted: counted)
            } else {
                lock.lock(); let last = memory.lastRequest, link = memory.link; lock.unlock()
                if now - last >= 86400, (try? publish(Sealed.request(account: me, device: devicePub, link: link, now: now))) != nil {
                    remember { $0.lastRequest = now }
                }
            }
            onChange?()
            return
        }
        // a device whose session is gone leaves (5.6), after a random wait and a second look
        let gone = c.devices.filter { $0 != devicePub && !live.contains($0) }
        if !gone.isEmpty {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 0...60) * 1_000_000_000)
            if let again = chain(me), again.head.id == c.head.id { await drop(Set(gone), from: again) }
            onChange?()
            return
        }
        // a request with the proof of a code this device showed is allowed at once (5.2)
        lock.lock(); let secrets = shownLinks.filter { now - $0.at < 900 }.map(\.secret); lock.unlock()
        for r in requests(c, sessions) where Sealed.linked(r.event, secrets: secrets) {
            await allow(r.event.pubkey)
            return
        }
        if !c.ready, counted.allSatisfy(c.devices.contains) {
            _ = try? publish(RosterChain.template(account: me, n: c.head.n + 1, prev: c.head.id, lb: c.lb, devices: c.devices, ready: true, now: now))
            onChange?()
        }
        await writeNames(c)
    }

    private func requests(_ c: RosterChain, _ sessions: [SessionInfo]) -> [(event: NostrEvent, session: SessionInfo)] {
        lock.lock(); let no = denied; lock.unlock()
        var seen = Set<String>()
        return engine.snapshot().filter { $0.kind == SealedKind.request && $0.hasTag("p", me) }.sorted { $0.createdAt > $1.createdAt }.compactMap { e -> (event: NostrEvent, session: SessionInfo)? in
            guard !c.devices.contains(e.pubkey), !no.contains(e.pubkey), seen.insert(e.pubkey).inserted,
                  let s = sessions.first(where: { $0.clientPubkey == e.pubkey && $0.chat }) else { return nil }
            return (e, s)
        }
    }

    /// The new devices waiting for an answer on this device (the Allow prompt); none unless this
    /// device is in my head.
    public func asks() async -> [Ask] {
        guard let c = chain(me), c.devices.contains(devicePub), let sessions = await sessions?() else { return [] }
        return requests(c, sessions).map { r in
            let n = r.session.device.flatMap { $0.isEmpty ? nil : $0 } ?? (r.session.applicationName.isEmpty ? "A new device" : r.session.applicationName)
            return Ask(id: r.event.pubkey, device: r.event.pubkey, name: n, at: r.event.createdAt)
        }
    }

    /// Allow: the keys go to the new device, then roster n+1 with it (same letterbox).
    @discardableResult
    public func allow(_ newDevice: String, now: Int = .now) async -> Bool {
        guard let c = chain(me), c.devices.contains(devicePub) else { return false }
        if c.devices.contains(newDevice) { return true } // another device answered first
        guard c.devices.count < SealedKind.maxDevices else { return false }
        lock.lock(); let k = keys; lock.unlock()
        guard let w = try? Sealed.keysWrap(k, account: me, device: device, to: newDevice) else { return false }
        engine.enqueueSigned(w, target: .main, dm: nil)
        let counted = (await sessions?()).map { SealedEngine.counted($0, now: now) } ?? []
        let devices = c.devices + [newDevice]
        let ready = !counted.isEmpty && counted.allSatisfy(devices.contains)
        guard (try? publish(RosterChain.template(account: me, n: c.head.n + 1, prev: c.head.id, lb: c.lb, devices: devices, ready: ready, now: now))) != nil else { return false }
        onChange?()
        return true
    }

    /// Not me: that session is revoked. No roster change.
    public func deny(_ newDevice: String) async -> Bool {
        guard let s = await sessions?()?.first(where: { $0.clientPubkey == newDevice }) else { return false }
        guard await revoke?(s.bunkerPubkey) == true else { return false }
        lock.lock(); denied.insert(newDevice); lock.unlock()
        onChange?()
        return true
    }

    /// A device leaves: a new letterbox, its secret to each device that stays, roster n+1 without it.
    private func drop(_ gone: Set<String>, from c: RosterChain, now: Int = .now) async {
        let stay = c.devices.filter { !gone.contains($0) }
        guard stay.contains(devicePub) else { return }
        lock.lock()
        var k = keys
        guard let lb = try? k.make() else { lock.unlock(); return }
        keys = k
        lock.unlock()
        store.save(k)
        for d in stay where d != devicePub {
            if let w = try? Sealed.keysWrap(k, account: me, device: device, to: d) { engine.enqueueSigned(w, target: .main, dm: nil) }
        }
        guard (try? publish(RosterChain.template(account: me, n: c.head.n + 1, prev: c.head.id, lb: lb, devices: stay, ready: false, now: now))) != nil else { return }
        if let next = chain(me) { await writeNames(next, gone: Dictionary(uniqueKeysWithValues: gone.map { ($0, now) })) }
    }

    /// The user removes one of their devices: its session is revoked, then it leaves the roster.
    public func remove(_ gone: String) async -> Bool {
        guard let c = chain(me), c.devices.contains(devicePub), gone != devicePub else { return false }
        if let s = await sessions?()?.first(where: { $0.clientPubkey == gone }), await revoke?(s.bunkerPubkey) != true { return false }
        if c.devices.contains(gone) { await drop([gone], from: c) }
        onChange?()
        return true
    }

    /// Signing out: this device's keys go.
    public func wipe() {
        store.wipe()
        lock.lock(); keys = KeyChain(); lock.unlock()
        engine.db.remove("sealed-state")
    }

    // ---- what the screens show --------------------------------------------------------------------------------

    public struct Notice: Hashable, Sendable {
        public let id: String
        public let who: String
        public let at: Int
        public let added: Bool
        /// The person started fresh (the amber line) and nobody shared history yet.
        public let fresh: Bool
        public let device: String
    }

    /// The device lines of CONV: every roster step of its people since it was sealed here, and
    /// the fresh starts.
    public func notices(_ conv: String) -> [Notice] {
        guard let since = sealedSince(conv), let people = SealedEngine.people(conv, me: me) else { return [] }
        lock.lock(); let resets = memory.resets; lock.unlock()
        var out = [Notice]()
        for p in people {
            for ch in chain(p)?.changes ?? [] where ch.at >= since {
                out.append(Notice(id: ch.roster + ch.device, who: p, at: ch.at, added: ch.added, fresh: false, device: ch.device))
            }
            for r in resets[p] ?? [] { out.append(Notice(id: "fresh:" + r.root, who: p, at: r.at, added: true, fresh: !r.shared, device: "")) }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// Share history (sealed.md 8): RUMORS of the conversation, oldest first, to PERSON's new head.
    public func share(_ rumors: [NostrEvent], with person: String, notice: String) throws {
        guard mine == .inside, let lb = letterbox(person) else { throw BelfryError.invalid("It can't be shared just now. Try again.") }
        for part in Sealed.history(rumors, sharer: me, person: person) {
            engine.enqueueSigned(try Sealed.wrap(part, device: device, to: person, lb: lb), target: .main, dm: nil)
        }
        remember { m in
            m.resets[person] = (m.resets[person] ?? []).map { r in
                var r = r
                if "fresh:" + r.root == notice { r.shared = true }
                return r
            }
        }
        onChange?()
    }
}
