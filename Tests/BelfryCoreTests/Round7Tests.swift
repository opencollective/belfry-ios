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

final class MessageLinkTests: XCTestCase {
    /// Board channels/message-link: where …/#/c/<channel>/m/<event> leads.
    func testWhereAMessageLinkLeads() {
        let meta = ev(RELAY, 39000, 100, [["d", "g"], ["name", "Garden"]])
        let root = ev(A, 9, 110, [["h", "g"]], "root")
        let reply = ev(B, 1111, 120, [["h", "g"], ["E", root.id], ["e", root.id]], "a reply")
        let gone = ev(B, 9, 130, [["h", "g"]], "oops")
        let del = ev(B, 5, 140, [["h", "g"], ["e", gone.id]])
        let d = Derive(events: [meta, root, reply, gone, del], me: A)
        XCTAssertEqual(d.messagePlace("g", root.id), .message)
        XCTAssertEqual(d.messagePlace("g", reply.id), .reply(root: root.id))
        XCTAssertEqual(d.messagePlace("g", gone.id), .missing)
        XCTAssertEqual(d.messagePlace("g", String(repeating: "0", count: 64)), .missing)
        XCTAssertEqual(d.messagePlace("nowhere", root.id), .missing)
        XCTAssertEqual(Derive(events: [meta, root], context: WorldContext(me: A, domain: "belfry.sh")).messageURL("g", root.id), "https://chat.belfry.sh/#/c/g/m/" + root.id)
    }
}

/// References in a message (vectors/references.json, copied byte for byte from the web chat,
/// commonshub/collective-belfry branch chat-source, sha256 5df35e6a5fc0b040…).
final class ReferencesTests: XCTestCase {
    func testVectors() throws {
        let v = try vector("references")
        let domain = try XCTUnwrap(v.str("domain"))
        func target(_ o: [String: Any]) -> RefTarget? {
            switch o["type"] as? String {
            case "group": return .group(o["id"] as? String ?? "")
            case "event": return .event(link: o["link"] as? String, coord: o["coord"] as? String)
            case "proposal": return .proposal(o["coord"] as? String ?? "")
            case "todo": return .todo(group: o["group"] as? String ?? "", task: o["task"] as? String ?? "")
            case "message": return .message(group: o["group"] as? String, link: o["link"] as? String, id: o["id"] as? String ?? "")
            case "person": return .person(o["pubkey"] as? String ?? "")
            case "drop": return .drop(o["token"] as? String ?? "")
            default: return nil
            }
        }
        let cases = v.list("cases")
        XCTAssertEqual(cases.count, 43)
        let known = v.dict("known")
        for c in cases {
            let want: [RefPart] = try (c["parts"] as? [[String: Any]] ?? []).map { p in
                if let t = p["text"] as? String { return .text(t) }
                if let r = p["ref"] as? [String: Any] { return .ref(try XCTUnwrap(target(r))) }
                return .box(try XCTUnwrap(target(p["box"] as? [String: Any] ?? [:])))
            }
            XCTAssertEqual(References.parts(c.str("text") ?? "", domain: domain), want, c.str("name") ?? "")
            // as plain text (one-line previews): the known name, else the generic word
            XCTAssertEqual(References.plain(c.str("text") ?? "", domain: domain) { known[References.refKey($0)] as? String }, c.str("plain"), "plain: " + (c.str("name") ?? ""))
        }
    }

    /// The text drawn: the box taken out, the rest as written.
    func testSplit() {
        let d = "riverside.example"
        let a = References.split("Seed talk carries on here https://chat.riverside.example/#/c/garden \n", domain: d)
        XCTAssertEqual(a.text, "Seed talk carries on here")
        XCTAssertEqual(a.box, .group("garden"))
        let b = References.split("Is it https://chat.riverside.example/#/c/garden?", domain: d)
        XCTAssertEqual(b.text, "Is it https://chat.riverside.example/#/c/garden?")
        XCTAssertNil(b.box)
        XCTAssertEqual(References.split("https://riverside.example/events/repair-cafe", domain: d).text, "")
    }

