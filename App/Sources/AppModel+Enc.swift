import BelfryCore
import Foundation

// Format 3 (docs/encrypted.md; SPEC 19.70): the encryption engine wired to this session. The device key
// is the session's client key (already in the Keychain); nothing new is generated. A guest's session
// does not run it (§25). Writing format 3 only on a belfry whose belfry.json says so; reading always.

extension AppModel {
    func ensureEnc() {
        guard encEngine == nil, !isDemo, let s = session, s.reading != true, let e = engine, let d = dms, isHex64(e.me),
              let secret = Data(hex: s.clientSecret), secret.count == 32 else { return }
        let enc = EncEngine(engine: e, deviceSecret: secret)
        encEngine = enc
        d.enc = enc
        let me = e.me
        e.encFilters = { [weak enc] t in t == .main ? (enc?.mainFilters() ?? []) : (enc?.groupFilters() ?? []) }
        e.encRefuse = { [weak enc] ev in enc?.refuseClear(ev) ?? false }
        e.groupWrap = { [weak enc] t in try await enc?.wrapForGroup(t) }
        e.groupEncryptsFiles = { [weak enc] h, kind in
            guard let enc else { return false }
            return enc.groupEncrypts(h) && !enc.clearInGroup(kind: kind, pubkey: me, tags: [])
        }
        e.groupBeforeOut = { [weak enc] K in enc?.groupBeforeOut(K) }
        e.onPublished = { [weak enc] ev in enc?.confirmed(ev.id) }
        // after the switch no version-1 roster, anchor, request or hand-over is written (§12)
        sealedEngine?.writesStopped = { [weak enc] in enc?.writes3 ?? false }
        // version-1 secrets go in the key packs this device shares, and are taken from those it gets
        enc.v1Provider = { [weak self] in self?.sealedEngine?.v1Secrets() ?? [] }
        enc.onV1Secrets = { [weak self] list in Task { @MainActor in self?.sealedEngine?.takeV1Secrets(list) } }
        enc.onKeys = { [weak d, weak self] in
            Task { await d?.process() }
            Task { @MainActor in self?.version += 1 }
        }
        updateEncWorld()
        e.refreshFilters()
        encNews()
    }

    /// The private groups, their members and the guests, as the engine needs them (on every change).
    func updateEncWorld() {
        guard let enc = encEngine else { return }
        let d = derive
        var privateIds = Set<String>(), members = [String: Set<String>]()
        for g in d.allGroups() where g.isPod && g.isPrivate { privateIds.insert(g.id); members[g.id] = g.members }
        let guests = Set(kinds.filter { $0.value == "guest" }.map(\.key))
        enc.setWorld(EncEngine.World(privateIds: privateIds, members: members, guests: guests))
        enc.setPartners(dms?.threads().flatMap { MailThreads.peers($0.conv) }.filter { $0 != me && isHex64($0) } ?? [])
    }

    /// Lists, keys, messages or packs arrived: envelopes taken, private groups' messages opened into
    /// the store, direct messages processed.
    func encNews() {
        guard let enc = encEngine, let e = engine else { ensureEnc(); return }
        updateEncWorld()
        let d = dms
        Task.detached {
            enc.takeEnvelopes()
            let add = enc.openGroupMessages()
            if !add.isEmpty { e.add(add, verify: false) }
            await d?.process()
        }
    }
}
