import Foundation

// Channel categories (SPEC 19.34, iOS 2026-11-17; vectors/categories.json, reference
// tools/vectors/categories.py). The same event as the channel order: kind 30078,
// d = belfry:channel-order on the community relay, by a belfry admin (the latest by an admin wins).
// Its content gains `categories`:
//   {"order": [channel ids, flattened], "categories": [{"id": "life", "name": "Community life", "channels": [ids]}, …]}
// Built-in ids: `life` (the default: any channel no category names lands here) and `building`
// (default members `proposals`, `website`). The town (general, Members, the Charter) is not a
// category. Without `categories` the list is exactly as before (19.31: life, then building).

/// One category of the channel list: its id, its title and its channels' ids in order.
public struct ChannelCategory: Hashable, Sendable, Identifiable {
    public static let life = "life"
    public static let building = "building"
    public static let defaultNames = [life: "Community life", building: "Building together"]
    /// The channels `building` holds while no category names them.
    public static let buildingDefault = ["proposals", "website"]

    public var id: String
    public var name: String
    public var channels: [String]

    public init(id: String, name: String, channels: [String]) {
        self.id = id
        self.name = name
        self.channels = channels
    }

    public var isBuiltIn: Bool { ChannelCategory.defaultNames[id] != nil }
    public static func defaultName(_ id: String) -> String? { defaultNames[id] }
}

/// The admins' event as read: the flattened order and the categories (nil = the event has none).
public struct ChannelLayout: Hashable, Sendable {
    public var order: [String]
    public var categories: [ChannelCategory]?

    public init(order: [String] = [], categories: [ChannelCategory]? = nil) {
        self.order = order
        self.categories = categories
    }