    /// Routes the vectors don't spell out (refs.ts routeRef): a thread's reply, a topic, a page
    /// that isn't one, an empty segment, a bad escape.
    func testRoutes() {
        let d = "riverside.example", h = "https://chat.riverside.example/#/", x = String(repeating: "ab", count: 32)
        XCTAssertEqual(References.target(h + "c/garden/thread/\(x)/reply", domain: d), .message(group: "garden", link: nil, id: x))
        XCTAssertEqual(References.target(h + "c/garden/t/seeds", domain: d), .group("garden"))
        XCTAssertNil(References.target(h + "c/garden/settings", domain: d))
        XCTAssertNil(References.target(h + "c/garden/files/x", domain: d))
        XCTAssertNil(References.target(h + "c//m/\(x)", domain: d))
        XCTAssertNil(References.target(h + "c/%E9", domain: d))
        XCTAssertNil(References.target(h + "u/npub1nope", domain: d))
        XCTAssertNil(References.target(h + "events/repair-cafe/m/\(x)/more", domain: d))
        XCTAssertNil(References.target("https://riverside.example/drop/short", domain: d))
        XCTAssertNil(References.target("https://chat.riverside.example/drop/Zx81kQ_p-3aB9cD0", domain: d))
    }

    /// How the new kinds read: a to-do, a message, a person, a drop box (SPEC 19.61).
    func testShown() throws {
        let prof = ev(B, 0, 1, [], "{\"name\":\"Ben\"}")
        let msg = ev(B, 9, 110, [["h", "garden"]], "Bring   the\nseeds on Saturday")
        let task = ev(B, 2100, 200, Actions.addTask("garden", title: "Water the beds").tags, "Water the beds")
        let claim = ev(B, 2101, 210, Actions.taskAction("garden", taskId: task.id, action: "claim").tags)
        let d = Derive(events: channel("garden", "Garden", members: [A, B]) + channel("crew", "Crew", members: [B], closed: true) + [prof, msg, task, claim],
                       context: WorldContext(me: A, domain: "riverside.example"))
        let t = d.refShown(.todo(group: "garden", task: task.id))
        XCTAssertEqual(t.kind, .todo)
        XCTAssertEqual(t.name, "☐ Water the beds")
        XCTAssertEqual(t.line, "To-do in #Garden · Ben is on it")
        XCTAssertEqual(t.open, .todo(group: "garden", task: task.id))
        XCTAssertEqual(d.refShown(.todo(group: "crew", task: task.id)).kind, .locked)
        XCTAssertEqual(d.refShown(.message(group: "crew", link: nil, id: msg.id)).name, "a message in a closed channel")
        let m = d.refShown(.message(group: "garden", link: nil, id: msg.id))
        XCTAssertEqual(m.kind, .message)
        XCTAssertEqual(m.name, "a message from Ben")
        XCTAssertEqual(m.title, "Ben")
        XCTAssertEqual(m.line, "Message in #Garden")
        XCTAssertEqual(m.about, "Bring the seeds on Saturday")
        XCTAssertEqual(m.open, .message(group: "garden", id: msg.id))
        XCTAssertEqual(d.refShown(.message(group: "garden", link: nil, id: String(repeating: "0", count: 64))).kind, .unknown)
        XCTAssertEqual(d.refShown(.message(group: "nowhere", link: nil, id: msg.id)).name, "Message")
        let p = d.refShown(.person(B))
        XCTAssertEqual(p.name, "@Ben")
        XCTAssertEqual(p.open, .person(B))
        XCTAssertEqual(d.refShown(.todo(group: "garden", task: "nope")).name, "To-do")
        let drop = d.refShown(.drop("Zx81kQ_p-3aB9cD0"))
        XCTAssertEqual(drop.title, "Drop box")
        XCTAssertEqual(drop.open, .url("https://riverside.example/drop/Zx81kQ_p-3aB9cD0"))
        XCTAssertEqual(References.excerpt(String(repeating: "a", count: 200)).utf16.count, 160)
        // one-line previews: names, generic words, never the address
        let h = "https://chat.riverside.example/#/"
        XCTAssertEqual(d.plainRefs("Take \(h)c/garden/todo/\(task.id)"), "Take ☐ Water the beds")
        XCTAssertEqual(d.plainRefs("See \(h)c/garden/m/\(msg.id) and \(h)u/\(B)."), "See a message from Ben and @Ben.")
        XCTAssertEqual(d.plainRefs("See \(h)c/garden/todo/nope"), "See a to-do")
        XCTAssertEqual(d.plainRefs("In \(h)c/crew/m/\(msg.id)"), "In a message in a closed channel")
        XCTAssertEqual(d.plainRefs("Take \(h)c/garden/todo/\(task.id)", links: false), "Take \(h)c/garden/todo/\(task.id)")
        XCTAssertEqual(Rx("x").replace("x", with: NSRegularExpression.escapedTemplate(for: "@…")), "@…")
    }
}

