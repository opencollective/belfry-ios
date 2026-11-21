import Foundation
import XCTest
@testable import BelfryCore

// Round 5 (2026-11-17): buttons on messages (SPEC 19.36, vectors/message-actions.json), links in
// text, the channel settings queue (SPEC 19.37), #website keeps its own name.

private func label(_ id: String, _ pk: String, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
    NostrEvent(id: id, pubkey: pk, createdAt: at, kind: 1985, tags: tags, content: content)
}

final class ButtonsTests: XCTestCase {
    func testParseVectors() throws {
        let v = try vector("message-actions")
        for c in v.list("buttons") {
            let got = Buttons.parse(tags(c["tags"]))
            let want = c.list("buttons").map {
                MessageButton(id: $0.str("id")!, label: $0.str("label")!, style: MessageButton.Style(rawValue: $0.str("style") ?? "")!, action: $0.str("action") ?? "")
            }
            XCTAssertEqual(got, want, c.str("name") ?? "")
        }
    }

    func testPressVector() throws {
        let v = try vector("message-actions").dict("press")
        let m = v.dict("message")
        let d = Buttons.press(messageId: m.str("id")!, author: m.str("pubkey")!, group: m.str("group")!, button: v.str("button")!)
        let e = v.dict("event")
        XCTAssertEqual(d.kind, e.int("kind"))
        XCTAssertEqual(d.content, e.str("content"))
        XCTAssertEqual(d.tags, tags(e["tags"]))
        XCTAssertEqual(d.target, .groups)
    }

    func testStateVectors() throws {
        let v = try vector("message-actions")
        for c in v.list("state") {
            let name = c.str("name") ?? ""
            let m = c.dict("message")
            let mid = m.str("id")!
            let author = m.str("pubkey")!
            let buttons = m.list("buttons").map { MessageButton(id: $0.str("id")!, label: $0.str("id")!, action: $0.str("action") ?? "") }
            var evs = [NostrEvent]()
            if let p = c["press"] as? [String: Any] {
                evs.append(label(p.str("id")!, p.str("pubkey")!, p.int("created_at")!,
                                 Buttons.press(messageId: mid, author: author, group: "g", button: p.str("button")!).tags))
            }
            for (i, a) in c.list("answers").enumerated() {
                var t: [Tag] = [["L", Buttons.resultNS], ["l", a.str("l")!, Buttons.resultNS], ["e", mid], ["press", a.str("press")!], ["p", "P"], ["h", "g"]]
                if let code = a.str("code") { t.append(["code", code]) }
                if a["closed"] as? Bool == true { t.append(["closed", "1"]) }
                evs.append(label("answer-\(i)", a.str("pubkey")!, a.int("created_at")!, t, a.str("content") ?? ""))
            }
            let st = Buttons.state(messageId: mid, author: author, buttons: buttons, me: c.str("me")!, events: evs, belfryKeys: ["B", "G"])
            let want = c.dict("expect")
            XCTAssertEqual(st.closed, want["closed"] as? Bool, name)
            if let ct = want.str("closed_text") { XCTAssertEqual(st.closedText, ct, name) }
            if let mine = want["mine"] as? [String: Any] {
                XCTAssertEqual(st.mine?.status.rawValue, mine.str("status"), name)
                XCTAssertEqual(st.mine?.text, mine.str("text"), name)
                if let code = mine.str("code") { XCTAssertEqual(st.mine?.code, code, name) }
            } else {
                XCTAssertNil(st.mine, name)
            }
        }
    }

