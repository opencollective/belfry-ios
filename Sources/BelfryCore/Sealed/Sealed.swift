import Foundation

// Sealed conversations (collective-belfry docs/sealed.md, version 1): the key chain, sealing and
// opening a message, handing keys to a device, a new device's request, my device names, shared
// history. Everything here happens on the device: the signer is never asked.

/// Every letterbox secret this device was ever given, by its public key. Kept in the Keychain
/// by the app (never in the database, never logged).
public struct KeyChain: Codable, Hashable, Sendable {
    /// letterbox public key (hex) → secret (hex)
    public private(set) var keys: [String: String]

    public init(keys: [String: String] = [:]) { self.keys = keys.filter { KeyChain.matches(lb: $0.key, secret: $0.value) } }

    public var isEmpty: Bool { keys.isEmpty }

    public func secret(_ lb: String) -> Data? { keys[lb].flatMap { Data(hex: $0) } }

    public static func matches(lb: String, secret: String) -> Bool {
        guard isHex64(lb), isHex64(secret), let s = Data(hex: secret), let pub = try? Keys.publicKeyHex(secret: s) else { return false }
        return pub == lb
    }

    /// Adds a secret after checking it against its public key. False when it does not match.
    @discardableResult
    public mutating func add(lb: String, secret: String) -> Bool {
        guard KeyChain.matches(lb: lb, secret: secret) else { return false }
        keys[lb] = secret
        return true
    }

    /// A new letterbox: added to the chain, its public key returned.
    public mutating func make() throws -> String {
        let s = Keys.generateSecret()
        let lb = try Keys.publicKeyHex(secret: s)
        keys[lb] = s.hex
        return lb
    }

    /// Keys handed over by another device: true when anything new came.
    @discardableResult
    public mutating func merge(_ other: [(lb: String, secret: String)]) -> Bool {
        var changed = false
        for k in other where keys[k.lb] == nil { if add(lb: k.lb, secret: k.secret) { changed = true } }
        return changed
    }
}

public enum Sealed {
    /// The letterbox a wrap is sealed to; nil for a wrap of the old kind (it goes to the signer).
    public static func lb(of wrap: NostrEvent) -> String? {
        guard wrap.kind == 1059, let lb = wrap.tag("lb"), isHex64(lb) else { return nil }
        return lb
    }

    private static func conv(_ secret: Data, _ pub: String) throws -> Data {
        guard let p = Data(hex: pub), p.count == 32 else { throw BelfryError.crypto("bad key") }
        return try NIP44.conversationKey(secret: secret, publicKey: p)
    }

    /// Seal (signed by the device) and wrap (a one-time key) RUMOR for ACCOUNT's letterbox LB
    /// (sealed.md 4). SIGN: nil = the device key signs the seal.
    public static func wrap(_ rumor: NostrEvent, device: Data, to account: String, lb: String, now: Int = .now) throws -> NostrEvent {
        let sealContent = try NIP44.encrypt(rumor.json, conversationKey: conv(device, lb))
        let seal = try NostrEvent(pubkey: "", createdAt: GiftWrap.backdate(now: now), kind: 13, tags: [], content: sealContent).signed(with: device)
        let one = Keys.generateSecret()
        let content = try NIP44.encrypt(seal.json, conversationKey: conv(one, lb))
        return try NostrEvent(pubkey: "", createdAt: GiftWrap.backdate(now: now), kind: 1059, tags: [["p", account], ["lb", lb]], content: content).signed(with: one)
    }

    public enum Opening: Sendable {
        /// The rumor and the key that signed its seal. Whether that key may speak for the rumor's
        /// author is the caller's check (the author's chain, or the belfry's key for a mail).
        case opened(rumor: NostrEvent, sealPubkey: String)
        /// No secret for its letterbox on this device: locked here, keep the wrap.
        case locked
        /// Not a sealed wrap, or it does not open: nothing to keep trying.
        case invalid
    }

    public static func open(_ wrap: NostrEvent, keys: KeyChain) -> Opening {
        guard let lb = lb(of: wrap) else { return .invalid }
        guard let secret = keys.secret(lb) else { return .locked }
        return open(wrap, secret: secret)
    }

