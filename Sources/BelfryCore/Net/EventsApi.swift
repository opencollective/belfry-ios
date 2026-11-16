import Foundation

// Belfry events through the belfry's API (events.py; SPEC 19.18): `<api base>/events/<link>`
// (read), `/events/slug`, `PUT /events/<d>/slug`, `POST /events/<d>/join`, `/apply`, `/decide`,
// and co-host links (`POST /channel-invites` with `role: host`). Signed by the member (NIP-98).
// Failures are ApiErrors with fixed messages chosen by the server's `error` key.

public struct ApiTicket: Hashable, Sendable {
    public let d, id, title, summary: String
    public let quantity, left: Int?
    public let closed: Bool
    public let prompt: String
    public let members: Bool
    public let position: Int
    public let implicit: Bool
    public var ticket: Ticket {
        Ticket(d: d, id: id, title: title, summary: summary, quantity: quantity, closed: closed, prompt: prompt, members: members,
               position: position, implicit: implicit, ev: nil, apiLeft: left)
    }
}

public struct ApiMe: Hashable, Sendable {
    public let host: Bool
    public let ticket: String?
    public let applied, waitlist, declined: Bool
    public let rsvp: Rsvp?
    public let member: Bool
    /// The `viewer` fields of the check-in contract (SPEC 19.29); an older belfry sends none.
    public var ticketCode: String? = nil
    /// What my ticket's QR holds: https://chat.<domain>/events/<link>/t/<code> (never shown as text).
    public var ticketURL: String? = nil
    public var checkedIn: Int? = nil
    /// Subset of host, cohost, steward.
    public var roles: [String] = []
    public var mayCheckIn = false
}

/// What the belfry told me about myself at one event, kept on the phone per event (offline
/// first: my ticket's QR shows without a connection).
public struct EventViewer: Codable, Hashable, Sendable {
    public var ticket: String?
    public var ticketCode: String?
    public var ticketURL: String?
    public var checkedIn: Int?
    public var roles: [String]
    public var mayCheckIn: Bool
    public var at: Int
    public init(ticket: String?, ticketCode: String?, ticketURL: String?, checkedIn: Int?, roles: [String], mayCheckIn: Bool, at: Int) {
        self.ticket = ticket; self.ticketCode = ticketCode; self.ticketURL = ticketURL; self.checkedIn = checkedIn
        self.roles = roles; self.mayCheckIn = mayCheckIn; self.at = at
    }
    public init(_ m: ApiMe, at: Int) {
        self.init(ticket: m.ticket, ticketCode: m.ticketCode, ticketURL: m.ticketURL, checkedIn: m.checkedIn, roles: m.roles, mayCheckIn: m.mayCheckIn, at: at)
    }
}

/// A ticket holder as the check-in list shows them (`POST /events/<d>/attendees`).
public struct Attendee: Codable, Hashable, Sendable, Identifiable {
    public var pubkey: String
    public var name: String
    public var ticket: String
    public var ticketTitle: String
    public var rsvp: String?
    public var checkedIn: Int?
    public var role: String
    public var id: String { pubkey }
    public init(pubkey: String, name: String, ticket: String, ticketTitle: String, rsvp: String?, checkedIn: Int?, role: String) {
        self.pubkey = pubkey; self.name = name; self.ticket = ticket; self.ticketTitle = ticketTitle
        self.rsvp = rsvp; self.checkedIn = checkedIn; self.role = role
    }
}

public struct AttendeeList: Codable, Hashable, Sendable {
    public var people: [Attendee]
    public var going: Int
    public var checkedIn: Int
    public init(people: [Attendee], going: Int, checkedIn: Int) { self.people = people; self.going = going; self.checkedIn = checkedIn }
}

public struct CheckInResult: Hashable, Sendable {
    public let person: Attendee
    public let already: Bool
    public init(person: Attendee, already: Bool) { self.person = person; self.already = already }
}

public struct ApiEvent: Hashable, Sendable {
    public let d, coord: String
    public let kind: Int
    public let group, link, url, title, description: String
    public let allDay: Bool
    public let start, end: String?
    public let tz, location: String
    public let online: Bool
    public let links: [String]
    public let cover: String?
    public let visibility: Visibility
    public let status: EventStatus
    public let statusReason: String
    /// (pubkey, name)
    public let hosts: [[String]]
    public let tickets: [ApiTicket]
    public let going: Int
    public let community: String
    public let me: ApiMe?

