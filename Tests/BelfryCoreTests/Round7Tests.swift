import Foundation
import XCTest
@testable import BelfryCore

// Round 7 (2026-11-18, the owner's TestFlight remarks): to-dos claimed, assigned and unassigned
// (SPEC 19.41, vectors/todo-assign.json), a channel's name before its metadata and the metadata
// always asked whole (19.42), member links and a guest who became a member (19.43).

private let RELAY = String(repeating: "d", count: 64)
private let A = String(repeating: "a", count: 64)
private let B = String(repeating: "b", count: 64)
private let C = String(repeating: "c", count: 64)

private func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
    NostrEvent(id: Crypto.sha256("\(pk)\(kind)\(at)\(tags)\(c)").hex, pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
}

private func key(_ letter: String?) -> String? {
    guard let l = letter else { return nil }
    return ["A": A, "B": B, "C": C][l] ?? l
}

private func channel(_ id: String, _ name: String, members: [String], closed: Bool = false) -> [NostrEvent] {
    [ev(RELAY, 39000, 100, [["d", id], ["name", name]] + (closed ? [["closed"]] : [])),
     ev(RELAY, 39002, 100, [["d", id]] + members.map { ["p", $0] })]
}

final class TodoAssignTests: XCTestCase {
    func testVectors() throws {
        let v = try vector("todo-assign")
        for c in v.list("cases") {
            let label = c.str("name") ?? ""
            let task = ev(A, 2100, 100, Actions.taskTags("g"), "Fix the gate")
            var evs = [task]
            for (i, s) in (c["steps"] as? [[Any]] ?? []).enumerated() {
                let who = key(s[0] as? String)!, action = s[1] as! String, p = key(s[2] as? String)
                evs.append(ev(who, 2101, 110 + i, [["e", task.id], ["action", action]] + (p.map { [["p", $0]] } ?? []) + Actions.taskTags("g")))
            }
            let t = try XCTUnwrap(Derive(events: evs, me: A).tasks("g").first, label)
            XCTAssertEqual(t.assignee, key(c.str("assignee")), label)
            XCTAssertEqual(t.assignedBy, key(c.str("assigned_by")), label)
        }
        for w in v.list("wire") {
            let label = w.str("name") ?? ""
            let me = key(w.str("me"))!
            var evs = [ev(A, 2100, 100, Actions.taskTags("g"), "Fix the gate")]
            if let a = key(w.str("assignee")) { evs.append(ev(a, 2101, 101, [["e", evs[0].id], ["action", "claim"]] + Actions.taskTags("g"))) }
            let t = try XCTUnwrap(Derive(events: evs, me: me).tasks("g").first)
            let d = Actions.assignTask("g", task: t, to: key(w.str("to")), me: me)
            XCTAssertEqual(d.kind, 2101, label)
            let want = (w["tags"] as? [[String]] ?? []).map { $0.map { $0 == "<task>" ? t.id : key($0) ?? $0 } }
            XCTAssertEqual(d.tags, want + Actions.taskTags("g"), label)
        }
    }

    func testWhoLine() throws {
        let task = ev(A, 2100, 100, Actions.taskTags("g"), "Fix the gate")
        let assign = ev(A, 2101, 110, [["e", task.id], ["action", "assign"], ["p", B]] + Actions.taskTags("g"))
        let prof = ev(B, 0, 90, [], #"{"name":"Ben"}"#)
        let d = Derive(events: [prof, task, assign], me: A)
        XCTAssertEqual(d.todoWho(try XCTUnwrap(d.tasks("g").first)), "Ben is on it · assigned by you")
        let asBen = Derive(events: [prof, task, assign], me: B)
        XCTAssertTrue(asBen.todoWho(try XCTUnwrap(asBen.tasks("g").first)).hasPrefix("You are on it · assigned by "))
    }
}

final class ChannelNamesTests: XCTestCase {
    func testFallbackName() {
        // no name before the metadata, never the id (Xavier 2026-11-18): sentences say the kind
        XCTAssertEqual(Group.neutral("issues-5fce"), "this channel")
        XCTAssertEqual(Group.neutral("pod-bees-1a2b", capital: true), "This group")
        XCTAssertEqual(Group.neutral("ev-1a2b3c"), "this event")
        XCTAssertEqual(Group.kindTitle("prop-rules-cd"), "Proposal")
        // a reference to a channel whose name is unknown: the kind's word, the naddr kept behind it
        XCTAssertEqual(ChannelRefs.unknownLabel("tools-2b8e"), "channel")
        XCTAssertEqual(ChannelRefs.unknownLabel("pod-bees-1a2b"), "group")
        let two = ChannelRefs.substitute("see #channel and #channel", picked: [("#channel", "nostr:naddr1a"), ("#channel", "nostr:naddr1b")])
        XCTAssertEqual(two, "see nostr:naddr1a and nostr:naddr1b")
    }

