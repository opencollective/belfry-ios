import Foundation

// Meetings (web core/meetings.ts, ui/Meeting.tsx; SPEC 19.23 "Meetings"): a members-only Belfry
// event made in a few taps from a channel's ＋. The NIP-52 event carries ["t","meeting"],
// ["channel", <where it was made>] and one ["p", <key>, "", "invited"] per person invited; its chat
// ev-<d> is closed (no ticket) and each member invited is put in it (9000 by the maker). Every
// later version keeps those tags. Attendance: a host labels someone there or not (1985
// belfry/attendance, attended | absent, p, a), the latest label per person by a host counts.

public struct MeetingForm: Hashable, Sendable {
    public var topic: String
    public var people: [String] = []
    /// Unix seconds.
    public var start: Int
    public var minutes = 60
    public var place = ""
    public var online = ""
    public var tz = "UTC"
    public init(topic: String, start: Int) { self.topic = topic; self.start = start }
}

/// Someone who isn't on the belfry, added by name (an account is made for them).
public struct NamedPerson: Hashable, Sendable {
    public var name: String
    public var email: String?
    public init(name: String, email: String? = nil) { self.name = name; self.email = email }

    /// What "+" makes of the two answers: an address first → its part before @ as the name.
    public static func from(_ first: String, _ second: String) -> NamedPerson {
        let a = first.jsTrim(), b = second.jsTrim()
        if Meetings.isEmail(a) { return NamedPerson(name: b.isEmpty ? String(a.split(separator: "@").first ?? "") : b, email: a) }
        return NamedPerson(name: a, email: Meetings.isEmail(b) ? b : nil)
    }
}

/// Where a person stands for a meeting (Android SPEC 19.63, Xavier 2026-11-22: "show the status
/// of each person (invited / confirmed / checked in)"). Never told by colour alone: each has its
/// own mark.
public enum MeetingStatus: String, Sendable, CaseIterable {
    case checkedIn, confirmed, maybe, cantCome, invited
    public var label: String {
        switch self {
        case .checkedIn: return "Checked in"
        case .confirmed: return "Confirmed"
        case .maybe: return "Maybe"
        case .cantCome: return "Can't come"
        case .invited: return "Invited"
        }
    }
    /// In the counts: "1 checked in · 1 confirmed · 2 invited".
    public var word: String { label.lowercased() }
    /// SF Symbol of its mark.
    public var symbol: String {
        switch self {
        case .checkedIn: return "checkmark.circle.fill"
        case .confirmed: return "checkmark"
        case .maybe: return "questionmark"
        case .cantCome: return "xmark"
        case .invited: return "clock"
        }
    }
}

/// One person on a meeting's page and what is said under their name.
public struct MeetingPerson: Hashable, Sendable, Identifiable {
    public let pubkey: String
    public var status: MeetingStatus = .invited
    /// "Host" (the maker only), "Co-host" (an admin by role), or nil.
    public var role: String?
    /// "Host · Confirmed", "Invited"…
    public let state: String
    /// A host marked them there.
    public let there: Bool
    /// A name-only account I made (a guest join with `unsaved`, invited by me): I can hand it over.
    public let heldByMe: Bool
    public var id: String { pubkey }
}

public enum Meetings {
    public static let attendanceNS = "belfry/attendance"
    public static let lengths = [30, 45, 60, 90, 120]

    public static func isEmail(_ s: String) -> Bool { Rx("^\\S+@\\S+\\.\\S+$").test(s) }

    /// "45 min", "1 h", "1 h 30".
    public static func lengthLabel(_ m: Int) -> String {
        m < 60 ? "\(m) min" : "\(m / 60) h" + (m % 60 == 0 ? "" : " \(m % 60)")
    }

    /// The tags a meeting keeps on every version.
    public static func keptTags(_ ev: NostrEvent) -> [Tag] {
        ev.tags.filter { t in
            (t.count >= 2 && t[0] == "t" && t[1] == "meeting") || t.first == "channel" || (t.count >= 4 && t[0] == "p" && t[3] == "invited")
        }
    }

