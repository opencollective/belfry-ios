import Foundation

// Roles in a group and check-ins (SPEC 19.29; the belfry's contract of 2026-11-15):
// - admin: NIP-29 admin of the group (39001). In an event the creator is the "Host", other
//   admins "Co-host".
// - steward: events only; may check people in. Kind 1985 `L belfry/group-role`,
//   `l steward|none`, `p`, `h`, signed by the groups key; the latest per `p` wins; an admin is
//   never a steward.
// - member: everyone else ("Attendee" in an event).
// Check-ins: kind 1985 `L belfry/ticket`, `l checked-in|not-checked-in`, `p`, `h ev-<d>`, signed
// by the groups key; the latest per `p` wins.
// Only the groups key's labels count (anyone could publish a label).

public enum GroupRole: String, Sendable, CaseIterable, Codable {
    case admin, steward, member
}

/// A person's place in an event, as the UI names it.
public enum EventRole: String, Sendable, CaseIterable {
    case host, cohost, steward, attendee

    public var label: String {
        switch self {
        case .host: return "Host"
        case .cohost: return "Co-host"
        case .steward: return "Steward"
        case .attendee: return "Attendee"
        }
    }

    /// What `POST /group-roles` takes for this choice (the host is never picked).
    public var groupRole: GroupRole {
        switch self {
        case .host, .cohost: return .admin
        case .steward: return .steward
        case .attendee: return .member
        }
    }

    public var maysCheckIn: Bool { self != .attendee }
}

public extension Derive {
    static let groupRoleNS = "belfry/group-role"
    static let ticketNS = "belfry/ticket"

    /// The value of the label in NS on E (`["l", value, ns]`), else nil.
    internal static func labelValue(_ e: NostrEvent, _ ns: String) -> String? {
        e.tags.first { $0.count >= 2 && $0[0] == "l" && ($0.count < 3 || $0[2] == ns) }?[1]
    }

    /// The groups key's latest label in NS per person in GROUP: pubkey → (value, time).
    internal func latestGroupsKeyLabels(_ groupId: String, _ ns: String) -> [String: (String, Int)] {
        guard let key = ctx.groupsKey, !key.isEmpty else { return [:] }
        var out = [String: (String, Int)]()
        for e in inGroupSorted(groupId) where e.kind == 1985 && e.pubkey == key && e.tag("L") == ns {
            guard let p = e.tag("p"), isHex64(p), let v = Derive.labelValue(e, ns) else { continue }
            if let prev = out[p], prev.1 > e.createdAt { continue }
            out[p] = (v, e.createdAt)
        }
        return out
    }

    /// Stewards of GROUP (an event's): the groups key's latest label for them says "steward".
    func stewards(_ groupId: String) -> Set<String> {
        guard Group.typeOf(groupId) == .event else { return [] }
        return Set(latestGroupsKeyLabels(groupId, Derive.groupRoleNS).filter { $0.value.0 == "steward" }.keys)
    }

    /// Keys that administer every group: the belfry's admins, the relay's key (the author of the
    /// group's 39000), the groups key. Never shown as a group's "Admin" or an event's "Co-host".
    func everywhere(_ groupId: String) -> Set<String> {
        var out = communityAdmins
        if let r = ofKind(39000).first(where: { $0.tag("d") == groupId })?.pubkey { out.insert(r) }
        if let k = ctx.groupsKey, !k.isEmpty { out.insert(k) }
        return out
    }

    /// "Admin" for a channel's or group's own admin ('' for everyone else and for the keys that
    /// administer every group), as its people lists show it.
    func adminWord(_ groupId: String, _ pubkey: String) -> String? {
        guard group(groupId)?.admins.contains(pubkey) == true, !everywhere(groupId).contains(pubkey) else { return nil }
        return "Admin"
    }

    /// PUBKEY's role in GROUP.
    func groupRole(_ groupId: String, _ pubkey: String) -> GroupRole {
        if group(groupId)?.admins.contains(pubkey) == true { return .admin }
        if Group.typeOf(groupId) == .event, stewards(groupId).contains(pubkey) { return .steward }
        return .member
    }

    /// Who is checked in at GROUP (an event's group): pubkey → when.
    func checkIns(_ groupId: String) -> [String: Int] {
        var out = [String: Int]()
        for (p, v) in latestGroupsKeyLabels(groupId, Derive.ticketNS) where v.0 == "checked-in" { out[p] = v.1 }
        return out
    }

