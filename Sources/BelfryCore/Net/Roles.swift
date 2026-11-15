import Foundation

// Roles, member links and the belfry's membership settings (collective-belfry docs/roles.md,
// docs/membership.md, docs/guests.md; web src/core/roles.ts, invite.ts, requests.ts). Errors are
// fixed words per code, never the server's text.

public struct Role: Hashable, Sendable, Identifiable {
    public let id: String
    public var label: String
    public var description: String
    public var builtin: Bool
    public var powers: Bool
    public var isDefault: Bool
    public init(id: String, label: String, description: String = "", builtin: Bool = false, powers: Bool = false, isDefault: Bool = false) {
        self.id = id; self.label = label; self.description = description; self.builtin = builtin; self.powers = powers; self.isDefault = isDefault
    }

    public static let member = "member"
    public static let admin = "admin"
    /// What a belfry without the roles API answers (the two built-ins).
    public static let builtins = [
        Role(id: member, label: "Member", description: "Joins any open channel, invites guests, votes.", builtin: true, isDefault: true),
        Role(id: admin, label: "Admin", description: "Everything, plus settings and roles.", builtin: true, powers: true),
    ]
}

public struct RolesInfo: Hashable, Sendable {
    public var roles: [Role]
    public var defaultRole: String
    /// member key → role id (every member; guests and agents have none)
    public var members: [String: String]
    public init(roles: [Role] = Role.builtins, defaultRole: String = Role.member, members: [String: String] = [:]) {
        self.roles = roles; self.defaultRole = defaultRole; self.members = members
    }
    public func role(_ id: String?) -> Role? { id.flatMap { i in roles.first { $0.id == i } } }
    /// The label to show next to a member (nil = no role to show: a guest, an agent, or plain Member).
    public func label(of pubkey: String) -> String? {
        guard let id = members[pubkey], id != Role.member, let r = role(id) else { return nil }
        return r.label
    }

    /// `GET /roles`, cleaned (ids and labels as strings, the built-ins always there, member first,
    /// admin last).
    public static func parse(_ b: [String: Any]) -> RolesInfo {
        var list = [Role]()
        for o in b["roles"] as? [[String: Any]] ?? [] {
            guard let id = o["id"] as? String, !id.isEmpty, let label = o["label"] as? String, !label.isEmpty,
                  !list.contains(where: { $0.id == id }) else { continue }
            list.append(Role(id: id, label: label.sliceUnits(40), description: (o["description"] as? String ?? "").sliceUnits(200),
                             builtin: o["builtin"] as? Bool ?? (id == Role.member || id == Role.admin),
                             powers: o["powers"] as? Bool ?? (id == Role.admin), isDefault: o["default"] as? Bool ?? false))
        }
        for r in Role.builtins where !list.contains(where: { $0.id == r.id }) { list.append(r) }
        let member = list.filter { $0.id == Role.member }, admin = list.filter { $0.id == Role.admin }
        list = member + list.filter { $0.id != Role.member && $0.id != Role.admin } + admin
        var def = b["default"] as? String ?? Role.member
        if !list.contains(where: { $0.id == def }) || def == Role.admin { def = Role.member }
        for i in list.indices { list[i].isDefault = list[i].id == def }
        var members = [String: String]()
        for (k, v) in b["members"] as? [String: Any] ?? [:] { if isHex64(k), let r = v as? String { members[k] = r } }
        return RolesInfo(roles: list, defaultRole: def, members: members)
    }
}

/// Membership settings (`GET /membership`).
public struct MembershipSettings: Hashable, Sendable {
    /// admins | members
    public var invite: String
    /// admins | vouches
    public var accept: String
    public var vouches: Int
    public var mayInviteMembers: Bool
    public var admin: Bool
    public init(invite: String = "admins", accept: String = "admins", vouches: Int = 2, mayInviteMembers: Bool = false, admin: Bool = false) {
        self.invite = invite; self.accept = accept; self.vouches = vouches; self.mayInviteMembers = mayInviteMembers; self.admin = admin
    }
    public static func parse(_ b: [String: Any]) -> MembershipSettings {
        MembershipSettings(invite: b["invite"] as? String == "members" ? "members" : "admins",
                           accept: b["accept"] as? String == "vouches" ? "vouches" : "admins",
                           vouches: max(1, min(5, (b["vouches"] as? NSNumber)?.intValue ?? 2)),
                           mayInviteMembers: b["may_invite_members"] as? Bool ?? false, admin: b["admin"] as? Bool ?? false)
    }
}