    /// A new meeting from CHANNEL: its closed chat (ev-<d>, me as creator), the event, and the
    /// members invited put in the chat. Returns the drafts in order.
    public static func create(_ m: MeetingForm, channel: String, d: String, me: String, groupsRelay: String) -> [Draft] {
        let group = "ev-" + d
        let people = m.people.reduce(into: [String]()) { out, p in if p != me && isHex64(p) && !out.contains(p) { out.append(p) } }
        var f = EventForm(title: String(m.topic.jsTrim().prefix(200)))
        f.start = m.start
        f.end = m.start + m.minutes * 60
        f.tz = m.tz
        f.location = m.place
        f.online = m.online
        f.visibility = .members
        var out = [Draft(kind: 9007, tags: [["h", group]])]
        out.append(Draft(kind: 9002, tags: [["h", group], ["name", f.title], ["about", "The meeting’s chat"], ["closed"]]))
        let extra: [Tag] = [["t", "meeting"], ["channel", channel]] + people.map { ["p", $0, "", "invited"] }
        let (kind, tags) = EventActions.versionTags(d, f, groupsRelay: groupsRelay, extra: extra)
        out.append(Draft(.main, kind: kind, content: "", tags: tags))
        for p in people { out.append(Actions.admit(group, pubkey: p)) }
        return out
    }

    /// Invite more people to meeting E: each put in its chat, then one new version with their tags.
    public static func invite(_ e: CalEvent, _ keys: [String]) -> [Draft] {
        let fresh = keys.reduce(into: [String]()) { out, k in if isHex64(k) && !e.invited.contains(k) && !out.contains(k) { out.append(k) } }
        guard !fresh.isEmpty else { return [] }
        var out = fresh.map { Actions.admit(e.groupId, pubkey: $0) }
        out.append(newVersion(e, more: fresh.map { ["p", $0, "", "invited"] }))
        return out
    }

    /// A new version of E with MORE tags (its other tags as they are; no client tag).
    public static func newVersion(_ e: CalEvent, more: [Tag]) -> Draft {
        Draft(.main, kind: e.ev.kind, content: e.ev.content, tags: e.ev.tags.filter { $0.first != "client" } + more)
    }

    /// How long before its start a meeting's check-in opens: at the start (Xavier's words, the
    /// lead's ruling 2026-11-23; one constant in case it becomes 15 minutes).
    public static let checkInOpensBefore = 0

    public static func checkInOpen(_ e: CalEvent, now: Int = .now) -> Bool { now >= e.start - checkInOpensBefore }

    /// Who is no longer among a meeting's people (vectors/meetings.json `removal`): of the chat's
    /// 9000 / 9001 signed by the MAKER or a belfry admin, the latest per `p` decides (9001 =
    /// removed, a later 9000 brings back); anyone else's are ignored; the maker is never removed.
    public static func removed(_ events: [NostrEvent], maker: String, admins: Set<String>) -> Set<String> {
        var last = [String: (at: Int, out: Bool)]()
        for e in events where (e.kind == 9000 || e.kind == 9001) && (e.pubkey == maker || admins.contains(e.pubkey)) {
            for p in e.tagValues("p") where p != maker {
                if let had = last[p], had.at > e.createdAt { continue }
                last[p] = (e.createdAt, e.kind == 9001)
            }
        }
        return Set(last.filter { $0.value.out }.keys)
    }

    /// The maker (or a belfry admin) takes PUBKEY off meeting E before it starts: out of its chat,
    /// and a new version of the event without their `p … invited`.
    public static func remove(_ e: CalEvent, pubkey: String) -> [Draft] {
        guard pubkey != e.creator, isHex64(pubkey) else { return [] }
        var out = [Draft(kind: 9001, tags: [["h", e.groupId], ["p", pubkey]])]
        if e.invited.contains(pubkey) {
            let tags = e.ev.tags.filter { t in t.first != "client" && !(t.count >= 4 && t[0] == "p" && t[1] == pubkey && t[3] == "invited") }
            out.append(Draft(.main, kind: e.ev.kind, content: e.ev.content, tags: tags))
        }
        return out
    }

    /// "1 checked in · 1 confirmed · 2 invited": the counts in words, in that order, none at 0.
    public static func counts(_ people: [MeetingPerson]) -> String {
        MeetingStatus.allCases.compactMap { s in
            let n = people.filter { $0.status == s }.count
            return n > 0 ? "\(n) \(s.word)" : nil
        }.joined(separator: " · ")
    }

