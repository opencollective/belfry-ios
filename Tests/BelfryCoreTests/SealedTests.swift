import Foundation
import XCTest
@testable import BelfryCore

// Sealed conversations (collective-belfry docs/sealed.md, version 1): the roster chain, sealing
// and opening, the key chain, a hand-over, the link proof, my device names, shared history.
// Written from the contract's text; vectors/sealed.json is added when the lead's file arrives.

private func key(_ name: String) -> Data { Crypto.sha256("sealed-test:" + name) }
private func pub(_ name: String) -> String { try! Keys.publicKeyHex(secret: key(name)) }

private func roster(_ account: String, by device: String, n: Int, prev: String?, lb: String, devices: [String], ready: Bool = false, at: Int) -> NostrEvent {
    try! RosterChain.template(account: account, n: n, prev: prev, lb: lb, devices: devices.map(pub), ready: ready, now: at).event(pubkey: "").signed(with: key(device))
}

private func anchor(_ account: String, root: String, at: Int = 100) -> NostrEvent {
    try! RosterChain.anchor(root: root, now: at).event(pubkey: "").signed(with: key(account))
}

final class RosterChainTests: XCTestCase {
    let A = pub("alice")

    func testChainGrowsAndForks() {
        let lb1 = pub("lb1"), lb2 = pub("lb2")
        let r1 = roster(A, by: "phone", n: 1, prev: nil, lb: lb1, devices: ["phone"], at: 100)
        let r2 = roster(A, by: "phone", n: 2, prev: r1.id, lb: lb1, devices: ["phone", "mac"], ready: true, at: 200)
        let r3 = roster(A, by: "mac", n: 3, prev: r2.id, lb: lb2, devices: ["mac"], at: 300)
        let a = anchor("alice", root: r1.id)
        let c = RosterChain.resolve(account: A, anchor: a, rosters: [r3, r1, r2])
        XCTAssertEqual(c?.rosters.map(\.id), [r1.id, r2.id, r3.id])
        XCTAssertEqual(c?.lb, lb2)
        XCTAssertEqual(c?.devices, [pub("mac")])
        XCTAssertEqual(c?.ready, true) // r2 had it: it stays
        // the phone was dropped by r3 (at 300): its old messages still count, later ones don't
        XCTAssertEqual(c?.accepts(device: pub("phone"), rumorAt: 300), true)
        XCTAssertEqual(c?.accepts(device: pub("phone"), rumorAt: 301), false)
        XCTAssertEqual(c?.accepts(device: pub("mac"), rumorAt: 9999), true)
        XCTAssertEqual(c?.accepts(device: pub("other"), rumorAt: 1), false)
        XCTAssertEqual(c?.changes.map { "\($0.added ? "+" : "-")\($0.device == pub("mac") ? "mac" : "phone")@\($0.at)" }, ["+mac@200", "-phone@300"])
        XCTAssertNil(c?.joined(pub("phone"))?.from)
        XCTAssertEqual(c?.joined(pub("mac"))?.from, pub("phone"))
        XCTAssertEqual(c?.joined(pub("mac"))?.at, 200)

        // no anchor, an anchor by someone else, an anchor naming an unknown root: no chain
        XCTAssertNil(RosterChain.resolve(account: A, anchor: nil, rosters: [r1]))
        XCTAssertNil(RosterChain.resolve(account: A, anchor: anchor("mallory", root: r1.id), rosters: [r1]))
        XCTAssertNil(RosterChain.resolve(account: A, anchor: anchor("alice", root: r2.id), rosters: [r1, r2]))

        // a fork: two valid rosters on r1; the lower id wins, the other and what follows it are ignored
        let f = roster(A, by: "phone", n: 2, prev: r1.id, lb: lb1, devices: ["phone", "pad"], at: 201)
        let fork = RosterChain.resolve(account: A, anchor: a, rosters: [r1, r2, f])
        XCTAssertEqual(fork?.rosters.last?.id, min(r2.id, f.id))
    }

