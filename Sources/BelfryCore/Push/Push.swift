import Foundation
import Security

// Push notifications (collective-belfry docs/push.md; SPEC 19.19). The device makes a random
// 32-byte key K and registers it with the belfry; the belfry encrypts each notification with
// NIP-44 v2 using K directly as the conversation key and sends it through the push gateway. APNs
// delivers `aps.alert` = a placeholder and `b` = the ciphertext; the Notification Service
// Extension decrypts it here and replaces title and body. Nothing here trusts the payload's
// `url`: `route` only accepts chat.<domain> of the belfry this device is signed in to.

/// What a notification says once decrypted (the plaintext of push.md §4).
public struct PushContent: Hashable, Sendable {
    public let domain: String
    public let type: String
    public let title: String
    public let body: String
    public let channel: String?
    public let event: String?
    public let from: String?
    public let url: String?

    /// The notification's thread: `dm` for direct messages, else the channel (push.md `collapse`).
    public var threadId: String { type == "dm" ? "dm" : (channel ?? "belfry") }

    /// Which setting it falls under (vectors/push.json `channel`): dms, mentions (mentions and
    /// replies), announcements, pins, messages.
    public var category: String {
        switch type {
        case "dm": return "dms"
        case "mention", "reply": return "mentions"
        case "announcement": return "announcements"
        case "pin": return "pins"
        default: return "messages"
        }
    }

    /// What a tap opens for someone signed in to SIGNEDIN: only this belfry's own addresses.
    public func route(signedIn: String) -> PushRoute {
        domain.lowercased() == signedIn.lowercased() ? Push.route(url, domain: signedIn) : .home
    }
}

/// Where a tap on a notification leads.
public enum PushRoute: Hashable, Sendable {
    case channel(String, message: String?)
    /// A thread reply: the channel with the thread of ROOT open.
    case thread(String, root: String)
    case messages
    case home
}

public enum Push {
    /// A new device key K: 32 random bytes, base64 as the belfry stores it.
    public static func newKey() -> Data { Crypto.random(32) }

    /// Decrypts `b` with K; nil when it doesn't open or isn't a version-1 notification.
    public static func open(_ b: String, key: Data) -> PushContent? {
        guard key.count == 32, let text = try? NIP44.decrypt(b, conversationKey: key),
              let o = JSON.parse(text) as? [String: Any], (o["v"] as? NSNumber)?.intValue == 1,
              let domain = o["domain"] as? String, !domain.isEmpty else { return nil }
        func s(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let type = s("type") ?? "message"
        let title = (s("title") ?? domain).sliceUnits(120)
        // an address of something of the belfry never shows: its generic word (nothing is known
        // by name in the extension; SPEC 19.61)
        let body = References.plain(s("body") ?? "New notification", domain: domain) { _ in nil }.sliceUnits(180)
        return PushContent(domain: domain, type: type, title: title, body: body, channel: s("channel"),
                           event: s("event").flatMap { isHex64($0) ? $0 : nil }, from: s("from").flatMap { isHex64($0) ? $0 : nil }, url: s("url"))
    }

    /// Where URL leads, if it is https://chat.<DOMAIN>/#/c/<id>[/m/<event>] or …/#/dm; else home.
    public static func route(_ url: String?, domain: String) -> PushRoute {
        guard let url, let u = URL(string: url), u.scheme == "https", u.host?.lowercased() == "chat." + domain.lowercased() else { return .home }
        let parts = (u.fragment ?? "").split(separator: "/").map(String.init)
        if parts == ["dm"] { return .messages }
        guard parts.count == 2 || parts.count == 4, parts[0] == "c", let id = parts[1].removingPercentEncoding, channelIdRx.test(id) else { return .home }
        if parts.count == 2 { return .channel(id, message: nil) }
        if parts[2] == "m", isHex64(parts[3]) { return .channel(id, message: parts[3]) }
        if parts[2] == "thread", isHex64(parts[3]) { return .thread(id, root: parts[3]) }
        return .home
    }

    /// Stay quiet for a "dm" notification that comes within 30 s of this phone sending a direct
    /// message or an e-mail: NIP-17 self-copies look like any other DM to the belfry (push.md §4).
    public static let quietAfterSend = 30

    public static func isOwnEcho(type: String, lastSent: Int, now: Int) -> Bool {
        type == "dm" && lastSent > 0 && now - lastSent >= 0 && now - lastSent <= quietAfterSend
    }

    /// vectors/push.json `quiet`: a dm within 30 s of sending one, or while Messages / a
    /// conversation is open in the foreground (times in milliseconds).
    public static func quiet(type: String, nowMs: Int, lastSentMs: Int, dmsOpen: Bool) -> Bool {
        guard type == "dm" else { return false }
        return dmsOpen || (lastSentMs > 0 && nowMs - lastSentMs >= 0 && nowMs - lastSentMs <= quietAfterSend * 1000)
    }

    /// A channel id in a tapped address.
    static let channelIdRx = Rx("^[A-Za-z0-9_.-]{1,64}$")

    /// App Group defaults shared by the app and its extension (when the group is available).
    public static let appGroup = "group.sh.belfry.app"
    public static let lastSentKey = "belfry-last-dm-sent"

    public static var shared: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    /// The app sent a DM or an e-mail now.
    public static func markSent(now: Int = .now) { shared.set(now, forKey: lastSentKey) }
    public static var lastSent: Int { shared.integer(forKey: lastSentKey) }

    /// The body of `POST /api/v1/push/devices` that registers this device.
    public static func addBody(token: Data, sandbox: Bool, key: Data, name: String) -> [String: Any] {
        ["add": ["platform": "apns", "token": token.hex, "env": sandbox ? "sandbox" : "production",
                 "key": key.base64EncodedString(), "app": "belfry-ios", "name": String(name.prefix(60))]]
    }
}

/// Where K is kept: the keychain, in an access group the app and its extension share (falls back
/// to the app's own group when the shared one isn't available, e.g. an unsigned simulator build).
/// One K per account (SPEC 19.24): account "device-key" (slot "") or "device-key@<slot>", value
/// "<domain> <base64 K>".
public enum PushKeyStore {
    static let service = "sh.belfry.app.push"
    static let account = "device-key"

