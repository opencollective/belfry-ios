import Foundation

// Guest mode (SPEC 19.26; collective-belfry docs/guests.md, web village-app b2e968b
// core/guestmode.ts + core/guestjoin.ts). Someone who opened a guest link without an account
// reads its channel at once, with no name. Nothing they do is sent until they join (a name, an
// e-mail and the 6-digit code mailed to it). The relay does not enforce this: the app does, at the
// places everything goes through (the outbox, signed HTTP calls, direct messages), and each
// refusal opens the Join sheet.

/// Something that writes was refused because this device is only reading as a guest.
public struct GuestModeRefused: Error, Equatable, LocalizedError {
    public init() {}
    public static let message = "Join to do this: you are reading as a guest."
    public var errorDescription: String? { GuestModeRefused.message }
}

/// The switch every write checks. `reading` is set by the app from the stored session; `onRefused`
/// opens the Join sheet (called on any thread).
public final class GuestModeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var topic: String?
    public var onRefused: (() -> Void)?

    /// The topic this guest reached through a printed card (docs/cards.md §3, `"card": "topic"`):
    /// while reading they may post a plain message with photos there, and nothing else.
    public var cardTopic: String? {
        get { lock.lock(); defer { lock.unlock() }; return topic }
        set { lock.lock(); topic = newValue; lock.unlock() }
    }

    /// True (and the Join sheet asked for) when this event must not go out: anything while
    /// reading, but the approved post in the card's topic (`Cards.guestTopicPost`).
    @discardableResult
    public func refuse(kind: Int, tags: [[String]], fileTypes: [String]) -> Bool {
        guard reading else { return false }
        if Cards.guestTopicPost(kind: kind, tags: tags, topic: cardTopic, fileTypes: fileTypes) { return false }
        onRefused?()
        return true
    }

    /// Throws for an upload while reading, but a picture for the card's topic.
    public func checkUpload(mime: String) throws {
        guard reading else { return }
        if cardTopic != nil, mime.lowercased().hasPrefix("image/") { return }
        onRefused?()
        throw GuestModeRefused()
    }

    public init(reading: Bool = false) { on = reading }

    public var reading: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }

    /// True (and the Join sheet asked for) when a write must not go out.
    @discardableResult
    public func refuse() -> Bool {
        guard reading else { return false }
        onRefused?()
        return true
    }

    /// Throws for any write while reading.
    public func check() throws {
        if refuse() { throw GuestModeRefused() }
    }

    /// Throws for an HTTP call that writes while reading (reads and joining itself pass).
    public func check(url: String, method: String) throws {
        guard reading, !GuestModeGate.allowsWhileReading(url: url, method: method) else { return }
        onRefused?()
        throw GuestModeRefused()
    }

    /// What the belfry may be asked while reading: any GET; joining itself (`/guest/save`,
    /// `/guest/save/verify`), using a link (`/channel-invites/<token>/join`), ending this session
    /// (`/me/sessions/revoke`) and asking who people are (`/whois`, a read sent as a POST).
    public static func allowsWhileReading(url: String, method: String) -> Bool {
        if method.uppercased() == "GET" { return true }
        let path = URL(string: url)?.path ?? ""
        return allowedPath.test(path)
    }

    static let allowedPath = Rx("/(guest/save(/verify)?|me/sessions/revoke|channel-invites/[^/]+/join|whois)$")
}

/// What joining from guest mode can answer (`POST /guest/save`, `/guest/save/verify`), by the
/// server's `error` code. The messages are this app's own fixed words (web JOIN_ERRORS).
public enum GuestJoinError: String, Error, CaseIterable, Sendable {
    case invalid, nameNeeded = "name_needed", tooMany = "too_many", wrongCode = "wrong_code", expired, taken
    case notGuest = "not_guest", offline, failed
    /// Signing in with the code (SPEC 19.55): the new session key is linked to another account /
    /// the belfry's signer did not answer. Both need a new code.
    case keyTaken = "key_taken", signer

