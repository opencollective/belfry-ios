import Foundation
import XCTest
@testable import BelfryCore

// Meetings (web core/meetings.ts, SPEC 19.23): the drafts, the tags kept on every version,
// attendance, the people line, suggestions, the meeting-guests call with its retries.

private let ME = String(repeating: "a", count: 64)
private let ANA = String(repeating: "b", count: 64)
private let BEN = String(repeating: "c", count: 64)
private let LOU = String(repeating: "e", count: 64)
private let RELAY = String(repeating: "f", count: 64)
private var counter = 0

/// Drafts signed (made up) by WHO at AT, in order.
private func events(_ drafts: [Draft], by who: String = ME, at: Int) -> [NostrEvent] {
    drafts.enumerated().map { i, d in
        counter += 1
        return NostrEvent(id: String(format: "%064x", 60000 + counter), pubkey: who, createdAt: at + i, kind: d.kind, tags: d.tags, content: d.content)
    }
}

private func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
    counter += 1
    return NostrEvent(id: String(format: "%064x", 60000 + counter), pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
}

final class MeetingsTests: XCTestCase {
    let d = "2026-abc123"
    let start = 1_900_000_000

    func made() -> [NostrEvent] {
        var m = MeetingForm(topic: "  Plan the garden day ", start: start)
        m.people = [ANA, ME, ANA, "nope"]
        m.minutes = 45
        m.place = "The shed"
        return events(Meetings.create(m, channel: "garden-3f2a", d: d, me: ME, groupsRelay: "wss://g"), at: 1000)
    }

    func testCreate() {
        let evs = made()
        XCTAssertEqual(evs.map(\.kind), [9007, 9002, 31923, 9000])
        XCTAssertTrue(evs[1].hasTag("closed"))
        let e = evs[2]
        XCTAssertEqual(e.tag("title"), "Plan the garden day")
        XCTAssertEqual(e.tag("visibility"), "members")
        XCTAssertEqual(e.tag("end"), String(start + 45 * 60))
        XCTAssertTrue(e.hasTag("t", "meeting"))
        XCTAssertEqual(e.tag("channel"), "garden-3f2a")
        XCTAssertEqual(e.tags.filter { $0.count >= 4 && $0[3] == "invited" }.map { $0[1] }, [ANA])
        XCTAssertNil(e.tag("slug"))
        XCTAssertEqual(evs[3].tags, [["h", "ev-" + d], ["p", ANA, "member"]])

        let dv = Derive(events: evs, me: ME)
        let cal = try! XCTUnwrap(dv.calendar.first)
        XCTAssertTrue(cal.meeting)
        XCTAssertEqual(cal.invited, [ANA])
        XCTAssertEqual(cal.originChannel, "garden-3f2a")
        // Ana sees it in her events
        XCTAssertEqual(Derive(events: evs, me: ANA).yourEvents(now: start - 3600).map(\.d), [d])
    }

    func testEditKeepsMeetingTags() {
        let evs = made()
        let cal = Derive(events: evs, me: ME).calendar[0]
        var f = EventForm(title: "Garden day, renamed")
        f.start = start
        let drafts = EventActions.edit(cal, f, group: nil, groupsRelay: "wss://g")
        let v = drafts[0]
        XCTAssertTrue(v.tags.contains(["t", "meeting"]))
        XCTAssertTrue(v.tags.contains(["channel", "garden-3f2a"]))
        XCTAssertTrue(v.tags.contains(["p", ANA, "", "invited"]))
        // invite more: chat first, then one new version with all the invited
        let more = Meetings.invite(cal, [ANA, BEN, BEN])
        XCTAssertEqual(more.map(\.kind), [9000, 31923])
        let after = Derive(events: evs + events(more, at: 2000), me: ME).calendar[0]
        XCTAssertEqual(after.invited, [ANA, BEN])
        XCTAssertTrue(Meetings.invite(after, [ANA]).isEmpty)
    }

