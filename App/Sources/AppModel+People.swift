import BelfryCore
import Foundation
import Security
import SwiftUI
import UIKit

// People and joining (SPEC 19.4, 19.5, 19.15, 19.16): guest links (join as someone new, join
// with an account, save the account), profiles (name, about, picture, username, tags, place),
// the admin switch, a member's own agents, signed-in devices, sign-out that ends the session,
// follows, drop box links. Every server error comes back as a fixed message.

private final class Flag { var on = false }

extension AppModel {
    // ---- guest links ----------------------------------------------------------------------------

    /// A guest link opened (https://chat.<domain>/join/<token>): only its domain and token are kept.
    func handle(url: URL) {
        if handleTicketURL(url) { return }
        if let a = LoginLink.parse(url) { Task { await logIn(with: a) }; return }
        guard let (domain, token) = InviteLink.parse(url) else { return }
        pendingInvite = PendingInvite(domain: domain, token: token)
        // signed out: straight to the channel in guest mode (one loading screen, no name asked)
        if phase == .signedOut, pendingCode == nil, !inviteSignInFirst { inviteProblem = nil; openInvite(pendingInvite!) }
    }

    /// Someone signed in uses a guest link: their account gets the channel (no second account).
    func joinWithAccount(_ token: String) async -> String? {
        if engine?.localOnly == true { pendingInvite = nil; joinedChannel = generalId; return nil }
        do {
            let j = try await api.joinWithAccount(token: token)
            pendingInvite = nil
            // a saved guest who used a member link: a member now (SPEC 19.43)
            if j.member && derive.amGuest { becameMember() }
            joinedChannel = j.channel
            await refresh()
            return nil
        } catch let e as ApiError {
            return e.message
        } catch {
            return BelfryAPI.generic
        }
    }

    /// Am I a guest whose account has no e-mail yet ("save your account").
    var unsavedGuest: Bool {
        let joins = derive.guestJoinsOf(me)
        return !guestReading && !joins.isEmpty && joins.allSatisfy(\.unsaved)
    }

    // ---- guest links I make ---------------------------------------------------------------------

