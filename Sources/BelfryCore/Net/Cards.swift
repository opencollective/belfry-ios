import Foundation

// Printed cards (collective-belfry docs/cards.md; web chat-source f10e6b2 core/cards.ts; canvas
// "Belfry · Group cards", boards cards/*). An A6 card with a QR: https://chat.<domain>/g/<id>.
// The first scan starts a group (upright card) or a topic (card on its side: a channel whose id is
// a hashtag); later scans join it through the card's guest link.
//   GET  /cards/<id>               → {kind, state: unclaimed} | {kind, state: claimed, group, title, invite}
//                                    | {kind, state: retired | archived, title}; 404 unknown; 429
//   GET  /cards/hashtag/<name>     → {state: free | taken | invalid}
//   POST /cards/<id>/claim         {title, about, hashtag?}   NIP-98 by the account → {group}
//   POST /cards/<id>/claim-start   {email}                    NIP-98 by a key this phone just made → 202
//   POST /cards/<id>/claim-verify  {email, code, name, title, about, hashtag?, client}  the same key
//                                    → {signed_in, bunker_url, pubkey, nip05?, group}: that key is the session's
//   GET  /groups/<group>/card      → {id, kind, started_by: {name, pubkey}, joined_by_scan}
//   POST /cards/<id>/retire        → {state: retired}
// Errors by code, in this app's own words (never the server's `message`). Nothing of the address
// is ever shown: the id only picks what to ask the belfry.

public enum CardKind: String, Sendable, Codable {
    case group, topic
    /// "group" / "topic" in a sentence.
    public var word: String { rawValue }
}

/// A card's address.
public enum CardLink {
    /// 6 characters: capitals and digits without O, I, L, 0, 1.
    public static let idRx = Rx("^[A-HJKMNP-Z2-9]{6}$")
    public static func isId(_ s: String) -> Bool { idRx.test(s) }

    /// https://chat.<domain>/g/<id> (or …/#/g/<id>). Lower case reads as upper case. `id` nil: the
    /// address is a card's but what follows is not an id ("This card isn't known here").
    public static func parse(_ url: URL) -> (domain: String, id: String?)? {
        guard url.scheme == "https", let host = url.host?.lowercased(), host.hasPrefix("chat.") else { return nil }
        let domain = String(host.dropFirst(5))
        guard Discovery.isDomain(domain) else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.isEmpty, let f = url.fragment { parts = f.split(separator: "/").map(String.init) }
        guard let first = parts.first, first == "g" else { return nil }
        guard parts.count == 2 else { return (domain, nil) }
        let id = parts[1].uppercased()
        return (domain, isId(id) ? id : nil)
    }

    /// The card's address (its QR).
    public static func url(domain: String, id: String) -> String { "https://chat.\(domain)/g/\(id)" }
}

/// What the belfry says a card is.
public enum CardInfo: Equatable, Sendable {
    case unclaimed(CardKind)
    case claimed(CardKind, group: String, title: String, invite: String)
    case retired(CardKind, title: String)
    case archived(CardKind, title: String)
    case unknown

    static let groupRx = Rx("^[A-Za-z0-9_-]{1,120}$")
    static let inviteRx = Rx("^[A-Za-z0-9_-]{20,200}$")

    /// A GET answer, kept only when every field is what it should be.
    public static func parse(_ d: [String: Any]?) -> CardInfo {
        guard let d else { return .unknown }
        let kind: CardKind = d["kind"] as? String == "topic" ? .topic : .group
        let title = Cards.label(d["title"] as? String ?? "", 80)
        switch d["state"] as? String {
        case "unclaimed": return .unclaimed(kind)
        case "claimed":
            guard let g = d["group"] as? String, groupRx.test(g), let i = d["invite"] as? String, inviteRx.test(i) else { return .unknown }
            return .claimed(kind, group: g, title: title, invite: i)
        case "retired": return .retired(kind, title: title)
        case "archived": return .archived(kind, title: title)
        default: return .unknown
        }
    }

    public var kind: CardKind? {
        switch self {
        case .unclaimed(let k), .claimed(let k, _, _, _), .retired(let k, _), .archived(let k, _): return k
        case .unknown: return nil
        }
    }
}

/// What is typed to start a group or a topic.
public struct CardForm: Equatable, Sendable, Codable {
    public var title = ""
    public var about = ""
    public var hashtag = ""
    public var name = ""
    public var email = ""
    public init(title: String = "", about: String = "", hashtag: String = "", name: String = "", email: String = "") {
        self.title = title; self.about = about; self.hashtag = hashtag; self.name = name; self.email = email
    }

