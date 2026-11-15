import Foundation

// The read state shared by a person's devices (SPEC 19.27; Android engine/ReadSync.kt): kept in
// the store, merged with every `belfry:read` event of mine that arrives, published (NIP-44 to
// myself, through the outbox, on the community relay) once the community relay answered this
// session and only when the relay's newest copy lacks something. Guests, guest mode and the
// demo keep it on the device.

public final class ReadSync: @unchecked Sendable {
    public static let kState = "read-state"
    public static let kRemote = "read-state-remote"
    public static let debounce: TimeInterval = 3
    public static let minGap: TimeInterval = 10

    private let engine: SyncEngine
    private let lock = NSLock()
    private var local: ReadState
    private var remote = ReadState.empty
    private var remoteAt = 0
    private var checked = false
    private var handled = Set<String>()
    private var timer: Task<Void, Never>?
    private var lastPublish = Date.distantPast
    private var processing = false
    /// False keeps it on the device (guests, guest mode, the demo).
    public var shared: () -> Bool = { true }
    public var clock: () -> Int = { Int.now }
    /// Told on every change (any thread).
    public var onChange: ((ReadState) -> Void)?

    struct Remote: Codable { let at: Int; let state: String }

    /// SEED: the old per-device DM marks, taken once on the first run (channels start read).
    public init(engine: SyncEngine, seedD: () -> [String: Int]) {
        self.engine = engine
        if let kept: String = engine.db.get(ReadSync.kState) {
            local = ReadState.parse(kept)
        } else {
            var r = ReadState(s: Int.now)
            for (conv, at) in seedD() { r = r.mark("d", conv, at) }
            local = r
            engine.db.set(ReadSync.kState, r.serialize())
        }
        if let r: Remote = engine.db.get(ReadSync.kRemote) {
            remoteAt = r.at
            remote = ReadState.parse(r.state)
        }
    }

    public var state: ReadState { lock.lock(); defer { lock.unlock() }; return local }

    /// Read SEC/KEY up to AT (never backwards).
    public func mark(_ sec: Character, _ key: String, _ at: Int) {
        lock.lock()
        let n = local.mark(sec, key, at)
        if n == local { lock.unlock(); return }
        local = n
        lock.unlock()
        save(n)
        schedule()
    }

    private func save(_ r: ReadState) {
        engine.db.set(ReadSync.kState, r.serialize())
        onChange?(r)
    }

    /// Events that arrived: my `belfry:read` events (exact d) are decrypted and merged.
    public func offer(_ events: [NostrEvent]) {
        let me = engine.me
        let mine = events.filter { $0.kind == ReadState.kind && $0.pubkey == me && $0.tag("d") == ReadState.readD }
        guard !mine.isEmpty else { return }
        Task { await process(mine) }
    }

    func process(_ list: [NostrEvent]) async {
        for e in list.sorted(by: { $0.createdAt < $1.createdAt }) {
            lock.lock()
            if handled.contains(e.id) { lock.unlock(); continue }
            handled.insert(e.id)
            lock.unlock()
            guard let text = try? await engine.signer.nip44Decrypt(peer: engine.me, payload: e.content) else { continue }
            let got = ReadState.parse(text)
            lock.lock()
            if e.createdAt >= remoteAt {
                remoteAt = e.createdAt
                remote = got
                engine.db.set(ReadSync.kRemote, Remote(at: remoteAt, state: got.serialize()))
            }
            let next = ReadState.merge(local, got)
            let changed = next.serialize() != local.serialize()
            if changed { local = next }
            lock.unlock()
            if changed { save(next) }
        }
        schedule()
    }

    /// The community relay answered the live subscription (EOSE): publishing may start.
    public func relayAnswered() {
        lock.lock()
        let was = checked
        checked = true
        lock.unlock()
        if !was { schedule() }
    }

    private func needed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return checked && !ReadState.covers(remote, local, now: clock())
    }

    /// 3 s after the last change, at most one every 10 s.
    private func schedule() {
        guard shared(), needed() else { return }
        lock.lock()
        timer?.cancel()
        let gap = max(0, lastPublish.addingTimeInterval(ReadSync.minGap).timeIntervalSinceNow)
        let wait = max(ReadSync.debounce, gap)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.publishNow()
        }
        lock.unlock()
    }

    /// The app goes to the background: publish now what waits.
    public func flush() {
        guard shared(), needed() else { return }
        lock.lock(); timer?.cancel(); timer = nil; lock.unlock()
        Task { await publishNow() }
    }

    private func publishNow() async {
        guard shared(), needed() else { return }
        lock.lock()
        let out = ReadState.merge(local, remote).prune(now: clock())
        let at = max(remoteAt + 1, clock())
        lock.unlock()
        guard let content = try? await engine.signer.nip44Encrypt(peer: engine.me, plaintext: out.serialize()) else { schedule(); return }
        // a newer read state replaces one still waiting in the outbox
        for item in engine.outboxItems() where item.kind == ReadState.kind && item.tags.contains(["d", ReadState.readD]) && item.signed == nil {
            engine.cancel(item.localId)
        }
        engine.enqueue(Draft(.main, kind: ReadState.kind, content: content, tags: [["d", ReadState.readD]]))
        lock.lock()
        lastPublish = Date()
        remote = out
        remoteAt = at
        engine.db.set(ReadSync.kRemote, Remote(at: at, state: out.serialize()))
        lock.unlock()
    }
}

// ---- what is unread (SPEC 19.27) ----------------------------------------------------------------

public extension Derive {
    /// A channel's top-level messages by someone else after its mark.
    func unreadIn(_ groupId: String, _ r: ReadState, now: Int) -> Int {
        let upTo = r.readUpTo("c", groupId, now: now)
        var n = 0
        for m in messages(groupId).reversed() {
            if m.ev.createdAt <= upTo { break }
            if m.ev.pubkey != me { n += 1 }
        }
        return n
    }

    /// A thread's replies by someone else after its mark, only when I am in it.
    func unreadInThread(_ groupId: String, _ rootId: String, _ r: ReadState, now: Int) -> Int {
        let replies = threadReplies(groupId, rootId)
        guard !replies.isEmpty else { return 0 }
        let mine = message(groupId, rootId)?.ev.pubkey == me || replies.contains { $0.ev.pubkey == me } || (r.t[rootId] ?? 0) > r.floor("t", now: now)
        guard mine else { return 0 }
        let upTo = r.readUpTo("t", rootId, now: now)
        return replies.filter { $0.ev.pubkey != me && $0.ev.createdAt > upTo }.count
    }

    /// What reading a channel marks: its newest kind 9 (mine included).
    func channelMark(_ groupId: String) -> Int? { messages(groupId).map(\.ev.createdAt).max() }

    /// What reading a thread marks: its newest reply, else the message itself.
    func threadMark(_ groupId: String, _ rootId: String) -> Int? {
        threadReplies(groupId, rootId).map(\.ev.createdAt).max() ?? message(groupId, rootId)?.ev.createdAt
    }

    /// A mention is new after the @Mentions mark and its channel's / thread's.
    static func mentionIsNew(_ r: ReadState, _ e: NostrEvent, now: Int) -> Bool {
        var place = 0
        if e.kind == 9, let h = e.tag("h") { place = r.readUpTo("c", h, now: now) }
        if e.kind == 1111, let root = e.tag("E") ?? e.tag("e") { place = r.readUpTo("t", root, now: now) }
        return e.createdAt > max(r.readUpTo("m", "", now: now), place)
    }
}
