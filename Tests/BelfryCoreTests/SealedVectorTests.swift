import Foundation
import XCTest
@testable import BelfryCore

// vectors/sealed.json = collective-belfry docs/sealed-vectors.json (sha256 572c8f01…95e4), byte
// for byte: the roster chain, opening and acceptance, the ceiling and the packing of a shared
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
        XCTAssertEqual(cases.count, 27)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let exp = dict(c["expected"])
            let got = RosterChain.resolve(account: alice, anchor: try? event(c["anchor"]), rosters: try events(c["rosters"]))
            XCTAssertEqual(got?.rosters.map(\.id) ?? [], exp["valid_ids"] as? [String] ?? [], name)
            XCTAssertEqual(got?.head.id, exp["head"] as? String, name)
            XCTAssertEqual(got?.devices ?? [], exp["devices"] as? [String] ?? [], name)
            XCTAssertEqual(got?.lb, exp["lb"] as? String, name)
            XCTAssertEqual(got?.ready ?? false, exp["ready"] as? Bool ?? false, name)
        }
    }

    func testWraps() throws {
        let v = try vector("sealed")
        let cases = list(v["wraps"])
        XCTAssertEqual(cases.count, 11)
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
        XCTAssertEqual(cases.count, 3)
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
}