    func testNameBeforeAndAfterMetadata() throws {
        let msg = ev(B, 9, 500, [["h", "issues-5fce"]], "the gate is stuck")
        let before = Derive(events: [msg], me: A)
        XCTAssertEqual(before.group("issues-5fce")?.named, false)
        XCTAssertEqual(before.group("issues-5fce")?.name, "")
        XCTAssertEqual(before.label("issues-5fce"), "this channel")
        // the metadata arrives later (even with an older created_at): its name is shown
        let after = Derive(events: [msg, ev(RELAY, 39000, 100, [["d", "issues-5fce"], ["name", "Issues"]])], me: A)
        XCTAssertEqual(after.group("issues-5fce")?.name, "Issues")
        XCTAssertEqual(after.group("issues-5fce")?.rawName, "Issues")
    }

    func testMetadataAlwaysAskedWhole() throws {
        let path = NSTemporaryDirectory() + "belfry-test-\(UUID().uuidString).sqlite"
        let db = try Database(path: path)
        let me = try LocalSigner(secret: Keys.generateSecret())
        let e = SyncEngine(config: .defaults(domain: "example.org"), db: db, signer: me, localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        let signed = try me.signNow(EventTemplate(kind: 9, content: "hi", tags: [["h", "general"]], createdAt: 1_800_000_000))
        _ = e.add([ev(RELAY, 39000, 100, [["d", "general"], ["name", "general"]]), signed], verify: false)
        let f = e.filters(.groups)
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(f[0]["since"] as? Int, 1_800_000_000 - 3600)
        XCTAssertNil(f[1]["since"], "metadata: no since")
        XCTAssertEqual(f[1]["kinds"] as? [Int], [39000, 39001, 39002, 39003])
        // the charter: every agreement ever added, whatever the newest stored event (Xavier 2026-11-18)
        XCTAssertEqual(f[2]["kinds"] as? [Int], [2100])
        XCTAssertEqual(f[2]["#h"] as? [String], [Derive.charterId])
        XCTAssertNil(f[2]["since"]); XCTAssertNil(f[3]["since"])
        XCTAssertEqual(f[3]["kinds"] as? [Int], [2101])
        // after a guest became a member (stored, so it survives a restart): everything from the start
        db.set("full-sync", ["groups", "main"])
        let e2 = SyncEngine(config: .defaults(domain: "example.org"), db: try Database(path: path), signer: me, localOnly: true,
                            attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertEqual(e2.filters(.groups)[0]["since"] as? Int, 0)
        XCTAssertEqual(e2.filters(.main)[0]["since"] as? Int, 0)
        e2.eose(.groups, "live-groups")
        XCTAssertEqual(e2.filters(.groups)[0]["since"] as? Int, 1_800_000_000 - 3600)
        XCTAssertEqual(e2.filters(.main)[0]["since"] as? Int, 0, "main still waits for its own EOSE")
    }
}

final class MemberLinkTests: XCTestCase {
    func testParse() throws {
        let m = try XCTUnwrap(MemberLinkInfo.parse(["as": "member", "member_role": "host", "member_role_label": " Host ", "membership": "year"]))
        XCTAssertEqual(m, MemberLinkInfo(role: "host", label: "Host", membership: "year"))
        XCTAssertEqual(m.asWho, "a Host")
        XCTAssertEqual(m.lengthLine, ", for a year")
        XCTAssertNil(MemberLinkInfo.parse(["as": "guest", "member_role": "host"]))
        XCTAssertNil(MemberLinkInfo.parse([:]))
        let plain = try XCTUnwrap(MemberLinkInfo.parse(["as": "member", "membership": "forever"]))
        XCTAssertEqual(plain, MemberLinkInfo(role: "member", label: "Member", membership: "permanent"))
        XCTAssertEqual(plain.lengthLine, "")
        XCTAssertEqual(MemberLinkInfo(role: "admin", label: "Admin", membership: "month").asWho, "an Admin")
    }

    /// A guest of #general (its guest join, reading) who became a member through a member link:
    /// the register's word (kinds) makes them a member everywhere at once, before any relay event.
    func testGuestBecameMember() throws {
        var evs = channel("general", "general", members: [A, B]) + channel("garden-3f2a", "Garden", members: [C]) + channel("board-5d1e", "Board", members: [C], closed: true)
        evs.append(ev(RELAY, 9000, 200, [["h", "general"], ["p", B, "member"], ["guest", "2026-12-12"], ["invited-by", A], ["unsaved", "1"], ["reading", "1"]]))
        let asGuest = Derive(events: evs, me: B)
        XCTAssertTrue(asGuest.amGuest)
        XCTAssertTrue(asGuest.amReading("general"))
        XCTAssertEqual(asGuest.readableChannels().map(\.id), ["general"], "a guest reads only their own")
        let asMember = Derive(events: evs, context: WorldContext(me: B, kinds: [B: "member"]))
        XCTAssertFalse(asMember.amGuest)
        XCTAssertFalse(asMember.amReading("general"))
        XCTAssertTrue(asMember.guestJoinsOf(B).isEmpty)
        // SPEC 19.42: every open channel (not in its 39002), not a closed one they are not in
        XCTAssertEqual(Set(asMember.readableChannels().map(\.id)), ["general", "garden-3f2a"])
        // the drawer still lists the closed one (with Ask to join)
        XCTAssertTrue(asMember.townChannels().contains { $0.id == "board-5d1e" })
    }

    func testFreshMemberSeesEveryOpenChannel() {
        let evs = channel("general", "general", members: [A]) + channel("issues-5fce", "issues", members: [A]) + channel("board-5d1e", "Board", members: [B], closed: true)
        let d = Derive(events: evs, me: B) // B is in no open channel's 39002
        XCTAssertEqual(Set(d.readableChannels().map(\.id)), ["general", "issues-5fce", "board-5d1e"])
        let other = Derive(events: evs, me: C)
        XCTAssertEqual(Set(other.readableChannels().map(\.id)), ["general", "issues-5fce"])
        XCTAssertEqual(other.group("issues-5fce")?.name, "issues")
    }
}

final class NoIdsAsTextTests: XCTestCase {
    /// Xavier 2026-11-18: never a key, a group id or an event's d as text.
    func testUnknownPeopleAndLists() {
        let ana = ev(A, 0, 1, [], #"{"name":"Ana"}"#)
        let d = Derive(events: [ana], me: String(repeating: "f", count: 64))
        XCTAssertEqual(d.displayName(B), "Somebody")
        XCTAssertEqual(d.namesLine([A]), "Ana")
        XCTAssertEqual(d.namesLine([A, B]), "Ana and one other")
        XCTAssertEqual(d.namesLine([B, RELAY]), "2 people")
        XCTAssertEqual(d.namesLine([B]), "one person")
    }

    func testGroupLabels() {
        let d = Derive(events: [ev(RELAY, 39000, 100, [["d", "garden-1a2b"], ["name", "Garden"]]), ev(B, 9, 101, [["h", "pod-bees-1a2b"]], "hi")], me: A)
        XCTAssertEqual(d.label("garden-1a2b"), "#Garden")
        XCTAssertEqual(d.label("pod-bees-1a2b"), "this group")
        XCTAssertEqual(d.label("ev-zz9a1b"), "this event")
        XCTAssertFalse(d.group("pod-bees-1a2b")!.named)
    }
}

final class MentionRangesTests: XCTestCase {
    /// The composer marks each picked name, spaces included, and nothing else.
    func testRangesOfPickedLabels() {
        let text = "@OSV website agent what's the minimum? cc @OSV and @OSV website agent, in #Garden"
        let r = Mentions.ranges(in: text, labels: ["@OSV", "@OSV website agent", "#Garden", "@OSV"])
        let ns = text as NSString
        XCTAssertEqual(r.map { ns.substring(with: $0) }, ["@OSV website agent", "@OSV", "@OSV website agent", "#Garden"])
        XCTAssertEqual(r.first, NSRange(location: 0, length: 18))
        XCTAssertTrue(Mentions.ranges(in: "no mention here", labels: ["@Ana"]).isEmpty)
        // an emoji before it: UTF-16 offsets
        XCTAssertEqual(Mentions.ranges(in: "👋 @Ana Silva hi", labels: ["@Ana Silva"]), [NSRange(location: 3, length: 10)])
    }
}

final class ReplyReactionsTests: XCTestCase {
    /// A reaction on a reply in a thread (kind 1111): NIP-25 with `k` = 1111, read like any other.
    func testReactToAReply() {
        let root = ev(A, 9, 100, [["h", "g"]], "root")
        let reply = ev(B, 1111, 110, [["h", "g"], ["E", root.id], ["e", root.id]], "a reply")
        let dr = Actions.react("g", messageId: reply.id, author: B, emoji: "🙏", kind: 1111)
        XCTAssertEqual(dr.kind, 7)
        XCTAssertTrue(dr.tags.contains(["k", "1111"]))
        XCTAssertTrue(Actions.react("g", messageId: root.id, author: A, emoji: "👍").tags.contains(["k", "9"]))
        let d = Derive(events: [root, reply, ev(A, 7, 120, dr.tags, dr.content)], me: A)
        XCTAssertEqual(d.reactions("g")[reply.id]?.first?.emoji, "🙏")
        XCTAssertNotNil(d.reactions("g")[reply.id]?.first?.mine)
    }
}

final class TodoLimitTests: XCTestCase {
    /// A to-do's text is never cut silently: the form says how far over it is and refuses it.
    func testLimitLine() {
        XCTAssertNil(Actions.taskLimitLine("Order compost"))
        XCTAssertEqual(Actions.taskOver("  " + String(repeating: "a", count: 300) + " \n"), 0)
        XCTAssertEqual(Actions.taskLimitLine(String(repeating: "a", count: 250)), "250 of 300")
        XCTAssertEqual(Actions.taskOver(String(repeating: "a", count: 301)), 1)
        XCTAssertEqual(Actions.taskLimitLine(String(repeating: "a", count: 301)), "1 character too long. A to-do holds 300; put the rest in a comment on it.")
        XCTAssertEqual(Actions.taskOver(String(repeating: "👋", count: 151)), 2)
        XCTAssertEqual(Actions.addTask("g", title: String(repeating: "a", count: 300)).content.utf16.count, 300)
    }
}

/// Applying with no link (onboarding/apply-form; Belfry 8b0331d POST /apply): Android's ApplyFormTest.
final class ApplyFormTests: XCTestCase {
    func testTheBody() {
        let b = ApplyForm.body(email: " lina@example.org ", motivation: " I live on Mill Street ", agreed: ["a1", "b2"])
        XCTAssertEqual(b["email"] as? String, "lina@example.org")
        XCTAssertEqual(b["motivation"] as? String, "I live on Mill Street")
        XCTAssertEqual(b["agreed"] as? [String], ["a1", "b2"])
        XCTAssertEqual(b["website"] as? String, "")
        XCTAssertEqual((ApplyForm.body(email: String(repeating: "x", count: 500), motivation: "y", agreed: [])["email"] as? String)?.count, 200)
    }

    func testTheWords() {
        func err(_ code: String, _ message: String? = nil) -> [String: Any] { message.map { ["error": code, "message": $0] } ?? ["error": code] }
        XCTAssertEqual(ApplyForm.error(status: 400, body: err("unticked", "server words")), ApplyForm.unticked)
        XCTAssertEqual(ApplyForm.error(status: 400, body: err("missing")), ApplyForm.missing)
        XCTAssertEqual(ApplyForm.error(status: 400, body: err("bad_request")), ApplyForm.missing)
        XCTAssertEqual(ApplyForm.error(status: 400, body: err("refused", " This address can't receive mail. ")), "This address can't receive mail.")
        XCTAssertEqual(ApplyForm.error(status: 400, body: err("refused", String(repeating: "z", count: 900))).count, 300)
        XCTAssertEqual(ApplyForm.error(status: 400, body: err("refused")), ApplyForm.other)
        XCTAssertEqual(ApplyForm.error(status: 429, body: nil), ApplyForm.busy)
        XCTAssertEqual(ApplyForm.error(status: 500, body: nil), ApplyForm.other)
    }

    func testTheButton() {
        XCTAssertEqual(ApplyForm.button(ticked: 2, of: 3), "Tick each agreement (2 of 3)")
        XCTAssertEqual(ApplyForm.button(ticked: 3, of: 3), "Send my request")
        XCTAssertEqual(ApplyForm.button(ticked: 0, of: 0), "Send my request")
    }
}

final class NoLinkTests: XCTestCase {
    /// What people type for a belfry: its address, its chat's address, a pasted link.
    func testDomain() {
        XCTAssertEqual(NoLink.domain(" Belfry.sh "), "belfry.sh")
        XCTAssertEqual(NoLink.domain("https://chat.belfry.sh/c/general?x=1"), "belfry.sh")
        XCTAssertEqual(NoLink.domain("belfry.belfry.sh"), "belfry.sh")
        XCTAssertEqual(NoLink.domain("chat.example"), "chat.example")
        XCTAssertEqual(NoLink.domain("riverside.example/"), "riverside.example")
    }

    /// An invitation: its link as it is, or its bare code at this belfry; nothing else.
    func testInvite() {
        let token = "demoinvite0123456789abcd"
        XCTAssertEqual(NoLink.invite(" https://chat.belfry.sh/join/\(token) ", domain: "other.example")?.absoluteString, "https://chat.belfry.sh/join/\(token)")
        XCTAssertEqual(NoLink.invite(token, domain: "riverside.example")?.absoluteString, "https://chat.riverside.example/join/\(token)")
        XCTAssertNil(NoLink.invite("https://evil.example/join/\(token)", domain: "riverside.example"))
        XCTAssertNil(NoLink.invite("hello there", domain: "riverside.example"))
    }
}
