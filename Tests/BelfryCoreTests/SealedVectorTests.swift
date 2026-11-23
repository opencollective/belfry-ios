import Foundation
import XCTest
@testable import BelfryCore

// vectors/sealed.json = belfry-android main 41f34a8 (sha256 c4492f3f…42c7), byte for byte: the
// lead's docs/sealed-vectors.json (32f97764…b09a) plus the sections `confirm` (kind 8563),
// `notes` (Notes to myself) and `silent` (silent wraps): the roster chain, opening and acceptance, the ceiling and the packing of a shared
// history, the key hand-over, the link proof, shared history, `ready`. Not reproduced here:
// making the same wrap byte for byte (it needs fixed one-time keys, nonces and Schnorr auxiliary).

private func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
private func list(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }

final class SealedVectorTests: XCTestCase {
    private func key(_ v: [String: Any], _ name: String) -> (secret: String, pub: String) {
        let k = dict(dict(v["keys"])[name])
        return (k["secret"] as? String ?? "", k["pubkey"] as? String ?? "")
    }

    /// The chain of the case NAME, as an opener would resolve it.
    private func chain(_ v: [String: Any], named name: String?, account: String) throws -> RosterChain? {
        guard let name, let c = list(v["chains"]).first(where: { $0["name"] as? String == name }) else { return nil }
        return RosterChain.resolve(account: account, anchor: try? event(c["anchor"]), rosters: try events(c["rosters"]))
    }

    private func chain(events e: [String: Any], account: String) throws -> RosterChain? {
        RosterChain.resolve(account: account, anchor: try? event(e["anchor"]), rosters: try events(e["rosters"]))
    }

