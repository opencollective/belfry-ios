import BelfryCore
import Foundation

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
    var kind: DeviceKind = .phone
}

struct SealedConv: Hashable {
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

struct SealedState {
    var myDevices: [MyDevice] = []
    /// The sealed conversations (a conversation that is not in here shows no lock).
    var convs: [String: SealedConv] = [:]
    /// This is a new device nobody allowed yet: earlier messages are locked on it.
    var lockedHere = false
    /// On such a device, the conversations that read normally (started after it was added).
    var open: Set<String> = []
    var ask: AllowAsk?
    /// Demo: devices removed in Devices.
    var removed: Set<String> = []
}

@MainActor
extension AppModel {
    func sealedConv(_ conv: String) -> SealedConv? { sealed.convs[conv] }

    /// "Locked on this device": a new device nobody allowed, and a conversation from before it.
    func lockedHere(_ conv: String) -> Bool { sealed.lockedHere && !sealed.open.contains(conv) }

    /// Allow / Not me on the prompt. The first device to answer wins: the prompt goes either way.
    func answerAllow(_ ask: AllowAsk, allow: Bool) async {
        try? await Task.sleep(nanoseconds: 700_000_000) // the demo's stand-in for the call
        if sealed.ask?.id == ask.id { sealed.ask = nil }
    }

    /// Share history with someone's new device; the amber line then reads "<name> added a device".
    func shareHistory(_ notice: DeviceNotice, in conv: String) async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard var c = sealed.convs[conv], let i = c.notices.firstIndex(where: { $0.id == notice.id }) else { return }
        c.notices[i].what = .added
        sealed.convs[conv] = c
    }

    /// The first name on a notice line ("Lina added a device"); "Somebody" stays whole.
    func firstName(_ pubkey: String) -> String {
        let r = realName(pubkey)
        return r.isEmpty ? name(pubkey) : String(r.split(separator: " ").first ?? Substring(r))
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
        s.convs["n:" + pk("ana")] = SealedConv(others: [SealedPerson(id: pk("ana"), devices: 3, changeAt: now - 5 * 3600)])
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
        case "encnewdevice", "enchow":
            s.lockedHere = true
            s.open = [lina]
        case "encallow":
            s.ask = AllowAsk(id: "mac", device: "Safari on Mac", kind: .computer, at: now - 120)
        default: break
        }
        return s
    }

    static func groupConv(me: String) -> String {
        MailThreads.nostrConv(author: signer("emma").pubkey, pTags: ["ana", "ben", "lina"].map { signer($0).pubkey }, me: me)
    }
}