/// Reactions to direct messages (vectors/dm-reactions.json, copied byte for byte from belfry-android).
final class DmReactionsTests: XCTestCase {
    func testReading() throws {
        let v = try vector("dm-reactions")
        let target = try XCTUnwrap(v.dict("message").str("id"))
        let cases = v.list("read")
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            var r = DmReactions()
            for o in c.list("rumors") {
                let ev = NostrEvent(id: o.str("id") ?? "", pubkey: o.str("pubkey") ?? "", createdAt: o.int("created_at") ?? 0, kind: o.int("kind") ?? 0,
                                    tags: tags(o["tags"]), content: o.str("content") ?? "")
                XCTAssertTrue(r.apply(ev))
            }
            let got = r.chips(target, viewer: c.str("viewer") ?? "")
            let want = c.list("chips").map { DmChip(emoji: $0.str("emoji") ?? "", who: $0.strs("who"), mine: $0["mine"] as? Bool ?? false) }
            XCTAssertEqual(got, want, c.str("name") ?? "")
        }
    }

    func testSendShape() throws {
        let v = try vector("dm-reactions")
        let people = v.dict("people")
        let me = try XCTUnwrap(people.str("me"))
        let all = [people.str("ana") ?? "", people.str("ben") ?? "", me]
        let m = v.dict("message")
        let add = v.dict("send").dict("add").dict("rumor")
        XCTAssertEqual(DmReactions.addTags(message: m.str("id") ?? "", author: m.str("pubkey") ?? "", participants: all, me: me), tags(add["tags"]))
        let rem = v.dict("send").dict("remove")
        XCTAssertEqual(DmReactions.removeTags(reaction: rem.str("reaction") ?? "", participants: all, me: me), tags(rem.dict("rumor")["tags"]))
    }
}

/// Ticket prices (vectors/ticket-prices.json: the server's price_of on these cases).
final class TicketPriceTests: XCTestCase {
    func testVectors() throws {
        let v = try vector("ticket-prices")
        let cases = v.list("cases")
        XCTAssertEqual(cases.count, 34)
        for c in cases {
            let name = c.str("name") ?? ""
            let p = TicketPrice.of(tags: tags(c["tags"]), now: c.int("now") ?? 0)
            let o = c.dict("out")
            XCTAssertEqual(p.priced, o["priced"] as? Bool, name)
            XCTAssertEqual(p.amount, o.str("amount"), name)
            XCTAssertEqual(p.currency, o.str("currency"), name)
            XCTAssertEqual(p.vat, o.str("vat"), name)
            XCTAssertEqual(p.vatIncluded, o["vat_included"] as? Bool, name)
            XCTAssertEqual(p.until, o.int("until"), name)
            XCTAssertEqual(p.onSale, o["on_sale"] as? Bool, name)
            XCTAssertEqual(p.line, c.str("line"), name)
        }
    }

    func testFromTheApi() {
        let p = TicketPrice.from(api: ["price": ["amount": "50", "currency": "EUR", "vat": "21", "vat_included": false, "until": 1798761600] as [String: Any],
                                       "on_sale": true, "needs_payment": true])
        XCTAssertEqual(p.line, "€50 + 21% VAT")
        XCTAssertEqual(p.until, 1798761600)
        XCTAssertEqual(TicketPrice.from(api: ["price": NSNull(), "needs_payment": true, "on_sale": true]).line, "Paid")
        XCTAssertEqual(TicketPrice.from(api: ["price": NSNull(), "needs_payment": true, "on_sale": false]).line, "Not on sale now")
        XCTAssertEqual(TicketPrice.from(api: ["title": "Seat"]).line, "Free")
        // the checkout (docs/sales.md §10): only with can_pay and an https page
        let buy: [String: Any] = ["price": ["amount": "50", "currency": "EUR"], "needs_payment": true, "on_sale": true, "can_pay": true,
                                  "checkout_url": "https://riverside.example/tickets/repair-cafe"]
        XCTAssertEqual(TicketPrice.from(api: buy).checkout, "https://riverside.example/tickets/repair-cafe")
        XCTAssertNil(TicketPrice.from(api: buy.merging(["can_pay": false]) { $1 }).checkout)
        XCTAssertNil(TicketPrice.from(api: buy.merging(["checkout_url": "javascript:alert(1)"]) { $1 }).checkout)
        XCTAssertNil(TicketPrice.from(api: buy.merging(["checkout_url": "http://riverside.example/x"]) { $1 }).checkout)
        XCTAssertNil(TicketPrice.from(api: buy.merging(["on_sale": false]) { $1 }).checkout)
        // a price that isn't in the fixed shape is never shown as written
        XCTAssertEqual(TicketPrice.from(api: ["price": ["amount": "<b>", "currency": "EUR"], "needs_payment": true]).line, "Paid")
    }
}

