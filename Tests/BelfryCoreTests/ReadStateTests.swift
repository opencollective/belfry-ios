import Foundation
import XCTest
@testable import BelfryCore

/// Every case of vectors/readstate.json (SPEC 19.27), as Android's ReadStateVectorsTest.
final class ReadStateTests: XCTestCase {
    func st(_ x: Any?) -> ReadState { ReadState.parse(object: x ?? [:]) }

    func testEveryCase() throws {
        let cases = try vector("readstate").list("cases")
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        var ops = Set<String>()
        for c in cases {
            let name = c.str("name")!, op = c.str("op")!
            ops.insert(op)
            switch op {
            case "merge": XCTAssertEqual(ReadState.merge(st(c["local"]), st(c["remote"])).serialize(), st(c["expect"]).serialize(), name)
            case "parse": XCTAssertEqual(ReadState.parse(c.str("input")!).serialize(), st(c["expect"]).serialize(), name)
            case "serialize": XCTAssertEqual(st(c["input"]).serialize(), c.str("expect_text"), name)
            case "readUpTo":
                let s = st(c["state"])
                for q in c.list("queries") {
                    XCTAssertEqual(s.readUpTo(Character(q.str("sec")!), q.str("key")!, now: c.int("now")!), q.int("expect"), name)
                }
            case "mark":
                var s = st(c["state"])
                for step in c.list("steps") { s = s.mark(Character(step.str("sec")!), step.str("key")!, step.int("at")!) }
                XCTAssertEqual(s.serialize(), st(c["expect"]).serialize(), name)
            case "prune":
                let got = st(c["state"]).prune(now: c.int("now")!)
                XCTAssertEqual(got.serialize(), st(c["expect"]).serialize(), name)
                if let n = c["expect_counts"] as? [String: Any] {
                    XCTAssertEqual(got.c.count, n.int("c"), name)
                    XCTAssertEqual(got.d.count, n.int("d"), name)
                    XCTAssertEqual(got.s, n.int("s"), name)
                }
            case "covers": XCTAssertEqual(ReadState.covers(st(c["remote"]), st(c["local"]), now: c.int("now")!), c["expect"] as? Bool, name)
            default: XCTFail("unknown op \(op)")
            }
        }
        XCTAssertEqual(ops, ["merge", "parse", "serialize", "readUpTo", "mark", "prune", "covers"])
    }

    func testRoundTrip() {
        let s = ReadState(s: 5, m: 6, c: ["b": 2, "a": 1], extra: ["q": "\"x\""])
        XCTAssertEqual(s.serialize(), #"{"q":"x","v":1,"s":5,"m":6,"c":{"a":1,"b":2},"t":{},"d":{}}"#)
        XCTAssertEqual(ReadState.parse(s.serialize()).serialize(), s.serialize())
    }
}
