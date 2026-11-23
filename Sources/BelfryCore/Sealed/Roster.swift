import Foundation

// Sealed conversations (collective-belfry docs/sealed.md, version 1): which devices are a
// person's. A roster (kind 8560) is signed by a device; the chain starts at the root the
// account's anchor (30078 `belfry:sealed`) names. Pure: the caller reads the events.

public enum SealedKind {
    public static let roster = 8560
    public static let keys = 8561
    public static let request = 8562
    public static let history = 8564
    public static let anchorD = "belfry:sealed"
    /// My device names: one event per device, `d` = this prefix + the device's key.
    public static let deviceD = "belfry:device:"
    public static let maxDevices = 20
}

/// One roster event, read.
public struct Roster: Hashable, Sendable {
    public let id: String
    public let signer: String
    public let account: String
    public let n: Int
    public let prev: String?
    public let lb: String
    public let devices: [String]
    public let ready: Bool
    public let createdAt: Int
    /// ["endorse", <device>]: the devices that added themselves and that this roster's signer
    /// answers for ("It was me", sealed.md 5.7).
    public let endorses: [String]

    /// nil for anything that is not a well-formed roster (the signature is the caller's check).
    public init?(_ e: NostrEvent) {
        // exactly one p, one n, one lb, at most one prev: a tag given twice makes it invalid
        func count(_ name: String) -> Int { e.tags.filter { $0.first == name }.count }
        guard e.kind == SealedKind.roster, count("p") == 1, count("n") == 1, count("lb") == 1, count("prev") <= 1,
              let p = e.tag("p"), isHex64(p), let nText = e.tag("n"), let n = Int(nText), n >= 1, String(n) == nText,
              let lb = e.tag("lb"), isHex64(lb) else { return nil }
        // invalid: no device, more than 20, one listed twice
        let devices = e.tagValues("device")
        guard (1...SealedKind.maxDevices).contains(devices.count), devices.allSatisfy(isHex64), Set(devices).count == devices.count else { return nil }
        let prev = e.tag("prev")
        if let prev, !isHex64(prev) { return nil }
        id = e.id; signer = e.pubkey; account = p; self.n = n; self.prev = prev; self.lb = lb
        self.devices = devices
        ready = e.tags.contains { $0.first == "ready" }
        createdAt = e.createdAt
        endorses = e.tags.filter { $0.first == "endorse" && $0.count >= 2 && isHex64($0[1]) }.map { $0[1] }
    }
}

/// A person's valid chain (sealed.md 3.3).
public struct RosterChain: Hashable, Sendable {
    public let account: String
    /// Root first, head last.
    public let rosters: [Roster]
    /// The end of the anchored path, as the anchor gives it (the root when it names no usable
    /// head); what comes after it in `rosters` is not anchored yet.
    public let anchored: String
    /// The head's devices that added themselves and are still limited (no "It was me" yet), in
    /// the head's order: they read and write, and can neither add nor remove a device.
    public var unendorsed: [String] = []

    public var root: Roster { rosters[0] }
    public var head: Roster { rosters[rosters.count - 1] }
    /// Once a chain has had `ready`, it stays ready.
    public var ready: Bool { rosters.contains { $0.ready } }
    public var devices: [String] { head.devices }
    public var lb: String { head.lb }