    /// The event in the app's own shape (for guests, and cards they get).
    public func calEvent(timeZone: TimeZone, me mine: String) -> CalEvent {
        let parts = coord.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let k = parts.first.flatMap { Int($0) } ?? kind
        let creator = parts.count > 1 ? parts[1] : ""
        let isAllDay = k == 31922
        func parse(_ v: String?) -> Int? {
            guard let v, !v.isEmpty else { return nil }
            if isAllDay {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = timeZone
                let p = v.prefix(10).split(separator: "-").compactMap { Int($0) }
                guard p.count == 3 else { return nil }
                return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2])).map { Int($0.timeIntervalSince1970) }
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: v) { return Int(d.timeIntervalSince1970) }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: v).map { Int($0.timeIntervalSince1970) }
        }
        let fake = NostrEvent(id: "api-" + d, pubkey: creator, createdAt: 0, kind: k, tags: [["d", d]], content: description)
        var e = CalEvent(coord: coord, d: d, ev: fake, title: title, description: description, location: location.isEmpty ? nil : location,
                         allDay: isAllDay, start: parse(start) ?? 0, end: parse(end), groupId: group, links: links,
                         rsvps: me?.rsvp.map { [mine: $0] } ?? [:], tz: tz.isEmpty ? nil : tz, isNew: true, creator: creator,
                         hosts: Set(hosts.compactMap(\.first)), cover: cover, visibility: visibility, slug: link != d ? link : nil,
                         status: status, statusReason: statusReason.isEmpty ? nil : statusReason, versions: [fake])
        e.remote = true
        e.goingCount = going
        return e
    }

    /// Where I stand as the belfry says it (guests; the API's `me`).
    public var myState: MyState {
        guard let m = me else { return .none }
        if m.declined { return .declined }
        if m.ticket != nil { return m.rsvp == .tentative ? .maybe : m.rsvp == .declined ? .cant : .ticket }
        if m.applied { return m.waitlist ? .waitlist : .applied }
        switch m.rsvp {
        case .some(.accepted): return .ticket
        case .some(.tentative): return .maybe
        case .some(.declined): return .cant
        case .none: return m.host ? .host : MyState.none
        }
    }
}

public struct SlugCheck: Hashable, Sendable {
    public let free: Bool
    public let suggestion: String
    public let problem: String?
    public init(free: Bool, suggestion: String, problem: String?) { self.free = free; self.suggestion = suggestion; self.problem = problem }
}

public extension BelfryAPI {
    internal var eventsBase: String { config.apiBase + "/events" }

    internal static func eventFail(_ a: Answer, _ fallback: String, _ own: [String: String] = [:]) -> ApiError {
        let code = a.error.isEmpty ? (a.status == 0 ? "network" : "http") : a.error
        return ApiError(code, a.status, own[code] ?? eventErrors[code] ?? fallback)
    }

    /// The event as the belfry tells it to me. Codes: `not_found`, `members_only`.
    func event(_ link: String) async throws -> ApiEvent {
        let a = try await signed(eventsBase + "/" + MailThreads.encodeURIComponent(link))
        if a.status == 403 { throw ApiError("members_only", 403, BelfryAPI.eventErrors["members_only"]!) }
        if a.status == 404 { throw ApiError("not_found", 404, BelfryAPI.eventErrors["not_found"]!) }
        guard a.ok, let b = a.body, let e = BelfryAPI.parseEvent(b) else { throw BelfryAPI.eventFail(a, "The event could not be read just now.") }
        return e
    }

    /// Is that custom URL free? EVENT: the event it is for (its own name counts as free).
    func slugCheck(_ name: String, event: String = "") async throws -> SlugCheck {
        let q = "name=" + MailThreads.encodeURIComponent(name) + (event.isEmpty ? "" : "&event=" + MailThreads.encodeURIComponent(event))
        let a = try await signed(eventsBase + "/slug?" + q)
        guard a.ok, let b = a.body else { throw BelfryAPI.eventFail(a, "Could not check the URL.") }
        return SlugCheck(free: b["free"] as? Bool ?? false, suggestion: b["suggestion"] as? String ?? name, problem: b["problem"] as? String)
    }

    /// A host sets the event's URL to /events/<slug>. Codes: `taken`, `invalid`, `not_host`.
    func claimSlug(d: String, slug: String) async throws {
        let a = try await signed(eventsBase + "/" + d + "/slug", method: "PUT", json: ["slug": slug])
        if !a.ok { throw BelfryAPI.eventFail(a, "That URL could not be set.") }
    }

