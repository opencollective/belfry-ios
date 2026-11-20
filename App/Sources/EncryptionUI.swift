import BelfryCore
import SwiftUI

// The screens of end-to-end encrypted conversations (boards messages/encryption-*, approved
// 2026-11-20). They draw `model.sealed` (Sealed.swift): demo data until the lead's contract.
// Never a key, an npub or an id as text; only my own devices are named.

/// The small lock by a sealed conversation's name: opens the Encryption screen.
struct SealedLock: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End-to-end encrypted: see who can read it")
        .accessibilityIdentifier("sealed-lock")
    }
}

/// "Lina added a device" in a conversation: a channel's join line, with a › (it opens a screen).
struct DeviceNoticeLine: View {
    @EnvironmentObject var model: AppModel
    let notice: DeviceNotice
    let action: () -> Void

    var body: some View {
        let warn = notice.what == .locked
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: notice.device != nil ? notice.kind.icon : "lock")
                    .foregroundStyle(warn ? Color.orange : Color.secondary)
                Text(LocalizedStringKey(text)).font(.footnote).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, warn ? 10 : 6)
            .padding(.horizontal, warn ? 12 : 0)
            .background(warn ? Color.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(warn ? "device-notice-locked" : "device-notice")
    }

    var text: String {
        let mine = notice.who == model.me
        let who = mine ? "You" : model.firstName(notice.who)
        switch notice.what {
        case .added: return "**\(who) added a device**" + (mine ? notice.device.map { " · " + $0 } ?? "" : "")
        case .removed: return "**\(who) removed a device**" + (mine ? notice.device.map { " · " + $0 } ?? "" : "")
        case .locked: return "**\(who) signed in on a new device** that can't read earlier messages yet"
        }
    }
}

