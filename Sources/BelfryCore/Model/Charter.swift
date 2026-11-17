import Foundation

// The town's places (SPEC 19.31) and the charter (SPEC 19.32), iOS 2026-11-16.
//
// Names: the default channels read on brand (display only, ids unchanged) while their own name is
// still the default. Charter: a short list of agreements every person ticks for themselves. It is
// the NIP-29 group `charter` on the groups relay; each agreement is a to-do (kind 2100) of that
// group's task list carrying ["each", "1"]; a person's agreement is their own 2101 `done` (counted
// per author, not done once for everyone); a steward's 2101 `edit` changes the text, explanation
// or order (latest wins) and, when the text changes, asks everyone to agree to that rule again.
// Only the belfry's admins' agreements, edits and removals count.

public enum PlaceNames {
    /// The on-brand name of a default place, by group id. Since 2026-11-17 only #general
    /// ("Townsquare"; the owner: "Just Townsquare (instead of Square)"): events, proposals and
    /// website show their own names (they were Fairground, Assembly, Scriptorium, and a new belfry
    /// no longer has them).
    public static let defaults: [String: String] = [generalId: "Townsquare"]

    /// The name to show instead of NAME, or nil to keep it: only while the group's own name is
    /// still its default (empty, its id, or "#" + id, any case).
    public static func display(id: String, name: String) -> String? {
        guard let n = defaults[id] else { return nil }
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw.isEmpty || raw == id || raw == "#" + id ? n : nil
    }

    /// What to write for a name shown on brand: the id itself (never "Townsquare" on the wire).
    public static func wire(id: String, name: String) -> String { defaults[id] == name ? id : name }

    /// Members and requests (the drawer row and its screen). Called "Gates" until 2026-11-17
    /// (the owner: "just rename Gates to Members").
    public static let members = "Members"

    /// The drawer's sections: The town (the Townsquare, Members, the Charter), Community life,
    /// Building together (proposals, the website). Since SPEC 19.34 the last two are the built-in
    /// categories `life` and `building` (Model/Categories.swift).
    public enum Section: String, Sendable, CaseIterable {
        case town, life, building
        public var title: String {
            switch self {
            case .town: return "The town"
            case .life: return "Community life"
            case .building: return "Building together"
            }
        }
    }

    public static func section(_ id: String) -> Section {
        if id == generalId { return .town }
        if id == "proposals" || id == "website" { return .building }
        return .life
    }

    /// The belfry roles as people read them: Steward (the built-in admin), Member, Guest.
    public static let steward = "Steward"
    public static let member = "Member"
    public static let guest = "Guest"
    /// The per-event / per-group check-in role (wire value `steward`, SPEC 19.29) is shown as Door.
    public static let door = "Door"
}

public struct Agreement: Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var about: String
    public var order: Int
    public let author: String
    public let addedAt: Int
    /// When its text (title or explanation) last changed: its 2100, or a steward's edit.
    public var textAt: Int
    /// People whose latest tick is `done` and not older than `textAt` → when.
    public var agreed: [String: Int] = [:]
    /// People who had agreed before the text changed (they are asked again).
    public var stale: Set<String> = []
    public var pending = false

    public func hasAgreed(_ pubkey: String) -> Bool { agreed[pubkey] != nil }
}

public extension Derive {
    static let charterId = "charter"
    static let eachTag = "each"

    /// The charter's group, when a steward made it.
    var charterGroup: Group? { group(Derive.charterId) }

    /// The agreements, in the stewards' order (then oldest first).
    func charter() -> [Agreement] {
        if let c = charterCache { return c }
        let out = Derive.parseCharter(events.filter { $0.kind == 2100 || $0.kind == 2101 }, admins: communityAdmins, pending: ctx.pending)
        charterCache = out
        return out
    }

    /// The rules I haven't agreed to (or agreed to before their text changed).
    func charterToAgree() -> [Agreement] { charter().filter { $0.agreed[me] == nil } }

    /// When I agreed to the last rule I ticked, while I have agreed to all of them; nil otherwise.
    func charterAgreedAt() -> Int? {
        let list = charter()
        guard !list.isEmpty, list.allSatisfy({ $0.agreed[me] != nil }) else { return nil }
        return list.compactMap { $0.agreed[me] }.max()
    }

