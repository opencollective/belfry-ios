import XCTest
@testable import BelfryCore

// Printed cards (collective-belfry docs/cards.md; web chat-source f10e6b2 core/cards.ts): the
// address, what the belfry answers, the refusals' words, the hashtag, the bodies, who really
// made a card's group (`by`), the Townsquare's "New topic" post, a reading guest's post in a
// card's topic, followers.

private let ME = String(repeating: "a", count: 64)
private let ANA = String(repeating: "b", count: 64)
private let GK = String(repeating: "c", count: 64)
private var counter = 0
private func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
    counter += 1
    return NostrEvent(id: String(format: "%064x", 90000 + counter), pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
}

final class CardsTests: XCTestCase {
    func testAddress() {
        func p(_ s: String) -> (String, String?)? { CardLink.parse(URL(string: s)!).map { ($0.domain, $0.id) } }
        XCTAssertEqual(p("https://chat.belfry.brussels/g/K7Q2MX")?.1, "K7Q2MX")
        XCTAssertEqual(p("https://chat.belfry.brussels/g/K7Q2MX")?.0, "belfry.brussels")
        XCTAssertEqual(p("https://chat.belfry.brussels/g/k7q2mx")?.1, "K7Q2MX", "lower case reads as upper case")
        XCTAssertEqual(p("https://chat.belfry.brussels/g/K7Q2MX/")?.1, "K7Q2MX")
        XCTAssertEqual(p("https://chat.belfry.brussels/#/g/K7Q2MX")?.1, "K7Q2MX")
        // a card's address with something that is no id: a card nobody knows, never shown
        XCTAssertNotNil(p("https://chat.belfry.brussels/g/K7Q2M0"))
        XCTAssertNil(p("https://chat.belfry.brussels/g/K7Q2M0")?.1, "no 0, O, 1, I, L")
        XCTAssertNil(p("https://chat.belfry.brussels/g/TOOLONG1")?.1)
        XCTAssertNil(p("https://chat.belfry.brussels/g")?.1)
        XCTAssertNil(p("https://chat.belfry.brussels/join/K7Q2MX"))
        XCTAssertNil(p("https://belfry.brussels/g/K7Q2MX"), "the chat's host only")
        XCTAssertNil(p("http://chat.belfry.brussels/g/K7Q2MX"))
        XCTAssertEqual(CardLink.url(domain: "belfry.sh", id: "K7Q2MX"), "https://chat.belfry.sh/g/K7Q2MX")
    }

    func testInfo() {
        let invite = "abcdefghijklmnopqrstuvwx"
        XCTAssertEqual(CardInfo.parse(["kind": "group", "state": "unclaimed"]), .unclaimed(.group))
        XCTAssertEqual(CardInfo.parse(["kind": "topic", "state": "unclaimed"]), .unclaimed(.topic))
        XCTAssertEqual(CardInfo.parse(["kind": "group", "state": "claimed", "group": "pod-bread-x1y2", "title": " Sourdough   starters ", "invite": invite]),
                       .claimed(.group, group: "pod-bread-x1y2", title: "Sourdough starters", invite: invite))
        XCTAssertEqual(CardInfo.parse(["kind": "group", "state": "claimed", "group": "pod-bread-x1y2", "title": "x"]), .unknown, "claimed needs its invite")
        XCTAssertEqual(CardInfo.parse(["kind": "group", "state": "claimed", "group": "a b", "title": "x", "invite": invite]), .unknown)
        XCTAssertEqual(CardInfo.parse(["kind": "topic", "state": "retired", "title": ""]), .retired(.topic, title: ""))
        XCTAssertEqual(CardInfo.parse(["kind": "group", "state": "archived", "title": "Book club"]), .archived(.group, title: "Book club"))
        XCTAssertEqual(CardInfo.parse(["kind": "group", "state": "else"]), .unknown)
        XCTAssertEqual(CardInfo.parse(nil), .unknown)
    }

