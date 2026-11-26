import BelfryCore
import SwiftUI

// Format 3's own pieces (Encrypted canvas JrubHFFVtgRHFCGp1ePTqq, approved boards): the card on my
// other devices (encrypted/card, -remove), the line for earlier messages (encrypted/new-list,
// -thread, -asked), the subline of Notes to myself (encrypted/notes-self). Only my own devices are
// named; never a key or an id as text.

enum Enc3Words {
    /// "Encrypted for your 2 devices"; one device: "Encrypted for your device".
    static func notesLine(_ n: Int) -> String { n <= 1 ? "Encrypted for your device" : "Encrypted for your \(n) devices" }

    /// "Safari on iPhone or Safari on Mac" (and "…, A or B" past two).
    static func either(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "another of your devices" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
    }
    static func both(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "Your other devices" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// "Today 9:40", "Yesterday 18:02", "12 Nov".
    static func when(_ at: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(at))
        if Calendar.current.isDateInToday(d) { return "Today " + Format.time(at) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday " + Format.time(at) }
        return Format.day(at)
    }

    /// The headline of Who can read this.
    static func whoHeadline(notes: Bool, others: [String], group: String?) -> String {
        if notes { return "Only your devices can read your notes." }
        if others.count == 1 { return "Only \(others[0])’s devices and yours can read this conversation." }
        return "Only the devices of these \(others.count + 1) people can read \(group ?? "this conversation")."
    }
}

/// "Chrome on Android was added · Today 9:40": Share earlier messages, or Remove this device
/// (asks first). Answered once for every conversation and every device.
struct Enc3DeviceCard: View {
    @EnvironmentObject var model: AppModel
    let added: Enc3Added
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: added.kind.icon).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(added.name) was added").font(.subheadline.weight(.semibold))
                    Text(Enc3Words.when(added.at)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(added.reader ? "It can read your new messages. If this wasn't you, remove it."
                 : "Share your earlier messages with it? If this wasn't you, remove it.")
                .font(.subheadline)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if added.reader {
                Button("OK") { model.enc3Ok(added) }
                    .buttonStyle(.brand).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("enc3-ok")
            } else {
                BusyButton("Share earlier messages") { error = await model.enc3Share(added) }
                    .buttonStyle(.brand).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("enc3-share")
            }
            Button("Remove this device", role: .destructive) { removing = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("enc3-remove")
        }
        .padding(14)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("enc3-card")
        .alert("Remove \(added.name)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { error = await model.enc3Remove(added) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's signed out at once and can't read new messages.\n\nIf you didn't add it, someone used a code sent to your e-mail. Change your e-mail password.")
        }
        .task { if model.launch.screen == "e3cardremove" { try? await Task.sleep(nanoseconds: 1_500_000_000); removing = true } }
    }
}

/// "Earlier messages are on your other devices · Ask for them"; after asking, where they will come
/// from and "Your devices ›". At the bottom of Messages and above the history of a conversation.
struct Enc3EarlierLine: View {
    @EnvironmentObject var model: AppModel
    /// Messages' row says which devices can share; a conversation's line is shorter
    var list = false
    @State private var devices = false

    var body: some View {
        let st = model.sealed
        VStack(spacing: 4) {
            if st.enc3Asked > 0 {
                Text("Asked your other devices").font(.subheadline.weight(.semibold))
                Text("Earlier messages arrive here when \(Enc3Words.either(st.otherDevices)) is next open.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Your devices ›") { devices = true }
                    .font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                    .accessibilityIdentifier("enc3-devices")
            } else {
                Text("Earlier messages are on your other devices").font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                if list {
                    Text("\(Enc3Words.both(st.otherDevices)) can share them with this one.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                BusyButton("Ask for them") { await model.enc3Ask() }
                    .font(.footnote.weight(.semibold)).buttonStyle(.bordered)
                    .accessibilityIdentifier("enc3-ask")
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .navigationDestination(isPresented: $devices) { DevicesView() }
        .accessibilityIdentifier("enc3-earlier")
    }
}

/// Notes to myself's header: its name with the lock, "Encrypted for your N devices" under it; a tap
/// opens Who can read this.
struct Enc3NotesHeader: View {
    @EnvironmentObject var model: AppModel
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text("Notes to myself").font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(Enc3Words.notesLine(model.sealed.myDevices.count)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notes to myself, \(Enc3Words.notesLine(model.sealed.myDevices.count)). See who can read it.")
        .accessibilityIdentifier("enc3-notes-header")
    }
}

/// The warnings that don't go away (encrypted/edge-two-lists, edge-strange-device) and the line for a
/// 21st device (encrypted/edge-21st): on top of Messages, with the way to my devices.
struct Enc3Warning: View {
    @EnvironmentObject var model: AppModel
    @State private var devices = false

    var body: some View {
        let st = model.sealed
        let (title, line): (String, String) =
            st.enc3Fork ? ("Your belfry gave out two different lists of your devices",
                           "This should never happen. It can mean someone is trying to add a device that reads your messages. Until a steward has looked, check Your devices.")
            : st.enc3Strange ? ("A device that was never on your list got your messages",
                                "Someone may be reading what is sent to you. Tell the belfry’s admins; check Me › Devices.")
            : ("You have 20 devices signed in", "Remove one to read encrypted messages here.")
        let warn = st.enc3Fork || st.enc3Strange
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: warn ? "exclamationmark.triangle.fill" : "iphone.slash")
                .font(.subheadline.weight(.semibold)).foregroundStyle(warn ? Color.red : Color.primary)
            Text(line).font(.subheadline).foregroundStyle(.secondary)
            Button("Your devices ›") { devices = true }
                .font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                .accessibilityIdentifier("enc3-warning-devices")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((warn ? Color.red : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .navigationDestination(isPresented: $devices) { DevicesView() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("enc3-warning")
    }
}
