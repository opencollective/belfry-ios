import BelfryCore
import Foundation

// Round 2 of the places (2026-11-16, the belfry's 9d03d4a): a guest's real request to become a
// member (POST /applications {"apply": …}), the charter for people who can't read its group
// (GET /charter, belfry.json `charter`), public events for guests (GET /events?visibility=public),
// and a new member's first minutes (web Charter.tsx welcomeDue). Everything is kept per account and
// drawn from the stored copy first (offline first).

extension AppModel {
    static func loadStored<T: Decodable>(_ type: T.Type, _ base: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: perAccount(base)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func store<T: Encodable>(_ v: T?, _ base: String) {
        if let v, let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: perAccount(base)) } else { UserDefaults.standard.removeObject(forKey: perAccount(base)) }
    }

    /// My request is waiting.
    var guestApplied: Bool { applyState?.application?.isOpen ?? false }

    // ---- a guest's request ---------------------------------------------------------------------

    func loadApplyStatus() async {
        guard engine?.localOnly == false, derive.amGuest || applyState?.application != nil else { return }
        do { setApply(try await api.applyStatus()) }
        catch let e as ApiError where e.code == "not_guest" {
            // a member already (a member link, or accepted meanwhile): no request to show (SPEC 19.43)
            if await memberAlready() { return }
        } catch {}
    }

    private func setApply(_ s: ApplyStatus) {
        applyState = s
        AppModel.store(s, "belfry-apply-status")
    }

    /// Send the request with the agreements ticked on the way. Nil = sent (or waiting already).
    func applyAsGuest(answer: String, agreed: [String]) async -> ApiError? {
        if engine?.localOnly != false {
            try? await Task.sleep(nanoseconds: 250_000_000)
            setApply(ApplyStatus(application: MyApplication(id: 1, state: "new", vouches: 1, needed: 2,
                                                            vouchedBy: [.init(pubkey: Demo.signer("dev").pubkey, name: "Dev Patel")]),
                                 until: Int.now + 7 * 86400, accept: "vouches"))
            return nil
        }
        // the form is for guests only: a member never sends it (SPEC 19.43)
        if !derive.amGuest && !guestReading { return nil }
        do { setApply(try await api.guestApply(answer: answer, agreed: agreed)); return nil }
        catch let e as ApiError {
            // "Only guests apply from here": I am a member already; refresh and go on, no error
            if e.code == "not_guest" {
                if await memberAlready() { return nil }
                // whois holds no pass for me: no longer a guest here (Android 19.39)
                return ApiError("gone", 409, BelfryAPI.applyErrors["gone"]!)
            }
            return e
        }
        catch { return ApiError("network", 0, BelfryAPI.network) }
    }

    // ---- the charter for those who can't read it -------------------------------------------------

    /// The agreements to show: the group's own when this phone reads it, else the public copy.
    var charterRules: [Agreement] {
        let d = derive
        if d.charterGroup != nil || !d.charter().isEmpty { return d.charter() }
        return publicCharter.map(\.agreement).sorted { a, b in a.order != b.order ? a.order < b.order : a.addedAt < b.addedAt }
    }

    /// Whether the belfry has a charter (the group here, or belfry.json says so).
    var hasCharter: Bool { !charterRules.isEmpty || config.charter == true }

    func loadPublicCharter() async {
        let d = derive
        guard d.charterGroup == nil, config.charter != false, engine?.localOnly == false else { return }
        if let list = try? await api.publicCharter() {
            publicCharter = list
            AppModel.store(list, "belfry-public-charter")
        }
    }

    // ---- public events for guests --------------------------------------------------------------

    /// The public events this phone holds (from the stored answer), in the app's shape.
    var publicEvents: [CalEvent] {
        guard let data = publicEventsRaw, let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { BelfryAPI.parseEvent($0)?.calEvent(timeZone: .current, me: me) }
    }

    func loadPublicEvents() async {
        guard engine?.localOnly == false else { return }
        guard let list = try? await api.publicEvents(from: Int.now - 86400),
              let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        publicEventsRaw = data
        UserDefaults.standard.set(data, forKey: AppModel.perAccount("belfry-public-events"))
    }

    // ---- a new member's first minutes ----------------------------------------------------------

    /// This device made the account through a link: the welcome may come once they are a member.
    func markNewAccount() { UserDefaults.standard.set("new", forKey: AppModel.perAccount("belfry-welcome")) }

    /// Web welcomeDue: on a device that saw the account made through a link or saw its guest become
    /// a member, a charter exists, the person never ticked an agreement; not an agent, not a steward.
    func welcomeDue() -> Bool {
        let d = derive
        let ud = UserDefaults.standard
        let k = AppModel.perAccount("belfry-welcome"), wk = AppModel.perAccount("belfry-was-guest")
        if ["welcome", "welcomecharter", "welcomeprofile"].contains(launch.screen ?? "") { return ud.string(forKey: k) != "done:" + me }
        guard !me.isEmpty, !isDemo else { return false }
        if d.amGuest || guestReading { ud.set(me, forKey: wk); return false }
        var v = ud.string(forKey: k) ?? ""
        if ud.string(forKey: wk) == me && v != "done:" + me {
            ud.removeObject(forKey: wk)
            ud.set("new", forKey: k)
            v = "new"
        }
        guard v == "new", d.agentOwner(me) == nil, !d.isBelfryAdmin(me) else { return false }
        guard !charterRules.isEmpty else { return false }
        let listId = Derive.listIdFor(Derive.charterId)
        let ticked = d.events.contains { $0.kind == 2101 && $0.pubkey == me && $0.tag("h") == Derive.charterId && $0.tag("t") == listId }
        return !ticked
    }

    func welcomeDone() {
        UserDefaults.standard.set("done:" + me, forKey: AppModel.perAccount("belfry-welcome"))
        welcomeShown = false
    }

    /// Who let me in: the newest 9000 putting me somewhere with `invited-by`.
    var welcomeInviter: String? {
        derive.events.filter { $0.kind == 9000 && $0.tags.contains { $0.count > 1 && $0[0] == "p" && $0[1] == me } && $0.tag("invited-by") != nil }
            .max { $0.createdAt < $1.createdAt }?.tag("invited-by")
    }
}
