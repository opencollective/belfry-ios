import Foundation

// Deleted and archived groups (SPEC 19.30; the belfry's contract of 2026-11-16). "Group" here is
// anything with a NIP-29 group id that people open from the channel list or a card: channels and
// groups (ids `pod-…`). Events and proposals keep their own cancel / status mechanisms.
//
// Deleted: a kind 9008 for it is known, or the groups relay was asked for its metadata and
// answered that it has none (`WorldContext.groupsAbsent`), and nothing newer about it arrived
// since. Until the relay answered, a group nothing is known about is "unknown": never "deleted"
// on a guess.
//
// Archived: `["archived", "1"]` on the group's latest 9002 that says anything about it;
// `["archived", "0"]` unarchives. In no list, readable, nobody writes in it.

public enum GroupState: String, Sendable {
    /// Nothing is known about it and the relay has not answered yet.
    case unknown
    case open
    case archived
    case deleted
}

public extension Derive {
    func groupState(_ id: String) -> GroupState {
        if groupIndex.deleted.contains(id) { return .deleted }
        guard let g = group(id) else { return .unknown }
        return g.archived ? .archived : .open
    }

    func isDeleted(_ id: String) -> Bool { groupIndex.deleted.contains(id) }
    func isArchived(_ id: String) -> Bool { group(id)?.archived == true }
    /// Nothing is written in it: archived or deleted.
    func isLocked(_ id: String) -> Bool { isDeleted(id) || isArchived(id) }

    /// The ids nothing is written in (for `SyncEngine.setLocked`).
    var lockedGroups: Set<String> { groupIndex.deleted.union(groupIndex.all.filter(\.archived).map(\.id)) }

    /// Every archived group, by name.
    func archivedGroups() -> [Group] {
        groupIndex.all.filter(\.archived).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The archived groups I can open (the "Archived" row at the bottom of the channel list): the
    /// ones I am in or run, and for a member every archived channel.
    func myArchived() -> [Group] {
        let guest = isGuest(me)
        return archivedGroups().filter { g in
            g.members.contains(me) || canAdmin(g) || (g.type == .channel && !guest)
        }
    }

    /// May I archive / unarchive G: whoever may edit it (its admins, admins by role, the belfry's
    /// admins); only channels and groups, never #general.
    func mayArchive(_ g: Group?) -> Bool {
        guard let g, g.id != generalId, g.type == .channel || g.type == .pod, !g.pending else { return false }
        return canAdmin(g)
    }

    /// The name on a group's card when the group itself is gone: taken from the card's own text
    /// ("⬡ New pod: Canal · about"), else nil ("A group").
    static func cardName(_ text: String) -> String? {
        guard let r = text.range(of: #"^⬡ New (pod|group): "#, options: .regularExpression) else { return nil }
        var rest = String(text[r.upperBound...])
        if let nl = rest.firstIndex(where: \.isNewline) { rest = String(rest[..<nl]) }
        if let dot = rest.range(of: " · ") { rest = String(rest[..<dot.lowerBound]) }
        let name = rest.jsTrim().sliceUnits(80)
        return name.isEmpty ? nil : name
    }

    /// The ids to ask the groups relay about (does it still have them?): the channels and groups
    /// this device knows, and the groups named by cards it knows nothing about. Never one I am
    /// still creating.
    func presenceCandidates() -> [String] {
        var out = [String]()
        var seen: Set<String> = [generalId]
        for g in groupIndex.all where (g.type == .channel || g.type == .pod) && !g.pending && !seen.contains(g.id) {
            seen.insert(g.id)
            out.append(g.id)
        }
        // ones already said absent are asked again (a relay that lost and found its data)
        let creating = Set(groupIndex.all.filter(\.pending).map(\.id))
        for id in ctx.groupsAbsent.keys.sorted() where !seen.contains(id) && !creating.contains(id) {
            let t = Group.typeOf(id)
            guard t == .channel || t == .pod else { continue }
            seen.insert(id)
            out.append(id)
        }
        for e in events where e.kind == 9 {
            guard let p = Derive.podOf(e), !seen.contains(p), !isPending(e.id) else { continue }
            seen.insert(p)
            out.append(p)
        }
        return out
    }

    /// What `groupsAbsent` becomes after the relay answered a question about ASKED with ANSWER
    /// (its kind 39000 events). Nil when the answer can't be trusted: it must name #general,
    /// which is always asked along and always there.
    func presenceAfter(asked: [String], answer: [NostrEvent], was: [String: Int]? = nil) -> [String: Int]? {
        let there = Set(answer.filter { $0.kind == 39000 }.compactMap { $0.tag("d") })
        guard there.contains(generalId) else { return nil }
        var out = was ?? ctx.groupsAbsent
        for id in asked where id != generalId {
            if there.contains(id) { out[id] = nil } else { out[id] = groupIndex.newestMeta[id] ?? 0 }
        }
        return out
    }
}

public enum GroupPresence {
    public static let chunk = 100

    /// One filter per question: #general (the proof the relay answered) and up to 100 ids.
    public static func questions(_ ids: [String]) -> [[String]] {
        let list = ids.filter { $0 != generalId }
        return stride(from: 0, to: list.count, by: chunk).map { [generalId] + Array(list[$0..<min($0 + chunk, list.count)]) }
    }

    public static func filter(_ ids: [String]) -> [String: Any] { ["kinds": [39000], "#d": ids] }
}

/// The last check before anything is queued for a group nothing is written in.
public enum GroupLock {
    public static func refuses(_ d: Draft, locked: Set<String>) -> Bool {
        guard !locked.isEmpty, let h = d.tags.first(where: { $0.count > 1 && $0[0] == "h" })?[1], locked.contains(h) else { return false }
        // unarchiving is the one thing an archived group takes
        if d.kind == 9002 && d.tags.contains(["archived", "0"]) { return false }
        return true
    }
}

public extension Actions {
    /// Archive / unarchive G: a 9002 keeping every other setting.
    static func archive(_ g: Group, _ on: Bool) -> Draft { groupMeta(g, archived: on) }
}