final class ReferenceTagsTests: XCTestCase {
    /// On send: an `a` tag for an event or a proposal named by its address in the text.
    func testATagsForNamedCoords() throws {
        let v = try vector("references")
        let c = try XCTUnwrap(v.list("cases").first { $0.str("name") == "inside the text: names" })
        let d = Derive(events: [], context: WorldContext(me: A, domain: v.str("domain") ?? ""))
        let tags = d.eventTagsFor(c.str("text") ?? "", mainRelay: "wss://relay.riverside.example")
        XCTAssertEqual(tags.map { $0[0] }, ["a", "a"])
        XCTAssertTrue(tags[0][1].hasPrefix("31923:"))
        XCTAssertTrue(tags[1][1].hasPrefix("30023:"))
        XCTAssertEqual(tags[0][2], "wss://relay.riverside.example")
        XCTAssertTrue(d.eventTagsFor("Just words and https://example.org", mainRelay: "wss://x").isEmpty)
    }
}

final class ChannelPostsTests: XCTestCase {
    /// Board channels/settings "Posts": the web settings' `posts`, the other keys kept.
    func testSetPosts() throws {
        let meta = ev(RELAY, 39000, 100, [["d", "garden"], ["name", "Garden"]])
        let admins = ev(RELAY, 39001, 100, [["d", "garden"], ["p", A, "admin"]])
        let d0 = Derive(events: [meta, admins], me: A)
        let g0 = try XCTUnwrap(d0.group("garden"))
        XCTAssertNil(Actions.setPosts(g0, posts: nil, derive: d0), "anything already")
        let dr = try XCTUnwrap(Actions.setPosts(g0, posts: "thread", derive: d0))
        let c = try XCTUnwrap(JSON.parse(dr.content) as? [String: Any])
        XCTAssertEqual(c["posts"] as? String, "thread")
        XCTAssertEqual(c["on"] as? Bool, false)
        XCTAssertEqual(c["visibility"] as? String, "members")
        // set, with a public page: back to anything keeps the page as it is
        let web = ev(A, 30078, 200, dr.tags, #"{"on":true,"visibility":"public","slug":"garden","periods":[[150,null]],"posts":"event"}"#)
        let d1 = Derive(events: [meta, admins, web], me: A)
        let g1 = try XCTUnwrap(d1.group("garden"))
        XCTAssertEqual(d1.webPage(g1)?.posts, "event")
        XCTAssertNil(Actions.setPosts(g1, posts: "event", derive: d1))
        let back = try XCTUnwrap(JSON.parse(try XCTUnwrap(Actions.setPosts(g1, posts: nil, derive: d1)).content) as? [String: Any])
        XCTAssertNil(back["posts"])
        XCTAssertEqual(back["visibility"] as? String, "public")
        XCTAssertEqual(back["on"] as? Bool, true)
        XCTAssertNotNil(back["periods"])
        XCTAssertNil(Actions.setPosts(g0, posts: "nonsense", derive: d0), "an unknown kind is anything")
    }
}

final class MailForwardTests: XCTestCase {
    /// docs/mail.md "Forwarding": the answer's shape and the row's line.
    func testParseAndLine() {
        XCTAssertNil(MailForward.parse(["forward": NSNull()]))
        XCTAssertEqual(MailForward.line(nil), "Off")
        let pending = MailForward.parse(["forward": ["address": "old@example.org", "state": "pending", "set_by": "x", "since": 1, "same_domain_skipped": false] as [String: Any]])
        XCTAssertEqual(pending?.on, false)
        XCTAssertEqual(MailForward.line(pending), "Waiting for old@example.org to confirm")
        let on = MailForward.parse(["forward": ["address": "old@example.org", "state": "on", "same_domain_skipped": true] as [String: Any]])
        XCTAssertEqual(MailForward.line(on), "old@example.org")
        XCTAssertEqual(on?.sameDomainSkipped, true)
        // never shown as written when it isn't an address
        XCTAssertNil(MailForward.parse(["forward": ["address": "<b>hello</b>", "state": "on"]]))
        XCTAssertNil(MailForward.parse(["forward": ["address": "a b@example.org", "state": "on"]]))
    }
}

/// A guest whose address has an account is signed in by the right code (vectors/guest-signin.json).
final class GuestSignInTests: XCTestCase {
    func testVectors() throws {
        let v = try vector("guest-signin")
        let domain = try XCTUnwrap(v.str("domain"))
        let req = v.dict("request"), typed = req.dict("typed")
        func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }
        XCTAssertTrue(same(GuestSignIn.body(email: typed.str("email") ?? "", code: typed.str("code") ?? "", name: typed.str("name"),
                                            sessionKey: typed.str("session_key") ?? "", client: typed.str("client") ?? ""), req.dict("body")))
        XCTAssertTrue(same(GuestSignIn.body(email: typed.str("email") ?? "", code: typed.str("code") ?? "", name: nil,
                                            sessionKey: typed.str("session_key") ?? ""), req.dict("body_without_name")))
        let answers = v.list("answers")
        XCTAssertEqual(answers.count, 13)
        for a in answers {
            let name = a.str("name") ?? ""
            let body = a["body"] as? [String: Any]
            XCTAssertEqual(GuestSignIn.next(status: a.int("status") ?? 0, body: body, domain: domain).rawValue, a.str("next"), name)
            if a.str("next") == "signed_in" {
                let s = try XCTUnwrap(GuestSignIn.signedIn(body, domain: domain), name)
                XCTAssertEqual(s.address(typed: typed.str("email") ?? ""), a.str("address"), name)
                XCTAssertEqual(s.channel, a.str("open"), name)
                XCTAssertEqual(s.moved, a["moved"] as? Bool, name)
                XCTAssertNotNil(BunkerURL(s.bunkerURL), name)
            } else {
                XCTAssertNil(GuestSignIn.signedIn(body, domain: domain), name)
            }
        }
    }
}

