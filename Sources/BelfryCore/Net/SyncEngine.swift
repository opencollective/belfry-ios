import Foundation
import Network

// The sync engine (SPEC 4-5): two relays (groups, main), subscriptions with overlapping `since`,
// the outbox flushed in order per relay, wake-ups (network back, foreground, 15 s watchdog).
// In local-only (demo) mode nothing leaves the device and the engine plays the relay's part.

public enum AccessState: String, Sendable { case unknown, ok, denied }

public final class SyncEngine: @unchecked Sendable {
    public static let kindsGroups = [0, 39000, 39001, 39002, 9, 1111, 1010, 7, 9007, 9002, 9008, 9000, 9001, 9005, 9021, 9022, 1068, 1018, 5, 1985, 30078, 2100, 2101, 2102, 2103, 31925, 8534, 8535, 8536, 8538]
    public static let kindsMain = [0, 31922, 31923, 31925, 30023, 30402, 5]
    public static let clientTag: Tag = ["client", "belfry-ios"]

    public let config: BelfryConfig
    public let db: Database
    public let signer: Signer
    public let localOnly: Bool
    public let attachmentsDir: URL
    /// Guest mode (SPEC 19.26): while reading, nothing is queued, signed for a request or uploaded.
    public let guestMode = GuestModeGate()

    private let lock = NSLock()
    private var events = [String: NostrEvent]()
    private var outbox = [String: OutboxItem]()
    private var relays = [Target: Relay]()
    private var attempts = [Target: Int]()
    private var connecting = Set<Target>()
    private var lastCreatedAt = 0
    private var flushing = false
    private var flushAgain = false
    private var started = false
    private var firstChannelTried = false
    private var watchdog: Timer?
    private let monitor = NWPathMonitor()
    public private(set) var online = true
    public private(set) var access: AccessState = .unknown
    public private(set) var relayStates = [String: Relay.State]()
    private var cache: (version: Int, list: [NostrEvent])?
    public private(set) var version = 0

    /// Something changed (events, outbox, status): views read again. Called on any thread.
    public var onChange: (() -> Void)?
    /// An outbox item went out (with its event) or failed for good.
    public var onSent: ((OutboxItem, NostrEvent?) -> Void)?
    public var onFailed: ((OutboxItem) -> Void)?
    /// New events arrived (after storing).
    public var onNewEvents: (([NostrEvent]) -> Void)?
    /// A relay answered the live subscription (EOSE).
    public var onEOSE: ((Target) -> Void)?
    /// Makes an HTTP request (tests, the demo); nil = URLSession. Returns the body and the status.
    public var transport: ((URLRequest) async throws -> (Data, Int))?

    public init(config: BelfryConfig, db: Database, signer: Signer, localOnly: Bool, attachmentsDir: URL) {
        self.config = config
        self.db = db
        self.signer = signer
        self.localOnly = localOnly
        self.attachmentsDir = attachmentsDir
        for e in db.allEvents() { events[e.id] = e; if e.kind == 39000, let d = e.tag("d") { knownGroups.insert(d) } }
        for o in db.outbox() { outbox[o.localId] = o }
        lastCreatedAt = events.values.filter { $0.pubkey == signer.pubkey }.map(\.createdAt).max() ?? 0
    }

    public var me: String { signer.pubkey }

    private func changed() {
        lock.lock(); version += 1; lock.unlock()
        onChange?()
    }

    // ---- the log ----------------------------------------------------------------------------------

