import Foundation
import XCTest
@testable import BelfryCore

// Round 6 (2026-11-18): channel visibility with periods and closed channels (SPEC 19.38,
// vectors/visibility.json), the Notifications sheet's choices, a proposal's options and
// turnout (SPEC 19.39), and a new profile picture showing everywhere at once.

private let RELAY = String(repeating: "d", count: 64)
private let ME = String(repeating: "a", count: 64)
private let BEN = String(repeating: "b", count: 64)
private let EMMA = String(repeating: "e", count: 64)

private func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "", id: String? = nil) -> NostrEvent {
    NostrEvent(id: id ?? Crypto.sha256("\(pk)\(kind)\(at)\(tags)\(c)").hex, pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
}

private func channel(_ id: String, _ name: String, admins: [String], members: [String], closed: Bool = false) -> [NostrEvent] {
    [ev(RELAY, 39000, 100, [["d", id], ["name", name]] + (closed ? [["closed"]] : [])),
     ev(RELAY, 39001, 100, [["d", id]] + admins.map { ["p", $0, "admin"] }),
     ev(RELAY, 39002, 100, [["d", id]] + members.map { ["p", $0] })]
}

final class VisibilityTests: XCTestCase {
    func webEvent(_ id: String, _ content: Any?) -> [NostrEvent] {
        guard let content, !(content is NSNull) else { return [] }
        return [ev(RELAY, 30078, 150, [["d", Derive.webD + id], ["h", id]], JSON.encode(content))]
    }

    func testVectors() throws {
        let v = try vector("visibility")
        let id = v.str("id")!, name = v.str("name")!, now = v.int("now")!
        for c in v.list("cases") {
            let label = c.str("name") ?? ""
            let d = Derive(events: channel(id, name, admins: [ME], members: [ME]) + webEvent(id, c["content"]), me: ME)
            let g = try XCTUnwrap(d.group(id))
            let out = Actions.setVisibility(g, public: c.str("to") == "public", derive: d, now: now)
            guard let want = c["expect"] as? [String: Any] else { XCTAssertNil(out, label); continue }
            let draft = try XCTUnwrap(out, label)
            XCTAssertEqual(draft.kind, 30078, label)
            XCTAssertEqual(draft.tags, [["d", Derive.webD + id], ["h", id], ["t", "belfry-web"]], label)
            let got = try XCTUnwrap(JSON.parse(draft.content) as? [String: Any], label)
            for k in ["on", "slug", "visibility", "posts"] {
                XCTAssertEqual(got[k].map { "\($0)" }, want[k].map { "\($0)" }, "\(label): \(k)")
            }
            let periods = (got["periods"] as? [[Any]] ?? []).map { $0.map { ($0 as? NSNumber)?.intValue } }
            let wantP = (want["periods"] as? [[Any]] ?? []).map { $0.map { ($0 as? NSNumber)?.intValue } }
            XCTAssertEqual(periods, wantP, "\(label): periods")
            // written back, it reads as the new choice
            let after = Derive(events: channel(id, name, admins: [ME], members: [ME]) + [ev(ME, 30078, 2000, draft.tags, draft.content)], me: ME)
            XCTAssertEqual(after.isPublic(after.group(id)), c.str("to") == "public", label)
        }
    }

    func testAccessVectors() throws {
        let v = try vector("visibility")
        let id = v.str("id")!
        for c in v.list("access") {
            let d = Derive(events: channel(id, "Garden Club", admins: [ME], members: [ME], closed: c["closed"] as? Bool == true) + webEvent(id, c["content"]), me: ME)
            XCTAssertEqual(d.channelAccess(d.group(id)).rawValue, c.str("expect"), c.str("name") ?? "")
        }
    }

    func testWebSettingsOnlyFromItsAdmins() {
        let id = "garden-3f2a"
        let d = Derive(events: channel(id, "Garden", admins: [EMMA], members: [ME, EMMA]) +
                       [ev(BEN, 30078, 150, [["d", Derive.webD + id], ["h", id]], "{\"on\":true,\"slug\":\"g\",\"visibility\":\"public\"}")], me: ME)
        XCTAssertEqual(d.channelAccess(d.group(id)), .members)
        XCTAssertTrue(d.webContent(d.group(id)).isEmpty)
    }

    func testClosedChannel() throws {
        let id = "board-5d1e"
        var evs = channel(id, "Board", admins: [EMMA], members: [EMMA], closed: true) + channel("general", "general", admins: [EMMA], members: [ME, EMMA, BEN])
        evs.append(ev(BEN, 9021, 200, [["h", id]], "I can help with the budget"))
        let me = Derive(events: evs, me: ME)
        let g = try XCTUnwrap(me.group(id))
        XCTAssertTrue(me.needsJoinBar(g))
        XCTAssertTrue(me.readOnlyClosed(g))
        XCTAssertTrue(me.mayClose(g))
        XCTAssertFalse(me.mayClose(me.group("general")))
        // its steward: no bar, writes, sees the request
        let emma = Derive(events: evs, me: EMMA)
        let ge = try XCTUnwrap(emma.group(id))
        XCTAssertFalse(emma.needsJoinBar(ge))
        XCTAssertFalse(emma.readOnlyClosed(ge))
        XCTAssertEqual(ge.applications.map(\.pubkey), [BEN])
        XCTAssertEqual(emma.groupRequests().map(\.group.id), [id])
        // a belfry admin is no outsider either
        let admin = Derive(events: evs, me: ME, communityAdmins: [ME])
        XCTAssertFalse(admin.needsJoinBar(try XCTUnwrap(admin.group(id))))
        // Ben asked: still read only, his request is pending; accepted (9000): in
        var mine = evs
        let ben = Derive(events: mine, me: BEN)
        XCTAssertTrue(ben.group(id)!.applications.contains { $0.pubkey == BEN })
        mine.append(ev(EMMA, 9000, 300, [["h", id], ["p", BEN, "member"]]))
        let inside = Derive(events: mine, me: BEN)
        XCTAssertFalse(inside.readOnlyClosed(inside.group(id)!))
        XCTAssertTrue(inside.group(id)!.applications.isEmpty)
        // closing a channel: one 9002 with ["closed"] and the question
        let close = Actions.groupMeta(try XCTUnwrap(Derive(events: channel("garden-3f2a", "Garden", admins: [ME], members: [ME]), me: ME).group("garden-3f2a")), closed: true, prompt: "")
        XCTAssertTrue(close.tags.contains(["closed"]))
        XCTAssertTrue(close.tags.contains(["prompt", Actions.defaultPrompt]))
    }

    func testSettingsQueueKnowsVisibility() {
        let item = OutboxItem(target: .groups, kind: 30078, content: "{}", tags: [["d", Derive.webD + "garden"], ["h", "garden"]], createdAt: 10, status: .failed, error: "restricted: no")
        XCTAssertEqual(SettingsQueue.part(item), .visibility)
        XCTAssertEqual(SettingsQueue.failed([item], channel: "garden").count, 1)
        XCTAssertEqual(SettingsQueue.message(item), "Who can read it wasn't saved: you're not allowed to change this channel.")
    }
}

final class NotifyChoiceTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(NotifyChoice.of(level: "all"), .everything)
        XCTAssertEqual(NotifyChoice.of(level: "default"), .forMe)
        XCTAssertEqual(NotifyChoice.of(level: "mentions"), .forMe)
        XCTAssertEqual(NotifyChoice.of(level: "off"), .nothing)
        XCTAssertEqual(NotifyChoice.allCases.map(\.level), ["all", "default", "off"])
        XCTAssertEqual(NotifyChoice.forMe.line(stored: "default"), "Mentions, replies to me, announcements (the default here)")
        XCTAssertEqual(NotifyChoice.forMe.line(stored: "mentions"), "Mentions, replies to me, announcements")
        XCTAssertEqual(NotifyChoice.everything.line(stored: "default"), "Every new message")
        XCTAssertEqual(NotifyChoice.nothing.title, "Nothing")
    }
}