/// "Link your phone": which addresses are login links (vectors/login-links.json).
final class LoginLinkTests: XCTestCase {
    func testVectors() throws {
        let cases = try vector("login-links").list("cases")
        XCTAssertEqual(cases.count, 24)
        for c in cases {
            let url = c.str("url") ?? ""
            XCTAssertEqual(LoginLink.parse(url)?.description, c["valid"] as? Bool == true ? c.str("address") : nil, url)
        }
    }
}

/// The invite sheet's choices (boards inviting/sheet-external, -edit, -guest; canvas v45–v48).
final class InviteChoicesTests: XCTestCase {
    func testRolesTheViewerMayGive() {
        XCTAssertEqual(InviteChoices.roles(steward: true, mayInviteMembers: false, mayAddAgent: true), [.member, .steward, .agent])
        XCTAssertEqual(InviteChoices.roles(steward: true, mayInviteMembers: true, mayAddAgent: false), [.member, .steward])
        XCTAssertEqual(InviteChoices.roles(steward: false, mayInviteMembers: true, mayAddAgent: false), [.member])
        XCTAssertEqual(InviteChoices.roles(steward: false, mayInviteMembers: true, mayAddAgent: true), [.member, .agent])
        // only stewards invite new members here: a guest link, no rows
        XCTAssertEqual(InviteChoices.roles(steward: false, mayInviteMembers: false, mayAddAgent: true), [])
    }

    func testTheLineDescribesTheLink() {
        let m = JoinsAs.member(role: Role.member, membership: "permanent")
        XCTAssertEqual(InviteChoices.line(who: m, people: 1, linkDays: 1, channel: "#Garden"), "This QR code and link work for one person for 24 hours.")
        XCTAssertEqual(InviteChoices.line(who: m, people: 50, linkDays: 7, channel: "#Garden"), "This QR code and link work for up to 50 people for a week.")
        XCTAssertEqual(InviteChoices.line(who: .member(role: Role.member, membership: "year"), people: 1, linkDays: 30, channel: "#Garden"),
                       "This QR code and link work for one person for a month. They stay one year.")
        // a Steward link is always one person
        XCTAssertEqual(InviteChoices.line(who: .member(role: Role.admin, membership: "permanent"), people: 50, linkDays: 1, channel: "#Garden"),
                       "This QR code and link work for one person for 24 hours.")
        XCTAssertEqual(InviteChoices.line(who: .guest(days: 1), people: 1, linkDays: 1, channel: "#Garden"),
                       "This QR code and link let one person join #Garden as a guest for a day.")
        XCTAssertEqual(InviteChoices.line(who: .guest(days: 7), people: 50, linkDays: 30, channel: "#Garden"),
                       "This QR code and link let up to 50 people join #Garden as a guest for a week. The link works for a month.")
    }
}

