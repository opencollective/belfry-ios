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
    /// Delete group ID (NIP-29 9008): only on a belfry without `/group-delete`, by someone the
    /// relay lets moderate, and in the demo (SPEC 19.35).
    static func deleteGroup(_ id: String) -> Draft { Draft(.groups, kind: 9008, tags: [["h", id]]) }
}

/// What people post in a group (SPEC 19.35; the belfry's `checkin.CONTENT_KINDS`): a channel
/// with none of these is empty and may be deleted; its own metadata, roles, web settings, labels
/// and reactions don't count.
public enum ChannelContent {
    public static let kinds = [9, 10, 11, 12, 20, 1063, 1068, 1111, 9802, 30023, 31922, 31923]

    /// The question to the groups relay: one content event of ID, plus #general's metadata as the
    /// proof that the relay answered at all (an empty answer proves nothing, as in 19.30).
    public static func filters(_ id: String) -> [[String: Any]] {
        [["kinds": kinds, "#h": [id], "limit": 1], ["kinds": [39000], "#d": [generalId], "limit": 1]]
    }

    /// The relay's ANSWER read: false = it has content, true = empty, nil = no proof of an answer.
    public static func empty(_ id: String, answer: [NostrEvent]) -> Bool? {
        if answer.contains(where: { kinds.contains($0.kind) && $0.tag("h") == id }) { return false }
        return answer.contains(where: { $0.kind == 39000 && $0.tag("d") == generalId }) ? true : nil
    }
}

public extension Derive {
    /// Whether this device holds anything posted in group ID (SPEC 19.35).
    func hasContent(_ id: String) -> Bool {
        events.contains { ChannelContent.kinds.contains($0.kind) && $0.tag("h") == id }
    }

    /// Whether I may end G from Belfry settings → Channels (delete when empty, else archive): a
    /// channel (not #general, events, meetings or proposals) I may archive.
    func mayEndChannel(_ g: Group?) -> Bool {
        guard let g, g.type == .channel else { return false }
        return mayArchive(g)
    }
}