    func testRefusals() {
        XCTAssertEqual(CardFailure.from(status: 404, body: ["error": "not_found"]).code, .unknown)
        XCTAssertEqual(CardFailure.from(status: 429, body: nil).code, .tooMany)
        XCTAssertEqual(CardFailure.from(status: 503, body: ["error": "relay"]).code, .signer)
        XCTAssertEqual(CardFailure.from(status: 409, body: ["error": "unsupported"]).code, .unsupported)
        XCTAssertEqual(CardFailure.from(status: 500, body: ["error": "boom", "message": "never shown"]).code, .failed)
        let taken = CardFailure.from(status: 409, body: ["error": "claimed", "group": "pod-x", "invite": "abcdefghijklmnopqrstuvwx"])
        XCTAssertEqual(taken, CardFailure(.claimed, group: "pod-x", invite: "abcdefghijklmnopqrstuvwx"))
        let wrong = CardFailure.from(status: 400, body: ["error": "wrong_code", "tries_left": 2])
        XCTAssertEqual(wrong.text(), "That code is not right. 2 tries left.")
        XCTAssertTrue(wrong.clearsCode)
        XCTAssertEqual(CardFailure(.wrongCode, triesLeft: 1).text(), "That code is not right. 1 try left.")
        XCTAssertEqual(CardFailure(.wrongCode, triesLeft: 0).text(), "That code is not right. Send a new one.")
        XCTAssertEqual(CardFailure.from(status: 422, body: ["error": "invalid", "field": "hashtag"]).text(.topic), "Use letters, digits and dashes, 2 to 30 characters.")
        XCTAssertEqual(CardFailure.from(status: 422, body: ["error": "invalid", "field": "title"]).text(.topic), "Please give the topic’s name, up to 80 characters.")
        XCTAssertEqual(CardFailure(.claimed).text(.topic), "Someone just started this topic.")
        XCTAssertFalse(CardFailure(.offline).clearsCode)
        // every code has words of this app
        for c in CardError.allCases { XCTAssertFalse(CardFailure(c).text().isEmpty) }
    }

    func testHashtag() {
        XCTAssertEqual(Cards.hashtagSlug("Tool library"), "tool-library")
        XCTAssertEqual(Cards.hashtagSlug("  ##Gluten-free  Baking!! "), "gluten-free-baking")
        XCTAssertEqual(Cards.hashtagSlug("Café & thé"), "caf-th")
        XCTAssertEqual(Cards.hashtagSlug("---"), "")
        XCTAssertEqual(Cards.hashtagSlug(String(repeating: "a", count: 40)).count, 30)
        XCTAssertEqual(Cards.nextHashtag("tool-library", 2), "tool-library-2")
        XCTAssertEqual(Cards.nextHashtag(String(repeating: "a", count: 30), 3), String(repeating: "a", count: 28) + "-3")
        XCTAssertNil(Cards.nextHashtag("x", 10))
    }

    func testBodies() {
        let f = CardForm(title: "  Tool   library ", about: " Borrow drills. ", hashtag: "#Tool Library", name: " Dev  Patel ", email: " dev@example.org ")
        let g = Cards.claimBody(.group, f)
        XCTAssertEqual(g["title"] as? String, "Tool library")
        XCTAssertEqual(g["about"] as? String, "Borrow drills.")
        XCTAssertNil(g["hashtag"], "a group card sends no hashtag")
        XCTAssertEqual(Cards.claimBody(.topic, f)["hashtag"] as? String, "tool-library")
        let v = Cards.verifyBody(.topic, f, code: " 123456 ")
        XCTAssertEqual(v["email"] as? String, "dev@example.org")
        XCTAssertEqual(v["code"] as? String, "123456")
        XCTAssertEqual(v["name"] as? String, "Dev Patel")
        XCTAssertEqual(v["client"] as? String, "belfry-ios")
        XCTAssertEqual(Set(v.keys), ["title", "about", "hashtag", "email", "code", "name", "client"])
        // what may be sent
        XCTAssertTrue(f.ready(.group, tag: nil, signedIn: false))
        XCTAssertFalse(f.ready(.topic, tag: .taken, signedIn: true))
        XCTAssertTrue(f.ready(.topic, tag: .free, signedIn: true))
        XCTAssertFalse(CardForm(title: "x").ready(.group, tag: nil, signedIn: false), "a visitor gives a name and an e-mail")
        XCTAssertTrue(CardForm(title: "x").ready(.group, tag: nil, signedIn: true))
        XCTAssertFalse(CardForm(title: " ").ready(.group, tag: nil, signedIn: true))
    }

