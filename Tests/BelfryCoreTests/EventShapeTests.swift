import XCTest
@testable import BelfryCore

final class EventShapeTests: XCTestCase {
    func testServiceNamesOnly() {
        XCTAssertEqual(EventShape.service("https://meet.jit.si/garden-abc12"), "Jitsi")
        XCTAssertEqual(EventShape.service("https://meet.google.com/abc-defg-hij"), "Google Meet")
        XCTAssertEqual(EventShape.service("https://us02web.zoom.us/j/123?pwd=secret"), "Zoom")
        XCTAssertEqual(EventShape.service("https://calls.example.org/room/x"), "calls.example.org")
    }

    func testJoinFromTenMinutesBeforeUntilTheEnd() {
        let start = 10_000
        XCTAssertFalse(EventShape.joinOpen(start: start, end: start + 3600, now: start - 601))
        XCTAssertTrue(EventShape.joinOpen(start: start, end: start + 3600, now: start - 600))
        XCTAssertTrue(EventShape.joinOpen(start: start, end: start + 3600, now: start + 3600))
        XCTAssertFalse(EventShape.joinOpen(start: start, end: start + 3600, now: start + 3601))
        XCTAssertTrue(EventShape.joinOpen(start: start, end: nil, now: start + 3 * 3600))
        XCTAssertFalse(EventShape.joinOpen(start: start, end: nil, now: start + 3 * 3600 + 1))
    }

    func testHostedByAndGoing() {
        XCTAssertNil(EventShape.hostedBy([]))
        XCTAssertEqual(EventShape.hostedBy(["Lina Moreau", "Ben Okafor"]), "Hosted by Lina Moreau and Ben Okafor")
        XCTAssertEqual(EventShape.hostedBy(["A", "B", "C", "D"]), "Hosted by A, B and 2 more")
        XCTAssertEqual(EventShape.goingLine(going: 15, maybe: 3), "15 going · 3 maybe")
        XCTAssertEqual(EventShape.goingLine(going: 4, maybe: 0), "4 going")
        XCTAssertNil(EventShape.goingLine(going: 0, maybe: 0))
    }

    func testRsvpLineWords() {
        XCTAssertEqual(RsvpLine(pubkey: "a", rsvp: .accepted, at: 1).text(name: "Lina Moreau", me: false), "Lina Moreau is going")
        XCTAssertEqual(RsvpLine(pubkey: "a", rsvp: .accepted, at: 1).text(name: "", me: true), "You're going")
    }
}
