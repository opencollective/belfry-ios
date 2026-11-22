import BelfryCore
import Foundation
import UIKit

// End-to-end encrypted conversations (boards messages/encryption-*, approved 2026-11-20): what
// the screens show. SCREENS ONLY: this state is filled by the demo and by nothing else. No key,
// no crypto and no wire format here until the lead's contract (collective-belfry docs/sealed.md
// and its vectors) arrives; outside the demo no conversation is sealed, so no lock shows.

enum DeviceKind: String, Hashable {
    case phone, tablet, computer

    var icon: String { self == .phone ? "iphone" : self == .tablet ? "ipad" : "laptopcomputer" }

    /// From a device's own name ("iPhone", "iPad", "Pixel 8", "Chrome on Windows").
    static func of(_ name: String) -> DeviceKind {
        let n = name.lowercased()
        if n.contains("ipad") || n.contains("tablet") { return .tablet }
        if n.contains("iphone") || n.contains("pixel") || n.contains("phone") || n.contains("android") || n.contains("galaxy") { return .phone }
        return .computer
    }
}

/// One of MY devices: the only ones ever named.
struct MyDevice: Identifiable, Hashable {
    let id: String
    var name: String
    var kind: DeviceKind
    var added: Int
    /// The device that let it in ("from iPhone").
    var from: String?
    var this = false
}

/// Another person of a conversation: how many devices, never which.
struct SealedPerson: Identifiable, Hashable {
    /// Their key; for an e-mail correspondent, the conversation.
    let id: String
    /// "Town Hall": someone who writes by e-mail and is not on this belfry (no count).
    var mailName: String?
    var devices = 0
    /// The last change of their devices (shown for 30 days).
    var changeAdded = true
    var changeAt: Int?
}

/// A line in the conversation, in the style of a channel's join line.
struct DeviceNotice: Identifiable, Hashable {
    enum What: Hashable { case added, removed, locked }
    let id: String
    var at: Int
    var who: String
    var what: What
    /// The device's name: only on my own lines.
    var device: String?
    /// Known for my own devices and in the demo; never told about someone else's.
    var kind: DeviceKind?
}

struct SealedConv: Hashable {
    /// When the conversation became sealed: what was written before reads on any device.
    var since: Int?
    var others: [SealedPerson]
    var notices: [DeviceNotice] = []
}

/// "Give your new device … access?", asked on my other devices.
struct AllowAsk: Identifiable, Hashable {
    let id: String
    var device: String
    var kind: DeviceKind
    var at: Int
}

/// "‹device› was added just now · Not you? Remove it" (sealed.md 5.2 step 2a).
struct AddedNotice: Identifiable, Hashable {
    let id: String          // the device
    var name: String
    var kind: DeviceKind
    var at: Int
}

struct SealedState: Equatable {
    var myDevices: [MyDevice] = []
    /// Devices added to my devices without a prompt here: each until I answer or it is removed.
    var added: [AddedNotice] = []
    /// The sealed conversations (a conversation that is not in here shows no lock).
    var convs: [String: SealedConv] = [:]
    /// This device is not in my head (a new device nobody allowed yet): it reads no sealed
    /// message, old or new; messages from before a conversation was sealed stay readable. ONLY
    /// this hides messages or the composer.
    var notAllowed = false
    /// It holds a wrap for one of my own letterboxes that it has no key for: the banner, nothing else.
    var missingKeys = false
    /// How many messages wait here for a key (wraps to my own letterboxes this device can't open).
    var waitingCount = 0
    /// Messages kept for a letterbox this device does not know yet (my devices are still being
    /// read from the relay): "Checking your devices…".
    var checkingCount = 0
    /// When this device last asked to be allowed (0: not yet).
    var askedAt = 0
    /// When this device was added to my devices (0: not, or not known): "Added 9:42 PM · …".
    var addedAt = 0
    /// The devices that can let this one in (my head's devices), by their session names.
    var unlockers: [String] = []
    /// Diagnostics: why this device did or did not ask to be allowed (each step of the last pass).
    var upkeepLines: [String] = []
    /// In my head, the key not here yet: sealed conversations show "Waiting for another of your
    /// devices" in place of the composer.
    var waitingForKey = false
    /// It has waited more than a day: "None of your other devices has answered."
    var waitingLong = false
    var ask: AllowAsk?
    /// Asks the user closed without an answer (20 devices already): not shown again in this run.
    var dismissed: Set<String> = []
    /// "Devices" on the Allow card: Me → Devices is pushed.
    var openDevices = false
    /// Demo: devices removed in Devices.
    var removed: Set<String> = []
    /// Another device started my sealed conversations fresh while this one was in the head
    /// (board messages/encryption-fresh-elsewhere): its name (from the session list) and when.
    var freshElsewhere: FreshElsewhere?
    /// After "Sign out every other device" went through: the names signed out (the done card).
    var signedOutOthers: [String]?
}

