import XCTest
@testable import BelfryCore

/// Someone removed who never wrote shows nowhere; one who wrote shows only as the author of
/// their messages (the lead, 2026-11-22: a belfry showed seven removed guests of the same name).
final class RemovedPeopleTests: XCTestCase {
    let me = String(repeating: "a", count: 64)
    let gk = String(repeating: "9", count: 64)
    let ghost = String(repeating: "e", count: 64)
    let wrote = String(repeating: "d", count: 64)
    let stays = String(repeating: "c", count: 64)
    let back = String(repeating: "b", count: 64)

    private func ev(_ pubkey: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
        var e = NostrEvent(pubkey: pubkey, createdAt: at, kind: kind, tags: tags, content: content)
        e.id = Crypto.sha256(Data("\(pubkey)\(kind)\(at)\(tags)\(content)".utf8)).hex
        return e
    }

    func testRemovedPeopleAreInNoListAndHaveNoJoinLine() {
        func join(_ p: String, _ at: Int) -> NostrEvent { ev(gk, 9000, at, [["h", "general"], ["p", p, "member"], ["invited-by", me], ["name", "Marcel"]]) }
        func out(_ p: String, _ at: Int) -> NostrEvent { ev(gk, 9001, at, [["h", "general"], ["p", p]]) }
        func profile(_ p: String, _ name: String) -> NostrEvent { ev(p, 0, 50, [], "{\"name\":\"\(name)\"}") }
        let events = [
            ev(gk, 39000, 10, [["d", "general"], ["name", "general"]]),
            join(ghost, 100), out(ghost, 110), profile(ghost, "Marcel"),
            join(wrote, 120), ev(wrote, 9, 125, [["h", "general"]], "hello"), out(wrote, 130), profile(wrote, "Marcel"),
            join(stays, 140), profile(stays, "Marcel"),
            join(back, 150), out(back, 160), join(back, 170), profile(back, "Bea"),
        ]
        let d = Derive(events: events, context: WorldContext(me: me, groupsKey: gk))
        XCTAssertEqual(d.removed, [ghost, wrote])
        // the pickers and people lists: only who is still here
        XCTAssertEqual(Set(d.people.map(\.pubkey)), [stays, back])
        // join lines: the one who stays, and the one who came back (at their latest join); none for
        // the removed ones, whether or not they wrote
        XCTAssertEqual(d.guestJoins("general").map(\.pubkey), [stays, back])
        XCTAssertEqual(d.guestJoins("general").last?.at, 170)
        // what the removed one wrote stays, under their name
        XCTAssertEqual(d.messages("general").map(\.ev.pubkey), [wrote])
        XCTAssertEqual(d.profiles()[wrote]?.name, "Marcel")
    }

    func testSomeoneStillInAnotherGroupIsNotRemoved() {
        let events = [
            ev(gk, 39000, 10, [["d", "general"], ["name", "general"]]),
            ev(gk, 39000, 10, [["d", "garden"], ["name", "garden"]]),
            ev(gk, 9000, 100, [["h", "general"], ["p", ghost, "member"]]),
            ev(gk, 9000, 101, [["h", "garden"], ["p", ghost, "member"]]),
            ev(gk, 9001, 110, [["h", "general"], ["p", ghost]]),
        ]
        let d = Derive(events: events, context: WorldContext(me: me, groupsKey: gk))
        XCTAssertTrue(d.removed.isEmpty)
    }
}