final class ProposalTopTests: XCTestCase {
    func testOptionsAndTurnout() throws {
        let parent = "garden-3f2a", prop = "prop-sundays-1a2b"
        let coord = "30023:\(EMMA):sundays"
        var evs = channel(parent, "Garden", admins: [EMMA], members: [ME, BEN, EMMA, RELAY]) + channel(prop, "Sundays", admins: [EMMA], members: [EMMA])
        evs.append(ev(EMMA, 9, 110, [["h", parent], ["proposal", prop]], "New proposal"))
        evs.append(ev(EMMA, 30023, 120, [["d", "sundays"], ["h", prop], ["t", "proposal"], ["title", "Open on Sundays"], ["version", "2"], ["status", "voting"]], "We open on Sundays."))
        let poll = ev(EMMA, 1068, 130, [["h", prop], ["a", coord], ["version", "2"], ["option", "yes", "Yes"], ["option", "later", "Later"]], "?")
        evs.append(poll)
        evs.append(ev(BEN, 1018, 140, [["h", prop], ["e", poll.id], ["response", "later"]]))
        let d = Derive(events: evs, me: ME)
        let p = try XCTUnwrap(d.proposalFor(prop))
        XCTAssertEqual(p.options.map(\.id), ["yes", "later"])
        XCTAssertEqual(p.options.map(\.label), ["Yes", "Later"])
        XCTAssertTrue(p.votingNow)
        let t = d.voteTurnout(p)
        XCTAssertEqual(t.voted, 1)
        XCTAssertEqual(t.of, 2) // the proposal chat's members (Emma) and the voters (Ben)
        XCTAssertEqual(d.votesByOption(p), ["later": [BEN]])
        // versions: 1 (the card), then each "📝 Version N" note naming the proposal
        var more = evs
        more.append(ev(EMMA, 9, 125, [["h", prop], ["a", coord, "wss://x"], ["version", "2"]], "📝 Version 2: Sundays only in summer"))
        more.append(ev(BEN, 9, 126, [["h", prop], ["version", "3"]], "📝 Version 3: not about this proposal"))
        let dv = Derive(events: more, me: ME)
        let vs = dv.proposalVersions(try XCTUnwrap(dv.proposalFor(prop)))
        XCTAssertEqual(vs.map(\.version), [2, 1])
        XCTAssertEqual(vs[0].note, "Sundays only in summer")
        XCTAssertEqual(vs[0].text, "We open on Sundays.")
        XCTAssertEqual(vs[1].at, 110)
        XCTAssertNil(vs[1].text)
        XCTAssertTrue(d.needsMyVote(p))
        // a poll with no options: the three defaults
        let bare = Poll(ev: ev(EMMA, 1068, 1, [["h", prop]]), version: 1, votes: [:])
        XCTAssertEqual(bare.options.map(\.id), ["yes", "no", "abstain"])
    }
}

