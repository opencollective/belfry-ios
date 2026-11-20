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

struct SealedState: Equatable {
    var myDevices: [MyDevice] = []
    /// The sealed conversations (a conversation that is not in here shows no lock).
    var convs: [String: SealedConv] = [:]
    /// This is a new device nobody allowed yet: it reads no sealed message, old or new (it has no
    /// letterbox secret, sealed.md 5.2); messages from before the conversation was sealed stay readable.
    var notAllowed = false
    var ask: AllowAsk?
    /// Asks the user closed without an answer (20 devices already): not shown again in this run.
    var dismissed: Set<String> = []
    /// "Devices" on the Allow card: Me → Devices is pushed.
    var openDevices = false
    /// Demo: devices removed in Devices.
    var removed: Set<String> = []
}

/// The letterbox secrets of one account on this device: in the Keychain (the session's own
/// accessibility), never in the database, never logged; gone on sign-out.
final class KeychainKeyStore: SealedKeyStore, @unchecked Sendable {
    private let account: String
    init(slot: String) { account = slot.isEmpty ? "sealed-keys" : "sealed-keys@" + slot }
    func load() -> KeyChain {
        guard let text = Keychain.string(account), let c = try? JSONDecoder().decode(KeyChain.self, from: Data(text.utf8)) else { return KeyChain() }
        return KeyChain(keys: c.keys)
    }
    func save(_ chain: KeyChain) {
        guard let d = try? JSONEncoder().encode(chain) else { return }
        Keychain.setString(String(decoding: d, as: UTF8.self), account)
    }
    func wipe() { Keychain.removeString(account) }
}

@MainActor
extension AppModel {
    func sealedConv(_ conv: String) -> SealedConv? { sealed.convs[conv] }

    /// "Locked on this device": a sealed conversation on a device nobody allowed yet.
    func lockedHere(_ conv: String) -> Bool { sealed.notAllowed && sealed.convs[conv] != nil }

    // ---- the real thing (docs/sealed.md) ---------------------------------------------------------------

    func wireSealed(_ se: SealedEngine, dms d: DirectMessages) {
        se.bridge = { [weak d] in d?.bridge }
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
        se.onKeys = { [weak d] in Task { await d?.process() } }
        se.onChange = { [weak self] in Task { @MainActor in self?.refreshSealed() } }
        d.sealed = se
        if let l = pendingLinkSecret { se.setLink(l); pendingLinkSecret = nil }
    }

    /// Rosters, anchors, requests or keys arrived (or the relay answered): this device's upkeep,
    /// then the question a new device may be waiting with.
    func sealedNews(_ list: [NostrEvent]) {
        guard let se = sealedEngine else { return }
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
            let ask = await se.asks().first { !sealed.dismissed.contains($0.device) }
            let now = ask.map { AllowAsk(id: $0.device, device: $0.name, kind: DeviceKind.of($0.name), at: $0.at) }
            if sealed.ask != now { sealed.ask = now }
            refreshSealed()
        }
    }

    /// What the screens show, from the chains as they are now.
    func refreshSealed() {
        guard let se = sealedEngine, let dms, !isDemo else { return }
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
        st.notAllowed = se.mine == .waiting || dms.lockedWraps > 0
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
    /// False: Allow was refused because the account already has 20 devices (the card says so).
    @discardableResult
    func answerAllow(_ ask: AllowAsk, allow: Bool) async -> Bool {
        if let se = sealedEngine {
            // 20 devices already: refused, and said, before any key is handed over
            if allow, se.full, se.chain(me)?.devices.contains(ask.id) != true { return false }
            _ = allow ? await se.allow(ask.id) : await se.deny(ask.id)
            let next = await se.asks().first { $0.device != ask.id && !sealed.dismissed.contains($0.device) }
            sealed.ask = next.map { AllowAsk(id: $0.device, device: $0.name, kind: DeviceKind.of($0.name), at: $0.at) }
            return true
        }
        try? await Task.sleep(nanoseconds: 700_000_000) // the demo's stand-in for the call
        if allow, launch.screen == "encallowfull" { return false }
        if sealed.ask?.id == ask.id { sealed.ask = nil }
        return true
    }

    /// The Allow card closed without an answer: the new device stays locked.
    func closeAsk(_ ask: AllowAsk, devices: Bool) {
        sealed.dismissed.insert(ask.id)
        sealed.ask = nil
        if devices { sealed.openDevices = true }
    }

    /// Share history with someone's new device; the amber line then reads "<name> added a device".
    func shareHistory(_ notice: DeviceNotice, in conv: String) async {
        if let se = sealedEngine, let dms {
            try? se.share(dms.rumors(conv), with: notice.who, notice: notice.id)
            refreshSealed()
            return
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard var c = sealed.convs[conv], let i = c.notices.firstIndex(where: { $0.id == notice.id }) else { return }
        c.notices[i].what = .added
        sealed.convs[conv] = c
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
        case "encnewdevice", "enchow", "enclocked":
            s.notAllowed = true
        case "encallow", "encallowfull":
            s.ask = AllowAsk(id: "mac", device: "Safari on Mac", kind: .computer, at: now - 120)
        default: break
        }
        return s
    }

    static func groupConv(me: String) -> String {
        MailThreads.nostrConv(author: signer("emma").pubkey, pTags: ["ana", "ben", "lina"].map { signer($0).pubkey }, me: me)
    }
}