    func makeGuestLink(_ channel: String, people: Int, linkDays: Int, agent: Bool = false, role: String? = nil) async -> Result<GuestLink, ApiError> {
        if engine?.localOnly == true {
            let url = "https://chat.\(config.domain)/join/demo\(agent ? "agent" : "guest")link0123456789abcd"
            return .success(GuestLink(url: url, agentURL: agent ? "https://belfry.\(config.domain)/invite/demoagentlink0123456789.md" : nil,
                                      days: agent ? 0 : 30, people: people, linkDays: linkDays, expiresAt: nil, ownAgent: agent))
        }
        do { return .success(try await api.createGuestLink(channel: channel, people: people, linkDays: linkDays, agent: agent, role: role)) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    /// A link for CHANNEL that brings in WHO (invite sheet option C, docs/roles.md).
    func makeInvite(_ channel: String, who: JoinsAs, people: Int, linkDays: Int) async -> Result<GuestLink, ApiError> {
        if engine?.localOnly == true {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let kind: String
            switch who { case .guest: kind = "guest"; case .agent: kind = "agent"; case .member: kind = "member" }
            let token = "demo\(kind)\(people)x\(linkDays)" + String(repeating: "0", count: 12)
            return .success(GuestLink(url: "https://chat.\(config.domain)/join/\(token)", agentURL: "https://belfry.\(config.domain)/invite/\(token).md",
                                      days: 0, people: who.people(people), linkDays: linkDays, expiresAt: nil, ownAgent: who.isAgent))
        }
        do { return .success(try await api.createInvite(channel: channel, joinsAs: who, people: people, linkDays: linkDays)) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    /// The belfry's roles (who has which, the default), read again at most every 30 s.
    func loadRoles(force: Bool = false) async {
        if !force, let at = rolesAt, Date().timeIntervalSince(at) < 30 { return }
        rolesAt = Date()
        if engine?.localOnly == true {
            roles = RolesInfo(roles: [Role.builtins[0], Role(id: "host", label: "Host", description: "Opens the door on event days"), Role.builtins[1]],
                              defaultRole: Role.member, members: [Demo.signer("ana").pubkey: Role.admin, Demo.signer("dev").pubkey: "host"])
            return
        }
        if let r = try? await api.roles() { roles = r; engine?.db.set("roles", r) }
    }

    /// The belfry's membership settings (who invites members, how requests are accepted).
    func loadMembership() async {
        if engine?.localOnly == true { membership = MembershipSettings(admin: derive.isCommunityAdmin); return }
        if let m = try? await api.membership() { membership = m; engine?.db.set("membership", m) }
    }

    /// What the belfry has waiting for me: people asking to join (admins; members while vouching)
    /// and agents asking to join (admins). Group requests come from the relay (Derive).
    func loadRequests(force: Bool = false) async {
        if !force, let at = requestsAt, Date().timeIntervalSince(at) < 60 { return }
        requestsAt = Date()
        await loadMembership()
        let admin = derive.isCommunityAdmin
        if engine?.localOnly == true {
            if admin && !demoRequestsSeeded {
                demoRequestsSeeded = true
                var lou = BelfryRequest(id: 2, name: "Lou (neighbour)", motivation: "I live on Mill Street and I fix sewing machines and bikes.", created: "", vouches: 1, vouched: false, email: "lou@example.org")
                lou.kind = "guest"; lou.channels = ["general"]; lou.inviter = "Ana Silva"; lou.pubkey = Demo.signer("guest").pubkey; lou.since = "2026-11-15"
                belfryRequests = [lou, BelfryRequest(id: 1, name: "Nora Lindqvist", motivation: "I run the repair café on Thursdays and would like to bring it here. <b>not bold</b>", created: "", vouches: 1, vouched: false, email: "nora@example.org")]
                agentRequests = [AgentRequest(id: 7, pubkey: String(repeating: "b", count: 64), name: "Scout", about: "Sorts the bug reports in #issues.", created: "", forMe: true)]
            }
            return
        }
        // any member sees who asks to join and vouches (web 8f0ccb8), whatever the setting
        if admin || (!derive.amGuest && derive.agentOwner(me) == nil && !derive.isAgent(me)) {
            if let p = try? await api.applications() { belfryRequests = p }
        } else { belfryRequests = [] }
        if admin { if let a = try? await api.agentRequests() { agentRequests = a } } else { agentRequests = [] }
    }

    /// How many things wait for me (Requests' count, also on ☰).
    var requestCount: Int {
        let admin = derive.isCommunityAdmin
        return (admin ? agentRequests.count : 0) + belfryRequests.filter { admin || !$0.vouched }.count + derive.groupRequestCount()
    }

    /// Whether Requests shows at all: something waits, or I'm someone who decides things.
    var showRequests: Bool {
        requestCount > 0 || derive.isCommunityAdmin || groups.contains { $0.closed && $0.admins.contains(me) }
    }

    func decideApplication(_ id: Int, approve: Bool) async -> String? {
        if engine?.localOnly == true { belfryRequests.removeAll { $0.id == id }; return nil }
        defer { Task { await loadRequests(force: true) } }
        do { try await api.decideApplication(id, approve: approve); belfryRequests.removeAll { $0.id == id }; return nil }
        catch let e as ApiError { return e.message } catch { return BelfryAPI.network }
    }

    func vouchApplication(_ id: Int, on: Bool) async -> String? {
        if engine?.localOnly == true {
            belfryRequests = belfryRequests.map { $0.id == id ? BelfryRequest(id: $0.id, name: $0.name, motivation: $0.motivation, created: $0.created, vouches: max(0, $0.vouches + (on ? 1 : -1)), vouched: on, email: $0.email) : $0 }
            return nil
        }
        defer { Task { await loadRequests(force: true) } }
        do { _ = try await api.vouchApplication(id, on: on); return nil }
        catch let e as ApiError { return e.message } catch { return BelfryAPI.network }
    }

    func decideAgentRequest(_ id: Int, approve: Bool) async -> String? {
        if engine?.localOnly == true { agentRequests.removeAll { $0.id == id }; return nil }
        defer { Task { await loadRequests(force: true) } }
        do { try await api.decideAgentRequest(id, approve: approve); agentRequests.removeAll { $0.id == id }; return nil }
        catch let e as ApiError { return e.message } catch { return BelfryAPI.network }
    }

    /// Vouch in a group, then ask Belfry to count at once.
    func vouch(_ g: Channel, _ a: Application, on: Bool) {
        engine?.enqueue(Actions.vouch(g.id, requestId: a.id, applicant: a.pubkey, on: on))
        guard engine?.localOnly != true else { return }
        let api = self.api
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); await api.checkGroupRequests(g.id) }
    }

    /// May I make member links? (belfry admins; any member when the settings say so)
    var mayInviteMembers: Bool {
        let d = derive
        return d.isCommunityAdmin || (membership.mayInviteMembers && !d.amGuest && !d.isAgent(me))
    }

    // ---- profiles -------------------------------------------------------------------------------

    /// Name and about in my kind 0 (its other fields kept), and a new picture when given.
    func saveProfile(name: String, about: String, picture: Data?) async -> String? {
        var url: String?
        if let picture {
            guard let engine else { return "Not signed in." }
            if engine.localOnly {
                // the demo: an address of its own for the picture, held in the image cache
                url = "https://demo.belfry.sh/avatar-\(Crypto.sha256(picture).hex.prefix(16)).jpg"
            } else {
                do { url = try await engine.upload(picture, name: "avatar.jpg", mime: "image/jpeg", sha: Crypto.sha256(picture).hex) }
                catch { return "The picture could not be uploaded. Try again." }
            }
            // the new picture is on this phone already: every face shows it at once, no download
            if let url, let img = UIImage(data: picture) { ImageCache.shared.put(url, img) }
        }
        engine?.enqueue(Actions.saveProfile(current: derive.myProfileJSON, name: name, about: about, nip05: derive.profiles()[me]?.nip05, picture: url))
        return nil
    }

    /// My address here (username@domain); the belfry changes it and its nip05 in my profile.
    func setUsername(_ username: String) async -> String? {
        let u = username.jsTrim().lowercased()
        if u.isEmpty { return "A username is 1 to 30 lowercase letters, digits, dots, dashes or underscores." }
        if engine?.localOnly == true {
            engine?.enqueue(Actions.saveProfile(current: derive.myProfileJSON, name: realName(me), about: derive.aboutOf(me), nip05: u + "@" + config.domain))
            return nil
        }
        do {
            let n = try await api.setUsername(u)
            engine?.enqueue(Actions.saveProfile(current: derive.myProfileJSON, name: realName(me), about: derive.aboutOf(me), nip05: n))
            return nil
        } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    func saveExtras(tags: [String], share: Share, place: Place?) {
        engine?.enqueue(Actions.saveExtras(tags: tags, share: share, place: place))
    }

    func searchPlaces(_ q: String) async -> [Place] {
        if engine?.localOnly != false { return People.demoPlaces(q) }
        return (try? await api.searchPlaces(q))?.places ?? []
    }

    func addPlace(name: String, country: String, near: String) async -> Result<Place, ApiError> {
        if engine?.localOnly != false {
            let n = People.demoPlaces.first { $0.placeId == near }
            return .success(Place(country: country, id: "b:demo", name: name, lat: n?.lat, lon: n?.lon))
        }
        do { return .success(try await api.addPlace(name: name, country: country, nearId: near)) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    /// "Admin of the belfry" (belfry admins only); belfry.json is read again after.
    func setAdmin(_ pk: String, _ on: Bool) async -> String? {
        if let reason = derive.noAdminReason(pk), on { return reason }
        if engine?.localOnly != false {
            var c = config
            if on { if !c.admins.contains(pk) { c.admins.append(pk) } } else { c.admins.removeAll { $0 == pk } }
            config = c
            version += 1
            return nil
        }
        do {
            try await api.setAdmin(pk, admin: on)
            await revalidateConfig(force: true)
            return nil
        } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    // ---- a member's own agents ------------------------------------------------------------------

    func myAgents() async -> MyAgents? {
        if engine?.localOnly != false { return MyAgents(agents: [], limit: 1) }
        return try? await api.myAgents()
    }

    func setMyAgent(_ pk: String, mine: Bool) async -> String? {
        if engine?.localOnly != false {
            var c = config
            var a = c.agents
            if mine { a[pk] = me } else { a[pk] = nil }
            c.agentsMap = a
            config = c
            version += 1
            return nil
        }
        do {
            _ = try await api.setMyAgent(pk, mine: mine)
            await revalidateConfig(force: true)
            await askWhois([pk])
            return nil
        } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    /// "Make it my agent": a guest agent, I am a member (not a guest or an agent), I invited it or am an admin.
    func mayMakeMine(_ pk: String) -> Bool {
        let d = derive
        guard d.agentOwner(pk) == nil, d.isAgent(pk), d.isGuest(pk), !d.isGuest(me), !d.isAgent(me) else { return false }
        return d.isCommunityAdmin || d.guestJoinsOf(pk).contains { $0.by == me }
    }

    // ---- sessions and sign-out ------------------------------------------------------------------

    func sessions() async -> Result<[SessionInfo], ApiError> {
        if engine?.localOnly != false {
            return .success([SessionInfo(applicationName: "Belfry for iPhone", device: "iPhone", redirectOrigin: "sh.belfry.app://connect",
                                         bunkerPubkey: String(repeating: "0", count: 64), createdAt: "2026-11-01", lastActivity: "2026-11-11")])
        }
        do { return .success(try await api.sessions()) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    /// This device's session: the bunker URL's key.
    var mySessionKey: String? { session?.bunkerURL.flatMap(BunkerURL.init)?.remotePubkey }

    func endSession(_ pk: String) async -> String? {
        if engine?.localOnly != false { return nil }
        do { try await api.revokeSession(pk); return nil } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    /// Sign out: end this device's session on the belfry (best effort, 3 s), then wipe the phone.
    func signOutEverywhere() async {
        await removePushDevice()
        if let s = session, !s.demo, let pk = mySessionKey {
            let api = self.api
            let f = Flag()
            Task { try? await api.revokeSession(pk); await MainActor.run { f.on = true } }
            var waited = 0
            while !f.on && waited < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
        }
        signOut()
    }

    // ---- follows (e-mails of a channel's announcements) -----------------------------------------

    func follow(_ channel: String) async -> String? {
        if engine?.localOnly != false { return demoFollows[channel] }
        return (try? await api.follows())?.byChannel[channel]
    }

    /// CHOICE: asap | monthly | stop. Returns the frequency now in force (nil: not following) or an error.
    func setFollow(_ channel: String, _ choice: String) async -> Result<String?, ApiError> {
        if engine?.localOnly != false {
            demoFollows[channel] = choice == "stop" ? nil : choice
            return .success(demoFollows[channel])
        }
        do { return .success(try await api.setFollow(channel: channel, choice: choice)) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    // ---- drop box links -------------------------------------------------------------------------

    @discardableResult
    func createDropLink(_ group: String, days: Int, login: Bool) -> String {
        let (token, d) = Actions.createDropLink(group, days: days, login: login, now: .now)
        engine?.enqueue(d)
        return token
    }

    func endDropLink(_ l: DropLink) { engine?.enqueue(Actions.endDropLink(l)) }
}

/// A guest link waiting to be used (kept through sign-in; only its domain and token).
struct PendingInvite: Codable, Equatable, Identifiable {
    let domain: String
    let token: String
    var id: String { token }
}

extension Keychain {
    static func setString(_ value: String, _ account: String) {
        removeString(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".keys",
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func string(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".keys",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func removeString(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".keys", kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

enum Images {
    /// A picture as JPEG, at most MAX pixels on its longer side.
    static func jpeg(_ data: Data, max: CGFloat) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        let k = min(1, max / Swift.max(w, h))
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return out.jpegData(compressionQuality: 0.85)
    }
}
