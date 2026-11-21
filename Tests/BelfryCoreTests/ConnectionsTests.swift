import XCTest
@testable import BelfryCore

/// SPEC 19.50: lanes in the outbox, the line under a send, the send trace, the retry steps.
final class ConnectionsTests: XCTestCase {
    private func item(_ id: String, _ t: Target, at: Int, kind: Int = 9, tags: [Tag] = [], dm: String? = nil, signed: Bool = false, tries: Int = 0) -> OutboxItem {
        let ev = signed ? NostrEvent(id: "ev-" + id, pubkey: "", createdAt: at, kind: 1059, tags: [["p", "bob"]], content: "") : nil
        return OutboxItem(localId: id, target: t, kind: signed ? 1059 : kind, content: "", tags: tags, createdAt: at, tries: tries, signed: ev, dm: dm)
    }

    func testLanes() {
        XCTAssertEqual(OutboxPass.lane(item("a", .main, at: 1, dm: "r1", signed: true)), "dm:bob")
        XCTAssertEqual(OutboxPass.lane(item("b", .groups, at: 1, tags: [["h", "general"]])), "h:general")
        XCTAssertEqual(OutboxPass.lane(item("c", .main, at: 1, kind: 30078, tags: [["d", "belfry:read"]])), "k:30078:belfry:read")
        XCTAssertEqual(OutboxPass.lane(item("d", .main, at: 1, kind: 0)), "k:0")
    }

    func testAStuckReadMarkerNeverHoldsBackADirectMessage() async {
        let marker = item("marker", .main, at: 1, kind: 30078, tags: [["d", "belfry:read"]])
        let wrap = item("wrap", .main, at: 2, dm: "r1", signed: true)
        let profile = item("profile", .main, at: 3, kind: 0)
        let r = await OutboxPass.run([marker, wrap, profile]) { $0.localId == "marker" ? .error("timeout: the relay did not answer") : .ok(nil) }
        XCTAssertEqual(r.attempted, ["marker", "wrap"])          // the profile waits: the relay did not answer a non-DM
        XCTAssertEqual(r.sent.map(\.item.localId), ["wrap"])
        XCTAssertEqual(r.stalled, [.main])
    }

    func testAfterThreeTriesAnItemHoldsBackOnlyItsLane() async {
        let marker = item("marker", .main, at: 1, kind: 30078, tags: [["d", "belfry:read"]], tries: 3)
        let profile = item("profile", .main, at: 2, kind: 0)
        let marker2 = item("marker2", .main, at: 3, kind: 30078, tags: [["d", "belfry:read"]])
        let r = await OutboxPass.run([marker, profile, marker2]) { $0.localId == "marker" ? .error("timeout: the relay did not answer") : .ok(nil) }
        XCTAssertEqual(r.attempted, ["marker", "profile"]) // its own lane keeps its order
        XCTAssertEqual(r.sent.map(\.item.localId), ["profile"])
    }

    func testADirectMessageThatGetsNoAnswerHoldsBackItsRelay() async {
        let wrap = item("wrap", .main, at: 1, dm: "r1", signed: true)
        let profile = item("profile", .main, at: 2, kind: 0)
        let channel = item("msg", .groups, at: 3, tags: [["h", "general"]])
        let r = await OutboxPass.run([wrap, profile, channel]) { $0.localId == "wrap" ? .error("connection closed") : .ok(nil) }
        XCTAssertEqual(r.attempted, ["wrap", "msg"])
    }

    func testASignerThatDoesNotAnswerHoldsBackOnlyWhatStillNeedsSigning() async {
        let msg = item("msg", .groups, at: 1, tags: [["h", "general"]])
        let other = item("other", .groups, at: 2, tags: [["h", "garden"]])
        let wrap = item("wrap", .main, at: 3, dm: "r1", signed: true)
        let r = await OutboxPass.run([msg, other, wrap]) { $0.localId == "msg" ? .error("timeout: the signer did not answer") : .ok(nil) }
        XCTAssertEqual(r.attempted, ["msg", "wrap"])
        XCTAssertEqual(r.items.map(\.localId), ["msg", "other"])
        XCTAssertEqual(r.items.first?.tries, 1)
    }

