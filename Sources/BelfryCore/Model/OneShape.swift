import Foundation

// Navigation v2 + One shape (canvas sections of 2026-11-22; wire: collective-belfry
// docs/one-shape.md). The rules shared with Android are in vectors/one-shape.json:
// the menu's channel list (pins, then recent), pins, the header row's drop order.

public enum MenuChannels {
    public static let recentWindow = 30 * 86400

    /// The menu's CHANNELS, in order: pinned for everyone (channel-order "pinned"), then mine
    /// (belfry:pins), deduplicated, unknown ids skipped; then the channels where, within the last
    /// 30 days, I posted (9 / 1111), reacted (7) or someone else's 9 / 1111 tags me (p), ordered by
    /// the channel's newest 9 / 1111 / 7 by anyone (all time), newest first, ties by channel id ascending.
    /// Recent leaves out the pinned ones.
    public static func list(events: [NostrEvent], me: String, now: Int, known: [String],
                            pinsAll: [String], pinsMine: [String]) -> (pinned: [String], recent: [String]) {
        let knownSet = Set(known)
        var pinned = [String]()
        var seen = Set<String>()
        // the main channel is always first when known, pinned or not (the lead, 2026-11-22)
        if knownSet.contains(generalId) { pinned.append(generalId); seen.insert(generalId) }
        for id in pinsAll + pinsMine where knownSet.contains(id) && !seen.contains(id) {
            seen.insert(id); pinned.append(id)
        }
        let since = now - recentWindow
        var involved = Set<String>()
        var newest = [String: Int]()
        for e in events where e.kind == 9 || e.kind == 1111 || e.kind == 7 || e.kind == 9007 {
            // creating a channel counts as posting in it (the lead, 2026-11-22): the creator's 9007
            // makes me involved; any 9007 is activity for the order
            guard let h = e.tag("h"), knownSet.contains(h) else { continue }
            newest[h] = max(newest[h] ?? Int.min, e.createdAt)
            guard e.createdAt > since, !me.isEmpty else { continue }
            if e.pubkey == me { involved.insert(h); continue }
            if e.kind == 9 || e.kind == 1111, e.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == me }) { involved.insert(h) }
        }
        let recent = involved.subtracting(seen).sorted { a, b in
            let x = newest[a] ?? 0, y = newest[b] ?? 0
            return x != y ? x > y : a < b
        }
        return (pinned, recent)
    }
}

public enum Pins {
    public static let d = "belfry:pins"

    /// IDS with ID added at the end, or removed when it is there (Pin for me).
    public static func toggle(_ ids: [String], _ id: String) -> [String] {
        ids.contains(id) ? ids.filter { $0 != id } : ids + [id]
    }

    /// {"v":1,"c":[ids]} → the ids (bad JSON → [], non-strings skipped, duplicates keep the first).
    public static func parse(_ content: String?) -> [String] {
        guard let content, let obj = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
              let list = obj["c"] as? [Any] else { return [] }
        var out = [String](), seen = Set<String>()
        for case let s as String in list where !seen.contains(s) { seen.insert(s); out.append(s) }
        return out
    }

    /// Exactly {"v":1,"c":[...]} (v first, as the shared vector writes it).
    public static func serialize(_ ids: [String]) -> String { "{\"v\":1,\"c\":" + JSON.encode(ids) + "}" }

    /// "pinned" in the admins' channel-order content (unknown ids skipped by the reader).
    public static func pinnedForEveryone(_ content: String?) -> [String] {
        guard let content, let obj = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
              let list = obj["pinned"] as? [Any] else { return [] }
        var out = [String](), seen = Set<String>()
        for case let s as String in list where !seen.contains(s) { seen.insert(s); out.append(s) }
        return out
    }
}

/// The one header's second line: items that leave, when the row is too narrow, in this order.
public enum HeaderRow {
    public static let dropOrder = ["owner", "files", "todos", "photos", "comments", "events", "pinned"]

    /// ITEMS (key, width) in display order; the keys kept within BUDGET (items joined by GAP).
    /// The lead item and people never leave; kept items stay in their order.
    public static func fit(_ items: [(key: String, width: Double)], budget: Double, gap: Double) -> [String] {
        var kept = items
        func total() -> Double { kept.reduce(0) { $0 + $1.width } + gap * Double(max(0, kept.count - 1)) }
        for k in dropOrder {
            if total() <= budget { break }
            kept.removeAll { $0.key == k }
        }
        return kept.map(\.key)
    }
}

public extension Derive {
    /// Pinned for everyone: "pinned" in the admins' latest channel-order event.
    func pinnedForEveryone() -> [String] {
        let own = events.filter { $0.kind == 30078 && $0.tag("d") == Derive.orderD && communityAdmins.contains($0.pubkey) }
            .sorted(by: Derive.byTime)
        return Pins.pinnedForEveryone(own.last?.content)
    }

    /// The menu's channels (MenuChannels.list over this snapshot).
    func menuChannels(now: Int, pinsMine: [String]) -> (pinned: [String], recent: [String]) {
        MenuChannels.list(events: events, me: me, now: now, known: townChannels().map(\.id),
                          pinsAll: pinnedForEveryone(), pinsMine: pinsMine)
    }
}

public extension Derive {
    /// My newest kind KIND event with d = D (newest wins, ties by the lower id).
    func myNewest(kind: Int, d: String) -> NostrEvent? {
        ofKind(kind).filter { $0.pubkey == me && $0.tag("d") == d }
            .max { ($0.createdAt, $1.id) < ($1.createdAt, $0.id) }
    }

    /// The admins' latest channel-order content as an object (empty when none), so a writer can
    /// keep every key it doesn't change.
    func channelOrderObject() -> [String: Any] {
        let own = events.filter { $0.kind == 30078 && $0.tag("d") == Derive.orderD && communityAdmins.contains($0.pubkey) }
            .sorted(by: Derive.byTime)
        guard let c = own.last?.content, let obj = (try? JSONSerialization.jsonObject(with: Data(c.utf8))) as? [String: Any] else { return [:] }
        return obj
    }
}

public extension Actions {
    /// Pin for everyone (admins): "pinned" in channel-order with ID added at the end or removed;
    /// every other key of PREVIOUS stays.
    static func pinForEveryone(_ id: String, previous: [String: Any]) -> Draft {
        var obj = previous
        let now = Pins.pinnedForEveryone(JSON.encode(previous))
        obj["pinned"] = Pins.toggle(now, id)
        return Draft(.main, kind: 30078, content: JSON.encode(obj), tags: [["d", Derive.orderD]])
    }

    /// My pins (content already NIP-44 encrypted to myself).
    static func myPins(encrypted: String) -> Draft {
        Draft(.main, kind: 30078, content: encrypted, tags: [["d", Pins.d]])
    }
}

public extension Actions {
    /// A channel-order DRAFT that keeps the keys of PREVIOUS it doesn't set ("pinned" and any
    /// other: a writer keeps every other key).
    static func keepingOtherKeys(_ draft: Draft, previous: [String: Any]) -> Draft {
        guard let new = (try? JSONSerialization.jsonObject(with: Data(draft.content.utf8))) as? [String: Any] else { return draft }
        var d = draft
        d.content = JSON.encode(previous.merging(new) { _, n in n })
        return d
    }
}