    public static func accountName(_ slot: String) -> String { slot.isEmpty ? account : account + "@" + slot }

    /// The slot a keychain account name stands for; nil for anything else.
    public static func slot(ofAccount a: String) -> String? {
        if a == account { return "" }
        return a.hasPrefix(account + "@") ? String(a.dropFirst(account.count + 1)) : nil
    }

    static func query(_ group: String?, slot: String = "") -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountName(slot)]
        if let group, !group.isEmpty { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    /// Saves "<domain> <base64 K>".
    public static func save(domain: String, key: Data, group: String?, slot: String = "") {
        let value = Data((domain + " " + key.base64EncodedString()).utf8)
        clear(group: group, slot: slot)
        var q = query(group, slot: slot)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecValueData as String] = value
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess, group != nil {
            var plain = query(nil, slot: slot)
            plain[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            plain[kSecValueData as String] = value
            SecItemAdd(plain as CFDictionary, nil)
        }
    }

    /// "<domain> <base64 K>" → its parts (K must be 32 bytes).
    public static func parse(_ s: String) -> (domain: String, key: Data)? {
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let k = Data(base64Encoded: parts[1]), k.count == 32 else { return nil }
        return (parts[0], k)
    }

    public static func load(group: String?, slot: String = "") -> (domain: String, key: Data)? {
        for g in [group, nil] {
            var q = query(g, slot: slot)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
                  let s = String(data: d, encoding: .utf8), let p = parse(s) else { continue }
            return p
        }
        return nil
    }

    /// Every account's K on this device (the extension tries each).
    public static func loadAll(group: String?) -> [PushKey] {
        var out = [PushKey]()
        for g in [group, nil] {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            if let g, !g.isEmpty { q[kSecAttrAccessGroup as String] = g }
            var items: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { continue }
            for item in list {
                guard let a = item[kSecAttrAccount as String] as? String, let slot = slot(ofAccount: a),
                      let d = item[kSecValueData as String] as? Data, let s = String(data: d, encoding: .utf8), let p = parse(s),
                      !out.contains(where: { $0.slot == slot }) else { continue }
                out.append(PushKey(slot: slot, domain: p.domain, key: p.key))
            }
        }
        return out
    }

    public static func clear(group: String?, slot: String = "") {
        SecItemDelete(query(group, slot: slot) as CFDictionary)
        if group != nil { SecItemDelete(query(nil, slot: slot) as CFDictionary) }
    }
}

/// One account's K.
public struct PushKey: Hashable, Sendable {
    public let slot: String
    public let domain: String
    public let key: Data
    public init(slot: String, domain: String, key: Data) { self.slot = slot; self.domain = domain; self.key = key }
}

public extension Push {
    /// The account a payload is for: the first K that opens it and whose domain it names.
    static func openAny(_ b: String, keys: [PushKey]) -> (slot: String, content: PushContent)? {
        for k in keys {
            if let c = open(b, key: k.key), c.domain == k.domain { return (k.slot, c) }
        }
        return nil
    }
}

/// The person's notification settings (`POST /api/v1/notifications`, push.md §3).
public struct NotificationSettings: Hashable, Sendable {
    public var dms = true
    public var mentions = true
    public var announcements = true
    public var pins = true
    /// group id → all | default | mentions | off (absent = default)
    public var channels = [String: String]()
    public init() {}