    /// A host marks PUBKEY there (ON) or not.
    public static func checkIn(_ e: CalEvent, pubkey: String, on: Bool) -> Draft {
        Draft(kind: 1985, tags: [["h", e.groupId], ["L", attendanceNS], ["l", on ? "attended" : "absent", attendanceNS], ["p", pubkey], ["a", e.coord]])
    }
}

public extension Derive {
    /// Who the hosts marked there (true) or not (false): the latest label per person by a host.
    func attendance(_ e: CalEvent) -> [String: Bool] {
        var out = [String: (at: Int, on: Bool)]()
        for x in inGroup(e.groupId) where x.kind == 1985 && x.tag("L") == Meetings.attendanceNS && e.hosts.contains(x.pubkey) {
            guard let p = x.tag("p"), let l = x.tags.first(where: { $0.first == "l" }).flatMap({ $0.count > 1 ? $0[1] : nil }),
                  l == "attended" || l == "absent" else { continue }
            if let had = out[p], had.at > x.createdAt { continue }
            out[p] = (x.createdAt, l == "attended")
        }
        return out.mapValues(\.on)
    }

    /// A meeting's people: the maker, the invited, then whoever answered; each with what is said.
    func meetingPeople(_ e: CalEvent) -> [MeetingPerson] {
        var keys = [String]()
        func add(_ k: String) { if isHex64(k) && !keys.contains(k) { keys.append(k) } }
        add(e.creator)
        e.invited.forEach(add)
        e.rsvps.keys.sorted().forEach(add)
        e.goingKeys.forEach(add)
        let marks = attendance(e)
        let held = Set(guestJoins(e.groupId).filter { $0.unsaved && $0.by == me }.map(\.pubkey))
        let gone = meetingRemoved(e)
        return keys.filter { !gone.contains($0) }.map { k in
            let there = marks[k] == true
            let status: MeetingStatus
            if there { status = .checkedIn } else if let r = e.rsvps[k] {
                status = r == .accepted ? .confirmed : r == .tentative ? .maybe : .cantCome
            } else if k == e.creator { status = .confirmed } else { status = .invited }
            // only the maker is "Host"; "Co-host" = an admin by role; the belfry's admins listed in
            // the chat's 39001 are not hosts
            let r = eventRole(e, k)
            let role: String? = r == .host ? "Host" : r == .cohost ? "Co-host" : nil
            return MeetingPerson(pubkey: k, status: status, role: role, state: (role.map { $0 + " · " } ?? "") + status.label,
                                 there: there, heldByMe: held.contains(k))
        }
    }

    /// The people taken off meeting E (the maker's or a belfry admin's latest 9000 / 9001 per person).
    func meetingRemoved(_ e: CalEvent) -> Set<String> {
        Meetings.removed(inGroup(e.groupId).filter { $0.kind == 9000 || $0.kind == 9001 }, maker: e.creator, admins: communityAdmins)
    }

    /// Whether I may take someone off meeting E: its maker or a belfry admin, never a co-host
    /// (readers ignore a co-host's 9001), and only before it starts.
    func mayRemoveFromMeeting(_ e: CalEvent, now: Int = .now) -> Bool {
        (me == e.creator || communityAdmins.contains(me)) && now < e.start
    }

    /// "1 checked in · 1 confirmed · 2 invited".
    func meetingPeopleLine(_ e: CalEvent) -> String { Meetings.counts(meetingPeople(e)) }

    /// People to suggest first: the most recently active in CHANNEL, then in its parent, then
    /// their members; me left out (web suggestions()).
    func meetingSuggestions(_ channel: String, now: Int = .now) -> [String] {
        let g = group(channel)
        let parent = g?.parent.flatMap { group($0) }
        var keys = [String]()
        func add(_ list: [String]) { for k in list where k != me && isHex64(k) && !keys.contains(k) { keys.append(k) } }
        add(recentlyActive(channel, now: now).sorted { $0.at > $1.at }.map(\.pubkey))
        if let parent { add(recentlyActive(parent.id, now: now).sorted { $0.at > $1.at }.map(\.pubkey)) }
        add(Array(g?.members ?? []).sorted())
        add(Array(parent?.members ?? []).sorted())
        return keys
    }