    func testARefusalHoldsNothingBack() async {
        let a = item("a", .groups, at: 1, tags: [["h", "general"]])
        let b = item("b", .groups, at: 2, tags: [["h", "general"]])
        let r = await OutboxPass.run([a, b]) { $0.localId == "a" ? .error("restricted: not a member") : .ok(nil) }
        XCTAssertEqual(r.attempted, ["a", "b"])
        XCTAssertTrue(r.stalled.isEmpty)
        XCTAssertEqual(r.failed.map(\.localId), ["a"])
    }

    func testTheLineUnderASend() {
        let p = SendProgress(since: 100, step: SendState.sign)
        XCTAssertEqual(SendState.line(failed: false, tries: 0, progress: p, now: 102, online: true).text, "Sending…")
        XCTAssertEqual(SendState.line(failed: false, tries: 0, progress: p, now: 106, online: true).text, "Still sending… · waiting for the server")
        let late = SendState.line(failed: false, tries: 0, progress: p, now: 131, online: true)
        XCTAssertEqual(late, SendLine(text: "Not sent yet", retry: true))
        XCTAssertEqual(SendState.line(failed: false, tries: 1, progress: p, now: 101, online: true).text, "Sending again…")
        XCTAssertEqual(SendState.line(failed: false, tries: 0, progress: p, now: 106, online: false).text, "Waiting for the connection…")
        XCTAssertEqual(SendState.line(failed: true, tries: 1, progress: nil, now: 0, online: true), SendLine(text: "Not sent", retry: true))
        XCTAssertEqual(SendState.line(failed: false, tries: 2, progress: nil, now: 0, online: true).text, "Waiting for the connection…")
        // the words people see: never "signer" or "relay"
        XCTAssertEqual(SendState.shown(SendState.checking), "connecting")
        XCTAssertEqual(SendState.shown(SendState.connecting), "connecting")
        XCTAssertEqual(SendState.shown(SendState.again), "connecting")
        XCTAssertEqual(SendState.shown(SendState.prepare), "encrypting")
        XCTAssertEqual(SendState.shown(SendState.relayWait), "waiting for the server")
        XCTAssertEqual(SendState.shown(SendState.uploading(2_200_000, 4_800_000)), "uploading 2.2 of 4.8 MB")
        XCTAssertEqual(SendState.nextChange(p, now: 102), 3)
        XCTAssertEqual(SendState.nextChange(p, now: 110), 20)
        XCTAssertNil(SendState.nextChange(p, now: 140))
    }

    func testTheTrace() {
        var t: TimeInterval = 0
        let utc = TimeZone(identifier: "UTC")!
        let trace = SendTrace(clock: { t }, wall: { Date(timeIntervalSince1970: 12 * 3600 + 55 * 60) }, zone: utc)
        trace.step("r1", label: "DM", SendState.prepare)
        t = 0.3
        trace.step("r1", label: "DM", SendState.checking)
        t = 5.3
        trace.step("r1", label: "DM", SendState.connecting)
        t = 5.6
        trace.step("r1", label: "DM", SendState.relayWait)
        t = 5.7
        trace.end("r1", "OK", left: false)
        XCTAssertEqual(trace.lines(), ["12:55:00 DM · preparing 0.3s · checking the connection 5.0s · connecting 0.3s · waiting for the relay 0.1s · → OK 5.7s"])
        XCTAssertNil(trace.progress("r1"))
        // a retry keeps the send waiting, its time going on
        trace.step("m1", label: "message", SendState.sign)
        t = 7
        trace.end("m1", "retry (timeout)", left: true)
        XCTAssertEqual(trace.progress("m1")?.step, SendState.again)
        XCTAssertEqual(trace.progress("m1")?.since, 5.7)
        t = 9
        trace.restart()
        XCTAssertEqual(trace.progress("m1")?.since, 9)
        for i in 0..<30 { trace.note("n\(i)") }
        XCTAssertEqual(trace.lines().count, 20)
        XCTAssertEqual(trace.lines().last, "12:55:00 n29")
    }

    func testRetrySteps() {
        XCTAssertEqual((0..<8).map(SyncEngine.step), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testTraceLabels() {
        XCTAssertEqual(SendTrace.label(item("a", .main, at: 1, dm: "r", signed: true)), "DM")
        XCTAssertEqual(SendTrace.label(item("b", .main, at: 1, kind: 30078)), "read state")
        XCTAssertEqual(SendTrace.label(item("c", .groups, at: 1)), "message")
        var api = item("d", .api, at: 1)
        api.http = HttpCall(url: "https://x.org/api/v1/group-meta", json: [:])
        XCTAssertEqual(SendTrace.label(api), "API /api/v1/group-meta")
    }
}