/// Who a link brings in (the invite sheet's "Joins as").
public enum JoinsAs: Hashable, Sendable {
    /// a guest of the channel for 1, 7 or 30 days
    case guest(days: Int)
    /// my own agent
    case agent
    /// a member of the belfry with a role, for a month, a year or for good
    case member(role: String, membership: String)

    public static let memberships = ["month", "year", "permanent"]

    /// "Guest for a day" / "My own agent" / "<Role> · one year", and the line under it.
    public func line(channel: String, community: String, roles: RolesInfo) -> (String, String) {
        switch self {
        case .guest(let d): return ("Guest for \(JoinsAs.daysWord(d))", "\(channel) only, for \(JoinsAs.daysWord(d))")
        case .agent: return ("My own agent", "Your AI agent: a member for as long as you are one")
        case .member(let r, let m):
            return ("\(roles.role(r)?.label ?? "Member") · \(JoinsAs.membershipWord(m))", "A member of \(community), starting in \(channel)")
        }
    }

    public static func daysWord(_ d: Int) -> String { d == 7 ? "a week" : d == 30 ? "a month" : "a day" }
    public static func membershipWord(_ m: String) -> String { m == "month" ? "one month" : m == "year" ? "one year" : "permanent" }

    /// An agent's or an admin's link is for one person, whatever "Link" says.
    public func people(_ asked: Int) -> Int {
        switch self {
        case .agent: return 1
        case .member(let r, _) where r == Role.admin: return 1
        default: return asked == 50 ? 50 : 1
        }
    }

    /// The body of `POST /channel-invites` (web makeInviteLink).
    public func body(channel: String, people: Int, linkDays: Int) -> [String: Any] {
        var b: [String: Any] = ["channel": channel, "people": self.people(people), "link_days": [1, 7, 30].contains(linkDays) ? linkDays : 1]
        switch self {
        case .guest(let d): b["guest_days"] = [1, 7, 30].contains(d) ? d : 1
        case .agent: b["agent"] = true
        case .member(let r, let m):
            b["as"] = "member"; b["role"] = r; b["membership"] = JoinsAs.memberships.contains(m) ? m : "permanent"
        }
        return b
    }

    public var isAgent: Bool { if case .agent = self { return true }; return false }
}

public extension BelfryAPI {
    static let roleErrors = [
        "not_admin": "Only admins of the belfry can do this.",
        "not_here": "Only people of this belfry can see its roles.",
        "unknown_role": "That role doesn’t exist any more.",
        "invalid": "A label of 1 to 40 characters; a description of up to 200.",
        "taken": "There is a role with that label already.",
        "builtin": "Member and Admin are built in: they can’t be deleted.",
        "admin_default": "Admin can’t be the default role.",
        "not_member": "Only members have a role.",
        "guest_not_saved": "This guest has no e-mail yet. Once they save their account, you can make them a member.",
        "agent": "An agent has no role.",
        "last_admin": "A belfry needs at least one admin.",
        "too_many": "A belfry has at most 50 roles.",
        "unsupported": "This belfry can’t keep roles yet.",
    ]
    static let linkErrors = [
        "not_admin": "Only admins of the belfry invite members.",
        "not_allowed": "You can’t invite people to this channel.",
        "guest": "Guests can’t invite.",
        "agent": "Agents can’t invite.",
        "unknown_role": "That role doesn’t exist any more. Pick another.",
        "limit": "You have your agent already.",
        "unsupported": "This belfry does not take guests.",
        "no_channel": "This channel is not known to the belfry yet.",
        "invalid": "The link could not be made. Try again.",
    ]