    /// The charter's agreements from EVENTS (2100 / 2101 of the `charter` task list).
    static func parseCharter(_ events: [NostrEvent], admins: Set<String>, pending: Set<String> = []) -> [Agreement] {
        let listId = Derive.listIdFor(Derive.charterId)
        let evs = events.filter { ($0.kind == 2100 || $0.kind == 2101) && $0.tag("t") == listId && $0.tag("h") == Derive.charterId }
            .sorted(by: Derive.byTime)
        var rules = [String: Agreement]()
        var ticks = [String: [String: (on: Bool, at: Int)]]() // rule → person → latest tick
        for e in evs {
            if e.kind == 2100 {
                guard e.tag(Derive.eachTag) == "1", admins.contains(e.pubkey), rules[e.id] == nil else { continue }
                let title = e.content.jsTrim().sliceUnits(300)
                guard !title.isEmpty else { continue }
                rules[e.id] = Agreement(id: e.id, title: title, about: (e.tag("about") ?? "").jsTrim().sliceUnits(200),
                                        order: Int(e.tag("order") ?? "") ?? Int.max, author: e.pubkey, addedAt: e.createdAt,
                                        textAt: e.createdAt, pending: pending.contains(e.id))
                continue
            }
            guard let rid = e.tag("e"), var r = rules[rid] else { continue }
            switch e.tag("action") ?? "" {
            case "edit":
                guard admins.contains(e.pubkey) else { continue }
                let title = e.content.jsTrim().sliceUnits(300)
                let about = (e.tag("about") ?? "").jsTrim().sliceUnits(200)
                if !title.isEmpty, title != r.title || about != r.about {
                    r.title = title
                    r.about = about
                    r.textAt = e.createdAt
                }
                if let o = e.tag("order").flatMap({ Int($0) }) { r.order = o }
                rules[rid] = r
            case "delete":
                if admins.contains(e.pubkey) { rules[rid] = nil; ticks[rid] = nil }
            case "done": ticks[rid, default: [:]][e.pubkey] = (true, e.createdAt)
            case "undone": ticks[rid, default: [:]][e.pubkey] = (false, e.createdAt)
            default: break
            }
        }
        var out = [Agreement]()
        for var r in rules.values {
            for (pk, t) in ticks[r.id] ?? [:] where t.on {
                if t.at >= r.textAt { r.agreed[pk] = t.at } else { r.stale.insert(pk) }
            }
            out.append(r)
        }
        return out.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            if a.addedAt != b.addedAt { return a.addedAt < b.addedAt }
            return a.id < b.id
        }
    }
}

public extension Actions {
    static func charterTags() -> [Tag] { taskTags(Derive.charterId) + [[Derive.eachTag, "1"]] }

    /// The charter's group, made by the steward who writes the first agreement.
    static func createCharter() -> [Draft] {
        [Draft(kind: 9007, tags: [["h", Derive.charterId]]),
         Draft(kind: 9002, tags: [["h", Derive.charterId], ["name", "Charter"], ["about", "The agreements everyone here ticks."], ["open"]])]
    }

    static func addAgreement(title: String, about: String, order: Int) -> Draft {
        Draft(kind: 2100, content: title.jsTrim().sliceUnits(300), tags: charterTags() + aboutTag(about) + [["order", String(order)]])
    }

    /// A steward's change: the full text, explanation and place (latest wins).
    static func editAgreement(_ id: String, title: String, about: String, order: Int) -> Draft {
        Draft(kind: 2101, content: title.jsTrim().sliceUnits(300),
              tags: [["e", id], ["action", "edit"]] + charterTags() + aboutTag(about) + [["order", String(order)]])
    }

    static func removeAgreement(_ id: String) -> Draft {
        Draft(kind: 2101, tags: [["e", id], ["action", "delete"]] + charterTags())
    }

    /// My own tick (or taking it back).
    static func agree(_ id: String, _ on: Bool) -> Draft {
        Draft(kind: 2101, tags: [["e", id], ["action", on ? "done" : "undone"]] + charterTags())
    }

    private static func aboutTag(_ about: String) -> [Tag] {
        let a = about.jsTrim().sliceUnits(200)
        return a.isEmpty ? [] : [["about", a]]
    }
}
