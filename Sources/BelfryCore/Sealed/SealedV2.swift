import Foundation

// Sealed conversations, version 2 (collective-belfry docs/sealed-v2.md, belfry-sh df53525,
// 2026-11-23; Xavier: "We need to trust any device that entered the 6-digit"): one list of
// devices per account, written by the belfry; every sealed message wrapped once per device of
// every participant. No chain, no letterbox, nothing to hand over, nothing locked.

/// One device list, read (§3.1).
public struct DeviceList: Hashable, Sendable, Codable {
    public let id: String
    public let account: String
    public let createdAt: Int
    public let devices: [String]

    public static let prefix = "belfry:devices:"
    public static let max = 20
    /// Readers ignore a list dated more than 10 minutes ahead of their clock.
    public static let ahead = 600

    public static func d(_ account: String) -> String { prefix + account }

    /// The filter an app reads ACCOUNT's list with: from the belfry's key only, without `since`.
    public static func filter(belfry: String, accounts: [String]) -> [String: Any] {
        ["kinds": [30078], "authors": [belfry], "#d": accounts.map(d)]
    }

    /// nil for anything that is not a well-formed list signed by BELFRY (the signature itself is
    /// the caller's check): exactly one d and one p naming the same account, 0 to 20 devices,
    /// none twice.
    public init?(_ e: NostrEvent, belfry: String) {
        func all(_ name: String) -> [Tag] { e.tags.filter { $0.first == name } }
        guard e.kind == 30078, !belfry.isEmpty, e.pubkey == belfry, all("d").count == 1, all("p").count == 1,
              let d = e.tag("d"), d.hasPrefix(DeviceList.prefix), let p = e.tag("p"), isHex64(p), d == DeviceList.d(p) else { return nil }
        let devices = all("device").compactMap { $0.count >= 2 ? $0[1] : nil }
        guard devices.count == all("device").count, devices.count <= DeviceList.max, devices.allSatisfy(isHex64),
              Set(devices).count == devices.count else { return nil }
        id = e.id; account = p; createdAt = e.createdAt; self.devices = devices
    }

    public init(id: String, account: String, createdAt: Int, devices: [String]) {
        self.id = id; self.account = account; self.createdAt = createdAt; self.devices = devices
    }

    /// The newest of ACCOUNT's lists among EVENTS: `created_at`, then the lower id; never from
    /// another author, never one dated more than 10 minutes ahead.
    public static func newest(_ events: [NostrEvent], belfry: String, account: String, now: Int = .now) -> DeviceList? {
        events.compactMap { DeviceList($0, belfry: belfry) }
            .filter { $0.account == account && $0.createdAt <= now + ahead }
            .max { a, b in a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id.lowercased() > b.id.lowercased() }
    }
}

/// What an app remembers per account (§3.2): the lists it has seen, for good.
public struct ListsSeen: Hashable, Sendable, Codable {
    public struct Seen: Hashable, Sendable, Codable {
        public let list: DeviceList
        /// When this app first saw it.
        public let at: Int
    }
    public private(set) var seen: [Seen] = []

    public init() {}

    /// The newest list seen (by its own date, then the lower id).
    public var newest: DeviceList? {
        seen.map(\.list).max { a, b in a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id.lowercased() > b.id.lowercased() }
    }

    public func has(_ id: String) -> Bool { seen.contains { $0.list.id == id } }

    /// LIST was read at NOW. True when it is new to this app.
    @discardableResult
    public mutating func see(_ list: DeviceList, now: Int = .now) -> Bool {
        guard !has(list.id) else { return false }
        seen.append(Seen(list: list, at: now))
        return true
    }

    /// When this app first saw a list of the account WITHOUT device S, after having seen one
    /// with it (nil: never listed, or still on every list seen since).
    public func firstSeenWithout(_ s: String) -> Int? {
        let byDate = seen.sorted { $0.list.createdAt != $1.list.createdAt ? $0.list.createdAt < $1.list.createdAt : $0.at < $1.at }
        guard let first = byDate.firstIndex(where: { $0.list.devices.contains(s) }) else { return nil }
        return byDate[first...].filter { !$0.list.devices.contains(s) }.map(\.at).min()
    }