/// One of my devices: its plain name, when it was added and from which device.
struct MyDeviceRow: View {
    let icon: String
    let name: String
    let line: String
    var this = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name).font(.body)
                    if this {
                        Text("This device").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Only these devices can read this conversation": my devices in full, every other person as a
/// count (boards messages/encryption-devices, -group, -email). A pushed screen.
struct EncryptionScreen: View {
    @EnvironmentObject var model: AppModel
    let conv: String
    @State private var mineOpen = true

    var body: some View {
        let s = model.sealedConv(conv) ?? SealedConv(others: [])
        let mine = model.sealed.myDevices
        let group = s.others.count > 1
        let counted = s.others.contains { $0.mailName == nil }
        let mail = s.others.contains { $0.mailName != nil }
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .background(Color.secondary.opacity(0.15), in: Circle())
                        .accessibilityHidden(true)
                    Text("Only these devices can read this conversation")
                        .font(.title3.weight(.bold)).multilineTextAlignment(.center)
                    if group {
                        Text(SealedWords.summary(people: s.others.count + 1, devices: mine.count + s.others.reduce(0) { $0 + $1.devices }))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            if group {
                // only "You" unfolds, to my own devices
                Section("You") {
                    DisclosureGroup(isExpanded: $mineOpen) {
                        ForEach(mine) { d in MyDeviceRow(icon: d.kind.icon, name: d.name, line: SealedWords.added(d.added, from: d.from), this: d.this) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(pubkey: model.me, size: 32)
                            (Text(model.name(model.me)) + Text(" (you)").foregroundStyle(.secondary)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(SealedWords.devices(mine.count)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("encryption-you")
                }
            } else {
                Section {
                    ForEach(mine) { d in MyDeviceRow(icon: d.kind.icon, name: d.name, line: SealedWords.added(d.added, from: d.from), this: d.this) }
                } header: {
                    HStack(spacing: 8) {
                        Avatar(pubkey: model.me, size: 22)
                        Text(model.name(model.me)).foregroundStyle(.primary) + Text(" (you)")
                    }
                    .font(.subheadline)
                    .textCase(nil)
                }
            }
            Section {
                ForEach(s.others) { p in person(p) }
            } header: { Text("Others") } footer: {
                if counted { Text("You see only how many devices others have, not which.") }
            }
            Section {
                fact("eye.slash", "The server and the belfry's admins can't read it.")
                fact("arrow.triangle.2.circlepath", group ? "When a device is removed or someone leaves, the lock changes: they can't read anything new."
                     : "When a device is removed, the lock changes: that device can't read anything new.")
                if mail {
                    fact("envelope", "E-mails are locked as soon as they arrive. They pass through the belfry's mail server, and the other side's mail provider keeps its own copy.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("encryption-screen")
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
    }

    /// One row per person: face, name, "N devices" and the change of the last 30 days. It does not
    /// unfold and is not a button.
    @ViewBuilder private func person(_ p: SealedPerson) -> some View {
        HStack(spacing: 12) {
            if let m = p.mailName {
                Image(systemName: "envelope.fill").font(.footnote).foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32).background(Color.brand, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m) · by e-mail").lineLimit(1)
                    Text("not on this belfry").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Avatar(pubkey: p.id, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name(p.id)).lineLimit(1)
                    if let at = p.changeAt, let line = SealedWords.change(added: p.changeAdded, at: at, now: Int.now) {
                        Text(line).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Text(SealedWords.devices(p.devices)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The amber banner at the top of Messages on a new device nobody allowed yet.
struct LockedHereBanner: View {
    let showHow: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Earlier messages are locked on this device").font(.subheadline.weight(.semibold))
                Text("Open Belfry on another device of yours to unlock them.").font(.subheadline)
                Button("Show how", action: showHow)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                    .accessibilityIdentifier("locked-show-how")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "Show how": the three steps, a pushed screen.
struct UnlockHowScreen: View {
    private let steps = [
        "Open Belfry on a phone, tablet or computer where you're already signed in.",
        "It asks whether to give this device access: tap Allow.",
        "Your conversations open here.",
    ]
    var body: some View {
        List {
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "\(i + 1).circle.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(s)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(i + 1). \(s)")
                }
            } footer: {
                Text("No other device? The people you write to can share a conversation's history with this device.")
            }
        }
        .navigationTitle("Unlock with another device")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "Give your new device … access to your conversations?" on my other devices, over whatever
/// screen is open. Allow / Not me; both lock while one works.
struct AllowPrompt: View {
    @EnvironmentObject var model: AppModel
    let ask: AllowAsk
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: ask.kind.icon).font(.system(size: 30)).foregroundStyle(.secondary)
                    .frame(width: 60, height: 60).background(Color.secondary.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                Text("Give your new device “\(ask.device)” access to your conversations?")
                    .font(.headline).multilineTextAlignment(.center)
                Text("It will read all your messages, including earlier ones.")
                    .font(.subheadline).multilineTextAlignment(.center)
                Text("Signed in as \(model.name(model.me)) · \(Format.ago(ask.at))")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                BusyButton { await answer(true) } label: { Text("Allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand).controlSize(.large)
                    .padding(.top, 6)
                    .accessibilityIdentifier("allow-device")
                BusyButton(role: .destructive) { await answer(false) } label: { Text("Not me").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).tint(.red)
                    .accessibilityIdentifier("allow-not-me")
                Text("Not me removes that device and signs it out.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .disabled(busy)
            .padding(20)
            .frame(maxWidth: 340)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 28)
            .accessibilityAddTraits(.isModal)
        }
    }

    private func answer(_ allow: Bool) async {
        busy = true
        await model.answerAllow(ask, allow: allow)
        busy = false
    }
}

/// Opened from the amber line: share this conversation's history with someone's new device.
/// A notice opens it, not a list row, so it is a sheet. Share history / Not now.
struct ShareHistorySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let conv: String
    let notice: DeviceNotice
    @State private var busy = false

    var body: some View {
        let who = model.firstName(notice.who)
        let group = MailThreads.peers(conv).count > 1
        let kind = notice.kind == .phone ? "phone" : notice.kind == .tablet ? "tablet" : "computer"
        VStack(spacing: 12) {
            Image(systemName: notice.kind.icon).font(.system(size: 30)).foregroundStyle(.secondary)
                .frame(width: 60, height: 60).background(Color.secondary.opacity(0.15), in: Circle())
                .padding(.top, 24)
                .accessibilityHidden(true)
            Text("Share this \(group ? "group" : "conversation")'s history with \(who)'s new device?")
                .font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text("\(who) signed in on a new device that can't read earlier messages yet, and has no other device to unlock it. Only do this if you're sure it's \(who): ask in person or by phone if you're not.")
                .font(.subheadline).multilineTextAlignment(.center)
            Text("A new \(kind) · signed in \(SealedWords.dayWord(notice.at, now: Int.now)) \(Format.time(notice.at))")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            BusyButton {
                busy = true
                await model.shareHistory(notice, in: conv)
                busy = false
                dismiss()
            } label: { Text("Share history").frame(maxWidth: .infinity) }
                .buttonStyle(.brand).controlSize(.large)
                .accessibilityIdentifier("share-history")
            Button { dismiss() } label: { Text("Not now").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(busy)
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .solidSheet()
        .interactiveDismissDisabled(busy)
    }
}