final class ProfileEverywhereTests: XCTestCase {
    /// A face's picture belongs to an address: never the old one for a new address (the cause of
    /// "my past messages should show immediately my new avatar").
    func testPictureSlot() {
        var slot = PictureSlot<String>(url: "https://x/old.jpg", picture: "OLD")
        let cache = ["https://x/new.jpg": "NEW"]
        // the profile now names the new address, already in the memory cache: NEW, not OLD
        XCTAssertEqual(slot.shown(for: "https://x/new.jpg") { cache[$0] }, "NEW")
        // not cached yet: the placeholder, not OLD
        XCTAssertNil(slot.shown(for: "https://x/other.jpg") { cache[$0] })
        XCTAssertTrue(slot.needsLoad("https://x/new.jpg"))
        slot.hold("NEW", for: "https://x/new.jpg")
        XCTAssertFalse(slot.needsLoad("https://x/new.jpg"))
        XCTAssertEqual(slot.shown(for: "https://x/new.jpg") { _ in nil }, "NEW")
        XCTAssertNil(slot.shown(for: nil) { cache[$0] })
        XCTAssertNil(PictureSlot<String>(url: "u", picture: nil).url)
    }

    /// My own new profile is in the snapshot the moment it is queued, before any relay echo.
    /// Two profiles of the same second: the lower id wins, as relays keep it (NIP-01), whatever
    /// the order they arrive in.
    func testProfileTie() {
        let a = ev(ME, 0, 500, [], "{\"name\":\"A\"}", id: String(repeating: "1", count: 64))
        let b = ev(ME, 0, 500, [], "{\"name\":\"B\"}", id: String(repeating: "2", count: 64))
        XCTAssertEqual(Derive(events: [a, b], me: BEN).profiles()[ME]?.name, "A")
        XCTAssertEqual(Derive(events: [b, a], me: BEN).profiles()[ME]?.name, "A")
        // my next event always comes a second after my last one
        XCTAssertEqual(Outbox.nextCreatedAt(last: 500, now: 500), 501)
    }

    func testOwnProfileAtOnce() throws {
        let path = NSTemporaryDirectory() + "belfry-test-\(UUID().uuidString).sqlite"
        let me = try LocalSigner(secret: Keys.generateSecret())
        let e = SyncEngine(config: .defaults(domain: "example.org"), db: try Database(path: path), signer: me, localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        let old = try me.signNow(EventTemplate(kind: 0, content: "{\"name\":\"Sam\",\"picture\":\"https://x/old.jpg\"}", tags: [], createdAt: Int.now - 100))
        e.add([old], verify: false)
        XCTAssertEqual(Derive(events: e.snapshot(), me: me.pubkey).profiles()[me.pubkey]?.picture, "https://x/old.jpg")
        let before = e.outboxVersion
        let d0 = Derive(events: e.snapshot(), me: me.pubkey)
        e.enqueue(Actions.saveProfile(current: d0.myProfileJSON, name: "Sam", about: "", picture: "https://x/new.jpg"))
        XCTAssertGreaterThan(e.outboxVersion, before)
        let d1 = Derive(events: e.snapshot(), me: me.pubkey)
        XCTAssertEqual(d1.profiles()[me.pubkey]?.picture, "https://x/new.jpg")
        XCTAssertEqual(d1.profiles()[me.pubkey]?.name, "Sam")
    }
}