    func testInvalidRostersAreIgnored() {
        let lb1 = pub("lb1"), lb2 = pub("lb2")
        let r1 = roster(A, by: "phone", n: 1, prev: nil, lb: lb1, devices: ["phone"], at: 100)
        let a = anchor("alice", root: r1.id)
        func head(_ e: NostrEvent) -> String? { RosterChain.resolve(account: A, anchor: a, rosters: [r1, e])?.head.id }
        // signed by a device that is not in the roster before
        XCTAssertEqual(head(roster(A, by: "thief", n: 2, prev: r1.id, lb: lb1, devices: ["phone", "thief"], at: 200)), r1.id)
        // n is not the previous n + 1
        XCTAssertEqual(head(roster(A, by: "phone", n: 3, prev: r1.id, lb: lb1, devices: ["phone", "mac"], at: 200)), r1.id)
        // nobody left and a new letterbox; somebody left and the same letterbox
        XCTAssertEqual(head(roster(A, by: "phone", n: 2, prev: r1.id, lb: lb2, devices: ["phone", "mac"], at: 200)), r1.id)
        let r2 = roster(A, by: "phone", n: 2, prev: r1.id, lb: lb1, devices: ["phone", "mac"], at: 200)
        let drop = roster(A, by: "mac", n: 3, prev: r2.id, lb: lb1, devices: ["mac"], at: 300)
        XCTAssertEqual(RosterChain.resolve(account: A, anchor: a, rosters: [r1, r2, drop])?.head.id, r2.id)
        // a device twice, 21 devices, a broken signature
        XCTAssertEqual(head(roster(A, by: "phone", n: 2, prev: r1.id, lb: lb1, devices: ["phone", "mac", "mac"], at: 200)), r1.id)
        XCTAssertEqual(head(roster(A, by: "phone", n: 2, prev: r1.id, lb: lb1, devices: ["phone"] + (1...20).map { "d\($0)" }, at: 200)), r1.id)
        var bad = r2
        bad.sig = String(repeating: "0", count: 128)
        XCTAssertEqual(head(bad), r1.id)
        // a root that its signer is not part of
        let odd = roster(A, by: "phone", n: 1, prev: nil, lb: lb1, devices: ["mac"], at: 100)
        XCTAssertNil(RosterChain.resolve(account: A, anchor: anchor("alice", root: odd.id), rosters: [odd]))
        // a letterbox that comes back after a removal
        let r3 = roster(A, by: "mac", n: 3, prev: r2.id, lb: lb2, devices: ["mac"], at: 300)
        let r4 = roster(A, by: "mac", n: 4, prev: r3.id, lb: lb2, devices: ["mac", "pad"], at: 400)
        let back = roster(A, by: "mac", n: 5, prev: r4.id, lb: lb1, devices: ["mac"], at: 500)
        XCTAssertEqual(RosterChain.resolve(account: A, anchor: a, rosters: [r1, r2, r3, r4, back])?.head.id, r4.id)
    }
}

final class SealedMessageTests: XCTestCase {
    func testSealAndOpen() throws {
        var bob = KeyChain()
        let lb = try bob.make()
        let rumor = GiftWrap.rumor(kind: 14, pubkey: pub("alice"), tags: [["p", pub("bob")]], content: "Hello Bob", createdAt: 1000)
        let w = try Sealed.wrap(rumor, device: key("alice-phone"), to: pub("bob"), lb: lb)
        XCTAssertEqual(w.kind, 1059)
        XCTAssertTrue(w.isValid)
        XCTAssertEqual(w.tags, [["p", pub("bob")], ["lb", lb]])
        XCTAssertEqual(Sealed.lb(of: w), lb)
        XCTAssertFalse(w.content.contains("Hello"))
        guard case .opened(let r, let seal) = Sealed.open(w, keys: bob) else { return XCTFail("not opened") }
        XCTAssertEqual(r.id, rumor.id)
        XCTAssertEqual(r.content, "Hello Bob")
        XCTAssertEqual(r.pubkey, pub("alice"))
        XCTAssertEqual(seal, pub("alice-phone")) // the device signed the seal, not the account
        // no secret for that letterbox: locked here, the wrap is kept
        guard case .locked = Sealed.open(w, keys: KeyChain()) else { return XCTFail("not locked") }
        // an old-style wrap is not ours to open
        var old = w
        old.tags = [["p", pub("bob")]]
        guard case .invalid = Sealed.open(old, keys: bob) else { return XCTFail("old wrap opened") }
        // a wrap whose content was changed does not open
        var broken = w
        broken.content = String(w.content.dropLast(4)) + "AAAA"
        guard case .invalid = Sealed.open(broken, keys: bob) else { return XCTFail("broken wrap opened") }
    }

