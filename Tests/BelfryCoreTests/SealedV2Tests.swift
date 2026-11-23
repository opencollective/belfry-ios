import Foundation
import XCTest
@testable import BelfryCore

// Sealed version 2 (docs/sealed-v2.md, belfry-sh df53525), written from the contract's text;
// belfry-android's `v2` vectors are run when they land.

private func key(_ name: String) -> Data { Crypto.sha256("sealed-v2-test:" + name) }
private func pub(_ name: String) -> String { try! Keys.publicKeyHex(secret: key(name)) }

private func list(_ account: String, _ devices: [String], at: Int, by: String = "belfry") -> NostrEvent {
    try! NostrEvent(pubkey: "", createdAt: at, kind: 30078, tags: [["d", DeviceList.d(pub(account))], ["p", pub(account)]] + devices.map { ["device", pub($0)] },
                    content: "").signed(with: key(by))
}

final class SealedV2Tests: XCTestCase {
    let B = pub("belfry"), A = pub("alice")

    func testTheListIsTheBelfrysAndTheNewestWins() {
        let l1 = list("alice", ["phone"], at: 100), l2 = list("alice", ["phone", "mac"], at: 200)
        XCTAssertEqual(DeviceList(l1, belfry: B)?.devices, [pub("phone")])
        XCTAssertNil(DeviceList(list("alice", ["phone"], at: 100, by: "alice"), belfry: B), "never from another author")
        XCTAssertNil(DeviceList(list("alice", ["phone", "phone"], at: 100), belfry: B), "a device twice")
        XCTAssertNil(DeviceList(list("alice", (0..<21).map { "d\($0)" }, at: 100), belfry: B), "more than 20")
        XCTAssertEqual(DeviceList(list("alice", [], at: 100), belfry: B)?.devices, [], "an empty list is a list")
        XCTAssertEqual(DeviceList.newest([l1, l2], belfry: B, account: A, now: 300)?.id, l2.id)
        XCTAssertEqual(DeviceList.newest([l1, l2], belfry: B, account: pub("bob"), now: 300), nil)
        // dated more than 10 minutes ahead: ignored
        let ahead = list("alice", ["mallory"], at: 300 + 601)
        XCTAssertEqual(DeviceList.newest([l1, l2, ahead], belfry: B, account: A, now: 300)?.id, l2.id)
        XCTAssertEqual((DeviceList.filter(belfry: B, accounts: [A])["#d"] as? [String]), ["belfry:devices:" + A])
    }

    func testAcceptAndNotices() throws {
        let l1 = try XCTUnwrap(DeviceList(list("alice", ["phone", "old"], at: 100), belfry: B))
        let l2 = try XCTUnwrap(DeviceList(list("alice", ["phone", "mac"], at: 200), belfry: B))
        var seen = ListsSeen()
        XCTAssertTrue(seen.see(l1, now: 1000))
        XCTAssertEqual(seen.added, [], "no notice for the first list an app ever sees")
        XCTAssertTrue(seen.accepts(device: pub("old"), rumorAt: 5000))
        XCTAssertFalse(seen.accepts(device: pub("mac"), rumorAt: 5000), "never seen listed")
        XCTAssertTrue(seen.see(l2, now: 2000))
        XCTAssertFalse(seen.see(l2, now: 3000), "seen once")
        XCTAssertEqual(seen.added, [pub("mac")])
        XCTAssertEqual(seen.newest?.id, l2.id)
        XCTAssertTrue(seen.accepts(device: pub("mac"), rumorAt: 1))
        // a removed device: what it wrote until this app first saw a list without it, nothing after
        XCTAssertEqual(seen.firstSeenWithout(pub("old")), 2000)
        XCTAssertTrue(seen.accepts(device: pub("old"), rumorAt: 2000))
        XCTAssertFalse(seen.accepts(device: pub("old"), rumorAt: 2001))
    }

    func testAWrapPerDevice() throws {
        let rumor = GiftWrap.rumor(kind: 14, pubkey: A, tags: [["p", pub("bob")], ["list", A, String(repeating: "a", count: 64)]], content: "Hello", createdAt: 500)
        let toBob = try SealedV2.wrap(rumor, device: key("phone"), to: pub("bobphone"), of: pub("bob"))
        XCTAssertEqual(toBob.tags, [["p", pub("bob")], ["d", pub("bobphone")]])
        let mine = try SealedV2.wrap(rumor, device: key("phone"), to: pub("mac"), of: A)
        XCTAssertEqual(mine.tags, [["p", A], ["d", pub("mac")], ["silent", "1"]], "my own devices: silent")
        XCTAssertEqual(SealedV2.device(of: toBob), pub("bobphone"))
        XCTAssertNil(Sealed.lb(of: toBob), "not a letterbox wrap")
        guard case .opened(let got, let seal) = SealedV2.open(toBob, device: key("bobphone")) else { return XCTFail("does not open") }
        XCTAssertEqual(got.id, rumor.id)
        XCTAssertEqual(seal, pub("phone"))
        XCTAssertEqual(SealedV2.listNamed(got, for: A), String(repeating: "a", count: 64))
        if case .opened = SealedV2.open(toBob, device: key("mac")) { XCTFail("another device opens it") }
        let f = SealedV2.filter(account: A, device: pub("phone"))
        XCTAssertEqual(f["#d"] as? [String], [pub("phone")])
    }