    /// May "Start the …" be tapped? TAG: the hashtag's live check (a topic). SIGNED_IN: no name, no e-mail.
    public func ready(_ kind: CardKind, tag: HashtagState?, signedIn: Bool) -> Bool {
        guard !title.jsTrim().isEmpty else { return false }
        if kind == .topic && tag != .free { return false }
        return signedIn || (!name.jsTrim().isEmpty && Cards.emailRx.test(email.jsTrim()))
    }
}

public enum HashtagState: String, Sendable { case free, taken, invalid, unknown }

public enum CardError: String, Sendable, CaseIterable {
    case claimed, retired, noPass = "no_pass", guestNotSaved = "guest_not_saved", unverified
    case hashtagTaken = "hashtag_taken", ownKey = "own_key", agent, keyTaken = "key_taken"
    case wrongCode = "wrong_code", expired, invalid, tooMany = "too_many", signer
    case unknown, unsupported, offline, failed

    /// From the server: these codes only (`relay` reads as `signer`).
    static let known: Set<CardError> = [.claimed, .retired, .noPass, .guestNotSaved, .unverified, .hashtagTaken, .ownKey, .agent, .keyTaken,
                                        .wrongCode, .expired, .invalid, .tooMany, .signer]
}

public struct CardFailure: Error, Equatable, Sendable {
    public let code: CardError
    public var triesLeft: Int?
    public var field: String?
    /// `claimed`: theirs, to join.
    public var group: String?
    public var invite: String?
    public init(_ code: CardError, triesLeft: Int? = nil, field: String? = nil, group: String? = nil, invite: String? = nil) {
        self.code = code; self.triesLeft = triesLeft; self.field = field; self.group = group; self.invite = invite
    }

    static let fieldRx = Rx("^[a-z_]{1,20}$")

    /// A refusal, by status and body.
    public static func from(status: Int, body d: [String: Any]?) -> CardFailure {
        if status == 404 { return CardFailure(.unknown) }
        if status == 429 { return CardFailure(.tooMany) }
        let e = d?["error"] as? String ?? ""
        let code: CardError
        if e == "relay" { code = .signer } else if e == "unsupported" { code = .unsupported }
        else if let c = CardError(rawValue: e), CardError.known.contains(c) { code = c } else { code = .failed }
        var f = CardFailure(code)
        if let n = d?["tries_left"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue), (0..<100).contains(n.intValue) { f.triesLeft = n.intValue }
        if let s = d?["field"] as? String, fieldRx.test(s) { f.field = s }
        if let s = d?["group"] as? String, CardInfo.groupRx.test(s) { f.group = s }
        if let s = d?["invite"] as? String, CardInfo.inviteRx.test(s) { f.invite = s }
        return f
    }

    /// The code boxes are emptied (a new code, or a new try, is needed).
    public var clearsCode: Bool { code == .wrongCode || code == .expired || code == .keyTaken || code == .signer }

    /// The words for a refusal: the app's own.
    public func text(_ kind: CardKind = .group) -> String {
        let k = kind.word
        if code == .wrongCode, let n = triesLeft {
            return n <= 0 ? "That code is not right. Send a new one." : "That code is not right. \(n) \(n == 1 ? "try" : "tries") left."
        }
        if code == .invalid {
            switch field {
            case "email": return "That doesn’t look like an e-mail address."
            case "hashtag": return "Use letters, digits and dashes, 2 to 30 characters."
            case "name": return "Please give your name."
            default: return "Please give the \(k)’s name, up to 80 characters."
            }
        }
        switch code {
        case .claimed: return "Someone just started this \(k)."
        case .retired: return "This card was retired: it doesn’t start a \(k) any more."
        case .noPass: return "Only members of this belfry can start a \(k) while signed in. Sign out to start it as a guest with your e-mail."
        case .guestNotSaved: return "Save your account with your e-mail first, then scan the card again."
        case .unverified: return "Confirm your e-mail address first, then scan the card again."
        case .hashtagTaken: return "This hashtag is taken. Try another one."
        case .ownKey: return "This address has an account that signs in with its own key. Sign in with it, then scan the card again."
        case .agent: return "An AI agent can’t start it. Use a person’s account."
        case .keyTaken: return "That did not work. Send a new code and try again."
        case .wrongCode: return "That code is not right. Check the e-mail and try again."
        case .expired: return "That code has expired. Send a new one."
        case .tooMany: return "Too many tries for now. Try again in a few minutes."
        case .signer: return "The belfry is busy. Try again in a minute."
        case .unknown: return "This card isn’t known here."
        case .unsupported: return "This belfry doesn’t take printed cards."
        case .offline: return "No connection. Try again."
        case .invalid: return "Please check the form."
        case .failed: return "That did not work. Try again."
        }
    }
}

/// A visitor's right code: the session to store, and what was started.
public struct CardSignedIn: Equatable, Sendable {
    public let session: GuestSignedIn
    public let group: String
}

