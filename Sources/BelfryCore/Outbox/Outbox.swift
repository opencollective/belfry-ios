import Foundation

// The outbox (SPEC 5): saved first, published in order per relay, classified errors.
// The pass logic is pure (OutboxPass) so it is tested against vectors/outbox.json; the app's
// SyncEngine runs it with real relays.

public struct Attachment: Codable, Hashable, Sendable {
    public var file: String // a file name in the app's attachments folder
    public var name: String
    public var mime: String
    public var size: Int
    public var width: Int?
    public var height: Int?

    public init(file: String, name: String, mime: String, size: Int, width: Int? = nil, height: Int? = nil) {
        self.file = file
        self.name = name
        self.mime = mime
        self.size = size
        self.width = width
        self.height = height
    }
}

/// A call to the belfry's HTTP API waiting in the outbox (SPEC 19.37). Its NIP-98 header is
/// signed when it is sent, never when it is queued.
public struct HttpCall: Codable, Hashable, Sendable {
    public var method: String
    public var url: String
    /// The JSON body as text.
    public var body: String

    public init(method: String = "POST", url: String, json: [String: Any]) {
        self.method = method
        self.url = url
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.body = String(decoding: data, as: UTF8.self)
    }

    public var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    }

    /// What an answer means for the outbox: nil = done; else an error message for
    /// `Outbox.classify`: 401 / 408 / 429 / 5xx / no answer are tried again, any other 4xx fails
    /// for good with its `error` code.
    public static func outcome(status: Int, body: Data) -> String? {
        if (200..<300).contains(status) { return nil }
        let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String ?? ""
        if status == 0 || status >= 500 || [401, 408, 429].contains(status) { return "timeout: http \(status)" }
        return "error: http \(status)" + (code.isEmpty ? "" : " " + code)
    }

    /// The `error` code of a failed call's message ("error: http 403 not_allowed" → not_allowed).
    public static func code(of message: String?) -> String? {
        guard let m = message, let x = Rx("^error: http \\d+ ([a-z_]+)").first(m) else { return nil }
        return x[1]
    }
}

public struct OutboxItem: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case queued, failed }

    public var localId: String
    public var target: Target
    public var kind: Int
    public var content: String
    public var tags: [Tag]
    public var createdAt: Int
    public var attachments: [Attachment]
    public var status: Status
    public var tries: Int
    public var error: String?
    /// Signed already (a gift wrap): published as is.
    public var signed: NostrEvent?
    /// The direct message (rumor id) it carries.
    public var dm: String?
    /// Target `api`: the call to make. KIND / TAGS then describe the change it makes (a 9002 for
    /// a channel's settings), shown in the log until it is out, as a queued event is.
    public var http: HttpCall?

    public var id: String { localId }

    public init(localId: String = "local-" + Crypto.random(8).hex, target: Target, kind: Int, content: String, tags: [Tag], createdAt: Int,
                attachments: [Attachment] = [], status: Status = .queued, tries: Int = 0, error: String? = nil, signed: NostrEvent? = nil, dm: String? = nil,
                http: HttpCall? = nil) {
        self.localId = localId
        self.target = target
        self.kind = kind
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.attachments = attachments
        self.status = status
        self.tries = tries
        self.error = error
        self.signed = signed
        self.dm = dm
        self.http = http
    }

    /// How it shows in the feed until it is out (pubkey = me).
    public func asEvent(me: String) -> NostrEvent {
        NostrEvent(id: localId, pubkey: me, createdAt: createdAt, kind: kind, tags: tags, content: content)
    }

    /// The line under a pending message.
    public var stateText: String {
        switch status {
        case .failed: return "Not sent"
        case .queued: return tries > 0 ? "Waiting for connection…" : "Sending…"
        }
    }
}

public enum Outbox {
    public enum ErrorClass: String, Sendable { case duplicate, failed, retry }

    static let permanentPrefix = Rx("^(blocked|invalid|restricted|pow|duplicate|error):")
    static let permanentWords = Rx("not allowed|denied|unauthori[sz]ed", [.caseInsensitive])

    public static func classify(_ message: String) -> ErrorClass {
        if message.hasPrefix("duplicate:") { return .duplicate }
        if permanentPrefix.test(message) || permanentWords.test(message) || refusedUpload(message) { return .failed }
        return .retry
    }

    static let refusedUploadRx = Rx("^upload failed \\((4\\d\\d)")
    static let uploadMayPass: Set<String> = ["401", "408", "429"]

    /// A file the storage refuses (4xx but 401 / 408 / 429) fails its message for good (SPEC 19.17).
    static func refusedUpload(_ message: String) -> Bool {
        guard let code = refusedUploadRx.first(message)?[1] else { return false }
        return !uploadMayPass.contains(code)
    }