    func testWhenAConversationIsSealed() throws {
        let la = try XCTUnwrap(DeviceList(list("alice", ["phone"], at: 100), belfry: B))
        let lb = try XCTUnwrap(DeviceList(list("bob", ["bobphone"], at: 100), belfry: B))
        let bob = pub("bob")
        XCTAssertEqual(SealedV2.state(participants: [A, bob], lists: [A: la, bob: lb], read: [A, bob], seenNonEmpty: []), .sealed)
        XCTAssertEqual(SealedV2.state(participants: [A, bob], lists: [A: la], read: [A, bob], seenNonEmpty: []), .notSealed, "an account with no list")
        XCTAssertEqual(SealedV2.state(participants: [A, bob], lists: [A: la], read: [A], seenNonEmpty: []), .hold, "a list that cannot be read")
        XCTAssertEqual(SealedV2.state(participants: [A, bob], lists: [A: la], read: [A, bob], seenNonEmpty: [bob]), .hold, "seen once, missing now: hold, never the old way")
        XCTAssertEqual(SealedV2.listTags([lb, la]).map { $0[1] }, [A, bob].sorted())
    }

    /// The lists a device knows: read from the belfry, remembered across runs, and what a message
    /// between two people becomes: a wrap per device, opened and accepted on the other side.
    func testDeviceListsEndToEnd() async throws {
        let path = NSTemporaryDirectory() + "belfry-v2-\(UUID().uuidString).sqlite"
        let bob = pub("bob")
        let events = [list("alice", ["phone", "mac"], at: 100), list("bob", ["bobphone"], at: 100)]
        let phone = try XCTUnwrap(DeviceLists(me: A, belfry: B, deviceSecret: key("phone"), db: try Database(path: path)))
        phone.ask = { _ in events }
        XCTAssertEqual(phone.state([A, bob], now: 1000), .hold, "nothing read yet: hold")
        XCTAssertEqual(await phone.refresh([A, bob], now: 1000), [A, bob])
        XCTAssertTrue(phone.listed)
        XCTAssertEqual(phone.state([A, bob], now: 1000), .sealed)
        XCTAssertEqual(phone.addedDevices(), [], "the first list ever seen raises nothing")
        let rumor = GiftWrap.rumor(kind: 14, pubkey: A, tags: [["p", bob]] + phone.listTags([A, bob]), content: "Hi", createdAt: 900)
        let wraps = try phone.wraps(rumor, participants: [A, bob])
        XCTAssertEqual(wraps.count, 3, "one per device of every participant, this device included")
        XCTAssertEqual(Set(wraps.compactMap(SealedV2.device(of:))), [pub("phone"), pub("mac"), pub("bobphone")])
        // Bob's phone opens its own and accepts it once it has read Alice's list
        let bobPhone = try XCTUnwrap(DeviceLists(me: bob, belfry: B, deviceSecret: key("bobphone"), db: try Database(path: path + "b")))
        let his = try XCTUnwrap(wraps.first { SealedV2.device(of: $0) == pub("bobphone") })
        if case .unjudged = bobPhone.open(his) {} else { XCTFail("before the list is read it is kept, not accepted") }
        bobPhone.take(events, now: 1000)
        guard case .accepted(let got, let seal) = bobPhone.open(his) else { return XCTFail("not accepted") }
        XCTAssertEqual(got.id, rumor.id)
        XCTAssertEqual(seal, pub("phone"))
        if case .no = bobPhone.open(wraps[0]) {} else if SealedV2.device(of: wraps[0]) != pub("bobphone") { XCTFail("another device's wrap") }
        // a list from another key changes nothing; a new device raises the notice; memory survives
        phone.take([list("alice", ["phone", "mallory"], at: 300, by: "mallory")], now: 1100)
        XCTAssertEqual(phone.list(A)?.devices.count, 2)
        phone.take([list("alice", ["phone", "mac", "tablet"], at: 200)], now: 1200)
        XCTAssertEqual(phone.addedDevices(), [pub("tablet")])
        let again = try XCTUnwrap(DeviceLists(me: A, belfry: B, deviceSecret: key("phone"), db: try Database(path: path)))
        XCTAssertEqual(again.list(A)?.devices.count, 3)
        XCTAssertEqual(again.state([A, bob], now: 1300), .hold, "a new run reads the lists again before it seals")
    }

    func testBelfryJsonSealed() {
        XCTAssertFalse(BelfryConfig.from(domain: "example.org", document: [:]).sealedLists)
        let v1 = BelfryConfig.from(domain: "example.org", document: ["sealed": ["version": 1, "lists": true]])
        XCTAssertTrue(v1.sealedLists); XCTAssertEqual(v1.sealedVersion, 1)
        let v2 = BelfryConfig.from(domain: "example.org", document: ["sealed": ["version": 2]])
        XCTAssertTrue(v2.sealedLists); XCTAssertEqual(v2.sealedVersion, 2)
    }
}