    func testGroupCard() {
        let c = CardOfGroup.parse(["id": "K7Q2MX", "kind": "group", "started_by": ["name": "Lou", "pubkey": ANA], "joined_by_scan": 8])
        XCTAssertEqual(c?.line, "Started by Lou · 8 people joined by scanning it")
        XCTAssertEqual(CardOfGroup.parse(["id": "K7Q2MX", "joined_by_scan": 1])?.line, "1 person joined by scanning it")
        XCTAssertNil(CardOfGroup.parse(["id": "nope"]))
    }

    /// The groups key signs a card's group for the claimer: `by` names them (docs/cards.md).
    func testWhoMadeIt() {
        let pod = "pod-sourdough-x1y2"
        let evs = [
            ev(GK, 9007, 100, [["h", pod], ["by", ANA]]),
            ev(GK, 9002, 101, [["h", pod], ["name", "Sourdough starters"], ["open"], ["public"], ["by", ANA]]),
            ev(GK, 9000, 102, [["h", pod], ["p", ANA, "admin"], ["role", "admin"], ["by", ANA]]),
            ev(GK, 9, 103, [["h", "general"], ["pod", pod], ["by", ANA]], "⬡ New group: Sourdough starters"),
            ev(GK, 9, 104, [["h", pod], ["p", ANA], ["card", "1"]], "Ana started this group from a printed card"),
            // an older card: no `by` anywhere, only the first line names the person
            ev(GK, 9007, 200, [["h", "pod-old-aaaa"]]),
            ev(GK, 9, 201, [["h", "pod-old-aaaa"], ["p", ME], ["card", "1"]], "Sam started this group from a printed card"),
            ev(GK, 9, 202, [["h", "general"], ["pod", "pod-old-aaaa"]], "⬡ New group: Old"),
            // the belfry's own posts stay the belfry's
            ev(GK, 9, 203, [["h", "pod-old-aaaa"], ["client", "belfry-mail-out"]], "sent"),
            ev(ANA, 9, 204, [["h", "general"], ["by", ME]], "mine, whatever it says"),
        ]
        let d = Derive(events: evs, context: WorldContext(me: ME, groupsKey: GK))
        XCTAssertEqual(d.group(pod)?.admins.contains(ANA), true, "its creator administers it")
        let town = d.messages("general")
        XCTAssertEqual(town[0].pubkey, ANA)
        XCTAssertEqual(town[0].special, .podCard(podId: pod))
        XCTAssertEqual(town[1].pubkey, ME, "the claimer by the card's first line")
        XCTAssertEqual(town[2].pubkey, ANA, "`by` counts on the groups key's events only")
        XCTAssertEqual(d.messages(pod)[0].pubkey, ANA)
        XCTAssertEqual(d.messages("pod-old-aaaa").map(\.pubkey), [ME, GK])
        XCTAssertFalse(d.canDelete(d.messages("pod-old-aaaa")[0]), "signed by the groups key: not mine to delete")
        // without the groups key nothing is re-attributed
        XCTAssertEqual(Derive(events: evs, me: ME).messages("general")[0].pubkey, GK)
    }

    func testNewTopicPost() {
        let e = ev(GK, 9, 100, [["h", "general"], ["t", "new-topic"], ["channel", "tool-library"], ["by", ANA]], "# New topic: #tool-library · Tool library · Borrow drills")
        XCTAssertEqual(Derive.newTopicOf(e), "tool-library")
        XCTAssertNil(Derive.newTopicOf(ev(ANA, 9, 100, [["h", "general"], ["t", "new-topic"]])))
        let d = Derive(events: [e], context: WorldContext(me: ME, groupsKey: GK))
        XCTAssertEqual(d.messages("general")[0].special, .topicCard(channel: "tool-library"))
        XCTAssertEqual(d.messages("general")[0].pubkey, ANA)
        XCTAssertEqual(CardTopicWords.parts(about: "Tool library · Borrow drills · and saws", post: ""), CardTopicWords(topic: "Tool library", about: "Borrow drills · and saws"))
        XCTAssertEqual(CardTopicWords.parts(about: nil, post: "# New topic: #tool-library · Tool library · Borrow drills\nhttps://chat.example.org/#/c/tool-library"),
                       CardTopicWords(topic: "Tool library", about: "Borrow drills"))
    }

