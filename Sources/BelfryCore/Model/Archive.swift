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

    /// Can a group be deleted by the relay's "nothing" at all (web `archivable`): channels and
    /// groups; never #general, events (ev-, ws-) or proposals (prop-), which have their own cancel /
    /// status and are deleted only by a 9008.
    static func deletableByAbsence(_ id: String) -> Bool {
        let t = Group.typeOf(id)
        return id != generalId && (t == .channel || t == .pod)
    }

    /// This device holds the group's own metadata (9007 / 9002 / 39000, my queued or just-sent
    /// creation events included): it is there, whatever an earlier answer said (web `g.known`).
    func knowsMeta(_ id: String) -> Bool { groupIndex.newestMeta[id] != nil }

    /// The ids to ask the groups relay about (web groupstate.ts): channels and groups this
    /// device has nothing of their own about, named by cards, by messages in them, or marked
    /// absent before (asked again: a relay that lost and found its data). Never #general, an
    /// event, a proposal, nor one this device knows the metadata of (my own creation included).
    func presenceCandidates() -> [String] {
        var out = [String]()
        var seen: Set<String> = [generalId]
        func add(_ id: String) {
            guard !seen.contains(id), Derive.deletableByAbsence(id), !knowsMeta(id) else { return }
            seen.insert(id)
            out.append(id)
        }
        for id in ctx.groupsAbsent.keys.sorted() { add(id) }
        for e in events where e.kind == 9 && !isPending(e.id) {
            if let p = Derive.podOf(e) { add(p) }
        }
        for g in groupIndex.all { add(g.id) }
        return out
    }

    /// What `groupsAbsent` becomes after the relay answered a question about ASKED with ANSWER
    /// (the 39000s by `d`, the 9007 / 9002 / 9008s by `h`, up to EOSE). Nil when it did not answer
    /// to EOSE: still unknown, nothing changes. An id with any event in the answer is there (its
    /// events go into the log); one with none is absent since NOW.
    func presenceAfter(asked: [String], answer: [NostrEvent]?, was: [String: Int]? = nil, now: Int = .now) -> [String: Int]? {
        guard let answer else { return nil }
        var there = Set<String>()
        for e in answer {
            if e.kind == 39000, let d = e.tag("d") { there.insert(d) }
            if [9007, 9002, 9008].contains(e.kind), let h = e.tag("h") { there.insert(h) }
        }
        var out = was ?? ctx.groupsAbsent
        for id in asked where Derive.deletableByAbsence(id) {
            if there.contains(id) { out[id] = nil } else { out[id] = now }
        }
        return out
    }
}

public enum GroupPresence {
    public static let chunk = 100
    /// A group marked absent is asked again after 5 minutes; an unknown one after 10 seconds.
    public static let againAbsent = 300
    public static let againUnknown = 10

    /// The questions: up to 100 ids each.
    public static func questions(_ ids: [String]) -> [[String]] {
        let list = ids.filter { $0 != generalId }
        return stride(from: 0, to: list.count, by: chunk).map { Array(list[$0..<min($0 + chunk, list.count)]) }
    }

    /// One question (web checkGroup): the groups' 39000 and their own 9007 / 9002 / 9008.
    public static func filters(_ ids: [String]) -> [[String: Any]] {
        [["kinds": [39000], "#d": ids], ["kinds": [9007, 9002, 9008], "#h": ids]]
    }

    /// The ids of ASKED to put to the relay now: not while my outbox still holds events for the
    /// group (OUTBOX = their `h`), not asked a moment ago (LAST = when each was asked).
    public static func due(_ asked: [String], outbox: Set<String>, last: [String: Int], absent: [String: Int], now: Int) -> [String] {
        asked.filter { id in
            if outbox.contains(id) { return false }
            guard let at = last[id] else { return true }
            return now - at >= (absent[id] != nil ? againAbsent : againUnknown)
        }
    }
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