    /// created_at strictly increasing per client.
    public static func nextCreatedAt(last: Int, now: Int = .now) -> Int { max(last + 1, now) }
}

public enum SendOutcome: Sendable {
    case ok(NostrEvent?)
    case error(String)
}

public struct PassResult: Sendable {
    public var attempted: [String] = []
    public var sent: [(item: OutboxItem, event: NostrEvent?)] = []
    public var failed: [OutboxItem] = []
    public var items: [OutboxItem] = []
    /// Relays with an item left to try again (it failed for now, or waited behind one that did):
    /// when not empty, run again soon (1, 2, 4… s), not at once.
    public var stalled: Set<Target> = []
}

public enum OutboxPass {
    /// Which items keep their order among themselves (SPEC 19.50): a direct message's wraps by
    /// whom they go to, a group's events and API calls by the group (`h`), anything else by its
    /// kind (and `d`). A retrying item holds back only its own lane, so a message never waits
    /// behind a read marker or a settings call.
    public static func lane(_ item: OutboxItem) -> String {
        if let dm = item.dm { return "dm:" + (item.signed?.tag("p") ?? dm) }
        if let h = item.tags.first(where: { $0.count >= 2 && $0[0] == "h" })?[1] { return "h:" + h }
        let d = item.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1]
        return "k:\(item.kind)" + (d.map { ":" + $0 } ?? "")
    }

    /// After this many transient failures an item holds back only its own lane, never its whole relay.
    public static let stallsRelayUntil = 3

    /// The signer did not answer: nothing else that needs a signature goes in this pass.
    public static func signerDown(_ message: String) -> Bool { message.hasPrefix("timeout: the signer") }

    /// The relay (or the API) did not answer or is not reachable: its other items would wait the same.
    public static func connectionDown(_ message: String) -> Bool { message.hasPrefix("timeout:") || message == "connection closed" }

    /// One flush pass over ITEMS. SEND signs (unless pre-signed), uploads and publishes one item.
    /// Items are walked by created_at; failed ones are skipped. After a retryable error (SPEC 5, 19.50):
    /// - the item's lane waits for the rest of the pass (order kept within it);
    /// - a signer that did not answer holds back every item that still needs signing;
    /// - a relay that did not answer holds back its other items, unless the item failed
    ///   `stallsRelayUntil` times already, and never a direct message for another item's sake.
    public static func run(_ items: [OutboxItem], send: (OutboxItem) async -> SendOutcome) async -> PassResult {
        var box = items
        var r = PassResult()
        var lanes = Set<String>()
        var relayDown = Set<Target>()          // by a direct message: holds back everything on that relay
        var relayDownForOthers = Set<Target>() // by anything else: direct messages still go
        var signerOut = false
        func replace(_ next: OutboxItem) { box = box.map { $0.localId == next.localId ? next : $0 } }
        for item in items.sorted(by: { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.localId < $1.localId }) {
            if item.status == .failed { continue }
            let lane = item.target.rawValue + "/" + lane(item)
            let isDm = item.dm != nil
            let held = lanes.contains(lane) || relayDown.contains(item.target) || (!isDm && relayDownForOthers.contains(item.target))
                || (signerOut && item.signed == nil)
            if held { r.stalled.insert(item.target); continue }
            r.attempted.append(item.localId)
            switch await send(item) {
            case .ok(let ev):
                box.removeAll { $0.localId == item.localId }
                r.sent.append((item, ev))
            case .error(let msg) where msg.hasPrefix("hold:"):
                // this item waits for something of its own (a sealed wrap whose head could not be
                // checked): tried again next time, and the items after it still go
                var next = item
                next.tries += 1
                next.error = msg
                box = box.map { $0.localId == item.localId ? next : $0 }
            case .error(let msg):
                switch Outbox.classify(msg) {
                case .duplicate:
                    box.removeAll { $0.localId == item.localId }
                    r.sent.append((item, item.signed))
                case .failed:
                    var next = item
                    next.tries += 1
                    next.status = .failed
                    next.error = msg
                    replace(next)
                    r.failed.append(next)
                case .retry:
                    var next = item
                    next.tries += 1
                    next.error = msg
                    replace(next)
                    r.stalled.insert(item.target)
                    lanes.insert(lane)
                    if signerDown(msg) { signerOut = true }
                    else if connectionDown(msg) && item.tries < stallsRelayUntil {
                        if isDm { relayDown.insert(item.target) } else { relayDownForOthers.insert(item.target) }
                    }
                }
            }
        }
        r.items = box
        return r
    }
}
