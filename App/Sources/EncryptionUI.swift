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
                Image(systemName: notice.device != nil ? (notice.kind ?? .computer).icon : "lock")
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
                            (Text(model.myName) + Text(" (you)").foregroundStyle(.secondary)).lineLimit(1)
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
                        Text(model.myName).foregroundStyle(.primary) + Text(" (you)")
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
                Text("Messages are locked on this device").font(.subheadline.weight(.semibold))
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

/// In a sealed conversation on a device nobody allowed yet, after the messages from before it was
/// sealed (board messages/encryption-locked-thread).
struct LockedThreadBlock: View {
    /// When the conversation became sealed.
    let since: Int?
    let showHow: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Locked on this device").font(.subheadline.weight(.semibold))
                Text(line).font(.subheadline)
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

    private var line: String {
        guard let since else { return "Messages can be read once another device of yours allows this one." }
        let day = SealedWords.dayWord(since, now: Int.now)
        return "Messages from \(day.hasPrefix("on ") ? String(day.dropFirst(3)) : day) on can be read once another device of yours allows this one."
    }
}

/// "Shared by Sam" above a block of earlier messages someone shared with this device (board
/// messages/encryption-shared-history). A line, not a list row: it opens a small sheet.
struct SharedByLine: View {
    @EnvironmentObject var model: AppModel
    let by: String
    @State private var why = false

    var body: some View {
        let who = model.firstName(by)
        Button { hideKeyboard(); why = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up").font(.caption)
                Text("Shared by \(who)").font(.footnote)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shared-by")
        .sheet(isPresented: $why) {
            VStack(spacing: 16) {
                Text("\(who) sent you these earlier messages. They come from \(who)'s device, so the app can't check them the way it checks new ones.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { why = false } label: { Text("OK").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand).controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
            .solidSheet()
        }
        .onAppear { if model.launch.screen == "encsharedwhy" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { why = true } } }
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
    /// Allow was refused: the account already has 20 devices.
    @State private var full = false
    @State private var failed: String?
    /// Allow could not be given yet: this device waits for its own key.
    @State private var waiting = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: ask.kind.icon).font(.system(size: 30)).foregroundStyle(.secondary)
                    .frame(width: 60, height: 60).background(Color.secondary.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                if let failed {
                    // it did not go through: said plainly, the card stays
                    Label(failed, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                if full {
                    Text("You already have 20 devices. Remove one in Devices, then try again.")
                        .font(.headline).multilineTextAlignment(.center)
                    Button { model.closeAsk(ask, devices: true) } label: { Text("Devices").frame(maxWidth: .infinity) }
                        .buttonStyle(.brand).controlSize(.large)
                        .padding(.top, 6)
                    Button { model.closeAsk(ask, devices: false) } label: { Text("OK").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                } else {
                    Text("Give your new device “\(ask.device)” access to your conversations?")
                        .font(.headline).multilineTextAlignment(.center)
                    Text("It will read all your messages, including earlier ones.")
                        .font(.subheadline).multilineTextAlignment(.center)
                    Text("Signed in as \(model.myName) · \(Format.ago(ask.at))")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if waiting {
                        // this device has no key itself yet (board messages/encryption-allow-waiting)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Not allowed yet: waiting for your other device").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.top, 6)
                        .accessibilityElement(children: .combine)
                    } else {
                        BusyButton { await answer(true) } label: { Text("Allow").frame(maxWidth: .infinity) }
                            .buttonStyle(.brand).controlSize(.large)
                            .padding(.top, 6)
                            .accessibilityIdentifier("allow-device")
                    }
                    BusyButton(role: .destructive) { await answer(false) } label: { Text("Not me").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large).tint(.red)
                        .accessibilityIdentifier("allow-not-me")
                    Text("Not me removes that device and signs it out.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .disabled(busy)
            .padding(20)
            .frame(maxWidth: 340)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 28)
            .accessibilityAddTraits(.isModal)
        }
        .task {
            // screenshots: the card after Allow was refused
            if model.launch.screen == "encallowfull" { full = true }
            if model.launch.screen == "encallowwaiting" { waiting = true }
        }
    }

    private func answer(_ allow: Bool) async {
        busy = true
        failed = nil
        switch await model.answerAllow(ask, allow: allow) {
        case .done: break
        case .full: full = true
        case .waiting: waiting = true
        case .failed: failed = allow ? "Not done: the belfry did not confirm it. Try again." : "Not done: that device is still signed in. Try again."
        }
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
    @State private var error: String?

    var body: some View {
        let who = model.firstName(notice.who)
        let group = MailThreads.peers(conv).count > 1
        // the kind of someone else's device is not always known: then just "device"
        let kind = notice.kind.map { $0 == .phone ? "phone" : $0 == .tablet ? "tablet" : "computer" } ?? "device"
        VStack(spacing: 12) {
            Image(systemName: notice.kind?.icon ?? "lock.open").font(.system(size: 30)).foregroundStyle(.secondary)
                .frame(width: 60, height: 60).background(Color.secondary.opacity(0.15), in: Circle())
                .padding(.top, 24)
                .accessibilityHidden(true)
            Text("Share this \(group ? "group" : "conversation")'s history with \(who)'s new device?")
                .font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text("\(who) started over on a new device and can't read your earlier messages. Only do this if you're sure it's \(who): ask in person or by phone if you're not.")
                .font(.subheadline).multilineTextAlignment(.center)
            Text("A new \(kind) · signed in \(SealedWords.dayWord(notice.at, now: Int.now)) \(Format.time(notice.at))")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red) }
            BusyButton {
                busy = true
                error = await model.shareHistory(notice, in: conv)
                busy = false
                if error == nil { dismiss() }
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