    /// Take an open ticket (the belfry checks the places and issues it).
    func joinEvent(d: String, ticket: String) async throws {
        let a = try await signed(eventsBase + "/" + d + "/join", method: "POST", json: ["ticket": ticket])
        if !a.ok { throw BelfryAPI.eventFail(a, BelfryAPI.generic) }
    }

    /// A guest's application: their own signed 9021, which the belfry hands to the group.
    func applyEvent(d: String, ticket: String, request: NostrEvent) async throws {
        let req = (JSON.parse(request.json) as? [String: Any]) ?? [:]
        let a = try await signed(eventsBase + "/" + d + "/apply", method: "POST", json: ["ticket": ticket, "request": req])
        if !a.ok { throw BelfryAPI.eventFail(a, "Your application did not go through. Try again.") }
    }

    /// A host who can't moderate on the relay (a guest co-host): the belfry decides for them.
    func decideEvent(d: String, pubkey: String, approve: Bool, ticket: String?) async throws {
        var body: [String: Any] = ["pubkey": pubkey, "action": approve ? "approve" : "decline"]
        if let ticket { body["ticket"] = ticket }
        let a = try await signed(eventsBase + "/" + d + "/decide", method: "POST", json: body)
        if !a.ok { throw BelfryAPI.eventFail(a, "That did not work.") }
    }

    /// A co-host invitation link: for one person, for a day. Whoever opens it becomes a host.
    func coHostLink(group: String) async throws -> String {
        let a = try await signed(config.channelInvites, method: "POST", json: ["channel": group, "role": "host", "people": 1, "link_days": 1])
        guard a.ok, let url = a.body?["url"] as? String, url.hasPrefix("https://") else {
            throw BelfryAPI.eventFail(a, "The link could not be made.", ["invalid": "This event can’t have co-host links.", "not_allowed": "You can’t invite here.", "guest": "Guests can’t make co-host links."])
        }
        return url
    }

    /// The API's answer, or nil when it is not an event. Text fields cut to sane lengths.
    static func parseEvent(_ o: [String: Any]) -> ApiEvent? {
        guard let d = o["d"] as? String, let coord = o["coord"] as? String, let group = o["group"] as? String else { return nil }
        func s(_ k: String) -> String? { o[k] as? String }
        var me: ApiMe?
        // `me` (events v1) and `viewer` (the check-in contract): read both, viewer's fields win
        let mo = o["me"] as? [String: Any], vo = o["viewer"] as? [String: Any]
        if mo != nil || vo != nil {
            var m = mo ?? [:]
            for (k, v) in vo ?? [:] { m[k] = v }
            var x = ApiMe(host: m["host"] as? Bool ?? false, ticket: m["ticket"] as? String, applied: m["applied"] as? Bool ?? false,
                          waitlist: m["waitlist"] as? Bool ?? false, declined: m["declined"] as? Bool ?? false,
                          rsvp: Rsvp(rawValue: m["rsvp"] as? String ?? ""), member: m["member"] as? Bool ?? false)
            if let c = m["ticket_code"] as? String, TicketScan.isCode(c) {
                x.ticketCode = c
                let u = m["ticket_url"] as? String ?? ""
                x.ticketURL = u.hasPrefix("https://") && u.hasSuffix("/t/" + c) && (u as NSString).length <= 400 ? u : nil
            }
            x.checkedIn = int(m["checked_in"])
            x.roles = (m["roles"] as? [Any] ?? []).compactMap { $0 as? String }.filter { ["host", "cohost", "steward"].contains($0) }
            x.mayCheckIn = m["may_check_in"] as? Bool ?? false
            me = x
        }
        let tickets: [ApiTicket] = (o["tickets"] as? [[String: Any]] ?? []).compactMap { x in
            guard let td = x["d"] as? String else { return nil }
            let id = x["id"] as? String ?? String(td.split(separator: ":", maxSplits: 1).last ?? "")
            return ApiTicket(d: td, id: id, title: (x["title"] as? String ?? "Ticket").sliceUnits(120), summary: (x["summary"] as? String ?? "").sliceUnits(300),
                             quantity: int(x["quantity"]), left: int(x["left"]), closed: x["closed"] as? Bool ?? false,
                             prompt: (x["prompt"] as? String ?? "").sliceUnits(500), members: x["members"] as? Bool ?? false,
                             position: int(x["position"]) ?? 0, implicit: x["implicit"] as? Bool ?? false)
        }
        let hosts: [[String]] = (o["hosts"] as? [[String: Any]] ?? []).compactMap { h in
            guard let pk = h["pubkey"] as? String else { return nil }
            return [pk, (h["name"] as? String ?? "").sliceUnits(100)]
        }
        return ApiEvent(d: d, coord: coord, kind: int(o["kind"]) ?? 31923, group: group, link: s("link") ?? d, url: s("url") ?? "",
                        title: (s("title") ?? "Untitled").sliceUnits(200), description: (s("description") ?? "").sliceUnits(20_000),
                        allDay: o["all_day"] as? Bool ?? false, start: s("start"), end: s("end"), tz: s("tz") ?? "",
                        location: (s("location") ?? "").sliceUnits(300), online: o["online"] as? Bool ?? false,
                        links: (o["links"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil } },
                        cover: s("cover").flatMap { $0.hasPrefix("https://") ? $0 : nil }, visibility: Visibility.of(s("visibility")),
                        status: s("status") == "cancelled" ? .cancelled : .scheduled, statusReason: (s("status_reason") ?? "").sliceUnits(500),
                        hosts: hosts, tickets: tickets, going: int(o["going"]) ?? 0, community: (s("community") ?? "").sliceUnits(100), me: me)
    }

