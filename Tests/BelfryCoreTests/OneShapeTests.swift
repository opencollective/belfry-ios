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

/// vectors/one-shape.json (belfry-android's, copied byte for byte).
final class OneShapeVectorTests: XCTestCase {
    func testRecent() throws {
        for c in try vector("one-shape").dict("recent").list("cases") {
            let r = MenuChannels.list(events: try events(c["events"]), me: c.str("me")!, now: c.int("now")!, known: c.strs("known"),
                                      pinsAll: c.strs("pinsAll"), pinsMine: c.strs("pinsMine"))
            XCTAssertEqual(r.pinned, c.dict("expect").strs("pinned"), c.str("name")!)
            XCTAssertEqual(r.recent, c.dict("expect").strs("recent"), c.str("name")!)
            XCTAssertEqual(r.pinned + r.recent, c.dict("expect").strs("list"), c.str("name")!)
        }
    }

    func testPins() throws {
        for c in try vector("one-shape").dict("pins").list("cases") {
            let name = c.str("name")!
            let known = Set(c.strs("known"))
            if let start = c["start"] as? [String] {
                var ids = start
                for t in c.strs("toggle") { ids = Pins.toggle(ids, t) }
                XCTAssertEqual(Pins.serialize(ids), c.str("expectContent"), name)
            } else if let order = c.str("channelOrder") {
                XCTAssertEqual(Pins.pinnedForEveryone(order).filter(known.contains), c.strs("expect"), name)
            } else {
                let newest = c.list("copies").max { ($0.int("created_at") ?? 0) < ($1.int("created_at") ?? 0) }
                XCTAssertEqual(Pins.parse(newest?.str("plain")).filter(known.contains), c.strs("expect"), name)
            }
        }
    }

    func testHeaderRow() throws {
        let v = try vector("one-shape").dict("headerRow")
        XCTAssertEqual(HeaderRow.dropOrder, v.strs("dropOrder"))
        for c in v.list("cases") {
            let items = c.list("items").map { (key: $0.str("key")!, width: ($0["width"] as! NSNumber).doubleValue) }
            XCTAssertEqual(HeaderRow.fit(items, budget: (c["budget"] as! NSNumber).doubleValue, gap: (c["gap"] as! NSNumber).doubleValue),
                           c.strs("expect"), c.str("name")!)
        }
    }
}

final class PinWriterTests: XCTestCase {
    func testPinForEveryoneKeepsOtherKeys() throws {
        let d = Actions.pinForEveryone("b", previous: ["order": ["general", "b"], "categories": [], "pinned": ["a"]])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(d.content.utf8)) as? [String: Any])
        XCTAssertEqual(obj["pinned"] as? [String], ["a", "b"])
        XCTAssertEqual(obj["order"] as? [String], ["general", "b"])
        XCTAssertNotNil(obj["categories"])
        let off = Actions.pinForEveryone("a", previous: obj)
        XCTAssertEqual(Pins.pinnedForEveryone(off.content), ["b"])
        XCTAssertEqual(d.tags, [["d", "belfry:channel-order"]])
    }
}
