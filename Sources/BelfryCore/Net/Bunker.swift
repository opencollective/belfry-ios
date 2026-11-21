import Foundation

// NIP-46 remote signer (SPEC 3, 19.50): the member's key stays in the belfry's signer; this device
// holds only a client key. Requests are kind 24133, NIP-44 encrypted JSON-RPC. The signer's socket
// is ONE Relay made once and opened again as needed; the sync engine asks it with the others (on
// foreground, a network change, 25 s of quiet). Requests wait while it (re)connects; a socket quiet
// for more than 10 s is asked first; a request with no answer drops the socket and is asked once
// more on a fresh one.

public final class BunkerSigner: Signer, @unchecked Sendable {
    public let bunker: BunkerURL
    private let client: LocalSigner
    public private(set) var pubkey: String
    private let lock = NSLock()
    /// The signer's socket, from the bunker URL's relay (it may one day be the community relay).
    public let relay: Relay
    private var connected = false
    private var opening: Task<Void, Error>?
    private var waiting = [String: CheckedContinuation<String, Error>]()
    public var timeout: TimeInterval = 15
    /// Each request's method and how long it took (seconds), answered or not (the send trace).
    public var onRequest: ((String, TimeInterval) -> Void)?

    static let noAnswer = "timeout: the signer did not answer"
    static let lost = "connection closed"

    /// CLIENTSECRET: this device's key for the bunker (kept in the Keychain). PUBKEY: the member's
    /// key if known already (cached so the app opens offline).
    public init(bunker: BunkerURL, clientSecret: Data, pubkey: String?) throws {
        self.bunker = bunker
        self.client = try LocalSigner(secret: clientSecret)
        self.pubkey = pubkey ?? ""
        self.relay = Relay(url: bunker.relays.first ?? "")
        relay.onEvent = { [weak self] _, ev in self?.handle(ev) }
        relay.onDisconnect = { [weak self] in self?.lostSocket() }
    }

    /// Asks the signer for the member's key if it is not known yet.
    public func ensurePubkey() async throws -> String {
        if !pubkey.isEmpty { return pubkey }
        let pk = try await request("get_public_key", [])
        guard isHex64(pk) else { throw BelfryError.signer("the signer sent no key") }
        pubkey = pk
        return pk
    }

    /// Connected and said hello to, ahead of the next request (foreground, network back).
    public func warm() async {
        try? await ready()
    }

    /// The socket is open, subscribed and the signer said hello on it. Concurrent requests wait for
    /// the same opening. A socket quiet for more than 10 s is asked for a pong first.
    private func ready() async throws {
        lock.lock()
        if connected, relay.isUp {
            let quiet = relay.quietFor
            lock.unlock()
            if quiet <= Relay.quietBeforeSend { return }
            if await relay.probe() { return }
            lock.lock()
        }
        if let t = opening { lock.unlock(); try await t.value; return }
        let t = Task { try await self.open() }
        opening = t
        lock.unlock()
        defer { lock.lock(); opening = nil; lock.unlock() }
        try await t.value
    }

    private func open() async throws {
        if !relay.isUp { try await relay.connect() }
        relay.subscribe("nip46", filters: [["kinds": [24133], "#p": [client.pubkey], "since": Int.now - 10]])
        _ = try await rpc("connect", [bunker.remotePubkey, bunker.secret ?? ""])
        lock.lock(); connected = true; lock.unlock()
    }

    /// The socket closed or was dropped: requests on it fail now (each is asked once more).
    private func lostSocket() {
        lock.lock()
        connected = false
        let w = waiting
        waiting = [:]
        lock.unlock()
        w.values.forEach { $0.resume(throwing: BelfryError.signer(BunkerSigner.lost)) }
    }

    private func reset() {
        lock.lock(); connected = false; lock.unlock()
        relay.close()
        lostSocket()
    }