    /// `POST /channel-invites` for WHO (a guest, my agent, a member with a role).
    func createInvite(channel: String, joinsAs who: JoinsAs, people: Int, linkDays: Int) async throws -> GuestLink {
        let a = try await signed(config.channelInvites, method: "POST", json: who.body(channel: channel, people: people, linkDays: linkDays))
        guard a.ok, let b = a.body, let url = b["url"] as? String, url.hasPrefix("https://") else {
            throw BelfryAPI.fail(a, BelfryAPI.linkErrors, "The link could not be made. Try again.")
        }
        return GuestLink(url: url, agentURL: (b["agent_url"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil },
                         days: BelfryAPI.int(b["days"]) ?? 0, people: BelfryAPI.int(b["people"]) ?? who.people(people),
                         linkDays: BelfryAPI.int(b["link_days"]) ?? linkDays, expiresAt: b["expires_at"] as? String,
                         ownAgent: BelfryAPI.bool(b["own_agent"]) ?? who.isAgent)
    }

    /// `GET /roles`. An older belfry (404) answers the two built-ins.
    func roles() async throws -> RolesInfo {
        let a = try await signed(base + "/roles")
        if a.status == 404 && a.error.isEmpty { return RolesInfo() }
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.roleErrors, "Could not read the roles. Try again.") }
        return RolesInfo.parse(b)
    }

    /// `POST /roles` (new) or `/roles/<id>` (change). Returns the roles after.
    func saveRole(id: String?, label: String, description: String, makeDefault: Bool?) async throws -> RolesInfo {
        var body: [String: Any] = ["label": label, "description": description]
        if let makeDefault { body["default"] = makeDefault }
        let path = id.map { "/roles/" + MailThreads.encodeURIComponent($0) } ?? "/roles"
        let a = try await signed(base + path, method: "POST", json: body)
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.roleErrors, "That did not work. Try again.") }
        return RolesInfo.parse(b)
    }

    func deleteRole(_ id: String) async throws -> RolesInfo {
        let a = try await signed(base + "/roles/" + MailThreads.encodeURIComponent(id) + "/delete", method: "POST", json: [:])
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.roleErrors, "That did not work. Try again.") }
        return RolesInfo.parse(b)
    }

    /// `POST /member-roles`: a member's role (a saved guest becomes a member with it).
    func setMemberRole(_ pubkey: String, role: String) async throws {
        let a = try await signed(base + "/member-roles", method: "POST", json: ["pubkey": pubkey, "role": role])
        guard a.ok else { throw BelfryAPI.fail(a, BelfryAPI.roleErrors, "That did not work. Try again.") }
    }

    /// `GET /membership`. An older belfry (404): the defaults.
    func membership() async throws -> MembershipSettings {
        let a = try await signed(base + "/membership")
        if a.status == 404 && a.error.isEmpty { return MembershipSettings() }
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.roleErrors, "Could not read the membership settings.") }
        return MembershipSettings.parse(b)
    }

    func setMembership(invite: String? = nil, accept: String? = nil, vouches: Int? = nil) async throws -> MembershipSettings {
        var body = [String: Any]()
        if let invite { body["invite"] = invite }
        if let accept { body["accept"] = accept }
        if let vouches { body["vouches"] = vouches }
        let a = try await signed(base + "/membership", method: "POST", json: body)
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.roleErrors, "That did not work. Try again.") }
        return MembershipSettings.parse(b)
    }
}

// ---- requests to join the belfry, agents asking to join (docs/membership.md, docs/agents.md) ---

public struct BelfryRequest: Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let motivation: String
    public let created: String
    public let vouches: Int
    public let vouched: Bool
    public let email: String?
    public init(id: Int, name: String, motivation: String, created: String, vouches: Int, vouched: Bool, email: String?) {
        self.id = id; self.name = name; self.motivation = motivation; self.created = created; self.vouches = vouches; self.vouched = vouched; self.email = email
    }
}

public struct AgentRequest: Hashable, Sendable, Identifiable {
    public let id: Int
    public let pubkey: String
    public let name: String
    public let about: String
    public let created: String
    public let forMe: Bool
    public init(id: Int, pubkey: String, name: String, about: String, created: String, forMe: Bool) {
        self.id = id; self.pubkey = pubkey; self.name = name; self.about = about; self.created = created; self.forMe = forMe
    }
}

public extension BelfryAPI {
    static let requestErrors = [
        "not_admin": "Only admins of the belfry can do this.",
        "not_here": "Only members of the belfry can do this.",
        "not_vouching": "Requests here are accepted by the admins.",
        "not_found": "This request is gone.",
        "decided": "Someone answered this request already.",
        "invalid": "That did not work. Try again.",
        "unsupported": "This belfry can’t keep requests yet.",
        "limit": "You have as many agents as you can have.",
    ]

    static func parseRequests(_ x: Any?) -> [BelfryRequest] {
        (x as? [[String: Any]] ?? []).compactMap { r in
            guard let id = int(r["id"]) else { return nil }
            return BelfryRequest(id: id, name: (r["name"] as? String ?? "").sliceUnits(100), motivation: (r["motivation"] as? String ?? "").sliceUnits(2000),
                                 created: r["created"] as? String ?? "", vouches: int(r["vouches"]) ?? 0, vouched: r["vouched"] as? Bool ?? false,
                                 email: r["email"] as? String)
        }
    }

