import Foundation
import XCTest
@testable import BelfryCore

// The channel list (web order.ts, webPage / isPublicChannel), @Mentions and branding.

private let ME = String(repeating: "a", count: 64)
private let ADMIN = String(repeating: "b", count: 64)
private let OTHER = String(repeating: "c", count: 64)
private let RELAY = String(repeating: "d", count: 64)
private var n = 0

private func ev(_ pubkey: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
    n += 1
    return NostrEvent(id: String(format: "%064x", 9000 + n), pubkey: pubkey, createdAt: at, kind: kind, tags: tags, content: content)
}

private func meta(_ id: String, _ name: String) -> NostrEvent { ev(RELAY, 39000, 100, [["d", id], ["name", name]]) }

final class ChannelListTests: XCTestCase {
    func testPublicMembersAndAdminOrder() {
        let events = [
            meta("general", "general"), meta("events", "events"), meta("garden", "garden"), meta("bugs", "bugs"),
            // events: public page set up by the relay's key; garden: page on but members only
            ev(RELAY, 30078, 110, [["d", "belfry:web:events"], ["h", "events"]], #"{"on":true,"slug":"events","visibility":"public","posts":"event"}"#),
            ev(RELAY, 30078, 110, [["d", "belfry:web:garden"], ["h", "garden"]], #"{"on":true,"visibility":"members"}"#),
            // someone who isn't an admin can't make bugs public
            ev(OTHER, 30078, 120, [["d", "belfry:web:bugs"], ["h", "bugs"]], #"{"on":true,"visibility":"public"}"#),
            // the admins' order; a non-admin's later order doesn't count
            ev(ADMIN, 30078, 130, [["d", "belfry:channel-order"]], #"{"order":["garden","bugs","general"]}"#),
            ev(OTHER, 30078, 140, [["d", "belfry:channel-order"]], #"{"order":["general","garden"]}"#),
        ]
        let d = Derive(events: events, me: ME, communityAdmins: [ADMIN])
        let s = d.channelSections()
        XCTAssertEqual(s.pub.map(\.id), ["events"])
        XCTAssertEqual(s.members.map(\.id), ["garden", "bugs", "general"])
        XCTAssertEqual(d.webPage(d.group("events"))?.posts, "event")
        XCTAssertNil(d.webPage(d.group("bugs")))
        XCTAssertEqual(d.visibilityLine(d.group("general")), "Members only")
        XCTAssertTrue(d.visibilityLine(d.group("events")).hasPrefix("Public · "))
    }

    func testInOrderIsStable() {
        let d = Derive(events: [meta("x", "x"), meta("y", "y"), meta("z", "z")], me: ME)
        let list = ["x", "y", "z"].compactMap { d.group($0) }
        XCTAssertEqual(d.inOrder(list, order: ["z"]).map(\.id), ["z", "x", "y"])
        XCTAssertEqual(d.inOrder(list, order: []).map(\.id), ["x", "y", "z"])
    }

    func testMentionsOfMe() {
        let npub = Bech32.npub(ME)!
        let events = [
            meta("general", "general"),
            ev(OTHER, 9, 200, [["h", "general"], ["p", ME]], "hi"),
            ev(OTHER, 1111, 300, [["h", "general"], ["E", "x"]], "see nostr:\(npub)"),
            ev(ME, 9, 400, [["h", "general"], ["p", ME]], "me myself"),
            ev(OTHER, 9, 500, [["h", "general"]], "nothing"),
        ]
        let d = Derive(events: events, me: ME)
        XCTAssertEqual(d.mentionsOfMe().map(\.createdAt), [300, 200])
    }

    func testBrandingIsCleaned() {
        let doc: [String: Any] = ["name": "X", "branding": ["primary": "#1E40AF", "secondary": "red", "logo": "http://x/y.png", "cover": "https://x.org/c.jpg"]]
        let c = BelfryConfig.from(domain: "x.org", document: doc)
        XCTAssertEqual(c.branding?.primary, "#1e40af")
        XCTAssertEqual(c.branding?.secondary, "")
        XCTAssertEqual(c.branding?.logo, "")
        XCTAssertEqual(c.branding?.cover, "https://x.org/c.jpg")
        XCTAssertNil(BelfryConfig.from(domain: "x.org", document: ["branding": ["primary": "nope"]]).branding)
        XCTAssertTrue(Branding.darkText(on: "#fde047"))
        XCTAssertFalse(Branding.darkText(on: "#1e40af"))
    }
}
