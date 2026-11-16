import Foundation
import XCTest
@testable import BelfryCore

// E-mail threads in a channel (SPEC 19.33, vectors/mailthreads.json) and the channel's address.

final class MailInboxTests: XCTestCase {
    func testThreadsVector() throws {
        let v = try vector("mailthreads")
        let group = try XCTUnwrap(v.str("group"))
        let d = Derive(events: try events(v["events"]), context: WorldContext(me: v.str("me") ?? "", groupsKey: v.str("groups_key")))
        let got = d.mailThreads(group).list
        let want = v.list("threads")
        XCTAssertEqual(got.map(\.id), want.map { $0.str("id") ?? "" })
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.ids, w.strs("ids"))
            XCTAssertEqual(g.address, w.str("address"))
            XCTAssertEqual(g.name, w.str("name"))
            XCTAssertEqual(g.subject, w.str("subject"))
            XCTAssertEqual(g.state.status.rawValue, w.str("status"))
            XCTAssertEqual(g.state.answered, w.int("answered"))
            XCTAssertEqual(g.state.assignee, w.str("assignee"))
            XCTAssertEqual(g.replies, w.int("replies"))
            XCTAssertEqual(g.who, w.strs("who"))
            XCTAssertEqual(g.last, w.int("last"))
            XCTAssertEqual(g.refs, w.strs("refs"))
            XCTAssertEqual(g.lastIn?.m.id, w.str("lastIn"))
        }
        XCTAssertEqual(d.feed(group).map(\.id), v.strs("feed"))
        // without the groups key nothing is an e-mail from outside
        let none = Derive(events: try events(v["events"]), context: WorldContext(me: v.str("me") ?? ""))
        XCTAssertTrue(none.mailThreads(group).list.isEmpty)
    }

    func testMailLocal() {
        let admin = String(repeating: "a", count: 64), other = String(repeating: "c", count: 64), relay = String(repeating: "d", count: 64)
        var n = 0
        func ev(_ pk: String, _ kind: Int, _ tags: [Tag]) -> NostrEvent {
            n += 1
            return NostrEvent(id: String(format: "%064x", 60000 + n), pubkey: pk, createdAt: n, kind: kind, tags: tags, content: "")
        }
        let evs = [
            ev(relay, 39000, [["d", "hello-79f0"], ["name", "Hello"]]), ev(admin, 9007, [["h", "hello-79f0"]]),
            ev(relay, 39000, [["d", "bugs-c3e5"], ["name", "Bugs"]]), ev(other, 9007, [["h", "bugs-c3e5"]]),
            ev(relay, 39000, [["d", "team-aaaa"], ["name", "Team"]]), ev(admin, 9007, [["h", "team-aaaa"]]),
            ev(relay, 39000, [["d", "team-bbbb"], ["name", "Team"]]), ev(admin, 9007, [["h", "team-bbbb"]]),
            ev(relay, 39000, [["d", "general"], ["name", "general"]]),
        ]
        var ctx = WorldContext(me: admin, domain: "x.org", communityAdmins: [admin])
        ctx.placeNames = true
        let d = Derive(events: evs, context: ctx)
        XCTAssertEqual(d.mailLocal("hello-79f0"), "hello")
        XCTAssertEqual(d.channelAddress("hello-79f0"), "hello@x.org")
        XCTAssertEqual(d.mailLocal("bugs-c3e5"), "bugs-c3e5") // not made by an admin
        XCTAssertEqual(d.mailLocal("team-aaaa"), "team-aaaa") // two answer to "team"
        XCTAssertEqual(d.mailLocal("general"), "general")
        XCTAssertEqual(Derive.slugify("Café Été!"), "cafe-ete")
    }

    func testApplyStatus() {
        let s = ApplyStatus.parse(["application": ["id": 3, "state": "new", "vouches": 1, "needed": 2, "vouched_by": [["pubkey": "x", "name": "Dev"]]],
                                   "until": 1700000000, "accept": "vouches"])
        XCTAssertEqual(s.line, "1 of 2 vouches")
        XCTAssertEqual(s.application?.vouchedBy.first?.name, "Dev")
        XCTAssertEqual(s.until, 1700000000)
        XCTAssertEqual(ApplyStatus.parse(["application": ["state": "declined"]]).line, "Not this time")
        XCTAssertNil(ApplyStatus.parse(["application": NSNull()]).application)
        let list = PublicAgreement.parseList(["agreements": [["id": String(repeating: "1", count: 64), "title": "Be kind", "about": "", "order": NSNull(), "added": 5, "text_at": 7],
                                                             ["id": "bad", "title": "x"]]])
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].order)
        XCTAssertEqual(list[0].agreement.textAt, 7)
    }
}