/// The card a group was started from, for its stewards.
public struct CardOfGroup: Equatable, Sendable {
    public let id: String
    public let kind: CardKind
    /// The person's name only (never a key).
    public let startedBy: String
    public let joinedByScan: Int
    public init(id: String, kind: CardKind, startedBy: String, joinedByScan: Int) {
        self.id = id; self.kind = kind; self.startedBy = startedBy; self.joinedByScan = joinedByScan
    }

    public static func parse(_ d: [String: Any]?) -> CardOfGroup? {
        guard let d, let id = d["id"] as? String, CardLink.isId(id) else { return nil }
        let n = (d["joined_by_scan"] as? NSNumber).flatMap { $0.doubleValue == Double($0.intValue) && $0.intValue >= 0 ? $0.intValue : nil } ?? 0
        let name = ((d["started_by"] as? [String: Any])?["name"] as? String).map { Cards.label($0, 100) } ?? ""
        return CardOfGroup(id: id, kind: d["kind"] as? String == "topic" ? .topic : .group, startedBy: name, joinedByScan: n)
    }

    /// "Started by Lou · 8 people joined by scanning it"
    public var line: String {
        (startedBy.isEmpty ? "" : "Started by \(startedBy) · ") + (joinedByScan == 1 ? "1 person" : "\(joinedByScan) people") + " joined by scanning it"
    }
}

public enum Cards {
    static let emailRx = Rx("^\\S+@\\S+\\.\\S+$")

    /// A name as plain words: spaces collapsed, trimmed, N UTF-16 units at most.
    public static func label(_ s: String, _ n: Int) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").sliceUnits(n)
    }

    /// The hashtag as a channel id: lower case, letters, digits and dashes (30 at most).
    public static func hashtagSlug(_ s: String) -> String {
        var t = s.jsTrim()
        while t.hasPrefix("#") { t.removeFirst() }
        var out = ""
        var gap = false
        for ch in t.lowercased().unicodeScalars {
            let ok = (ch.value >= 97 && ch.value <= 122) || (ch.value >= 48 && ch.value <= 57) || ch == "-"
            if ok { if gap { out.append("-") }; gap = false; out.unicodeScalars.append(ch) } else { gap = true }
        }
        if gap { out.append("-") }
        // the web: runs of other characters → one dash, dashes cut from both ends, then 30
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(30))
    }

    /// A suggestion that is taken: the next one to ask about (-2 … -9), nil after that.
    public static func nextHashtag(_ slug: String, _ n: Int) -> String? {
        guard (2...9).contains(n) else { return nil }
        let tail = "-\(n)"
        return String(slug.prefix(30 - tail.count)) + tail
    }

    /// The body of a claim.
    public static func claimBody(_ kind: CardKind, _ f: CardForm) -> [String: Any] {
        var b: [String: Any] = ["title": label(f.title, 80), "about": f.about.jsTrim().sliceUnits(500)]
        if kind == .topic { b["hashtag"] = hashtagSlug(f.hashtag) }
        return b
    }

    public static func verifyBody(_ kind: CardKind, _ f: CardForm, code: String, client: String = "belfry-ios") -> [String: Any] {
        var b = claimBody(kind, f)
        b["email"] = f.email.jsTrim()
        b["code"] = code.jsTrim()
        b["name"] = label(f.name, 100)
        b["client"] = client
        return b
    }

    /// A reading guest's post that goes out in a topic reached by a card (the lead's approved
    /// list, web guestmode.guestTopicPost): kind 9 whose tags are exactly [["h", TOPIC]] plus
    /// `imeta` (its photos; images only). Nothing else a reading guest writes goes.
    public static func guestTopicPost(kind: Int, tags: [[String]], topic: String?, fileTypes: [String] = []) -> Bool {
        guard kind == 9, let topic, !topic.isEmpty else { return false }
        let h = tags.filter { $0.first == "h" }
        guard h.count == 1, h[0].count >= 2, h[0][1] == topic else { return false }
        return tags.allSatisfy { $0.first == "h" || $0.first == "imeta" } && fileTypes.allSatisfy { $0.lowercased().hasPrefix("image/") }
    }
}

extension BelfryAPI {
    var cards: String { base + "/cards" }

    /// What the belfry says about card ID. A wrong id is `.unknown`, never an error.
    public func cardInfo(_ id: String) async throws -> CardInfo {
        guard CardLink.isId(id) else { return .unknown }
        let a: Answer
        do { a = try await plain(cards + "/" + id) } catch { throw CardFailure(.offline) }
        if a.status == 404 { return .unknown }
        guard a.ok else { throw CardFailure.from(status: a.status, body: a.body) }
        return CardInfo.parse(a.body)
    }

