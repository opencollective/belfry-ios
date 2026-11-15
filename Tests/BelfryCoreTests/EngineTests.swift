import Foundation
import XCTest
@testable import BelfryCore

/// The sync engine and direct messages in local-only mode (no network): the outbox survives a
/// restart, sends in order, and what it sends is signed, tagged and derived like relay events.
final class EngineTests: XCTestCase {
    func tempDB() throws -> (Database, String) {
        let path = NSTemporaryDirectory() + "belfry-test-\(UUID().uuidString).sqlite"
        return (try Database(path: path), path)
    }

    func engine(_ db: Database, _ signer: LocalSigner) -> SyncEngine {
        SyncEngine(config: .defaults(domain: "example.org"), db: db, signer: signer, localOnly: true,
                   attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    func testOutboxSurvivesRestart() async throws {
        let (db, path) = try tempDB()
        let me = try LocalSigner(secret: Keys.generateSecret())
        // a message queued before the app was killed
        db.putOutbox(OutboxItem(target: .groups, kind: 9, content: "still here", tags: [["h", "general"], SyncEngine.clientTag], createdAt: 1_800_000_000))
        let reopened = try Database(path: path)
        let e = engine(reopened, me)
        XCTAssertEqual(e.outboxItems().map(\.content), ["still here"])
        // shown at once, as pending
        XCTAssertTrue(e.snapshot().contains { $0.content == "still here" && e.pending($0.id) != nil })
        await e.flush()
        XCTAssertTrue(e.outboxItems().isEmpty)
        let sent = try XCTUnwrap(e.snapshot().first { $0.content == "still here" })
        XCTAssertTrue(sent.isValid)
        XCTAssertEqual(sent.pubkey, me.pubkey)
        XCTAssertTrue(sent.hasTag("client", "belfry-ios"))
        // and stored: a new engine on the same file has it
        XCTAssertNotNil(engine(try Database(path: path), me).snapshot().first { $0.id == sent.id })
    }

    func testCreateChannelAndPostInOrder() async throws {
        let (db, _) = try tempDB()
        let me = try LocalSigner(secret: Keys.generateSecret())
        let e = engine(db, me)
        for d in Actions.createChannel(id: "book-club-1a2b", name: "Book club", about: "Monthly") { e.enqueue(d) }
        e.enqueue(Actions.postMessage("book-club-1a2b", text: "First! #books"))
        await e.flush()
        let d = Derive(events: e.snapshot(), me: me.pubkey)
        let g = try XCTUnwrap(d.group("book-club-1a2b"))
        XCTAssertEqual(g.name, "Book club")
        XCTAssertTrue(g.admins.contains(me.pubkey))
        XCTAssertEqual(d.messages("book-club-1a2b").map(\.text), ["First! #books"])
        XCTAssertEqual(d.messages("book-club-1a2b").first?.topics, ["books"])
        let times = e.snapshot().filter { $0.pubkey == me.pubkey && [9, 9002, 9007].contains($0.kind) }.map(\.createdAt).sorted()
        XCTAssertEqual(Set(times).count, times.count, "created_at grows per client")
    }

    func testDirectMessageRoundTrip() async throws {
        let (db, _) = try tempDB()
        let me = try LocalSigner(secret: Keys.generateSecret())
        let ana = try LocalSigner(secret: Keys.generateSecret())
        let e = engine(db, me)
        let dms = DirectMessages(engine: e)
        try await dms.demoDM(from: ana, text: "Hi there", at: Int.now - 60)
        try await dms.send("Hello Ana", in: "n:" + ana.pubkey)
        await e.flush()
        await dms.process()
        let conv = "n:" + ana.pubkey
        XCTAssertEqual(dms.thread(conv).map(\.text), ["Hi there", "Hello Ana"])
        XCTAssertEqual(dms.threads().first?.unread, 1)
        dms.markRead(conv)
        XCTAssertEqual(dms.threads().first?.unread, 0)
    }

    func testMailArrivesInItsThread() async throws {
        let (db, _) = try tempDB()
        let me = try LocalSigner(secret: Keys.generateSecret())
        let e = engine(db, me)
        let dms = DirectMessages(engine: e)
        let bridge = Keys.generateSecret()
        try await dms.demoMail(bridgeSecret: bridge, sender: "Ana <ana@example.org>", subject: "Re: Picnic", text: "Count me in", at: 1_800_000_000)
        await dms.process()
        let t = try XCTUnwrap(dms.threads().first)
        XCTAssertEqual(t.conv, "m:ana@example.org|picnic")
        XCTAssertEqual(dms.threadName(t.conv), "Picnic")
        XCTAssertEqual(t.last.text, "Count me in")
        XCTAssertEqual(t.last.fromName, "Ana")
    }

    func testDiscoveryFallbacks() {
        let c = BelfryConfig.from(domain: "Example.org", document: [
            "name": "Example", "relays": ["groups": "wss://g.example.org", "signer": ["wss://b.example.org"]],
            "admins": [String(repeating: "a", count: 64), "nope"],
            "apps": [["name": "Chat", "url": "https://example.org/chat"]],
        ])
        XCTAssertEqual(c.domain, "example.org")
        XCTAssertEqual(c.name, "Example")
        XCTAssertEqual(c.groupsRelay, "wss://g.example.org")
        XCTAssertEqual(c.mainRelay, "wss://relay.example.org")
        XCTAssertEqual(c.apiBase, "https://belfry.example.org/api/v1")
        XCTAssertEqual(c.channelInvites, "https://belfry.example.org/api/v1/channel-invites")
        XCTAssertEqual(c.authorize, "https://belfry.example.org/connect/authorize")
        XCTAssertEqual(c.admins, [String(repeating: "a", count: 64)])
        XCTAssertEqual(c.channelLink("garden-1a"), "https://example.org/chat/#/c/garden-1a")
        XCTAssertTrue(Discovery.isDomain("belfry.sh"))
        XCTAssertFalse(Discovery.isDomain("not a domain"))
        XCTAssertNotNil(BunkerURL("bunker://\(String(repeating: "b", count: 64))?relay=wss%3A%2F%2Fbunker.example.org&secret=x"))
        XCTAssertNil(BunkerURL("bunker://short?relay=wss://x"))
    }

    func testSignInCallback() throws {
        let flow = SignIn(config: .defaults(domain: "example.org"), redirectURI: "sh.belfry.app://connect")
        let q = URLComponents(url: flow.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(q.first { $0.name == "redirect_uri" }?.value, "sh.belfry.app://connect")
        XCTAssertEqual(q.first { $0.name == "code_challenge" }?.value, PKCE.challenge(for: flow.verifier))
        XCTAssertEqual(try flow.code(from: URL(string: "sh.belfry.app://connect?code=abc&state=\(flow.state)")!), "abc")
        XCTAssertThrowsError(try flow.code(from: URL(string: "sh.belfry.app://connect?code=abc&state=other")!)) {
            XCTAssertEqual($0 as? SignIn.Failure, .wrongState)
        }
        XCTAssertThrowsError(try flow.code(from: URL(string: "sh.belfry.app://connect?error=access_denied&state=\(flow.state)")!)) {
            XCTAssertEqual($0 as? SignIn.Failure, .cancelled)
        }
    }
}

/// Counts what goes to the signer (a NIP-46 round trip each, in real life).
final class CountingSigner: Signer, @unchecked Sendable {
    let inner: LocalSigner
    var decrypts = 0
    init(_ inner: LocalSigner) { self.inner = inner }
    var pubkey: String { inner.pubkey }
    func sign(_ t: EventTemplate) async throws -> NostrEvent { try await inner.sign(t) }
    func nip44Encrypt(peer: String, plaintext: String) async throws -> String { try await inner.nip44Encrypt(peer: peer, plaintext: plaintext) }
    func nip44Decrypt(peer: String, payload: String) async throws -> String { decrypts += 1; return try await inner.nip44Decrypt(peer: peer, payload: payload) }
}

final class OfflineFirstTests: XCTestCase {
    /// A gift wrap is opened once: after a restart (a new engine on the same file) nothing goes to
    /// the signer again, and the conversation is there at once.
    func testKnownWrapsAreNotDecryptedAgain() async throws {
        let path = NSTemporaryDirectory() + "dm-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let me = try LocalSigner(secret: Keys.generateSecret())
        let ana = try LocalSigner(secret: Keys.generateSecret())
        let rumor = GiftWrap.rumor(kind: 14, pubkey: ana.pubkey, tags: [["p", me.pubkey]], content: "Hi")
        let wrap = try await GiftWrap.wrap(rumor, to: me.pubkey, signer: ana)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let s1 = CountingSigner(me)
        let e1 = SyncEngine(config: .defaults(domain: "x.org"), db: try Database(path: path), signer: s1, localOnly: true, attachmentsDir: dir)
        e1.add([wrap], verify: false)
        let d1 = DirectMessages(engine: e1)
        await d1.process()
        XCTAssertEqual(d1.threads().count, 1)
        XCTAssertGreaterThan(s1.decrypts, 0)
        let s2 = CountingSigner(me)
        let e2 = SyncEngine(config: .defaults(domain: "x.org"), db: try Database(path: path), signer: s2, localOnly: true, attachmentsDir: dir)
        let d2 = DirectMessages(engine: e2)
        XCTAssertEqual(d2.threads().first?.last.text, "Hi") // from the store, before any processing
        await d2.process()
        XCTAssertEqual(s2.decrypts, 0)
    }
}
