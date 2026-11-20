import Foundation
import XCTest
@testable import BelfryCore

// The sealed engine against a fake relay (docs/sealed.md 5 and 6): the first device, a second
// device asking and being allowed (or refused, or let in by the link's proof), a message between
// two people, a device leaving. The "relay" is a list every device publishes to and reads from;
// /api/me/sessions is a list the test edits.

private func secret(_ name: String) -> Data { Crypto.sha256("sealed-engine-test:" + name) }

private final class FakeBelfry: @unchecked Sendable {
    let lock = NSLock()
    var events = [NostrEvent]()
    var sessions = [String: [SessionInfo]]() // account → its sessions
    var revoked = [String]()
    var devices = [Device]()

    func put(_ e: NostrEvent) { lock.lock(); if !events.contains(where: { $0.id == e.id }) { events.append(e) }; lock.unlock() }
    func all() -> [NostrEvent] { lock.lock(); defer { lock.unlock() }; return events }
    func list(_ account: String) -> [SessionInfo] { lock.lock(); defer { lock.unlock() }; return sessions[account] ?? [] }

    /// Everything queued goes out, and every device reads everything (a few rounds: one device's
    /// answer may be another's question).
    func sync() async {
        for _ in 0..<3 {
            for d in devices { await d.engine.flush() }
            let now = all()
            for d in devices { d.engine.add(now); d.sealed.takeKeys(); d.sealed.observe(now.compactMap { $0.kind == 8560 ? $0.tag("p") : $0.pubkey }) }
        }
    }

    func signIn(_ person: String, _ device: String, name: String = "", chat: Bool = true, link: String? = nil) throws -> Device {
        let account = try LocalSigner(secret: secret(person))
        let key = secret(person + "/" + device)
        let pub = try Keys.publicKeyHex(secret: key)
        let engine = SyncEngine(config: .defaults(domain: "example.org"), db: try .memory(), signer: account, localOnly: true,
                                attachmentsDir: FileManager.default.temporaryDirectory)
        let sealed = try XCTUnwrap(SealedEngine(engine: engine, deviceSecret: key, store: MemoryKeyStore()))
        sealed.runsLocally = true
        sealed.mayStart = true
        sealed.removalWait = 0...0
        sealed.askAnchor = { [weak self] in self?.all().filter { $0.kind == 30078 && $0.pubkey == account.pubkey && $0.tag("d") == SealedKind.anchorD } }
        sealed.sessions = { [weak self] in self?.list(account.pubkey) }
        sealed.revoke = { [weak self] bunker in
            guard let self else { return false }
            self.lock.lock()
            self.revoked.append(bunker)
            self.sessions[account.pubkey]?.removeAll { $0.bunkerPubkey == bunker }
            self.lock.unlock()
            return true
        }
        sealed.myName = { Sealed.DeviceName(name: "iPhone", kind: "phone", added: 1) }
        sealed.setLink(link)
        engine.onSent = { [weak self] _, e in if let e { self?.put(e) } }
        lock.lock()
        sessions[account.pubkey, default: []].append(SessionInfo(applicationName: "Belfry", device: name, redirectOrigin: "", bunkerPubkey: "bunker-" + pub,
                                                                  createdAt: "2026-11-20T10:00:00Z", lastActivity: nil, clientPubkey: pub, chat: chat))
        lock.unlock()
        let d = Device(account: account.pubkey, pub: pub, engine: engine, sealed: sealed)
        devices.append(d)
        return d
    }

    struct Device {
        let account: String
        let pub: String
        let engine: SyncEngine
        let sealed: SealedEngine
    }
}

final class SealedEngineTests: XCTestCase {
    /// 2026-11-20 12:00 UTC: two hours after every session of these tests was created.
    let now = 1795176000