    public static let levels: [(id: String, label: String)] = [("all", "All messages"), ("default", "Default"), ("mentions", "Mentions only"), ("off", "Off")]

    public func level(_ group: String) -> String { channels[group] ?? "default" }

    public static func parse(_ o: [String: Any]) -> NotificationSettings {
        var s = NotificationSettings()
        s.dms = o["dms"] as? Bool ?? true
        s.mentions = o["mentions"] as? Bool ?? true
        s.announcements = o["announcements"] as? Bool ?? true
        s.pins = o["pins"] as? Bool ?? true
        for (k, v) in o["channels"] as? [String: Any] ?? [:] {
            if let l = v as? String, levels.contains(where: { $0.id == l }) { s.channels[k] = l }
        }
        return s
    }
}

/// The channel's Notifications sheet (SPEC 19.38, the owner's mock-up Notif-C): three choices over
/// the four stored levels. `default` is what the belfry sends without a choice (mentions, replies,
/// announcements, pins: docs/push.md), shown as "When it's for me (the default here)".
public enum NotifyChoice: String, CaseIterable, Sendable {
    case everything, forMe, nothing

    /// The choice a stored level shows as.
    public static func of(level: String) -> NotifyChoice {
        switch level {
        case "all": return .everything
        case "off": return .nothing
        default: return .forMe // "default" and "mentions"
        }
    }

    /// The level a tap stores: "When it's for me" goes back to the belfry's default.
    public var level: String {
        switch self {
        case .everything: return "all"
        case .forMe: return "default"
        case .nothing: return "off"
        }
    }

    public var title: String {
        switch self {
        case .everything: return "Everything"
        case .forMe: return "When it's for me"
        case .nothing: return "Nothing"
        }
    }

    /// The explaining line; "(the default here)" after the one the stored `default` resolves to.
    public func line(stored: String?) -> String {
        let base: String
        switch self {
        case .everything: base = "Every new message"
        case .forMe: base = "Mentions, replies to me, announcements"
        case .nothing: base = "I'll look when I open the channel"
        }
        return stored == "default" && self == .forMe ? base + " (the default here)" : base
    }
}

public struct PushDevice: Hashable, Sendable, Identifiable { public let id, app, name, since: String }

public extension BelfryAPI {
    /// Registers (or re-registers) this device; returns its id.
    @discardableResult
    func addPushDevice(token: Data, sandbox: Bool, key: Data, name: String) async throws -> String {
        let a = try await signed(config.apiBase + "/push/devices", method: "POST", json: Push.addBody(token: token, sandbox: sandbox, key: key, name: name))
        guard a.ok, let id = a.body?["id"] as? String else { throw BelfryAPI.fail(a, [:], "Notifications could not be turned on just now.") }
        return id
    }

    func removePushDevice(token: Data) async throws {
        let a = try await signed(config.apiBase + "/push/devices", method: "POST", json: ["remove": token.hex])
        if !a.ok { throw BelfryAPI.fail(a, [:], BelfryAPI.generic) }
    }

    func pushDevices() async throws -> [PushDevice] {
        let a = try await signed(config.apiBase + "/push/devices", method: "POST", json: [:])
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "Your devices could not be read just now.") }
        return (b["devices"] as? [[String: Any]] ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            return PushDevice(id: id, app: o["app"] as? String ?? "", name: (o["name"] as? String ?? "").sliceUnits(60), since: o["since"] as? String ?? "")
        }
    }

    /// SET nil reads the settings; otherwise merges SET and returns the result.
    func notificationSettings(set: [String: Any]? = nil) async throws -> NotificationSettings {
        let a = try await signed(config.apiBase + "/notifications", method: "POST", json: set.map { ["set": $0] } ?? [:])
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "Your notification settings could not be read just now.") }
        return NotificationSettings.parse(b)
    }
}