    /// The valid chain of ACCOUNT from its anchor (the newest 30078 `belfry:sealed` it signed) and
    /// every roster that names it (sealed.md 3.3). The anchored path runs from the root to the
    /// anchor's `head`; a roster off that path that does not descend from its end is ignored
    /// whatever its id (a dropped device cannot fork the chain). After the path's end each valid
    /// step is followed, the lower id winning for now. PINNEDHEAD: the head this client last
    /// accepted: an anchor whose head is an ancestor of it is not followed back.
    /// VERIFY: check ids and signatures here (events from the local log were checked when stored).
    public static func resolve(account: String, anchor: NostrEvent?, rosters events: [NostrEvent], pinnedHead: String? = nil, verify: Bool = true) -> RosterChain? {
        // the anchor: exactly one d and one root (a tag given twice makes it invalid)
        guard let anchor, anchor.kind == 30078, anchor.pubkey == account, anchor.tag("d") == SealedKind.anchorD,
              anchor.tags.filter({ $0.first == "d" }).count == 1, anchor.tags.filter({ $0.first == "root" }).count == 1,
              let rootId = anchor.tag("root"), !verify || anchor.isValid else { return nil }
        var byId = [String: Roster]()
        var byPrev = [String: [Roster]]()
        for e in events where e.kind == SealedKind.roster {
            guard let r = Roster(e), r.account == account, !verify || e.isValid else { continue }
            byId[r.id] = r
            if let p = r.prev { byPrev[p, default: []].append(r) }
        }
        guard let root = byId[rootId], root.n == 1, root.prev == nil, root.devices.contains(root.signer) else { return nil }
        /// The walk along the chain: the rosters taken, the letterboxes and the devices the chain
        /// ever had, and the devices that added themselves and that no older device has signed
        /// after yet (sealed.md 5.7, tightened 2026-11-23).
        struct Walk {
            var chain: [Roster]
            var lbs: Set<String>
            var ever: Set<String>
            /// A device that added itself, still limited → the devices of the roster before its join.
            var unendorsed: [String: Set<String>] = [:]

            /// NEXT is a valid step after the last roster. JOIN (only on the anchored path: not
            /// anchored it is nothing, anyone can sign one): a roster signed by a device the
            /// chain NEVER had, not dated before its prev, with prev's devices in their order plus
            /// the signer last, and a letterbox the chain never had. A normal roster signed by
            /// a device that added itself is invalid until a roster of an older device (one in
            /// the head before that join, or a joiner endorsed since) has come after the join.
            mutating func step(_ next: Roster, join: Bool) -> Bool {
                let cur = chain[chain.count - 1]
                guard next.prev == cur.id, next.n == cur.n + 1 else { return false }
                if cur.devices.contains(next.signer) {
                    guard unendorsed[next.signer] == nil else { return false }
                    let missing = cur.devices.contains { !next.devices.contains($0) }
                    guard missing ? !lbs.contains(next.lb) : next.lb == cur.lb else { return false }
                    // only an explicit ["endorse", <device>] lifts a joiner's limits, and only
                    // from a device that was in the roster before that join (1440e79)
                    for d in next.endorses where unendorsed[d]?.contains(next.signer) == true { unendorsed[d] = nil }
                } else {
                    guard join, !ever.contains(next.signer), next.createdAt >= cur.createdAt,
                          next.devices == cur.devices + [next.signer], !lbs.contains(next.lb) else { return false }
                    unendorsed[next.signer] = Set(cur.devices)
                }
                chain.append(next)
                lbs.insert(next.lb)
                ever.formUnion(next.devices)
                // a joiner that left the head is no longer waiting
                unendorsed = unendorsed.filter { next.devices.contains($0.key) }
                return true
            }
        }
        /// The walk from the root to ID when every step is valid; nil otherwise.
        func path(to id: String) -> Walk? {
            var back = [Roster]()
            var cur = byId[id]
            while let c = cur, c.id != root.id {
                guard back.count <= byId.count, let p = c.prev else { return nil }
                back.append(c)
                cur = byId[p]
            }
            guard cur?.id == root.id else { return nil }
            var w = Walk(chain: [root], lbs: [root.lb], ever: Set(root.devices))
            for r in back.reversed() { guard w.step(r, join: true) else { return nil } }
            return w
        }
        // one well-formed head tag; none, several or a malformed one = absent (the root alone)
        let heads = anchor.tags.filter { $0.first == "head" }
        let named = heads.count == 1 && heads[0].count >= 2 && isHex64(heads[0][1]) ? heads[0][1] : nil
        var walk = named.flatMap(path(to:)) ?? Walk(chain: [root], lbs: [root.lb], ever: Set(root.devices))
        let anchored = walk.chain[walk.chain.count - 1].id
        // no going back: the anchor's head is an ancestor of the head already accepted
        let at = walk.chain.count - 1
        if let pinnedHead, let pinned = path(to: pinnedHead), pinned.chain.count > walk.chain.count, pinned.chain[at].id == walk.chain[at].id {
            walk = pinned
        }
        while let cur = walk.chain.last {
            // published, not anchored yet: the lower id wins for now (never a join)
            let next = (byPrev[cur.id] ?? []).sorted { $0.id.lowercased() < $1.id.lowercased() }.first { r in
                var probe = walk
                return probe.step(r, join: false)
            }
            guard let next, walk.step(next, join: false) else { break }
        }
        let chain = walk.chain
        let limited = chain[chain.count - 1].devices.filter { walk.unendorsed[$0] != nil }
        return RosterChain(account: account, rosters: chain, anchored: anchored, unendorsed: limited)
    }