    /// Reads the event's content; anything malformed is left out (never an error).
    public static func parse(_ content: String?) -> ChannelLayout {
        guard let content, !content.isEmpty, let obj = JSON.parse(content) as? [String: Any] else { return ChannelLayout() }
        let order = Array(((obj["order"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(1000))
        guard let list = obj["categories"] as? [Any] else { return ChannelLayout(order: order, categories: nil) }
        var cats = [ChannelCategory]()
        var ids = Set<String>()
        for item in list.prefix(100) {
            guard let c = item as? [String: Any], let rawId = c["id"] as? String else { continue }
            let id = String(rawId.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            if id.isEmpty || id == "town" || ids.contains(id) { continue }
            ids.insert(id)
            let name = String(((c["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            let chans = Array(((c["channels"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(1000))
            cats.append(ChannelCategory(id: id, name: name, channels: chans))
        }
        return ChannelLayout(order: order, categories: cats)
    }
}

/// A row of the flat list a drag works on: a category's header or a channel.
public enum CategoryRow: Hashable, Sendable {
    case header(String)
    case channel(String)

    /// "h:<id>" / "c:<id>" (the vectors' notation).
    public init?(code: String) {
        if code.hasPrefix("h:") { self = .header(String(code.dropFirst(2))) } else if code.hasPrefix("c:") { self = .channel(String(code.dropFirst(2))) } else { return nil }
    }
}

public enum Categories {
    /// The categories with their visible channels. CHANNELS = the town's listed channels in their
    /// natural order (general may be in it: it is never in a category).
    public static func arrange(_ layout: ChannelLayout, channels: [String]) -> [ChannelCategory] {
        let visible = channels.filter { $0 != generalId }
        let vis = Set(visible)
        let ordered = inOrder(visible, layout.order)
        let life = ChannelCategory.life, building = ChannelCategory.building
        guard let cats = layout.categories else {
            return [
                ChannelCategory(id: life, name: ChannelCategory.defaultNames[life]!, channels: ordered.filter { !ChannelCategory.buildingDefault.contains($0) }),
                ChannelCategory(id: building, name: ChannelCategory.defaultNames[building]!, channels: ordered.filter { ChannelCategory.buildingDefault.contains($0) }),
            ]
        }
        var seen = Set<String>()
        var out = [ChannelCategory]()
        for c in cats {
            var chans = [String]()
            for x in c.channels where vis.contains(x) && !seen.contains(x) {
                seen.insert(x)
                chans.append(x)
            }
            let name = c.name.isEmpty ? (ChannelCategory.defaultName(c.id) ?? c.id) : c.name
            out.append(ChannelCategory(id: c.id, name: name, channels: chans))
        }
        if !out.contains(where: { $0.id == building }) {
            let chans = ordered.filter { ChannelCategory.buildingDefault.contains($0) && !seen.contains($0) }
            seen.formUnion(chans)
            out.append(ChannelCategory(id: building, name: ChannelCategory.defaultNames[building]!, channels: chans))
        }
        if !out.contains(where: { $0.id == life }) {
            out.insert(ChannelCategory(id: life, name: ChannelCategory.defaultNames[life]!, channels: []), at: 0)
        }
        if let i = out.firstIndex(where: { $0.id == life }) {
            out[i].channels += ordered.filter { !seen.contains($0) }
        }
        return out
    }

    /// The categories a list shows: `building` only with channels; others always for the
    /// belfry's admins (empty, with their ＋), with channels for everyone else, except Community
    /// life, which any MEMBER (not a guest) sees even empty: its ＋ is how a member starts the first
    /// channel of a belfry that has only #general (web order.ts `shownCategories`, 2026-11-17).
    /// MEMBER defaults to ADMIN.
    public static func shown(_ cats: [ChannelCategory], admin: Bool, member: Bool? = nil) -> [ChannelCategory] {
        let member = member ?? admin
        return cats.filter { !$0.channels.isEmpty || (admin && $0.id != ChannelCategory.building) || ($0.id == ChannelCategory.life && (admin || member)) }
    }

    /// The content of the admins' event for CATS (the whole arrangement as edited). The flattened
    /// `order` (general first) keeps older clients working; built-in names equal to their default
    /// are left out; an empty `building` is left out; ids from PREVIOUS that the writer doesn't
    /// see (KNOWN = the channels it sees) stay at the end of their category.
    public static func encode(_ cats: [ChannelCategory], previous: ChannelLayout?, known: Set<String>) -> [String: Any] {
        var prev = [String: [String]]()
        for c in previous?.categories ?? [] where prev[c.id] == nil { prev[c.id] = c.channels }
        var written = Set<String>()
        var lists = [[String]]()
        for c in cats {
            var chans = [String]()
            for x in c.channels where !written.contains(x) {
                written.insert(x)
                chans.append(x)
            }
            lists.append(chans)
        }
        var order = [generalId]
        var res = [[String: Any]]()
        for (c, base) in zip(cats, lists) {
            var chans = base
            for x in prev[c.id] ?? [] where !known.contains(x) && !written.contains(x) && x != generalId {
                written.insert(x)
                chans.append(x)
            }
            if c.id == ChannelCategory.building && chans.isEmpty { continue }
            var item: [String: Any] = ["id": c.id]
            let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !(c.isBuiltIn && name == ChannelCategory.defaultName(c.id)) { item["name"] = name }
            item["channels"] = chans
            res.append(item)
            order += chans
        }
        return ["order": order, "categories": res]
    }

    /// CATS after a drag in the flat list FLAT (headers and channels): a channel belongs to the
    /// header above it (above the first header: the first one); categories not in FLAT keep theirs.
    public static func rebuild(_ cats: [ChannelCategory], flat: [CategoryRow]) -> [ChannelCategory] {
        var heads = [String]()
        for r in flat { if case .header(let h) = r { heads.append(h) } }
        var lists = [String: [String]]()
        for h in heads { lists[h] = [] }
        var cur = heads.first ?? ChannelCategory.life
        for r in flat {
            switch r {
            case .header(let h): cur = h
            case .channel(let c): lists[cur, default: []].append(c)
            }
        }
        return cats.map { c in
            var c = c
            if let l = lists[c.id] { c.channels = l }
            return c
        }
    }

    /// The flat list of CATS: each header, then its channels.
    public static func flat(_ cats: [ChannelCategory]) -> [CategoryRow] {
        cats.flatMap { [CategoryRow.header($0.id)] + $0.channels.map { CategoryRow.channel($0) } }
    }

    /// CHANNEL moved to the end of category TO (out of wherever it was).
    public static func put(_ channel: String, in to: String, _ cats: [ChannelCategory]) -> [ChannelCategory] {
        var out = cats.map { c -> ChannelCategory in
            var c = c
            c.channels.removeAll { $0 == channel }
            return c
        }
        if let i = out.firstIndex(where: { $0.id == to }) { out[i].channels.append(channel) } else if let i = out.firstIndex(where: { $0.id == ChannelCategory.life }) { out[i].channels.append(channel) }
        return out
    }

    /// Category ID removed: its channels go to the end of Community life (built-ins stay).
    public static func remove(_ id: String, _ cats: [ChannelCategory]) -> [ChannelCategory] {
        guard let i = cats.firstIndex(where: { $0.id == id }), !cats[i].isBuiltIn else { return cats }
        var out = cats
        let moved = out.remove(at: i).channels
        if let l = out.firstIndex(where: { $0.id == ChannelCategory.life }) { out[l].channels += moved } else { out.insert(ChannelCategory(id: ChannelCategory.life, name: ChannelCategory.defaultNames[ChannelCategory.life]!, channels: moved), at: 0) }
        return out
    }

    /// A new category's id: a short slug of its name and 4 random characters.
    public static func newId(_ name: String) -> String {
        var s = String(Actions.slug(name, random: { "" }).prefix(24))
        while s.hasSuffix("-") { s.removeLast() }
        if s.isEmpty || s == "channel" { s = "category" }
        return s + "-" + Crypto.random(2).hex
    }

    static func inOrder(_ ids: [String], _ order: [String]) -> [String] {
        var at = [String: Int]()
        for (i, id) in order.enumerated() where at[id] == nil { at[id] = i }
        return ids.enumerated().sorted { a, b in
            (at[a.element] ?? 1_000_000 + a.offset) < (at[b.element] ?? 1_000_000 + b.offset)
        }.map(\.element)
    }
}

public extension Derive {
    /// The admins' latest d=belfry:channel-order event, read (order and categories).
    func channelLayout() -> ChannelLayout {
        let own = events.filter { $0.kind == 30078 && $0.tag("d") == Derive.orderD && communityAdmins.contains($0.pubkey) }
            .sorted(by: Derive.byTime)
        return ChannelLayout.parse(own.last?.content)
    }

    /// The town's channels (listed, not groups, not the charter) in their natural order.
    func townChannels() -> [Group] {
        groups().filter { $0.type == .channel && $0.id != Derive.charterId }
    }

    /// The drawer's categories with their channels (general is never in one).
    func channelCategories() -> [ChannelCategory] {
        Categories.arrange(channelLayout(), channels: townChannels().map(\.id))
    }
}

public extension Actions {
    /// The admins' order with categories (SPEC 19.34); `order` stays the flattened list.
    static func channelLayout(_ cats: [ChannelCategory], previous: ChannelLayout?, known: Set<String>) -> Draft {
        Draft(.main, kind: 30078, content: JSON.encode(Categories.encode(cats, previous: previous, known: known)), tags: [["d", Derive.orderD]])
    }
}
