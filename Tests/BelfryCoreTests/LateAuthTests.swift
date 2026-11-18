import Foundation
import XCTest
@testable import BelfryCore

/// The groups relay answered the first REQ before NIP-42 AUTH (public events only), then asked
/// for AUTH (the web's missing agreement and channels, chat 458704e; the lead, 2026-11-18).
final class LateAuthTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var list = [String]()
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func testFirstAnswerBeforeAuthIsAskedAgainFromZero() async throws {
        let r = Relay(url: "wss://groups-relay.example.org")
        r.authSigner = try LocalSigner(secret: Keys.generateSecret())
        let frames = Frames()
        r.testSink = { frames.add($0) }
        r.refilter = { id in id == "live-groups" ? [["kinds": [9, 39000, 2100], "limit": 2000]] : nil }
        r.subscribe("live-groups", filters: [["kinds": [9, 39000, 2100], "since": 1_800_000_000, "limit": 2000]])
        // the public answer ends before any AUTH
        r.receiveForTest(#"["EOSE","live-groups"]"#)
        XCTAssertFalse(r.challenged)
        XCTAssertFalse(r.authed)
        // the challenge comes late; the app signs and sends AUTH
        r.receiveForTest(#"["AUTH","challenge-1"]"#)
        XCTAssertTrue(r.challenged)
        var authId: String?
        for _ in 0..<100 where authId == nil {
            if let f = frames.all.first(where: { $0.hasPrefix("[\"AUTH\"") }),
               let arr = JSON.parse(f) as? [Any], let ev = arr.last as? [String: Any] { authId = ev["id"] as? String }
            else { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let id = try XCTUnwrap(authId, "no AUTH sent")
        r.receiveForTest("[\"OK\",\"\(id)\",true,\"\"]")
        XCTAssertTrue(r.authed)
        // the subscription is sent again, from 0: older members-only events come too
        let reqs = frames.all.filter { $0.hasPrefix("[\"REQ\",\"live-groups\"") }
        XCTAssertEqual(reqs.count, 2)
        XCTAssertTrue(reqs[0].contains("\"since\""))
        XCTAssertFalse(reqs[1].contains("\"since\""), "after AUTH: no since")
    }

    func testAnEndBeforeAuthIsNotTheRelaysAnswer() throws {
        let path = NSTemporaryDirectory() + "belfry-test-\(UUID().uuidString).sqlite"
        let db = try Database(path: path)
        let me = try LocalSigner(secret: Keys.generateSecret())
        let e = SyncEngine(config: .defaults(domain: "example.org"), db: db, signer: me, localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        // a recent public message is stored: `since` would move past older members-only events
        let pub = try me.signNow(EventTemplate(kind: 9, content: "hi", tags: [["h", "general"]], createdAt: 1_800_000_000))
        _ = e.add([pub], verify: false)
        XCTAssertEqual(e.filters(.groups)[0]["since"] as? Int, 1_800_000_000 - 3600)
        XCTAssertEqual(e.filters(.groups, fromStart: true)[0]["since"] as? Int, 0, "the first subscription after AUTH")
        // a catch-up from the start is pending; the relay answers, then asks for AUTH
        db.set("full-sync", ["groups"])
        let e2 = SyncEngine(config: .defaults(domain: "example.org"), db: try Database(path: path), signer: me, localOnly: true,
                            attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        var answered = 0
        e2.onEOSE = { _ in answered += 1 }
        let r = Relay(url: "wss://groups-relay.example.org")
        r.authSigner = me
        r.testSink = { _ in }
        r.receiveForTest(#"["AUTH","challenge-2"]"#)
        e2.eose(.groups, "live-groups", relay: r)
        XCTAssertEqual(answered, 0, "an answer before AUTH is not the relay's answer")
        XCTAssertEqual(e2.filters(.groups)[0]["since"] as? Int, 0, "the catch-up is still pending")
        // without a signer (no AUTH), the answer counts at once
        let open = Relay(url: "wss://open.example.org")
        e2.eose(.groups, "live-groups", relay: open)
        XCTAssertEqual(answered, 1)
        XCTAssertEqual(e2.filters(.groups)[0]["since"] as? Int, 1_800_000_000 - 3600)
    }

    /// Android auth-since 3ad9280's case: the app starts again (or reconnects) with a recent public
    /// message stored from a pre-AUTH answer. Through the engine's own wiring: the first REQ asks
    /// from that message, the end before AUTH starts no absence check, and after AUTH the live
    /// subscription asks again from 0; only that answer is the relay's.
    func testNextLaunchAfterAPublicOnlyAnswer() async throws {
        let path = NSTemporaryDirectory() + "belfry-test-\(UUID().uuidString).sqlite"
        let me = try LocalSigner(secret: Keys.generateSecret())
        let first = SyncEngine(config: .defaults(domain: "example.org"), db: try Database(path: path), signer: me, localOnly: true,
                               attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        _ = first.add([try me.signNow(EventTemplate(kind: 9, content: "public", tags: [["h", "general"]], createdAt: 1_800_000_000))], verify: false)
        // the next launch: a new engine on the same store
        let e = SyncEngine(config: .defaults(domain: "example.org"), db: try Database(path: path), signer: me, localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        var answers = 0
        e.onEOSE = { t in if t == .groups { answers += 1 } } // the app's deleted-by-absence check starts here
        let r = Relay(url: "wss://groups-relay.example.org")
        let frames = Frames()
        r.testSink = { frames.add($0) }
        e.wireAnswers(r, .groups)
        e.subscribe(.groups, r)
        XCTAssertTrue(frames.all[0].contains("\"since\":\(1_800_000_000 - 3600)"))
        r.receiveForTest(#"["EOSE","live-groups"]"#)
        r.receiveForTest(#"["AUTH","challenge-3"]"#)
        XCTAssertEqual(answers, 0, "a public-only answer starts no absence check")
        var authId: String?
        for _ in 0..<100 where authId == nil {
            if let f = frames.all.first(where: { $0.hasPrefix("[\"AUTH\"") }),
               let arr = JSON.parse(f) as? [Any], let ev = arr.last as? [String: Any] { authId = ev["id"] as? String }
            else { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        r.receiveForTest("[\"OK\",\"\(try XCTUnwrap(authId))\",true,\"\"]")
        let reqs = frames.all.filter { $0.hasPrefix("[\"REQ\",\"live-groups\"") }
        XCTAssertEqual(reqs.count, 2)
        // the main filter of the REQ after AUTH asks from 0
        let again = try XCTUnwrap(JSON.parse(reqs[1]) as? [Any])
        XCTAssertEqual((again[2] as? [String: Any])?["since"] as? Int, 0)
        r.receiveForTest(#"["EOSE","live-groups"]"#)
        XCTAssertEqual(answers, 1, "the answer after AUTH is the relay's")
    }
}
