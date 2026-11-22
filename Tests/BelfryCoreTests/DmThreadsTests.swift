import XCTest
@testable import BelfryCore

final class DmThreadsTests: XCTestCase {
    func testTheVectorsTag() throws {
        for c in try vector("one-shape").dict("dmReply").list("cases") {
            XCTAssertEqual(DmThreads.rootTag(c.str("root")!), c.strs("expectTag"), c.str("name")!)
            XCTAssertEqual(DmThreads.root([["p", "x"], DmThreads.rootTag(c.str("root")!)]), c.str("root"))
        }
    }

    func testARumorsRootIsRead() {
        let me = String(repeating: "a", count: 64), you = String(repeating: "b", count: 64)
        let r = GiftWrap.rumor(kind: 14, pubkey: you, tags: [["p", me], DmThreads.rootTag("abc")], content: "the reel", createdAt: 10)
        let d = DmReader.dm(from: r, me: me, bridge: nil, known: [])
        XCTAssertEqual(d?.root, "abc")
        let plain = GiftWrap.rumor(kind: 14, pubkey: you, tags: [["p", me], ["e", "abc"]], content: "q", createdAt: 11)
        XCTAssertNil(DmReader.dm(from: plain, me: me, bridge: nil, known: [])?.root)
    }

    func testRepliesGoUnderAKnownRootOnly() {
        func dm(_ id: String, _ at: Int, root: String? = nil) -> Dm {
            var d = Dm(rid: id, conv: "n:x", from: "x", mine: false, at: at, kind: 14, text: id)
            d.root = root
            return d
        }
        let s = DmThreads.split([dm("a", 1), dm("b", 2, root: "a"), dm("c", 3, root: "zz"), dm("d", 4, root: "b"), dm("e", 5, root: "a")])
        XCTAssertEqual(s.main.map(\.rid), ["a", "c", "d"])
        XCTAssertEqual(s.replies["a"]?.map(\.rid), ["b", "e"])
    }
}
