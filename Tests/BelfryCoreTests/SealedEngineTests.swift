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
        // a complete answer of the relay about these people's anchors and rosters
        sealed.askChains = { [weak self] who in
            self?.all().filter { e in (e.kind == 30078 && who.contains(e.pubkey) && e.tag("d") == SealedKind.anchorD) || (e.kind == 8560 && who.contains(e.tag("p") ?? "")) }
        }
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

    /// The same device with an empty store (nothing synced yet): no new session.
    func again(_ person: String, _ device: String) throws -> Device {
        let account = try LocalSigner(secret: secret(person))
        let key = secret(person + "/" + device)
        let engine = SyncEngine(config: .defaults(domain: "example.org"), db: try .memory(), signer: account, localOnly: true,
                                attachmentsDir: FileManager.default.temporaryDirectory)
        let sealed = try XCTUnwrap(SealedEngine(engine: engine, deviceSecret: key, store: MemoryKeyStore()))
        sealed.runsLocally = true
        return Device(account: account.pubkey, pub: try Keys.publicKeyHex(secret: key), engine: engine, sealed: sealed)
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
        XCTAssertEqual(ok, .done)
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

    /// A device with nothing loaded and a silent relay cannot tell whether the conversation is
    /// sealed: the send is refused and nothing is queued; the old way needs a complete answer.
    func testNothingGoesTheOldWayOnSilence() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        let bob = try LocalSigner(secret: secret("bob")).pubkey
        let conv = "n:" + bob
        let dms = DirectMessages(engine: alice.engine)
        dms.sealed = alice.sealed
        // the relay does not answer
        alice.sealed.askChains = { _ in nil }
        XCTAssertEqual(alice.sealed.way(conv, now: now), .unknown)
        do {
            try await dms.send("Hello Bob", in: conv)
            XCTFail("sent on silence")
        } catch {}
        XCTAssertTrue(dms.thread(conv).isEmpty)
        await alice.engine.flush()
        XCTAssertTrue(alice.engine.outboxItems().isEmpty)
        XCTAssertTrue(b.all().isEmpty) // nothing left this device
        // the relay answers, completely: neither has a chain. Now it is known: today's way.
        alice.sealed.askChains = { _ in [] }
        try await dms.send("Hello Bob", in: conv)
        XCTAssertEqual(dms.thread(conv).map(\.text), ["Hello Bob"])
        await alice.engine.flush()
        let out = b.all()
        XCTAssertEqual(out.count, 2) // one wrap for Bob, one for me
        XCTAssertTrue(out.allSatisfy { $0.kind == 1059 && $0.tag("lb") == nil })
        // an answer older than 10 minutes is no knowledge any more
        XCTAssertEqual(alice.sealed.way(conv, now: Int.now + 601), .unknown)
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
        XCTAssertEqual(ok, .done)
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
        // my copy is sealed to my letterbox, which is none of Bob's: on his device it is dropped
        guard case .drop = bob.sealed.open(wraps[1]) else { return XCTFail("Bob kept or opened my copy") }

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

    /// Two devices in, by the ordinary path.
    private func pair(_ b: FakeBelfry, _ person: String) async throws -> (FakeBelfry.Device, FakeBelfry.Device) {
        let phone = try b.signIn(person, "phone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        let mac = try b.signIn(person, "mac")
        await b.sync()
        await mac.sealed.maintain(now: now)
        await b.sync()
        let ok = await phone.sealed.allow(mac.pub, now: now + 5)
        XCTAssertEqual(ok, .done)
        await b.sync()
        return (phone, mac)
    }

    func testRemoveRevokesFirstAndChangesNothingWhenThatFails() async throws {
        let b = FakeBelfry()
        let (phone, mac) = try await pair(b, "alice")
        let before = try XCTUnwrap(phone.sealed.chain(phone.account))
        // the belfry does not revoke: nothing changes, and it is not reported as removed
        let revoke = phone.sealed.revoke
        phone.sealed.revoke = { _ in false }
        let refused = await phone.sealed.remove(mac.pub, now: now + 50)
        XCTAssertFalse(refused)
        await b.sync()
        XCTAssertEqual(phone.sealed.chain(phone.account)?.head.id, before.head.id)
        // the session list cannot be read: the same
        let sessions = phone.sealed.sessions
        phone.sealed.sessions = { nil }
        let blind = await phone.sealed.remove(mac.pub, now: now + 51)
        XCTAssertFalse(blind)
        XCTAssertEqual(phone.sealed.chain(phone.account)?.head.id, before.head.id)
        // it works: the session is revoked, then the roster drops the device with a new letterbox
        phone.sealed.revoke = revoke
        phone.sealed.sessions = sessions
        let done = await phone.sealed.remove(mac.pub, now: now + 60)
        XCTAssertTrue(done)
        XCTAssertEqual(b.revoked, ["bunker-" + mac.pub])
        await b.sync()
        let after = try XCTUnwrap(phone.sealed.chain(phone.account))
        XCTAssertEqual(after.devices, [phone.pub])
        XCTAssertNotEqual(after.lb, before.lb)
        XCTAssertEqual(phone.sealed.mine, .inside)
        XCTAssertEqual(mac.sealed.mine, .waiting)
        // this device can't remove itself here
        let me = await phone.sealed.remove(phone.pub, now: now + 70)
        XCTAssertFalse(me)
    }

    func testNoFreshStartIsMadeByItself() async throws {
        let b = FakeBelfry()
        let phone = try b.signIn("alice", "phone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        // the phone's session is gone; a new device signs in and finds no head device live
        b.lock.lock(); b.sessions[phone.account]?.removeAll { $0.clientPubkey == phone.pub }; b.lock.unlock()
        let mac = try b.signIn("alice", "mac")
        await b.sync()
        await mac.sealed.maintain(now: now + 10)
        await b.sync()
        // it asks and stays locked: no new root, the anchor untouched
        XCTAssertEqual(mac.sealed.mine, .waiting)
        XCTAssertEqual(b.all().filter { $0.kind == 8560 }.count, 1)
        XCTAssertEqual(b.all().filter { $0.kind == 30078 && $0.tag("d") == "belfry:sealed" }.count, 1)
        XCTAssertEqual(b.all().filter { $0.kind == 8562 && $0.pubkey == mac.pub }.count, 1)
    }

    func testAllowRefusesTheTwentyFirstDeviceBeforeAnyKeyLeaves() async throws {
        let b = FakeBelfry()
        let phone = try b.signIn("alice", "phone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        for i in 1..<20 {
            let d = try b.signIn("alice", "d\(i)")
            await b.sync()
            await d.sealed.maintain(now: now + i)
            await b.sync()
            let ok = await phone.sealed.allow(d.pub, now: now + i)
            XCTAssertEqual(ok, .done, "device \(i)")
            await b.sync()
        }
        XCTAssertEqual(phone.sealed.chain(phone.account)?.devices.count, 20)
        XCTAssertTrue(phone.sealed.full)
        let extra = try b.signIn("alice", "one-too-many")
        await b.sync()
        await extra.sealed.maintain(now: now + 30)
        await b.sync()
        let answer = await phone.sealed.allow(extra.pub, now: now + 31)
        XCTAssertEqual(answer, .full)
        await b.sync()
        XCTAssertEqual(phone.sealed.chain(phone.account)?.devices.count, 20)
        XCTAssertTrue(b.all().filter { $0.kind == 1059 && $0.hasTag("p", extra.pub) }.isEmpty) // no key was handed over
        XCTAssertEqual(extra.sealed.mine, .waiting)
    }

    func testAllowIsNotDoneWhenTheRelayDidNotTakeIt() async throws {
        let b = FakeBelfry()
        let phone = try b.signIn("alice", "phone")
        await phone.sealed.maintain(now: now)
        await b.sync()
        let mac = try b.signIn("alice", "mac")
        await b.sync()
        await mac.sealed.maintain(now: now)
        await b.sync()
        // the relay gives no complete answer after the change: it is not reported as done
        let ask = phone.sealed.askChains
        phone.sealed.askChains = { _ in nil }
        let first = await phone.sealed.allow(mac.pub, now: now + 5)
        XCTAssertEqual(first, .failed)
        // a session that is gone meanwhile (another device said Not me) gets nothing
        phone.sealed.askChains = ask
        let gone = try b.signIn("alice", "gone")
        await b.sync()
        await gone.sealed.maintain(now: now + 6)
        await b.sync()
        b.lock.lock(); b.sessions[phone.account]?.removeAll { $0.clientPubkey == gone.pub }; b.lock.unlock()
        let refused = await phone.sealed.allow(gone.pub, now: now + 7)
        XCTAssertEqual(refused, .failed)
        XCTAssertTrue(b.all().filter { $0.kind == 1059 && $0.hasTag("p", gone.pub) }.isEmpty)
        // tried again with the relay answering: done, and the keys follow
        let second = await phone.sealed.allow(mac.pub, now: now + 8)
        XCTAssertEqual(second, .done)
        await b.sync()
        XCTAssertEqual(mac.sealed.mine, .inside)
        XCTAssertFalse(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.isEmpty)
    }

    func testAHandoverThatArrivesBeforeTheRostersIsKeptAndTaken() async throws {
        let b = FakeBelfry()
        let (phone, mac) = try await pair(b, "alice")
        // the Mac again with an empty store: the key wraps come first, its rosters later
        let late = try b.again("alice", "mac")
        let wraps = b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }
        XCTAssertFalse(wraps.isEmpty)
        late.engine.add(wraps)
        XCTAssertFalse(late.sealed.takeKeys()) // the giver is in no roster known here yet: not taken, not dropped
        late.engine.add(b.all())
        XCTAssertTrue(late.sealed.takeKeys())
        XCTAssertEqual(late.sealed.mine, .inside)
        let rumor = GiftWrap.rumor(kind: 14, pubkey: phone.account, tags: [["p", phone.account]], content: "note", createdAt: now + 9)
        let wrap = try XCTUnwrap(try phone.sealed.wraps(rumor, to: []).first)
        guard case .rumor = late.sealed.open(wrap) else { return XCTFail("the keys were not taken") }
    }

    func testMessagesOpenOnTheDeviceAndOnlyMyOwnLockedWrapsCount() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        await alice.sealed.maintain(now: now)
        let (bob, _) = try await pair(b, "bob")
        await b.sync()
        let conv = "n:" + bob.account
        let aliceDms = DirectMessages(engine: alice.engine)
        aliceDms.sealed = alice.sealed
        let bobDms = DirectMessages(engine: bob.engine)
        bobDms.sealed = bob.sealed
        try await aliceDms.send("Hello Bob", in: conv)
        await b.sync()
        let sent = b.all().filter { $0.kind == 1059 && $0.tag("lb") != nil && $0.hasTag("p", bob.account) }
        XCTAssertEqual(sent.count, 1) // sealed, never the old way
        XCTAssertTrue(b.all().filter { $0.kind == 1059 && $0.tag("lb") == nil && $0.hasTag("p", bob.account) }.isEmpty)
        await bobDms.process()
        let got = bobDms.thread("n:" + alice.account)
        XCTAssertEqual(got.map(\.text), ["Hello Bob"])
        XCTAssertNotNil(got.first?.rumor)
        XCTAssertNil(got.first?.unsealed)
        XCTAssertEqual(bobDms.lockedWraps, 0)
        XCTAssertTrue(bob.sealed.isSealed("n:" + alice.account)) // accepting a sealed message seals it here

        // a third device of Bob's that nobody allowed: it reads nothing, and the banner counts the wrap
        let pad = try b.signIn("bob", "pad")
        await b.sync()
        let padDms = DirectMessages(engine: pad.engine)
        padDms.sealed = pad.sealed
        await padDms.process()
        XCTAssertTrue(padDms.thread("n:" + alice.account).isEmpty)
        XCTAssertEqual(padDms.lockedWraps, 1)

        // a wrap anybody made for Bob with a letterbox that is nobody's: dropped, never a lock
        let junk = try Sealed.wrap(GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", bob.account]], content: "junk", createdAt: now),
                                   device: secret("mallory"), to: bob.account, lb: try Keys.publicKeyHex(secret: secret("nobody")))
        bob.engine.add([junk]); pad.engine.add([junk])
        await bobDms.process(); await padDms.process()
        XCTAssertEqual(bobDms.lockedWraps, 0)
        XCTAssertEqual(padDms.lockedWraps, 1)
        guard case .drop = bob.sealed.open(junk) else { return XCTFail("a wrap to nobody's letterbox was kept") }

        // the old way, with a sealed message's id claimed inside: it never takes that message's place
        let aliceKey = try LocalSigner(secret: secret("alice"))
        var forged = GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", bob.account]], content: "Changed", createdAt: Int.now + 60)
        forged.id = try XCTUnwrap(got.first?.rid)
        bob.engine.add([try await GiftWrap.wrap(forged, to: bob.account, signer: aliceKey)], verify: false)
        await bobDms.process()
        let after = bobDms.thread("n:" + alice.account)
        XCTAssertEqual(after.first { $0.rid == got.first?.rid }?.text, "Hello Bob")
        XCTAssertEqual(after.first { $0.text == "Changed" }?.unsealed, true) // shown apart, marked "Not sealed"
        // an old-style reaction there is ignored
        let reaction = GiftWrap.rumor(kind: 7, pubkey: alice.account, tags: [["e", got[0].rid], ["p", bob.account]], content: "👍", createdAt: Int.now + 61)
        bob.engine.add([try await GiftWrap.wrap(reaction, to: bob.account, signer: aliceKey)], verify: false)
        await bobDms.process()
        XCTAssertTrue(bobDms.chips(got[0].rid).isEmpty)
    }

    func testAQueuedWrapIsSealedAgainForTheHeadTheRelayHasNow() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        await alice.sealed.maintain(now: now)
        let (bob, bobMac) = try await pair(b, "bob")
        await b.sync()
        let conv = "n:" + bob.account
        XCTAssertTrue(alice.sealed.isSealed(conv, now: now + 6))
        let dms = DirectMessages(engine: alice.engine)
        dms.sealed = alice.sealed
        let rumor = GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", bob.account]], content: "Hello", createdAt: now + 7)
        let old = try XCTUnwrap(try alice.sealed.wraps(rumor, to: [bob.account]).first)
        dms.hold(rumor)
        let item = OutboxItem(target: .main, kind: 1059, content: old.content, tags: old.tags, createdAt: old.createdAt, signed: old, dm: rumor.id)
        // nothing changed: it goes as it is
        let same = try await dms.reseal(item)
        XCTAssertNil(same)
        // Bob removes his Mac; Alice's device has not heard of it (only the relay has)
        let removed = await bob.sealed.remove(bobMac.pub, now: now + 20)
        XCTAssertTrue(removed)
        await bob.engine.flush()
        let head = try XCTUnwrap(bob.sealed.chain(bob.account)?.lb)
        XCTAssertNotEqual(old.tag("lb"), head)
        XCTAssertEqual(alice.sealed.chain(bob.account)?.lb, old.tag("lb")) // stale here
        // before it leaves, the relay is asked: sealed again to the letterbox Bob has now
        let made = try await dms.reseal(item)
        let again = try XCTUnwrap(made)
        XCTAssertEqual(again.tag("lb"), head)
        guard case .rumor(let r) = bob.sealed.open(again) else { return XCTFail("Bob does not open the new wrap") }
        XCTAssertEqual(r.id, rumor.id)
        bobMac.engine.add(b.all()) // it learns it was dropped; it has no key for the new letterbox
        guard case .keep = bobMac.sealed.open(again) else { return XCTFail("the removed device opened it") }
        // the relay does not answer: the wrap waits (an error that is tried again), it never goes stale
        alice.sealed.askChains = { _ in nil }
        do { _ = try await dms.reseal(item); XCTFail("sent without checking the head") } catch {}
    }
}
