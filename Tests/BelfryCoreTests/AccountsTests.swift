import Foundation
import XCTest
@testable import BelfryCore

// Several accounts on one device (SPEC 19.24): slots, migration, where things are kept, and which
// account's K opens a push payload.

final class AccountsTests: XCTestCase {
    let a = String(repeating: "a", count: 64)
    let b = String(repeating: "b", count: 64)

    func testMigrationKeepsTheOldNames() {
        let l = AccountList.migrated(existing: ("belfry.sh", a))
        XCTAssertEqual(l.accounts.map(\.slot), [""])
        XCTAssertEqual(l.current, "")
        XCTAssertEqual(l.open?.id, a + "@belfry.sh")
        XCTAssertEqual(AccountList.sessionKey(""), "session")
        XCTAssertEqual(AccountList.dbName(domain: "belfry.sh", slot: ""), "belfry-belfry.sh.sqlite")
        XCTAssertEqual(AccountList.defaultsKey("belfry-mentions-seen", slot: ""), "belfry-mentions-seen")
        XCTAssertEqual(PushKeyStore.accountName(""), "device-key")
        XCTAssertTrue(AccountList.migrated(existing: nil).accounts.isEmpty)
    }

    func testSlotsAreNeverGivenTwice() {
        var l = AccountList()
        XCTAssertEqual(l.adopt(domain: "belfry.sh", pubkey: a).slot, "")
        let second = l.adopt(domain: "enspiral.eu", pubkey: a)
        XCTAssertEqual(second.slot, "a2")
        XCTAssertTrue(second.isNew)
        // the same identity again keeps its slot
        let again = l.adopt(domain: "belfry.sh", pubkey: a)
        XCTAssertEqual(again.slot, "")
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(l.current, "")
        // a second identity in the same belfry is another account
        XCTAssertEqual(l.adopt(domain: "belfry.sh", pubkey: b).slot, "a3")
        // removing a2 opens the one after it; a2 is not given again
        XCTAssertEqual(l.remove("a2")?.slot, "a3")
        XCTAssertEqual(l.adopt(domain: "x.org", pubkey: b).slot, "a4")
        XCTAssertEqual(AccountList.sessionKey("a4"), "session@a4")
        XCTAssertEqual(AccountList.dbName(domain: "x.org", slot: "a4"), "belfry-x.org@a4.sqlite")
        XCTAssertEqual(PushKeyStore.accountName("a4"), "device-key@a4")
        XCTAssertEqual(PushKeyStore.slot(ofAccount: "device-key@a4"), "a4")
        XCTAssertEqual(PushKeyStore.slot(ofAccount: "device-key"), "")
        XCTAssertNil(PushKeyStore.slot(ofAccount: "other"))
    }

    func testRemoveTheLastOrTheOneBefore() {
        var l = AccountList()
        _ = l.adopt(domain: "one.org", pubkey: a)
        _ = l.adopt(domain: "two.org", pubkey: a)
        XCTAssertEqual(l.remove("a2")?.slot, "")
        XCTAssertNil(l.remove(""))
        XCTAssertNil(l.current)
        // "" is free again (its store was wiped with it)
        XCTAssertEqual(l.adopt(domain: "three.org", pubkey: b).slot, "")
    }

    func testAKeyLearntLaterAndTheLine() {
        var l = AccountList()
        _ = l.adopt(domain: "belfry.sh", pubkey: nil)
        l.setPubkey(a, slot: "")
        XCTAssertEqual(l.adopt(domain: "belfry.sh", pubkey: a).slot, "")
        l.describe("", name: "Xavier", address: "xavier@belfry.sh", community: "Belfry", picture: "", guest: false)
        XCTAssertEqual(l.open?.line, "xavier@belfry.sh")
        l.describe("", name: "", address: "", community: "Belfry", picture: "", guest: true)
        XCTAssertEqual(l.open?.line, "Guest · Belfry")
        XCTAssertEqual(l.open?.placeLine, "Guest · Belfry")
        var e = AccountEntry(slot: "", domain: "riverside.example", pubkey: nil)
        XCTAssertEqual(e.placeLine, "riverside.example")
        e.community = "Riverside Commons"
        XCTAssertEqual(e.placeLine, "Riverside Commons")
        e.role = "Steward"
        XCTAssertEqual(e.placeLine, "Riverside Commons · Steward")
        // a list saved before the role existed still opens
        let old = #"{"accounts":[{"slot":"","domain":"belfry.sh","name":"","address":"","community":"","picture":"","guest":false}],"current":"","nextSlot":2}"#
        let saved = try? JSONDecoder().decode(AccountList.self, from: Data(old.utf8))
        XCTAssertEqual(saved?.accounts.count, 1)
        XCTAssertNil(saved?.accounts.first?.role)
        let data = try! JSONEncoder().encode(l)
        XCTAssertEqual(try! JSONDecoder().decode(AccountList.self, from: data), l)
    }

    func testWhichKeyOpensAPayload() throws {
        let k1 = Push.newKey(), k2 = Push.newKey()
        let o: [String: Any] = ["v": 1, "domain": "enspiral.eu", "type": "dm", "title": "Ana", "body": "Hi"]
        let b = try NIP44.encrypt(JSON.encode(o), conversationKey: k2, nonce: Data(repeating: 7, count: 32))
        let keys = [PushKey(slot: "", domain: "belfry.sh", key: k1), PushKey(slot: "a2", domain: "enspiral.eu", key: k2)]
        let got = Push.openAny(b, keys: keys)
        XCTAssertEqual(got?.slot, "a2")
        XCTAssertEqual(got?.content.title, "Ana")
        // a K that opens it but for another belfry does not count
        XCTAssertNil(Push.openAny(b, keys: [PushKey(slot: "a3", domain: "belfry.sh", key: k2)]))
        XCTAssertEqual(PushKeyStore.parse("belfry.sh " + k1.base64EncodedString())?.key, k1)
        XCTAssertNil(PushKeyStore.parse("belfry.sh short"))
    }
}
