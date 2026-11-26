import XCTest
@testable import BelfryCore

// The format-3 engine on this device (docs/encrypted.md; SPEC 19.70): what a send makes, what the
// other side opens, and the holds (never clear, never another account's key, never backdated).
// Keys and lists from vectors/encrypted.json (Sam's d2 writes to Lina's c1).

private func sk(_ name: String) -> Data { Crypto.sha256(Data(("belfry-vector:" + name).utf8)) }

final class EncEngineTests: XCTestCase {
    var v: [String: Any] = [:]
    var K: [String: String] = [:]

    override func setUpWithError() throws {
        v = try vector("encrypted")
        K = (v["keys"] as? [String: String]) ?? [:]
    }

    func list(_ name: String) throws -> NostrEvent { try event(v.dict("lists").dict("valid").dict(name)["event"]) }

    /// Sam's engine on device d2, on a format-3 belfry, with the lists of Sam (L1–L3) and Lina (LC1).
    func samOn(_ device: String = "d2", lists: [String] = ["L1", "L2", "L3", "LC1"]) throws -> (SyncEngine, EncEngine) {
        var cfg = BelfryConfig.defaults(domain: "example.org")
        cfg.belfryKey = v.str("belfry")
        cfg.encryptedFormat = 3
        let e = SyncEngine(config: cfg, db: try Database.memory(), signer: try LocalSigner(secret: sk("sam")), localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        _ = e.add(try lists.map(list), verify: false)
        let enc = EncEngine(engine: e, deviceSecret: sk(device))
        enc.assumeRead = true
        return (e, enc)
    }

    func testAPeopleMessageGoesEncryptedAndOpensOnTheOtherSide() async throws {
        let (_, enc) = try samOn()
        XCTAssertTrue(enc.writes3)
        XCTAssertEqual(enc.listedHere(), .yes, "d2 is on Sam's current list (L3)")
        let rumor = Enc.withId(NostrEvent(pubkey: K["sam"]!, createdAt: Int.now, kind: 14, tags: [["p", K["lina"]!]], content: "Bread on Saturday?"))
        let got = try await enc.encrypt(rumor, people: [K["lina"]!])
        let out = try XCTUnwrap(got)
        XCTAssertEqual(out.missing, [])
        let envs = out.events.filter { $0.kind == Enc.key }, msgs = out.events.filter { $0.kind == Enc.msg }
        XCTAssertEqual(envs.count, 2, "a new key: one envelope per person, before the messages")
        XCTAssertEqual(msgs.count, 2, "one copy per person, mine included")
        XCTAssertEqual(out.events.firstIndex { $0.kind == Enc.msg }, 2, "envelopes first")
        XCTAssertTrue(msgs.allSatisfy { abs($0.createdAt - Int.now) <= 2 }, "never backdated (§17.11)")
        XCTAssertTrue(msgs.first { $0.hasTag("p", K["sam"]!) }!.tags.contains(Enc.silent), "my own copy is silent")
        // Lina's device c1 opens its envelope and her copy
        let linaEnv = try XCTUnwrap(envs.first { $0.hasTag("p", K["lina"]!) })
        let o = try XCTUnwrap(try Enc.openPeopleEnvelope(device: sk("c1"), linaEnv))
        let linaMsg = try XCTUnwrap(msgs.first { $0.hasTag("p", K["lina"]!) })
        let opened = try Enc.openPeopleMessage(k: o.rumor.content, linaMsg)
        XCTAssertEqual(opened.rumor.id, rumor.id)
        XCTAssertEqual(opened.rumor.content, "Bread on Saturday?")
        // the next message uses the same key: no new envelopes
        let r2 = Enc.withId(NostrEvent(pubkey: K["sam"]!, createdAt: Int.now, kind: 14, tags: [["p", K["lina"]!]], content: "And jam?"))
        enc.confirmed(envs[0].id); enc.confirmed(envs[1].id)
        let again = try await enc.encrypt(r2, people: [K["lina"]!])
        XCTAssertEqual(again?.events.filter { $0.kind == Enc.key }.count, 0)
        XCTAssertTrue(enc.isEncrypted([K["sam"]!, K["lina"]!]))
    }

    func testHeld() async throws {
        let (_, enc) = try samOn()
        // someone with no list known: held, never sent clear, never on their account key (§17.1)
        let toOther = Enc.withId(NostrEvent(pubkey: K["sam"]!, createdAt: Int.now, kind: 14, tags: [["p", K["other"]!]], content: "hi"))
        do { _ = try await enc.encrypt(toOther, people: [K["other"]!]); XCTFail("sent") } catch let h as EncEngine.Held {
            guard case .noList = h else { return XCTFail("\(h)") } // (named, or before: the read of the lists failed)
        }
        // a device not on its own account's list holds what it would send (§3)
        let (_, d1) = try samOn("d1")
        XCTAssertNotEqual(d1.listedHere(), .yes, "d1 left Sam's list at L3")
        let r = Enc.withId(NostrEvent(pubkey: K["sam"]!, createdAt: Int.now, kind: 14, tags: [["p", K["lina"]!]], content: "hi"))
        do { _ = try await d1.encrypt(r, people: [K["lina"]!]); XCTFail("sent") } catch let h as EncEngine.Held { XCTAssertEqual(h, .notListed) }
        // a guest in an encrypted conversation: held (§25), never clear
        _ = try await enc.encrypt(r, people: [K["lina"]!])
        enc.setWorld(EncEngine.World(guests: [K["lina"]!]))
        do { _ = try await enc.encrypt(r, people: [K["lina"]!]); XCTFail("sent") } catch let h as EncEngine.Held { XCTAssertEqual(h, .guest) }
    }

    func testNeverAnotherAccountsKey() async throws {
        let (e, enc) = try samOn()
        // Lina's key for our conversation arrives (made by her c1 for the same lists): opened, never sent with (§17.8)
        let L3 = try list("L3"), LC1 = try list("LC1")
        let theirs = Enc.newKey(sk("linas-key"))
        let kr = Enc.keyRumor(maker: K["c1"]!, k: theirs.k, people: [(K["sam"]!, L3.id), (K["lina"]!, LC1.id)])
        let envs = try Enc.peopleEnvelopes(maker: sk("c1"), rumor: kr, people: [(K["sam"]!, ["d2"].map { _ in K["d2"]! }), (K["lina"]!, [K["c1"]!])])
        _ = e.add(envs, verify: true)
        enc.takeEnvelopes()
        XCTAssertEqual(enc.keyCount, 1, "her key is held to read with")
        let r = Enc.withId(NostrEvent(pubkey: K["sam"]!, createdAt: Int.now, kind: 14, tags: [["p", K["lina"]!]], content: "hi"))
        let out = try await enc.encrypt(r, people: [K["lina"]!])
        XCTAssertEqual(out?.events.filter { $0.kind == Enc.key }.count, 2, "my own new key, not hers")
        let used = out!.events.first { $0.kind == Enc.msg }!.tag("d")
        XCTAssertNotEqual(used, Enc.alias(theirs.K, K["sam"]!))
    }

    func testAListSignedBySomeoneElseCountsForNothing() throws {
        let (e, enc) = try samOn(lists: [])
        // §3: an 8570 counts only from the belfry key of belfry.json, never from a session or anyone else
        let bad = try event(v.dict("lists").dict("valid").dict("other_signer")["event"])
        _ = e.add([bad], verify: false)
        XCTAssertEqual(enc.devices(K["sam"]!), .unknown)
        XCTAssertEqual(enc.devices(v.str("belfry")!), .service, "the belfry key is its own device")
    }
}
