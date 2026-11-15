import Foundation
import XCTest
@testable import BelfryCore

// Roles, member links and the invite sheet's choices (docs/roles.md, web invite.ts / roles.ts).

final class RolesTests: XCTestCase {
    func testInviteBodies() {
        let g = JoinsAs.guest(days: 7).body(channel: "general", people: 50, linkDays: 30)
        XCTAssertEqual(g["guest_days"] as? Int, 7)
        XCTAssertEqual(g["people"] as? Int, 50)
        XCTAssertEqual(g["link_days"] as? Int, 30)
        XCTAssertNil(g["as"])
        let a = JoinsAs.agent.body(channel: "general", people: 50, linkDays: 1)
        XCTAssertEqual(a["agent"] as? Bool, true)
        XCTAssertEqual(a["people"] as? Int, 1)
        let m = JoinsAs.member(role: "host", membership: "year").body(channel: "general", people: 50, linkDays: 7)
        XCTAssertEqual(m["as"] as? String, "member")
        XCTAssertEqual(m["role"] as? String, "host")
        XCTAssertEqual(m["membership"] as? String, "year")
        XCTAssertEqual(m["people"] as? Int, 50)
        // an admin link is for one person
        XCTAssertEqual(JoinsAs.member(role: "admin", membership: "permanent").body(channel: "x", people: 50, linkDays: 1)["people"] as? Int, 1)
        XCTAssertEqual(JoinsAs.guest(days: 3).body(channel: "x", people: 2, linkDays: 5)["guest_days"] as? Int, 1)
    }

    func testLines() {
        let roles = RolesInfo(roles: Role.builtins + [Role(id: "host", label: "Host")])
        XCTAssertEqual(JoinsAs.guest(days: 1).line(channel: "#general", community: "Riverside", roles: roles).0, "Guest for a day")
        XCTAssertEqual(JoinsAs.member(role: "host", membership: "month").line(channel: "#general", community: "Riverside", roles: roles).0, "Host · one month")
        XCTAssertEqual(JoinsAs.member(role: "host", membership: "permanent").line(channel: "#general", community: "Riverside", roles: roles).1,
                       "A member of Riverside, starting in #general")
    }

    func testParseRoles() {
        let k = String(repeating: "a", count: 64)
        let b: [String: Any] = [
            "roles": [["id": "admin", "label": "Admin", "builtin": true, "powers": true],
                      ["id": "host", "label": "Host", "description": "Opens the door"],
                      ["id": "member", "label": "Neighbour", "builtin": true]],
            "default": "host", "members": [k: "host", "bad": "member"],
        ]
        let r = RolesInfo.parse(b)
        XCTAssertEqual(r.roles.map(\.id), ["member", "host", "admin"])
        XCTAssertEqual(r.defaultRole, "host")
        XCTAssertEqual(r.roles.first { $0.isDefault }?.id, "host")
        XCTAssertEqual(r.label(of: k), "Host")
        XCTAssertEqual(r.members.count, 1)
        XCTAssertEqual(RolesInfo.parse(["default": "admin"]).defaultRole, "member")
        XCTAssertEqual(RolesInfo.parse([:]).roles.map(\.id), ["member", "admin"])
    }

    func testMembership() {
        let m = MembershipSettings.parse(["invite": "members", "accept": "vouches", "vouches": 9, "may_invite_members": true])
        XCTAssertEqual(m.invite, "members")
        XCTAssertEqual(m.vouches, 5)
        XCTAssertTrue(m.mayInviteMembers)
        XCTAssertEqual(MembershipSettings.parse([:]).invite, "admins")
    }
}

final class RequestsTests: XCTestCase {
    func testParse() {
        let k = String(repeating: "b", count: 64)
        let p = BelfryAPI.parseRequests([["id": 1, "name": "Nora", "motivation": "<b>hi</b>", "vouches": 1, "vouched": true, "email": "n@x.org"], ["name": "no id"]])
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].motivation, "<b>hi</b>")
        XCTAssertTrue(p[0].vouched)
        let a = BelfryAPI.parseAgentRequests([["id": 7, "pubkey": k, "name": "Scout", "for_me": true], ["id": 8, "pubkey": "nope"]])
        XCTAssertEqual(a.map(\.id), [7])
        XCTAssertTrue(a[0].forMe)
    }

    func testGroupVouches() {
        let me = String(repeating: "a", count: 64), ben = String(repeating: "b", count: 64), lou = String(repeating: "c", count: 64)
        let admin = String(repeating: "e", count: 64)
        var n = 0
        func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
            n += 1
            return NostrEvent(id: String(format: "%064x", 7000 + n), pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
        }
        let ask = ev(lou, 9021, 300, [["h", "pod-x-1234"]], "I grow beans")
        let events = [
            ev(admin, 9007, 100, [["h", "pod-x-1234"]]),
            ev(admin, 9002, 110, [["h", "pod-x-1234"], ["closed"], ["vouches", "2"]]),
            ev(admin, 9000, 120, [["h", "pod-x-1234"], ["p", me]]),
            ev(admin, 9000, 120, [["h", "pod-x-1234"], ["p", ben]]),
            ask,
            ev(ben, 1985, 400, Actions.vouch("pod-x-1234", requestId: ask.id, applicant: lou).tags),
            ev(me, 1985, 410, Actions.vouch("pod-x-1234", requestId: ask.id, applicant: lou).tags),
            ev(me, 1985, 420, Actions.vouch("pod-x-1234", requestId: ask.id, applicant: lou, on: false).tags),
        ]
        let d = Derive(events: events, me: me)
        let g = d.group("pod-x-1234")!
        XCTAssertEqual(g.vouches, 2)
        XCTAssertEqual(d.groupRequestsFor(g).map(\.pubkey), [lou])
        XCTAssertEqual(d.vouchesFor(g, d.groupRequestsFor(g)[0]), [ben])
        XCTAssertEqual(d.groupRequestCount(), 1)
    }
}
