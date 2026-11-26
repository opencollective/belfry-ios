import BelfryCore
import Foundation
import UIKit

// Format 3 (docs/encrypted.md; SPEC 19.70): the encryption engine wired to this session. The device key
// is the session's client key (already in the Keychain); nothing new is generated. A guest's session
// does not run it (§25). Writing format 3 only on a belfry whose belfry.json says so; reading always.

extension AppModel {
    func ensureEnc() {
        guard encEngine == nil, !isDemo, let e = engine else { return }
        // with format 3 seen and no engine (yet), a group write waits: never clear (the review's P1-2)
        e.encExpected = EncEngine.expected(db: e.db, config: config)
        // no engine for any guest (§25); the guest rule itself is decided per call (updateGuestSession)
        updateGuestSession(derive)
        if e.isGuestSession { return }
        guard let s = session, let d = dms, isHex64(e.me), let secret = Data(hex: s.clientSecret), secret.count == 32 else { return }
        let enc = EncEngine(engine: e, deviceSecret: secret)
        encEngine = enc
        d.enc = enc
        enc.setConfigFormat(config.encryptedFormat)
        enc.freshFormat = { [weak self] in await self?.freshEncFormat() }
        e.groupMode = { [weak enc] t in enc?.groupMode(t) ?? .hold }
        e.encFilters = { [weak enc] t in t == .main ? (enc?.mainFilters() ?? []) : (enc?.groupFilters() ?? []) }
        e.encRefuse = { [weak enc] ev in enc?.refuseClear(ev) ?? false }
        e.groupWrap = { [weak enc] t in try await enc?.wrapForGroup(t) }
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
        updateEncWorld(derive)
        e.refreshFilters()
        encNews()
        // the sessions (names, how many chat devices: §17.4) and the removed check (§16.6)
        Task { @MainActor in
            if case .success(let list) = await sessions() {
                enc.chatSessions = list.filter(\.chat).count
                for s in list { if let pk = s.clientPubkey, let n = s.device ?? (s.applicationName.isEmpty ? nil : s.applicationName) { freshDeviceNames[pk] = String(n.prefix(60)) } }
                refreshSealed()
            }
            await checkEncRemoved()
        }
    }

    /// §16.6: removed by another of my devices: signed out here (its messages deleted with the
    /// account's database), and said once on the sign-in screen (encrypted/removed-device).
    func checkEncRemoved() async {
        guard let enc = encEngine, Date().timeIntervalSince(encRemovedCheckedAt) > 600 else { return }
        encRemovedCheckedAt = Date()
        guard let r = await enc.checkRemoved() else { return }
        let by = r.by.map { "\($0) removed it" } ?? "Another of your devices removed it"
        let when = r.at > 0 ? " " + (Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(r.at))) ? "today at " + Format.time(r.at) : "on " + Format.day(r.at)) : ""
        removedNotice = "\(by)\(when). Your messages were deleted from this device. They're still on your other devices.\n\nIf that was a mistake, sign in again. Your other devices will be asked to share earlier messages."
        signOut()
    }

    /// The format to write now (the web's freshFormat): a belfry.json read in the last 5 minutes, or
    /// read again first (at most 3 s); nil when unknown or stale.
    func freshEncFormat() async -> Int? {
        if encEngine?.writes3 == true { return 3 }
        if Date().timeIntervalSince(configReadAt) < 300 { return config.encryptedFormat ?? 1 }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await self.revalidateConfig(force: true) }
            g.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            await g.next(); g.cancelAll()
        }
        if encEngine?.writes3 == true { return 3 }
        return Date().timeIntervalSince(configReadAt) < 300 ? (config.encryptedFormat ?? 1) : nil
    }

    /// The private groups, their members, the groups known and the guests, as the engine needs them:
    /// on every new snapshot (the review's P1-2: a group turning private is encrypted at once).
    /// Guest or not, as the app knows it now (the register may answer after launch): the outbox and
    /// the DM path ask per call; an engine started before a guest status arrived is stopped.
    func updateGuestSession(_ d: Derive) {
        guard let e = engine else { return }
        let guest = d.amGuest || guestReading || session?.reading == true
        e.setGuestSession(guest, privateGroups: guest ? Set(d.allGroups().filter { $0.isPod && $0.isPrivate }.map(\.id)) : [])
        if guest, encEngine != nil {
            encEngine = nil
            dms?.enc = nil
            e.encFilters = nil; e.encRefuse = nil; e.groupWrap = nil; e.groupMode = nil; e.onPublished = nil
            e.refreshFilters()
        }
    }

    func updateEncWorld(_ d: Derive) {
        guard let enc = encEngine else { return }
        var privateIds = Set<String>(), members = [String: Set<String>](), known = Set<String>()
        for g in d.allGroups() {
            if g.named || !g.metaExtra.isEmpty { known.insert(g.id) }
            if g.isPod && g.isPrivate { privateIds.insert(g.id); members[g.id] = g.members }
        }
        let guests = Set(kinds.filter { $0.value == "guest" }.map(\.key))
        // the register's answer about guests: here once asked for the keys that came by links
        let answered = whoisAnswered
        let unanswered = Set(d.guestJoinKeys.filter { kinds[$0] == nil && !answered.contains($0) && $0 != me })
        enc.setWorld(EncEngine.World(privateIds: privateIds, members: members, guests: guests, known: known, unanswered: unanswered))
        enc.setConfigFormat(config.encryptedFormat)
        enc.setPartners(dms?.threads().flatMap { MailThreads.peers($0.conv) }.filter { $0 != me && isHex64($0) } ?? [])
    }

    /// Lists, keys, messages or packs arrived: envelopes taken, private groups' messages opened into
    /// the store, direct messages processed.
    func encNews() {
        guard let enc = encEngine, let e = engine else { ensureEnc(); return }
        updateEncWorld(derive)
        let d = dms
        Task.detached { [weak self] in
            await enc.catchUp()
            enc.takeEnvelopes()
            await self?.checkEncRemoved()
            let add = enc.openGroupMessages()
            if !add.isEmpty { e.add(add, verify: false) }
            await d?.process()
            d?.retryHeld()
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
                enc.chatSessions = list.filter(\.chat).count
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
        let w = enc.listWarnings()
        st.enc3Fork = w.fork
        st.enc3Strange = w.strange > 0
        st.enc3Full = enc.listedHere() == .full
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
        if a.reader {
            // a reader is my agent (§11): its access is taken back, it has no session to end
            do { _ = try await api.setAgentReads(a.id, reads: false) } catch { return "It could not be removed. Try again." }
        } else {
            // removed only when its session really ended: no session found is a failure, said so
            guard case .success(let list) = await sessions(), let s = list.first(where: { $0.clientPubkey == a.id }) else {
                return "It could not be removed: its session wasn’t found. Try again, or remove it in Me › Devices."
            }
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
