import Foundation
import XCTest
@testable import BelfryCore

// Activity previews (one shape, 2026-11-22): what shows in a channel's feed and which preview
// starts open.

private let ME = String(repeating: "a", count: 64)
private let ANA = String(repeating: "b", count: 64)
private var n = 0

private func ev(_ pubkey: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
    n += 1
    return NostrEvent(id: String(format: "%064x", 7000 + n), pubkey: pubkey, createdAt: at, kind: kind, tags: tags, content: content)
}

final class ActivityTests: XCTestCase {
    func testTodoMadeAndFinishedShowInTheFeedOnlyWhenAsked() {
        let g = "garden"
        let list = Derive.listIdFor(g)
        let meta = ev(ANA, 39000, 10, [["d", g], ["name", "garden"]])
        let msg = ev(ANA, 9, 100, [["h", g]], "Seedlings are on the shelf.")
        let made = ev(ANA, 2100, 110, [["t", list], ["h", g]], "Water the seedlings")
        let other = ev(ANA, 2100, 115, [["t", list], ["h", g]], "Order seed potatoes")
        let give = ev(ANA, 2101, 120, [["t", list], ["h", g], ["e", made.id], ["action", "assign"], ["p", ME]])
        let done = ev(ANA, 2101, 130, [["t", list], ["h", g], ["e", other.id], ["action", "done"]])
        let d = Derive(events: [meta, msg, made, other, give, done], me: ME)
        let acts = d.activities(g)
        XCTAssertEqual(acts.map(\.verb), [Activity.madeTodo, Activity.madeTodo, Activity.finished])
        XCTAssertEqual(acts.map(\.title), ["Water the seedlings", "Order seed potatoes", "Order seed potatoes"])
        // the plain feed (the shared vectors) has no activity lines; the app's feed has them in time order
        XCTAssertEqual(d.feed(g).count, 1)
        XCTAssertEqual(d.feed(g, actions: true).map(\.id), [msg.id, "do:" + made.id, "do:" + other.id, "do:" + done.id])
        // the one on me starts open; the one done and the one nobody has stay closed
        XCTAssertTrue(d.activityNeedsMe(acts[0], groupId: g, now: 200))
        XCTAssertFalse(d.activityNeedsMe(acts[1], groupId: g, now: 200))
        XCTAssertFalse(d.activityNeedsMe(acts[2], groupId: g, now: 200))
    }

    func testAToDoInAnotherChannelStaysThere() {
        let made = ev(ANA, 2100, 110, [["t", Derive.listIdFor("x")], ["h", "x"]], "Elsewhere")
        let d = Derive(events: [made], me: ME)
        XCTAssertTrue(d.activities("garden").isEmpty)
        XCTAssertEqual(d.activities("x").count, 1)
    }
}