    public var message: String {
        switch self {
        case .invalid: return "That doesn’t look like an e-mail address."
        case .nameNeeded: return "Your name is needed to join."
        case .tooMany: return "Too many codes for now. Try again in half an hour."
        case .wrongCode: return "That code is not right. Check the e-mail and try again."
        case .expired: return "That code has expired. Send a new one."
        case .taken: return "This address already has an account here."
        case .keyTaken: return "That did not work. Send a new code and try again."
        case .signer: return "The belfry’s signer is not answering. Send a new code and try again."
        case .notGuest: return "This guest access has ended. Ask for a new invite."
        case .offline: return "No connection. Try again."
        case .failed: return "That did not work. Try again."
        }
    }

    /// The server's code (unknown codes: `failed`).
    public init(code: String) { self = GuestJoinError(rawValue: code) ?? .failed }
}

/// A refusal of `/guest/save` or `/guest/save/verify`. `moved`: with `taken`, the belfry gave the
/// address's account the channel and closed this guest (sign in with the address).
public struct GuestJoinFailure: Error, Equatable, LocalizedError {
    public let error: GuestJoinError
    public let moved: Bool
    /// `wrong_code`: how many tries the code has left (collective-belfry d2b4c52).
    public let triesLeft: Int?
    /// `taken`: that account's address here (`name@domain`), when the belfry could read it.
    public let nip05: String?
    public init(_ error: GuestJoinError, moved: Bool = false, triesLeft: Int? = nil, nip05: String? = nil) {
        self.error = error; self.moved = moved; self.triesLeft = triesLeft; self.nip05 = nip05
    }
    public var errorDescription: String? { display }

    /// The text to show: a wrong code says how many tries are left (as the native sign-in does).
    public var display: String {
        guard error == .wrongCode, let n = triesLeft else { return error.message }
        if n <= 0 { return "That code is not right. Ask for a new one." }
        if n == 1 { return "That code is not right. 1 try left." }
        return "That code is not right. \(n) tries left."
    }
}

public enum GuestJoinForm {
    /// A name as it is sent: trimmed, inner spaces folded, at most 100 UTF-16 units (web `clean`).
    public static func cleanName(_ name: String) -> String {
        Rx("\\s+").replace(name.jsTrim(), with: " ").sliceUnits(100)
    }

    /// The e-mail field is worth sending (web: /^\S+@\S+\.\S+$/ on the trimmed text).
    public static func looksLikeEmail(_ s: String) -> Bool { Rx("^\\S+@\\S+\\.\\S+$").test(s.jsTrim()) }

    /// The address to put in the native sign-in after "Sign in instead" (SPEC 19.26): the
    /// belfry's `nip05` for that account when it is name@DOMAIN, else the typed e-mail when it is
    /// such an address, else nil (the field stays empty, with a fixed hint).
    public static func signInAddress(nip05: String?, typed: String, domain: String) -> String? {
        let d = domain.lowercased()
        for c in [nip05, typed] {
            guard let a = c?.jsTrim().lowercased(), !a.isEmpty else { continue }
            let parts = a.split(separator: "@", omittingEmptySubsequences: false)
            if parts.count == 2, parts[1] == Substring(d), Rx("^[a-z0-9._-]{1,64}$").test(String(parts[0])) { return a }
        }
        return nil
    }

    /// What the Join sheet's first step needs before Continue unlocks.
    public static func canContinue(name: String, email: String, askName: Bool) -> Bool {
        (!askName || !cleanName(name).isEmpty) && looksLikeEmail(email)
    }
}

// ---- the code step after a failure (#issues 2026-11-13; web village-app 8cd92ac + guestjoin.ts
// savedOnRelay, Android 2385da4) ------------------------------------------------------------------

extension GuestJoinError {
    /// The code itself was refused: the boxes are cleared. Anything else (no connection, a timeout,
    /// a 5xx or 429, …) keeps the digits and offers "Try again".
    public var clearsCode: Bool { self == .wrongCode || self == .expired || self == .keyTaken || self == .signer }

    /// An attempt that failed like this may have reached the belfry (and used the code there):
    /// its answer was lost, or the belfry broke after saving.
    public var mayHaveReached: Bool { self == .offline || self == .failed }

    /// After such an attempt, these answers to a manual "Try again" may only mean the first one
    /// worked: look whether the save happened before saying so.
    public var mayMeanSavedAlready: Bool { self == .expired || self == .wrongCode || self == .notGuest }
}

public enum GuestJoinSaved {
    /// How long to look for the save on the relay (one look a second).
    public static let looks = 6

