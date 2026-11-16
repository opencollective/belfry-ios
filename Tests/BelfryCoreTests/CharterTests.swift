import Foundation
import XCTest
@testable import BelfryCore

// The town's names (SPEC 19.31) and the charter (SPEC 19.32, vectors/charter.json).

final class CharterTests: XCTestCase {
    func testVectors() throws {
        let v = try vector("charter")
        XCTAssertEqual(Derive.listIdFor(Derive.charterId), v.str("list_id"))
        let evs = try events(v["events"])
        let admins = Set(v.strs("admins"))
        let got = Derive.parseCharter(evs, admins: admins)
        let want = v.list("expected")
        XCTAssertEqual(got.map(\.id), want.map { $0.str("id") ?? "" })
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.title, w.str("title"))
            XCTAssertEqual(g.about, w.str("about"))
            XCTAssertEqual(g.order, w.int("order"))
            XCTAssertEqual(g.textAt, w.int("textAt"))
            let agreed = (w["agreed"] as? [String: Any] ?? [:]).mapValues { ($0 as? NSNumber)?.intValue ?? 0 }
            XCTAssertEqual(g.agreed, agreed, g.title)
            XCTAssertEqual(g.stale, Set(w.strs("stale")), g.title)
        }
        let me = try XCTUnwrap(v.str("me"))
        let d = Derive(events: evs, context: WorldContext(me: me, communityAdmins: admins))
        XCTAssertEqual(d.charterToAgree().map(\.id), v.strs("me_to_agree"))
        XCTAssertEqual(d.charterAgreedAt(), v.int("me_agreed_at"))
    }

    func testActions() {
        let add = Actions.addAgreement(title: "  Be kind ", about: "", order: 3)
        XCTAssertEqual(add.kind, 2100)
        XCTAssertEqual(add.content, "Be kind")
        XCTAssertTrue(add.tags.contains(["each", "1"]))
        XCTAssertTrue(add.tags.contains(["h", "charter"]))
        XCTAssertTrue(add.tags.contains(["order", "3"]))
        XCTAssertFalse(add.tags.contains { $0.first == "about" })
        let tick = Actions.agree("x", true)
        XCTAssertEqual(tick.kind, 2101)
        XCTAssertTrue(tick.tags.contains(["action", "done"]))
        XCTAssertTrue(Actions.agree("x", false).tags.contains(["action", "undone"]))
        let edit = Actions.editAgreement("x", title: "Be kind", about: "Always", order: 1)
        XCTAssertTrue(edit.tags.contains(["action", "edit"]))
        XCTAssertTrue(edit.tags.contains(["about", "Always"]))
        XCTAssertEqual(Actions.createCharter().map(\.kind), [9007, 9002])
    }

    func testPlaceNames() {
        XCTAssertEqual(PlaceNames.display(id: "general", name: "general"), "Square")
        XCTAssertEqual(PlaceNames.display(id: "general", name: ""), "Square")
        XCTAssertEqual(PlaceNames.display(id: "events", name: "#Events"), "Fairground")
        XCTAssertNil(PlaceNames.display(id: "general", name: "Town square"))
        XCTAssertNil(PlaceNames.display(id: "garden-3f2a", name: "garden-3f2a"))
        XCTAssertEqual(PlaceNames.section("general"), .town)
        XCTAssertEqual(PlaceNames.section("proposals"), .building)
        XCTAssertEqual(PlaceNames.section("garden-3f2a"), .life)
        let meta = NostrEvent(id: String(repeating: "1", count: 64), pubkey: String(repeating: "d", count: 64), createdAt: 1, kind: 39000,
                              tags: [["d", "general"], ["name", "general"]], content: "")
        var ctx = WorldContext(me: String(repeating: "a", count: 64))
        XCTAssertEqual(Derive(events: [meta], context: ctx).group("general")?.name, "general")
        ctx.placeNames = true
        XCTAssertEqual(Derive(events: [meta], context: ctx).group("general")?.name, "Square")
    }

    func testCharterIsNoChannel() {
        let relay = String(repeating: "d", count: 64)
        let evs = [
            NostrEvent(id: String(repeating: "1", count: 64), pubkey: relay, createdAt: 1, kind: 39000, tags: [["d", "general"], ["name", "general"]], content: ""),
            NostrEvent(id: String(repeating: "2", count: 64), pubkey: relay, createdAt: 2, kind: 39000, tags: [["d", "charter"], ["name", "Charter"]], content: ""),
        ]
        let d = Derive(events: evs, context: WorldContext(me: String(repeating: "a", count: 64)))
        let s = d.channelSections()
        XCTAssertFalse((s.pub + s.members).contains { $0.id == "charter" })
        XCTAssertNotNil(d.charterGroup)
    }
}