    /// Anyone whose name matches Q, suggestions first.
    func findPeople(_ channel: String, _ q: String, limit: Int = 8) -> [String] {
        let s = q.jsTrim().lowercased()
        let first = meetingSuggestions(channel)
        if s.isEmpty { return Array(first.prefix(limit)) }
        var pool = first
        for k in profiles().keys.sorted() where k != me && !pool.contains(k) { pool.append(k) }
        return Array(pool.filter { displayName($0).lowercased().contains(s) }.prefix(limit))
    }

    /// The place of my last meeting (then of my last event), for the default.
    func lastMeetingPlace() -> String {
        let mine = calendar.filter { $0.creator == me && !($0.location ?? "").jsTrim().isEmpty }.sorted { $0.ev.createdAt > $1.ev.createdAt }
        return (mine.first { $0.meeting } ?? mine.first)?.location ?? ""
    }

    /// The last five places of meetings, newest first.
    func meetingPlaces() -> [String] {
        var out = [String]()
        for e in calendar.filter(\.meeting).sorted(by: { $0.ev.createdAt > $1.ev.createdAt }) {
            if let l = e.location?.jsTrim(), !l.isEmpty, !out.contains(l) { out.append(l) }
        }
        return Array(out.prefix(5))
    }

    /// "N people" for a meeting's rows (maker + invited + who answered).
    func meetingCount(_ e: CalEvent) -> Int { meetingPeople(e).count }
}

// ---- the belfry's API: people who aren't on it (meetingguests.py) -------------------------------

public struct MeetingGuest: Hashable, Sendable {
    public let pubkey: String
    public let held: Bool
    public let member: Bool
}

public extension BelfryAPI {
    static let meetingErrors = [
        "invalid": "A name, and an e-mail address if you have one.",
        "not_host": "Only the meeting’s hosts can add people.",
        "guest": "Guests can’t add people.",
        "no_channel": "The meeting’s chat isn’t on the relay yet. Try again in a moment.",
        "unsupported": "This belfry can’t add people by name yet.",
        "signer": "The belfry could not make an account just now. Try again.",
        "not_yours": "Only who made this account can hand it over.",
        "has_email": "This account has an e-mail address already.",
        "taken": "That address is someone else’s account here.",
    ]
    /// Errors worth trying again for (the meeting's chat may not be on the relay yet).
    static let meetingRetry: Set<String> = ["no_channel", "not_host", "signer", "network"]

    /// An account for someone who isn't on the belfry, put in the meeting's chat: with an e-mail,
    /// the account behind that address; without, one held by me until I hand it over.
    func meetingGuest(channel: String, _ n: NamedPerson) async throws -> MeetingGuest {
        var body: [String: Any] = ["channel": channel, "name": String(n.name.jsTrim().prefix(100))]
        if let e = n.email?.jsTrim(), !e.isEmpty { body["email"] = e }
        let a = try await signed(base + "/meeting-guests", method: "POST", json: body)
        guard a.ok, let b = a.body, let pk = b["pubkey"] as? String, isHex64(pk) else {
            throw BelfryAPI.fail(a, BelfryAPI.meetingErrors, "Could not add them just now.")
        }
        return MeetingGuest(pubkey: pk, held: b["held"] as? Bool ?? false, member: b["member"] as? Bool ?? false)
    }

    /// The same, tried up to six times (1 s, 2 s … 5 s apart) while the answer may change.
    func meetingGuestRetrying(channel: String, _ n: NamedPerson, wait: (Int) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000) }) async throws -> MeetingGuest {
        var i = 0
        while true {
            do { return try await meetingGuest(channel: channel, n) } catch let e as ApiError {
                guard i < 5, BelfryAPI.meetingRetry.contains(e.code) else { throw e }
                i += 1
                await wait(min(5, i))
            }
        }
    }

    /// Hand a name-only account I made to its person: their address goes on it.
    func meetingHandOver(pubkey: String, email: String) async throws {
        let a = try await signed(base + "/meeting-guests/transfer", method: "POST", json: ["pubkey": pubkey, "email": email.jsTrim()])
        guard a.ok else { throw BelfryAPI.fail(a, BelfryAPI.meetingErrors, "That did not work. Try again.") }
    }
}