struct FreshElsewhere: Equatable {
    /// Its name from the session list; nil when no session names it ("a new device", no quotes).
    var device: String?
    var at: Int
}

/// The letterbox secrets of one account on this device: one Keychain item per account slot,
/// this device only, never synchronised, in the app's own access group (not the one shared with
/// the notification extension); never in the database, never logged; gone on sign-out. The owner
/// check is `OwnedKeyStore`'s (core, tested).
final class KeychainSecret: RawSecretStore, @unchecked Sendable {
    private let name: String
    init(slot: String) { name = slot.isEmpty ? "sealed-keys" : "sealed-keys@" + slot }

    /// The app's own group ($(AppIdentifierPrefix)sh.belfry.app); nil on an unsigned build.
    static let group: String? = (Bundle.main.object(forInfoDictionaryKey: "BelfryPrivateKeychainGroup") as? String).flatMap { $0.isEmpty || $0.hasPrefix("sh.") ? nil : $0 }

    private var base: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Keychain.service + ".sealed",
                                kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false]
        if let g = KeychainSecret.group { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    func read() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func write(_ data: Data) -> Bool {
        // updated in place when it exists (a delete that worked followed by an add that failed would lose every key)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    func delete() { SecItemDelete(base as CFDictionary) }
}

extension Keychain {
    /// The session (this device's key, which opens key hand-overs) leaves the access group the
    /// notification extension can read for the app's own: the item is moved in place, never
    /// deleted and added again. Once per account slot; nothing on an unsigned build.
    static func moveSessionToPrivateGroup() {
        guard let group = KeychainSecret.group else { return }
        let flag = AccountList.defaultsKey("belfry-session-private", slot: slot)
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: AccountList.sessionKey(slot)]
        let status = SecItemUpdate(q as CFDictionary, [kSecAttrAccessGroup as String: group] as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound || status == errSecDuplicateItem { UserDefaults.standard.set(true, forKey: flag) }
    }
}

@MainActor
extension AppModel {
    func sealedConv(_ conv: String) -> SealedConv? { sealed.convs[conv] }

    /// "Locked on this device": a sealed conversation on a device nobody allowed yet.
    func lockedHere(_ conv: String) -> Bool { sealed.notAllowed && sealed.convs[conv] != nil }

    // ---- the real thing (docs/sealed.md) ---------------------------------------------------------------

    func wireSealed(_ se: SealedEngine, dms d: DirectMessages) {
        se.sessions = { [weak self] in
            guard let api = await self?.api else { return nil }
            return try? await api.sessions()
        }
        se.revoke = { [weak self] pk in
            guard let api = await self?.api else { return false }
            return (try? await api.revokeSession(pk)) != nil
        }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        se.myName = { Sealed.DeviceName(name: pad ? "iPad" : "iPhone", kind: pad ? "tablet" : "phone", added: Int.now) }
        // new keys: what was kept opens now, and the relay is asked again for my wraps from the start
        se.onKeys = { [weak d, weak self] in
            Task {
                await d?.process()
                await self?.engine?.fetchAllWraps()
                await d?.process()
            }
        }
        se.onChange = { [weak self] in Task { @MainActor in self?.refreshSealed() } }
        // my chain was read again: the wraps kept for a letterbox this device did not know are judged now
        se.onMineRead = { [weak d] in Task { await d?.process() } }
        // a pass that failed on a precondition (the relay not answered yet, my devices not read,
        // the session list silent) is run again in seconds
        se.onRetry = { [weak self] in Task { @MainActor in self?.sealedNews([]) } }
        d.sealed = se
        if let l = pendingLinkSecret { se.setLink(l); pendingLinkSecret = nil }
    }

    /// The sealed engine, once this account's key is known (a signer may learn it after the session
    /// opened: nothing is read from or written to the Keychain before).
    func ensureSealed() {
        guard sealedEngine == nil, !isDemo, let s = session, s.reading != true, let e = engine, let d = dms, isHex64(e.me),
              let secret = Data(hex: s.clientSecret) else { return }
        Keychain.moveSessionToPrivateGroup()
        let store = OwnedKeyStore(raw: KeychainSecret(slot: Keychain.slot), owner: { [weak e] in e?.me ?? "" })
        guard let se = SealedEngine(engine: e, deviceSecret: secret, store: store) else { return }
        sealedStore = store
        wireSealed(se, dms: d)
        adoptSealed(se)
        startSealedUpkeep()
        sealedNews([])
    }

    /// Rosters, anchors, requests or keys arrived (or the relay answered): this device's upkeep,
    /// then the question a new device may be waiting with.
    func sealedNews(_ list: [NostrEvent]) {
        guard let se = sealedEngine else { ensureSealed(); return }
        se.observe(list.filter { $0.kind == SealedKind.roster }.compactMap { $0.tag("p") } + list.filter { $0.kind == 30078 }.map(\.pubkey))
        // only what touches my own account costs a look at my sessions
        let mine = list.isEmpty || list.contains { $0.pubkey == me || $0.hasTag("p", me) || $0.hasTag("p", se.devicePub) }
        // a kept wrap is tried again at each new roster (its author's chain may be whole now)
        // and a queued wrap is sealed again for a head that moved: the outbox tries now
        if list.contains(where: { $0.kind == SealedKind.roster }) { engine?.flushSoon() }
        se.mayStart = !derive.amGuest && !guestReading
        guard mine else { Task { await dms?.process(); refreshSealed() }; return }
        Task {
            await se.maintain()
            await dms?.process()
            // not allowed yet: who can let this device in, by name (the session list knows them)
            if se.mine == .waiting, let head = se.chain(me)?.devices, case .success(let list) = await sessions() {
                unlockerNames = list.filter { s in s.clientPubkey.map(head.contains) ?? false }
                    .map { s in (s.device ?? "").isEmpty ? (s.applicationName.isEmpty ? "A device" : s.applicationName) : s.device! }
            }
            let ask = await se.asks().first { !sealed.dismissed.contains($0.device) }
            let now = ask.map { AllowAsk(id: $0.device, device: $0.name, kind: DeviceKind.of($0.name), at: $0.at) }
            if sealed.ask != now { sealed.ask = now }
            refreshSealed()
        }
    }

    /// What the screens show, from the chains as they are now.
    func refreshSealed() {
        ensureSealed()
        guard let se = sealedEngine, let dms, !isDemo else { return }
        // the Keychain refused to keep the keys: said once (they live in memory until a write works)
        if sealedStore?.failed == true, !sealedSaveToldOnce {
            sealedSaveToldOnce = true
            showToast("This phone could not save its message keys. Keep the app open and try again later.")
        }
        var st = SealedState()
        st.ask = sealed.ask
        st.dismissed = sealed.dismissed
        let mine = se.chain(me)
        let names = se.deviceNames()
        func kind(_ d: String) -> DeviceKind? { names[d].flatMap { DeviceKind(rawValue: $0.kind) } }
        st.myDevices = (mine?.devices ?? []).map { d in
            let j = mine?.joined(d)
            let this = d == se.devicePub
            return MyDevice(id: d, name: names[d]?.name ?? (this ? UIDevice.current.model : "A device"), kind: kind(d) ?? .computer,
                            added: j?.at ?? 0, from: j?.from.flatMap { names[$0]?.name }, this: this)
        }
        st.added = se.addedNotices().map { n in
            AddedNotice(id: n.device, name: names[n.device]?.name ?? freshDeviceNames[n.device] ?? "A new device", kind: kind(n.device) ?? .phone, at: n.at)
        }
        // a device just added has no name record this device can read yet: its session's name
        for n in st.added where names[n.id] == nil && freshDeviceNames[n.id] == nil && !freshNameAsked.contains(n.id) {
            freshNameAsked.insert(n.id)
            Task { @MainActor in
                if case .success(let list) = await sessions(),
                   let s = list.first(where: { $0.clientPubkey == n.id }), let name = s.device ?? (s.applicationName.isEmpty ? nil : s.applicationName), !name.isEmpty {
                    freshDeviceNames[n.id] = name
                    refreshSealed()
                }
            }
        }
        st.notAllowed = se.mine == .waiting
        st.missingKeys = dms.lockedWraps > 0
        st.waitingCount = dms.lockedWraps
        st.checkingCount = dms.unknownWraps
        st.askedAt = se.upkeepState.lastRequest
        st.addedAt = se.lacksKey ? (mine?.joined(se.devicePub)?.at ?? 0) : 0
        st.unlockers = st.notAllowed ? unlockerNames : []
        st.upkeepLines = SealedDiagnostics.lines(se.upkeepState, mine: se.mine, now: Int.now)
        st.waitingForKey = se.lacksKey
        st.waitingLong = st.waitingForKey && (se.waitingSince.map { Int.now - $0 > 86400 } ?? false)
        st.signedOutOthers = sealed.signedOutOthers
        if let f = se.foreignFreshStart {
            // named from the belfry's session list (its own name record is sealed to the new letterbox)
            st.freshElsewhere = FreshElsewhere(device: freshDeviceNames[f.device], at: f.at)
            if freshDeviceNames[f.device] == nil, !freshNameAsked.contains(f.device) {
                freshNameAsked.insert(f.device)
                Task { @MainActor in
                    if case .success(let list) = await sessions(),
                       let s = list.first(where: { $0.clientPubkey == f.device }), let n = s.device ?? (s.applicationName.isEmpty ? nil : s.applicationName), !n.isEmpty {
                        freshDeviceNames[f.device] = n
                        refreshSealed()
                    }
                }
            }
        }
        for t in dms.threads() {
            let conv = t.conv
            if MailThreads.isMail(conv) {
                // my e-mail is sealed as soon as my chain is ready; the correspondent is not on this belfry
                if se.mailSealed { st.convs[conv] = SealedConv(since: mine?.root.createdAt, others: [SealedPerson(id: conv, mailName: convName(self, conv))]) }
                continue
            }
            guard se.isSealed(conv) else { continue }
            let others = MailThreads.peers(conv).filter { $0 != me }.map { p -> SealedPerson in
                let c = se.chain(p)
                let last = c?.changes.last
                return SealedPerson(id: p, devices: c?.devices.count ?? 0, changeAdded: last?.added ?? true, changeAt: last?.at)
            }
            let notices = se.notices(conv).map { n in
                DeviceNotice(id: n.id, at: n.at, who: n.who, what: n.fresh ? .locked : (n.added ? .added : .removed),
                             device: n.who == me ? names[n.device]?.name : nil, kind: n.who == me ? kind(n.device) : nil)
            }
            st.convs[conv] = SealedConv(since: se.sealedSince(conv), others: others, notices: notices)
        }
        if st != sealed { sealed = st }
    }

    /// Allow / Not me on the prompt. The first device to answer wins: the prompt goes either way.
    /// What the card shows after Allow / Not me: it closes only on `.done`.
    func answerAllow(_ ask: AllowAsk, allow: Bool) async -> SealedEngine.Answer {
        if let se = sealedEngine {
            let answer: SealedEngine.Answer
            if allow { answer = await se.allow(ask.id) } else { answer = await se.deny(ask.id) ? .done : .failed }
            // not done: the card stays and says so (a refused "Not me" leaves that session live)
            guard answer == .done else { return answer }
            let next = await se.asks().first { $0.device != ask.id && !sealed.dismissed.contains($0.device) }
            sealed.ask = next.map { AllowAsk(id: $0.device, device: $0.name, kind: DeviceKind.of($0.name), at: $0.at) }
            refreshSealed()
            return .done
        }
        try? await Task.sleep(nanoseconds: 700_000_000) // the demo's stand-in for the call
        if allow, launch.screen == "encallowfull" { return .full }
        if sealed.ask?.id == ask.id { sealed.ask = nil }
        return .done
    }

    /// The Allow card closed without an answer: the new device stays locked.
    func closeAsk(_ ask: AllowAsk, devices: Bool) {
        sealed.dismissed.insert(ask.id)
        sealed.ask = nil
        if devices { sealed.openDevices = true }
    }

    /// Share history with someone's new device; the amber line then reads "<name> added a device".
    /// Nil when it went; else what to tell the person (the sheet stays).
    func shareHistory(_ notice: DeviceNotice, in conv: String) async -> String? {
        if let se = sealedEngine, let dms {
            // to the person's head as the relay has it now, never to one they may have left
            guard await se.refresh([notice.who]) else { return "The belfry did not answer. Try again." }
            do { try se.share(dms.rumors(conv), with: notice.who, notice: notice.id) } catch {
                return (error as? BelfryError)?.errorDescription ?? "It could not be shared. Try again."
            }
            refreshSealed()
            return nil
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard var c = sealed.convs[conv], let i = c.notices.firstIndex(where: { $0.id == notice.id }) else { return nil }
        c.notices[i].what = .added
        sealed.convs[conv] = c
        return nil
    }

    /// Every 6 hours while the app runs (sealed.md 5.6): a device whose session is gone leaves.
    func startSealedUpkeep() {
        sealedTimer?.invalidate()
        sealedTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sealedNews([]) }
        }
    }

    /// My own name where a screen names me ("Sam Rivera (you)", "Signed in as Sam Rivera").
    var myName: String { let r = realName(me); return r.isEmpty ? name(me) : r }

    /// The first name on a notice line ("Lina added a device"); "Somebody" stays whole.
    func firstName(_ pubkey: String) -> String {
        let r = realName(pubkey)
        return r.isEmpty ? name(pubkey) : String(r.split(separator: " ").first ?? Substring(r))
    }

    /// The link the QR of "Link a phone or tablet" shows: with a fresh one-time secret when this
    /// device can let the other one in.
    func deviceLink(_ a: MemberAddress) -> String {
        LoginLink.link(a, secret: sealedEngine?.mine == .inside ? sealedEngine?.newLinkSecret() : nil)
    }
}

