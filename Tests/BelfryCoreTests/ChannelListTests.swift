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

/// The shared inbox switch per channel (docs/mail.md @73a414f): d = belfry:inbox:<group> + h.
final class InboxSwitchTests: XCTestCase {
    private func admins(_ id: String) -> NostrEvent { ev(RELAY, 39001, 100, [["d", id], ["p", ADMIN, "admin"]]) }
    private func sw(_ who: String, _ at: Int, d: String, h: String, on: Bool) -> NostrEvent {
        ev(who, 30078, at, [["d", d], ["h", h]], on ? #"{"on":true}"# : #"{"on":false}"#)
    }

    func testInboxSettingPerChannel() {
        let base = [meta("general", "general"), meta("hello", "hello"), admins("general"), admins("hello")]
        // one admin, two channels: each keeps its own switch; turning one off leaves the other on
        var d = Derive(events: base + [sw(ADMIN, 200, d: Derive.inboxD("hello"), h: "hello", on: true),
                                       sw(ADMIN, 210, d: Derive.inboxD("general"), h: "general", on: true),
                                       sw(ADMIN, 220, d: Derive.inboxD("general"), h: "general", on: false)], me: ME)
        XCTAssertTrue(d.isInbox(d.group("hello")))
        XCTAssertFalse(d.isInbox(d.group("general")))
        // the old d is read by its h; old against new, the latest wins
        d = Derive(events: base + [sw(ADMIN, 200, d: Derive.inboxD, h: "hello", on: true)], me: ME)
        XCTAssertTrue(d.isInbox(d.group("hello")))
        XCTAssertFalse(d.isInbox(d.group("general")))
        d = Derive(events: base + [sw(ADMIN, 200, d: Derive.inboxD, h: "hello", on: true), sw(ADMIN, 210, d: Derive.inboxD("hello"), h: "hello", on: false)], me: ME)
        XCTAssertFalse(d.isInbox(d.group("hello")))
        // a d naming another channel than its h counts for neither
        d = Derive(events: base + [sw(ADMIN, 200, d: Derive.inboxD("general"), h: "hello", on: true)], me: ME)
        XCTAssertFalse(d.isInbox(d.group("hello")))
        XCTAssertFalse(d.isInbox(d.group("general")))
        // a non-admin's never counts
        d = Derive(events: base + [sw(OTHER, 200, d: Derive.inboxD("hello"), h: "hello", on: true)], me: ME)
        XCTAssertFalse(d.isInbox(d.group("hello")))
        // what the app writes
        XCTAssertEqual(Actions.setInbox("general", on: true).tags, [["d", "belfry:inbox:general"], ["h", "general"]])
    }

    /// OSV, 2026-11-22: the log keeps every copy of a 30078. An old-d copy for #hello (on), replaced
    /// by the same admin's old-d copy for #sponsors, counts no more: #hello reads off (it opened ON,
    /// so Save saw no change and published nothing).
    func testAReplacedOldSwitchCountsNoMore() {
        let base = [meta("hello", "hello"), meta("sponsors", "sponsors"), admins("hello"), admins("sponsors")]
        var d = Derive(events: base + [sw(ADMIN, 200, d: Derive.inboxD, h: "hello", on: true),
                                       sw(ADMIN, 300, d: Derive.inboxD, h: "sponsors", on: true)], me: ME)
        XCTAssertFalse(d.isInbox(d.group("hello")))
        XCTAssertTrue(d.isInbox(d.group("sponsors")))
        // only the sponsors copy on the relay: viewing #hello → off
        d = Derive(events: base + [sw(ADMIN, 300, d: Derive.inboxD, h: "sponsors", on: true)], me: ME)
        XCTAssertFalse(d.isInbox(d.group("hello")))
        // the new d for #hello still decides, newer than the old copy
        d = Derive(events: base + [sw(ADMIN, 300, d: Derive.inboxD, h: "sponsors", on: true),
                                   sw(ADMIN, 310, d: Derive.inboxD("hello"), h: "hello", on: true)], me: ME)
        XCTAssertTrue(d.isInbox(d.group("hello")))
        // a replaced new-d copy: the newest of that d wins, even when an older copy said on
        d = Derive(events: base + [sw(ADMIN, 200, d: Derive.inboxD("hello"), h: "hello", on: true),
                                   sw(ADMIN, 250, d: Derive.inboxD("hello"), h: "hello", on: false)], me: ME)
        XCTAssertFalse(d.isInbox(d.group("hello")))
    }

    /// The forward row reads the server's answer as it is (mailforward.py `public`): on and confirmed.
    func testForwardStateFromTheServersAnswer() {
        let on: [String: Any] = ["forward": ["address": "team@example.org", "state": "on", "set_by": "ab", "since": 1763337600, "same_domain_skipped": false]]
        XCTAssertEqual(MailForward.parse(on), MailForward(address: "team@example.org", on: true, sameDomainSkipped: false))
        XCTAssertEqual(MailForward.line(MailForward.parse(on)), "team@example.org")
        let pending: [String: Any] = ["forward": ["address": "team@gmail.com", "state": "pending", "same_domain_skipped": true]]
        XCTAssertEqual(MailForward.parse(pending)?.on, false)
        XCTAssertNil(MailForward.parse(["forward": NSNull()]))
    }

    /// Save publishes the switch whenever it was touched or differs from what the channel reads, so
    /// a stale reading can never swallow a Save; a refused one shows the channel's error mark.
    func testSaveSendsTheSwitchAndAFailureShows() {
        XCTAssertTrue(Actions.inboxToSend(chosen: true, reads: true, touched: true))
        XCTAssertTrue(Actions.inboxToSend(chosen: true, reads: false, touched: false))
        XCTAssertFalse(Actions.inboxToSend(chosen: false, reads: false, touched: false))
        let d = Actions.setInbox("hello", on: true)
        var item = OutboxItem(target: d.target, kind: d.kind, content: d.content, tags: d.tags, createdAt: 1)
        XCTAssertEqual(SettingsQueue.part(item), .inbox)
        XCTAssertEqual(d.target, .groups)
        item.status = .failed
        item.error = "restricted: not an admin"
        XCTAssertEqual(SettingsQueue.failed([item], channel: "hello").count, 1)
        XCTAssertEqual(SettingsQueue.message(item), "The e-mail setting wasn't saved: you're not allowed to change this channel.")
    }
}