    /// Wrap → seal (signature checked) → rumor, with the secret the wrap was made for.
    static func open(_ wrap: NostrEvent, secret: Data) -> Opening {
        guard let sealJSON = try? NIP44.decrypt(wrap.content, conversationKey: conv(secret, wrap.pubkey)),
              let seal = NostrEvent.from(json: sealJSON), seal.kind == 13, seal.isValid,
              let rumorJSON = try? NIP44.decrypt(seal.content, conversationKey: conv(secret, seal.pubkey)),
              var rumor = NostrEvent.from(json: rumorJSON) else { return .invalid }
        // a rumor is unsigned: its id is what its content gives
        rumor.id = rumor.computedId
        rumor.sig = ""
        return .opened(rumor: rumor, sealPubkey: seal.pubkey)
    }

    // ---- handing keys to a device (sealed.md 5.5) --------------------------------------------------

    public struct Handover: Sendable {
        /// The device that gave them (the seal's signer).
        public let giver: String
        public let account: String
        public let keys: [(lb: String, secret: String)]
    }

    /// A gift wrap to the DEVICE `to`: the giver's whole chain.
    public static func keysWrap(_ chain: KeyChain, account: String, device: Data, to: String, now: Int = .now) throws -> NostrEvent {
        let giver = try Keys.publicKeyHex(secret: device)
        let list = chain.keys.sorted { $0.key < $1.key }.map { "{\"lb\":\(JSON.string($0.key)),\"secret\":\(JSON.string($0.value))}" }
        let content = "{\"v\":1,\"account\":\(JSON.string(account)),\"keys\":[\(list.joined(separator: ","))]}"
        let rumor = GiftWrap.rumor(kind: SealedKind.keys, pubkey: giver, tags: [["p", account]], content: content, createdAt: now)
        let seal = try NostrEvent(pubkey: "", createdAt: GiftWrap.backdate(now: now), kind: 13, tags: [],
                                  content: NIP44.encrypt(rumor.json, conversationKey: conv(device, to))).signed(with: device)
        let one = Keys.generateSecret()
        return try NostrEvent(pubkey: "", createdAt: GiftWrap.backdate(now: now), kind: 1059, tags: [["p", to]],
                              content: NIP44.encrypt(seal.json, conversationKey: conv(one, to))).signed(with: one)
    }

    /// Opens a key hand-over addressed to this device. The caller accepts it only when `giver` is
    /// a device of a roster of its own account's chains; each secret is checked on merge.
    public static func openKeys(_ wrap: NostrEvent, device: Data) -> Handover? {
        guard wrap.kind == 1059, case .opened(let rumor, let giver) = open(wrap, secret: device),
              rumor.kind == SealedKind.keys, rumor.pubkey == giver,
              let o = JSON.parse(rumor.content) as? [String: Any], (o["v"] as? Int) == 1,
              let account = o["account"] as? String, isHex64(account), rumor.tag("p") == account,
              let list = o["keys"] as? [[String: Any]] else { return nil }
        let keys = list.compactMap { k -> (lb: String, secret: String)? in
            guard let lb = k["lb"] as? String, let s = k["secret"] as? String, KeyChain.matches(lb: lb, secret: s) else { return nil }
            return (lb, s)
        }
        return Handover(giver: giver, account: account, keys: keys)
    }

    // ---- a new device asks (sealed.md 5.2) -----------------------------------------------------------

    /// hex HMAC-SHA256(link secret, device pubkey bytes)
    public static func linkProof(secret: String, device: String) -> String? {
        guard isHex64(secret), let k = Data(hex: secret), let d = Data(hex: device), d.count == 32 else { return nil }
        return Crypto.hmacSHA256(key: k, d).hex
    }

    /// The request a new device signs with its own key. LINK: the secret of the login link it
    /// signed in from, when there was one.
    public static func request(account: String, device: String, link: String? = nil, now: Int = .now) -> EventTemplate {
        var tags: [Tag] = [["p", account]]
        if let link, let proof = linkProof(secret: link, device: device) { tags.append(["link", proof]) }
        return EventTemplate(kind: SealedKind.request, content: "", tags: tags, createdAt: now)
    }

    /// Whether REQUEST carries the proof of one of the link secrets this device showed.
    public static func linked(_ request: NostrEvent, secrets: [String]) -> Bool {
        guard request.kind == SealedKind.request, let proof = request.tag("link") else { return false }
        return secrets.contains { linkProof(secret: $0, device: request.pubkey) == proof }
    }

    // ---- my device names (sealed.md 3.5) ----------------------------------------------------------------

    public struct DeviceName: Hashable, Sendable {
        public var name: String
        /// phone | tablet | computer
        public var kind: String
        public var added: Int
        public init(name: String, kind: String, added: Int) { self.name = name; self.kind = kind; self.added = added }
    }

