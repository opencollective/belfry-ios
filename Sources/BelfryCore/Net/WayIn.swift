import Foundation

// The way in (SPEC 19.59; collective-belfry docs/membership.md "Applying from the chat (verified)"
// and "A name and a username"; vectors/way-in.json): a belfry's start screen is Log in and a
// smaller Apply to join. The phone makes a key, the applicant key, and signs every call below with
// it (NIP-98). A 6-digit code mailed to an address is the only proof of that address; a session
// is only ever bound to the key that signed the request.

/// The screen an answer leads to.
public enum WayInScreen: String, Sendable {
    /// A code was mailed: the six boxes.
    case code
    /// A session on the account, bound to the applicant key: stored like any sign-in.
    case signedIn = "signed_in"
    /// "Your request is pending".
    case pending
    /// The address is confirmed but nobody's here: "No account here yet" → Apply to join (with the proof).
    case unknown
    /// "Not this time".
    case declined
    /// No request of this key: the belfry's start screen.
    case start
    /// Approved, and the session was handed out already: Log in, the address filled in.
    case logIn = "log_in"
    /// The account holds its own key: the older sign-in with its address.
    case signInInstead = "sign_in_instead"
    /// The proof was refused or is too old: ask the same again without it (a code is mailed).
    case withoutProof = "without_proof"
    /// A refusal shown on the screen that asked.
    case stay
    /// This belfry doesn't have these calls: the older way (the native sign-in, the unproven form).
    case older
}

public struct WayInAnswer: Equatable, Sendable {
    public var screen: WayInScreen
    /// Fixed words for a refusal (never the server's own text).
    public var message: String?
    public var session: GuestSignedIn?
    /// `/login/verify` → unknown: goes back with `/apply/start`.
    public var proof: String?
    /// The account's address here, when the answer names one.
    public var nip05: String?
    /// What they sent, shown back on the pending screen.
    public var pending: Pending?
    /// For a taken username.
    public var suggestions: [String] = []
    /// The digits typed are of no use any more.
    public var clearsCode = false

    public struct Pending: Equatable, Sendable, Codable {
        public var name = "", username = "", email = "", motivation = ""
        public init(name: String = "", username: String = "", email: String = "", motivation: String = "") {
            self.name = name; self.username = username; self.email = email; self.motivation = motivation
        }
    }

    public init(_ screen: WayInScreen, message: String? = nil) { self.screen = screen; self.message = message }
}

public enum WayIn {
    public enum Call: String, Sendable {
        case loginStart = "login/start", loginVerify = "login/verify"
        case applyStart = "apply/start", applyVerify = "apply/verify", applyStatus = "apply/status"
        case welcome
    }

    public static let words: [String: String] = [
        "expired": "That code has expired. Send a new one.",
        "too_many": "Too many codes for now. Try again in half an hour.",
        "invalid": "That doesn’t look like an e-mail address.",
        "missing": "Please give your name and a few words on why you would like to join.",
        "unticked": "Please tick each agreement of the charter: joining means agreeing to them.",
        "username_invalid": "Use lowercase letters, digits and dashes, 3 to 30 characters.",
        "username_reserved": "That name is kept for the belfry.",
        "username_taken": "This username is taken.",
        "key_taken": "That did not work. Send a new code and try again.",
        "signer": "The belfry’s signer is not answering. Send a new code and try again.",
        "not_member": "Only members pick a username here.",
        "unverified": "Confirm your e-mail first.",
        "own_key": "You hold your own key: your username is set where your key lives.",
        "already_set": "Your username is set already. You change it from your profile.",
        "network": "No connection to the belfry. Try again.",
        "other": "That did not work. Try again.",
    ]

    public static func wrongCode(_ triesLeft: Int?) -> String {
        guard let n = triesLeft else { return "That code is not right." }
        if n <= 0 { return "That code is not right. Send a new one." }
        return n == 1 ? "That code is not right. 1 try left." : "That code is not right. \(n) tries left."
    }

    // ---- what is sent ---------------------------------------------------------------------------

    public static func loginBody(email: String) -> [String: Any] { ["email": email.jsTrim().lowercased()] }
    public static func codeBody(email: String, code: String) -> [String: Any] { ["email": email.jsTrim().lowercased(), "code": code.jsTrim()] }

    /// `/apply/start`: the name cleaned, the username lower-cased, every agreement's id, the proof
    /// when the address was confirmed by logging in just before.
    public static func applyBody(email: String, motivation: String, name: String, username: String, agreed: [String], proof: String?) -> [String: Any] {
        var b: [String: Any] = ["email": email.jsTrim().lowercased(), "motivation": String(motivation.jsTrim().prefix(4000)),
                                "name": GuestJoinForm.cleanName(name), "agreed": agreed]
        let u = username.jsTrim().lowercased()
        if !u.isEmpty { b["username"] = u }
        if let proof, !proof.isEmpty { b["proof"] = proof }
        return b
    }

    public static func welcomeBody(name: String, username: String) -> [String: Any] {
        ["name": GuestJoinForm.cleanName(name), "username": username.jsTrim().lowercased()]
    }

    // ---- what comes back ------------------------------------------------------------------------