    static func parseAgentRequests(_ x: Any?) -> [AgentRequest] {
        (x as? [[String: Any]] ?? []).compactMap { r in
            guard let id = int(r["id"]), let pk = r["pubkey"] as? String, isHex64(pk) else { return nil }
            return AgentRequest(id: id, pubkey: pk, name: (r["name"] as? String ?? "").sliceUnits(100), about: (r["about"] as? String ?? "").sliceUnits(500),
                                created: r["created"] as? String ?? "", forMe: r["for_me"] as? Bool ?? false)
        }
    }

    private func requestsCall(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let a = try await signed(base + path, method: "POST", json: body)
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.requestErrors, "That did not work. Try again.") }
        return b
    }

    /// People asking to join the belfry (admins; members while it accepts by vouches).
    func applications() async throws -> [BelfryRequest] { BelfryAPI.parseRequests(try await requestsCall("/applications", ["list": true])["applications"]) }
    func decideApplication(_ id: Int, approve: Bool) async throws { _ = try await requestsCall("/applications", ["decide": id, "approve": approve]) }
    /// Vouch (or take it back); true when they got in by it.
    func vouchApplication(_ id: Int, on: Bool) async throws -> Bool { try await requestsCall("/applications", ["vouch": id, "on": on])["accepted"] as? Bool ?? false }
    /// Agents asking to join (belfry admins).
    func agentRequests() async throws -> [AgentRequest] { BelfryAPI.parseAgentRequests(try await requestsCall("/agent-requests", ["list": true])["requests"]) }
    func decideAgentRequest(_ id: Int, approve: Bool) async throws { _ = try await requestsCall("/agent-requests", ["decide": id, "approve": approve]) }
    /// Ask Belfry to count a group's vouches at once (it also does every few minutes).
    func checkGroupRequests(_ channel: String) async { _ = try? await signed(base + "/group-requests/check", method: "POST", json: ["channel": channel]) }
}

// ---- branding (web src/core/branding.ts; Android SPEC 19.21) ----------------------------------

public extension BelfryAPI {
    static let brandingErrors = [
        "not_admin": "Only admins of the belfry can change its look.",
        "invalid": "A logo or cover must be an https address; colours like #1e40af.",
        "no_key": "This belfry has no key of its own yet.",
    ]

    /// The branding as the belfry has it now (`GET /branding`, no auth).
    func branding() async throws -> Branding {
        let a = try await plain(base + "/branding")
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.brandingErrors, "Could not read the branding.") }
        return Branding.clean(b)
    }

    /// An admin changes any of the fields ("" clears one); answers them as saved.
    func saveBranding(_ change: [String: String]) async throws -> Branding {
        let a = try await signed(base + "/branding", method: "POST", json: change)
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.brandingErrors, "The branding could not be saved just now.") }
        return Branding.clean(b)
    }
}


// ---- the members directory (whois {"directory": true}; web Directory.tsx, 8f0ccb8) -------------

public struct DirMember: Hashable, Sendable, Identifiable {
    public let pubkey: String
    public let name: String
    public let role: String?
    public let agents: [(pubkey: String, name: String)]
    public var id: String { pubkey }
    public init(pubkey: String, name: String, role: String?, agents: [(pubkey: String, name: String)]) {
        self.pubkey = pubkey; self.name = name; self.role = role; self.agents = agents
    }
    public static func == (a: DirMember, b: DirMember) -> Bool { a.pubkey == b.pubkey && a.name == b.name && a.role == b.role && a.agents.map(\.pubkey) == b.agents.map(\.pubkey) }
    public func hash(into h: inout Hasher) { h.combine(pubkey) }
}

public extension BelfryAPI {
    static func parseDirectory(_ b: [String: Any]) -> [DirMember] {
        let agents = b["agents"] as? [String: Any] ?? [:]
        let names = b["names"] as? [String: Any] ?? [:]
        return (b["members"] as? [[String: Any]] ?? []).compactMap { m in
            guard let pk = m["pubkey"] as? String, isHex64(pk) else { return nil }
            let mine = agents.compactMap { a, o -> (String, String)? in
                guard isHex64(a), o as? String == pk else { return nil }
                return (a, ((names[a] as? String) ?? "").sliceUnits(100))
            }.sorted { $0.0 < $1.0 }
            return DirMember(pubkey: pk, name: ((m["name"] as? String) ?? "").sliceUnits(100), role: m["role"] as? String, agents: mine.map { (pubkey: $0.0, name: $0.1) })
        }
    }

    /// Every member of the belfry, their own agents under them (members only).
    func directory() async throws -> [DirMember] {
        let a = try await signed(base + "/whois", method: "POST", json: ["directory": true])
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.whoisErrors, "The list could not be loaded.") }
        return BelfryAPI.parseDirectory(b)
    }
}
