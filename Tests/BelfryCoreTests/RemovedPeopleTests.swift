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

/// "‹name› joined ‹the belfry›" in the main channel (one-shape.md, 2026-11-22).
final class BelfryJoinTests: XCTestCase {
    let me = String(repeating: "a", count: 64)
    let gk = String(repeating: "9", count: 64)
    let lina = String(repeating: "b", count: 64)
    let bot = String(repeating: "c", count: 64)
    let gone = String(repeating: "d", count: 64)
    let old = String(repeating: "e", count: 64)
    let guest = String(repeating: "f", count: 64)

    private func ev(_ pubkey: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
        var e = NostrEvent(pubkey: pubkey, createdAt: at, kind: kind, tags: tags, content: content)
        e.id = Crypto.sha256(Data("\(pubkey)\(kind)\(at)\(tags)\(content)".utf8)).hex
        return e
    }

    func testOnlyTheBelfrysOwnJoinedLinesOncePerPersonAndNotForTheRemoved() {
        func joined(_ p: String, _ at: Int, by: String? = nil, extra: [Tag] = []) -> NostrEvent {
            ev(by ?? gk, 9000, at, [["h", "general"], ["p", p, "member"], ["joined", "belfry"], ["name", "N"]] + extra)
        }
        let events = [
            ev(gk, 39000, 10, [["d", "general"], ["name", "general"]]),
            joined(lina, 100), joined(lina, 105),                       // once per person: the first
            joined(bot, 110, extra: [["agent", "1"]]),
            joined(gone, 120), ev(gk, 9001, 130, [["h", "general"], ["p", gone]]),
            ev(gk, 9000, 140, [["h", "general"], ["p", old, "member"]]),                               // no tag: no line
            ev(gk, 9000, 150, [["h", "general"], ["p", guest, "member"], ["invited-by", me], ["guest", "2026-12-09"]]),
            joined(String(repeating: "1", count: 64), 160, by: me),                                    // not the belfry's key
        ]
        let d = Derive(events: events, context: WorldContext(me: me, groupsKey: gk))
        let lines = d.belfryJoins()
        XCTAssertEqual(lines.map(\.pubkey), [lina, bot])
        XCTAssertEqual(lines.map(\.at), [100, 110])
        XCTAssertEqual(lines.map(\.agent), [false, true])
        XCTAssertTrue(lines.allSatisfy { $0.belfry && $0.chip == nil })
        // in the main channel's feed, beside the guest's own line; never among the guests
        let feed = d.feed("general").compactMap { i -> GuestJoin? in if case .join(let j) = i { return j } else { return nil } }
        XCTAssertEqual(Set(feed.map(\.pubkey)), [lina, bot, guest])
        XCTAssertEqual(d.guestJoins("general").map(\.pubkey), [guest])
        XCTAssertFalse(d.isGuest(lina))
        // without the groups key known, nothing is drawn (it can't be told from anyone's 9000)
        XCTAssertTrue(Derive(events: events, context: WorldContext(me: me)).belfryJoins().isEmpty)
    }
}

/// Groups: open, closed, private (one-shape.md, 2026-11-22).
final class GroupAccessTests: XCTestCase {
    let me = String(repeating: "a", count: 64)
    let ana = String(repeating: "b", count: 64)
    let gk = String(repeating: "9", count: 64)

    private func ev(_ pubkey: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
        var e = NostrEvent(pubkey: pubkey, createdAt: at, kind: kind, tags: tags, content: content)
        e.id = Crypto.sha256(Data("\(pubkey)\(kind)\(at)\(tags)\(content)".utf8)).hex
        return e
    }

    func testTheFormsThreeChoicesOnTheWire() {
        func meta(_ a: GroupAccess) -> [Tag] { Actions.createGroup(id: "pod-x", name: "X", about: "", access: a)[1].tags }
        XCTAssertTrue(meta(.open).contains(["open"]) && meta(.open).contains(["public"]))
        XCTAssertTrue(meta(.closed).contains(["closed"]) && meta(.closed).contains(["public"]))
        XCTAssertNil(meta(.closed).first { $0.first == "prompt" }, "a new closed group starts with no question")
        XCTAssertTrue(meta(.private).contains(["closed"]) && meta(.private).contains(["private"]))
        // a private group is not announced in its parent; the others are
        XCTAssertEqual(Actions.createGroup(id: "pod-x", name: "X", about: "", access: .private).map(\.kind), [9007, 9002])
        XCTAssertEqual(Actions.createGroup(id: "pod-x", name: "X", about: "", access: .open).map(\.kind), [9007, 9002, 9])
        // the picked people: one 9000 each, once
        let adds = Actions.addPeople("pod-x", [ana, me, ana])
        XCTAssertEqual(adds.map(\.tags), [[["h", "pod-x"], ["p", ana, "member"]], [["h", "pod-x"], ["p", me, "member"]]])
    }

