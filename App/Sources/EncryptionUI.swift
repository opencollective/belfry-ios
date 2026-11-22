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

/// The amber banner at the top of Messages on a device that is not allowed yet (the lead,
/// 2026-11-22, after a phone showed nothing for a mail it could not open): how many messages
/// wait, what to do. While my devices are still being read from the relay: "Checking your
/// devices…". (Boards messages/encryption-waiting-list, -waiting-checking, canvas v177: a draft for
/// Xavier, built on a branch only.)
struct LockedHereBanner: View {
    /// Messages kept here for a key this device doesn't have.
    var waiting = 0
    /// My devices aren't read yet: no "locked", no Show how.
    var checking = false
    let showHow: () -> Void

    static func title(waiting: Int, checking: Bool) -> String {
        if checking { return "Checking your devices…" }
        if waiting == 1 { return "1 message is waiting for another of your devices" }
        if waiting > 1 { return "\(waiting) messages are waiting for another of your devices" }
        return "Messages are locked on this device"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if checking { ProgressView().controlSize(.small).padding(.top, 2) }
            else { Image(systemName: "lock.fill").foregroundStyle(.orange).padding(.top, 2).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 4) {
                Text(LockedHereBanner.title(waiting: waiting, checking: checking)).font(.subheadline.weight(.semibold))
                if checking {
                    Text(waiting == 1 ? "1 message is waiting." : "\(waiting) messages are waiting.").font(.subheadline)
                } else {
                    Text("Open Belfry on a device where you already read your messages and tap Allow.").font(.subheadline)
                    Button("Show how", action: showHow)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                        .accessibilityIdentifier("locked-show-how")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("locked-banner")
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
    @EnvironmentObject var model: AppModel
    @State private var asking = false
    @State private var starting = false
    @State private var failed = false
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
            } header: {
                Text("With another device")
            } footer: {
                Text("No other device? The people you write to can share a conversation's history with this device.")
            }
            // board messages/encryption-start-fresh: the last row; it asks first
            if model.sealed.notAllowed || model.launch.screen?.hasPrefix("encfresh") == true {
                Section {
                    Button { asking = true } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("I don't have another device").foregroundStyle(.primary)
                                Text("Start fresh on this device").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if starting { ProgressView() } else { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(starting)
                    .accessibilityIdentifier("start-fresh")
                } footer: {
                    if failed { Text("It didn't go through. Check the connection and try again.").foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Unlock this device")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Start fresh on this device?", isPresented: $asking) {
            Button("Start fresh", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Earlier sealed messages stay locked here unless someone shares them with you or an old device comes back.\n\nThe people you write with will see that you started on a new device.")
        }
        .onAppear { if model.launch.screen == "encfreshconfirm" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { asking = true } } }
    }

    /// Start fresh locks and shows progress until the relay holds the new chain.
    private func start() {
        guard !starting else { return }
        starting = true
        failed = false
        Task { @MainActor in
            let ok = model.isDemo ? true : (await model.sealedEngine?.startFresh() ?? false)
            starting = false
            failed = !ok
            if ok { model.refreshSealed() }
        }
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

/// My sealed conversations were started fresh on another device while this one was in the head
/// (boards messages/encryption-fresh-elsewhere, -done; the attacker-after-the-e-mail-code case).
/// The alert card over any screen, like the Allow prompt; it comes back at every start until one
/// button is tapped.
struct FreshElsewherePrompt: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false
    @State private var failed = false
    @State private var how = false

    private var demoDone: Bool { model.launch.screen == "encelsewheredone" }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                if let names = model.sealed.signedOutOthers ?? (demoDone ? ["iPad"] : nil) {
                    done(names)
                } else {
                    ask(model.sealed.freshElsewhere ?? FreshElsewhere(device: "iPad", at: Int.now - 120))
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(24)
        }
        .sheet(isPresented: $how) { NavigationStack { UnlockHowScreen().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { how = false } } } } }
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private func ask(_ f: FreshElsewhere) -> some View {
        Image(systemName: "exclamationmark.lock.fill").font(.system(size: 30)).foregroundStyle(.orange)
            .frame(width: 60, height: 60).background(Color.orange.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
        Text(f.device.map { "Sealed conversations were started fresh on \u{201C}\($0)\u{201D}" } ?? "Sealed conversations were started fresh on a new device")
            .font(.headline).multilineTextAlignment(.center)
        Text(FreshElsewherePrompt.when(f.at)).font(.subheadline).foregroundStyle(.secondary)
        Text("This device can't read new sealed messages until it's allowed again.").font(.subheadline).multilineTextAlignment(.center)
        Text("If this wasn't you, sign out every other device.").font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
        if failed { Text("Couldn't sign out every device. Try again.").font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
        BusyButton(role: .destructive) { await signOutOthers() } label: {
            Text("Sign out every other device").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
        .accessibilityIdentifier("fresh-signout-others")
        Button { model.sealedEngine?.dismissForeignFresh(); model.refreshSealed() } label: {
            Text("It was me").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
        .disabled(busy)
    }

    @ViewBuilder private func done(_ names: [String]) -> some View {
        Image(systemName: "checkmark.shield.fill").font(.system(size: 30)).foregroundStyle(.green)
            .frame(width: 60, height: 60).background(Color.green.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
        Text("Every other device is signed out").font(.headline).multilineTextAlignment(.center)
        VStack(alignment: .leading, spacing: 8) {
            if !names.isEmpty { Text("\(ListFormatter.localizedString(byJoining: names)) can't open your account any more.") }
            Text("Someone may have signed in with a code sent to your e-mail: change that e-mail's password.")
            Text("To read sealed conversations here again, start fresh on this device.")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        Button { how = true } label: { Text("Show how").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large)
        Button { model.sealed.signedOutOthers = nil } label: { Text("Done").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).controlSize(.large)
    }

    /// Locks and shows progress; every session but this one is revoked, then this device asks
    /// to be allowed. Some failed: the red button comes back with the error line.
    private func signOutOthers() async {
        busy = true
        failed = false
        let names = model.isDemo ? ["iPad"] : await model.sealedEngine?.signOutEveryOtherDevice()
        busy = false
        if let names { model.sealed.signedOutOthers = names; model.refreshSealed() } else { failed = true }
    }

    /// "Today at 9:41 PM", "Yesterday at 9:41 PM", "21 Nov at 9:41 PM".
    static func when(_ at: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(at))
        let t = DateFormatter(); t.timeStyle = .short; t.dateStyle = .none
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today at " + t.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday at " + t.string(from: d) }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: d) + " at " + t.string(from: d)
    }
}