    func testFixedText() throws {
        let f = try vector("message-actions").dict("fixed_text")
        for (k, v) in f {
            switch k {
            case "timeout": XCTAssertEqual(Buttons.timeoutText, v as? String)
            case "unknown_belfry_action": XCTAssertEqual(Buttons.unknownActionText, v as? String)
            case let c where c.hasPrefix("confirm:"):
                let action = String(c.dropFirst("confirm:".count))
                // an action this app does not know yet (its button is disabled, "Update the app
                // to use this.") has no question here
                guard Buttons.knownActions.contains(action) else { XCTAssertNil(Buttons.confirmText(action, domain: "<domain>")); continue }
                XCTAssertEqual(Buttons.confirmText(action, domain: "<domain>"), v as? String)
            default: XCTAssertEqual(Buttons.fixed[k], v as? String, k)
            }
        }
        XCTAssertEqual(Buttons.errorText(code: "not_allowed", content: ""), "You're not allowed to do this.")
        XCTAssertEqual(Buttons.errorText(code: "weird", content: " "), "That didn't work.")
    }

    func testWaitingLocksForTwentySeconds() {
        let st = Buttons.state(messageId: "m", author: "A", buttons: [MessageButton(id: "go", label: "Go")], me: "P",
                               events: [label("p1", "P", 100, Buttons.press(messageId: "m", author: "A", group: "g", button: "go").tags)], belfryKeys: [])
        XCTAssertEqual(st.mine?.status, .waiting)
        XCTAssertTrue(st.locked(now: 110))
        XCTAssertFalse(st.timedOut(now: 110))
        XCTAssertFalse(st.locked(now: 120))
        XCTAssertTrue(st.timedOut(now: 120))
    }

    func testUnknownBelfryActionAndDerive() {
        XCTAssertFalse(MessageButton(id: "x", label: "X", action: "belfry:launch-rockets").known)
        XCTAssertTrue(MessageButton(id: "x", label: "X", action: Buttons.websitePublish).known)
        // Close on a request card: known, asked with the app's own two lines, "Closing" while locked
        XCTAssertTrue(MessageButton(id: "close", label: "Close", action: "belfry:request-close").known)
        let q = Buttons.confirmParts(Buttons.confirmText(Buttons.requestClose, domain: "x.org") ?? "")
        XCTAssertEqual(q.title, "Close this request?")
        XCTAssertEqual(q.detail, "It stays readable, and people can still comment.")
        XCTAssertEqual(Buttons.confirmVerb(Buttons.requestClose), "Close")
        XCTAssertEqual(Buttons.busyLabel(Buttons.requestClose), "Closing")
        XCTAssertNil(Buttons.busyLabel(Buttons.websitePublish))
        // an offer's answer: known, its own question, "Answer"
        XCTAssertTrue(MessageButton(id: "offer-75", label: "75% off", action: "belfry:offer-decide").known)
        let o = Buttons.confirmParts(Buttons.confirmText(Buttons.offerDecide, domain: "x.org") ?? "")
        XCTAssertEqual(o.title, "Answer this offer?")
        XCTAssertEqual(o.detail, "The answer is public in the thread; the code goes privately to them.")
        XCTAssertEqual(Buttons.confirmVerb(Buttons.offerDecide), "Answer")
        let one = Buttons.confirmParts(Buttons.confirmText(Buttons.websitePublish, domain: "x.org", paths: ["/a/"]) ?? "")
        XCTAssertEqual(one.title, "Publish this version of /a/ on https://x.org?")
        XCTAssertEqual(one.detail, "Only that part of the website changes.")
        XCTAssertTrue(MessageButton(id: "x", label: "X").known)
        // through Derive: the groups key's closing answer shows for everyone, after a restart too
        let me = String(repeating: "a", count: 64), agent = String(repeating: "c", count: 64), gk = String(repeating: "e", count: 64)
        let msg = NostrEvent(id: String(repeating: "1", count: 64), pubkey: agent, createdAt: 50, kind: 9,
                             tags: [["h", "website"], ["button", "publish", "Approve and publish", "primary", Buttons.websitePublish]], content: "v2")
        let ans = label(String(repeating: "2", count: 64), gk, 60, [["L", Buttons.resultNS], ["l", "ok", Buttons.resultNS], ["e", msg.id], ["press", "x"], ["p", "z"], ["h", "website"], ["closed", "1"]], "Published by Ana.")
        let forged = label(String(repeating: "3", count: 64), agent, 70, [["L", Buttons.resultNS], ["l", "ok", Buttons.resultNS], ["e", msg.id], ["press", "x"], ["closed", "1"]], "Forged")
        var ctx = WorldContext(me: me, groupsKey: gk)
        ctx.belfryKey = String(repeating: "f", count: 64)
        let d = Derive(events: [msg, ans, forged], context: ctx)
        let m = try! XCTUnwrap(d.messages("website").first)
        XCTAssertEqual(d.buttons(m).map(\.id), ["publish"])
        let st = d.buttonState(m)
        XCTAssertTrue(st.closed)
        XCTAssertEqual(st.closedText, "Published by Ana.")
    }