    /// The answer of CALL as the screen to show. Only fixed shapes are read; anything else is a
    /// refusal in fixed words.
    public static func answer(_ call: Call, status: Int, body b: [String: Any]?, domain: String) -> WayInAnswer {
        let error = b?["error"] as? String ?? ""
        if (200...299).contains(status) {
            switch call {
            case .loginStart: return WayInAnswer(.code)
            case .applyStart where b?["state"] == nil: return WayInAnswer(.code)
            case .welcome:
                var a = WayInAnswer(.signedIn)
                a.nip05 = GuestJoinForm.signInAddress(nip05: b?["nip05"] as? String, typed: "", domain: domain)
                return a
            default: break
            }
            switch b?["state"] as? String {
            case "signed_in": return signedIn(b, domain)
            case "pending":
                var a = WayInAnswer(.pending)
                a.pending = pending(b)
                return a
            case "unknown" where call == .loginVerify:
                guard let p = b?["proof"] as? String, !p.isEmpty, p.count <= 400 else { return WayInAnswer(.stay, message: words["other"]) }
                var a = WayInAnswer(.unknown)
                a.proof = p
                return a
            case "none" where call == .applyStatus: return WayInAnswer(.start)
            case "declined" where call == .applyStatus: return WayInAnswer(.declined)
            case "approved" where call == .applyStatus:
                if b?["signed_in"] as? Bool == true { return signedIn(b, domain) }
                var a = WayInAnswer(.logIn)
                a.nip05 = GuestJoinForm.signInAddress(nip05: b?["nip05"] as? String, typed: "", domain: domain)
                return a
            default:
                // the status is asked on its own (when the app opens, every 5 s): a state we don't
                // know reads as none, never as an error on a screen that asked nothing
                return call == .applyStatus ? WayInAnswer(.start) : WayInAnswer(.stay, message: words["other"])
            }
        }
        // nothing for this person to pick (set already, their own key, not a member): the chat
        if call == .welcome, ["already_set", "own_key", "not_member", "unverified"].contains(error) { return WayInAnswer(.signedIn) }
        // a belfry without these calls (or without its own register): the older way
        if error == "unsupported" || ((status == 404 || status == 405) && error.isEmpty) { return WayInAnswer(.older) }
        switch error {
        case "wrong_code":
            let n = (b?["tries_left"] as? NSNumber).map { min(max($0.intValue, 0), 9) }
            var a = WayInAnswer(.stay, message: wrongCode(n))
            a.clearsCode = true
            return a
        case "expired", "key_taken", "signer":
            var a = WayInAnswer(.stay, message: words[error])
            a.clearsCode = true
            return a
        case "taken":
            var a = WayInAnswer(.signInInstead)
            a.nip05 = GuestJoinForm.signInAddress(nip05: b?["nip05"] as? String, typed: "", domain: domain)
            return a
        case "proof": return WayInAnswer(.withoutProof)
        case "username_invalid":
            return WayInAnswer(.stay, message: words[b?["reason"] as? String == "reserved" ? "username_reserved" : "username_invalid"])
        case "username_taken":
            var a = WayInAnswer(.stay, message: words["username_taken"])
            a.suggestions = suggestions(b?["suggestions"])
            return a
        case "too_many", "invalid", "missing", "unticked", "not_member", "unverified", "own_key", "already_set":
            return WayInAnswer(.stay, message: words[error])
        default: return WayInAnswer(.stay, message: words["other"])
        }
    }

    static func signedIn(_ b: [String: Any]?, _ domain: String) -> WayInAnswer {
        // the same shape and the same checks as the guest's sign-in by code (SPEC 19.55)
        var shaped = b ?? [:]
        shaped["signed_in"] = true
        guard let s = GuestSignIn.signedIn(shaped, domain: domain) else { return WayInAnswer(.stay, message: words["other"]) }
        var a = WayInAnswer(.signedIn)
        a.session = s
        a.nip05 = s.nip05
        return a
    }

    static func pending(_ b: [String: Any]?) -> WayInAnswer.Pending {
        func s(_ k: String, _ n: Int) -> String { String((b?[k] as? String ?? "").prefix(n)) }
        return WayInAnswer.Pending(name: s("name", 100), username: LoginLink.isUsername(s("username", 30)) ? s("username", 30) : "",
                                   email: s("email", 200), motivation: s("motivation", 4000))
    }

    static func suggestions(_ v: Any?) -> [String] {
        Array((v as? [Any] ?? []).compactMap { $0 as? String }.filter(LoginLink.isUsername).prefix(3))
    }
}

/// `POST /username/check`: the line under "Pick a username:".
public struct UsernameCheck: Equatable, Sendable {
    public enum State: String, Sendable { case available, taken, invalid }
    public var username: String
    public var state: State
    public var reason: String?
    public var suggestions: [String]

    public init(username: String, state: State, reason: String? = nil, suggestions: [String] = []) {
        self.username = username; self.state = state; self.reason = reason; self.suggestions = suggestions
    }

    /// From `{"username", "state", "reason"?, "suggestions"}`; nil for anything else.
    public static func parse(_ b: [String: Any]?) -> UsernameCheck? {
        guard let b, let u = b["username"] as? String, let st = (b["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        return UsernameCheck(username: String(u.prefix(60)), state: st, reason: b["reason"] as? String, suggestions: WayIn.suggestions(b["suggestions"]))
    }

    /// From `{"suggested", "suggestions"}` (a name alone was asked): the username to fill in.
    public static func suggested(_ b: [String: Any]?) -> String? {
        guard let s = b?["suggested"] as? String, LoginLink.isUsername(s) else { return nil }
        return s
    }

    /// "lina@riverside.example is available" · "Taken. Try lina-moreau" · the rule.
    public func line(domain: String) -> String {
        switch state {
        case .available: return "\(username)@\(domain) is available"
        case .taken: return suggestions.first.map { "Taken. Try \($0)" } ?? "Taken. Try another one."
        case .invalid:
            if reason == "reserved" { return WayIn.words["username_reserved"]! + (suggestions.first.map { " Try \($0)" } ?? "") }
            return WayIn.words["username_invalid"]!
        }
    }
}