    // ---- check-in and roles in a group (SPEC 19.29) ---------------------------------------------

    /// The message when the belfry does not know a new endpoint yet (404 without one of its codes).
    static let updateNeeded = "This belfry needs an update."

    static func checkinFail(_ a: Answer, _ fallback: String, known: Set<String>) -> ApiError {
        if a.status == 404 && !known.contains(a.error) { return ApiError("update_needed", 404, updateNeeded) }
        if a.status == 405 { return ApiError("update_needed", 405, updateNeeded) }
        return eventFail(a, fallback, checkinErrors)
    }

    static func parseAttendee(_ x: [String: Any]) -> Attendee? {
        guard let pk = x["pubkey"] as? String, isHex64(pk) else { return nil }
        return Attendee(pubkey: pk, name: (x["name"] as? String ?? "").sliceUnits(100), ticket: (x["ticket"] as? String ?? "").sliceUnits(200),
                        ticketTitle: (x["ticket_title"] as? String ?? "").sliceUnits(120), rsvp: x["rsvp"] as? String,
                        checkedIn: int(x["checked_in"]), role: (x["role"] as? String ?? "member").sliceUnits(20))
    }

    /// Ticket holders with their check-in state (hosts, co-hosts, stewards). Codes: `not_allowed`.
    func attendees(d: String) async throws -> AttendeeList {
        let a = try await signed(eventsBase + "/" + d + "/attendees", method: "POST", json: [:])
        guard a.ok, let b = a.body else { throw BelfryAPI.checkinFail(a, "The list could not be loaded.", known: ["not_allowed"]) }
        let people = (b["people"] as? [[String: Any]] ?? []).compactMap(BelfryAPI.parseAttendee)
        return AttendeeList(people: people, going: BelfryAPI.int(b["going"]) ?? people.count, checkedIn: BelfryAPI.int(b["checked_in"]) ?? people.filter { $0.checkedIn != nil }.count)
    }

    /// Check someone in (by their ticket's CODE or their PUBKEY), or UNDO it. Codes: `no_ticket`, `not_allowed`.
    /// PEEK: who it is and whether they are in, nothing recorded (the card a ticket link opens).
    func checkIn(d: String, code: String? = nil, pubkey: String? = nil, undo: Bool = false, peek: Bool = false) async throws -> CheckInResult {
        var body: [String: Any] = [:]
        if let code { body["code"] = code } else if let pubkey { body["pubkey"] = pubkey }
        if undo { body["undo"] = true }
        if peek { body["peek"] = true }
        let a = try await signed(eventsBase + "/" + d + "/checkin", method: "POST", json: body)
        guard a.ok, let b = a.body, let p = (b["person"] as? [String: Any]).flatMap(BelfryAPI.parseAttendee) else {
            throw BelfryAPI.checkinFail(a, "That did not work. Try again.", known: ["no_ticket", "not_allowed"])
        }
        return CheckInResult(person: p, already: b["already"] as? Bool ?? false)
    }