    func testBelfryJsonKeys() {
        let c = BelfryConfig.from(domain: "example.org", document: [
            "nostr": ["pubkey": String(repeating: "f", count: 64), "npub": "npub1…"],
            "groups_key": ["pubkey": String(repeating: "e", count: 64)],
        ])
        XCTAssertEqual(c.belfryKey, String(repeating: "f", count: 64))
        XCTAssertEqual(c.groupsKeyHex, String(repeating: "e", count: 64))
        XCTAssertNil(BelfryConfig.from(domain: "example.org", document: [:]).groupsKeyHex)
    }
}

final class LinksTests: XCTestCase {
    func testXaviersThreeLinks() {
        let npub = "npub10j0emvtx36vh5h0dmd2e2zau7uh7vssx9mqnk2mn68agvknvecsqraxdux"
        let text = "**Website updated**: a new version. Preview: https://preview.opensourcevillage.org/p/\(npub)@website\n" +
            "An admin can approve it at https://belfry.opensourcevillage.org/website. Live at https://opensourcevillage.org"
        XCTAssertEqual(Links.inMarkdown(text), [
            "https://preview.opensourcevillage.org/p/\(npub)@website",
            "https://belfry.opensourcevillage.org/website",
            "https://opensourcevillage.org",
        ])
        XCTAssertNotNil(URL(string: "https://preview.opensourcevillage.org/p/\(npub)@website")?.host)
    }

    func testEdges() {
        XCTAssertEqual(Links.find("(see https://a.example/x)"), ["https://a.example/x"])
        for p in [",", "!", "?", ")", ".", ";", ":", "'", "\""] {
            XCTAssertEqual(Links.find("go to https://a.example/x\(p) now"), ["https://a.example/x"], p)
        }
        XCTAssertEqual(Links.find("https://a.example/page#part-2"), ["https://a.example/page#part-2"])
        XCTAssertEqual(Links.find("https://a.example/s?q=bells&lang=en"), ["https://a.example/s?q=bells&lang=en"])
        XCTAssertEqual(Links.find("mail me at https://a.example/u/ana@a.example"), ["https://a.example/u/ana@a.example"])
        XCTAssertEqual(Links.find("just opensourcevillage.org or www.example.org"), [])
        XCTAssertEqual(Links.inMarkdown("[the site](https://a.example/) and `https://b.example/`"), ["https://a.example/"])
    }

    func testTargets() {
        func t(_ s: String) -> Links.Target { Links.target(URL(string: s)!, domain: "opensourcevillage.org") }
        XCTAssertEqual(t("https://chat.opensourcevillage.org/join/abc123"), .app)
        XCTAssertEqual(t("https://chat.opensourcevillage.org/events/repair-cafe"), .app)
        XCTAssertEqual(t("https://chat.opensourcevillage.org/#/c/website"), .channel("website"))
        XCTAssertEqual(t("https://opensourcevillage.org/chat/#/c/garden-3f2a/m/x"), .channel("garden-3f2a"))
        // board channels/message-link: a link to one message
        let mid = String(repeating: "ab", count: 32)
        XCTAssertEqual(t("https://chat.opensourcevillage.org/#/c/garden-3f2a/m/\(mid)"), .message("garden-3f2a", mid))
        XCTAssertEqual(t("https://opensourcevillage.org"), .browser)
        XCTAssertEqual(t("https://belfry.opensourcevillage.org/website"), .browser)
        XCTAssertEqual(t("https://chat.belfry.sh/join/abc"), .browser) // another belfry: the browser (and its universal link)
    }
}

