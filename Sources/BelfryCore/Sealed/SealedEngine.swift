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

/// Where the bytes of one account's key chain are kept (the Keychain in the app).
public protocol RawSecretStore: AnyObject, Sendable {
    func read() -> Data?
    /// False when the store refused the write.
    func write(_ data: Data) -> Bool
    func delete()
}

/// A key chain that belongs to an account: stored with its owner, and neither read nor written
/// before the account's key is known. (A signer that learns its key late starts with ""; a chain
/// saved under "" would be thrown away by the next start, and then overwritten: every secret lost.)
public final class OwnedKeyStore: SealedKeyStore, @unchecked Sendable {
    private struct Stored: Codable { var account: String; var keys: [String: String] }
    private let raw: RawSecretStore
    private let owner: () -> String
    private let lock = NSLock()
    /// The store refused a write: the keys live only in memory until one works.
    public private(set) var failed = false

    public init(raw: RawSecretStore, owner: @escaping () -> String) { self.raw = raw; self.owner = owner }

    public func load() -> KeyChain {
        let me = owner()
        guard isHex64(me), let data = raw.read(), let s = try? JSONDecoder().decode(Stored.self, from: data), s.account == me else { return KeyChain() }
        return KeyChain(keys: s.keys)
    }

    public func save(_ chain: KeyChain) {
        let me = owner()
        // never before the account is known; never over another account's chain with less
        guard isHex64(me), let data = try? JSONEncoder().encode(Stored(account: me, keys: chain.keys)) else { return }
        let ok = raw.write(data)
        lock.lock(); failed = !ok; lock.unlock()
    }

    public func wipe() { raw.delete() }
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
    /// Per person: what this device remembers of their chain (root, head and its path, what was
    /// seen anchored, and for my own account who is trusted after a switch). `SealedFollow`.
    var pins = [String: SealedPin]()
    /// Per person: the last valid head seen (where to seal when their chain is not ready any more).
    var heads = [String: Head]()
    /// Sealed conversations → when this device first saw them sealed.
    var sealed = [String: Int]()
    /// People who started fresh: account → [root → when], for the amber line; `shared`: done.
    var resets = [String: [Reset]]()
    /// My account's roots before the pinned one (their devices may still hand keys over).
    var oldRoots = [String]()
    var lastRequest = 0
    /// Requests of head devices already answered with the keys (kept: a restart answers none twice).
    var answeredRequests = [String]()
    /// Per device: when this device last handed it the key chain.
    var handed = [String: Int]()

    struct Head: Codable { var lb: String; var devices: [String] }
    /// Since when this device is in my head without the key.
    var waitingSince: Int?
    struct Reset: Codable, Hashable { var root: String; var at: Int; var shared: Bool }
    /// My account was started fresh by another device while this one was in the head (the
    /// attacker-after-the-e-mail-code case): shown until the person answers.
    var foreignFresh: ForeignFresh?
    struct ForeignFresh: Codable, Hashable { var root: String; var at: Int; var device: String }
    /// The roots whose head this device, coming back from an older root, already gave its old key
    /// chain to (the device that allowed it back; sealed.md 5.4), once each.
    var handedBack: [String]?
    /// "‹device› was added" notices (sealed.md 5.2 step 2a): only rosters dated from here on
    /// (when this device first ran with them) raise one; and the devices the person answered
    /// ("It was me"), or for which this device itself showed the prompt or a link code.
    var noticeSince: Int?
    var noticeDone: [String]?
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
    /// Devices whose add without a prompt did not go through in this run: the Allow card takes over.
    private var autoFailed = Set<String>()
    /// Tests of the Allow card turn the add without a prompt off (they exercise the path that
    /// stays for the undecidable case).
    var autoAdd = true
    private var sessionName: String?
    /// The secret of the login link this device signed in from: in memory only, never stored.
    private var link: String?
    /// After `wipe()` (signing out) nothing is saved or published any more, whatever was under way.
    private var closed = false
    /// Wraps kept for an author whose chain did not accept them: wrap → that author's head then
    /// ("" = none). Tried again only when the head changed.
    private var waiting = [String: String]()
    /// Devices this run handed the key chain to.
    private var given = Set<String>()
    /// The connection on which the relay last answered completely about my own anchor and rosters.
    private var mineSeenOn: String?
    /// The reads of my own chain: how many were begun, and the number of the last one that the
    /// relay answered completely. A wrap to a letterbox this device does not know is judged only
    /// against a read begun AFTER the wrap was first seen here (never an older one).
    private var mineReadsBegun = 0
    private var mineReadDone = 0
    private var unknownSeen = [String: Int]()
    private var rereadAt = 0
    private var rereadPending = false
    /// My own chain was read again while wraps to an unknown letterbox were kept: open them again.
    public var onMineRead: (() -> Void)?

    // ---- why a device did or did not ask (Diagnostics; the lead, 2026-11-22: an iPhone signed in
    // for eight minutes never sent its request and showed nothing) ---------------------------------

    /// One upkeep pass, step by step: nil = not reached.
    public struct UpkeepReport: Hashable, Sendable {
        public var at = 0
        /// The community relay answered after AUTH on this connection.
        public var relayAnswered: Bool?
        /// My anchor and rosters were read completely (an authenticated question, 3 s).
        public var chainRead: Bool?
        /// The belfry's session list answered.
        public var sessions: Bool?
        /// It lists this device's own chat session.
        public var listsMe: Bool?
        /// This device is in my head (false: it must ask).
        public var inHead: Bool?
        /// The request (8562) was published in this pass.
        public var asked: Bool?
        /// A request of this device is still in the outbox (not on the relay yet).
        public var requestWaiting: Bool?
        /// The relay refused this device's request for good: what it said (asked again at once).
        public var requestRefused: String?
        /// The session list as it answered: how many sessions, how many are the belfry's chat
        /// clients, how many carry a device key, and whether this device's key is among them
        /// (one screenshot tells why "in the session list" says no).
        public var sessionCount: Int?
        public var chatSessions: Int?
        public var keyedSessions: Int?
        public var keyListed: Bool?
        /// My head as this device reads it: how many devices.
        public var headDevices: Int?
        /// The waiting request in the outbox: how often it was tried and what the relay last said.
        public var requestTries: Int?
        public var requestError: String?
        /// A request was made earlier and is no longer in the outbox: the relay took it.
        public var requestLeft: Bool?
        public var failed: Bool {
            relayAnswered == false || chainRead == false || sessions == false || listsMe == false || asked == false || requestWaiting == true
        }
    }

    private var report = UpkeepReport()
    private var failures = 0
    private var retryAt: Int?
    private var retryTask: Task<Void, Never>?
    /// Seconds before the next try after 1, 2, 3… failed passes (the last one repeats).
    var retryDelays: [Double] = [5, 10, 20, 40, 80, 160, 300]
    /// A pass failed on a precondition and its retry is due: the app runs its upkeep again.
    public var onRetry: (() -> Void)?

    /// The last pass, when the request last left (0: never), the failed passes in a row, and when
    /// the next try is due.
    public var upkeepState: (report: UpkeepReport, lastRequest: Int, failures: Int, retryAt: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (report, memory.lastRequest, failures, retryAt)
    }

    /// My own chain was read completely at least once in this run.
    public var mineRead: Bool { lock.lock(); defer { lock.unlock() }; return mineReadDone > 0 }

    /// A sealed wrap this device has no secret for whose letterbox it does not know (yet): my
    /// chain was not read, or the letterbox is newer than what was read.
    public func isUnknown(_ wrap: NostrEvent) -> Bool {
        guard let lb = Sealed.lb(of: wrap) else { return false }
        lock.lock(); let has = keys.secret(lb) != nil; lock.unlock()
        return !has && !myLetterboxes().contains(lb)
    }

    private func note(_ change: (inout UpkeepReport) -> Void) {
        lock.lock(); change(&report); lock.unlock()
    }

