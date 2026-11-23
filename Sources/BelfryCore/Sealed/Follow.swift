import Foundation

// Sealed conversations (docs/sealed.md 3.3 and 5.5): what a client remembers about a person's
// chain (the pin), how it follows the anchor from one read to the next, and who is answered
// without a prompt. A port of the reference (`follow`, `allow_locally`, `answer_without_prompt`
// in the belfry's sealed.py), checked against vectors/sealed.json `follow` and `trust`.

/// What a client remembers about one person's chain. Durable.
public struct SealedPin: Codable, Hashable, Sendable {
    public var root: String
    public var head: String
    /// The ids from the root to the head, as followed.
    public var path: [String]
    /// The head was seen as the end of the anchored path.
    public var anchored: Bool
    /// The furthest roster of the path seen as the anchored end.
    public var anchoredHead: String?
    /// After a switch (my own account): the devices answered without a prompt. Nil: no switch.
    public var trusted: [String]?
    /// The chain's head at the moment of the switch: only rosters after it, seen in later reads,
    /// change `trusted`.
    public var switchHead: String?
    /// The root before a fresh start.
    public var prevRoot: String?

    enum CodingKeys: String, CodingKey {
        case root, head, path, anchored, trusted
        case anchoredHead = "anchored_head", switchHead = "switch_head", prevRoot = "prev_root"
    }
}

public enum SealedFollow {
    public enum Event: String, Sendable { case none, moved, ignoredBack = "ignored_back", `switch`, freshStart = "fresh_start" }

    private static func pin(_ c: RosterChain, seen: String, was: SealedPin? = nil, trusted: Set<String>??  = nil, switchHead: String?? = nil, prevRoot: String?? = nil) -> SealedPin {
        let t: Set<String>? = trusted ?? was?.trusted.map(Set.init)
        return SealedPin(root: c.root.id, head: c.head.id, path: c.rosters.map(\.id), anchored: seen == c.head.id, anchoredHead: seen,
                         trusted: t.map { $0.sorted() }, switchHead: switchHead ?? was?.switchHead, prevRoot: prevRoot ?? was?.prevRoot)
    }

    /// One roster after a switch: a device it drops is no longer trusted; a device it adds is
    /// trusted only when its signer is (as the signer stood before this roster); a device it
    /// merely keeps: nothing.
    /// A device that added itself (5.7) is trusted here only once a device that IS trusted here
    /// has endorsed it: an ["endorse", <device>] on a roster signed by a trusted device that was
    /// in the roster before that join.
    private static func trustStep(_ trusted: inout Set<String>, _ c: RosterChain, _ i: Int) {
        let before = c.rosters[i - 1], r = c.rosters[i]
        let vouches = trusted.contains(r.signer)
        trusted.subtract(before.devices.filter { !r.devices.contains($0) })
        guard vouches, before.devices.contains(r.signer) else { return }
        trusted.formUnion(r.devices.filter { !before.devices.contains($0) })
        for d in r.endorses where r.devices.contains(d) {
            // the join of D before this roster, and its signer's place before that join
            guard let j = c.rosters[..<i].lastIndex(where: { $0.signer == d && $0.devices.last == d }), j > 0,
                  !c.rosters[j - 1].devices.contains(d), c.rosters[j - 1].devices.contains(r.signer) else { continue }
            trusted.insert(d)
        }
    }

    /// PIN moved onto chain C (same root, no switch): the new head and path, and, after a switch,
    /// trust carried over the rosters that are new to this client and descend from the switch
    /// head, in chain order (never by their dates).
    private static func carry(_ p: SealedPin, _ c: RosterChain, seen s: String) -> SealedPin {
        let ids = c.rosters.map(\.id)
        var seen = s
        if let i = ids.firstIndex(of: seen), let a = ids.firstIndex(of: c.anchored) { if a > i { seen = c.anchored } } else { seen = c.anchored }
        var trusted = p.trusted.map(Set.init)
        if var t = trusted, let sw = p.switchHead, let at = ids.firstIndex(of: sw) {
            var known = 0
            while known < min(ids.count, p.path.count), ids[known] == p.path[known] { known += 1 }
            var i = max(known, at + 1)
            while i < ids.count {
                trustStep(&t, c, i)
                i += 1
            }
            trusted = t
        }
        return pin(c, seen: seen, was: p, trusted: .some(trusted))
    }