    func testAPrivateGroupShowsOnlyToThoseInItAndTakesNoRequests() {
        let base = [
            ev(gk, 39000, 10, [["d", "general"], ["name", "general"]]),
            ev(ana, 9007, 20, [["h", "pod-secret-1a2b"]]),
            ev(ana, 9002, 21, [["h", "pod-secret-1a2b"], ["name", "Secret"], ["about", ""], ["closed"], ["private"]]),
            ev(me, 9021, 30, [["h", "pod-secret-1a2b"]], "let me in"),
        ]
        var d = Derive(events: base, context: WorldContext(me: me, groupsKey: gk))
        XCTAssertNil(d.groups().first { $0.id == "pod-secret-1a2b" }, "not in it: in no list")
        // nobody outside it sees it, the belfry's stewards included (one-shape.md d85f408)
        let steward = Derive(events: base, context: WorldContext(me: me, communityAdmins: [me], groupsKey: gk))
        XCTAssertNil(steward.groups().first { $0.id == "pod-secret-1a2b" })
        // added by its admin: it shows, private, with no request in it
        d = Derive(events: base + [ev(ana, 9000, 40, [["h", "pod-secret-1a2b"], ["p", me, "member"]])], context: WorldContext(me: me, groupsKey: gk))
        let g = d.groups().first { $0.id == "pod-secret-1a2b" }
        XCTAssertEqual(g?.isPrivate, true)
        XCTAssertEqual(g?.closed, true)
        XCTAssertEqual(g?.applications.count, 0)
    }
}

/// A channel's Settings: which kinds of post it takes (one-shape.md, 2026-11-22).
final class AcceptsTests: XCTestCase {
    func testWhatAChannelTakesAndTheLegacyValue() {
        func page(posts: String? = nil, accepts: [String]? = nil) -> WebPage { WebPage(on: false, slug: "x", visibility: "members", posts: posts, accepts: accepts) }
        let all = Set(WebPage.kinds)
        XCTAssertEqual(page().takes, all, "nothing written: all four")
        XCTAssertEqual(page(posts: "thread").takes, ["thread"], "an older app's single kind")
        XCTAssertEqual(page(posts: "request").takes, all)
        XCTAssertEqual(page(posts: "thread", accepts: ["message", "event"]).takes, ["message", "event"], "accepts wins")
        XCTAssertEqual(page(accepts: ["nope"]).takes, all, "nothing known in it: as if absent")
        XCTAssertNil(page(accepts: ["message", "event"]).only)
        XCTAssertEqual(page(accepts: ["event", "proposal"]).only, "event", "no plain messages: the first kind that is on")
        XCTAssertEqual(page(posts: "proposal").only, "proposal")
        // what an older app reads
        XCTAssertEqual(WebPage.legacyPosts(all), "anything")
        XCTAssertEqual(WebPage.legacyPosts(["thread"]), "thread")
        XCTAssertEqual(WebPage.legacyPosts(["message"]), "anything")
        XCTAssertEqual(WebPage.legacyPosts(["event", "proposal"]), "anything")
    }

    func testAnOddOldValueStaysWhileAllFourAreOn() throws {
        let me = String(repeating: "a", count: 64)
        func ev(_ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
            var e = NostrEvent(pubkey: me, createdAt: at, kind: kind, tags: tags, content: content)
            e.id = Crypto.sha256(Data("\(kind)\(at)\(tags)\(content)".utf8)).hex
            return e
        }
        let events = [
            ev(39000, 10, [["d", "requests"], ["name", "requests"]]),
            ev(39001, 10, [["d", "requests"], ["p", me, "admin"]]),
            ev(30078, 20, [["d", "belfry:web:requests"], ["h", "requests"]], #"{"on":false,"visibility":"members","slug":"requests","posts":"request","accepts":["message","thread"]}"#),
        ]
        let d = Derive(events: events, context: WorldContext(me: me))
        let g = try XCTUnwrap(d.group("requests"))
        func content(_ takes: Set<String>) throws -> [String: Any] {
            let draft = try XCTUnwrap(Actions.setAccepts(g, takes: takes, derive: d))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(draft.content.utf8)) as? [String: Any])
        }
        // all four on again: "request" stays
        XCTAssertEqual(try content(Set(WebPage.kinds))["posts"] as? String, "request")
        // a kind is off: the rule
        XCTAssertEqual(try content(["event"])["posts"] as? String, "event")
        XCTAssertEqual(try content(["message", "event"])["posts"] as? String, "anything")
    }

    func testTheAddressTheBelfryGives() {
        let a = MailAlias.parse(["channel": "hello-79f0", "alias": "hello", "address": "hello@riverside.example", "custom": true, "may_set": false])
        XCTAssertEqual(a?.address, "hello@riverside.example")
        XCTAssertEqual(a?.alias, "hello")
        XCTAssertEqual(a?.custom, true)
        XCTAssertEqual(a?.maySet, false)
        XCTAssertNil(MailAlias.parse(["address": "not an address"]))
        XCTAssertEqual(MailAlias.checkLine("available", address: "bike@riverside.example"), "bike@riverside.example is free.")
        XCTAssertEqual(MailAlias.checkLine("", address: "x"), "")
    }
}