    /// Is HASHTAG free for a new topic? `.unknown`: the belfry couldn't check just now.
    public func hashtagState(_ hashtag: String) async -> HashtagState {
        let h = Cards.hashtagSlug(hashtag)
        guard h.count >= 2 else { return .invalid }
        guard let a = try? await plain(cards + "/hashtag/" + h) else { return .unknown }
        if a.status >= 500 || a.status == 429 || a.status == 0 { return .unknown }
        switch a.body?["state"] as? String {
        case "free": return .free
        case "taken": return .taken
        default: return .invalid
        }
    }

    /// Signed in: start the group or topic now. Returns its id.
    public func claimCard(_ id: String, kind: CardKind, form: CardForm) async throws -> String {
        let a: Answer
        do { a = try await signed(cards + "/\(id)/claim", method: "POST", json: Cards.claimBody(kind, form)) } catch let e as ApiError {
            throw CardFailure(e.code == "network" ? .offline : e.code == "guest_mode" ? .guestNotSaved : .failed)
        }
        guard a.ok else { throw CardFailure.from(status: a.status, body: a.body) }
        guard let g = a.body?["group"] as? String, CardInfo.groupRx.test(g) else { throw CardFailure(.failed) }
        return g
    }

    /// A request signed by the key this phone just made (it becomes the session's).
    func cardPost(_ path: String, _ json: [String: Any], secretHex: String) async throws -> [String: Any] {
        let url = cards + path
        guard let body = try? JSONSerialization.data(withJSONObject: json), let signer = try? LocalSigner(secretHex: secretHex),
              let auth = try? await BelfryAPI.header(signer, url: url, method: "POST", body: body) else { throw CardFailure(.failed) }
        let a: Answer
        do { a = try await send(url, method: "POST", body: body, authorization: auth) } catch { throw CardFailure(.offline) }
        guard a.ok else { throw CardFailure.from(status: a.status, body: a.body) }
        return a.body ?? [:]
    }

    /// Not signed in: the code goes to EMAIL (nothing is kept on the belfry yet).
    public func claimStart(_ id: String, email: String, secretHex: String) async throws {
        _ = try await cardPost("/\(id)/claim-start", ["email": email.jsTrim()], secretHex: secretHex)
    }

    /// The code: the group or topic is made now, and the key is a session (of the account the
    /// address already had, or of a new guest who looks after this group).
    public func claimVerify(_ id: String, kind: CardKind, form: CardForm, code: String, secretHex: String) async throws -> CardSignedIn {
        let d = try await cardPost("/\(id)/claim-verify", Cards.verifyBody(kind, form, code: code), secretHex: secretHex)
        guard let g = d["group"] as? String, CardInfo.groupRx.test(g), let s = GuestSignIn.signedIn(d, domain: config.domain) else { throw CardFailure(.failed) }
        return CardSignedIn(session: s, group: g)
    }

    /// The card GROUP was started from; nil when it has none in use, or I may not see it.
    public func groupCard(_ group: String) async throws -> CardOfGroup? {
        guard let g = group.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) else { return nil }
        let a: Answer
        do { a = try await signed(base + "/groups/\(g)/card") } catch { throw CardFailure(.offline) }
        if a.status == 404 || a.status == 403 { return nil }
        guard a.ok else { throw CardFailure.from(status: a.status, body: a.body) }
        return CardOfGroup.parse(a.body)
    }

    public func retireCard(_ id: String) async throws {
        guard CardLink.isId(id) else { throw CardFailure(.unknown) }
        let a: Answer
        do { a = try await signed(cards + "/\(id)/retire", method: "POST", json: [:]) } catch { throw CardFailure(.offline) }
        guard a.ok else { throw CardFailure.from(status: a.status, body: a.body) }
    }
}

/// The Townsquare's card of a topic started from a printed card (canvas
/// cards/townsquare-new-topic): the cards server writes the topic's about as
/// "<topic> · <description>", and the post as "# New topic: #tag · topic · description".
public struct CardTopicWords: Equatable, Sendable {
    public let topic: String
    public let about: String
    public init(topic: String, about: String) { self.topic = topic; self.about = about }

    static let postHead = Rx("^#\\s*New topic:\\s*#\\S+\\s*·?\\s*")

    /// ABOUT: the topic's own description when it is known here; else from the POST's first line.
    public static func parts(about: String?, post: String) -> CardTopicWords {
        let first = post.components(separatedBy: "\n").first ?? ""
        let text = about ?? postHead.replace(first, with: "")
        let p = text.components(separatedBy: " · ")
        return CardTopicWords(topic: (p.first ?? "").jsTrim(), about: p.dropFirst().joined(separator: " · ").jsTrim())
    }
}

public extension Actions {
    /// A reading guest's message in a topic reached by a printed card: kind 9 with the topic's
    /// `h` and nothing else (photos become `imeta` when it is sent).
    static func guestTopicPost(_ group: String, text: String) -> Draft {
        Draft(.groups, kind: 9, content: text.jsTrim(), tags: [["h", group]])
    }
}
