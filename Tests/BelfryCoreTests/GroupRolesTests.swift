import Foundation
import XCTest
@testable import BelfryCore

// Roles in a group, check-ins, ticket codes in scans, the viewer block and the check-in API
// (SPEC 19.29, the belfry's contract of 2026-11-15).

private let ME = String(repeating: "a", count: 64)
private let ANA = String(repeating: "b", count: 64)
private let BEN = String(repeating: "c", count: 64)
private let GROUPS = String(repeating: "d", count: 64)
private let MALLORY = String(repeating: "e", count: 64)
private var n = 0

private func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
    n += 1
    return NostrEvent(id: String(format: "%064x", 90000 + n), pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
}

private func role(_ by: String, _ group: String, _ p: String, _ v: String, _ at: Int) -> NostrEvent {
    ev(by, 1985, at, [["L", Derive.groupRoleNS], ["l", v, Derive.groupRoleNS], ["p", p], ["h", group], ["by", ME]])
}

private func checkin(_ by: String, _ group: String, _ p: String, _ v: String, _ at: Int) -> NostrEvent {
    ev(by, 1985, at, [["L", Derive.ticketNS], ["l", v, Derive.ticketNS], ["p", p], ["h", group], ["by", ME]])
}

final class GroupRolesTests: XCTestCase {
    let d = "2026-abc123"
    var group: String { "ev-" + d }

    func world(_ extra: [NostrEvent]) -> Derive {
        var f = EventForm(title: "Picnic")
        f.start = 1_900_000_000
        f.end = f.start + 3 * 3600
        let made = EventActions.create(f, d: d, me: ME, groupsRelay: "wss://g", mainRelay: "wss://m").enumerated().map { i, dr in
            ev(ME, dr.kind, 1000 + i, dr.tags, dr.content)
        }
        let admins = ev(GROUPS, 39001, 1100, [["d", group], ["p", ME, "admin"]])
        return Derive(events: made + [admins] + extra, context: WorldContext(me: ME, groupsKey: GROUPS, timeZone: TimeZone(identifier: "UTC")!))
    }

    func testStewardsOnlyFromTheGroupsKeyLatestWins() {
        let dv = world([
            role(GROUPS, group, ANA, "steward", 2000),
            role(MALLORY, group, BEN, "steward", 2000),
            role(GROUPS, group, BEN, "steward", 2001),
            role(GROUPS, group, BEN, "none", 2002),
            // an admin is never a steward
            role(GROUPS, group, ME, "steward", 2003),
        ])
        XCTAssertEqual(dv.stewards(group), [ANA])
        XCTAssertEqual(dv.groupRole(group, ANA), .steward)
        XCTAssertEqual(dv.groupRole(group, BEN), .member)
        XCTAssertEqual(dv.groupRole(group, ME), .admin)
        // a steward label outside an event counts for nothing
        let ch = Derive(events: [role(GROUPS, "garden", ANA, "steward", 1)], context: WorldContext(me: ME, groupsKey: GROUPS))
        XCTAssertEqual(ch.groupRole("garden", ANA), .member)
        // without a known groups key nothing counts
        let unknown = Derive(events: [role(GROUPS, group, ANA, "steward", 1)], context: WorldContext(me: ME))
        XCTAssertTrue(unknown.stewards(group).isEmpty)
    }

    func testEventRolesAndWhoMayCheckIn() throws {
        let dv = world([role(GROUPS, group, ANA, "steward", 2000)])
        let e = try XCTUnwrap(dv.calendar.first)
        XCTAssertEqual(dv.eventRole(e, ME), .host)
        XCTAssertEqual(dv.eventRole(e, ANA), .steward)
        XCTAssertEqual(dv.eventRole(e, BEN), .attendee)
        XCTAssertTrue(dv.mayCheckIn(e))
        let ana = Derive(events: dv.events, context: WorldContext(me: ANA, groupsKey: GROUPS))
        XCTAssertTrue(ana.mayCheckIn(try XCTUnwrap(ana.calendar.first)))
        let ben = Derive(events: dv.events, context: WorldContext(me: BEN, groupsKey: GROUPS))
        XCTAssertFalse(ben.mayCheckIn(try XCTUnwrap(ben.calendar.first)))
        XCTAssertEqual(EventRole.cohost.groupRole, .admin)
        XCTAssertEqual(EventRole.attendee.groupRole, .member)
    }