    /// All events, with queued outbox items shown as if published (gift wraps excluded).
    public func snapshot() -> [NostrEvent] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.version == version { return c.list }
        var list = Array(events.values)
        for o in outbox.values where o.signed == nil { list.append(o.asEvent(me: me)) }
        cache = (version, list)
        return list
    }

    public func outboxItems() -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        return outbox.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.localId < $1.localId }
    }

    public func pending(_ id: String) -> OutboxItem? {
        lock.lock(); defer { lock.unlock() }
        return outbox[id]
    }

    /// Stores events (signatures checked for relay events), returns the new ones.
    @discardableResult
    public func add(_ list: [NostrEvent], verify: Bool = true) -> [NostrEvent] {
        // known ids first: a replayed subscription (a reconnect) costs no signature checks
        lock.lock()
        let fresh = list.filter { events[$0.id] == nil }
        lock.unlock()
        guard !fresh.isEmpty else { return [] }
        let ok = verify ? fresh.filter(\.isValid) : fresh
        lock.lock()
        let unseen = ok.filter { events[$0.id] == nil }
        for e in unseen { events[e.id] = e }
        // groups this device hears of for the first time (added to a closed group, a new channel)
        var learned = [String]()
        for e in unseen where e.kind == 39000 { if let d = e.tag("d"), knownGroups.insert(d).inserted { learned.append(d) } }
        let askHistory = !learned.isEmpty && authedAnswer.contains(.groups)
        // my own events from another device: what I write next comes after them (a profile of
        // the same second would tie, and the lower id would win over mine)
        let me = signer.pubkey
        if let newest = unseen.filter({ $0.pubkey == me }).map(\.createdAt).max(), newest > lastCreatedAt { lastCreatedAt = newest }
        lock.unlock()
        guard !unseen.isEmpty else { return [] }
        db.add(unseen)
        changed()
        onNewEvents?(unseen)
        if askHistory { historyOf(learned) }
        return unseen
    }

    /// The newest member profile extras (kind 30078, d = belfry:profile) held (SPEC 19.9).
    func latestProfileExtras() -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.values.filter { $0.kind == 30078 && $0.hasTag("d", Derive.profileD) }.map(\.createdAt).max() ?? 0
    }

    public func latest(_ kinds: [Int]) -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.values.filter { kinds.contains($0.kind) }.map(\.createdAt).max() ?? 0
    }

    // ---- the outbox -------------------------------------------------------------------------------

    func nextCreatedAt() -> Int {
        lock.lock(); defer { lock.unlock() }
        lastCreatedAt = Outbox.nextCreatedAt(last: lastCreatedAt)
        return lastCreatedAt
    }

    /// Groups nothing is written in (archived or deleted, SPEC 19.30): the app sets them from its
    /// snapshot. Only an unarchiving 9002 passes.
    public func setLocked(_ ids: Set<String>) { lock.lock(); lockedGroups = ids; lock.unlock() }
    private var lockedGroups = Set<String>()

    @discardableResult
    public func enqueue(_ d: Draft, attachments: [Attachment] = []) -> String {
        if guestMode.refuse() { return "" } // guest mode: nothing is sent; the Join sheet opens
        lock.lock(); let locked = lockedGroups; lock.unlock()
        if GroupLock.refuses(d, locked: locked) { return "" }
        let item = OutboxItem(target: d.target, kind: d.kind, content: d.content, tags: d.tags + [SyncEngine.clientTag],
                              createdAt: nextCreatedAt(), attachments: attachments)
        put(item)
        flushSoon()
        return item.localId
    }

    /// A call to the belfry's API queued like an event (SPEC 19.37): DISPLAY is the change it
    /// makes as the log should show it until the relay has the result (a 9002 for a channel's
    /// settings); CALL is made, NIP-98 signed, when the item's turn comes.
    @discardableResult
    public func enqueueCall(_ call: HttpCall, display: Draft) -> String {
        if guestMode.refuse() { return "" }
        lock.lock(); let locked = lockedGroups; lock.unlock()
        if GroupLock.refuses(display, locked: locked) { return "" }
        let item = OutboxItem(target: .api, kind: display.kind, content: display.content, tags: display.tags,
                              createdAt: nextCreatedAt(), http: call)
        put(item)
        flushSoon()
        return item.localId
    }

    /// Signs D and publishes it at once, NOT through the outbox (a button's press, SPEC 19.36):
    /// throws when it can't be sent; stored and shown once the relay took it.
    @discardableResult
    public func publishNow(_ d: Draft) async throws -> NostrEvent {
        try guestMode.check()
        let ev = try await signer.sign(EventTemplate(kind: d.kind, content: d.content, tags: d.tags + [SyncEngine.clientTag], createdAt: nextCreatedAt()))
        if !localOnly {
            guard online else { throw BelfryError.relay("timeout: offline") }
            try await publish(d.target, ev)
        }
        lock.lock(); outboxVersion += 1; lock.unlock() // my own action: shown at once
        add([ev], verify: false)
        return ev
    }

    @discardableResult
    public func enqueueSigned(_ ev: NostrEvent, target: Target, dm: String?) -> String {
        if guestMode.refuse() { return "" }
        let item = OutboxItem(target: target, kind: ev.kind, content: ev.content, tags: ev.tags, createdAt: ev.createdAt, signed: ev, dm: dm)
        put(item)
        flushSoon()
        return item.localId
    }

    /// The demo's screenshots: an outbox item in a given state (a refused settings change).
    public func demoPut(_ item: OutboxItem) { put(item) }

    /// Bumped by every change of the outbox (my own actions): the app's snapshot follows it at once.
    public private(set) var outboxVersion = 0

    func put(_ item: OutboxItem) {
        lock.lock(); outbox[item.localId] = item; outboxVersion += 1; lock.unlock()
        db.putOutbox(item)
        changed()
    }

    func drop(_ localId: String) {
        lock.lock(); outbox[localId] = nil; outboxVersion += 1; lock.unlock()
        db.dropOutbox(localId)
        changed()
    }

    public func retry(_ localId: String) {
        lock.lock()
        guard var item = outbox[localId] else { lock.unlock(); return }
        lock.unlock()
        item.status = .queued
        item.error = nil
        put(item)
        flushSoon()
    }

    /// Removes a queued item that has not gone out (a reaction taken back before it was sent).
    public func cancel(_ localId: String) { drop(localId) }

    public func flushSoon() { Task { await self.flush() } }

    public func flush() async {
        lock.lock()
        if flushing { flushAgain = true; lock.unlock(); return }
        flushing = true
        flushAgain = false
        lock.unlock()
        let items = outboxItems()
        let result = await OutboxPass.run(items) { item in
            if !self.localOnly && !self.online { return .error("timeout: offline") }
            do { return .ok(try await self.send(item)) } catch let e as BelfryError { return .error(e.relayMessage) } catch { return .error("timeout: \(error.localizedDescription)") }
        }
        for (item, ev) in result.sent {
            if let ev, item.signed == nil {
                lock.lock(); events[ev.id] = ev; lock.unlock()
                db.add([ev])
            }
            drop(item.localId)
            onSent?(item, ev)
        }
        for item in result.items {
            lock.lock(); let cur = outbox[item.localId]; lock.unlock()
            if cur != nil, cur != item { put(item) }
        }
        for f in result.failed { onFailed?(f) }
        lock.lock()
        flushing = false
        let again = flushAgain && result.items.allSatisfy { $0.status == .failed || $0.tries == 0 }
        lock.unlock()
        if again { await flush() }
    }

    private func send(_ item: OutboxItem) async throws -> NostrEvent? {
        if let call = item.http {
            // signed now, not when queued; a 4xx that isn't 401 / 408 / 429 fails for good
            // the demo (local only, no transport): nothing leaves the device
            let (data, status) = localOnly && transport == nil ? (Data("{}".utf8), 200) : try await signedRequest(call.url, method: call.method, json: call.json)
            if let err = HttpCall.outcome(status: status, body: data) { throw BelfryError.relay(err) }
            // the change stays shown (in memory) until the relay's own copy arrives
            let shown = item.asEvent(me: me)
            lock.lock(); events["call-" + item.localId] = NostrEvent(id: "call-" + item.localId, pubkey: shown.pubkey, createdAt: shown.createdAt,
                                                                       kind: shown.kind, tags: shown.tags, content: shown.content); lock.unlock()
            return nil
        }
        if let made = item.signed {
            if localOnly { return made }
            // a sealed wrap whose letterbox changed while it waited is sealed again (sealed.md 9)
            let signed = reseal?(item) ?? made
            try await publish(item.target, signed)
            return signed
        }
        var content = item.content
        var tags = item.tags
        for a in item.attachments {
            let file = attachmentsDir.appendingPathComponent(a.file)
            let url: String
            var x: String?
            if localOnly {
                url = file.absoluteString
            } else {
                guard let data = try? Data(contentsOf: file) else { continue }
                x = Crypto.sha256(data).hex
                url = try await upload(data, name: a.name, mime: a.mime, sha: x!)
            }
            var imeta: Tag = ["imeta", "url \(url)", "m \(a.mime)", "size \(a.size)"]
            if let x { imeta.append("x \(x)") }
            if let w = a.width, let h = a.height { imeta.append("dim \(w)x\(h)") }
            imeta.append("alt \(a.name)")
            tags.append(imeta)
            content = content.isEmpty ? url : content + "\n" + url
        }
        let ev = try await signer.sign(EventTemplate(kind: item.kind, content: content, tags: tags, createdAt: item.createdAt))
        if localOnly {
            synthesizeRelayEvents(ev)
            return ev
        }
        try await publish(item.target, ev)
        return ev
    }

    /// Local-only mode: what the relay would publish for 9007 / 9002 / 9000.
    private func synthesizeRelayEvents(_ ev: NostrEvent) {
        guard let h = ev.tag("h"), ev.kind == 9007 || ev.kind == 9002 else { return }
        let meta = ev.tags.filter { ["name", "about", "picture"].contains($0.first ?? "") }
        var out = [NostrEvent]()
        if ev.kind == 9002 || !meta.isEmpty {
            out.append(NostrEvent(id: Crypto.sha256("meta-" + ev.id).hex, pubkey: ev.pubkey, createdAt: ev.createdAt, kind: 39000, tags: [["d", h]] + meta, content: ""))
        }
        if ev.kind == 9007 {
            out.append(NostrEvent(id: Crypto.sha256("members-" + ev.id).hex, pubkey: ev.pubkey, createdAt: ev.createdAt, kind: 39002, tags: [["d", h], ["p", ev.pubkey]], content: ""))
        }
        add(out, verify: false)
    }

    // ---- Blossom, NIP-98 -------------------------------------------------------------------------

    public func upload(_ data: Data, name: String, mime: String, sha: String) async throws -> String {
        try guestMode.check()
        let auth = try await signer.sign(Actions.blossomAuth(sha256: sha, name: name))
        guard let url = URL(string: config.blossom + "/upload") else { throw BelfryError.network("upload failed (no file server)") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "PUT"
        req.setValue("Nostr " + Data(auth.json.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let u = obj["url"] as? String else {
            throw BelfryError.network("upload failed (\(status))")
        }
        return u
    }

    /// A request with a NIP-98 Authorization header signed by the member.
    public func signedRequest(_ urlString: String, method: String = "GET", json: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw BelfryError.invalid("bad url") }
        try guestMode.check(url: urlString, method: method)
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let auth = try await signer.sign(Actions.httpAuth(url: urlString, method: method, body: body))
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Nostr " + Data(auth.json.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let transport { return try await transport(req) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // ---- relays -----------------------------------------------------------------------------------

    func url(_ t: Target) -> String { t == .groups ? config.groupsRelay : config.mainRelay }

    func relay(_ t: Target) async throws -> Relay {
        lock.lock()
        if let r = relays[t], r.isUp { lock.unlock(); return r }
        lock.unlock()
        let r = Relay(url: url(t))
        wireAnswers(r, t)
        r.onClosed = { [weak self] sub, reason in self?.closed(t, sub, reason) }
        r.onState = { [weak self] s in
            guard let self else { return }
            self.lock.lock(); self.relayStates[self.url(t)] = s; self.lock.unlock()
            self.changed()
        }
        r.onDisconnect = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let same = self.relays[t] === r
            if same { self.relays[t] = nil }
            self.lock.unlock()
            if same { self.retryLater(t) }
        }
        try await r.connect()
        lock.lock(); relays[t] = r; attempts[t] = 0; lock.unlock()
        return r
    }

    func backoff(_ t: Target) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let n = (attempts[t] ?? 0) + 1
        attempts[t] = n
        return min(30, 0.8 * pow(2, Double(n)))
    }

    func retryLater(_ t: Target) {
        let delay = backoff(t)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { await self?.connect(t) }
        }
    }

    func publish(_ t: Target, _ ev: NostrEvent) async throws {
        let r = try await relay(t)
        try await r.publish(ev)
    }

    /// One-off query that counts only when answered to EOSE (nil: no answer).
    public func queryComplete(_ t: Target, _ filters: [[String: Any]], timeout: TimeInterval = 8) async -> [NostrEvent]? {
        if localOnly { return nil }
        guard let r = try? await relay(t) else { return nil }
        return await r.queryComplete(filters, timeout: timeout)
    }

    /// One-off query up to EOSE.
    public func query(_ t: Target, _ filters: [[String: Any]], timeout: TimeInterval = 8) async -> [NostrEvent] {
        if localOnly { return [] }
        guard let r = try? await relay(t) else { return [] }
        return await r.query(filters, timeout: timeout)
    }

    /// The groups' metadata, always asked whole (no `since`, SPEC 19.42): a channel this key could
    /// not read before (a guest who became a member, a channel opened to everyone) has metadata
    /// older than the newest event stored here, and would otherwise show by its id.
    public static let metadataFilter: [String: Any] = ["kinds": [39000, 39001, 39002, 39003], "limit": 2000]

    /// The charter, always asked whole (no `since`, SPEC 19.32): every agreement ever added and not
    /// deleted is listed (Xavier, 2026-11-18). The first subscription asks the newest 2000 events of
    /// every group: on a busy belfry an agreement written long ago was not among them, and later
    /// subscriptions ask only from the newest stored event on. Its ticks come with it.
    public static let charterFilters: [[String: Any]] = [
        ["kinds": [2100], "#h": [Derive.charterId], "limit": 1000],
        ["kinds": [2101], "#h": [Derive.charterId], "limit": 5000],
    ]

    /// Ask everything again on the next subscription to T (no `since`), until its EOSE: after this
    /// key's access changed (a guest became a member, SPEC 19.43).
    public func catchUpFromStart() {
        if localOnly { return }
        lock.lock(); fullSync = [.groups, .main]; lock.unlock()
        db.set("full-sync", [Target.groups.rawValue, Target.main.rawValue])
        db.set("member-view", true)
        dropSockets()
        wake()
    }
    /// The same, before the engine starts (no reconnect): a store that never had a member's view
    /// (SPEC 19.42; Android's `groups-full-1`). Once per store: `member-view` is kept after.
    public func catchUpOnceAsMember() {
        if localOnly || db.get("member-view", as: Bool.self) == true { return }
        db.set("member-view", true)
        lock.lock(); fullSync = [.groups, .main]; lock.unlock()
        db.set("full-sync", [Target.groups.rawValue, Target.main.rawValue])
    }

    private lazy var fullSync: Set<Target> = Set((db.get("full-sync", as: [String].self) ?? []).compactMap { Target(rawValue: $0) })

    func sinceFor(_ t: Target, _ kinds: [Int], back: Int) -> Int {
        lock.lock(); let full = fullSync.contains(t); lock.unlock()
        return full ? 0 : max(0, latest(kinds) - back)
    }

    /// FROMSTART: the first subscription after AUTH (everything from 0, see `Relay.refilter`).
    func filters(_ t: Target, fromStart: Bool = false) -> [[String: Any]] {
        let kinds = t == .groups ? SyncEngine.kindsGroups : SyncEngine.kindsMain
        let since = fromStart ? 0 : sinceFor(t, kinds, back: 3600)
        if t == .groups { return [["kinds": kinds, "since": since, "limit": 2000], SyncEngine.metadataFilter] + SyncEngine.charterFilters }
        let wraps = max(0, latest([1059]) - 3 * 86400)
        let old = max(0, latest([4]) - 3600)
        let extras = since == 0 ? 0 : max(0, latestProfileExtras() - 3600)
        return [
            ["kinds": kinds, "since": since, "limit": 2000],
            ["kinds": [30078], "#d": [Derive.profileD], "since": extras, "limit": 2000],
            // my read state (SPEC 19.27): always the exact d
            ["kinds": [ReadState.kind], "authors": [me], "#d": [ReadState.readD], "limit": 5],
            ["kinds": [1059], "#p": [me], "since": wraps, "limit": 1000],
        ] + sealedFilters + [
            ["kinds": [4], "#p": [me], "since": old, "limit": 500],
            ["kinds": [4], "authors": [me], "since": old, "limit": 500],
        ]
    }

    /// Sealed conversations (docs/sealed.md): the anchors and rosters of everybody, the requests
    /// for my account, the key hand-overs to this device, my device names. Always whole (no `since`).
    public var sealedDevice: String?
    /// A queued sealed wrap, made again for the head its letterbox moved to; nil = send it as it is.
    public var reseal: ((OutboxItem) -> NostrEvent?)?
    var sealedFilters: [[String: Any]] {
        guard let d = sealedDevice else { return [] }
        return [
            ["kinds": [30078], "#d": [SealedKind.anchorD], "limit": 5000],
            ["kinds": [SealedKind.roster], "limit": 5000],
            ["kinds": [SealedKind.request], "#p": [me], "limit": 200],
            ["kinds": [1059], "#p": [d], "limit": 200],
            // my device names (`belfry:device:<key>`): by author, the `d` prefix matched here
            ["kinds": [30078], "authors": [me], "limit": 200],
        ]
    }

    func subscribe(_ t: Target, _ r: Relay) {
        r.subscribe("live-" + t.rawValue, filters: filters(t))
    }

    /// A relay's events, its ends of stored events and its subscriptions after AUTH (every
    /// connection: a reconnect or the next launch asks again from 0 once AUTH succeeds).
    func wireAnswers(_ r: Relay, _ t: Target) {
        r.authSigner = signer
        r.onEvent = { [weak self] _, ev in self?.add([ev]) }
        r.onEOSE = { [weak self, weak r] sub in
            guard let self, let r else { return }
            self.eose(t, sub, relay: r)
        }
        r.refilter = { [weak self] id in
            guard let self, id == "live-" + t.rawValue else { return nil }
            // from 0 until one answer after AUTH came in this run; a later reconnect asks from
            // `since`, which that answer made safe (replaying 2000 events at every reconnect kept
            // the phone busy and live events late)
            self.lock.lock(); let had = self.authedAnswer.contains(t); self.lock.unlock()
            return self.filters(t, fromStart: !had)
        }
    }

    /// The groups (39000 `d`) this device holds metadata of.
    private var knownGroups = Set<String>()

    /// The filters that ask the whole history of newly learned groups.
    static func historyFilters(_ groups: [String]) -> [[String: Any]] {
        [["kinds": kindsGroups, "#h": groups, "limit": 2000]]
    }

    /// A group first learned from the metadata after this run's from-0 answer: its own history
    /// is asked from 0 (the live subscription asks from `since`, which is past it).
    func historyOf(_ groups: [String]) {
        if localOnly { return }
        Task { [weak self] in
            guard let self else { return }
            self.add(await self.query(.groups, SyncEngine.historyFilters(groups), timeout: 15))
        }
    }

    /// The relays whose answer after AUTH (an EOSE of the live subscription) came in this run.
    private var authedAnswer = Set<Target>()

    /// Every 15 s and when the app comes back: a relay that sent nothing for IDLE seconds is asked
    /// for a pong; a socket that doesn't answer is dropped and connected again (a phone back from
    /// sleep, or a network that changed, can hold a dead socket that still looks up: no live events).
    public func checkSockets(idle: TimeInterval = 25) {
        lock.lock(); let rs = Array(relays.values); lock.unlock()
        for r in rs where r.isUp && r.quietFor >= idle { r.ping() }
    }

    /// An end of stored events from relay R. Before AUTH the answer holds only public events: it
    /// is not "the relay's answer" (no catch-up done, no deleted-by-absence check) while AUTH is
    /// asked or may still be; the subscription sent again after AUTH (from 0) answers instead. A
    /// relay that never asks for AUTH within 5 s: that first answer counts.
    func eose(_ t: Target, _ sub: String, relay r: Relay) {
        if sub.hasPrefix("live-"), r.authSigner != nil, !r.authed {
            if r.challenged { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + SyncEngine.authGrace) { [weak self, weak r] in
                guard let self, let r, !r.challenged, !r.authed else { return }
                self.eose(t, sub)
            }
            return
        }
        if sub.hasPrefix("live-"), r.authed { lock.lock(); authedAnswer.insert(t); lock.unlock() }
        eose(t, sub)
    }
    static var authGrace: TimeInterval = 5

    func eose(_ t: Target, _ sub: String) {
        if sub.hasPrefix("live-") {
            lock.lock()
            let was = fullSync.remove(t) != nil
            let left = fullSync
            lock.unlock()
            if was { db.set("full-sync", left.map(\.rawValue)) }
            onEOSE?(t)
        }
        guard t == .groups else { return }
        if access != .ok { access = .ok; changed() }
        firstChannel()
    }

    func closed(_ t: Target, _ sub: String, _ reason: String) {
        if reason.hasPrefix("auth-required") { return } // the relay resubscribes after AUTH
        if t == .groups { noteRefusal(reason) }
    }

    func noteRefusal(_ reason: String) {
        if Rx("^(restricted|blocked)|pass|member", [.caseInsensitive]).test(reason) {
            access = .denied
            changed()
        }
    }

    /// A new belfry has no channel yet: the first member in opens #general.
    func firstChannel() {
        lock.lock()
        let tried = firstChannelTried
        firstChannelTried = true
        let hasAny = events.values.contains { $0.kind == 39000 }
        lock.unlock()
        guard !tried, !hasAny, !guestMode.reading else { return }
        for d in Actions.createChannel(id: generalId, name: "general", about: "Everything about \(config.name). Say hi 👋") { enqueue(d) }
    }

    public func connect(_ t: Target) async {
        if localOnly { return }
        lock.lock()
        if relays[t]?.isUp == true || connecting.contains(t) || !online { lock.unlock(); return }
        connecting.insert(t)
        lock.unlock()
        defer { lock.lock(); connecting.remove(t); lock.unlock() }
        do {
            let r = try await relay(t)
            subscribe(t, r)
            await flush()
        } catch {
            retryLater(t)
        }
    }

    // ---- life cycle -------------------------------------------------------------------------------

    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let up = path.status == .satisfied
            let was = self.online
            self.online = up
            if up != was {
                self.changed()
                if up { self.wake() } else { self.dropSockets() }
            }
        }
        monitor.start(queue: DispatchQueue.global())
        DispatchQueue.main.async {
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        }
        if !localOnly { wake() } // local-only (demo) data is seeded by the app
        flushSoon()
    }

    /// Network back, app in the foreground, pull to refresh: reconnect, catch up, send.
    public func wake() {
        lock.lock(); attempts = [:]; lock.unlock()
        // a socket that looks up may have died while the app slept: ask each one now
        checkSockets(idle: 0)
        Task {
            await connect(.groups)
            await connect(.main)
            await flush()
        }
    }

    /// Re-sends the subscriptions (catching up from the latest event).
    public func refresh() async {
        if localOnly { return }
        for t in [Target.groups, .main] {
            if let r = try? await relay(t) { subscribe(t, r) }
        }
        await flush()
    }

    private func tick() {
        if localOnly { return }
        if online { for t in [Target.groups, .main] where relays[t]?.isUp != true { Task { await connect(t) } } }
        checkSockets()
        if outboxItems().contains(where: { $0.status != .failed }) { flushSoon() }
    }

    private func dropSockets() {
        lock.lock()
        let rs = relays
        relays = [:]
        lock.unlock()
        for r in rs.values { r.onDisconnect = nil; r.close() }
    }

    public func stop() {
        monitor.cancel()
        DispatchQueue.main.async { self.watchdog?.invalidate() }
        dropSockets()
    }

    public var relaysUp: Bool {
        if localOnly { return true }
        lock.lock(); defer { lock.unlock() }
        return relays[.groups]?.isUp == true
    }
}