    /// Did the belfry save ME in CHANNEL (nil: in any channel) since SINCE: its label (kind 1985
    /// `belfry/guest`, `l` saved or member, `p` me), or the join with a name (kind 9000 for me
    /// with `name` and without `reading`)? Web `savedOnRelay`.
    public static func saved(in events: [NostrEvent], me: String, channel: String?, since: Int) -> Bool {
        events.contains { e in
            guard e.createdAt >= since,
                  e.tags.contains(where: { $0.count > 1 && $0[0] == "h" && !$0[1].isEmpty && (channel == nil || $0[1] == channel) }),
                  e.tags.contains(where: { $0.count > 1 && $0[0] == "p" && $0[1] == me }) else { return false }
            if e.kind == 1985 {
                return e.tags.contains(where: { $0.count > 1 && $0[0] == "L" && $0[1] == Derive.guestNS })
                    && e.tags.contains(where: { $0.count > 1 && $0[0] == "l" && ($0[1] == "saved" || $0[1] == "member") })
            }
            if e.kind == 9000 {
                return e.tags.contains(where: { $0.first == "name" }) && !e.tags.contains(where: { $0.first == "reading" })
            }
            return false
        }
    }
}

// ---- an address that has an account: the right code signs you in (SPEC 19.55; collective-belfry
// docs/guests.md; vectors/guest-signin.json) -----------------------------------------------------

/// The member's session the belfry opened for the new session key.
public struct GuestSignedIn: Hashable, Sendable {
    public let bunkerURL: String
    public let pubkey: String
    /// That account's address here, only when it is name@<this belfry's domain>.
    public let nip05: String?
    /// The account got the guest's channel and the anonymous guest pass is closed.
    public let moved: Bool
    /// The channel to open next (nil: home).
    public let channel: String?

    /// "Signed in as <address>": the account's address here, else the e-mail typed.
    public func address(typed: String) -> String { nip05 ?? typed.jsTrim() }
}

public enum GuestSignIn {
    /// What the app does after an answer of `/guest/save/verify` sent with a session key.
    public enum Next: String, Sendable {
        case signedIn = "signed_in", saved, signInInstead = "sign_in_instead", sameCode = "same_code"
        case newKeyNewCode = "new_key_new_code", newCode = "new_code"
        case wrongCode = "wrong_code", expired, tooMany = "too_many", notGuest = "not_guest", failed
    }

    /// The body of the verify call: e-mail and code trimmed, the name only when asked for, the
    /// NEW session key's public key and this app's id.
    public static func body(email: String, code: String, name: String?, sessionKey: String, client: String = "belfry-ios") -> [String: Any] {
        var b: [String: Any] = ["email": email.jsTrim(), "code": code.jsTrim(), "session_key": sessionKey.lowercased(), "client": client]
        if let name { b["name"] = GuestJoinForm.cleanName(name) }
        return b
    }

    /// The session of a `200 {"signed_in": true, …}`; nil when it is not one that can be stored.
    public static func signedIn(_ b: [String: Any]?, domain: String) -> GuestSignedIn? {
        guard let b, b["signed_in"] as? Bool == true, let bunker = b["bunker_url"] as? String, bunker.count <= 2000, BunkerURL(bunker) != nil,
              let pk = (b["pubkey"] as? String)?.lowercased(), isHex64(pk) else { return nil }
        let nip05 = GuestJoinForm.signInAddress(nip05: b["nip05"] as? String, typed: "", domain: domain)
        let ch = (b["channel"] as? String).flatMap { $0.isEmpty || $0.count > 120 ? nil : $0 }
        return GuestSignedIn(bunkerURL: bunker, pubkey: pk, nip05: nip05, moved: b["moved"] as? Bool == true, channel: ch)
    }

    public static func next(status: Int, body: [String: Any]?, domain: String) -> Next {
        if (200...299).contains(status) {
            if body?["signed_in"] as? Bool == true { return signedIn(body, domain: domain) == nil ? .failed : .signedIn }
            return .saved
        }
        switch body?["error"] as? String {
        case "taken": return .signInInstead
        case "invalid": return .sameCode
        case "key_taken": return .newKeyNewCode
        case "signer": return .newCode
        case "wrong_code": return .wrongCode
        case "expired": return .expired
        case "too_many": return .tooMany
        case "not_guest": return .notGuest
        default: return .failed
        }
    }
}