/// The way in: each endpoint's answers → the screen shown (vectors/way-in.json).
final class WayInTests: XCTestCase {
    func testVectors() throws {
        let v = try vector("way-in")
        let domain = try XCTUnwrap(v.str("domain"))
        let cases = v.list("cases")
        XCTAssertEqual(cases.count, 41)
        // an unknown status is not a "none": the request is asked about again on the next open
        XCTAssertTrue(WayIn.answer(.applyStatus, status: 200, body: ["state": "archived"], domain: "riverside.example").asksAgain)
        XCTAssertFalse(WayIn.answer(.applyStatus, status: 200, body: ["state": "none"], domain: "riverside.example").asksAgain)
        for c in cases {
            let name = (c.str("call") ?? "") + ": " + (c.str("name") ?? "")
            let call = try XCTUnwrap(WayIn.Call(rawValue: c.str("call") ?? ""), name)
            let a = WayIn.answer(call, status: c.int("status") ?? 0, body: c["body"] as? [String: Any], domain: domain)
            XCTAssertEqual(a.screen.rawValue, c.str("screen"), name)
            XCTAssertEqual(a.message, c.str("message"), name)
            XCTAssertEqual(a.clearsCode, c["clears_code"] as? Bool ?? false, name)
            XCTAssertEqual(a.proof, c.str("proof"), name)
            XCTAssertEqual(a.nip05, c.str("nip05"), name)
            XCTAssertEqual(a.suggestions, c.strs("suggestions"), name)
            XCTAssertEqual(a.session != nil, c.str("screen") == "signed_in" && call != .welcome, name)
            if let p = c["pending"] as? [String: Any] {
                XCTAssertEqual(a.pending, WayInAnswer.Pending(name: p["name"] as? String ?? "", username: p["username"] as? String ?? "",
                                                              email: p["email"] as? String ?? "", motivation: p["motivation"] as? String ?? ""), name)
            }
        }
        for c in v.list("username_check") {
            XCTAssertEqual(UsernameCheck.parse(c["body"] as? [String: Any])?.line(domain: domain), c.str("line"), c.str("name") ?? "")
            if c["offers"] != nil { XCTAssertEqual(UsernameCheck.parse(c["body"] as? [String: Any])?.suggestions, c.strs("offers"), c.str("name") ?? "") }
        }
    }

    func testBodies() {
        let b = WayIn.applyBody(email: " Lina@Example.org ", motivation: " Hello ", name: "Lina   Moreau", username: " Lina ", agreed: ["a", "b"], proof: nil)
        XCTAssertEqual(b["email"] as? String, "lina@example.org")
        XCTAssertEqual(b["name"] as? String, "Lina Moreau")
        XCTAssertEqual(b["username"] as? String, "lina")
        XCTAssertEqual(b["motivation"] as? String, "Hello")
        XCTAssertNil(b["proof"])
        XCTAssertEqual(WayIn.applyBody(email: "a@b.c", motivation: "x", name: "L", username: "", agreed: [], proof: "p")["proof"] as? String, "p")
        XCTAssertNil(WayIn.applyBody(email: "a@b.c", motivation: "x", name: "L", username: "", agreed: [], proof: nil)["username"])
        XCTAssertEqual(WayIn.codeBody(email: " A@b.c", code: " 123456 ")["code"] as? String, "123456")
        XCTAssertEqual(UsernameCheck.suggested(["suggested": "lina", "suggestions": ["lina"]]), "lina")
        XCTAssertNil(UsernameCheck.suggested(["suggested": "Lina!"]))
    }