extension Demo {
    /// The demo's sealed conversations: Lina (two people), Emma's group of five, Town Hall by
    /// e-mail, and Sam's two devices. `screen`: the screenshot being taken.
    @MainActor static func sealed(me: String, dms: DirectMessages, screen: String?) -> SealedState {
        let now = Int.now, day = 86400
        func pk(_ n: String) -> String { signer(n).pubkey }
        var s = SealedState()
        s.myDevices = [
            MyDevice(id: "this", name: "iPhone", kind: .phone, added: now - 100 * day, this: true),
            MyDevice(id: "mac", name: "Safari on Mac", kind: .computer, added: now - 49 * day, from: "iPhone"),
        ]
        let lina = "n:" + pk("lina")
        s.convs[lina] = SealedConv(
            others: [SealedPerson(id: pk("lina"), devices: 2, changeAdded: false, changeAt: now - 3 * 3600)],
            notices: [
                DeviceNotice(id: "l1", at: now - 20 * 3600, who: pk("lina"), what: .added),
                DeviceNotice(id: "l2", at: now - 3 * 3600, who: pk("lina"), what: .removed),
                DeviceNotice(id: "l3", at: now - 3 * 3600 + 600, who: me, what: .added, device: "Safari on Mac", kind: .computer),
                DeviceNotice(id: "l4", at: now - 2400, who: pk("lina"), what: .locked, kind: .phone),
            ])
        s.convs["n:" + pk("ana")] = SealedConv(since: now - 3600, others: [SealedPerson(id: pk("ana"), devices: 3, changeAt: now - 5 * 3600)])
        s.convs["n:" + pk("dev")] = SealedConv(others: [SealedPerson(id: pk("dev"), devices: 1)])
        let group = MailThreads.nostrConv(author: pk("emma"), pTags: [me, pk("ana"), pk("ben"), pk("lina")], me: me)
        s.convs[group] = SealedConv(others: [
            SealedPerson(id: pk("ana"), devices: 3, changeAt: now - 5 * 3600),
            SealedPerson(id: pk("ben"), devices: 1),
            SealedPerson(id: pk("emma"), devices: 2, changeAdded: false, changeAt: now - 18 * day),
            SealedPerson(id: pk("lina"), devices: 3),
        ])
        if let mail = dms.threads().first(where: { MailThreads.isMail($0.conv) })?.conv {
            s.convs[mail] = SealedConv(others: [SealedPerson(id: mail, mailName: "Town Hall")])
        }
        switch screen {
        case "encwaiting":
            s.waitingForKey = true
        case "encnewdevice", "enchow", "enclocked":
            s.notAllowed = true
        // boards messages/encryption-waiting-list, -waiting-checking (canvas v177)
        // boards messages/encryption-device-added, -devices-added (canvas v183)
        case "encdeviceadded", "encdevicesadded":
            s.added = [AddedNotice(id: "mac", name: "Safari on Mac", kind: .computer, at: now - 40)]
        case "encdeviceswaiting":
            s.notAllowed = true
            s.askedAt = now - 1500
            // a device that is not allowed is not among my devices: the screen adds its own row
            s.myDevices.removeAll { $0.this }
        case "encwaitinglist":
            s.askedAt = now - 900
            s.unlockers = ["Safari on Mac", "Android phone"]
            s.notAllowed = true
            s.missingKeys = true
            s.waitingCount = 3
        case "encchecking":
            s.checkingCount = 3
        case "encallow", "encallowfull", "encallowwaiting":
            s.ask = AllowAsk(id: "mac", device: "Safari on Mac", kind: .computer, at: now - 120)
        default: break
        }
        return s
    }