    /// Whether a seal signed by DEVICE counts for a rumor of this account written at RUMORAT:
    /// a device of the head, or of an earlier roster when the rumor is not after the roster that
    /// dropped it (sealed.md 4).
    public func accepts(device: String, rumorAt: Int) -> Bool {
        if head.devices.contains(device) { return true }
        for i in 0..<(rosters.count - 1) where rosters[i].devices.contains(device) && !rosters[i + 1].devices.contains(device) {
            if rumorAt <= rosters[i + 1].createdAt { return true }
        }
        return false
    }

    /// Whether DEVICE is in any roster of the chain (who may hand keys over, sealed.md 5.5).
    public func everHad(_ device: String) -> Bool { rosters.contains { $0.devices.contains(device) } }

    public struct Change: Hashable, Sendable {
        public let device: String
        public let added: Bool
        public let at: Int
        /// The roster that made the change.
        public let roster: String
        /// Who signed it (for "from <device>" on my own list).
        public let by: String
    }

    /// One entry per device that appears or disappears, roster after roster (the notices of
    /// sealed.md 3.4; the root's own devices are not changes).
    public var changes: [Change] {
        var out = [Change]()
        guard rosters.count > 1 else { return out }
        for i in 1..<rosters.count {
            let a = rosters[i - 1], b = rosters[i]
            for d in b.devices where !a.devices.contains(d) { out.append(Change(device: d, added: true, at: b.createdAt, roster: b.id, by: b.signer)) }
            for d in a.devices where !b.devices.contains(d) { out.append(Change(device: d, added: false, at: b.createdAt, roster: b.id, by: b.signer)) }
        }
        return out
    }

    /// The first roster that contains DEVICE: when it was added, and the device that signed it
    /// (nil when it signed itself in: the root).
    public func joined(_ device: String) -> (at: Int, from: String?)? {
        // the roster that LAST added it (removed and added again: the later one)
        guard let i = rosters.indices.last(where: { rosters[$0].devices.contains(device) && ($0 == 0 || !rosters[$0 - 1].devices.contains(device)) }) else { return nil }
        let r = rosters[i]
        return (r.createdAt, r.signer == device ? nil : r.signer)
    }

    // ---- what a device publishes ---------------------------------------------------------------

    /// A roster to sign with a device key.
    /// ENDORSE: the devices that added themselves and that this roster's signer answers for
    /// ("It was me" / Allow, sealed.md 5.7): one ["endorse", <device>] each, last, after `ready`.
    public static func template(account: String, n: Int, prev: String?, lb: String, devices: [String], ready: Bool, endorse: [String] = [], now: Int = .now) -> EventTemplate {
        var tags: [Tag] = [["p", account], ["n", String(n)]]
        if let prev { tags.append(["prev", prev]) }
        tags.append(["lb", lb])
        tags += devices.map { ["device", $0] }
        if ready { tags.append(["ready"]) }
        tags += endorse.map { ["endorse", $0] }
        return EventTemplate(kind: SealedKind.roster, content: "", tags: tags, createdAt: now)
    }

    /// The anchor, signed by the account (through the signer).
    public static func anchor(root: String, head: String? = nil, now: Int = .now) -> EventTemplate {
        EventTemplate(kind: 30078, content: "", tags: [["d", SealedKind.anchorD], ["root", root], ["head", head ?? root]], createdAt: now)
    }
}