    /// The chain a client that holds PIN follows now, what it remembers after, and what happened:
    /// `none`, `moved` (the head changed, nothing to tell), `ignoredBack` (the anchor went back
    /// behind a head seen anchored: not followed), `switch` (the anchor left a head seen anchored
    /// for another branch of the same root: told like a fresh start, and only the devices held
    /// before stay trusted) or `freshStart` (another root).
    public static func follow(account: String, anchor: NostrEvent?, rosters: [NostrEvent], pin p: SealedPin?, verify: Bool = true) -> (chain: RosterChain?, pin: SealedPin?, event: Event) {
        guard let c = RosterChain.resolve(account: account, anchor: anchor, rosters: rosters, verify: verify) else { return (nil, p, .none) }
        guard let p else { return (c, pin(c, seen: c.anchored), .none) }
        if c.root.id != p.root {
            return (c, pin(c, seen: c.anchored, trusted: .some(nil), switchHead: .some(nil), prevRoot: .some(p.root)), .freshStart)
        }
        let path = p.path, seen = p.anchoredHead ?? p.root
        // a pin that holds a join past what it saw anchored (stored by an earlier look, or a join
        // that lost its anchor): cut back to before it; a join counts only once seen anchored
        if let at = path.firstIndex(of: seen), at < path.count - 1 {
            let byId = Dictionary(rosters.compactMap { e in Roster(e).map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
            let join = ((at + 1)..<path.count).contains { i in
                guard let r = byId[path[i]], let prev = byId[path[i - 1]] else { return false }
                return !prev.devices.contains(r.signer)
            }
            if join {
                let cut = SealedPin(root: p.root, head: seen, path: Array(path.prefix(at + 1)), anchored: true, anchoredHead: seen,
                                    trusted: p.trusted, switchHead: p.switchHead, prevRoot: p.prevRoot)
                let r = follow(account: account, anchor: anchor, rosters: rosters, pin: cut, verify: verify)
                return (r.chain, r.pin, r.event == .none ? .moved : r.event)
            }
        }
        let ids = c.rosters.map(\.id)
        if let at = path.dropLast().firstIndex(of: c.anchored) {
            // the anchor names an ancestor of the pinned head: the pinned head is kept (with what
            // follows it); told as going back only when it is behind what was seen anchored
            let kept = RosterChain.resolve(account: account, anchor: anchor, rosters: rosters, pinnedHead: p.head, verify: verify)
            let back = path.firstIndex(of: seen).map { at < $0 } ?? false
            guard let kept, kept.rosters.contains(where: { $0.id == p.head }) else { return (nil, p, back ? .ignoredBack : .none) }
            let new = carry(p, kept, seen: seen)
            return (kept, new, back ? .ignoredBack : (new.head != p.head ? .moved : .none))
        }
        if ids.contains(p.head) {
            let new = carry(p, c, seen: seen)
            return (c, new, new.head != p.head ? .moved : .none)
        }
        if ids.contains(seen) { return (c, carry(p, c, seen: seen), .moved) } // a tail that was never anchored gave way
        // the anchor left a head this client saw anchored: a switch
        let held = rosters.compactMap { e -> Roster? in
            guard let r = Roster(e), r.account == account, r.id == p.head, !verify || e.isValid else { return nil }
            return r
        }.first
        var before = Set(held?.devices ?? [])
        if let t = p.trusted { before.formIntersection(t) } // a second switch never widens the first
        // a device the new head does not have is not trusted when it comes back
        let trusted = before.intersection(c.devices)
        return (c, pin(c, seen: c.anchored, was: p, trusted: .some(trusted), switchHead: .some(c.head.id)), .switch)
    }

    /// The person allowed DEVICE on this device (the Allow card): trusted from now on.
    public static func allowLocally(_ p: SealedPin, _ device: String) -> SealedPin {
        guard let t = p.trusted else { return p }
        var q = p
        q.trusted = Set(t + [device]).sorted()
        return q
    }

    /// Whether a request (8562) of a device that is in the head already is answered with the keys
    /// at once: on the anchored end, in the head this client holds, trusted (after a switch), the
    /// client key of a live chat session, and its request newer (strictly) than the roster that
    /// added it and than the last hand-over this client made to it.
    public static func answerWithoutPrompt(chain c: RosterChain?, pin p: SealedPin?, device: String, liveChatDevices: Set<String>, requestAt: Int,
                                           addedAt: Int? = nil, lastHandoverAt: Int?) -> Bool {
        guard let c, let p, c.head.id == p.head, c.root.id == p.root else { return false }
        guard let end = c.rosters.first(where: { $0.id == c.anchored }), end.devices.contains(device), c.devices.contains(device) else { return false }
        if let t = p.trusted, !t.contains(device) { return false }
        guard liveChatDevices.contains(device) else { return false }
        // newer (strictly) than the roster that added it; a device that added ITSELF asks in the
        // same breath: its request counts from its own join's second (5.7)
        let own = AddedConfirm.addedBy(c, device)?.signer == device
        guard let added = addedAt ?? c.joined(device)?.at, own ? requestAt >= added : requestAt > added else { return false }
        return lastHandoverAt.map { requestAt > $0 } ?? true
    }
}

/// A new device of mine is added without a prompt (sealed.md 5.2 step 2, 2026-11-22; Xavier: "If
/// I'm connecting a new device to my account it should automatically consider it as a sealed
/// device"). Pure: what a head device decides from its chain, its pin, the session just read and
/// the request.
public enum AutoAdd {
    public static let window = 86400
    public static let limit = 3
    public static let maxAge = 30 * 86400
    public static let skew = 120

    /// Devices added by rosters dated in the last 24 hours (not the root), whoever added them and
    /// however: counted from the rosters' own times, no local memory.
    public static func addedLately(_ c: RosterChain, now: Int) -> Int {
        var n = 0
        for i in c.rosters.indices.dropFirst() where c.rosters[i].createdAt > now - window {
            n += Set(c.rosters[i].devices).subtracting(c.rosters[i - 1].devices).count
        }
        return n
    }

    /// May THIS device (in the head) add NEWDEVICE at once? All of: this device holds this head
    /// (pinned), the head is the anchored end, this device is trusted (after a switch); the
    /// request is not dated before its session (minus 120 s) and is at most 30 days old; fewer
    /// than 3 devices were added in the last 24 hours; and no roster of the chain ever listed the
    /// new device. The session being live and a chat client
    /// in a list read for this request is the caller's part (SESSIONCREATEDAT nil: not known, ask).
    public static func allowed(chain c: RosterChain?, pin p: SealedPin?, thisDevice: String, newDevice: String,
                               sessionCreatedAt: Int?, requestAt: Int, now: Int) -> Bool {
        guard let c, let p, c.head.id == p.head, c.root.id == p.root else { return false }
        guard c.anchored == c.head.id, c.devices.contains(thisDevice), !c.devices.contains(newDevice) else { return false }
        // the chain never had the asking device before (sealed.md 5.2, belfry-sh e39e2e8): a
        // removed device whose session outlived its removal asks; it is never put back by itself
        guard !c.rosters.contains(where: { $0.devices.contains(newDevice) }) else { return false }
        if let t = p.trusted, !t.contains(thisDevice) { return false }
        guard let s = sessionCreatedAt, requestAt >= s - skew, now - requestAt <= maxAge else { return false }
        return addedLately(c, now: now) < limit
    }
}

/// "It was me", answered once for every device (sealed.md 5.2 step 2b, 2026-11-22; Xavier: "make
/// sure we only need to do that once, in case I have more than 2 devices"): the device that was
/// tapped sends a sealed rumor of kind 8563 to my own head letterbox; every other device of mine
/// clears its notice for that device when the rule holds.
public enum AddedConfirm {
    public static let kind = 8563

    /// The roster of C that added DEVICE: the LAST one that lists it while the one before does
    /// not (a device removed and added again is a new notice that needs its own answer; nil:
    /// the root's own device, or not in the chain).
    public static func addedBy(_ c: RosterChain, _ device: String) -> Roster? {
        var last: Roster?
        for i in c.rosters.indices.dropFirst() where c.rosters[i].devices.contains(device) && !c.rosters[i - 1].devices.contains(device) {
            last = c.rosters[i]
        }
        return last
    }

    public static func tags(account: String, device: String, roster: String) -> [Tag] {
        [["p", account], ["device", device], ["e", roster]]
    }

    public enum Verdict: Equatable, Sendable {
        /// The notice for this device is answered.
        case clears(String)
        /// The roster it names is not in my chain as this device has it (yet): look again later.
        case unknownRoster
        case no
    }

    /// What an opened 8563 means: it clears the notice for its `device` when its seal signer
    /// (a) is in the roster BEFORE the one named by `e` (the added device can never confirm
    /// itself, nor two devices added together each other), (b) is in the head now, and (c) `e`
    /// names the roster that really added that device. Anything else is ignored.
    public static func verdict(_ rumor: NostrEvent, sealPubkey: String, chain c: RosterChain?, account: String) -> Verdict {
        // the shape, read strictly (vectors/sealed.json `confirm`): the rumor's key is the key
        // that signed its seal, content "", p / device / e exactly once
        func once(_ name: String) -> String? {
            let all = rumor.tags.filter { $0.first == name }
            return all.count == 1 && all[0].count >= 2 ? all[0][1] : nil
        }
        guard rumor.kind == kind, rumor.pubkey == sealPubkey, rumor.content.isEmpty, once("p") == account,
              let device = once("device"), isHex64(device), let e = once("e"), isHex64(e) else { return .no }
        guard let c, c.account == account else { return .unknownRoster }
        guard let i = c.rosters.firstIndex(where: { $0.id == e }) else { return .unknownRoster }
        // the roster that LAST added the device, never the root
        guard i > 0, addedBy(c, device)?.id == e else { return .no }
        guard c.rosters[i - 1].devices.contains(sealPubkey), c.devices.contains(sealPubkey) else { return .no }
        return .clears(device)
    }
}