    func testChains() throws {
        let v = try vector("sealed")
        let alice = key(v, "alice").pub
        let cases = list(v["chains"])
        XCTAssertEqual(cases.count, 39)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let got = RosterChain.resolve(account: alice, anchor: try? event(c["anchor"]), rosters: try events(c["rosters"]),
                                          pinnedHead: c["pinned_head"] as? String)
            XCTAssertEqual(got?.rosters.map(\.id) ?? [], exp["valid_ids"] as? [String] ?? [], name)
            XCTAssertEqual(got?.head.id, exp["head"] as? String, name)
            XCTAssertEqual(got?.devices ?? [], exp["devices"] as? [String] ?? [], name)
            XCTAssertEqual(got?.lb, exp["lb"] as? String, name)
            XCTAssertEqual(got?.ready ?? false, exp["ready"] as? Bool ?? false, name)
        }
    }

    /// "It was me" once for every device (sealed.md 5.2 step 2b, kind 8563): belfry-android's
    /// `confirm` section (main 921a6c1): 1 accepted, 9 refused by the rule, 5 on the shape.
    func testConfirm() throws {
        let v = try vector("sealed")
        let c = dict(v["confirm"])
        let account = try XCTUnwrap(c["account"] as? String)
        let ch = try XCTUnwrap(try chain(events: dict(c["chain"]), account: account))
        XCTAssertEqual(ch.rosters.count, 4)
        let cases = list(c["cases"])
        XCTAssertEqual(cases.count, 15)
        var accepted = 0
        for k in cases {
            let name = k["name"] as? String ?? ""
            let r = dict(k["rumor"])
            let rumor = NostrEvent(id: r["id"] as? String ?? "", pubkey: r["pubkey"] as? String ?? "", createdAt: r["created_at"] as? Int ?? 0,
                                   kind: r["kind"] as? Int ?? 0, tags: r["tags"] as? [[String]] ?? [], content: r["content"] as? String ?? "")
            let exp = dict(k["expected"])
            let got = AddedConfirm.verdict(rumor, sealPubkey: k["seal_pubkey"] as? String ?? "", chain: ch, account: account)
            if exp["accepted"] as? Bool == true {
                accepted += 1
                XCTAssertEqual(got, .clears(exp["device"] as? String ?? ""), name)
                XCTAssertEqual(AddedConfirm.addedBy(ch, exp["device"] as? String ?? "")?.id, exp["roster"] as? String, name)
            } else {
                XCTAssertEqual(exp["accepted"] as? Bool, false, name)
                if case .clears = got { XCTFail("cleared: " + name) }
            }
        }
        XCTAssertEqual(accepted, 1)
        // the one real wrap opens to the first case's rumor, sealed by the phone
        let w = dict(c["wrap"])
        let secret = try XCTUnwrap(Data(hex: w["letterbox_secret"] as? String ?? ""))
        guard case .opened(let rumor, let seal) = Sealed.open(try event(w["wrap"]), secret: secret) else { return XCTFail("the confirm wrap does not open") }
        let exp = dict(w["expected"])
        XCTAssertEqual(seal, exp["seal_pubkey"] as? String)
        XCTAssertEqual(rumor.id, dict(exp["rumor"])["id"] as? String)
        XCTAssertEqual(AddedConfirm.verdict(rumor, sealPubkey: seal, chain: ch, account: account), .clears(rumor.tag("device") ?? ""))
        // an 8563 is never taken from a shared history
        XCTAssertFalse([14, 7, 5].contains(AddedConfirm.kind))
    }

    /// Notes to myself (belfry-android's `notes` section): what is a note, the one wrap on a
    /// chain that is not ready, and what happens to a note written now.
    func testNotes() throws {
        let v = try vector("sealed")
        let n = dict(v["notes"])
        let me = try XCTUnwrap(n["account"] as? String)
        XCTAssertEqual(dict(n["conversation"])["participants"] as? [String], [me])
        XCTAssertEqual(Notes.conv(me), "n:" + me)
        let rumors = list(n["rumors"])
        XCTAssertEqual(rumors.count, 9)
        for c in rumors {
            let name = c["name"] as? String ?? ""
            let r = dict(c["rumor"])
            let conv = MailThreads.nostrConv(author: r["pubkey"] as? String ?? "", pTags: (r["tags"] as? [[String]] ?? []).filter { $0.first == "p" && $0.count > 1 }.map { $0[1] }, me: me)
            let exp = dict(c["expected"])
            // the file lists every participant, me included; the iPhone's id names the others
            // (and me alone for Notes)
            let others = (exp["participants"] as? [String] ?? []).filter { $0 != me }.sorted()
            XCTAssertEqual(conv, "n:" + (others.isEmpty ? me : others.joined(separator: ",")), name)
            XCTAssertEqual(Notes.isNotes(conv, me: me), exp["notes"] as? Bool ?? false, name)
        }
        // the single wrap: p = me, my head letterbox; accepted on a chain without `ready`. (This
        // case was generated before silent wraps: it carries no tag. That a note written today
        // does is in `silent.carries` and in SealedEngineTests.testNotesToMyself.)
        let w = dict(n["wrap"])
        let wrap = try event(w["wrap"])
        XCTAssertEqual(wrap.tagValues("p"), [me])
        let secret = try XCTUnwrap(Data(hex: w["letterbox_secret"] as? String ?? ""))
        guard case .opened(let rumor, let seal) = Sealed.open(wrap, secret: secret) else { return XCTFail("the note's wrap does not open") }
        let exp = dict(w["expected"])
        XCTAssertEqual(seal, exp["seal_pubkey"] as? String)
        XCTAssertEqual(rumor.id, dict(exp["rumor"])["id"] as? String)
        let ch = try XCTUnwrap(try chain(events: dict(w["chain"]), account: me))
        XCTAssertFalse(ch.ready)
        XCTAssertTrue(Sealed.accepted(rumor, sealPubkey: seal, chain: ch, belfry: nil))
        let plans = list(n["plans"])
        XCTAssertEqual(plans.count, 6)
        for p in plans {
            let name = p["name"] as? String ?? ""
            let c = (p["chain"] as? [String: Any]).flatMap { try? chain(events: $0, account: me) }
            let device = p["device"] as? String ?? ""
            let got = Notes.plan(canSeal: p["can_seal"] as? Bool ?? false, hasChain: c != nil, inHead: c?.devices.contains(device) ?? false,
                                 answered: p["answer"] as? String == "complete")
            XCTAssertEqual(got.rawValue, dict(p["expected"])["decision"] as? String, name)
        }
    }

    /// Silent wraps (sealed.md 4; belfry-android's `silent` section): only the exact tag counts,
    /// and a wrap with it, or with tags this reader does not know, opens exactly as before.
    func testSilent() async throws {
        let v = try vector("sealed")
        let s = dict(v["silent"])
        XCTAssertEqual(s["tag"] as? [String], Sealed.silentTag)
        let tags = list(s["tags"])
        XCTAssertEqual(tags.count, 12)
        for c in tags {
            let name = c["name"] as? String ?? ""
            let t = c["tags"] as? [[String]] ?? []
            XCTAssertEqual(Sealed.isSilent(t), dict(c["expected"])["silent"] as? Bool, name)
            // a sealed wrap stays a sealed wrap whatever else it carries
            if t.contains(where: { $0.first == "lb" }) {
                XCTAssertNotNil(Sealed.lb(of: NostrEvent(pubkey: "", createdAt: 0, kind: 1059, tags: t, content: "")), name)
            }
        }
        let secret = try XCTUnwrap(Data(hex: s["letterbox_secret"] as? String ?? ""))
        let alice = try LocalSigner(secret: try XCTUnwrap(Data(hex: key(v, "alice").secret)))
        let wraps = list(s["wraps"])
        XCTAssertEqual(wraps.count, 4)
        for c in wraps {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let wrap = try event(c["wrap"])
            XCTAssertEqual(Sealed.isSilent(wrap.tags), exp["silent"] as? Bool, name)
            let want = dict(exp["rumor"])["id"] as? String
            if c["sealed"] as? Bool == true {
                guard case .opened(let rumor, let seal) = Sealed.open(wrap, secret: secret) else { XCTFail("does not open: " + name); continue }
                XCTAssertEqual(rumor.id, want, name)
                XCTAssertEqual(seal, exp["seal_pubkey"] as? String, name)
            } else {
                let o = try await GiftWrap.unwrap(wrap, signer: alice)
                XCTAssertEqual(o?.rumor.id, want, name)
            }
        }
        XCTAssertEqual(list(s["carries"]).count, 10)
    }

    /// A device that signed in adds itself (sealed.md 5.7 as tightened, belfry-sh 88a27b9):
    /// belfry-android's `join.chains` (branch self-join 2d69652), 42 cases.
    func testJoinChains() throws {
        let v = try vector("sealed")
        let j = dict(v["join"])
        let alice = key(v, "alice").pub
        let cases = list(j["chains"])
        XCTAssertEqual(cases.count, 42)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let got = RosterChain.resolve(account: alice, anchor: try? event(c["anchor"]), rosters: try events(c["rosters"]),
                                          pinnedHead: c["pinned_head"] as? String)
            XCTAssertEqual(got?.rosters.map(\.id) ?? [], exp["valid_ids"] as? [String] ?? [], name)
            XCTAssertEqual(got?.head.id, exp["head"] as? String, name)
            XCTAssertEqual(got?.devices ?? [], exp["devices"] as? [String] ?? [], name)
            XCTAssertEqual(got?.lb, exp["lb"] as? String, name)
            XCTAssertEqual(got?.unendorsed ?? [], exp["unendorsed"] as? [String] ?? [], name)
        }
    }

    func testWraps() throws {
        let v = try vector("sealed")
        let cases = list(v["wraps"])
        XCTAssertEqual(cases.count, 12)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let secret = try XCTUnwrap(Data(hex: c["letterbox_secret"] as? String ?? ""))
            let wrap = try event(c["wrap"])
            guard case .opened(let rumor, let seal) = Sealed.open(wrap, secret: secret) else {
                XCTAssertEqual(exp["opens"] as? Bool, false, name)
                continue
            }
            XCTAssertEqual(exp["opens"] as? Bool, true, name)
            XCTAssertEqual(seal, exp["seal_pubkey"] as? String, name)
            let r = dict(exp["rumor"])
            XCTAssertEqual(rumor.id, r["id"] as? String, name)
            XCTAssertEqual(rumor.pubkey, r["pubkey"] as? String, name)
            XCTAssertEqual(rumor.createdAt, r["created_at"] as? Int, name)
            XCTAssertEqual(rumor.kind, r["kind"] as? Int, name)
            XCTAssertEqual(rumor.content, r["content"] as? String, name)
            XCTAssertEqual(rumor.tags, r["tags"] as? [[String]], name)
            var ch = try chain(v, named: c["author_chain"] as? String, account: rumor.pubkey)
            if let e = c["author_chain_events"] as? [String: Any] { ch = try chain(events: e, account: rumor.pubkey) }
            XCTAssertEqual(Sealed.accepted(rumor, sealPubkey: seal, chain: ch, belfry: c["belfry"] as? String), exp["accepted"] as? Bool, name)
        }
    }

    func testCeiling() throws {
        let v = try vector("sealed")
        let ceiling = dict(v["ceiling"])
        XCTAssertEqual(ceiling["max_rumor_json_bytes"] as? Int, Sealed.maxRumorBytes)
        let device = try XCTUnwrap(Data(hex: key(v, "alice_phone").secret))
        for c in list(ceiling["cases"]) {
            let name = c["name"] as? String ?? ""
            let r = dict(c["rumor"])
            let rep = dict(r["content"])
            let content = String(repeating: rep["repeat"] as? String ?? "", count: rep["times"] as? Int ?? 0)
            let rumor = GiftWrap.rumor(kind: r["kind"] as? Int ?? 0, pubkey: r["pubkey"] as? String ?? "", tags: r["tags"] as? [[String]] ?? [],
                                       content: content, createdAt: r["created_at"] as? Int ?? 0)
            XCTAssertEqual(rumor.id, c["rumor_id"] as? String, name)
            XCTAssertEqual(Sealed.json(rumor).utf8.count, c["rumor_json_bytes"] as? Int, name)
            let w = try? Sealed.wrap(rumor, device: device, to: key(v, "bob").pub, lb: key(v, "bob_lb1").pub)
            XCTAssertEqual(w != nil, c["may_seal"] as? Bool, name)
            if let w, let chars = c["wrap_content_chars"] as? Int { XCTAssertEqual(w.content.count, chars, name) }
        }
    }

    func testHistoryPacking() throws {
        let v = try vector("sealed")
        let exp = dict(dict(dict(v["ceiling"])["history_packing"])["expected"])
        let t0 = try XCTUnwrap(dict(v["fixed"])["T0"] as? Int)
        let alice = key(v, "alice").pub, bob = key(v, "bob").pub
        var rumors = [NostrEvent]()
        for i in 0..<300 {
            let from = i % 2 == 1 ? alice : bob
            rumors.append(GiftWrap.rumor(kind: 14, pubkey: from, tags: [["p", from == alice ? bob : alice]],
                                         content: "Message \(i): \"quoted\" \\ and é", createdAt: t0 + i))
            if i == 149 {
                // fits a sealed rumor of its own, but no 8564: left out
                rumors.append(GiftWrap.rumor(kind: 14, pubkey: bob, tags: [["p", alice]], content: String(repeating: "x", count: 39_700), createdAt: t0 + i))
            }
        }
        let parts = Sealed.history(rumors, sharer: bob, person: alice, now: t0 + 800)
        XCTAssertEqual(parts.map { Sealed.sharedRumors($0).count }, exp["rumors_per_8564"] as? [Int])
        XCTAssertEqual(parts.map { Sealed.json($0).utf8.count }, exp["json_bytes_per_8564"] as? [Int])
        XCTAssertEqual(parts.map(\.id), exp["ids_of_8564"] as? [String])
        XCTAssertEqual(parts.flatMap(Sealed.sharedRumors).count, 300)
    }

    func testKeysPacking() throws {
        let v = try vector("sealed")
        let exp = dict(dict(dict(v["ceiling"])["keys_packing"])["expected"])
        let t0 = try XCTUnwrap(dict(v["fixed"])["T0"] as? Int)
        let keys = try (0..<600).map { i -> (lb: String, secret: String) in
            let s = Crypto.sha256("belfry sealed vectors/key/many-lb-\(i)")
            return (try Keys.publicKeyHex(secret: s), s.hex)
        }
        let rumors = Sealed.keysRumors(keys, account: key(v, "alice").pub, giver: key(v, "alice_phone").pub, now: t0 + 600)
        XCTAssertEqual(rumors.map { ((JSON.parse($0.content) as? [String: Any])?["keys"] as? [Any])?.count ?? 0 }, exp["keys_per_8561"] as? [Int])
        XCTAssertEqual(rumors.map { Sealed.json($0).utf8.count }, exp["json_bytes_per_8561"] as? [Int])
        XCTAssertEqual(rumors.map(\.id), exp["ids_of_8561"] as? [String])
    }

    func testKeysHandover() throws {
        let v = try vector("sealed")
        let cases = list(v["keys_handover"])
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let device = try XCTUnwrap(Data(hex: c["device_secret"] as? String ?? ""))
            let account = c["account"] as? String ?? ""
            let h = try XCTUnwrap(Sealed.openKeys(try event(c["wrap"]), device: device), name)
            XCTAssertEqual(h.giver, exp["giver"] as? String, name)
            XCTAssertEqual(h.account, account, name)
            // taken only from a device of some roster of the account's chain, each secret checked
            let ch = try chain(v, named: c["chain"] as? String, account: account)
            var mine = KeyChain()
            if ch?.everHad(h.giver) == true { mine.merge(h.keys) }
            let want = Dictionary(uniqueKeysWithValues: list(exp["keys"]).map { ($0["lb"] as? String ?? "", $0["secret"] as? String ?? "") })
            XCTAssertEqual(mine.keys, want, name)
        }
    }

    func testLink() throws {
        let v = try vector("sealed")
        let cases = list(v["link"])
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let secret = c["link_secret"] as? String ?? ""
            let request = try event(c["request"])
            XCTAssertTrue(request.isValid, name)
            XCTAssertEqual(Sealed.linkProof(secret: secret, device: request.pubkey), exp["link_for_this_device"] as? String, name)
            XCTAssertEqual(Sealed.linked(request, secrets: [secret]), exp["valid"] as? Bool, name)
        }
    }

    func testHistory() throws {
        let v = try vector("sealed")
        let cases = list(v["history"])
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let secret = try XCTUnwrap(Data(hex: c["letterbox_secret"] as? String ?? ""))
            guard case .opened(let rumor, let seal) = Sealed.open(try event(c["wrap"]), secret: secret) else { XCTFail(name); continue }
            XCTAssertEqual(rumor.kind, 8564, name)
            XCTAssertEqual(rumor.pubkey, exp["sharer"] as? String, name)
            XCTAssertEqual(seal, exp["seal_pubkey"] as? String, name)
            let ch = try chain(events: dict(c["sharer_chain_events"]), account: rumor.pubkey)
            XCTAssertTrue(Sealed.accepted(rumor, sealPubkey: seal, chain: ch, belfry: nil), name)
            XCTAssertEqual(Sealed.sharedTaken(rumor, receiver: c["receiver"] as? String ?? "").map(\.id), exp["added_ids"] as? [String], name)
        }
    }

    func testReady() throws {
        let v = try vector("sealed")
        let ready = dict(v["ready"])
        let now = try XCTUnwrap(ready["now"] as? Int)
        let cases = list(ready["cases"])
        XCTAssertEqual(cases.count, 13)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let sessions = list(c["sessions"]).enumerated().map { i, s in
                SessionInfo(applicationName: s["application_name"] as? String ?? "", device: s["device"] as? String, redirectOrigin: "",
                            bunkerPubkey: "session-\(i)", createdAt: s["created_at"] as? String ?? "", lastActivity: s["last_activity"] as? String,
                            clientPubkey: s["client_pubkey"] as? String, chat: s["chat"] as? Bool ?? false)
            }
            XCTAssertEqual(SealedEngine.mayCarryReady(sessions, devices: c["roster_devices"] as? [String] ?? [], now: now),
                           dict(c["expected"])["may_carry_ready"] as? Bool, name)
        }
    }

    private func pin(_ v: Any?) throws -> SealedPin? {
        guard let v, !(v is NSNull) else { return nil }
        return try JSONDecoder().decode(SealedPin.self, from: JSONSerialization.data(withJSONObject: v))
    }

    /// One case's steps: each is one read given to follow(anchor, rosters, pin); then the devices
    /// the person allows on this device. Returns the chain and pin after the last step.
    private func run(_ c: [String: Any], account: String, check: Bool) throws -> (RosterChain?, SealedPin?) {
        let name = c["name"] as? String ?? ""
        var p = try pin(c["pin"])
        var chain: RosterChain?
        for (i, step) in list(c["steps"]).enumerated() {
            let (got, next, event) = SealedFollow.follow(account: account, anchor: try? event(step["anchor"]), rosters: try events(step["rosters"]), pin: p)
            chain = got
            p = next
            for d in step["allow_locally"] as? [String] ?? [] { p = p.map { SealedFollow.allowLocally($0, d) } }
            guard check else { continue }
            let exp = dict(step["expected"])
            let at = "\(name) [step \(i)]"
            XCTAssertEqual(event.rawValue, exp["event"] as? String, at)
            XCTAssertEqual(p, try pin(exp["pin"]), at)
            let ec = dict(exp["chain"])
            // no chain: the lists are empty, the rest null
            XCTAssertEqual(got?.rosters.map(\.id) ?? [], ec["valid_ids"] as? [String] ?? [], at)
            XCTAssertEqual(got?.head.id, ec["head"] as? String, at)
            XCTAssertEqual(got?.devices ?? [], ec["devices"] as? [String] ?? [], at)
            XCTAssertEqual(got?.lb, ec["lb"] as? String, at)
            if got != nil { XCTAssertEqual(got?.ready, ec["ready"] as? Bool, at) }
        }
        return (chain, p)
    }

    func testFollow() throws {
        let v = try vector("sealed")
        let alice = key(v, "alice").pub
        let cases = list(dict(v["follow"])["cases"])
        XCTAssertEqual(cases.count, 17)
        for c in cases { _ = try run(c, account: alice, check: true) }
    }

    /// The pin and trust around a join and a switch (belfry-android's `join.follow`, 8 cases) and
    /// the joiner's own request (`join.requests`, 9 cases).
    func testJoinFollow() throws {
        let v = try vector("sealed")
        let alice = key(v, "alice").pub
        let cases = list(dict(v["join"])["follow"])
        XCTAssertEqual(cases.count, 8)
        for c in cases { _ = try run(c, account: alice, check: true) }
    }

    func testJoinRequests() throws {
        let v = try vector("sealed")
        let alice = key(v, "alice").pub
        let cases = list(dict(v["join"])["requests"])
        XCTAssertEqual(cases.count, 9)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let (chain, p) = try run(c, account: alice, check: true)
            for a in list(c["asks"]) {
                let got = SealedFollow.answerWithoutPrompt(chain: chain, pin: p, device: a["device"] as? String ?? "",
                                                           liveChatDevices: Set(a["live_chat_devices"] as? [String] ?? []),
                                                           requestAt: a["request_created_at"] as? Int ?? 0,
                                                           addedAt: a["added_at"] as? Int, lastHandoverAt: a["last_handover_at"] as? Int)
                XCTAssertEqual(got, a["expected"] as? Bool, "\(name): \(a["device_name"] as? String ?? "")")
            }
        }
    }

    /// A joiner's earlier keys (`join.older_keys`, 9), the 8563 around a joiner (`join.confirm`, 4)
    /// and the endorsement roster "It was me" publishes (`join.endorsement`).
    func testJoinKeysConfirmEndorsement() throws {
        let v = try vector("sealed")
        let alice = key(v, "alice").pub
        let j = dict(v["join"])
        let older = list(j["older_keys"])
        XCTAssertEqual(older.count, 9)
        for c in older {
            let g = dict(c["given"])
            let got = JoinKeys.decide(now: g["now"] as? Int ?? 0, requestAt: g["request_created_at"] as? Int ?? 0, sessionCreatedAt: g["session_created_at"] as? Int,
                                      sessionFresh: g["session_live_chat_read_fresh"] as? Bool ?? false,
                                      thisDeviceOnPinnedAnchoredHead: g["this_device_in_pinned_anchored_head"] as? Bool ?? false,
                                      thisDeviceTrusted: g["this_device_trusted"] as? Bool ?? false, askerTrusted: g["asker_trusted"] as? Bool ?? false,
                                      askerInChainBeforeItsJoin: g["asker_in_chain_before_its_join"] as? Bool ?? true,
                                      othersLetIn24h: g["others_let_in_last_24h"] as? Int ?? 99)
            XCTAssertEqual(got.rawValue, c["expected"] as? String, c["name"] as? String ?? "")
        }
        let confirms = list(j["confirm"])
        XCTAssertEqual(confirms.count, 4)
        for c in confirms {
            let name = c["name"] as? String ?? ""
            let ch = try chain(events: dict(c["chain"]), account: alice)
            let r = dict(c["rumor"])
            let rumor = NostrEvent(id: r["id"] as? String ?? "", pubkey: r["pubkey"] as? String ?? "", createdAt: r["created_at"] as? Int ?? 0,
                                   kind: r["kind"] as? Int ?? 0, tags: r["tags"] as? [[String]] ?? [], content: r["content"] as? String ?? "")
            let got = AddedConfirm.verdict(rumor, sealPubkey: c["seal_pubkey"] as? String ?? "", chain: ch, account: alice,
                                           unanswered: Set(c["unanswered_on_this_device"] as? [String] ?? []))
            let exp = dict(c["expected"])
            var accepted = false
            if case .clears = got { accepted = true }
            XCTAssertEqual(accepted, exp["accepted"] as? Bool, name)
            XCTAssertEqual(got == .later || got == .unknownRoster, exp["judged_again_later"] as? Bool, name)
        }
        // the roster the tapped device publishes ("It was me", and Allow on the card): the head's
        // devices and lb, then the endorse tag; and the 8563 that goes with it
        for name in ["endorsement", "endorsement_by_allow"] {
            let e = dict(j[name])
            let before = try XCTUnwrap(try chain(events: dict(e["before"]), account: alice), name)
            let want = try event(e["roster"])
            let joiner = e["joiner"] as? String ?? ""
            XCTAssertTrue(before.unendorsed.contains(joiner), name)
            let t = RosterChain.template(account: alice, n: before.head.n + 1, prev: before.head.id, lb: before.lb, devices: before.devices,
                                         ready: want.tags.contains(["ready"]), endorse: e["endorses"] as? [String] ?? [], now: want.createdAt)
            XCTAssertEqual(t.tags, want.tags, name)
            XCTAssertEqual(want.pubkey, e["tapped_device"] as? String, name)
            XCTAssertEqual(Roster(want)?.endorses, e["endorses"] as? [String], name)
            let conf = dict(e["confirmation"])
            let join = try XCTUnwrap(AddedConfirm.addedBy(before, joiner), name)
            XCTAssertEqual(conf["tags"] as? [[String]], AddedConfirm.tags(account: alice, device: joiner, roster: join.id), name)
        }
    }

    func testTrust() throws {
        let v = try vector("sealed")
        let alice = key(v, "alice").pub
        let cases = list(dict(v["trust"])["cases"])
        XCTAssertEqual(cases.count, 13)
        var asks = 0
        for c in cases {
            let name = c["name"] as? String ?? ""
            let (chain, p) = try run(c, account: alice, check: true)
            for a in list(c["asks"]) {
                asks += 1
                let got = SealedFollow.answerWithoutPrompt(chain: chain, pin: p, device: a["device"] as? String ?? "",
                                                           liveChatDevices: Set(a["live_chat_devices"] as? [String] ?? []),
                                                           requestAt: a["request_created_at"] as? Int ?? 0,
                                                           addedAt: a["added_at"] as? Int, lastHandoverAt: a["last_handover_at"] as? Int)
                XCTAssertEqual(got, a["expected"] as? Bool, "\(name): \(a["device_name"] as? String ?? "")")
            }
        }
        XCTAssertEqual(asks, 27)
    }

    func testReports() throws {
        let v = try vector("sealed")
        let section = dict(v["reports"])
        let belfry = section["belfry"] as? String
        let cases = list(section["cases"])
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            // what the device holds, as given (a pair may be wrong on purpose)
            let held = Dictionary(list(c["key_chain"]).map { ($0["lb"] as? String ?? "", $0["secret"] as? String ?? "") }, uniquingKeysWith: { a, _ in a })
            let got = Sealed.report(try event(c["report"]), belfry: belfry) { held[$0].flatMap { Data(hex: $0) } }
            switch (got, exp["state"] as? String) {
            case (.opened(let text), "opened"?):
                let body = try XCTUnwrap(JSON.parse(text) as? NSDictionary, name)
                XCTAssertEqual(body, dict(exp["body"]) as NSDictionary, name)
            case (.error, "error"?), (.signer, "signer"?), (.locked, "locked"?): break
            default: XCTFail("\(name): \(got) is not \(exp["state"] as? String ?? "?")")
            }
        }
        // not the belfry's, or changed since it was signed: refused
        let report = try event(cases[0]["report"])
        XCTAssertEqual(Sealed.report(report, belfry: key(v, "mallory").pub) { _ in nil }, .refused)
        var changed = report
        changed.tags.append(["lb", key(v, "bob_lb1").pub])
        XCTAssertEqual(Sealed.report(changed, belfry: belfry, verify: false) { _ in nil }, .refused) // two lb
        XCTAssertEqual(Sealed.report(changed, belfry: belfry) { _ in nil }, .refused) // and its signature no longer holds
    }
}