    func testTheLatestAdminListWins() throws {
        // Ana made co-host, then made an attendee again: the relay's newer 39001 lists only me
        let dv = world([ev(GROUPS, 39001, 1200, [["d", group], ["p", ME, "admin"], ["p", ANA, "admin"]]),
                        ev(GROUPS, 39001, 1300, [["d", group], ["p", BEN, "admin"]])])
        let g = try XCTUnwrap(dv.group(group))
        // the creator (9007) stays an admin whatever the list says
        XCTAssertEqual(g.admins, [ME, BEN])
        let e = try XCTUnwrap(dv.calendar.first)
        XCTAssertEqual(dv.eventRole(e, ANA), .attendee)
        XCTAssertEqual(dv.eventRole(e, BEN), .cohost)
    }

    func testCheckInsLatestPerPersonByTheGroupsKey() {
        let dv = world([
            checkin(GROUPS, group, ANA, "checked-in", 3000),
            checkin(GROUPS, group, BEN, "checked-in", 3001),
            checkin(GROUPS, group, BEN, "not-checked-in", 3005),
            checkin(MALLORY, group, ME, "checked-in", 3010),
        ])
        XCTAssertEqual(dv.checkIns(group), [ANA: 3000])
    }

    func testOnEventDays() throws {
        let dv = world([])
        let e = try XCTUnwrap(dv.calendar.first)
        let day = dv.startOfDay(e.start)
        XCTAssertFalse(dv.onEventDays(e, now: day - 1))
        XCTAssertTrue(dv.onEventDays(e, now: day))
        XCTAssertTrue(dv.onEventDays(e, now: day + 86399))
        XCTAssertFalse(dv.onEventDays(e, now: day + 86400))
    }

    func testTicketCodeInAScan() {
        let code = "abcdefghijklmn23"
        XCTAssertEqual(TicketScan.code("https://chat.x.org/events/picnic/t/\(code)"), code)
        XCTAssertEqual(TicketScan.code("  https://chat.x.org/#/events/picnic/t/\(code)\n"), code)
        XCTAssertNil(TicketScan.code("https://chat.x.org/events/picnic/t/ABCDEFGHIJKLMN23"))
        XCTAssertNil(TicketScan.code("https://chat.x.org/events/picnic/t/abcdefghijklmn1"))
        XCTAssertNil(TicketScan.code("https://chat.x.org/join/\(code)"))
        XCTAssertNil(TicketScan.code(code))
        XCTAssertNil(TicketScan.code("javascript:/t/\(code)"))
        let u = TicketScan.eventLink(URL(string: "https://chat.x.org/events/picnic/t/\(code)")!)
        XCTAssertEqual(u?.domain, "x.org")
        XCTAssertEqual(u?.link, "picnic")
        XCTAssertEqual(u?.code, code)
        XCTAssertEqual(TicketScan.eventLink(URL(string: "https://chat.x.org/events/2026-abc123")!)?.code, nil)
        XCTAssertNil(TicketScan.eventLink(URL(string: "https://chat.x.org/events/picnic/x/\(code)")!))
        XCTAssertNil(TicketScan.eventLink(URL(string: "https://x.org/events/picnic")!))
    }

    func testViewerBlock() throws {
        let code = "abcdefghijklmn23"
        let json = """
        {"d":"2026-ab12cd","coord":"31923:\(ME):2026-ab12cd","kind":31923,"group":"ev-2026-ab12cd","link":"picnic","title":"Picnic","start":"2026-12-01T10:00:00Z",
         "me":{"host":false,"ticket":"2026-ab12cd:t1","applied":false,"waitlist":false,"declined":false,"rsvp":"accepted","member":true},
         "viewer":{"ticket_code":"\(code)","ticket_url":"https://chat.x.org/events/picnic/t/\(code)","checked_in":1800000000,"roles":["steward","admin"],"may_check_in":true}}
        """
        let a = try XCTUnwrap(BelfryAPI.parseEvent(try XCTUnwrap(JSON.parse(json) as? [String: Any])))
        let m = try XCTUnwrap(a.me)
        XCTAssertEqual(m.ticket, "2026-ab12cd:t1")
        XCTAssertEqual(m.ticketCode, code)
        XCTAssertEqual(m.ticketURL, "https://chat.x.org/events/picnic/t/\(code)")
        XCTAssertEqual(m.checkedIn, 1_800_000_000)
        XCTAssertEqual(m.roles, ["steward"])
        XCTAssertTrue(m.mayCheckIn)
        // a URL that does not end with the code is not used; a bad code drops both
        let bad = json.replacingOccurrences(of: "/t/\(code)\"", with: "/t/other\"")
        XCTAssertNil(BelfryAPI.parseEvent(try XCTUnwrap(JSON.parse(bad) as? [String: Any]))?.me?.ticketURL)
        // an older belfry: no viewer fields, nothing to show
        let old = """
        {"d":"2026-ab12cd","coord":"31923:\(ME):2026-ab12cd","group":"ev-2026-ab12cd","me":{"host":false,"ticket":null,"rsvp":null}}
        """
        let o = try XCTUnwrap(BelfryAPI.parseEvent(try XCTUnwrap(JSON.parse(old) as? [String: Any]))?.me)
        XCTAssertNil(o.ticketCode)
        XCTAssertFalse(o.mayCheckIn)
    }

