import XCTest
@testable import BelfryCore

final class OneShapeTests: XCTestCase {
    let me = String(repeating: "a", count: 64)
    let you = String(repeating: "b", count: 64)

    func ev(_ id: String, _ kind: Int, _ by: String, _ at: Int, h: String, p: String? = nil) -> NostrEvent {
        var tags: [Tag] = [["h", h]]
        if let p { tags.append(["p", p]) }
        return NostrEvent(id: id, pubkey: by, createdAt: at, kind: kind, tags: tags, content: "")
    }

    func testPinsFirstThenRecentByNewestActivity() {
        let now = 100 * 86400
        let events = [
            ev("1", 9, me, now - 40 * 86400, h: "old"),          // too old: not involved
            ev("2", 7, me, now - 86400, h: "garden"),             // reacted
            ev("3", 9, you, now - 3600, h: "garden"),             // newest in garden
            ev("4", 1111, you, now - 7200, h: "repair", p: me),   // mentioned
            ev("5", 9, me, now - 600, h: "pinned"),               // pinned: not in recent
            ev("6", 9, you, now - 60, h: "quiet"),                // never involved
        ]
        let r = MenuChannels.list(events: events, me: me, now: now, known: ["old", "garden", "repair", "pinned", "quiet"],
                                  pinsAll: ["pinned", "ghost"], pinsMine: ["pinned"])
        XCTAssertEqual(r.pinned, ["pinned"])
        XCTAssertEqual(r.recent, ["garden", "repair"])
    }

    func testPinsParse() {
        XCTAssertEqual(Pins.parse(#"{"v":1,"c":["a",2,"b","a"]}"#), ["a", "b"])
        XCTAssertEqual(Pins.parse("nope"), [])
        XCTAssertEqual(Pins.parse(Pins.serialize(["x"])), ["x"])
        XCTAssertEqual(Pins.pinnedForEveryone(#"{"order":["a"],"pinned":["c"]}"#), ["c"])
    }

    func testHeaderRowDropOrder() {
        let items: [(key: String, width: Double)] = [("lead", 60), ("owner", 40), ("people", 30), ("pinned", 30), ("todos", 30), ("files", 30)]
        XCTAssertEqual(HeaderRow.fit(items, budget: 1000, gap: 8), ["lead", "owner", "people", "pinned", "todos", "files"])
        XCTAssertEqual(HeaderRow.fit(items, budget: 200, gap: 8), ["lead", "people", "pinned", "todos"])
        XCTAssertEqual(HeaderRow.fit(items, budget: 10, gap: 8), ["lead", "people"])
    }
}
