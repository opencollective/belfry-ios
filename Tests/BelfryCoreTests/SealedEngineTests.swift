import Foundation
import XCTest
@testable import BelfryCore

// The sealed engine against a fake relay (docs/sealed.md 5 and 6): the first device, a second
// device asking and being allowed (or refused, or let in by the link's proof), a message between
// two people, a device leaving. The "relay" is a list every device publishes to and reads from;
// /api/me/sessions is a list the test edits.

private func secret(_ name: String) -> Data { Crypto.sha256("sealed-engine-test:" + name) }

/// Everything queued has left (a flush that finds another one running returns at once).
private func drain(_ engine: SyncEngine) async {
    for _ in 0..<100 {
        await engine.flush()
        if engine.outboxItems().isEmpty { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private final class FakeBelfry: @unchecked Sendable {
    let lock = NSLock()
    var events = [NostrEvent]()
    var sessions = [String: [SessionInfo]]() // account → its sessions
    var revoked = [String]()
    var devices = [Device]()
    /// Per engine: what this relay refuses from it (the reason a relay would give).
    var refusals = [ObjectIdentifier: (NostrEvent) -> String?]()

    func refuse(_ d: Device, _ rule: ((NostrEvent) -> String?)?) { lock.lock(); refusals[ObjectIdentifier(d.engine)] = rule; lock.unlock() }

    /// The relay's side of a publish: it has the event from the moment it answers OK (before the
    /// sender's outbox lets go of it), or it refuses.
    func wire(_ engine: SyncEngine) {
        engine.localRefuse = { [weak self, weak engine] e in
            guard let self, let engine else { return nil }
            self.lock.lock(); let rule = self.refusals[ObjectIdentifier(engine)]; self.lock.unlock()
            if let why = rule?(e) { return why }
            self.put(e)
            return nil
        }
        engine.onSent = { [weak self] _, e in if let e { self?.put(e) } }
    }

    func put(_ e: NostrEvent) { lock.lock(); if !events.contains(where: { $0.id == e.id }) { events.append(e) }; lock.unlock() }
    func all() -> [NostrEvent] { lock.lock(); defer { lock.unlock() }; return events }
    func list(_ account: String) -> [SessionInfo] { lock.lock(); defer { lock.unlock() }; return sessions[account] ?? [] }

    /// Everything queued goes out, and every device reads everything (a few rounds: one device's
    /// answer may be another's question).
    func sync() async {
        for _ in 0..<3 {
            for d in devices { await drain(d.engine) }
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
        sealed.followUps = []
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
        wire(engine)
        lock.lock()
        sessions[account.pubkey, default: []].append(SessionInfo(applicationName: "Belfry", device: name, redirectOrigin: "", bunkerPubkey: "bunker-" + pub,
                                                                  createdAt: "2026-11-20T10:00:00Z", lastActivity: nil, clientPubkey: pub, chat: chat))
        lock.unlock()
        let d = Device(account: account.pubkey, pub: pub, engine: engine, sealed: sealed)
        devices.append(d)
        return d
    }

    /// The same device with an empty store (nothing synced yet): no new session; it publishes to
    /// the relay and asks the belfry like any other, but `sync` does not feed it.
    func again(_ person: String, _ device: String) throws -> Device {
        let account = try LocalSigner(secret: secret(person))
        let key = secret(person + "/" + device)
        let engine = SyncEngine(config: .defaults(domain: "example.org"), db: try .memory(), signer: account, localOnly: true,
                                attachmentsDir: FileManager.default.temporaryDirectory)
        let sealed = try XCTUnwrap(SealedEngine(engine: engine, deviceSecret: key, store: MemoryKeyStore()))
        sealed.runsLocally = true
        sealed.followUps = []
        sealed.mayStart = true
        sealed.removalWait = 0...0
        sealed.askAnchor = { [weak self] in self?.all().filter { $0.kind == 30078 && $0.pubkey == account.pubkey && $0.tag("d") == SealedKind.anchorD } }
        sealed.askChains = { [weak self] who in
            self?.all().filter { e in (e.kind == 30078 && who.contains(e.pubkey) && e.tag("d") == SealedKind.anchorD) || (e.kind == 8560 && who.contains(e.tag("p") ?? "")) }
        }
        sealed.sessions = { [weak self] in self?.list(account.pubkey) }
        sealed.myName = { Sealed.DeviceName(name: "iPhone", kind: "phone", added: 1) }
        wire(engine)
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
        await drain(alice.engine)
        XCTAssertTrue(alice.engine.outboxItems().isEmpty)
        XCTAssertTrue(b.all().isEmpty) // nothing left this device
        // the relay answers, completely: neither has a chain. Now it is known: today's way.
        alice.sealed.askChains = { _ in [] }
        try await dms.send("Hello Bob", in: conv)
        XCTAssertEqual(dms.thread(conv).map(\.text), ["Hello Bob"])
        await drain(alice.engine)
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
        await drain(bob.engine)
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

    private func chainEvents(_ b: FakeBelfry) -> [NostrEvent] {
        b.all().filter { $0.kind == 8560 || ($0.kind == 30078 && $0.tag("d") == SealedKind.anchorD) }
    }

    /// In the head, but the hand-over was lost: the device asks like a new one, and a head device
    /// that holds the secret answers with the keys at once, no prompt.
    func testADeviceOfTheHeadThatLostItsKeysAsksAndIsAnswered() async throws {
        let b = FakeBelfry()
        let (phone, mac) = try await pair(b, "alice")
        let before = b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count
        // the Mac with its rosters but none of the key wraps
        let lost = try b.again("alice", "mac")
        lost.engine.add(chainEvents(b))
        XCTAssertEqual(lost.sealed.mine, .inside)
        await lost.sealed.maintain(now: now + 100)
        await drain(lost.engine)
        let asked = b.all().filter { $0.kind == 8562 && $0.pubkey == mac.pub && $0.createdAt == now + 100 }
        XCTAssertEqual(asked.count, 1)
        // the phone sees the request of a device that is in the head: no card, the keys go
        await b.sync()
        await phone.sealed.maintain(now: now + 101)
        await drain(phone.engine)
        let cards = await phone.sealed.asks()
        XCTAssertTrue(cards.isEmpty)
        let wraps = b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }
        XCTAssertGreaterThan(wraps.count, before)
        lost.engine.add(wraps)
        XCTAssertTrue(lost.sealed.takeKeys())
        // once per request: a second upkeep sends nothing more
        await phone.sealed.maintain(now: now + 102)
        await drain(phone.engine)
        XCTAssertEqual(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count, wraps.count)
        // a later request of that device, once its chat session is gone, gets nothing
        b.lock.lock(); b.sessions[phone.account]?.removeAll { $0.clientPubkey == mac.pub }; b.lock.unlock()
        let stale = try Sealed.request(account: phone.account, device: mac.pub, now: now + 200).event(pubkey: "").signed(with: secret("alice/mac"))
        phone.engine.add([stale])
        phone.sealed.removalWait = 3600...3600 // the removal that would follow is not this test's
        let task = Task { await phone.sealed.maintain(now: now + 201) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await drain(phone.engine)
        XCTAssertEqual(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count, wraps.count)
        task.cancel()
    }

    /// The session list can't be read: nothing rotates (a new letterbox whose secret went to
    /// nobody must never be published).
    func testNothingRotatesWhenTheSessionListCannotBeRead() async throws {
        let b = FakeBelfry()
        let (phone, mac) = try await pair(b, "alice")
        let rosters = b.all().filter { $0.kind == 8560 }.count
        let head = phone.sealed.chain(phone.account)?.head.id
        b.lock.lock(); b.sessions[phone.account]?.removeAll { $0.clientPubkey == mac.pub }; b.lock.unlock()
        phone.sealed.sessions = { nil }
        await phone.sealed.maintain(now: now + 100)
        await b.sync()
        XCTAssertEqual(b.all().filter { $0.kind == 8560 }.count, rosters)
        XCTAssertEqual(phone.sealed.chain(phone.account)?.head.id, head)
        // an answer that does not list this device's own session: the same
        phone.sealed.sessions = { [] }
        await phone.sealed.maintain(now: now + 101)
        await b.sync()
        XCTAssertEqual(b.all().filter { $0.kind == 8560 }.count, rosters)
    }

    private func isAnchor(_ e: NostrEvent) -> Bool { e.kind == 30078 && e.tag("d") == SealedKind.anchorD }

    /// The relay refuses the roster, the anchor, or both: Allow is not done, no key leaves, the
    /// device's own chain stays what the relay holds, and a later try starts clean.
    func testARefusedRosterOrAnchorIsNotDoneAndHandsNoKeyOver() async throws {
        for refused in ["both", "anchor", "roster"] {
            let b = FakeBelfry()
            let phone = try b.signIn("alice", "phone")
            await phone.sealed.maintain(now: now)
            await b.sync()
            let mac = try b.signIn("alice", "mac")
            await b.sync()
            await mac.sealed.maintain(now: now)
            await b.sync()
            let root = try XCTUnwrap(phone.sealed.chain(phone.account)?.head.id, refused)
            b.refuse(phone) { e in
                let roster = e.kind == 8560, anchor = e.kind == 30078 && e.tag("d") == SealedKind.anchorD
                return (roster && refused != "anchor") || (anchor && refused != "roster") ? "blocked: not today" : nil
            }
            let first = await phone.sealed.allow(mac.pub, now: now + 5)
            XCTAssertEqual(first, .failed, refused)
            await drain(phone.engine)
            // no key was handed over, and nothing of the change is left waiting to go out later
            XCTAssertTrue(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.isEmpty, refused)
            XCTAssertTrue(phone.engine.outboxItems().filter { $0.kind == 8560 || $0.kind == 30078 }.isEmpty, refused)
            // the device's own chain is what the relay holds
            let onRelay = b.all().filter { $0.kind == 8560 }.count
            XCTAssertEqual(onRelay, refused == "anchor" ? 2 : 1, refused)
            XCTAssertEqual(phone.sealed.chain(phone.account)?.rosters.count, onRelay, refused)
            // the anchor on the relay still names the head that stands (never a roster the relay refused)
            XCTAssertEqual(b.all().filter(isAnchor).max { $0.createdAt < $1.createdAt }?.tag("head"), root, refused)
            await b.sync()
            XCTAssertNotEqual(mac.sealed.open(try XCTUnwrapWrap(phone)).isRumor, true, refused)

            // the relay takes events again
            b.refuse(phone, nil)
            if refused == "anchor" {
                // the roster went out without its anchor: the next upkeep anchors it; until the
                // relay shows that, the device is still not "in" and gets no key
                await phone.sealed.maintain(now: now + 6)
                await drain(phone.engine)
                XCTAssertEqual(b.all().filter(isAnchor).max { $0.createdAt < $1.createdAt }?.tag("head"), b.all().filter { $0.kind == 8560 && $0.tag("n") == "2" }.first?.id)
            }
            let second = await phone.sealed.allow(mac.pub, now: now + 7)
            XCTAssertEqual(second, .done, refused)
            await b.sync()
            XCTAssertEqual(mac.sealed.mine, .inside, refused)
            XCTAssertFalse(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.isEmpty, refused)
            let chain = try XCTUnwrap(mac.sealed.chain(mac.account), refused)
            XCTAssertEqual(chain.devices, [phone.pub, mac.pub], refused)
            XCTAssertEqual(b.all().filter(isAnchor).max { $0.createdAt < $1.createdAt }?.tag("head"), chain.head.id, refused)
        }
    }

    /// A removal the relay refuses is not reported as done, and the device is still there.
    func testARefusedRemovalIsNotDone() async throws {
        let b = FakeBelfry()
        let (phone, mac) = try await pair(b, "alice")
        let before = try XCTUnwrap(phone.sealed.chain(phone.account))
        b.refuse(phone) { e in e.kind == 8560 ? "blocked: not today" : nil }
        let removed = await phone.sealed.remove(mac.pub, now: now + 50)
        XCTAssertFalse(removed)
        await b.sync()
        XCTAssertEqual(phone.sealed.chain(phone.account)?.devices, before.devices)
        XCTAssertEqual(b.revoked, ["bunker-" + mac.pub]) // its session is gone all the same: revoked first
        // the next upkeep drops it (its session is gone), now that the relay answers
        b.refuse(phone, nil)
        await phone.sealed.maintain(now: now + 60)
        await b.sync()
        XCTAssertEqual(phone.sealed.chain(phone.account)?.devices, [phone.pub])
    }

    /// A message sealed to my newest letterbox arrives before the roster that announces it: kept,
    /// never marked seen, and read once the roster and the key are here. A roster that merely
    /// names me (anyone can publish one) makes no letterbox mine.
    func testAWrapThatArrivesBeforeItsRosterIsKept() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        await alice.sealed.maintain(now: now)
        let (bob, bobMac) = try await pair(b, "bob")
        let pad = try b.signIn("bob", "pad")
        await b.sync()
        await pad.sealed.maintain(now: now + 6)
        await b.sync()
        let let3 = await bob.sealed.allow(pad.pub, now: now + 7)
        XCTAssertEqual(let3, .done)
        await b.sync()
        // the Mac as it was at this point: three devices, the first letterbox, its key
        let late = try b.again("bob", "mac")
        late.engine.add(b.all())
        XCTAssertTrue(late.sealed.takeKeys())
        let lateDms = DirectMessages(engine: late.engine)
        lateDms.sealed = late.sealed
        // the phone removes the pad: a new letterbox; Alice writes to it
        let removed = await bob.sealed.remove(pad.pub, now: now + 20)
        XCTAssertTrue(removed)
        await b.sync()
        let head = try XCTUnwrap(bob.sealed.chain(bob.account)?.lb)
        let aliceDms = DirectMessages(engine: alice.engine)
        aliceDms.sealed = alice.sealed
        try await aliceDms.send("After the change", in: "n:" + bob.account)
        await b.sync()
        let wrap = try XCTUnwrap(b.all().first { $0.kind == 1059 && $0.tag("lb") == head && $0.hasTag("p", bob.account) })
        // the wrap reaches the late Mac before the roster: kept, not seen
        late.engine.add([wrap])
        guard case .keep = late.sealed.open(wrap) else { return XCTFail("a wrap to my newest letterbox was dropped before its roster came") }
        await lateDms.process()
        XCTAssertTrue(lateDms.thread("n:" + alice.account).isEmpty)
        // the roster and the hand-over arrive: it is read
        late.engine.add(b.all())
        XCTAssertTrue(late.sealed.takeKeys())
        await lateDms.process()
        XCTAssertEqual(lateDms.thread("n:" + alice.account).map(\.text), ["After the change"])
        _ = bobMac

        // somebody publishes a roster "for" Bob with a letterbox of their own, and a wrap to it:
        // not Bob's letterbox, so no banner, and (Bob's chain being current) the wrap is dropped
        let fake = try Keys.publicKeyHex(secret: secret("planted-lb"))
        let planted = try RosterChain.template(account: bob.account, n: 1, prev: nil, lb: fake, devices: [try Keys.publicKeyHex(secret: secret("mallory"))], ready: false, now: now)
            .event(pubkey: "").signed(with: secret("mallory"))
        let junk = try Sealed.wrap(GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", bob.account]], content: "junk", createdAt: now),
                                   device: secret("mallory"), to: bob.account, lb: fake)
        bob.engine.add([planted, junk])
        XCTAssertFalse(bob.sealed.isLocked(junk))
        guard case .drop = bob.sealed.open(junk) else { return XCTFail("a planted roster made a letterbox mine") }
    }

    /// After a restart the wraps still queued are checked before they leave: the hook is there
    /// from the start, and the rumors were kept.
    func testQueuedWrapsAreCheckedAfterARestart() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        await alice.sealed.maintain(now: now)
        let (bob, bobMac) = try await pair(b, "bob")
        await b.sync()
        let conv = "n:" + bob.account
        XCTAssertTrue(alice.sealed.isSealed(conv, now: now + 6))
        let dms = DirectMessages(engine: alice.engine)
        dms.sealed = alice.sealed
        let rumor = GiftWrap.rumor(kind: 7, pubkey: alice.account, tags: [["e", String(repeating: "a", count: 64)], ["p", bob.account]], content: "👍", createdAt: now + 7)
        let old = try XCTUnwrap(try alice.sealed.wraps(rumor, to: [bob.account]).first)
        dms.hold(rumor)
        let item = OutboxItem(target: .main, kind: 1059, content: old.content, tags: old.tags, createdAt: old.createdAt, signed: old, dm: rumor.id)
        // "restart": a new DirectMessages on the same store; nothing was sent through it yet
        alice.engine.reseal = nil
        let again = DirectMessages(engine: alice.engine)
        again.sealed = alice.sealed
        let hook = try XCTUnwrap(alice.engine.reseal) // installed at start, not at the first send
        let removed = await bob.sealed.remove(bobMac.pub, now: now + 20)
        XCTAssertTrue(removed)
        await drain(bob.engine)
        let head = try XCTUnwrap(bob.sealed.chain(bob.account)?.lb)
        let made = try await hook(item)
        XCTAssertEqual(made?.tag("lb"), head) // a reaction too: its rumor was kept across the restart
        // a wrap that can't check its head waits by itself: the outbox goes on with the rest
        alice.sealed.askChains = { _ in nil }
        let other = OutboxItem(target: .main, kind: 1, content: "", tags: [], createdAt: old.createdAt + 1, signed: try NostrEvent(pubkey: "", createdAt: 1, kind: 1, tags: [], content: "x").signed(with: secret("x")), dm: nil)
        var sent = [String]()
        let pass = await OutboxPass.run([item, other]) { i in
            if i.localId == item.localId { do { _ = try await hook(i) } catch let e as BelfryError { return .error(e.relayMessage) } catch { return .error("timeout") } }
            sent.append(i.localId)
            return .ok(i.signed)
        }
        XCTAssertEqual(sent, [other.localId])
        XCTAssertEqual(pass.items.map(\.localId), [item.localId])
    }

    /// The key chain is neither read nor written before the account's key is known, and a chain
    /// stored for another account is never used.
    func testTheKeyStoreWaitsForItsOwner() throws {
        final class Raw: RawSecretStore, @unchecked Sendable {
            var data: Data?
            var writes = 0
            func read() -> Data? { data }
            func write(_ d: Data) -> Bool { data = d; writes += 1; return true }
            func delete() { data = nil }
        }
        let raw = Raw()
        var owner = ""
        let store = OwnedKeyStore(raw: raw, owner: { owner })
        var chain = KeyChain()
        let lb = try chain.make()
        // the account is not known yet: nothing is written, nothing is read
        store.save(chain)
        XCTAssertEqual(raw.writes, 0)
        XCTAssertTrue(store.load().isEmpty)
        // known: saved with its owner, read back
        owner = try Keys.publicKeyHex(secret: secret("alice"))
        store.save(chain)
        XCTAssertEqual(raw.writes, 1)
        XCTAssertEqual(store.load().secret(lb), chain.secret(lb))
        // a start where the key is not known yet does not lose it: no load, no save over it
        owner = ""
        XCTAssertTrue(store.load().isEmpty)
        store.save(KeyChain())
        XCTAssertEqual(raw.writes, 1)
        owner = try Keys.publicKeyHex(secret: secret("alice"))
        XCTAssertEqual(store.load().secret(lb), chain.secret(lb))
        // another account in the same slot never gets this chain
        owner = try Keys.publicKeyHex(secret: secret("bob"))
        XCTAssertTrue(store.load().isEmpty)
    }

    /// An older anchor published again (by the server, say) never makes a removed device
    /// "already allowed": the head this device holds stands, and no key goes to that device.
    func testAnOlderAnchorDoesNotBringARemovedDeviceBack() async throws {
        let b = FakeBelfry()
        let (phone, mac) = try await pair(b, "alice")
        let withMac = try XCTUnwrap(phone.sealed.chain(phone.account))
        let removed = await phone.sealed.remove(mac.pub, now: now + 50)
        XCTAssertTrue(removed)
        await b.sync()
        let head = try XCTUnwrap(phone.sealed.chain(phone.account))
        XCTAssertEqual(head.devices, [phone.pub])
        let before = b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count
        // the anchor that named the roster with the Mac, again, newer; the Mac's session back; it asks
        let old = try RosterChain.anchor(root: withMac.root.id, head: withMac.head.id, now: now + 500).event(pubkey: "").signed(with: secret("alice"))
        b.put(old)
        b.lock.lock()
        b.sessions[phone.account]?.append(SessionInfo(applicationName: "Belfry", device: "Mac", redirectOrigin: "", bunkerPubkey: "bunker-again",
                                                      createdAt: "2026-11-20T10:00:00Z", lastActivity: nil, clientPubkey: mac.pub, chat: true))
        b.lock.unlock()
        b.put(try Sealed.request(account: phone.account, device: mac.pub, now: now + 501).event(pubkey: "").signed(with: secret("alice/mac")))
        await b.sync()
        await phone.sealed.maintain(now: now + 502)
        await drain(phone.engine)
        // the head it holds stands; the request is one to ask about (a card), never answered by itself
        XCTAssertEqual(phone.sealed.chain(phone.account)?.head.id, head.head.id)
        XCTAssertEqual(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count, before)
        let cards = await phone.sealed.asks()
        XCTAssertEqual(cards.map(\.device), [mac.pub])
    }

    /// A SWITCH: the anchor leaves a head that had been seen anchored for another branch of the
    /// same root (the server holds the key that signs anchors, and here uses a removed device's
    /// sibling roster). It is followed, but shown like a fresh start to the people who write to
    /// that person, and on the person's own device a newcomer of that branch gets no key without
    /// the Allow card.
    func testASwitchOfAnchorIsShownAndAnswersNobodyWithoutAsking() async throws {
        let b = FakeBelfry()
        let (phone, mac) = try await pair(b, "alice")
        let bob = try b.signIn("bob", "phone")
        await bob.sealed.maintain(now: now)
        await b.sync()
        let conv = "n:" + phone.account
        XCTAssertTrue(bob.sealed.isSealed(conv, now: now + 6))
        let r2 = try XCTUnwrap(phone.sealed.chain(phone.account)?.head)
        // the phone removes the Mac: r3, anchored; everybody has seen it anchored
        let removed = await phone.sealed.remove(mac.pub, now: now + 50)
        XCTAssertTrue(removed)
        await b.sync()
        let r3 = try XCTUnwrap(bob.sealed.chain(phone.account)?.head)
        XCTAssertEqual(r3.devices, [phone.pub])
        XCTAssertTrue(bob.sealed.notices(conv).allSatisfy { !$0.fresh })
        // a sibling of r3, signed with the removed Mac's key on r2: the phone stays, the Mac stays,
        // a new device comes in; and an anchor for it, signed with the account's key
        let evil = secret("alice/evil")
        let evilPub = try Keys.publicKeyHex(secret: evil)
        let sibling = try RosterChain.template(account: phone.account, n: r2.n + 1, prev: r2.id, lb: r2.lb, devices: [phone.pub, mac.pub, evilPub], ready: false, now: now + 400)
            .event(pubkey: "").signed(with: secret("alice/mac"))
        b.put(sibling)
        b.put(try RosterChain.anchor(root: try XCTUnwrap(phone.sealed.chain(phone.account)?.root.id), head: sibling.id, now: now + 401).event(pubkey: "").signed(with: secret("alice")))
        b.lock.lock()
        for (d, name) in [(mac.pub, "Mac"), (evilPub, "New")] {
            b.sessions[phone.account]?.append(SessionInfo(applicationName: "Belfry", device: name, redirectOrigin: "", bunkerPubkey: "bunker-x-" + d,
                                                          createdAt: "2026-11-20T10:00:00Z", lastActivity: nil, clientPubkey: d, chat: true))
        }
        b.lock.unlock()
        b.put(try Sealed.request(account: phone.account, device: evilPub, now: now + 402).event(pubkey: "").signed(with: evil))
        await b.sync()
        // Bob follows the anchor, and it reads as a fresh start in his conversation with Alice
        XCTAssertEqual(bob.sealed.chain(phone.account)?.head.id, sibling.id)
        XCTAssertEqual(bob.sealed.notices(conv).filter(\.fresh).count, 1)
        // Alice's phone follows too; the newcomer asks for the keys: no key without the card
        let before = b.all().filter { $0.kind == 1059 && $0.hasTag("p", evilPub) }.count
        await phone.sealed.maintain(now: now + 403)
        await drain(phone.engine)
        XCTAssertEqual(phone.sealed.chain(phone.account)?.head.id, sibling.id)
        XCTAssertEqual(b.all().filter { $0.kind == 1059 && $0.hasTag("p", evilPub) }.count, before)
        // nor does the Mac the phone had removed get the key chain back by asking again
        let macBefore = b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count
        b.put(try Sealed.request(account: phone.account, device: mac.pub, now: now + 404).event(pubkey: "").signed(with: secret("alice/mac")))
        await b.sync()
        await phone.sealed.maintain(now: now + 405)
        await drain(phone.engine)
        XCTAssertEqual(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count, macBefore)
        let cards = await phone.sealed.asks()
        XCTAssertTrue(cards.map(\.device).contains(evilPub))
        XCTAssertTrue(cards.map(\.device).contains(mac.pub))
        // Not me: its session is revoked, and it still has nothing
        let refused = await phone.sealed.deny(evilPub)
        XCTAssertTrue(refused)
        XCTAssertEqual(b.all().filter { $0.kind == 1059 && $0.hasTag("p", evilPub) }.count, before)
        // its session gone, the phone's upkeep drops it by itself (a roster that removes vouches
        // for nobody): the Mac, kept by that roster, is still not trusted and still gets no key
        await phone.sealed.maintain(now: now + 500)
        await b.sync()
        let after = try XCTUnwrap(phone.sealed.chain(phone.account))
        XCTAssertEqual(Set(after.devices), [phone.pub, mac.pub])
        b.put(try Sealed.request(account: phone.account, device: mac.pub, now: now + 600).event(pubkey: "").signed(with: secret("alice/mac")))
        await b.sync()
        await phone.sealed.maintain(now: now + 601)
        await drain(phone.engine)
        XCTAssertEqual(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count, macBefore)
        // the person allows the Mac on this device: now it is trusted, and gets the keys
        let allowed = await phone.sealed.allow(mac.pub, now: now + 602)
        XCTAssertEqual(allowed, .done)
        await drain(phone.engine)
        XCTAssertGreaterThan(b.all().filter { $0.kind == 1059 && $0.hasTag("p", mac.pub) }.count, macBefore)
    }

    /// The first flush of a launch: the sealed engine is not attached yet, and a queued wrap must
    /// not leave unchecked. The hook is there from the moment Messages exists.
    func testNoQueuedWrapLeavesBeforeTheEngineIsAttached() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        alice.engine.reseal = nil
        let dms = DirectMessages(engine: alice.engine)
        dms.sealedExpected = true
        let hook = try XCTUnwrap(alice.engine.reseal) // installed by Messages itself, before any start
        let wrap = try Sealed.wrap(GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", alice.account]], content: "x", createdAt: now),
                                   device: secret("alice/phone"), to: alice.account, lb: try Keys.publicKeyHex(secret: secret("lb")))
        let item = OutboxItem(target: .main, kind: 1059, content: wrap.content, tags: wrap.tags, createdAt: wrap.createdAt, signed: wrap, dm: "rumor-id")
        do { _ = try await hook(item); XCTFail("a wrap left before the lock could be checked") } catch let e as BelfryError {
            XCTAssertTrue(e.relayMessage.hasPrefix("hold:"))
        }
        // a session that never seals (the demo, a guest reading): as before
        dms.sealedExpected = false
        let free = try await hook(item)
        XCTAssertNil(free)
        // attached: checked like any other
        dms.sealedExpected = true
        dms.sealed = alice.sealed
        await alice.sealed.maintain(now: now)
        _ = try await hook(item)
    }

    /// "Not sealed" goes by the message's date against the time this device first saw the
    /// conversation sealed, never by when it arrived: history read later is history.
    func testOldStyleHistoryIsNotMarkedByArrival() async throws {
        let b = FakeBelfry()
        let alice = try b.signIn("alice", "phone")
        await alice.sealed.maintain(now: now)
        let (bob, _) = try await pair(b, "bob")
        await b.sync()
        let aliceDms = DirectMessages(engine: alice.engine)
        aliceDms.sealed = alice.sealed
        let bobDms = DirectMessages(engine: bob.engine)
        bobDms.sealed = bob.sealed
        try await aliceDms.send("Sealed now", in: "n:" + bob.account)
        await b.sync()
        await bobDms.process()
        let conv = "n:" + alice.account
        let since = try XCTUnwrap(bob.sealed.sealedSince(conv))
        let first = try XCTUnwrap(bobDms.thread(conv).first)
        // history from before the conversation sealed arrives only now: a message and a reaction
        let key = try LocalSigner(secret: secret("alice"))
        let before = GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", bob.account]], content: "Long ago", createdAt: since - 86400)
        let liked = GiftWrap.rumor(kind: 7, pubkey: alice.account, tags: [["e", first.rid], ["p", bob.account]], content: "👍", createdAt: since - 10)
        // and two dated after it sealed
        let after = GiftWrap.rumor(kind: 14, pubkey: alice.account, tags: [["p", bob.account]], content: "Old app", createdAt: since + 60)
        let late = GiftWrap.rumor(kind: 7, pubkey: alice.account, tags: [["e", first.rid], ["p", bob.account]], content: "🔥", createdAt: since + 61)
        for r in [before, liked, after, late] { bob.engine.add([try await GiftWrap.wrap(r, to: bob.account, signer: key)], verify: false) }
        await bobDms.process()
        let thread = bobDms.thread(conv)
        XCTAssertNil(thread.first { $0.text == "Long ago" }?.unsealed)
        XCTAssertEqual(thread.first { $0.text == "Old app" }?.unsealed, true)
        XCTAssertEqual(bobDms.chips(first.rid).map(\.emoji), ["👍"])
    }

    /// The relay caps a page at 300 whatever is asked: a short page proves nothing; only an empty
    /// one ends the reading.
    func testPagingAgainstARelayThatCapsThePage() async {
        let all = (0..<1000).map { i in NostrEvent(id: "e\(i)", pubkey: "", createdAt: 5000 - i / 3, kind: 1, tags: [], content: "") } // three per second
        var got = [String: NostrEvent]()
        var asked = 0
        let ok = await SyncEngine.pageAll(limit: 500, from: 9999, ask: { until, limit in
            asked += 1
            return Array(all.filter { $0.createdAt <= until }.prefix(min(limit, 300)))
        }, take: { page in
            let fresh = page.filter { got[$0.id] == nil }
            for e in page { got[e.id] = e }
            return fresh.count
        })
        XCTAssertTrue(ok)
        XCTAssertEqual(got.count, 1000)
        XCTAssertGreaterThan(asked, 3)
        // a page that does not come: nothing is known for sure
        let failed = await SyncEngine.pageAll(from: 9999, ask: { _, _ in nil }, take: { $0.count })
        XCTAssertFalse(failed)
        // many events in one second (more than a page): stepped over, never a loop
        let same = (0..<700).map { i in NostrEvent(id: "s\(i)", pubkey: "", createdAt: 100, kind: 1, tags: [], content: "") }
        var seen = Set<String>()
        var rounds = 0
        _ = await SyncEngine.pageAll(from: 9999, ask: { until, limit in
            rounds += 1
            return Array(same.filter { $0.createdAt <= until }.prefix(min(limit, 300)))
        }, take: { page in
            let n = page.filter { seen.insert($0.id).inserted }.count
            return n
        })
        XCTAssertLessThan(rounds, 10)
    }
}

private extension SealedEngine.Outcome {
    var isRumor: Bool { if case .rumor = self { return true }; return false }
}

/// A sealed note to self of DEVICE's account (to try on another of its devices).
private func XCTUnwrapWrap(_ d: FakeBelfry.Device) throws -> NostrEvent {
    let rumor = GiftWrap.rumor(kind: 14, pubkey: d.account, tags: [["p", d.account]], content: "note", createdAt: 1795176000)
    return try XCTUnwrap(try d.sealed.wraps(rumor, to: []).first)
}