final class SettingsQueueTests: XCTestCase {
    let relay = String(repeating: "d", count: 64)

    func engine(_ path: String, _ me: LocalSigner, transport: ((URLRequest) async throws -> (Data, Int))?) throws -> SyncEngine {
        let e = SyncEngine(config: .defaults(domain: "example.org"), db: try Database(path: path), signer: me, localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        e.transport = transport
        return e
    }

    func meta(_ name: String) -> NostrEvent {
        NostrEvent(id: String(repeating: "9", count: 64), pubkey: relay, createdAt: 100, kind: 39000,
                   tags: [["d", "website"], ["name", name], ["about", "Old"], ["private"]], content: "")
    }

    func name(_ e: SyncEngine) -> String? { Derive(events: e.snapshot(), me: e.me).group("website")?.name }

    /// Flushes until UNTIL holds (enqueue's own flushSoon may be running: a flush then returns at once).
    func settle(_ e: SyncEngine, until: () -> Bool) async {
        for _ in 0..<100 {
            await e.flush()
            if until() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testRefusedCallShowsThenDiscardRestores() async throws {
        let path = NSTemporaryDirectory() + "belfry-test-\(UUID().uuidString).sqlite"
        let me = try LocalSigner(secret: Keys.generateSecret())
        var seen = [URLRequest]()
        let e = try engine(path, me) { req in
            seen.append(req)
            return (Data("{\"error\":\"not_allowed\"}".utf8), 403)
        }
        e.add([meta("website")], verify: false)
        let g = try XCTUnwrap(Derive(events: e.snapshot(), me: me.pubkey).group("website"))
        // the relay's copy has a tag the app doesn't model: every 9002 keeps it
        XCTAssertEqual(g.metaExtra, [["private"]])
        let display = Actions.groupMeta(g, name: "Our website", about: "New")
        XCTAssertTrue(display.tags.contains(["private"]))
        e.enqueueCall(HttpCall(url: "https://belfry.example.org/api/v1/group-meta", json: ["channel": "website", "name": "Our website"]), display: display)
        // shown at once, before anything is sent
        XCTAssertEqual(name(e), "Our website")
        await settle(e) { e.outboxItems().first?.status == .failed }
        // NIP-98 signed when sent
        XCTAssertEqual(seen.count, 1)
        guard let first = seen.first else { return XCTFail("no request") }
        XCTAssertTrue(first.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true)
        let failed = SettingsQueue.failed(e.outboxItems(), channel: "website")
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(SettingsQueue.message(failed[0]), "The new name and description weren't saved: you're not allowed to change this channel.")
        // survives a restart, still shown
        let again = try engine(path, me, transport: nil)
        XCTAssertEqual(SettingsQueue.failed(again.outboxItems(), channel: "website").count, 1)
        XCTAssertEqual(name(again), "Our website")
        // discard: what the relay has
        again.cancel(failed[0].localId)
        XCTAssertEqual(name(again), "website")
    }

    func testRetryableCallStaysQueuedThenGoes() async throws {
        let path = NSTemporaryDirectory() + "belfry-test-\(UUID().uuidString).sqlite"
        let me = try LocalSigner(secret: Keys.generateSecret())
        var status = 503
        let e = try engine(path, me) { _ in (Data("{}".utf8), status) }
        e.add([meta("website")], verify: false)
        let g = try XCTUnwrap(Derive(events: e.snapshot(), me: me.pubkey).group("website"))
        e.enqueueCall(HttpCall(url: "https://belfry.example.org/api/v1/group-meta", json: ["channel": "website"]), display: Actions.groupMeta(g, name: "Site"))
        await settle(e) { (e.outboxItems().first?.tries ?? 0) > 0 }
        XCTAssertEqual(e.outboxItems().count, 1)
        XCTAssertEqual(e.outboxItems()[0].status, .queued)
        XCTAssertEqual(e.outboxItems()[0].tries, 1)
        status = 200
        await settle(e) { e.outboxItems().isEmpty }
        XCTAssertTrue(e.outboxItems().isEmpty)
        // still shown until the relay's copy arrives
        XCTAssertEqual(name(e), "Site")
    }

    func testOutcomes() {
        XCTAssertNil(HttpCall.outcome(status: 200, body: Data()))
        for s in [0, 401, 408, 429, 500, 503] { XCTAssertEqual(Outbox.classify(HttpCall.outcome(status: s, body: Data())!), .retry, "\(s)") }
        let refused = HttpCall.outcome(status: 409, body: Data("{\"error\":\"archived\"}".utf8))!
        XCTAssertEqual(Outbox.classify(refused), .failed)
        XCTAssertEqual(HttpCall.code(of: refused), "archived")
        XCTAssertEqual(Outbox.classify(HttpCall.outcome(status: 404, body: Data())!), .failed)
    }

    func testRelayRefusalOfOwnEdit() {
        // a refused 9002 (my own edit on the relay) and a refused e-mail switch: both marked
        var meta = OutboxItem(target: .groups, kind: 9002, content: "", tags: [["h", "website"], ["name", "X"]], createdAt: 10, status: .failed, error: "restricted: not an admin")
        let inbox = OutboxItem(target: .groups, kind: 30078, content: "{\"on\":true}", tags: [["d", Derive.inboxD], ["h", "website"]], createdAt: 11, status: .failed, error: "invalid: bad")
        let other = OutboxItem(target: .groups, kind: 9, content: "hi", tags: [["h", "website"]], createdAt: 12, status: .failed, error: "blocked: x")
        let queued = OutboxItem(target: .groups, kind: 9002, content: "", tags: [["h", "website"]], createdAt: 13)
        XCTAssertEqual(SettingsQueue.failed([other, inbox, meta, queued], channel: "website").map(\.kind), [9002, 30078])
        XCTAssertTrue(SettingsQueue.failed([meta], channel: "general").isEmpty)
        XCTAssertEqual(SettingsQueue.message(inbox), "The e-mail setting wasn't saved: the belfry didn't accept them.")
        meta.error = "error: something"
        XCTAssertEqual(SettingsQueue.message(meta), "The new name and description weren't saved: the belfry refused the change.")
    }
}

final class WebsiteNameTests: XCTestCase {
    func testWebsiteKeepsItsName() {
        let relay = String(repeating: "d", count: 64)
        var ctx = WorldContext(me: String(repeating: "a", count: 64))
        ctx.placeNames = true
        let evs = ["general", "website", "events", "proposals"].enumerated().map { i, id in
            NostrEvent(id: String(format: "%064x", 900 + i), pubkey: relay, createdAt: 100, kind: 39000, tags: [["d", id], ["name", id]], content: "")
        }
        let d = Derive(events: evs, context: ctx)
        XCTAssertEqual(d.group("general")?.name, "Townsquare")
        XCTAssertEqual(d.group("website")?.name, "website")
        XCTAssertEqual(d.group("events")?.name, "events")
        XCTAssertEqual(d.group("proposals")?.name, "proposals")
        XCTAssertNil(PlaceNames.display(id: "website", name: "website"))
        XCTAssertEqual(PlaceNames.wire(id: "website", name: "Scriptorium"), "Scriptorium")
    }
}
