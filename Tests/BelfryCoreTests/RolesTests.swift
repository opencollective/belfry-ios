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

final class TodoWorkingTests: XCTestCase {
    func testHeartbeatAndStretch() {
        let me = String(repeating: "a", count: 64)
        let list = Derive.listIdFor("general")
        var n = 0
        func ev(_ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
            n += 1
            return NostrEvent(id: String(format: "%064x", 8000 + n), pubkey: me, createdAt: at, kind: kind, tags: tags, content: c)
        }
        let t = ev(2100, 100, [["t", list], ["h", "general"]], "Fix the gate")
        let evs = [t,
                   ev(2101, 110, [["t", list], ["e", t.id], ["action", "claim"]]),
                   ev(2101, 120, [["t", list], ["e", t.id], ["action", "working"]]),
                   ev(2101, 300, [["t", list], ["e", t.id], ["action", "working"]]),
                   ev(2101, 2000, [["t", list], ["e", t.id], ["action", "working"]])]
        let d = Derive(events: evs, me: me)
        let task = d.tasks("general")[0]
        XCTAssertEqual(task.beat, 2000)
        XCTAssertEqual(task.workingSince, 2000) // a gap over 5 minutes starts a new stretch
        XCTAssertTrue(task.isWorking(now: 2100))
        XCTAssertFalse(task.isWorking(now: 2400))
    }
}

final class WebsiteProposalTests: XCTestCase {
    func testWebsiteTagsAndPreview() {
        let me = String(repeating: "a", count: 64)
        let npub = Bech32.npub(String(repeating: "c", count: 64))!
        let ref = "nsite:\(npub)/spring"
        let (group, drafts) = Actions.createProposal(NewProposal(title: "A new version of the website", status: .feedback, website: ref),
                                                     parent: "website", me: me, groupsRelay: "wss://g", mainRelay: "wss://m", now: 100, x: "abc123")
        XCTAssertTrue(group.hasPrefix("prop-"))
        let article = drafts.first { $0.kind == 30023 }!
        XCTAssertTrue(article.tags.contains(["website", ref]))
        XCTAssertTrue(article.tags.contains(["t", "website"]))
        XCTAssertTrue(drafts.first { $0.kind == 9 }!.tags.contains(["website", ref]))
        XCTAssertEqual(websitePreviewLink(ref, domain: "x.org"), "https://preview.x.org/p/\(npub)@spring")
        XCTAssertNil(websitePreviewLink("https://evil", domain: "x.org"))
    }
}

final class ChannelLogTests: XCTestCase {
    func testWords() {
        let pk = String(repeating: "b", count: 64)
        func words(_ kind: Int, _ tags: [Tag], _ c: String = "") -> String? {
            let e = NostrEvent(id: String(repeating: "1", count: 64), pubkey: pk, createdAt: 100, kind: kind, tags: [["h", "g"]] + tags, content: c)
            return ChannelLog.item(e, titles: [:], name: { _ in "X" }).map { $0.icon + " " + $0.text }
        }
        XCTAssertEqual(words(9, [], "Hello   there"), "💬 posted a message")
        XCTAssertEqual(words(9, [["pod", "pod-x"]]), "⬡ created a group")
        XCTAssertEqual(words(9, [["imeta", "url https://x/a.jpg", "m image/jpeg"], ["imeta", "url https://x/b.jpg", "m image/png"]]), "🖼 posted 2 photos")
        XCTAssertEqual(words(9, [["imeta", "url https://x/a.m4a", "m audio/mp4"]]), "🎙 posted a recording")
        XCTAssertEqual(words(7, [["e", "m1"]], "+"), "👍 reacted")
        XCTAssertEqual(words(7, [["e", "m1"]], "🎉"), "🎉 reacted")
        XCTAssertEqual(words(5, [["e", "r"], ["k", "7"]]), "🗑 took back a reaction")
        XCTAssertEqual(words(2101, [["e", "t"], ["action", "done"]]), "✅ marked a todo done")
        XCTAssertNil(words(2101, [["e", "t"], ["action", "working"]]))
        XCTAssertNil(words(30078, [["d", "seen:g"]]))
        XCTAssertEqual(words(9000, [["p", pk, "admin"]]), "👋 made someone an admin")
        XCTAssertEqual(words(1985, [["L", "#t"], ["l", "x", "#t"]]), "# changed the pinned topics")
        XCTAssertEqual(words(31923, [["t", "meeting"]]), "👥 set the meeting")
        XCTAssertEqual(words(31925, [["status", "declined"]]), "📅 answered can't go")
        XCTAssertEqual(words(4242, []), "• kind 4242")
        XCTAssertEqual(ChannelLog.short("a  b\n c", 80), "a b c")
        XCTAssertEqual(ChannelLog.short(String(repeating: "x", count: 100), 10), String(repeating: "x", count: 9) + "…")
    }
}

final class DirectoryTests: XCTestCase {
    func testParse() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64)
        let d = BelfryAPI.parseDirectory(["members": [["pubkey": a, "name": "Ana", "role": "host"], ["pubkey": "bad"]],
                                          "agents": [b: a, c: "nope"], "names": [b: "Scout"]])
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].role, "host")
        XCTAssertEqual(d[0].agents.map(\.name), ["Scout"])
    }
}
