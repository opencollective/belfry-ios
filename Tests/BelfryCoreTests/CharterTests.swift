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
        XCTAssertEqual(PlaceNames.display(id: "general", name: "general"), "Townsquare")
        XCTAssertEqual(PlaceNames.display(id: "general", name: ""), "Townsquare")
        XCTAssertNil(PlaceNames.display(id: "events", name: "#Events")) // own name since 2026-11-17
        XCTAssertNil(PlaceNames.display(id: "proposals", name: "proposals"))
        XCTAssertNil(PlaceNames.display(id: "website", name: ""))
        XCTAssertEqual(PlaceNames.wire(id: "general", name: "Townsquare"), "general")
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
        XCTAssertEqual(Derive(events: [meta], context: ctx).group("general")?.name, "Townsquare")
    }

    func testPlaceNamesVectors() throws {
        let v = try vector("placenames")
        XCTAssertEqual(v.dict("names") as? [String: String], PlaceNames.defaults)
        for c in v.list("display") {
            let id = c.str("id") ?? "", name = c.str("name") ?? ""
            XCTAssertEqual(PlaceNames.display(id: id, name: name), c.str("expected"), "\(id) / \(name)")
        }
        for c in v.list("wire") {
            XCTAssertEqual(PlaceNames.wire(id: c.str("id") ?? "", name: c.str("name") ?? ""), c.str("expected"))
        }
        XCTAssertEqual(v.strs("fixed_rows"), [PlaceNames.defaults[generalId]!, PlaceNames.members, "Charter"])
    }

    func testChannelContent() {
        let h = String(repeating: "c", count: 64)
        func e(_ kind: Int, _ tags: [Tag]) -> NostrEvent {
            NostrEvent(id: String(repeating: "\(kind % 10)", count: 64), pubkey: h, createdAt: 1, kind: kind, tags: tags, content: "")
        }
        let general = e(39000, [["d", "general"]])
        XCTAssertEqual(ChannelContent.empty("tools", answer: [general]), true)
        XCTAssertNil(ChannelContent.empty("tools", answer: []))
        XCTAssertEqual(ChannelContent.empty("tools", answer: [general, e(9, [["h", "tools"]])]), false)
        XCTAssertEqual(ChannelContent.empty("tools", answer: [general, e(9, [["h", "other"]])]), true)
        // metadata, roles, labels and reactions are no content
        let d = Derive(events: [e(9002, [["h", "tools"]]), e(1985, [["h", "tools"]]), e(7, [["h", "tools"]])], me: h)
        XCTAssertFalse(d.hasContent("tools"))
        XCTAssertTrue(Derive(events: [e(1111, [["h", "tools"]])], me: h).hasContent("tools"))
        XCTAssertEqual(Actions.deleteGroup("tools").kind, 9008)
        XCTAssertEqual(Actions.deleteGroup("tools").tags, [["h", "tools"]])
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