    /// Change PUBKEY's role in a channel, group or event. Codes: `not_allowed`, `not_in_group`,
    /// `last_admin`, `guest_not_saved`, `agent`, `events_only`.
    func setGroupRole(channel: String, pubkey: String, role: GroupRole) async throws -> GroupRole {
        let a = try await signed(base + "/group-roles", method: "POST", json: ["channel": channel, "pubkey": pubkey, "role": role.rawValue])
        guard a.ok else {
            throw BelfryAPI.checkinFail(a, "The role could not be changed.", known: BelfryAPI.roleCodes)
        }
        return GroupRole(rawValue: a.body?["role"] as? String ?? "") ?? role
    }

    /// Take PUBKEY out of a channel, group or event through the belfry (`role: removed`). An
    /// older belfry answers `update_needed`: the caller falls back to its own 9001.
    func removeFromGroup(channel: String, pubkey: String) async throws {
        let a = try await signed(base + "/group-roles", method: "POST", json: ["channel": channel, "pubkey": pubkey, "role": "removed"])
        guard a.ok else { throw BelfryAPI.checkinFail(a, "They could not be removed.", known: BelfryAPI.roleCodes) }
    }

    /// Change a group's name / description / picture / access through the belfry (an admin by role:
    /// the relay refuses their own 9002). Only the fields given change. Codes: `not_allowed`,
    /// `not_found`, `invalid`, `relay`, and (SPEC 19.30) `archived` (an archived group takes only
    /// `archived: false`), `always_open` (#general). Returns the `archived` the belfry answers
    /// with, nil when it says nothing about it (a belfry from before archiving).
    @discardableResult
    func groupMeta(channel: String, name: String? = nil, about: String? = nil, picture: String? = nil, closed: Bool? = nil, prompt: String? = nil, archived: Bool? = nil) async throws -> Bool? {
        var body: [String: Any] = ["channel": channel]
        if let name { body["name"] = name }
        if let about { body["about"] = about }
        if let picture { body["picture"] = picture }
        if let closed { body["closed"] = closed }
        if let prompt { body["prompt"] = prompt }
        if let archived { body["archived"] = archived }
        let a = try await signed(base + "/group-meta", method: "POST", json: body)
        guard a.ok else { throw BelfryAPI.checkinFail(a, "The change could not be saved.", known: ["not_allowed", "not_found", "invalid", "relay", "archived", "always_open"]) }
        return a.body?["archived"] as? Bool
    }

    internal static let roleCodes: Set<String> = ["not_allowed", "not_in_group", "last_admin", "guest_not_saved", "agent", "events_only", "always_admin", "invalid", "relay", "archived"]

    static let checkinErrors = [
        // the web chat's words (checkin.ts CHECK_ERRORS)
        "not_allowed": "Only the admins can change this.",
        "not_in_group": "This person isn’t in the group.",
        "last_admin": "A group keeps at least one admin.",
        "guest_not_saved": "This guest has no e-mail yet. Once they save their account, they can be an admin.",
        "agent": "An agent can’t be an admin.",
        "events_only": "Stewards are for events.",
        "always_admin": "The host and the belfry’s admins stay admins.",
        "invalid": "That did not work. Try again.",
        "relay": "The event could not be reached. Try again.",
        "no_ticket": "Not a ticket for this event",
        "archived": "This group is archived: nothing changes in it until it is unarchived.",
        "always_open": "#general can’t be archived.",
        "update_needed": updateNeeded,
    ]

    static let eventErrors = [
        "not_found": "There is no such event here.",
        "members_only": "This event is for members.",
        "too_many": "Too many requests for now. Try again in a minute.",
        "cancelled": "This event is cancelled.",
        "ended": "This event is over.",
        "no_ticket": "Pick one of the event’s tickets.",
        "needs_application": "This ticket takes an application.",
        "full": "This ticket is full: join the waitlist.",
        "use_join": "This ticket is open: take it.",
        "name_needed": "Tell us your name.",
        "email_needed": "An application needs your e-mail address.",
        "member_email": "This address belongs to a member: sign in with it instead.",
        "publish_yourself": "That did not work. Try again.",
        "request_needed": "Your application did not go through. Try again.",
        "bad_request": "Your application did not go through. Try again.",
        "relay": "The event could not be reached. Try again.",
        "failed": "That did not work just now. Try again.",
        "not_host": "Only the event’s hosts can do this.",
        "taken": "Another event has that URL.",
        "invalid": "That URL can’t be used.",
        "unsupported": "This belfry does not have event guests yet.",
        "unauthorized": "Your session was not accepted. Sign in again.",
        "no_pass": "Only members can do this.",
        "network": "No connection to the belfry.",
    ]
}