    /// A reading guest in a topic reached by a card posts a plain message with photos; nothing else.
    func testGuestTopicPost() async throws {
        XCTAssertTrue(Cards.guestTopicPost(kind: 9, tags: [["h", "tools"]], topic: "tools"))
        XCTAssertTrue(Cards.guestTopicPost(kind: 9, tags: [["h", "tools"], ["imeta", "url https://x/y.jpg"]], topic: "tools", fileTypes: ["image/jpeg"]))
        XCTAssertFalse(Cards.guestTopicPost(kind: 9, tags: [["h", "tools"]], topic: "tools", fileTypes: ["application/pdf"]))
        XCTAssertFalse(Cards.guestTopicPost(kind: 9, tags: [["h", "general"]], topic: "tools"))
        XCTAssertFalse(Cards.guestTopicPost(kind: 9, tags: [["h", "tools"], ["t", "x"]], topic: "tools"))
        XCTAssertFalse(Cards.guestTopicPost(kind: 9, tags: [["h", "tools"], ["h", "general"]], topic: "tools"))
        XCTAssertFalse(Cards.guestTopicPost(kind: 7, tags: [["h", "tools"]], topic: "tools"))
        XCTAssertFalse(Cards.guestTopicPost(kind: 9, tags: [["h", "tools"]], topic: nil))

        let db = try Database.memory()
        let me = try LocalSigner(secret: Keys.generateSecret())
        let e = SyncEngine(config: .defaults(domain: "example.org"), db: db, signer: me, localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        var asked = 0
        e.guestMode.onRefused = { asked += 1 }
        e.guestMode.reading = true
        e.guestMode.cardTopic = "tools"
        XCTAssertNotEqual(e.enqueue(Actions.guestTopicPost("tools", text: "Spare drill at no. 7")), "")
        XCTAssertEqual(e.enqueue(Actions.guestTopicPost("general", text: "hi")), "")
        XCTAssertEqual(e.enqueue(Actions.react("tools", messageId: String(repeating: "1", count: 64), author: ANA, emoji: "👍")), "")
        XCTAssertEqual(e.enqueue(Actions.seen("tools")), "")
        XCTAssertEqual(asked, 3)
        XCTAssertEqual(e.outboxItems().count, 1)
        XCTAssertNoThrow(try e.guestMode.checkUpload(mime: "image/png"))
        XCTAssertThrowsError(try e.guestMode.checkUpload(mime: "application/pdf"))
        e.guestMode.cardTopic = nil
        XCTAssertThrowsError(try e.guestMode.checkUpload(mime: "image/png"))
        XCTAssertEqual(e.enqueue(Actions.guestTopicPost("tools", text: "again")), "")
        // joined: everything goes
        e.guestMode.reading = false
        XCTAssertNoThrow(try e.guestMode.checkUpload(mime: "application/pdf"))
    }

    func testFollowers() {
        let ids = ["tool-library", "pod-x", "ev-x", "prop-x"]
        let d = Derive(events: ids.enumerated().map { i, id in ev(ANA, 9007, 100 + i, [["h", id]]) }, me: ME)
        guard let ch = d.group(ids[0]), let pod = d.group(ids[1]), let event = d.group(ids[2]), let prop = d.group(ids[3]) else { return XCTFail("groups") }
        XCTAssertEqual(ch.peopleTitle, "Followers")
        XCTAssertEqual(ch.peopleCount(1), "1 follower")
        XCTAssertEqual(ch.peopleCount(12), "12 followers")
        for g in [pod, event, prop] {
            XCTAssertEqual(g.peopleTitle, "Members")
            XCTAssertEqual(g.peopleCount(1), "1 member")
            XCTAssertEqual(g.peopleCount(8), "8 members")
        }
    }
}
