import BelfryCore
import Foundation
import UIKit

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
            Task { @MainActor in self?.version += 1; self?.refreshSealed() }
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
        Task.detached { [weak self] in
            enc.takeEnvelopes()
            let add = enc.openGroupMessages()
            if !add.isEmpty { e.add(add, verify: false) }
            await d?.process()
            await MainActor.run { self?.refreshSealed() }
        }
    }
}

// ---- the screens' state (Encrypted canvas) ----------------------------------------------------------

extension AppModel {
    /// SealedState from the format-3 engine: my devices by name (the belfry's session list), the
    /// encrypted conversations with a count of devices per other person, the card, the Ask line.
    func refreshEnc3(_ enc: EncEngine) {
        guard let dms else { return }
        var st = SealedState()
        st.format3 = true
        st.dismissed = sealed.dismissed
        func name(_ d: String) -> String? { freshDeviceNames[d] }
        func kind(_ n: String?) -> DeviceKind {
            guard let n = n?.lowercased() else { return .computer }
            if n.contains("ipad") || n.contains("tablet") { return .tablet }
            if n.contains("iphone") || n.contains("android") || n.contains("phone") { return .phone }
            return .computer
        }
        let mine = enc.devicesOf(me)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        st.myDevices = (mine?.devices ?? []).map { d in
            let this = d == enc.devicePub
            let n = this ? (name(d) ?? (pad ? "iPad" : "iPhone")) : (name(d) ?? "A device")
            return MyDevice(id: d, name: n, kind: this ? (pad ? .tablet : .phone) : kind(name(d)), added: mine?.since[d] ?? 0, this: this)
        }
        st.otherDevices = st.myDevices.filter { !$0.this }.map(\.name)
        let unnamed = (mine?.devices ?? []) + enc.addedDevices().map(\.device)
        if unnamed.contains(where: { name($0) == nil && !freshNameAsked.contains($0) }) {
            for d in unnamed { freshNameAsked.insert(d) }
            Task { @MainActor in
                guard case .success(let list) = await sessions() else { return }
                for s in list {
                    guard let pk = s.clientPubkey else { continue }
                    let n = s.device ?? (s.applicationName.isEmpty ? nil : s.applicationName)
                    if let n, !n.isEmpty { freshDeviceNames[pk] = String(n.prefix(60)) }
                }
                refreshSealed()
            }
        }
        st.enc3Added = enc.addedDevices().map { a in
            Enc3Added(id: a.device, name: name(a.device) ?? (a.reader ? "Your agent" : "A new device"), kind: kind(name(a.device)), at: a.at, reader: a.reader, ask: a.ask)
        }
        st.earlier = st.otherDevices.isEmpty ? 0 : enc.unresolvedCount()
        st.enc3Asked = enc.askedAt ?? 0
        let notes = Notes.conv(me)
        st.convs[notes] = SealedConv(others: [])
        let se = sealedEngine
        for t in dms.threads() where t.conv != notes {
            let conv = t.conv
            if MailThreads.isMail(conv) {
                st.convs[conv] = SealedConv(others: [SealedPerson(id: conv, mailName: convName(self, conv))])
                continue
            }
            let peers = MailThreads.peers(conv).filter { $0 != me }
            guard enc.isEncrypted(peers + [me]) || se?.isSealed(conv) == true else { continue }
            st.convs[conv] = SealedConv(since: enc.firstKeyAt(peers + [me]),
                                        others: peers.map { SealedPerson(id: $0, devices: enc.devicesOf($0)?.devices.count ?? 0) })
        }
        if st != sealed { sealed = st }
    }

    /// The device's card: Share (every key this device holds, in packs, then the answer).
    func enc3Share(_ a: Enc3Added) async -> String? {
        if isDemo { try? await Task.sleep(nanoseconds: 900_000_000); sealed.enc3Added.removeAll { $0.id == a.id }; showToast("Earlier messages shared with \(a.name)"); return nil }
        guard let enc = encEngine, let d = enc.addedDevices().first(where: { $0.device == a.id }) else { return "It could not be shared. Try again." }
        do { try await enc.share(with: d) } catch { return "It could not be shared. Try again." }
        showToast("Earlier messages shared with \(a.name)")
        refreshSealed()
        return nil
    }

    /// Remove this device: its session ended at once (the belfry), then the answer for my other devices.
    func enc3Remove(_ a: Enc3Added) async -> String? {
        if isDemo { sealed.enc3Added.removeAll { $0.id == a.id }; showToast("\(a.name) was removed"); return nil }
        guard let enc = encEngine, let d = enc.addedDevices().first(where: { $0.device == a.id }) else { return "It could not be removed. Try again." }
        guard case .success(let list) = await sessions(), let api else { return "It could not be removed. Try again." }
        if let s = list.first(where: { $0.clientPubkey == a.id }) {
            do { try await api.revokeSession(s.bunkerPubkey) } catch { return "It could not be removed. Try again." }
        }
        do { try enc.answer(d, "removed") } catch { return "It could not be removed. Try again." }
        showToast("\(a.name) was removed")
        refreshSealed()
        return nil
    }

    /// A reader (my agent) seen: the card goes on this device only.
    func enc3Ok(_ a: Enc3Added) {
        sealed.enc3Added.removeAll { $0.id == a.id }
        encEngine?.dismiss(a.id)
    }

    /// "Ask for them": once for every conversation.
    func enc3Ask() async {
        if isDemo { sealed.enc3Asked = Int.now; return }
        _ = try? encEngine?.askForEarlier()
        refreshSealed()
    }
}