    func testKeyChain() throws {
        var c = KeyChain()
        XCTAssertFalse(c.add(lb: pub("x"), secret: key("y").hex)) // a secret that is not its key's
        XCTAssertTrue(c.add(lb: pub("x"), secret: key("x").hex))
        XCTAssertEqual(c.secret(pub("x")), key("x"))
        XCTAssertTrue(c.merge([(pub("z"), key("z").hex), (pub("w"), key("x").hex)]))
        XCTAssertEqual(Set(c.keys.keys), [pub("x"), pub("z")])
        XCTAssertFalse(c.merge([(pub("z"), key("z").hex)]))
        // stored and read back; a stored entry that does not match is dropped
        let back = try JSONDecoder().decode(KeyChain.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        XCTAssertTrue(KeyChain(keys: [pub("x"): key("y").hex]).isEmpty)
    }

    func testHandover() throws {
        var chain = KeyChain()
        chain.add(lb: pub("lb1"), secret: key("lb1").hex)
        chain.add(lb: pub("lb2"), secret: key("lb2").hex)
        let w = try Sealed.keysWrap(chain, account: pub("alice"), device: key("phone"), to: pub("mac"))
        XCTAssertEqual(w.tags, [["p", pub("mac")]])
        let h = try XCTUnwrap(Sealed.openKeys(w, device: key("mac")))
        XCTAssertEqual(h.giver, pub("phone"))
        XCTAssertEqual(h.account, pub("alice"))
        var mine = KeyChain()
        XCTAssertTrue(mine.merge(h.keys))
        XCTAssertEqual(mine, chain)
        XCTAssertNil(Sealed.openKeys(w, device: key("other")))
    }

    func testRequestAndLink() throws {
        let secret = String(repeating: "ab", count: 32)
        let t = Sealed.request(account: pub("alice"), device: pub("mac"), link: secret, now: 50)
        XCTAssertEqual(t.kind, 8562)
        let proof = Crypto.hmacSHA256(key: Data(hex: secret)!, Data(hex: pub("mac"))!).hex
        XCTAssertEqual(t.tags, [["p", pub("alice")], ["link", proof]])
        let e = try t.event(pubkey: "").signed(with: key("mac"))
        XCTAssertTrue(Sealed.linked(e, secrets: [String(repeating: "cd", count: 32), secret]))
        XCTAssertFalse(Sealed.linked(e, secrets: [String(repeating: "cd", count: 32)]))
        // the same proof signed by another device proves nothing
        XCTAssertFalse(Sealed.linked(try t.event(pubkey: "").signed(with: key("thief")), secrets: [secret]))
        XCTAssertEqual(Sealed.request(account: pub("alice"), device: pub("mac"), now: 50).tags, [["p", pub("alice")]])

        let url = URL(string: "https://chat.belfry.sh/login/sam#l=" + secret)!
        XCTAssertEqual(LoginLink.parse(url), MemberAddress(name: "sam", domain: "belfry.sh"))
        XCTAssertEqual(LoginLink.linkSecret(url), secret)
        XCTAssertNil(LoginLink.linkSecret(URL(string: "https://chat.belfry.sh/login/sam")!))
        XCTAssertNil(LoginLink.parse(URL(string: "https://chat.belfry.sh/login/sam#l=abc")!))
        XCTAssertNil(LoginLink.parse(URL(string: "https://chat.belfry.sh/login/sam#other")!))
        XCTAssertEqual(LoginLink.link(MemberAddress(name: "sam", domain: "belfry.sh"), secret: secret), url.absoluteString)
    }

    func testDeviceNames() throws {
        var chain = KeyChain()
        let lb = try chain.make()
        let old: [String: Any] = ["v": 1, "later": "kept", "devices": [pub("mac"): ["name": "Safari on Mac", "kind": "computer", "added": 10, "x": 1],
                                                                        pub("gone"): ["name": "Old", "kind": "phone", "added": 1]]]
        let doc = Sealed.deviceDoc(old, device: pub("phone"), entry: .init(name: "iPhone", kind: "phone", added: 20),
                                   gone: [pub("gone"): 0], now: 91 * 86400)
        let e = try Sealed.devicesTemplate(doc, lb: lb, keys: chain, now: 30).event(pubkey: "").signed(with: key("alice"))
        XCTAssertEqual(e.tags, [["d", "belfry:devices"], ["lb", lb]])
        let read = try XCTUnwrap(Sealed.deviceNames(e, keys: chain))
        XCTAssertEqual(read["later"] as? String, "kept")
        XCTAssertEqual(((read["devices"] as? [String: Any])?[pub("mac")] as? [String: Any])?["x"] as? Int, 1)
        let names = Sealed.names(in: read)
        XCTAssertEqual(names[pub("phone")], .init(name: "iPhone", kind: "phone", added: 20))
        XCTAssertEqual(names[pub("mac")]?.name, "Safari on Mac")
        XCTAssertNil(names[pub("gone")])
        XCTAssertNil(Sealed.deviceNames(e, keys: KeyChain()))
    }

    func testSharedHistory() throws {
        let a = pub("alice"), b = pub("bob")
        let rumors = (0..<450).map { GiftWrap.rumor(kind: 14, pubkey: $0 % 2 == 0 ? a : b, tags: [["p", $0 % 2 == 0 ? b : a]], content: "message \($0)", createdAt: 1000 + $0) }
        let parts = Sealed.history(rumors, sharer: a, person: b, now: 5000)
        XCTAssertGreaterThanOrEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Sealed.sharedRumors($0).count <= 200 })
        XCTAssertTrue(parts.allSatisfy { $0.kind == 8564 && $0.pubkey == a && $0.tags == [["p", b]] && $0.json.utf8.count <= 40_000 })
        // packed full: the next rumor would not have fitted
        XCTAssertGreaterThan(parts[0].json.utf8.count, 39_000)
        XCTAssertEqual(parts.flatMap(Sealed.sharedRumors).map(\.id), rumors.map(\.id))
        // it travels like any sealed message
        var chain = KeyChain()
        let lb = try chain.make()
        let w = try Sealed.wrap(parts[0], device: key("alice-phone"), to: b, lb: lb)
        guard case .opened(let r, _) = Sealed.open(w, keys: chain) else { return XCTFail("not opened") }
        XCTAssertEqual(Sealed.sharedRumors(r).map(\.id), Sealed.sharedRumors(parts[0]).map(\.id))
    }
}