    // A guest's tags come with /whois (canvas v66, n-home-profile-tags): cleaned like a member's.
    func testWhoisTags() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let got = BelfryAPI.whoisTags(["people": [a: "guest"], "tags": [a: ["#Repair", "bikes", "bikes", 7], b: [], "not-a-key": ["x"]]])
        XCTAssertEqual(got, [a: ["repair", "bikes"]])
        XCTAssertEqual(BelfryAPI.whoisTags(["people": [a: "guest"]]), [:])
        XCTAssertEqual(BelfryAPI.whoisTags(["tags": "nope"]), [:])
        XCTAssertEqual(BelfryAPI.whoisTags(nil), [:])
    }
}

/// One rule for every list of events (SPEC 19.62): past = now ≥ end, with a fixed clock.
final class EventsOverTests: XCTestCase {
    func testPastIsNowAtOrAfterTheEnd() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Brussels"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Int {
            Int(cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!.timeIntervalSince1970)
        }
        let now = at(20, 15)
        func timed(_ d: String, _ start: Int, _ end: Int?) -> NostrEvent {
            ev(A, 31923, 1, [["d", d], ["title", d], ["start", String(start)]] + (end.map { [["end", String($0)]] } ?? []))
        }
        func days(_ d: String, _ start: String, _ end: String? = nil, tz: String? = nil) -> NostrEvent {
            ev(A, 31922, 1, [["d", d], ["title", d], ["start", start]] + (end.map { [["end", $0]] } ?? []) + (tz.map { [["start_tzid", $0]] } ?? []))
        }
        let evs = [
            timed("morning", at(20, 9), at(20, 10)),          // ended earlier today: past (not until midnight)
            timed("noend-old", at(20, 13, 30), nil),          // no end: over an hour after its start
            timed("noend-now", at(20, 14, 30), nil),          // no end, started 30 min ago: still on
            timed("ongoing", at(20, 14), at(20, 16)),         // going on now: upcoming
            timed("ends-now", at(20, 13), now),               // now ≥ end: past
            timed("later", at(20, 18), at(20, 19)),
            days("day-today", "2026-11-20"),                  // all day today: until midnight
            days("day-range", "2026-11-18", "2026-11-20"),    // the end date is its last day
            days("day-yesterday", "2026-11-19"),
            days("day-auckland", "2026-11-20", tz: "Pacific/Auckland"), // its day ended at 12:00 in Brussels
        ]
        func world() -> Derive { Derive(events: evs, context: WorldContext(me: A, timeZone: zone)) }
        let d = world()
        XCTAssertEqual(Set(d.eventsIn(.upcoming, now: now).map(\.d)), ["noend-now", "ongoing", "later", "day-today", "day-range"])
        XCTAssertEqual(Set(d.eventsIn(.past, now: now).map(\.d)), ["morning", "noend-old", "ends-now", "day-yesterday", "day-auckland"])
        XCTAssertEqual(Set(d.eventsIn(.hosting, now: now).map(\.d)), Set(d.eventsIn(.upcoming, now: now).map(\.d)))
        XCTAssertEqual(Set(d.upcoming(now: now).map(\.d)), Set(d.eventsIn(.upcoming, now: now).map(\.d)))
        func e(_ id: String) throws -> CalEvent { try XCTUnwrap(d.calendar.first { $0.d == id }) }
        XCTAssertEqual(d.endsAt(try e("noend-now")), at(20, 15, 30))
        XCTAssertEqual(d.endsAt(try e("day-today")), at(21, 0))
        XCTAssertEqual(d.endsAt(try e("day-range")), at(21, 0))
        XCTAssertEqual(d.endsAt(try e("day-auckland")), at(20, 12))
        // answering closes by the same rule
        XCTAssertTrue(d.isOpen(try e("ongoing"), now: now))
        XCTAssertTrue(d.isOpen(try e("noend-now"), now: now))
        XCTAssertFalse(d.isOpen(try e("morning"), now: now))
        XCTAssertFalse(d.isOpen(try e("noend-old"), now: now))
        // the edges: the second before the end it is on, at the end it is over
        XCTAssertFalse(d.isPast(try e("ongoing"), now: at(20, 16) - 1))
        XCTAssertTrue(d.isPast(try e("ongoing"), now: at(20, 16)))
        XCTAssertFalse(d.isPast(try e("day-range"), now: at(21, 0) - 1))
        XCTAssertTrue(d.isPast(try e("day-range"), now: at(21, 0)))
        // the next one in time order among those not over
        XCTAssertEqual(d.eventsIn(.upcoming, now: now).first { !$0.allDay }?.d, "ongoing")
    }
}