    func testCheckInCalls() async throws {
        let api = BelfryAPI(config: .defaults(domain: "example.org"), signer: try LocalSigner(secret: Keys.generateSecret()), session: StubBelfry.session())
        StubBelfry.reset()
        StubBelfry.enqueue(200, #"{"people":[{"pubkey":"\#(ANA)","name":"Ana","ticket":"x:t1","ticket_title":"Seat","rsvp":"accepted","checked_in":null,"role":"member"},{"pubkey":"nope"}],"going":3,"checked_in":1}"#)
        let list = try await api.attendees(d: d)
        XCTAssertEqual(list.people.map(\.name), ["Ana"])
        XCTAssertEqual(list.going, 3)
        XCTAssertEqual(list.checkedIn, 1)
        let asked = try XCTUnwrap(StubBelfry.take())
        XCTAssertEqual(asked.url, "https://belfry.example.org/api/v1/events/\(d)/attendees")
        XCTAssertEqual(asked.method, "POST")

        StubBelfry.enqueue(200, #"{"person":{"pubkey":"\#(ANA)","name":"Ana","ticket":"x:t1","ticket_title":"Seat","checked_in":1800000000,"role":"member"},"already":true}"#)
        let r = try await api.checkIn(d: d, code: "abcdefghijklmn23")
        XCTAssertTrue(r.already)
        XCTAssertEqual(r.person.checkedIn, 1_800_000_000)
        let body = try XCTUnwrap(JSON.parse(try XCTUnwrap(StubBelfry.take()).body) as? [String: Any])
        XCTAssertEqual(body["code"] as? String, "abcdefghijklmn23")
        XCTAssertNil(body["undo"])

        // fixed messages per code; an older belfry (404 without its codes) needs an update
        StubBelfry.enqueue(404, #"{"error":"no_ticket"}"#)
        do { _ = try await api.checkIn(d: d, pubkey: BEN, undo: true); XCTFail() } catch let e as ApiError {
            XCTAssertEqual(e.code, "no_ticket"); XCTAssertEqual(e.message, "Not a ticket for this event")
        }
        let undoBody = try XCTUnwrap(JSON.parse(try XCTUnwrap(StubBelfry.take()).body) as? [String: Any])
        XCTAssertEqual(undoBody["undo"] as? Bool, true)
        XCTAssertEqual(undoBody["pubkey"] as? String, BEN)
        StubBelfry.enqueue(404, #"{"error":"not_found"}"#)
        do { _ = try await api.attendees(d: d); XCTFail() } catch let e as ApiError { XCTAssertEqual(e.message, "This belfry needs an update.") }
        _ = StubBelfry.take()
        StubBelfry.enqueue(404, "")
        do { _ = try await api.setGroupRole(channel: group, pubkey: ANA, role: .steward); XCTFail() } catch let e as ApiError { XCTAssertEqual(e.code, "update_needed") }
        _ = StubBelfry.take()
        StubBelfry.enqueue(409, #"{"error":"last_admin"}"#)
        do { _ = try await api.setGroupRole(channel: group, pubkey: ME, role: .member); XCTFail() } catch let e as ApiError {
            XCTAssertEqual(e.message, "Someone else must be an admin first.")
        }
        let roleBody = try XCTUnwrap(JSON.parse(try XCTUnwrap(StubBelfry.take()).body) as? [String: Any])
        XCTAssertEqual(roleBody["role"] as? String, "member")
        XCTAssertEqual(roleBody["channel"] as? String, group)
        StubBelfry.enqueue(200, #"{"role":"steward"}"#)
        let now = try await api.setGroupRole(channel: group, pubkey: ANA, role: .steward)
        XCTAssertEqual(now, .steward)
        XCTAssertEqual(try XCTUnwrap(StubBelfry.take()).url, "https://belfry.example.org/api/v1/group-roles")
    }
}