    /// §4.2: a seal by S counts for a rumor of this account dated RUMORAT when S is on the
    /// newest list, or was on a list seen and the rumor is not dated after this app first saw a
    /// list without S (a removed device cannot go on writing as the account).
    public func accepts(device s: String, rumorAt: Int) -> Bool {
        if newest?.devices.contains(s) == true { return true }
        guard seen.contains(where: { $0.list.devices.contains(s) }) else { return false }
        guard let gone = firstSeenWithout(s) else { return true }
        return rumorAt <= gone
    }

    /// §6.4: the devices of the newest list that were not on the list seen before it. None for
    /// the first list an app ever sees.
    public var added: [String] {
        let byDate = seen.map(\.list).sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.lowercased() > $1.id.lowercased() }
        guard byDate.count >= 2 else { return [] }
        let last = byDate[byDate.count - 1], before = byDate[byDate.count - 2]
        return last.devices.filter { !before.devices.contains($0) }
    }
}

public enum SealedV2 {
    /// A conversation's devices may total at most this many; over it, it is not sealed and says so.
    public static let maxDevices = 100
    /// "Too many devices to encrypt for everyone here".
    public static let tooMany = "Too many devices to encrypt for everyone here"
    public static let ready = "Getting your messages ready…"
    public static let notListed = "This device isn't on your device list yet."
    /// How long a signed-in device waits to see itself on its list before saying so.
    public static let listWait = 15

    public enum State: Equatable, Sendable {
        /// Every participant has a list with at least one device, 100 devices or fewer in all.
        case sealed
        /// Over 100 devices: not sealed, said in one line; never a silent downgrade.
        case tooMany
        /// Someone has no list (an agent, an account that holds its own key): not sealed.
        case notSealed
        /// A list cannot be read, or one that was seen non-empty is now missing or empty: hold.
        case hold
    }

    /// LISTS: per participant, the newest list read now (nil: none came back in a complete
    /// answer). READ: the accounts whose answer was complete. SEENNONEMPTY: the accounts this app
    /// ever saw a non-empty list for.
    public static func state(participants: [String], lists: [String: DeviceList], read: Set<String>, seenNonEmpty: Set<String>) -> State {
        var total = 0
        var unsealed = false
        for p in participants {
            guard read.contains(p) else { return .hold }
            guard let l = lists[p], !l.devices.isEmpty else {
                if seenNonEmpty.contains(p) { return .hold }
                unsealed = true
                continue
            }
            total += l.devices.count
        }
        if unsealed { return .notSealed }
        return total > maxDevices ? .tooMany : .sealed
    }

    /// §3.3: the list each participant's copy was sealed to, inside the rumor.
    public static func listTags(_ lists: [DeviceList]) -> [Tag] {
        lists.sorted { $0.account < $1.account }.map { ["list", $0.account, $0.id] }
    }

    /// The list a rumor names for ACCOUNT (exactly one such tag, else nil).
    public static func listNamed(_ rumor: NostrEvent, for account: String) -> String? {
        let all = rumor.tags.filter { $0.count >= 3 && $0[0] == "list" && $0[1] == account }
        return all.count == 1 && isHex64(all[0][2]) ? all[0][2] : nil
    }

    /// §4.1: one seal (signed by the sending device) and one gift wrap of RUMOR for device D of
    /// ACCOUNT. Silent when D's account is the rumor's own author.
    public static func wrap(_ rumor: NostrEvent, device: Data, to d: String, of account: String, now: Int = .now) throws -> NostrEvent {
        // the same envelope as version 1's, with the device where the letterbox was: its tag is d
        try Sealed.wrap(rumor, device: device, to: account, lb: d, now: now, silent: account == rumor.pubkey, keyTag: "d")
    }

    /// The device a version 2 wrap is for (exactly one d, 64 hex), nil for anything else.
    public static func device(of wrap: NostrEvent) -> String? {
        let all = wrap.tags.filter { $0.first == "d" }
        guard wrap.kind == 1059, all.count == 1, all[0].count >= 2, isHex64(all[0][1]), wrap.tags.first(where: { $0.first == "lb" }) == nil else { return nil }
        return all[0][1]
    }

    /// Wrap → seal (signature checked) → rumor, with this device's own secret.
    public static func open(_ wrap: NostrEvent, device: Data) -> Sealed.Opening {
        guard SealedV2.device(of: wrap) != nil else { return .invalid }
        return Sealed.open(wrap, secret: device)
    }

    /// The read of §4.2.
    public static func filter(account: String, device: String) -> [String: Any] {
        ["kinds": [1059], "#p": [account], "#d": [device]]
    }
}
