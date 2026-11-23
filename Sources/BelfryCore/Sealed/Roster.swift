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
        /// NEXT is a valid step after CUR, given the letterboxes the chain had so far.
        /// JOIN: on the anchored path a device may add ITSELF (sealed.md 5.7, 2026-11-23): its
        /// signer is NOT in prev's devices; its devices are exactly prev's, same order, plus the
        /// signer last; its letterbox is one the chain never had. Not anchored, it is nothing
        /// (anyone can sign one): never past the anchor.
        func valid(_ next: Roster, after cur: Roster, _ lbs: Set<String>, join: Bool = false) -> Bool {
            guard next.prev == cur.id, next.n == cur.n + 1 else { return false }
            guard cur.devices.contains(next.signer) else {
                return join && next.devices == cur.devices + [next.signer] && !lbs.contains(next.lb)
            }
            let missing = cur.devices.contains { !next.devices.contains($0) }
            return missing ? !lbs.contains(next.lb) : next.lb == cur.lb
        }
        /// The rosters from the root to ID when every step is valid; nil otherwise.
        func path(to id: String) -> [Roster]? {
            var back = [Roster]()
            var cur = byId[id]
            while let c = cur, c.id != root.id {
                guard back.count <= byId.count, let p = c.prev else { return nil }
                back.append(c)
                cur = byId[p]
            }
            guard cur?.id == root.id else { return nil }
            var chain = [root]
            var lbs: Set<String> = [root.lb]
            for r in back.reversed() {
                guard valid(r, after: chain[chain.count - 1], lbs, join: true) else { return nil }
                chain.append(r)
                lbs.insert(r.lb)
            }
            return chain
        }
        // one well-formed head tag; none, several or a malformed one = absent (the root alone)
        let heads = anchor.tags.filter { $0.first == "head" }
        let named = heads.count == 1 && heads[0].count >= 2 && isHex64(heads[0][1]) ? heads[0][1] : nil
        var chain = named.flatMap(path(to:)) ?? [root]
        let anchored = chain[chain.count - 1].id
        // no going back: the anchor's head is an ancestor of the head already accepted
        if let pinnedHead, let pinned = path(to: pinnedHead), pinned.count > chain.count, pinned[chain.count - 1].id == chain[chain.count - 1].id {
            chain = pinned
        }
        var lbs = Set(chain.map(\.lb))
        while let cur = chain.last {
            // published, not anchored yet: the lower id wins for now
            guard let next = (byPrev[cur.id] ?? []).filter({ valid($0, after: cur, lbs) }).min(by: { $0.id.lowercased() < $1.id.lowercased() }) else { break }
            chain.append(next)
            lbs.insert(next.lb)
        }
        return RosterChain(account: account, rosters: chain, anchored: anchored)
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
    public static func template(account: String, n: Int, prev: String?, lb: String, devices: [String], ready: Bool, now: Int = .now) -> EventTemplate {
        var tags: [Tag] = [["p", account], ["n", String(n)]]
        if let prev { tags.append(["prev", prev]) }
        tags.append(["lb", lb])
        tags += devices.map { ["device", $0] }
        if ready { tags.append(["ready"]) }
        return EventTemplate(kind: SealedKind.roster, content: "", tags: tags, createdAt: now)
    }

    /// The anchor, signed by the account (through the signer).
    public static func anchor(root: String, head: String? = nil, now: Int = .now) -> EventTemplate {
        EventTemplate(kind: 30078, content: "", tags: [["d", SealedKind.anchorD], ["root", root], ["head", head ?? root]], createdAt: now)
    }
}
