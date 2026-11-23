import Foundation

/// The device lists this app knows (docs/sealed-v2.md 3): read from the belfry's key only,
/// remembered for good per account, and what follows from them for one device: which
/// conversations are sealed, the wraps of a message, whether an opened rumor counts.
///
/// It reads and decides; it writes nothing but its own memory (the belfry writes the lists).
public final class DeviceLists: @unchecked Sendable {
    public let me: String
    public let belfry: String
    public let devicePub: String
    private let device: Data
    private let db: Database
    private let lock = NSLock()
    private var seen: [String: ListsSeen]
    /// The accounts whose list was asked and completely answered in this run, and when.
    private var answered = [String: Int]()

    /// Asks the relay (after AUTH, complete to EOSE) for the lists of these accounts; nil = no
    /// complete answer.
    public var ask: (([String]) async -> [NostrEvent]?)?
    /// Something changed (a list new to this app).
    public var onChange: (() -> Void)?

    private static let key = "sealed-v2-lists"

    public init?(me: String, belfry: String, deviceSecret: Data, db: Database) {
        guard isHex64(me), isHex64(belfry), let pub = try? Keys.publicKeyHex(secret: deviceSecret) else { return nil }
        self.me = me; self.belfry = belfry; device = deviceSecret; devicePub = pub; self.db = db
        seen = db.get(DeviceLists.key, as: [String: ListsSeen].self) ?? [:]
    }

    // ---- the lists ---------------------------------------------------------------------------

    public func list(_ account: String) -> DeviceList? { lock.lock(); defer { lock.unlock() }; return seen[account]?.newest }
    public func lists(_ account: String) -> ListsSeen { lock.lock(); defer { lock.unlock() }; return seen[account] ?? ListsSeen() }

    /// Events that may be lists (from the live subscription, a question's answer, a read by id):
    /// each well-formed one of the belfry's is remembered. True when one was new.
    @discardableResult
    public func take(_ events: [NostrEvent], now: Int = .now) -> Bool {
        var new = false
        lock.lock()
        for e in events where e.kind == 30078 && e.pubkey == belfry {
            guard e.isValid, let l = DeviceList(e, belfry: belfry), l.createdAt <= now + DeviceList.ahead else { continue }
            var s = seen[l.account] ?? ListsSeen()
            if s.see(l, now: now) { seen[l.account] = s; new = true }
        }
        let all = seen
        lock.unlock()
        if new { db.set(DeviceLists.key, all); onChange?() }
        return new
    }

    /// The lists of ACCOUNTS as the relay has them now (wait at most 3 s). Returns the accounts
    /// that were completely answered.
    @discardableResult
    public func refresh(_ accounts: [String], now: Int = .now) async -> Set<String> {
        let wanted = Array(Set(accounts.filter(isHex64)))
        guard !wanted.isEmpty, let ask, let found = await ask(wanted) else { return [] }
        take(found, now: now)
        lock.lock(); for a in wanted { answered[a] = now }; lock.unlock()
        return Set(wanted)
    }

    /// Whether this device is on my own newest list (§3.1: until it is, it seals nothing).
    public var listed: Bool { list(me)?.devices.contains(devicePub) == true }

    // ---- conversations -------------------------------------------------------------------------

    /// The state of a conversation between PARTICIPANTS (me included), from the lists read in the
    /// last 10 minutes of this run.
    public func state(_ participants: [String], now: Int = .now) -> SealedV2.State {
        lock.lock(); defer { lock.unlock() }
        var lists = [String: DeviceList]()
        var read = Set<String>()
        var nonEmpty = Set<String>()
        for p in participants {
            if let at = answered[p], now - at <= 600 { read.insert(p) }
            if let s = seen[p] {
                if let n = s.newest { lists[p] = n }
                if s.seen.contains(where: { !$0.list.devices.isEmpty }) { nonEmpty.insert(p) }
            }
        }
        return SealedV2.state(participants: participants, lists: lists, read: read, seenNonEmpty: nonEmpty)
    }

    /// The `list` tags a rumor of this conversation carries.
    public func listTags(_ participants: [String]) -> [Tag] { SealedV2.listTags(participants.compactMap(list)) }

    /// One wrap per device of every participant, this device included (§4.1).
    public func wraps(_ rumor: NostrEvent, participants: [String]) throws -> [NostrEvent] {
        var out = [NostrEvent]()
        for p in Array(Set(participants)).sorted() {
            for d in list(p)?.devices ?? [] { out.append(try SealedV2.wrap(rumor, device: device, to: d, of: p)) }
        }
        return out
    }

    // ---- receiving -----------------------------------------------------------------------------

    public enum Opened: Sendable {
        /// The rumor counts (its seal's device may speak for its author).
        case accepted(NostrEvent, sealPubkey: String)
        /// It opens, but its device is on no list of its author this app has seen: kept and
        /// judged again when that list is read.
        case unjudged(NostrEvent, sealPubkey: String)
        /// Not a version 2 wrap for this device, or it does not open.
        case no
    }

    public func open(_ wrap: NostrEvent) -> Opened {
        guard SealedV2.device(of: wrap) == devicePub, case .opened(let rumor, let seal) = SealedV2.open(wrap, device: device) else { return .no }
        return lists(rumor.pubkey).accepts(device: seal, rumorAt: rumor.createdAt) ? .accepted(rumor, sealPubkey: seal) : .unjudged(rumor, sealPubkey: seal)
    }

    /// §3.3: the list a correspondent's message names for MY account, when this app never saw it.
    public func unseenListNamed(by rumor: NostrEvent) -> String? {
        guard let id = SealedV2.listNamed(rumor, for: me), !lists(me).has(id) else { return nil }
        return id
    }

    /// §6.4: the devices of my newest list that were not on the list seen before it, this one left out.
    public func addedDevices() -> [String] { lists(me).added.filter { $0 != devicePub } }
}