    /// The content of `belfry:devices`, opened with the letterbox its `lb` tag names.
    public static func deviceNames(_ e: NostrEvent, keys: KeyChain) -> [String: Any]? {
        guard e.kind == 30078, e.tag("d") == SealedKind.devicesD, let lb = e.tag("lb"), let s = keys.secret(lb),
              let text = try? NIP44.decrypt(e.content, conversationKey: conv(s, lb)),
              let o = JSON.parse(text) as? [String: Any] else { return nil }
        return o
    }

    public static func names(in doc: [String: Any]?) -> [String: DeviceName] {
        var out = [String: DeviceName]()
        for (k, v) in (doc?["devices"] as? [String: Any]) ?? [:] {
            guard isHex64(k), let d = v as? [String: Any], let name = d["name"] as? String else { continue }
            let kind = (d["kind"] as? String).flatMap { ["phone", "tablet", "computer"].contains($0) ? $0 : nil } ?? "computer"
            out[k] = DeviceName(name: String(name.prefix(60)), kind: kind, added: (d["added"] as? Int) ?? 0)
        }
        return out
    }

    /// The document with this device's own entry written; unknown fields and the other devices'
    /// entries are kept; entries of devices in no roster any more go after 90 days.
    /// GONE: device → when it left the last roster that had it.
    public static func deviceDoc(_ old: [String: Any]?, device: String, entry: DeviceName, gone: [String: Int] = [:], now: Int = .now) -> [String: Any] {
        var doc = old ?? [:]
        doc["v"] = 1
        var devices = (doc["devices"] as? [String: Any]) ?? [:]
        var mine = (devices[device] as? [String: Any]) ?? [:]
        mine["name"] = entry.name
        mine["kind"] = entry.kind
        if mine["added"] == nil { mine["added"] = entry.added }
        devices[device] = mine
        for (d, at) in gone where d != device && now - at > 90 * 86400 { devices[d] = nil }
        doc["devices"] = devices
        return doc
    }

    /// `belfry:devices` to sign with the account: encrypted to the head letterbox itself.
    public static func devicesTemplate(_ doc: [String: Any], lb: String, keys: KeyChain, now: Int = .now) throws -> EventTemplate {
        guard let s = keys.secret(lb) else { throw BelfryError.crypto("no letterbox key") }
        let content = try NIP44.encrypt(JSON.encode(doc), conversationKey: conv(s, lb))
        return EventTemplate(kind: 30078, content: content, tags: [["d", SealedKind.devicesD], ["lb", lb]], createdAt: now)
    }

    // ---- sharing history (sealed.md 8) --------------------------------------------------------------------

    /// What one wrap may hold: 200 rumors, and no more text than NIP-44 can carry once sealed.
    public static let historyMaxRumors = 200
    public static let historyMaxBytes = 40_000

    /// The rumors (oldest first) as 8564 rumors of SHARER for PERSON, split to fit.
    public static func history(_ rumors: [NostrEvent], sharer: String, person: String, now: Int = .now) -> [NostrEvent] {
        var out = [NostrEvent](), batch = [String](), size = 0
        func flush() {
            guard !batch.isEmpty else { return }
            out.append(GiftWrap.rumor(kind: SealedKind.history, pubkey: sharer, tags: [["p", person]],
                                      content: "{\"v\":1,\"rumors\":[\(batch.joined(separator: ","))]}", createdAt: now))
            batch = []; size = 0
        }
        for r in rumors {
            let j = r.json
            let n = j.utf8.count + 1
            if n > historyMaxBytes { continue } // one rumor too large to share: left out
            if batch.count >= historyMaxRumors || size + n > historyMaxBytes { flush() }
            batch.append(j); size += n
        }
        flush()
        return out
    }

    /// The rumors of a shared history, ids recomputed. The caller keeps those whose conversation
    /// the sharer is in, and marks them as shared by that person.
    public static func sharedRumors(_ rumor: NostrEvent) -> [NostrEvent] {
        guard rumor.kind == SealedKind.history, let o = JSON.parse(rumor.content) as? [String: Any], (o["v"] as? Int) == 1,
              let list = o["rumors"] as? [Any] else { return [] }
        return list.prefix(historyMaxRumors).compactMap { item -> NostrEvent? in
            guard let data = try? JSONSerialization.data(withJSONObject: item), var e = try? JSONDecoder().decode(NostrEvent.self, from: data) else { return nil }
            e.id = e.computedId
            e.sig = ""
            return e
        }
    }
}