    private func handle(_ ev: NostrEvent) {
        guard ev.kind == 24133, ev.pubkey == bunker.remotePubkey else { return }
        Task {
            guard let text = try? await client.nip44Decrypt(peer: ev.pubkey, payload: ev.content),
                  let obj = JSON.parse(text) as? [String: Any], let id = obj["id"] as? String else { return }
            lock.lock(); let c = waiting.removeValue(forKey: id); lock.unlock()
            guard let c else { return }
            if let err = obj["error"] as? String, !err.isEmpty {
                c.resume(throwing: BelfryError.signer("signer: " + err))
            } else if let result = obj["result"] as? String {
                if result == "auth_url" { return } // not used by Belfry's signer
                c.resume(returning: result)
            } else {
                c.resume(throwing: BelfryError.signer("signer: empty answer"))
            }
        }
    }

    private func rpc(_ method: String, _ params: [String]) async throws -> String {
        let id = Crypto.random(8).hex
        let body = JSON.encode(["id": id, "method": method, "params": params] as [String: Any])
        let content = try await client.nip44Encrypt(peer: bunker.remotePubkey, plaintext: body)
        let ev = try client.signNow(EventTemplate(kind: 24133, content: content, tags: [["p", bunker.remotePubkey]], createdAt: .now))
        let seconds = timeout
        let r = relay
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            lock.lock(); waiting[id] = c; lock.unlock()
            Task { [weak self] in
                // a publish that fails (no OK: the socket is dropped and every request on it fails)
                do { try await r.publish(ev, timeout: seconds) } catch { self?.fail(id, error) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.fail(id, BelfryError.signer(BunkerSigner.noAnswer))
            }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        lock.lock(); let w = waiting.removeValue(forKey: id); lock.unlock()
        w?.resume(throwing: error)
    }

    /// One request: on an open socket; no answer (or the socket lost) drops the socket and asks
    /// once more on a fresh one. Its time goes to `onRequest`.
    private func request(_ method: String, _ params: [String]) async throws -> String {
        let started = Date()
        defer { onRequest?(method, Date().timeIntervalSince(started)) }
        do {
            try await ready()
            return try await rpc(method, params)
        } catch let e as BelfryError where BunkerSigner.transient(e) {
            reset()
            do {
                try await ready()
                return try await rpc(method, params)
            } catch let e as BelfryError where BunkerSigner.transient(e) {
                reset()
                throw BelfryError.signer(BunkerSigner.noAnswer)
            }
        }
    }

    /// No answer, a lost socket or no connection: worth one more try on a fresh socket.
    static func transient(_ e: BelfryError) -> Bool {
        let m = e.relayMessage
        return m.hasPrefix("timeout") || m == lost
    }

    public func sign(_ t: EventTemplate) async throws -> NostrEvent {
        let pk = try await ensurePubkey()
        let unsigned = t.event(pubkey: pk)
        let json = "{\"kind\":\(t.kind),\"content\":\(JSON.string(t.content)),\"tags\":[" +
            t.tags.map { "[" + $0.map(JSON.string).joined(separator: ",") + "]" }.joined(separator: ",") +
            "],\"created_at\":\(t.createdAt),\"pubkey\":\(JSON.string(pk))}"
        let result = try await request("sign_event", [json])
        guard let ev = NostrEvent.from(json: result), ev.pubkey == pk, ev.kind == unsigned.kind, ev.content == unsigned.content, ev.isValid else {
            throw BelfryError.signer("signer: the signature does not check out")
        }
        return ev
    }

    public func nip44Encrypt(peer: String, plaintext: String) async throws -> String {
        try await request("nip44_encrypt", [peer, plaintext])
    }

    public func nip44Decrypt(peer: String, payload: String) async throws -> String {
        try await request("nip44_decrypt", [peer, payload])
    }

    public func nip04Decrypt(peer: String, payload: String) async throws -> String {
        try await request("nip04_decrypt", [peer, payload])
    }

    public func disconnect() { reset() }
}