    func testAttendanceAndPeople() {
        var evs = made()
        let cal0 = Derive(events: evs, me: ME).calendar[0]
        evs += events([Meetings.checkIn(cal0, pubkey: ANA, on: true)], at: 3000)
        // not a host: doesn't count
        evs.append(ev(BEN, 1985, 3100, Meetings.checkIn(cal0, pubkey: ANA, on: false).tags))
        evs.append(ev(BEN, 31925, 3200, [["a", cal0.coord], ["status", "tentative"]]))
        // a name-only account I made, put in the chat by the groups key
        evs.append(ev(RELAY, 9000, 3300, [["h", "ev-" + d], ["p", LOU, "member"], ["guest", ""], ["invited-by", ME], ["name", "Lou"], ["unsaved", "1"]]))
        evs += events(Meetings.invite(cal0, [LOU]), at: 3400)
        let dv = Derive(events: evs, me: ME)
        let cal = dv.calendar[0]
        XCTAssertEqual(dv.attendance(cal), [ANA: true])
        let p = dv.meetingPeople(cal)
        XCTAssertEqual(p.map(\.pubkey), [ME, ANA, LOU, BEN])
        XCTAssertEqual(p.map(\.state), ["Host", "There", "Invited", "Maybe"])
        XCTAssertEqual(p.first { $0.pubkey == LOU }?.heldByMe, true)
        XCTAssertEqual(dv.meetingPeopleLine(cal), "People · 4 · 1 there")
        XCTAssertEqual(dv.lastMeetingPlace(), "The shed")
        XCTAssertEqual(dv.meetingPlaces(), ["The shed"])
    }

    func testWords() {
        XCTAssertEqual(Meetings.lengthLabel(45), "45 min")
        XCTAssertEqual(Meetings.lengthLabel(60), "1 h")
        XCTAssertEqual(Meetings.lengthLabel(90), "1 h 30")
        XCTAssertEqual(NamedPerson.from("lou@example.org", ""), NamedPerson(name: "lou", email: "lou@example.org"))
        XCTAssertEqual(NamedPerson.from("Lou", "lou@example.org"), NamedPerson(name: "Lou", email: "lou@example.org"))
        XCTAssertEqual(NamedPerson.from("Lou", "not an address"), NamedPerson(name: "Lou"))
    }

    func testSuggestions() {
        let evs = [
            ev(RELAY, 39000, 100, [["d", "garden"], ["name", "garden"]]),
            ev(RELAY, 39002, 100, [["d", "garden"], ["p", ME], ["p", ANA], ["p", BEN], ["p", LOU]]),
            ev(BEN, 9, Int.now - 600, [["h", "garden"]], "hi"),
            ev(ANA, 9, Int.now - 60, [["h", "garden"]], "hello"),
        ]
        let s = Derive(events: evs, me: ME).meetingSuggestions("garden")
        XCTAssertEqual(Array(s.prefix(2)), [ANA, BEN])
        XCTAssertTrue(s.contains(LOU))
        XCTAssertFalse(s.contains(ME))
    }

    func testMeetingGuestRetries() async throws {
        StubBelfry.reset()
        StubBelfry.enqueue(404, #"{"error":"no_channel"}"#)
        StubBelfry.enqueue(200, #"{"pubkey":"\#(LOU)","held":true}"#)
        let api = BelfryAPI(config: .defaults(domain: "example.org"), signer: try LocalSigner(secret: Keys.generateSecret()), session: StubBelfry.session())
        var waits = [Int]()
        let g = try await api.meetingGuestRetrying(channel: "ev-x", NamedPerson(name: "Lou")) { waits.append($0) }
        XCTAssertEqual(g.pubkey, LOU)
        XCTAssertTrue(g.held)
        XCTAssertEqual(waits, [1])
        let asked = try XCTUnwrap(StubBelfry.take())
        XCTAssertTrue(asked.url.hasSuffix("/meeting-guests"))
        XCTAssertTrue(asked.body.contains("\"name\":\"Lou\""))
        XCTAssertFalse(asked.body.contains("email"))
        // a refusal that won't change is not tried again
        StubBelfry.reset()
        StubBelfry.enqueue(422, #"{"error":"invalid","message":"server text"}"#)
        do {
            _ = try await api.meetingGuestRetrying(channel: "ev-x", NamedPerson(name: "")) { _ in }
            XCTFail("no error")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "invalid")
            XCTAssertEqual(e.message, BelfryAPI.meetingErrors["invalid"])
        }
        XCTAssertEqual(StubBelfry.count, 1)
    }
}
