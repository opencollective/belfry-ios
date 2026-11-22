import XCTest
@testable import BelfryCore

/// vectors/one-shape.json: replyAll, threadState, drafts (belfry-android's file, copied byte for byte).
final class OneShapeMailTests: XCTestCase {
    func testReplyAll() throws {
        for c in try vector("one-shape").dict("replyAll").list("cases") {
            let r = MailReplyAll.recipients(mailFrom: c.str("mailFrom")!, tags: tags(c["tags"]), domain: c.str("domain")!)
            let w = c.dict("expect")
            XCTAssertEqual(r.rcptTo, w.strs("rcptTo"), c.str("name")!)
            XCTAssertEqual(r.to, w.str("to"), c.str("name")!)
            XCTAssertEqual(r.cc, w.strs("cc"), c.str("name")!)
        }
    }

    func testThreadState() throws {
        for c in try vector("one-shape").dict("threadState").list("cases") {
            let received = (c["received"] as? [NSNumber] ?? []).map(\.intValue)
            var labels = c.list("labels").map { MailThreadState.Label(id: $0.str("id")!, at: $0.int("created_at")!, value: $0.str("l")!) }
            // a sent reply card counts as an `answered` label at its time (vectors 3fe5202)
            for (i, at) in (c["sent"] as? [NSNumber] ?? []).enumerated() { labels.append(MailThreadState.Label(id: "sent\(i)", at: at.intValue, value: "answered")) }
            XCTAssertEqual(MailThreadState.state(received: received, labels: labels), c.str("expect"), c.str("name")!)
        }
    }

    func testDrafts() throws {
        for c in try vector("one-shape").dict("drafts").list("cases") {
            let drafts = c.list("drafts").map { MailDrafts.Draft(id: $0.str("id")!, pubkey: $0.str("pubkey")!) }
            let sent = c.list("sent").map { tags($0["tags"]) }
            let del = c.list("deletions").map { (pubkey: $0.str("pubkey")!, e: $0.str("e")!) }
            XCTAssertEqual(MailDrafts.visible(drafts, sentTags: sent, deletions: del), c.strs("expect"), c.str("name")!)
        }
    }

    func testOwnDomain() {
        XCTAssertTrue(MailReplyAll.isOwn("a@x.org", domain: "x.org"))
        XCTAssertTrue(MailReplyAll.isOwn("a@mail.x.org", domain: "x.org"))
        XCTAssertFalse(MailReplyAll.isOwn("a@notx.org", domain: "x.org"))
    }

    /// An e-mail's thread: what went out counts as answered; a newer e-mail reopens it; drafts are
    /// not team replies and hide once a sent card names them.
    func testThreadWithDraftAndSentCard() {
        let key = String(repeating: "9", count: 64), ana = String(repeating: "a", count: 64)
        func id(_ n: Int) -> String { String(format: "%064x", n) }
        let inbox = NostrEvent(id: id(1), pubkey: key, createdAt: 100, kind: 9, tags: [["h", "c"], ["client", "belfry-mail"], ["mail-from", "lou@example.org"],
            ["subject", "Park"], ["message-id", "<1@x>"], ["to", "contact@r.example", "Contact"], ["cc", "dev@example.net", "Dev"]], content: "Hello")
        let draft = NostrEvent(id: id(2), pubkey: ana, createdAt: 110, kind: 1111, tags: [["h", "c"], ["E", id(1), "", key], ["K", "9"], ["e", id(1), "", key], ["k", "9"], ["mail-draft", "1"]], content: "Hi Lou")
        let team = NostrEvent(id: id(3), pubkey: ana, createdAt: 111, kind: 1111, tags: [["h", "c"], ["E", id(1), "", key], ["K", "9"], ["e", id(1), "", key], ["k", "9"]], content: "I'll answer")
        let d1 = Derive(events: [inbox, draft, team], context: WorldContext(me: ana, domain: "r.example", groupsKey: key))
        let t1 = d1.mailThread("c", of: id(1))!
        XCTAssertEqual(d1.mailDrafts("c", t1).map(\.id), [id(2)])
        XCTAssertEqual(d1.mailThreadReplies("c", t1).map(\.id), [id(3)])
        XCTAssertEqual(t1.replyAll(domain: "r.example"), .init(rcptTo: ["lou@example.org", "dev@example.net"], to: "lou@example.org", cc: ["dev@example.net"]))
        XCTAssertEqual(t1.state.status, .open)
        let sent = NostrEvent(id: id(4), pubkey: key, createdAt: 120, kind: 9, tags: [["h", "c"], ["client", "belfry-mail-out"], ["e", id(1), "", "reply"], ["draft", id(2)]], content: "Hi Lou")
        let d2 = Derive(events: [inbox, draft, team, sent], context: WorldContext(me: ana, domain: "r.example", groupsKey: key))
        let t2 = d2.mailThread("c", of: id(1))!
        XCTAssertEqual(d2.mailDrafts("c", t2), [])
        XCTAssertEqual(t2.state.status, .waiting)
        let again = NostrEvent(id: id(5), pubkey: key, createdAt: 130, kind: 9, tags: [["h", "c"], ["client", "belfry-mail"], ["mail-from", "lou@example.org"],
            ["subject", "Re: Park"], ["in-reply-to", "<1@x>"], ["message-id", "<5@x>"]], content: "Thanks")
        let d3 = Derive(events: [inbox, draft, team, sent, again], context: WorldContext(me: ana, domain: "r.example", groupsKey: key))
        XCTAssertEqual(d3.mailThread("c", of: id(1))!.state.status, .open)
    }
}
