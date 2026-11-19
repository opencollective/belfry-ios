import BelfryCore
import Foundation

// The native sign-in (SPEC 19.20) as the screens call it. The flow itself, its checks and what it
// keeps across the app being killed are BelfryCore's `NativeSignInFlow`; here its result becomes
// the stored session. Errors come back as `SessionError`: fixed messages, never the belfry's text.

extension AppModel {
    /// Screen 1 → the belfry mails a code → screen 2 (`pendingCode`).
    func requestCode(_ address: String) async -> SessionError? {
        signInError = nil
        do {
            pendingCode = try await nativeFlow.requestCode(address)
            return nil
        } catch let e as SessionError {
            return e
        } catch {
            return SessionError(.other)
        }
    }

    /// "Send a new code": the same request, the same session key.
    func resendCode() async -> SessionError? {
        do {
            pendingCode = try await nativeFlow.resendCode()
            return nil
        } catch let e as SessionError {
            if e.failure.endsTheRequest { backToAddress(e) }
            return e
        } catch {
            return SessionError(.other)
        }
    }

    /// Screen 2: the six digits. On success the session is stored and opened.
    func verifyCode(_ code: String) async -> SessionError? {
        do {
            let opened = try await nativeFlow.verifyCode(code)
            let s = StoredSession(domain: opened.config.domain, bunkerURL: opened.bunkerURL, clientSecret: opened.clientSecretHex, pubkey: opened.pubkey)
            store(s)
            pendingCode = nil
            loginLink = nil
            signInError = nil
            signInNote = nil
            open(s, config: opened.config)
            return nil
        } catch let e as SessionError {
            if e.failure.endsTheRequest { backToAddress(e) }
            return e
        } catch {
            return SessionError(.other)
        }
    }

    /// "Use another address": forget the request; the address stays in the field.
    func cancelCode() {
        loginLink = nil
        nativeFlow.cancel()
        signInError = nil
        pendingCode = nil
    }

    /// The request is over (expired, this phone's key is taken…): screen 1 with the reason.
    private func backToAddress(_ e: SessionError) {
        nativeFlow.cancel()
        signInError = e.display
        pendingCode = nil
        loginLink = nil
    }

    /// "Link your phone" (SPEC 19.56): a login link was scanned or opened. An account of that
    /// address already on this phone is switched to, no code; else the ordinary e-mail-code
    /// sign-in starts at once for it (a belfry this phone doesn't have yet is added that way),
    /// and the code screen says whose code to confirm.
    func logIn(with a: MemberAddress) async {
        let address = a.description
        if let have = accounts.accounts.first(where: { !$0.guest && $0.domain == a.domain && $0.address.lowercased() == address }) {
            if phase == .ready, !isDemo, have.slot == Keychain.slot { showToast("You’re logged in as \(address)"); return }
            switchAccount(have.slot)
            return
        }
        guard !busy, pendingCode == nil else { return }
        if phase == .ready { startAddingAccount() }
        pendingInvite = nil
        signInError = nil
        signInNote = nil
        UserDefaults.standard.set(address, forKey: "last-address")
        busy = true
        defer { busy = false }
        // the community's name for the screen, from its own belfry.json (as for a typed domain)
        loginLink = LoginLinkState(address: address, community: (try? await Discovery.fetch(domain: a.domain))?.name ?? a.domain)
        if let e = await requestCode(address) {
            loginLink = nil
            signInError = e.display
        }
    }
}

/// A login link being used: whose code the code screen asks to confirm.
struct LoginLinkState: Equatable {
    let address: String
    let community: String
}