    static func groupConv(me: String) -> String {
        MailThreads.nostrConv(author: signer("emma").pubkey, pTags: ["ana", "ben", "lina"].map { signer($0).pubkey }, me: me)
    }
}

extension AppModel {
    /// Signing out here would lose my sealed conversations until Start fresh: this is the only
    /// device in my roster and it holds the letterbox (not for guests, not in a demo without one).
    var onlySealedDevice: Bool {
        if launch.screen == "enconlydevice" { return true }
        guard !derive.amGuest, !guestReading, let se = sealedEngine else { return false }
        return se.onlyDevice
    }
}


/// About → Diagnostics: the sealed upkeep's last pass in words (no keys, no ids).
enum SealedDiagnostics {
    static func lines(_ u: (report: SealedEngine.UpkeepReport, lastRequest: Int, failures: Int, retryAt: Int?), mine: SealedEngine.Mine, now: Int) -> [String] {
        let r = u.report
        guard r.at > 0 else { return ["No check yet in this run"] }
        func yn(_ b: Bool?, _ yes: String, _ no: String) -> String? { b.map { $0 ? yes : no } }
        var out = ["Last check: \(Format.time(r.at))"]
        out += [yn(r.relayAnswered, "Community relay answered after signing in: yes", "Community relay answered after signing in: not yet"),
                yn(r.chainRead, "My devices read from the relay: yes", "My devices read from the relay: no answer in 3 s"),
                yn(r.sessions, "Session list from the belfry: yes", "Session list from the belfry: no answer"),
                yn(r.listsMe, "This device is in the session list: yes", "This device is in the session list: no"),
                yn(r.inHead, "This device is allowed: yes", "This device is allowed: not yet"),
                yn(r.asked, "Asked to be allowed in this check: yes", "Asked to be allowed in this check: could not send"),
                r.requestWaiting == true ? "The request is still waiting to be sent" : nil,
                r.requestRefused.map { "The relay refused the request (asked again): \($0)" }].compactMap { $0 }
        if mine == .waiting || u.lastRequest > 0 {
            out.append(u.lastRequest > 0 ? "Last asked to be allowed: \(Format.day(u.lastRequest)) \(Format.time(u.lastRequest))" : "Last asked to be allowed: never")
        }
        if u.failures > 0 { out.append("Failed checks in a row: \(u.failures)") }
        if let at = u.retryAt { out.append("Next try in \(max(0, at - now)) s") }
        return out
    }
}


extension AppModel {
    /// "It was me" on the notice.
    func ackAdded(_ n: AddedNotice) {
        if isDemo { sealed.added.removeAll { $0.id == n.id }; return }
        sealedEngine?.ackAdded(n.id)
        refreshSealed()
    }

    /// "Remove it": the device is signed out, then leaves my devices and the lock changes
    /// (sealed.md 5.6). Nil when done, else what to say.
    func removeAdded(_ n: AddedNotice) async -> String? {
        if isDemo {
            try? await Task.sleep(nanoseconds: 700_000_000)
            sealed.added.removeAll { $0.id == n.id }
            return nil
        }
        guard let se = sealedEngine, await se.remove(n.id) else { return "It couldn't be removed. Check your connection and try again." }
        refreshSealed()
        return nil
    }
}
