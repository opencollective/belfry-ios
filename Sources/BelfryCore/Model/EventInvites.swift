import Foundation

/// Inviting members to an event (Android SPEC 19.65; the lead's ruling 2026-11-22; Xavier: "just
/// the ability to select members and search for them. That should add in the chat an event like
/// 'Xavier invited @user1 @user2 ...'"). Not for a meeting (its own people list invites).
/// Nobody is put in the chat and nobody gets a role; telling the invitee is the server's.
public enum EventInvites {
    /// The mark of the chat line.
    public static let mark: Tag = ["invited", "event"]

    /// The line's readable fallback for a client that does not know the mark.
    public static func content(_ keys: [String]) -> String {
        "invited " + keys.compactMap { Bech32.npub($0).map { "nostr:" + $0 } }.joined(separator: " ")
    }

    /// (a) a new version of the event with one ["p", <pubkey>, "", "invited"] per person, and
    /// (b) one marked line in its chat: kind 9 by the host, ["h", chat], one ["p"] each, the mark.
    public static func invite(_ e: CalEvent, _ keys: [String]) -> [Draft] {
        let fresh = keys.reduce(into: [String]()) { out, k in if isHex64(k) && !e.invited.contains(k) && !out.contains(k) { out.append(k) } }
        guard !fresh.isEmpty, !e.meeting else { return [] }
        return [
            Meetings.newVersion(e, more: fresh.map { ["p", $0, "", "invited"] }),
            Draft(kind: 9, content: content(fresh), tags: [["h", e.groupId]] + fresh.map { ["p", $0] } + [mark]),
        ]
    }
}

public extension Derive {
    /// The event whose chat GROUP is.
    func eventOfChat(_ group: String) -> CalEvent? {
        guard group.hasPrefix("ev-") else { return nil }
        return calendar.first { $0.groupId == group }
    }

    /// The people a marked line names: only when its author is the event's maker, a co-host by
    /// role or a belfry admin; anyone else's is an ordinary message (nil).
    func invitedLine(_ ev: NostrEvent, in group: String) -> [String]? {
        guard ev.kind == 9, ev.tags.contains(EventInvites.mark), let e = eventOfChat(group) else { return nil }
        let role = eventRole(e, ev.pubkey)
        guard role == .host || role == .cohost || communityAdmins.contains(ev.pubkey) else { return nil }
        var keys = [String]()
        for k in ev.tagValues("p") where isHex64(k) && !keys.contains(k) { keys.append(k) }
        return keys.isEmpty ? nil : keys
    }

    /// The members a host can invite to E, by name: members only (no guests, no agents), not me,
    /// not already invited or going.
    func invitable(_ e: CalEvent, _ q: String) -> [String] {
        let s = q.jsTrim().lowercased()
        let out = Set(e.invited).union(e.goingKeys).union([me])
        return profiles().keys
            .filter { !out.contains($0) && !isGuest($0) && !isAgent($0) }
            .filter { s.isEmpty || displayName($0).lowercased().contains(s) }
            .sorted { displayName($0).lowercased() < displayName($1).lowercased() }
    }
}