    /// The latest check-in label per person (true: checked in) and its time, to lay over an older answer.
    func ticketLabels(_ groupId: String) -> [String: (on: Bool, at: Int)] {
        latestGroupsKeyLabels(groupId, Derive.ticketNS).mapValues { (on: $0.0 == "checked-in", at: $0.1) }
    }

    /// PUBKEY's role in event E: its creator hosts, other admins co-host, then stewards.
    func eventRole(_ e: CalEvent, _ pubkey: String) -> EventRole {
        if pubkey == e.creator { return .host }
        if group(e.groupId)?.admins.contains(pubkey) == true && !everywhere(e.groupId).contains(pubkey) { return .cohost }
        if stewards(e.groupId).contains(pubkey) { return .steward }
        return .attendee
    }

    /// May I check people in at E, as the relay tells it (the API's `may_check_in` wins when
    /// known): host, co-host, steward, any admin of its group, a belfry admin.
    func mayCheckIn(_ e: CalEvent) -> Bool {
        guard !e.remote else { return false }
        return eventRole(e, me).maysCheckIn || group(e.groupId)?.admins.contains(me) == true || isCommunityAdmin
    }

    /// From 00:00 of the event's first day to the end of its last day, in the context's zone.
    func onEventDays(_ e: CalEvent, now: Int) -> Bool {
        let c = calendarForDays
        let first = c.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(e.start)))
        var lastAt = endOf(e)
        // an all-day event's end date is the day after its last day
        if e.allDay, let end = e.end, end > e.start { lastAt = end - 1 }
        let lastDay = c.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(lastAt)))
        guard let after = c.date(byAdding: .day, value: 1, to: lastDay) else { return false }
        let t = Date(timeIntervalSince1970: TimeInterval(now))
        return t >= first && t < after
    }

    /// The people of event E for its People tab: hosts (creator first), stewards, then going,
    /// then maybe, each by name. Ticket holders who said nothing count as going.
    func eventPeopleList(_ e: CalEvent) -> (hosts: [String], going: [String], maybe: [String]) {
        let st = stewards(e.groupId)
        let byName: (String, String) -> Bool = { a, b in self.displayName(a).lowercased() < self.displayName(b).lowercased() }
        let co = (group(e.groupId)?.admins ?? []).filter { $0 != e.creator && eventRole(e, $0) == .cohost }
        let hosts = [e.creator] + co.sorted(by: byName) + st.filter { $0 != e.creator && !co.contains($0) }.sorted(by: byName)
        let taken = Set(hosts)
        let going = e.goingKeys.filter { !taken.contains($0) }.sorted(by: byName)
        let maybe = e.rsvps.filter { $0.value == .tentative && !taken.contains($0.key) && !e.goingKeys.contains($0.key) }.map(\.key).sorted(by: byName)
        return (hosts.filter { !$0.isEmpty }, going, maybe)
    }
}

/// A ticket's code in a scanned text (contract §3): a URL whose path ends `/t/<16 base32 chars>`
/// (or `#/events/<link>/t/<code>`). Only the code is kept; nothing of the text is shown.
public enum TicketScan {
    public static let codeRx = Rx("^[a-z2-7]{16}$")

    public static func isCode(_ s: String) -> Bool { codeRx.test(s) }

    public static func code(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (t as NSString).length <= 512, let u = URL(string: t), u.scheme == "https" || u.scheme == "http" else { return nil }
        var parts = u.path.split(separator: "/").map(String.init)
        if let f = u.fragment, parts.isEmpty || parts.last == "" { parts = f.split(separator: "/").map(String.init) }
        guard parts.count >= 2, parts[parts.count - 2] == "t", isCode(parts[parts.count - 1]) else { return nil }
        return parts[parts.count - 1]
    }

    /// An event address opened from outside: https://chat.<domain>/events/<link>[/t/<code>]
    /// (or the same after `#`). Only the domain, the link and the code are read.
    public static func eventLink(_ url: URL) -> (domain: String, link: String, code: String?)? {
        guard url.scheme == "https", let host = url.host?.lowercased(), host.hasPrefix("chat.") else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.isEmpty, let f = url.fragment { parts = f.split(separator: "/").map(String.init) }
        guard parts.count == 2 || parts.count == 4, parts[0] == "events" else { return nil }
        let link = parts[1]
        guard EventLinks.slugRx.test(link) || EventLinks.isD(link) else { return nil }
        var code: String?
        if parts.count == 4 {
            guard parts[2] == "t", isCode(parts[3]) else { return nil }
            code = parts[3]
        }
        let domain = String(host.dropFirst(5))
        guard Discovery.isDomain(domain) else { return nil }
        return (domain, link, code)
    }
}
