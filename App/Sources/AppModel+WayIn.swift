import BelfryCore
import Foundation

// The way in (SPEC 19.59): the calls of a belfry's Log in and Apply to join, each signed (NIP-98)
// by this phone's applicant key for that belfry. The key is made here and kept in the Keychain,
// so a request that waits is still this phone's after the app was closed. A session is bound to
// it: once signed in, the key is that session's own.

extension AppModel {
    private static func wayInKeyName(_ domain: String) -> String { "belfry-applicant:" + domain.lowercased() }
    /// The belfry a request of this phone waits at (not a secret).
    static let wayInPendingKey = "belfry-way-in-pending"

    /// This phone's applicant key for the belfry (made the first time).
    func wayInKey(_ domain: String) -> LocalSigner? {
        let vault = KeychainVault()
        if let hex = vault.get(AppModel.wayInKeyName(domain)), let d = Data(hex: hex), let s = try? LocalSigner(secret: d) { return s }
        let secret = Keys.generateSecret()
        guard let s = try? LocalSigner(secret: secret) else { return nil }
        vault.set(AppModel.wayInKeyName(domain), secret.hex)
        return s
    }

    /// A new key for the next try (the belfry said this one is linked to another account).
    func resetWayInKey(_ domain: String) { KeychainVault().remove(AppModel.wayInKeyName(domain)) }

    /// One call of the way in, as the screen to show next.
    func wayIn(_ call: WayIn.Call, _ c: BelfryConfig, _ body: [String: Any]) async -> WayInAnswer {
        guard let key = wayInKey(c.domain) else { return WayInAnswer(.stay, message: WayIn.words["other"]) }
        do {
            let a = try await BelfryAPI(config: c, signer: key).signed(c.apiBase + "/" + call.rawValue, method: "POST", json: body)
            let answer = WayIn.answer(call, status: a.status, body: a.body, domain: c.domain)
            if a.error == "key_taken" { resetWayInKey(c.domain) }
            return answer
        } catch let e as ApiError where e.code == "network" {
            return WayInAnswer(.stay, message: WayIn.words["network"])
        } catch { return WayInAnswer(.stay, message: WayIn.words["other"]) }
    }

    /// `POST /username/check`, by the applicant key (signed out) or by my own (a new member).
    func usernameCheck(_ c: BelfryConfig, _ body: [String: Any], mine: Bool = false) async -> [String: Any]? {
        let signer: Signer? = mine ? engine?.signer : wayInKey(c.domain)
        guard let signer, let a = try? await BelfryAPI(config: c, signer: signer).signed(c.apiBase + "/username/check", method: "POST", json: body), a.ok else { return nil }
        return a.body
    }

    /// Signed in through the way in: the session is on the account's signer, bound to the
    /// applicant key, which becomes this session's own key.
    func wayInSignedIn(_ s: GuestSignedIn, _ c: BelfryConfig, said address: String) {
        guard let key = wayInKey(c.domain) else { return }
        let st = StoredSession(domain: c.domain, bunkerURL: s.bunkerURL, clientSecret: key.secret.hex, pubkey: s.pubkey)
        resetWayInKey(c.domain)
        UserDefaults.standard.removeObject(forKey: AppModel.wayInPendingKey)
        store(st)
        pendingCode = nil
        signInError = nil
        signInNote = nil
        open(st, config: c)
        showToast("Signed in as \(s.nip05 ?? address)")
    }

    func wayInPending(_ c: BelfryConfig?) {
        if let c { UserDefaults.standard.set(c.domain, forKey: AppModel.wayInPendingKey) }
        else { UserDefaults.standard.removeObject(forKey: AppModel.wayInPendingKey) }
    }

    /// A new member's name and username (`POST /welcome`, by my own key). Nil = set.
    func setNameAndUsername(name: String, username: String) async -> WayInAnswer {
        guard let signer = engine?.signer, engine?.localOnly == false else { return WayInAnswer(.signedIn) }
        do {
            let a = try await BelfryAPI(config: config, signer: signer).signed(config.apiBase + "/welcome", method: "POST",
                                                                                 json: WayIn.welcomeBody(name: name, username: username))
            let answer = WayIn.answer(.welcome, status: a.status, body: a.body, domain: config.domain)
            if answer.screen == .signedIn { await refresh() }
            return answer
        } catch { return WayInAnswer(.stay, message: WayIn.words["network"]) }
    }
}
