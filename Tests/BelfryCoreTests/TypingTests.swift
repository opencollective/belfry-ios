import XCTest
@testable import BelfryCore

/// vectors/typing.json (written here from tools/vectors/typing.py).
final class TypingTests: XCTestCase {
    private func num(_ v: Any?) -> TimeInterval { (v as? NSNumber)?.doubleValue ?? 0 }

    func testTextsAndAccept() throws {
        let v = try vector("typing")
        for c in v.list("texts") { XCTAssertEqual(Typing.text(c.strs("names")), c.str("text")) }
        for c in v.list("accept") {
            XCTAssertEqual(Typing.accepted(createdAt: num(c["created_at"]), now: num(c["now"])), c["accepted"] as? Bool, c.str("note") ?? "")
        }
        let k = v.dict("constants")
        XCTAssertEqual(num(k["send_gap"]), Typing.sendGap)
        XCTAssertEqual(num(k["show_for"]), Typing.showFor)
        XCTAssertEqual(num(k["skew"]), Typing.skew)
        XCTAssertEqual(num(k["stop_window"]), Typing.stopWindow)
        XCTAssertEqual(k.int("kind"), Typing.kind)
        XCTAssertEqual(k.int("wrap_kind"), Typing.wrapKind)
    }

    func testBoard() throws {
        for c in try vector("typing").list("board") {
            var b = TypingBoard()
            var got = [[String]]()
            let me = c.str("me")!
            for s in c.list("steps") {
                let now = num(s["now"])
                switch s.str("type") {
                case "event": b.event(place: "h:x", author: s.str("author")!, createdAt: num(s["created_at"]), stop: (s["stop"] as? Bool) == true, now: now, me: me)
                case "message": b.message(place: "h:x", author: s.str("author")!)
                default: got.append(b.typers("h:x", now: now))
                }
            }
            XCTAssertEqual(got, (c["expect"] as? [[String]]) ?? [], c.str("note") ?? "")
        }
    }

    func testSender() throws {
        for c in try vector("typing").list("sender") {
            var s = TypingSender()
            var got = [[String]]()
            for step in c.list("steps") {
                let now = num(step["now"])
                var out: TypingSender.Out?
                switch step.str("type") {
                case "key": out = s.key(step.str("text")!, now: now, restored: (step["restored"] as? Bool) == true, editing: (step["editing"] as? Bool) == true)
                case "clear": out = s.cleared(now: now)
                default: s.sent()
                }
                if let out { got.append([out == .typing ? "typing" : "stop", String(now)]) }
            }
            let want = (c["expect"] as? [[Any]] ?? []).map { [$0[0] as! String, String(num($0[1]))] }
            XCTAssertEqual(got, want, c.str("note") ?? "")
        }
    }

    func testTags() {
        XCTAssertEqual(Typing.tags(group: "g", root: nil, stop: false), [["h", "g"]])
        XCTAssertEqual(Typing.tags(group: "g", root: "r", stop: true), [["h", "g"], ["e", "r"], ["status", "stop"]])
        XCTAssertEqual(Typing.dmTags(others: ["a", "b"], stop: false), [["p", "a"], ["p", "b"]])
        XCTAssertTrue(Typing.isStop([["status", "stop"]]))
        XCTAssertEqual(Typing.place(group: "g", root: "r"), "h:g/e:r")
    }
}