    func testFirstDeviceThenASecondOneIsAllowed() async throws {
        let b = FakeBelfry()
        let phone = try b.signIn("alice", "phone", name: "Alice's iPhone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        // 5.1: a root with this device, the anchor, ready (its only chat session is in it), its name
        var chain = try XCTUnwrap(phone.sealed.chain(phone.account))
        XCTAssertEqual(chain.rosters.count, 1)
        XCTAssertEqual(chain.devices, [phone.pub])
        XCTAssertTrue(chain.ready)
        XCTAssertEqual(phone.sealed.mine, .inside)
        await phone.sealed.maintain(now: now)
        await b.sync()
        XCTAssertEqual(phone.sealed.deviceNames()[phone.pub]?.name, "Alice's iPhone") // the session's own name
        XCTAssertEqual(b.all().filter { $0.kind == 8560 }.count, 1) // a second upkeep publishes nothing more
        // the anchor names the root as the head
        let first = b.all().filter { $0.kind == 30078 && $0.tag("d") == "belfry:sealed" }
        XCTAssertEqual(first.map { $0.tag("head") }, [chain.root.id])

        // 5.2: a second device finds the chain, is not in it, asks; it reads nothing sealed
        let mac = try b.signIn("alice", "mac", name: "Safari on Mac")
        await b.sync()
        await mac.sealed.maintain(now: now)
        await b.sync()
        XCTAssertEqual(mac.sealed.mine, .waiting)
        XCTAssertEqual(b.all().filter { $0.kind == 8562 && $0.pubkey == mac.pub }.count, 1)
        await mac.sealed.maintain(now: now + 3600)
        await b.sync()
        XCTAssertEqual(b.all().filter { $0.kind == 8562 }.count, 1) // asked again only after 24 h
        XCTAssertEqual(b.all().filter { $0.kind == 8560 }.count, 1) // and it never made a chain of its own
        let rumor = GiftWrap.rumor(kind: 14, pubkey: phone.account, tags: [["p", phone.account]], content: "note to self", createdAt: now)
        let wrap = try XCTUnwrap(try phone.sealed.wraps(rumor, to: []).first)
        guard case .keep = mac.sealed.open(wrap) else { return XCTFail("a device nobody allowed opened a sealed message") }
        XCTAssertTrue(mac.sealed.isLocked(wrap))
        XCTAssertThrowsError(try mac.sealed.wraps(rumor, to: []))

        // the phone is asked, with the name of the session; Allow hands the keys over and adds it
        await phone.sealed.maintain(now: now)
        let asks = await phone.sealed.asks()
        XCTAssertEqual(asks.map(\.device), [mac.pub])
        XCTAssertEqual(asks.first?.name, "Safari on Mac")
        let none = await mac.sealed.asks()
        XCTAssertTrue(none.isEmpty) // a device that is not in the head asks nobody
        let ok = await phone.sealed.allow(mac.pub, now: now + 10)
        XCTAssertTrue(ok)
        await b.sync()
        chain = try XCTUnwrap(mac.sealed.chain(mac.account))
        XCTAssertEqual(chain.devices, [phone.pub, mac.pub])
        XCTAssertEqual(chain.rosters.map(\.lb).last, chain.rosters.first?.lb) // nobody left: the same letterbox
        XCTAssertEqual(mac.sealed.mine, .inside)
        guard case .rumor(let opened) = mac.sealed.open(wrap) else { return XCTFail("the allowed device does not open the earlier message") }
        XCTAssertEqual(opened.id, rumor.id)
        XCTAssertFalse(mac.sealed.isLocked(wrap))
        let left = await phone.sealed.asks()
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(chain.joined(mac.pub)?.from, phone.pub) // "from iPhone"
        // the phone anchored its roster right after publishing it: same root, the new head
        let newest = b.all().filter { $0.kind == 30078 && $0.tag("d") == "belfry:sealed" }.max { $0.createdAt < $1.createdAt }
        XCTAssertEqual(newest?.tag("root"), chain.root.id)
        XCTAssertEqual(newest?.tag("head"), chain.head.id)
        // each device writes its own name record, and both read both
        await mac.sealed.maintain(now: now + 20)
        await b.sync()
        XCTAssertEqual(phone.sealed.deviceNames()[mac.pub]?.name, "Safari on Mac")
        XCTAssertEqual(mac.sealed.deviceNames()[phone.pub]?.name, "Alice's iPhone")
    }

    func testAGuestSessionNeverStartsAChain() async throws {
        let b = FakeBelfry()
        let guest = try b.signIn("gus", "phone")
        guest.sealed.mayStart = false
        await guest.sealed.maintain(now: now)
        await b.sync()
        XCTAssertNil(guest.sealed.chain(guest.account))
        XCTAssertTrue(b.all().isEmpty)
        // nor does anybody when the relay gave no complete answer about the anchor
        let alice = try b.signIn("alice", "phone")
        alice.sealed.askAnchor = { nil }
        await alice.sealed.maintain(now: now)
        await b.sync()
        XCTAssertTrue(b.all().isEmpty)
        // nor when the belfry's session list does not show this device's own session
        let bob = try b.signIn("bob", "phone")
        b.lock.lock(); b.sessions[bob.account] = []; b.lock.unlock()
        await bob.sealed.maintain(now: now)
        await b.sync()
        XCTAssertTrue(b.all().isEmpty)
    }

    func testNotMeRevokesAndChangesNoRoster() async throws {
        let b = FakeBelfry()
        let phone = try b.signIn("alice", "phone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        let thief = try b.signIn("alice", "thief")
        await b.sync()
        await thief.sealed.maintain(now: now)
        await b.sync()
        let asks = await phone.sealed.asks()
        XCTAssertEqual(asks.map(\.device), [thief.pub])
        let ok = await phone.sealed.deny(thief.pub)
        XCTAssertTrue(ok)
        XCTAssertEqual(b.revoked, ["bunker-" + thief.pub])
        let after = await phone.sealed.asks()
        XCTAssertTrue(after.isEmpty)
        await phone.sealed.maintain(now: now + 5)
        await b.sync()
        XCTAssertEqual(phone.sealed.chain(phone.account)?.devices, [phone.pub])
        XCTAssertEqual(b.all().filter { $0.kind == 8560 }.count, 1)
    }

    func testARequestFromNoLiveChatSessionIsIgnored() async throws {
        let b = FakeBelfry()
        let phone = try b.signIn("alice", "phone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        // somebody publishes a request "for" Alice with a key the belfry lists no session for
        let stranger = secret("stranger")
        let e = try Sealed.request(account: phone.account, device: try Keys.publicKeyHex(secret: stranger), now: now).event(pubkey: "").signed(with: stranger)
        b.put(e)
        await b.sync()
        let asks = await phone.sealed.asks()
        XCTAssertTrue(asks.isEmpty)
    }

    func testTheLinksProofLetsADeviceInWithoutAsking() async throws {
        let b = FakeBelfry()
        let phone = try b.signIn("alice", "phone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        let link = phone.sealed.newLinkSecret(now: now)
        let pad = try b.signIn("alice", "pad", name: "iPad", link: link)
        await b.sync()
        await pad.sealed.maintain(now: now + 60)
        await b.sync()
        await phone.sealed.maintain(now: now + 61) // sees the request with the proof of its own code
        await b.sync()
        XCTAssertEqual(pad.sealed.mine, .inside)
        XCTAssertEqual(phone.sealed.chain(phone.account)?.devices, [phone.pub, pad.pub])
        // a proof of a code shown more than 15 minutes ago asks like any other
        let old = phone.sealed.newLinkSecret(now: now)
        let late = try b.signIn("alice", "late", link: old)
        await b.sync()
        await late.sealed.maintain(now: now + 1000)
        await b.sync()
        await phone.sealed.maintain(now: now + 1001)
        await b.sync()
        XCTAssertEqual(late.sealed.mine, .waiting)
        let asks = await phone.sealed.asks()
        XCTAssertEqual(asks.map(\.device), [late.pub])
    }

    func testAConversationSealsWhenBothAreReadyAndADeviceLeaving() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        let mac = try b.signIn("alice", "mac")
        let conv = "n:" + (try LocalSigner(secret: secret("bob")).pubkey)
        await alice.sealed.maintain(now: now)
        await b.sync()
        // Alice has a second chat session that is not a device yet: her chain is not ready
        XCTAssertEqual(alice.sealed.chain(alice.account)?.ready, false)
        let bob = try b.signIn("bob", "phone")
        await bob.sealed.maintain(now: now)
        await b.sync()
        XCTAssertFalse(alice.sealed.isSealed(conv, now: now)) // Bob is ready, Alice is not: today's way, no lock
        await mac.sealed.maintain(now: now)
        await b.sync()
        let ok = await alice.sealed.allow(mac.pub, now: now + 5)
        XCTAssertTrue(ok)
        await b.sync()
        XCTAssertEqual(alice.sealed.chain(alice.account)?.ready, true)
        XCTAssertTrue(alice.sealed.isSealed(conv, now: now + 6))
        XCTAssertEqual(alice.sealed.sealedSince(conv), now + 6)

        // one wrap for Bob's letterbox, one for mine; Bob opens his, both of my devices open mine
        let rumor = GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", bob.account]], content: "Hello Bob", createdAt: now + 7)
        let wraps = try alice.sealed.wraps(rumor, to: [bob.account])
        XCTAssertEqual(wraps.map { $0.tag("p") }, [bob.account, alice.account])
        XCTAssertEqual(wraps.map { $0.tag("lb") }, [bob.sealed.chain(bob.account)?.lb, alice.sealed.chain(alice.account)?.lb])
        guard case .rumor(let got) = bob.sealed.open(wraps[0]) else { return XCTFail("Bob does not open it") }
        XCTAssertEqual(got.content, "Hello Bob")
        guard case .rumor = mac.sealed.open(wraps[1]) else { return XCTFail("my other device does not open my copy") }
        guard case .keep = bob.sealed.open(wraps[1]) else { return XCTFail("Bob opened my copy") }

        // the Mac's session is gone: the phone drops it, with a new letterbox the Mac never gets
        b.lock.lock(); b.sessions[alice.account]?.removeAll { $0.clientPubkey == mac.pub }; b.lock.unlock()
        let before = try XCTUnwrap(alice.sealed.chain(alice.account)?.lb)
        await alice.sealed.maintain(now: now + 100)
        await b.sync()
        let chain = try XCTUnwrap(bob.sealed.chain(alice.account))
        XCTAssertEqual(chain.devices, [alice.pub])
        XCTAssertNotEqual(chain.lb, before)
        XCTAssertEqual(alice.sealed.notices(conv).map { "\($0.added ? "+" : "-")\($0.device == mac.pub ? "mac" : "?")" }, ["-mac"])
        // Bob now seals to the new letterbox: the phone reads, the removed Mac does not
        let reply = GiftWrap.rumor(kind: 14, pubkey: bob.account, tags: [["p", alice.account]], content: "Hi Alice", createdAt: now + 200)
        let back = try bob.sealed.wraps(reply, to: [alice.account])
        XCTAssertEqual(back[0].tag("lb"), chain.lb)
        guard case .rumor = alice.sealed.open(back[0]) else { return XCTFail("the phone does not open it") }
        guard case .keep = mac.sealed.open(back[0]) else { return XCTFail("the removed device opened a new message") }
        XCTAssertTrue(mac.sealed.isLocked(back[0]))
        // what the Mac wrote before it left still counts; what it writes after does not
        XCTAssertTrue(chain.accepts(device: mac.pub, rumorAt: now + 100))
        XCTAssertFalse(chain.accepts(device: mac.pub, rumorAt: now + 101))
    }
}
