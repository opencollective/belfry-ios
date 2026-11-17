import Foundation
import XCTest
@testable import BelfryCore

// Channel categories (SPEC 19.34, vectors/categories.json).

private func cats(_ v: Any?) -> [ChannelCategory] {
    (v as? [[String: Any]] ?? []).map { ChannelCategory(id: $0.str("id") ?? "", name: $0.str("name") ?? "", channels: $0.strs("channels")) }
}

final class CategoriesTests: XCTestCase {
    func testRead() throws {
        let v = try vector("categories")
        for r in v.list("read") {
            let name = r.str("name") ?? ""
            let got = Categories.arrange(ChannelLayout.parse(r.str("content")), channels: r.strs("channels"))
            let want = cats(r["expected"])
            XCTAssertEqual(got.map(\.id), want.map(\.id), name)
            XCTAssertEqual(got.map(\.name), want.map(\.name), name)
            XCTAssertEqual(got.map(\.channels), want.map(\.channels), name)
            XCTAssertEqual(Categories.shown(got, admin: false).map(\.id), r.strs("shown_member"), name)
            XCTAssertEqual(Categories.shown(got, admin: true).map(\.id), r.strs("shown_admin"), name)
        }
    }

    func testWrite() throws {
        let v = try vector("categories")
        for w in v.list("write") {
            let name = w.str("name") ?? ""
            let got = Categories.encode(cats(w["categories"]), previous: ChannelLayout.parse(w.str("previous")), known: Set(w.strs("known")))
            let want = w.dict("expected")
            XCTAssertEqual(got["order"] as? [String], want.strs("order"), name)
            let gc = got["categories"] as? [[String: Any]] ?? []
            let wc = want.list("categories")
            XCTAssertEqual(gc.count, wc.count, name)
            for (g, x) in zip(gc, wc) {
                XCTAssertEqual(g.str("id"), x.str("id"), name)
                XCTAssertEqual(g.str("name"), x.str("name"), name)
                XCTAssertEqual(g.strs("channels"), x.strs("channels"), name)
            }
            // what was written reads back as the same arrangement
            let back = ChannelLayout.parse(JSON.encode(got))
            XCTAssertEqual(back.categories?.map(\.id), wc.map { $0.str("id") ?? "" }, name)
        }
    }

    func testFlatMoves() throws {
        let v = try vector("categories")
        for f in v.list("flat") {
            let flat = f.strs("flat").compactMap(CategoryRow.init(code:))
            let got = Categories.rebuild(cats(f["categories"]), flat: flat)
            let want = cats(f["expected"])
            XCTAssertEqual(got.map(\.id), want.map(\.id))
            XCTAssertEqual(got.map(\.channels), want.map(\.channels), f.str("name") ?? "")
        }
    }

    func testHelpers() {
        let base = [ChannelCategory(id: "life", name: "Community life", channels: ["a", "b"]),
                    ChannelCategory(id: "making-1234", name: "Making", channels: ["c"]),
                    ChannelCategory(id: "building", name: "Building together", channels: [])]
        XCTAssertEqual(Categories.put("a", in: "making-1234", base).map(\.channels), [["b"], ["c", "a"], []])
        XCTAssertEqual(Categories.put("new", in: "building", base).map(\.channels), [["a", "b"], ["c"], ["new"]])
        XCTAssertEqual(Categories.remove("making-1234", base).map(\.id), ["life", "building"])
        XCTAssertEqual(Categories.remove("making-1234", base).first?.channels, ["a", "b", "c"])
        XCTAssertEqual(Categories.remove("building", base).map(\.id), base.map(\.id), "built-ins stay")
        XCTAssertEqual(Categories.flat(base), [.header("life"), .channel("a"), .channel("b"), .header("making-1234"), .channel("c"), .header("building")])
        let id = Categories.newId("Making & mending!")
        XCTAssertTrue(id.hasPrefix("making-mending-"), id)
        XCTAssertEqual(id.count, "making-mending-".count + 4)
        XCTAssertTrue(Categories.newId("???").hasPrefix("category-"))
    }

    func testDeriveReadsOnlyAdmins() {
        let admin = String(repeating: "b", count: 64), other = String(repeating: "c", count: 64), relay = String(repeating: "d", count: 64)
        var n = 0
        func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
            n += 1
            return NostrEvent(id: String(format: "%064x", 7000 + n), pubkey: pk, createdAt: at, kind: kind, tags: tags, content: content)
        }
        var evs = ["general", "garden", "kitchen", "proposals"].map { ev(relay, 39000, 100, [["d", $0], ["name", $0]]) }
        evs.append(ev(admin, 30078, 200, [["d", "belfry:channel-order"]], #"{"order":["general","kitchen","garden"],"categories":[{"id":"food-aaaa","name":"Food","channels":["kitchen"]}]}"#))
        evs.append(ev(other, 30078, 300, [["d", "belfry:channel-order"]], #"{"order":[],"categories":[{"id":"x-bbbb","name":"X","channels":["garden"]}]}"#))
        let d = Derive(events: evs, me: other, communityAdmins: [admin])
        let c = d.channelCategories()
        XCTAssertEqual(c.map(\.id), ["life", "food-aaaa", "building"])
        XCTAssertEqual(c.map(\.channels), [["garden"], ["kitchen"], ["proposals"]])
        // the flattened order still reads for older clients
        XCTAssertEqual(d.channelOrder(), ["general", "kitchen", "garden"])
    }
}