    /// After a pass: a failed precondition is tried again in seconds, not at the next trigger.
    /// One retry waits at a time (passes that fail meanwhile don't push it back or lengthen it).
    private func settle(_ r: UpkeepReport) {
        lock.lock()
        defer { lock.unlock() }
        guard r.failed, !closed else {
            retryTask?.cancel(); retryTask = nil
            failures = 0; retryAt = nil
            return
        }
        guard retryAt == nil else { return }
        failures += 1
        let wait = retryDelays[min(failures, retryDelays.count) - 1]
        retryAt = Int.now + Int(wait.rounded(.up))
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.lock.lock(); self.retryAt = nil; let closed = self.closed; self.lock.unlock()
            if !closed { self.onRetry?() }
        }
    }
    /// Rosters and anchors were paged from the start on this connection.
    private var pagedOn: String?
    /// The shared-history wraps and other sealed rumors a sender wants kept while they are queued.
    public var holdRumor: ((NostrEvent) -> Void)?
    private var handled = Set<String>()
    /// The belfry's own key, from belfry.json: the one seal signer that is not a device, for a
    /// mail (kind 1301) only (sealed.md 7). Never a name looked up at the time.
    var belfryKey: String? { engine.config.belfryKey.flatMap { isHex64($0) ? $0 : nil } }
    /// GET /api/me/sessions; nil when it could not be read.
    public var sessions: (() async -> [SessionInfo]?)?
    /// POST /api/me/sessions/revoke, by the session's bunker key.
    public var revoke: ((String) async -> Bool)?
    /// This device's own name and kind for `belfry:devices`.
    public var myName: (() -> Sealed.DeviceName)?
    public var onChange: (() -> Void)?
    /// New keys came: the wraps kept locked can be tried again.
    public var onKeys: (() -> Void)?
    /// Tests: the upkeep runs on a local-only engine, the anchor question and the wait before a
    /// removal are the test's own.
    /// A member's or an admin's own session (never a guest's): only then may this device start a
    /// chain. Set by the app.
    public var mayStart = false
    var runsLocally = false
    var askAnchor: (() async -> [NostrEvent]?)?
    var removalWait: ClosedRange<UInt64> = 0...60
    var askChains: (([String]) async -> [NostrEvent]?)?
    /// After a change that ended "not done": the upkeep is run again after these seconds (a roster
    /// the relay took late is anchored, the hand-over it owed is made) instead of at the next
    /// event, which may be hours away on a quiet socket.
    var followUps: [UInt64] = [10, 60, 300]
    /// How long a change waits for the relay to take an event: tries × pause (5 s).
    var settleTries = 10
    var settlePause: UInt64 = 500_000_000
    private var following = false
    /// Per person: when the relay last gave a complete answer about their anchor and rosters.
    private var answered = [String: Int]()

    public init?(engine: SyncEngine, deviceSecret: Data, store: SealedKeyStore) {
        // only once the account's key is known (a signer may learn it after it starts)
        guard isHex64(engine.me), let pub = try? Keys.publicKeyHex(secret: deviceSecret) else { return nil }
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
            || (e.kind == 30078 && (e.tag("d") == SealedKind.anchorD || (e.tag("d") ?? "").hasPrefix(SealedKind.deviceD)))
    }

    /// RECHAIN: the change touches what a chain resolves to (a pinned head).
    private func remember(rechain: Bool = false, _ change: (inout SealedMemory) -> Void) {
        // changed and stored under the same lock: two writers never store an older copy last
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        change(&memory)
        engine.db.set("sealed-state", memory)
        if rechain { chains?.cache = [:] }
    }

    /// This engine's account was switched away from, or signed out: nothing more is saved or
    /// published by whatever it still had under way.
    public func close() { lock.lock(); closed = true; retryTask?.cancel(); retryTask = nil; retryAt = nil; lock.unlock() }

    public func setLink(_ secret: String?) { lock.lock(); link = secret; lock.unlock() }

    /// The key chain changed: kept in the store, unless this device signed out meanwhile.
    private func saveKeys(_ k: KeyChain) {
        lock.lock(); let gone = closed; lock.unlock()
        if !gone { store.save(k) }
    }

    /// One change of my chain at a time (allow, not me, remove, the upkeep): the next waits.
    private func exclusive<T>(_ body: () async -> T) async -> T {
        while true {
            lock.lock()
            if !working { working = true; lock.unlock(); break }
            lock.unlock()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { lock.lock(); working = false; lock.unlock() }
        return await body()
    }

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
            if e.kind == SealedKind.roster, let p = Roster(e)?.account { rosters[p, default: []].append(e) }
            else if e.kind == 30078, e.tag("d") == SealedKind.anchorD {
                if let old = anchors[e.pubkey], (old.createdAt, e.id) > (e.createdAt, old.id) { continue }
                anchors[e.pubkey] = e
            }
        }
        lock.lock(); if (chains?.version ?? -1) <= v { chains = (v, anchors, rosters, [:]) }; lock.unlock()
        return (anchors, rosters)
    }

    /// ACCOUNT's chain as this device follows it (its pin: no going back behind an anchored head),
    /// from the events held here (signatures were checked when stored). Remembering what was
    /// followed is `observe`'s.
    public func chain(_ account: String) -> RosterChain? {
        let (anchors, rosters) = index()
        lock.lock()
        if let hit = chains?.cache[account] { lock.unlock(); return hit }
        let pin = memory.pins[account]
        lock.unlock()
        let v = engine.version
        let c = SealedFollow.follow(account: account, anchor: anchors[account], rosters: rosters[account] ?? [], pin: pin, verify: false).chain
        // kept only for the snapshot it was read from (a newer one may have come meanwhile)
        lock.lock(); if chains?.version == v { chains?.cache[account] = .some(c) }; lock.unlock()
        return c
    }

    /// In my head, but without the head letterbox's secret (its hand-over has not come): it can't
    /// read what arrives, and says so in place of the composer.
    /// Another device started my account fresh while this one was in the head: its device key (to
    /// name it from the session list) and when. Nil once answered.
    public var foreignFreshStart: (device: String, at: Int)? {
        lock.lock(); defer { lock.unlock() }
        return memory.foreignFresh.map { ($0.device, $0.at) }
    }

    /// "It was me": the notice goes.
    public func dismissForeignFresh() { remember { $0.foreignFresh = nil } ; onChange?() }

    /// "Sign out every other device": every session of my account but this device's is revoked
    /// through the belfry, then this device asks to be allowed. The names of the sessions signed
    /// out when every revoke went through (the notice goes); nil: some session may still be live,
    /// the notice stays.
    public func signOutEveryOtherDevice(now: Int = .now) async -> [String]? {
        await exclusive {
            guard let sessions = await self.sessions?() else { return nil }
            var ok = true
            var names = [String]()
            for s in sessions where s.clientPubkey != self.devicePub {
                if await self.revoke?(s.bunkerPubkey) == true {
                    let n = (s.device ?? "").isEmpty ? (s.applicationName.isEmpty ? "A device" : s.applicationName) : s.device!
                    if !names.contains(n) { names.append(n) }
                } else { ok = false }
            }
            guard ok else { return nil }
            self.lock.lock(); let link = self.link; self.lock.unlock()
            if (try? self.publish(Sealed.request(account: self.me, device: self.devicePub, link: link, now: now))) != nil {
                self.remember { $0.lastRequest = now }
            }
            self.remember { $0.foreignFresh = nil }
            self.onChange?()
            return names
        }
    }

    /// This device is the only one in my head and holds its letterbox's secret: losing it (sign
    /// out) leaves my sealed conversations unreadable until Start fresh (board
    /// messages/encryption-only-device). False with no chain or no letterbox yet.
    public var onlyDevice: Bool {
        guard let c = chain(me), c.devices == [devicePub] else { return false }
        lock.lock(); defer { lock.unlock() }
        return keys.secret(c.lb) != nil
    }

    public var lacksKey: Bool {
        guard let c = chain(me), c.devices.contains(devicePub) else { return false }
        lock.lock(); defer { lock.unlock() }
        return keys.secret(c.lb) == nil
    }

    /// Since when this device waits for its key (nil: it has it, or is not in my head).
    public var waitingSince: Int? { lock.lock(); defer { lock.unlock() }; return memory.waitingSince }

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

    /// Every letterbox of my account's VALID chains: the current one, the ones pinned before it,
    /// and the last head this device accepted. Never a roster that merely names me: anyone can
    /// publish one.
    private func myLetterboxes() -> Set<String> {
        var out = Set(chain(me)?.rosters.map(\.lb) ?? [])
        lock.lock(); let old = memory.oldRoots; if let h = memory.heads[me] { out.insert(h.lb) }; lock.unlock()
        guard !old.isEmpty else { return out }
        let (_, rosters) = index()
        let mineAll = (rosters[me] ?? []).compactMap(Roster.init)
        for root in old {
            var cur = mineAll.first { $0.id == root && $0.n == 1 && $0.devices.contains($0.signer) }
            while let c = cur {
                out.insert(c.lb)
                cur = mineAll.filter { $0.prev == c.id && $0.n == c.n + 1 && c.devices.contains($0.signer) }.min { $0.id.lowercased() < $1.id.lowercased() }
            }
        }
        return out
    }

    /// Whether my own chain is current: my anchor and rosters were answered by the relay, after
    /// AUTH and to EOSE, on the connection that is open now. Only then can a wrap to a letterbox
    /// this device does not know be called nobody's.
    private var mineCurrent: Bool {
        lock.lock(); let seen = mineSeenOn; lock.unlock()
        guard let seen else { return false }
        if askChains != nil { return true } // tests: the fake relay has one connection
        return engine.connection(.main).map { "\($0)" } == seen
    }

    /// One read of these people's chains: what is followed, remembered (the pin), and told. A
    /// fresh start or a switch of somebody else gives the amber line in each conversation with
    /// them; of my own account, the old root's devices may still hand keys over. Call when
    /// rosters or anchors arrive.
    public func observe(_ accounts: [String], now: Int = .now) {
        var changed = false
        let (anchors, rosters) = index()
        for a in Set(accounts) {
            lock.lock(); let pin = memory.pins[a], head = memory.heads[a]; lock.unlock()
            let (c, next, event) = SealedFollow.follow(account: a, anchor: anchors[a], rosters: rosters[a] ?? [], pin: pin, verify: false)
            if next != pin {
                remember(rechain: true) { m in
                    m.pins[a] = next
                    switch event {
                    case .freshStart:
                        if a == self.me {
                            if let old = pin?.root { m.oldRoots.append(old) }
                            // started fresh by ANOTHER device while this one was in the head and is
                            // still here: "If this wasn't you, sign out every other device"
                            if let c, c.root.signer != self.devicePub, head?.devices.contains(self.devicePub) == true {
                                m.foreignFresh = .init(root: c.root.id, at: c.root.createdAt, device: c.root.signer)
                            }
                        }
                        else if let c { m.resets[a, default: []].append(.init(root: c.root.id, at: c.root.createdAt, shared: false)) }
                    case .switch:
                        if a != self.me, let c { m.resets[a, default: []].append(.init(root: c.head.id, at: c.head.createdAt, shared: false)) }
                    default: break
                    }
                }
                changed = true
            }
            if let c, head?.lb != c.lb || head?.devices != c.devices {
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
    /// Some conversation this device knows sealed has ACCOUNT in it (an old-style wrap to them
    /// whose rumor is lost must not leave: it may be one of them).
    public func sealedWith(_ account: String) -> Bool {
        lock.lock(); let convs = Array(memory.sealed.keys); lock.unlock()
        return convs.contains { MailThreads.peers($0).contains(account) }
    }

    public func isSealed(_ conv: String, now: Int = .now) -> Bool {
        lock.lock(); let known = memory.sealed[conv] != nil; lock.unlock()
        if known { return true }
        guard let people = SealedEngine.people(conv, me: me) else { return false }
        if people == [me] {
            // Notes to myself (one-shape.md): sealed as soon as I have a chain, WITHOUT waiting for
            // `ready`: the only reader is me. A device of mine outside the head waits to be added.
            guard chain(me) != nil else { return false }
        } else {
            guard people.allSatisfy({ chain($0)?.ready == true }) else { return false }
        }
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
        guard mine == .inside else { throw BelfryError.invalid("You can write here once this device is added.") }
        var targets = [String]()
        for p in to + (selfCopy ? [me] : []) where !targets.contains(p) { targets.append(p) }
        return try targets.map { p in
            guard let lb = letterbox(p) else { throw BelfryError.invalid("This conversation can't be locked for everyone yet. Try again.") }
            return try Sealed.wrap(rumor, device: device, to: p, lb: lb)
        }
    }

    /// One sealed wrap of RUMOR for ACCOUNT's letterbox as it is now.
    public func wrapOne(_ rumor: NostrEvent, to account: String) throws -> NostrEvent {
        guard mine == .inside, let lb = letterbox(account) else { throw BelfryError.invalid("This conversation can't be locked for everyone yet. Try again.") }
        return try Sealed.wrap(rumor, device: device, to: account, lb: lb)
    }

    /// A queued wrap of RUMOR for ACCOUNT, made again when that account's letterbox is no longer LB.
    public func again(_ rumor: NostrEvent, for account: String, was lb: String) -> NostrEvent? {
        guard mine == .inside, let now = letterbox(account), now != lb else { return nil }
        return try? Sealed.wrap(rumor, device: device, to: account, lb: now)
    }

    /// An e-mail on its way out: sealed by the device to the belfry's key (sealed.md 7).
    public func mailWrap(_ rumor: NostrEvent, bridge b: String) throws -> NostrEvent {
        let json = Sealed.json(rumor)
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

    /// Whether WRAP is one this device should be able to read and can't (the banner): sealed to a
    /// letterbox of MY OWN chain that it has no secret for. A wrap naming any other letterbox is
    /// nobody's (anyone can write one) and never counts.
    public func isLocked(_ wrap: NostrEvent) -> Bool {
        guard let lb = Sealed.lb(of: wrap) else { return false }
        lock.lock(); let has = keys.secret(lb) != nil; lock.unlock()
        return !has && myLetterboxes().contains(lb)
    }

    public func open(_ wrap: NostrEvent) -> Outcome {
        lock.lock(); let k = keys; lock.unlock()
        // a wrap is back-dated by up to 2 days: 32 = the 30 days a wrap may wait for its AUTHOR's
        // chain (only that: a wrap this device has no secret for never gives up by age)
        let old = Int.now - wrap.createdAt > 32 * 86400
        switch Sealed.open(wrap, keys: k) {
        case .invalid: return .drop
        case .locked:
            // no secret here. Sealed to a letterbox of my own chain: kept without limit (the
            // banner shows), never dropped, never marked seen: a device allowed after months gets
            // every key in the hand-over and must still find its history
            guard let lb = Sealed.lb(of: wrap) else { return .drop }
            if myLetterboxes().contains(lb) {
                lock.lock(); unknownSeen[wrap.id] = nil; lock.unlock()
                return .keep
            }
            // a letterbox this device does not know: it may be my newest one, whose roster has not
            // arrived yet (the wrap can come first), or an old one while my chain is not loaded.
            // Nobody's (anyone can write one) only by a complete read of my chain, on this
            // connection, BEGUN AFTER this wrap was first seen here; a read that is older, skipped
            // or throttled decides nothing: the wrap is kept, at any age, and never marked seen
            lock.lock()
            let first = unknownSeen[wrap.id]
            if first == nil { unknownSeen[wrap.id] = mineReadsBegun }
            let judged = first.map { mineReadDone > $0 } ?? false
            lock.unlock()
            if judged, mineCurrent {
                lock.lock(); unknownSeen[wrap.id] = nil; lock.unlock()
                return .drop
            }
            rereadMine()
            return .keep
        case .opened(let rumor, let seal):
            // a mail from the belfry: kind 1301, author and seal's signer both the belfry's key
            let b = belfryKey
            if let b, seal == b { return Sealed.accepted(rumor, sealPubkey: seal, chain: nil, belfry: b) ? .rumor(rumor) : .drop }
            // "It was me" from another device of mine (5.2 step 2b): never a message; it clears
            // this device's notice when the rule holds. Its roster not here yet: kept, tried again
            // when my chain changes, for 30 days. Anything else: ignored without a word.
            if rumor.kind == AddedConfirm.kind {
                switch AddedConfirm.verdict(rumor, sealPubkey: seal, chain: chain(me), account: me) {
                case .clears(let device):
                    noticed(device)
                    onChange?()
                    return .drop
                case .unknownRoster:
                    if old { return .drop }
                    let stamp = chainsStamp()
                    lock.lock(); waiting[wrap.id] = stamp; lock.unlock()
                    return .keep
                case .no:
                    return .drop
                }
            }
            // it opens, but its author's device is in no chain loaded here yet: kept and tried
            // again when that author's head changes (each new roster, each start), for 30 days
            let c = chain(rumor.pubkey)
            guard Sealed.accepted(rumor, sealPubkey: seal, chain: c, belfry: b) else {
                if old { return .drop }
                let stamp = chainsStamp()
                lock.lock(); waiting[wrap.id] = stamp; lock.unlock()
                return .keep
            }
            lock.lock(); waiting[wrap.id] = nil; lock.unlock()
            if rumor.kind == SealedKind.history {
                // each rumor's conversation must have the sharer and me in it
                return .shared(Sealed.sharedTaken(rumor, receiver: me), by: rumor.pubkey)
            }
            // a sealed rumor accepted: its conversation is sealed from now on, on this device too
            if [14, 15, 7, 5].contains(rumor.kind) {
                let conv = MailThreads.nostrConv(author: rumor.pubkey, pTags: rumor.tagValues("p"), me: me)
                lock.lock(); let known = memory.sealed[conv] != nil; lock.unlock()
                if !known { remember { $0.sealed[conv] = min(Int.now, rumor.createdAt) } }
            }
            return .rumor(rumor)
        }
    }

    /// A wrap to an unknown letterbox is kept: my own chain is read again, at most once a minute
    /// (one more read is owed when that minute is over). Tests ask by hand.
    private func rereadMine() {
        guard askChains == nil else { return }
        let now = Int.now
        lock.lock()
        let wait = max(0, rereadAt + 60 - now)
        if rereadPending { lock.unlock(); return }
        rereadPending = true
        lock.unlock()
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000) }
            guard let self else { return }
            self.lock.lock(); self.rereadAt = Int.now; self.rereadPending = false; self.lock.unlock()
            await self.refresh([self.me])
        }
    }

    /// Whether a kept wrap is worth opening again: never tried in this run, or its author's head
    /// changed since (opening costs two decryptions and a signature check each time).
    public func worthTrying(_ wrap: NostrEvent) -> Bool {
        lock.lock(); let seen = waiting[wrap.id]; lock.unlock()
        guard let seen else { return true }
        // the author is not known without opening it: any change of any chain since is a reason
        return seen != chainsStamp()
    }

    /// Changes whenever a roster or an anchor arrives.
    private func chainsStamp() -> String {
        let (anchors, rosters) = index()
        return "\(anchors.count):\(rosters.values.reduce(0) { $0 + $1.count }):\(anchors.values.map(\.createdAt).max() ?? 0)"
    }

    /// A delivery report sealed to my letterbox (7679 with `lb`): its text, when the belfry signed
    /// it and this device holds that letterbox's secret.
    public func openReport(_ e: NostrEvent) -> String? {
        lock.lock(); let k = keys; lock.unlock()
        if case .opened(let text) = Sealed.report(e, belfry: belfryKey, verify: false, secret: { k.secret($0) }) { return text }
        return nil
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
            if got { saveKeys(k) }
        }
        if got { lock.lock(); waiting = [:]; lock.unlock(); onKeys?(); onChange?() }
        return got
    }

    // ---- this device's part (sealed.md 5 and 6) ------------------------------------------------------------

    private func publish(_ t: EventTemplate) throws -> NostrEvent {
        lock.lock(); let gone = closed; lock.unlock()
        if gone { throw BelfryError.notSignedIn }
        let e = try t.event(pubkey: "").signed(with: device)
        engine.add([e], verify: false)
        engine.enqueueSigned(e, target: .main, dm: nil)
        return e
    }

    /// A roster of mine, then the anchor again right after it, naming it as the head (the root
    /// stays): a device always anchors its own roster at once.
    /// The roster is signed here; the anchor naming it is signed by the signer; only then are
    /// both sent, in the same moment, the roster first. When the anchor cannot be signed, neither
    /// is sent (nil: the change is tried again later).
    @discardableResult
    private func publishRoster(_ t: EventTemplate, root: String?, now: Int) async -> NostrEvent? {
        guard let r = try? t.event(pubkey: "").signed(with: device) else { return nil }
        let (anchors, _) = index()
        let at = max(now, (anchors[me]?.createdAt ?? 0) + 1)
        guard let a = try? await engine.signer.sign(RosterChain.anchor(root: root ?? r.id, head: r.id, now: at)) else { return nil }
        lock.lock(); let gone = closed; lock.unlock()
        if gone { return nil }
        // NOT added to the local store: this device's own chain is what the relay holds, read
        // back from it (`settled`), never what it meant to publish.
        // The roster first; its anchor only once the relay took it (an anchor that names a roster
        // the relay refused would un-anchor the head that stands)
        let id = engine.enqueueSigned(r, target: .main, dm: nil)
        for _ in 0..<settleTries {
            await engine.flush()
            guard let item = engine.outboxItems().first(where: { $0.localId == id }), item.status != .failed else { break }
            try? await Task.sleep(nanoseconds: settlePause)
        }
        if engine.outboxItems().contains(where: { $0.localId == id }) { engine.cancel(id); return nil }
        engine.enqueueSigned(a, target: .main, dm: nil)
        return r
    }

    /// LOCAL: also kept here at once (never for an anchor: my chain is what the relay holds).
    private func publishAsAccount(_ t: EventTemplate, local: Bool = true) async throws {
        let e = try await engine.signer.sign(t)
        lock.lock(); let gone = closed; lock.unlock()
        if gone { return }
        if local { engine.add([e], verify: false) }
        engine.enqueueSigned(e, target: .main, dm: nil)
    }

    /// Whether a roster with DEVICES may carry `ready`: every counted session is one of them.
    /// Counted: a chat client last active less than 30 days ago (created, when never active). A
    /// counted session without a client key is no device, so nothing is ready with it.
    static func mayCarryReady(_ sessions: [SessionInfo], devices: [String], now: Int) -> Bool {
        sessions.filter { s in s.chat && ((SessionInfo.time(s.lastActivity) ?? SessionInfo.time(s.createdAt)).map { now - $0 < 30 * 86400 } ?? false) }
            .allSatisfy { s in s.clientPubkey.map(devices.contains) ?? false }
    }

    private func nameEvents() -> [NostrEvent] {
        var latest = [String: NostrEvent]()
        for e in engine.snapshot() where e.kind == 30078 && e.pubkey == me {
            guard let d = e.tag("d"), d.hasPrefix(SealedKind.deviceD) else { continue }
            if let old = latest[d], old.createdAt >= e.createdAt { continue }
            latest[d] = e
        }
        return Array(latest.values)
    }

    /// This device's own name record: written when it joins the head and after each letterbox change.
    private func writeNames(_ c: RosterChain) async {
        guard c.devices.contains(devicePub), var name = myName?() else { return }
        // its own name is the `device` of its own session row: what the Allow prompt showed
        lock.lock(); let listed = sessionName, k = keys; lock.unlock()
        if let listed, !listed.isEmpty { name.name = String(listed.prefix(60)) }
        let mineNow = nameEvents().first { $0.tag("d") == SealedKind.deviceD + devicePub }
        let has = mineNow.flatMap { Sealed.deviceName($0, keys: k) }?.name
        if mineNow?.tag("lb") == c.lb, has?.name == name.name, has?.kind == name.kind { return }
        if let has { name.added = has.added }
        if let t = try? Sealed.deviceTemplate(device: devicePub, entry: name, lb: c.lb, keys: k) { try? await publishAsAccount(t) }
    }

    /// My devices' names (entries of devices in no roster are the caller's to ignore).
    public func deviceNames() -> [String: Sealed.DeviceName] {
        lock.lock(); let k = keys; lock.unlock()
        var out = [String: Sealed.DeviceName]()
        for e in nameEvents() { if let n = Sealed.deviceName(e, keys: k) { out[n.device] = n.name } }
        return out
    }

    /// Before each send, and when a sealed conversation opens: the relay is asked again for these
    /// people's anchors and rosters (at most 3 s, then what is known is used). Sealing to a
    /// letterbox its owner has left would let the removed device read. A complete answer (after
    /// AUTH, to EOSE) is remembered per person: only that is knowledge of "no ready chain".
    /// True when the relay answered completely (on an authenticated connection, to EOSE).
    @discardableResult
    public func refresh(_ accounts: [String], now: Int = .now) async -> Bool {
        let who = Array(Set(accounts + [me])).filter(isHex64)
        guard !who.isEmpty else { return false }
        lock.lock(); mineReadsBegun += 1; let read = mineReadsBegun; lock.unlock()
        let found: [NostrEvent]?
        if let askChains { found = await askChains(who) }
        else {
            found = await engine.queryAuthed(.main, [["kinds": [30078], "authors": who, "#d": [SealedKind.anchorD]],
                                                     ["kinds": [SealedKind.roster], "#p": who]], timeout: 3)
        }
        guard let found else { return false }
        engine.add(found)
        let conn = askChains != nil ? "test" : engine.connection(.main).map { "\($0)" }
        lock.lock()
        for a in who { answered[a] = now }
        if who.contains(me) { mineSeenOn = conn; mineReadDone = max(mineReadDone, read) }
        let kept = !unknownSeen.isEmpty
        lock.unlock()
        observe(who, now: now)
        if kept { onMineRead?() }
        return true
    }

    public enum Way: Sendable { case sealed, old, unknown }

    /// How a message of CONV goes. Sealed once every participant has a ready chain (and for good).
    /// The old way only on knowledge, never on silence: this device must hold, for some
    /// participant, a complete answer of the relay (since this start, at most 10 minutes old)
    /// that shows no ready chain. Otherwise it cannot tell, and the send is refused.
    public func way(_ conv: String, now: Int = .now) -> Way {
        if isSealed(conv, now: now) { return .sealed }
        guard let people = SealedEngine.people(conv, me: me) else { return .old }
        lock.lock(); let known = answered; lock.unlock()
        return people.contains { p in (known[p].map { now - $0 <= 600 } ?? false) && chain(p)?.ready != true } ? .old : .unknown
    }

    /// The same for my e-mail: sealed with a ready chain of mine; the old way only when the relay
    /// told this device that I have none.
    public func mailWay(now: Int = .now) -> Way {
        if mailSealed { return .sealed }
        lock.lock(); let at = answered[me]; lock.unlock()
        return (at.map { now - $0 <= 600 } ?? false) ? .old : .unknown
    }

    /// The first device (5.1): a new letterbox, a root with this device, the anchor.
    /// "I don't have another device" (sealed.md 5.4; boards messages/encryption-start-fresh +
    /// -confirm): this device is not in my head; on what the relay answers now (after AUTH, complete
    /// to EOSE, on this connection, for my anchor and my rosters), a new letterbox, a new root
    /// (n = 1, this device) and the anchor replaced. The old root is kept: its devices may come back
    /// and hand their keys over (5.5). True when the relay holds the new root and its anchor and the
    /// chain read back has it.
    public func startFresh(now: Int = .now) async -> Bool {
        await exclusive {
            guard await self.refresh([self.me], now: now), self.mineCurrent else { return false }
            // only from outside the head: a device in it has nothing to start
            guard let old = self.chain(self.me), !old.devices.contains(self.devicePub) else { return false }
            guard let sessions = await self.sessions?(), self.listsMe(sessions) else { return false }
            self.remember { m in if !m.oldRoots.contains(old.root.id) { m.oldRoots.append(old.root.id) } }
            self.lock.lock()
            var k = self.keys
            guard !self.closed, let lb = try? k.make() else { self.lock.unlock(); return false }
            self.keys = k
            self.lock.unlock()
            self.saveKeys(k)
            let ready = SealedEngine.mayCarryReady(sessions, devices: [self.devicePub], now: now)
            guard let r = await self.publishRoster(RosterChain.template(account: self.me, n: 1, prev: nil, lb: lb, devices: [self.devicePub], ready: ready, now: now),
                                                  root: nil, now: now) else { return false }
            guard await self.settled(r, now: now) else { self.onChange?(); return false }
            if let c = self.chain(self.me) { await self.writeNames(c) }
            self.onChange?()
            return true
        }
    }

    private func startChain(_ sessions: [SessionInfo], now: Int) async {
        // a root of mine the relay took whose anchor did not follow: that one is anchored, never a
        // second root made beside it
        let (_, rosters) = index()
        lock.lock(); let held = keys; lock.unlock()
        if let pending = (rosters[me] ?? []).compactMap(Roster.init).first(where: { $0.n == 1 && $0.prev == nil && $0.signer == devicePub && $0.devices == [devicePub] && held.secret($0.lb) != nil }) {
            // (an anchor is replaceable: always later than the one that stands, never the bare clock)
            let (anchors, _) = index()
            try? await publishAsAccount(RosterChain.anchor(root: pending.id, head: pending.id, now: max(now, (anchors[me]?.createdAt ?? 0) + 1)), local: false)
            followUp()
            return
        }
        lock.lock()
        var k = keys
        guard !closed, let lb = try? k.make() else { lock.unlock(); return }
        keys = k
        lock.unlock()
        saveKeys(k)
        let ready = SealedEngine.mayCarryReady(sessions, devices: [devicePub], now: now)
        guard let r = await publishRoster(RosterChain.template(account: me, n: 1, prev: nil, lb: lb, devices: [devicePub], ready: ready, now: now), root: nil, now: now) else { return }
        if await settled(r, now: now), let c = chain(me) { await writeNames(c) }
    }

    /// A roster change is done only when the relay took BOTH the roster and its anchor and the
    /// chain, read again from the relay, has that roster on its path (sealed.md 3.2). False: an
    /// event was refused or is still waiting, or another branch was anchored; the caller's change
    /// is not done (the upkeep does it again on the head that won).
    private func settled(_ roster: NostrEvent, now: Int) async -> Bool {
        func mine() -> [OutboxItem] {
            engine.outboxItems().filter { $0.signed?.id == roster.id || ($0.kind == 30078 && $0.signed?.tag("head") == roster.id) }
        }
        // a few seconds for the relay to take both
        for _ in 0..<settleTries {
            await engine.flush()
            let left = mine()
            if left.isEmpty || left.contains(where: { $0.status == .failed }) { break }
            try? await Task.sleep(nanoseconds: settlePause)
        }
        // refused, or still waiting: what did not leave is withdrawn, so a later try starts clean
        // (a roster that did leave without its anchor is anchored by the next upkeep)
        let left = mine()
        for item in left { engine.cancel(item.localId) }
        // read back from the relay, authenticated and complete: on the anchored path, or not done
        guard await refresh([me], now: now), left.isEmpty, let c = chain(me), c.rosters.contains(where: { $0.id == roster.id }),
              anchoredPath(c).contains(roster.id) else {
            followUp() // not done now: looked at again soon
            return false
        }
        return true
    }

    private func followUp() {
        lock.lock()
        if following || closed || followUps.isEmpty { lock.unlock(); return }
        following = true
        let delays = followUps
        lock.unlock()
        Task { [weak self] in
            for d in delays {
                try? await Task.sleep(nanoseconds: d * 1_000_000_000)
                await self?.maintain()
            }
            guard let self else { return }
            self.lock.lock(); self.following = false; self.lock.unlock()
        }
    }

    /// The ids of the rosters from the root to the end of the anchored path.
    private func anchoredPath(_ c: RosterChain) -> [String] {
        guard let i = c.rosters.firstIndex(where: { $0.id == c.anchored }) else { return [c.root.id] }
        return c.rosters[...i].map(\.id)
    }

    /// The upkeep of my account's chain. Call when the main relay answered on this connection (an
    /// EOSE after AUTH: never while catching up, never from what the device had stored), when my
    /// rosters, anchor or requests arrive, and every 6 hours.
    public func maintain(now: Int = .now) async {
        if (engine.localOnly && !runsLocally) || engine.guestMode.reading { return }
        // the head must be known from this connection: nothing is decided mid catch-up
        guard runsLocally || engine.answeredAfterAuth(.main) else {
            // not answered yet (AUTH still asked, or mid catch-up): said, and tried again soon
            lock.lock()
            let busy = working || closed
            if !busy { report = UpkeepReport(at: now, relayAnswered: false) }
            let r = report
            lock.unlock()
            if !busy { settle(r); onChange?() }
            return
        }
        lock.lock()
        if working || closed { lock.unlock(); return }
        working = true
        report = UpkeepReport(at: now, relayAnswered: true)
        lock.unlock()
        let gone = await upkeep(now: now)
        lock.lock(); working = false; let done = report; lock.unlock()
        settle(done)
        // a device whose session is gone leaves (5.6): after a random wait, outside the guard so
        // an Allow or a Remove is not held up meanwhile, and a second look at everything
        guard !gone.isEmpty else { return }
        try? await Task.sleep(nanoseconds: UInt64.random(in: removalWait) * 1_000_000_000)
        await exclusive {
            guard let sessions = await self.sessions?(), self.listsMe(sessions), let c = self.chain(self.me), c.devices.contains(self.devicePub) else { return }
            let live = Set(sessions.compactMap(\.clientPubkey))
            let still = c.devices.filter { $0 != self.devicePub && !live.contains($0) }
            if !still.isEmpty { _ = await self.drop(Set(still), from: c, live: live, now: now) }
        }
        onChange?()
    }

    /// The anchor again, naming the head, when the head is a roster this device signed and the
    /// anchor does not name it yet (sealed.md 3.2: at each start and each upkeep).
    private func anchorMine(_ c: RosterChain, now: Int) async {
        let (anchors, _) = index()
        guard let a = anchors[me], c.head.signer == devicePub else { return }
        let heads = a.tags.filter { $0.first == "head" }
        let named = heads.count == 1 && heads[0].count >= 2 ? heads[0][1] : c.root.id
        guard named != c.head.id else { return }
        try? await publishAsAccount(RosterChain.anchor(root: c.root.id, head: c.head.id, now: max(now, a.createdAt + 1)), local: false)
    }

    /// After a switch of my own account: DEVICE is not one this device trusts (the pin's
    /// `trusted`). It gets no key without the Allow card.
    private func unvouched(_ d: String, _ c: RosterChain) -> Bool {
        lock.lock(); let t = memory.pins[me]?.trusted; lock.unlock()
        guard let t, d != devicePub else { return false }
        return !t.contains(d)
    }

    /// A well-formed session list that has this device's own chat session: without it nothing is
    /// concluded (an empty or odd answer removes nobody).
    private func listsMe(_ sessions: [SessionInfo]) -> Bool {
        sessions.contains { $0.clientPubkey == devicePub && $0.chat }
    }

    /// One pass. Returns the head's devices whose session is gone (to drop after the wait).
    private func upkeep(now: Int) async -> [String] {
        // every anchor and roster, paged from the start, once per connection (the live
        // subscription's limit would hide some on a large belfry), then my own, read back
        if askChains == nil {
            let conn = engine.connection(.main).map { "\($0)" }
            lock.lock(); let done = pagedOn != nil && pagedOn == conn; lock.unlock()
            if !done, await engine.fetchAll(["kinds": [SealedKind.roster]]), await engine.fetchAll(["kinds": [30078], "#d": [SealedKind.anchorD]]) {
                lock.lock(); pagedOn = conn; lock.unlock()
            }
        }
        guard await refresh([me], now: now) else { note { $0.chainRead = false }; onChange?(); return [] }
        note { $0.chainRead = true }
        takeKeys()
        observe([me], now: now)
        guard let sessions = await sessions?() else { note { $0.sessions = false }; onChange?(); return [] }
        note {
            $0.sessions = true
            $0.sessionCount = sessions.count
            $0.chatSessions = sessions.filter(\.chat).count
            $0.keyedSessions = sessions.filter { !($0.clientPubkey ?? "").isEmpty }.count
            $0.keyListed = sessions.contains { $0.clientPubkey == self.devicePub }
        }
        let live = Set(sessions.compactMap(\.clientPubkey))
        lock.lock(); sessionName = sessions.first { $0.clientPubkey == devicePub }?.device; lock.unlock()
        guard listsMe(sessions) else { note { $0.listsMe = false }; onChange?(); return [] }
        note { $0.listsMe = true }
        guard let c = chain(me) else {
            // members only, and only when the relay itself, after authentication on this
            // connection and complete to EOSE, shows no anchor
            guard mayStart else { return [] }
            let asked: [NostrEvent]?
            if let askAnchor { asked = await askAnchor() }
            else { asked = await engine.queryAuthed(.main, [["kinds": [30078], "authors": [me], "#d": [SealedKind.anchorD]]]) }
            guard let found = asked, found.isEmpty else { return [] }
            await startChain(sessions, now: now)
            onChange?()
            return []
        }
        if !c.devices.contains(devicePub) {
            // not in my head: ask (5.2), again every 24 h. No fresh start is made here, whoever is
            // live: this device stays locked with the banner until another one allows it.
            lock.lock(); var last = memory.lastRequest; let link = self.link; lock.unlock()
            note { $0.inHead = false; $0.headDevices = c.devices.count }
            // "asked" means the relay has it: a request the relay refused for good is asked again
            // now, and one still waiting in the outbox is pushed and looked at again in seconds
            // (it used to count as asked for 24 hours from the moment it was queued)
            let queued = engine.outboxItems().filter { $0.kind == SealedKind.request && $0.signed?.pubkey == devicePub }
            if let refused = queued.first(where: { $0.status == .failed }) {
                for q in queued { engine.cancel(q.localId) }
                remember { $0.lastRequest = 0 }
                last = 0
                note { $0.requestRefused = String((refused.error ?? "refused").prefix(120)) }
            } else if !queued.isEmpty {
                engine.flushSoon()
                note { $0.requestWaiting = true; $0.requestTries = queued.map(\.tries).max(); $0.requestError = queued.compactMap(\.error).last.map { String($0.prefix(120)) } }
            } else if last > 0 {
                note { $0.requestLeft = true }
            }
            if now - last >= 86400 {
                let sent = (try? publish(Sealed.request(account: me, device: devicePub, link: link, now: now))) != nil
                if sent { remember { $0.lastRequest = now } }
                note { $0.asked = sent }
            }
            onChange?()
            return []
        }
        note { $0.inHead = true }
        // "was added" notices start with what happens from now on (never for what was there before)
        lock.lock(); let noSince = memory.noticeSince == nil; lock.unlock()
        if noSince { remember { $0.noticeSince = now } }
        // a roster of mine past the anchored end (its anchor was lost or refused): anchored now
        await anchorMine(c, now: now)
        // in the head, but without the head letterbox's secret (a hand-over that was lost): this
        // device asks like a new one; a head device that holds the secret answers with the keys
        lock.lock(); let lacks = keys.secret(c.lb) == nil, last = memory.lastRequest, link = self.link; lock.unlock()
        if lacks {
            lock.lock(); let since = memory.waitingSince; lock.unlock()
            if since == nil { remember { $0.waitingSince = now } }
            if now - last >= 3600, (try? publish(Sealed.request(account: me, device: devicePub, link: link, now: now))) != nil {
                remember { $0.lastRequest = now }
            }
            onChange?()
            return []
        }
        lock.lock(); let waited = memory.waitingSince != nil; lock.unlock()
        if waited { remember { $0.waitingSince = nil } }
        let gone = c.devices.filter { $0 != devicePub && !live.contains($0) }
        if !gone.isEmpty { return gone }
        // a device I let in whose Allow did not finish here (the relay was slow): its keys now,
        // once its roster is on the anchored path
        if anchoredPath(c).last == c.head.id {
            for d in c.devices { give(d, c, now: now) }
            // a device of an older root of mine, allowed back in after a fresh start: its whole key
            // chain (the old letterboxes too) goes once to the device that let it in (sealed.md 5.4)
            lock.lock(); let olds = memory.oldRoots, back = memory.handedBack ?? [], k0 = keys; lock.unlock()
            if !olds.isEmpty, !back.contains(c.root.id), let j = c.joined(devicePub), let from = j.from, from != devicePub, c.devices.contains(from) {
                if hand(from, k0, now: now) { remember { m in m.handedBack = (m.handedBack ?? []) + [c.root.id] } }
            }
            // a removal of mine that the relay took late: the new secret it owed to the devices that stay
            if c.head.signer == devicePub, c.rosters.count > 1, c.rosters[c.rosters.count - 2].lb != c.lb {
                lock.lock(); let handed = memory.handed, k = keys; lock.unlock()
                for d in c.devices where d != devicePub && live.contains(d) && !unvouched(d, c) && (handed[d] ?? 0) < c.head.createdAt { hand(d, k, now: max(now, c.head.createdAt)) }
            }
        }
        // a head device that asks (it lost its hand-over): the keys at once, no prompt, when its
        // chat session is live; once per request; only for a head that is anchored
        let liveChat = Set(sessions.filter(\.chat).compactMap(\.clientPubkey))
        for e in engine.snapshot() where e.kind == SealedKind.request && e.hasTag("p", me) && e.pubkey != devicePub && c.devices.contains(e.pubkey) {
            // once per request, remembered across restarts
            lock.lock()
            let done = memory.answeredRequests.contains(e.id), last = memory.handed[e.pubkey], pin = memory.pins[me], k = keys
            lock.unlock()
            // on the anchored end, in the head this device holds, trusted (after a switch), a
            // live chat session, a request strictly newer than the roster that added the device
            // and than my last hand-over to it
            guard !done, SealedFollow.answerWithoutPrompt(chain: c, pin: pin, device: e.pubkey, liveChatDevices: liveChat, requestAt: e.createdAt, lastHandoverAt: last) else { continue }
            // remembered only once the keys are on their way: a request met while something
            // passes (no session list, no row yet, no key here) is looked at again next time
            guard hand(e.pubkey, k, now: now) else { continue }
            remember { m in m.answeredRequests = Array((m.answeredRequests + [e.id]).suffix(300)) }
        }
        // a request with the proof of a code this device showed is allowed at once (5.2)
        lock.lock(); let secrets = shownLinks.filter { now - $0.at < 900 }.map(\.secret); lock.unlock()
        for r in requests(c, sessions) where Sealed.linked(r.event, secrets: secrets) {
            // this device showed the code: no "was added" notice here
            if await admit(r.event.pubkey, now: now) == .done { noticed(r.event.pubkey) }
            return []
        }
        // a new device of mine is added without a prompt (5.2 step 2): its session is live and a
        // chat client in the list read in this pass (`requests`), the rest is AutoAdd.allowed.
        // One per pass; one that does not go through is left to the Allow card for this run.
        for r in requests(c, sessions) where autoAddable(r, c, now: now) {
            let a = await admit(r.event.pubkey, now: now, byPerson: false)
            if a != .done { lock.lock(); autoFailed.insert(r.event.pubkey); lock.unlock() }
            onChange?()
            return []
        }
        if !c.ready, SealedEngine.mayCarryReady(sessions, devices: c.devices, now: now) {
            await publishRoster(RosterChain.template(account: me, n: c.head.n + 1, prev: c.head.id, lb: c.lb, devices: c.devices, ready: true, now: now), root: c.root.id, now: now)
            onChange?()
        }
        await writeNames(c)
        return []
    }

    private func requests(_ c: RosterChain, _ sessions: [SessionInfo]) -> [(event: NostrEvent, session: SessionInfo)] {
        lock.lock(); let no = denied; lock.unlock()
        var seen = Set<String>()
        return engine.snapshot().filter { $0.kind == SealedKind.request && $0.hasTag("p", me) }.sorted { $0.createdAt > $1.createdAt }.compactMap { e -> (event: NostrEvent, session: SessionInfo)? in
            guard !c.devices.contains(e.pubkey) || unvouched(e.pubkey, c), !no.contains(e.pubkey), seen.insert(e.pubkey).inserted,
                  let s = sessions.first(where: { $0.clientPubkey == e.pubkey && $0.chat }) else { return nil }
            return (e, s)
        }
    }

    /// 5.2 step 2 for one request, on what this device holds now.
    private func autoAddable(_ r: (event: NostrEvent, session: SessionInfo), _ c: RosterChain, now: Int) -> Bool {
        lock.lock(); let pin = memory.pins[me], failed = autoFailed.contains(r.event.pubkey); lock.unlock()
        guard autoAdd, !failed, !lacksKey else { return false }
        return AutoAdd.allowed(chain: c, pin: pin, thisDevice: devicePub, newDevice: r.event.pubkey,
                               sessionCreatedAt: SessionInfo.time(r.session.createdAt), requestAt: r.event.createdAt, now: now)
    }

    /// The person answered for DEVICE here (Allow, a link code, "It was me"): no notice for it.
    /// The notice for DEVICE is answered: for the roster that last added it (a device removed
    /// and added again is a new notice that needs its own answer).
    private func noticed(_ device: String) {
        let key = chain(me).flatMap { AddedConfirm.addedBy($0, device) }.map { device + ":" + $0.id } ?? device
        remember { m in if !(m.noticeDone ?? []).contains(key) { m.noticeDone = Array(((m.noticeDone ?? []) + [key]).suffix(200)) } }
    }

    /// "It was me" on the notice: answered here, and once for every device of mine (5.2 step
    /// 2b): a sealed 8563 to my own head letterbox, naming the roster that added the device.
    public func ackAdded(_ device: String) {
        noticed(device)
        if let c = chain(me), c.devices.contains(devicePub), let r = AddedConfirm.addedBy(c, device) {
            let rumor = GiftWrap.rumor(kind: AddedConfirm.kind, pubkey: devicePub, tags: AddedConfirm.tags(account: me, device: device, roster: r.id), content: "")
            lock.lock(); let gone = closed; lock.unlock()
            if !gone, let w = try? Sealed.wrap(rumor, device: self.device, to: me, lb: c.lb, silent: true) {
                _ = engine.enqueueSigned(w, target: .main, dm: nil)
            }
        }
        onChange?()
    }

    /// The devices added to my head without this device having shown a prompt or a link code for
    /// them (5.2 step 2a): each until the person answers here or it leaves the head. Only for
    /// rosters dated since this device first ran with this rule, and after it joined itself;
    /// never for this device. Oldest first.
    public func addedNotices() -> [(device: String, at: Int)] {
        guard let c = chain(me), c.devices.contains(devicePub) else { return [] }
        lock.lock(); let since = memory.noticeSince, done = Set(memory.noticeDone ?? []); lock.unlock()
        guard let since else { return [] }
        let mine = c.joined(devicePub)?.at ?? 0
        return c.devices.compactMap { d -> (device: String, at: Int)? in
            // answered: for this adding roster (or, kept from builds before 2026-11-23, for the device)
            if done.contains(d) || done.contains(d + ":" + (AddedConfirm.addedBy(c, d)?.id ?? "")) { return nil }
            guard d != devicePub, let j = c.joined(d), j.from != nil, j.at >= since, j.at > mine else { return nil }
            return (d, j.at)
        }.sorted { $0.at < $1.at }
    }

    /// The new devices waiting for an answer on this device (the Allow prompt); none unless this
    /// device is in my head. Not the ones this device adds by itself (5.2 step 2).
    public func asks(now: Int = .now) async -> [Ask] {
        guard let c = chain(me), c.devices.contains(devicePub), let sessions = await sessions?() else { return [] }
        return requests(c, sessions).filter { !autoAddable($0, c, now: now) }.map { r in
            let n = r.session.device.flatMap { $0.isEmpty ? nil : $0 } ?? (r.session.applicationName.isEmpty ? "A new device" : r.session.applicationName)
            return Ask(id: r.event.pubkey, device: r.event.pubkey, name: n, at: r.event.createdAt)
        }
    }

    public enum Answer: Sendable, Equatable {
        case done
        /// The roster already has 20 devices: nothing was handed over.
        case full
        /// It did not go through (the belfry or the relay did not answer, or the change lost to
        /// another one): nothing is to be taken as done; try again.
        case failed
        /// This device is in my head but has no key itself yet: it can't hand one over. Nothing
        /// was changed; it will be able to once another of my devices has given it the key.
        case waiting
    }

    /// Allow: the keys go to the new device, then roster n+1 with it (same letterbox), then the
    /// anchor. Done only when the relay holds both and the chain read back has the device.
    public func allow(_ newDevice: String, now: Int = .now) async -> Answer {
        await exclusive {
            let a = await self.admit(newDevice, now: now)
            // the person said Allow here: no "was added" notice for it on this device
            if a == .done { self.noticed(newDevice) }
            return a
        }
    }

    /// BYPERSON false: added without a prompt (5.2 step 2). A device that is in the head by
    /// somebody else's roster after a switch is then left to the Allow card.
    private func admit(_ newDevice: String, now: Int, byPerson: Bool = true) async -> Answer {
        // decided on what the relay holds now, not on what this device last saw
        guard await refresh([me], now: now), let c = chain(me), c.devices.contains(devicePub) else { return .failed }
        // already in (another device answered first, or my own roster went through after all)
        if c.devices.contains(newDevice), unvouched(newDevice, c) {
            guard byPerson else { return .failed }
            // after a switch: in the head by somebody else's roster; the person said Allow here
            lock.lock(); let no = denied.contains(newDevice), k = keys; lock.unlock()
            guard !no, !lacksKey, let sessions = await sessions?(), listsMe(sessions),
                  sessions.contains(where: { $0.clientPubkey == newDevice && $0.chat }) else { return .failed }
            remember(rechain: true) { m in if let p = m.pins[self.me] { m.pins[self.me] = SealedFollow.allowLocally(p, newDevice) } }
            hand(newDevice, k, now: now)
            onChange?()
            return .done
        }
        if c.devices.contains(newDevice) {
            // keys only to a device of the ANCHORED head: a roster still past the anchored end is
            // anchored first, and the answer is "not done yet"
            guard anchoredPath(c).last == c.head.id else { await anchorMine(c, now: now); return .failed }
            give(newDevice, c, now: now)
            return .done
        }
        // 20 devices already: refused before any key is handed over
        guard c.devices.count < SealedKind.maxDevices else { return .full }
        // no key here yet: this device has nothing to hand over
        if lacksKey { return .waiting }
        // its session must still be live and a chat client NOW (a card left open after another
        // device's Not me must not hand the chain over), and not refused here
        lock.lock(); let no = denied.contains(newDevice); lock.unlock()
        guard !no, let sessions = await sessions?(), listsMe(sessions),
              sessions.contains(where: { $0.clientPubkey == newDevice && $0.chat }) else { return .failed }
        let devices = c.devices + [newDevice]
        let ready = SealedEngine.mayCarryReady(sessions, devices: devices, now: now)
        // the roster first (signed and anchored, or nothing at all), then the keys: a device never
        // holds keys while it is in no roster
        guard let r = await publishRoster(RosterChain.template(account: me, n: c.head.n + 1, prev: c.head.id, lb: c.lb, devices: devices, ready: ready, now: now), root: c.root.id, now: now) else { followUp(); return .failed }
        guard await settled(r, now: now) else { onChange?(); return .failed }
        if let after = chain(me) { give(newDevice, after, now: now) }
        onChange?()
        return .done
    }

    /// The key chain to a device of my head that this device let in: once per run (a second
    /// hand-over costs nothing; a device in a roster without keys reads nothing).
    private func give(_ d: String, _ c: RosterChain, now: Int) {
        guard d != devicePub, c.devices.contains(d), !unvouched(d, c), let j = c.joined(d), j.from == devicePub, now - j.at < 86400 else { return }
        lock.lock()
        let first = given.insert(d).inserted && (memory.handed[d] ?? 0) < j.at
        let k = keys
        lock.unlock()
        if first { hand(d, k, now: now) }
    }

    /// The whole key chain to device D, and when (so its older requests are not answered again).
    @discardableResult
    private func hand(_ d: String, _ k: KeyChain, now: Int) -> Bool {
        guard let ws = try? Sealed.keysWraps(k, account: me, device: device, to: d), !ws.isEmpty else { return false }
        for w in ws { engine.enqueueSigned(w, target: .main, dm: nil) }
        remember { $0.handed[d] = now }
        return true
    }

    /// Not me: that session is revoked. No roster change. False when the belfry could not be
    /// asked or did not revoke it: the session may still be live.
    public func deny(_ newDevice: String) async -> Bool {
        await exclusive {
            guard let s = await self.sessions?()?.first(where: { $0.clientPubkey == newDevice }) else { return false }
            guard await self.revoke?(s.bunkerPubkey) == true else { return false }
            self.lock.lock(); self.denied.insert(newDevice); self.lock.unlock()
            self.onChange?()
            return true
        }
    }

    /// Devices leave: a new letterbox, its secret to each device that stays AND has a live
    /// session, roster n+1 without them, the anchor. True when the relay holds it.
    private func drop(_ gone: Set<String>, from c: RosterChain, live: Set<String>, now: Int) async -> Bool {
        let stay = c.devices.filter { !gone.contains($0) }
        guard stay.contains(devicePub) else { return false }
        lock.lock()
        var k = keys
        guard !closed, let lb = try? k.make() else { lock.unlock(); return false }
        keys = k
        lock.unlock()
        saveKeys(k)
        guard let r = await publishRoster(RosterChain.template(account: me, n: c.head.n + 1, prev: c.head.id, lb: lb, devices: stay, ready: false, now: now), root: c.root.id, now: now) else { return false }
        // the new secret goes out only once the relay holds the roster that uses it (a device
        // that misses it asks, and is answered: the lost hand-over path)
        guard await settled(r, now: now) else { return false }
        // (after a switch, never to a device nobody vouched for: it asks, through the Allow card)
        let after = chain(me) ?? c
        for d in stay where d != devicePub && live.contains(d) && !unvouched(d, after) { hand(d, k, now: now) }
        if let next = chain(me) { await writeNames(next) }
        return true
    }

    /// Whether my roster is full (Allow then refuses, and says so).
    public var full: Bool { (chain(me)?.devices.count ?? 0) >= SealedKind.maxDevices }

    /// The user removes one of their devices: its session is revoked FIRST, and nothing changes
    /// when that fails (a removed device with a live session could still have an anchor signed);
    /// then it leaves the roster. True only when the relay holds the roster without it.
    public func remove(_ gone: String, now: Int = .now) async -> Bool {
        await exclusive {
            guard gone != self.devicePub, self.mine == .inside, let sessions = await self.sessions?(), self.listsMe(sessions) else { return false }
            if let s = sessions.first(where: { $0.clientPubkey == gone }) {
                guard await self.revoke?(s.bunkerPubkey) == true else { return false }
            }
            // the chain as it is now (it may have moved while the belfry answered)
            _ = await self.refresh([self.me], now: now)
            guard let c = self.chain(self.me), c.devices.contains(self.devicePub) else { return false }
            var ok = true
            if c.devices.contains(gone) {
                let live = Set(sessions.compactMap(\.clientPubkey)).subtracting([gone])
                ok = await self.drop([gone], from: c, live: live, now: now)
            }
            self.onChange?()
            return ok
        }
    }

    /// Signing out: this device's keys go, and whatever was under way saves or publishes nothing more.
    public func wipe() {
        lock.lock()
        closed = true
        keys = KeyChain()
        link = nil
        lock.unlock()
        store.wipe()
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
            // kept while queued: its head is checked again before it leaves, like any sealed wrap
            holdRumor?(part)
            engine.enqueueSigned(try Sealed.wrap(part, device: device, to: person, lb: lb), target: .main, dm: part.id)
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
