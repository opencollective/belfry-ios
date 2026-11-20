import BelfryCore
import SwiftUI
import UserNotifications

// The accounts on this phone (SPEC 19.24), behind "you" at the drawer's bottom: each account
// (face, name, name@domain or "Guest · community"; a check on the open one), Add an account
// (the sign-in over the app, the open account untouched until the new one is in), Me, and
// "About Belfry" as the last row (board home/accounts).

struct AccountsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// A screen pushed on the place on screen (iPhone; board home/accounts), not the iPad's sheet.
    var pushed = false
    let openMe: () -> Void
    /// `-screen about`: About Belfry pushed at once, for its screenshot (the sheet).
    @State private var about = false
    @State private var scanning = false
    /// Slots of the other accounts that have news (a red dot on their row).
    @State private var news: Set<String> = []

    var body: some View {
        if pushed {
            list
        } else {
            NavigationStack {
                list
                    .navigationDestination(isPresented: $about) { AboutScreen(close: { dismiss() }) }
                    .onAppear { if model.launch.screen == "about" { about = true } }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .presentationDetents([.medium, .large])
            .solidSheet()
            .presentationDragIndicator(.visible)
        }
    }

    private var list: some View {
        let _ = model.version
        return List {
            Section {
                if model.isDemo {
                    row(name: model.realName(model.me).isEmpty ? "You" : model.realName(model.me), line: "Demo · " + model.config.name,
                        picture: "", open: true, initial: model.me, news: false)
                }
                ForEach(model.accounts.accounts) { a in
                    let isOpen = !model.isDemo && a.slot == Keychain.slot
                    Button {
                        if !isOpen { model.switchAccount(a.slot) }
                        if !pushed { dismiss() }
                    } label: {
                        row(name: a.name.isEmpty ? a.domain : a.name, line: a.placeLine, picture: a.picture, open: isOpen, initial: a.pubkey ?? a.domain,
                            news: !isOpen && news.contains(a.slot))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOpen ? .isSelected : [])
                }
            } header: { Text("On this phone") } footer: {
                Text("Each account has its own messages and notifications. One is open at a time; a red dot means news in another one.")
            }
            .task { news = await AccountsSheet.slotsWithNews() }
            Section {
                Button {
                    if !pushed { dismiss() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (pushed ? 0 : 0.4)) { model.startAddingAccount() }
                } label: { twoLines("person.crop.circle.badge.plus", "Add an account", "Another belfry, or another you here") }
                    .buttonStyle(.plain)
                Button { hideKeyboard(); scanning = true } label: { twoLines("qrcode.viewfinder", "Scan an invite", nil) }
                    .buttonStyle(.plain)
                // the open account on another device (board home/link-device): a member with an address here
                if let a = model.linkAddress {
                    if pushed {
                        NavigationLink { LinkDeviceScreen(address: a) } label: { twoLines("iphone.and.arrow.forward", "Link a phone or tablet", "Log in there as \(a.description)") }
                            .accessibilityIdentifier("link-device-row")
                    } else {
                        NavigationLink { LinkDeviceScreen(address: a) } label: { twoLines("iphone.and.arrow.forward", "Link a phone or tablet", "Log in there as \(a.description)") }
                    }
                }
            }
            Section {
                if pushed {
                    NavigationLink(value: PlaceRoute.me) { twoLines("person.crop.circle", "Me", "Profile, notifications, devices, sign out") }
                    NavigationLink(value: PlaceRoute.about) { twoLines("info.circle", "About Belfry", "Version \(AboutScreen.version)") }
                        .accessibilityIdentifier("about-row")
                } else {
                    Button(action: openMe) { twoLines("person.crop.circle", "Me", "Profile, notifications, devices, sign out") }
                        .buttonStyle(.plain)
                    NavigationLink { AboutScreen(close: { dismiss() }) } label: { twoLines("info.circle", "About Belfry", "Version \(AboutScreen.version)") }
                        .accessibilityIdentifier("about-row")
                }
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) {
            InviteScanner { url in
                scanning = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.handle(url: url) }
            }
        }
    }

    private func twoLines(_ icon: String, _ title: String, _ detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// The accounts with a notification still in Notification Centre (each carries its account's
    /// slot, set by the notification service).
    static func slotsWithNews() async -> Set<String> {
        let list = await UNUserNotificationCenter.current().deliveredNotifications()
        return Set(list.compactMap { $0.request.content.userInfo["account"] as? String })
    }

    private func row(name: String, line: String, picture: String, open: Bool, initial: String, news: Bool) -> some View {
        HStack(spacing: 12) {
            AccountFace(name: name, picture: picture, seed: initial)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if news { Circle().fill(.red).frame(width: 10, height: 10).accessibilityLabel("News") }
            if open { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand).accessibilityLabel("Open") }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// An account's face without its store: the saved picture, else its first letter.
struct AccountFace: View {
    let name: String
    let picture: String
    let seed: String
    var body: some View {
        ZStack {
            Circle().fill(color)
            Text(String((name.isEmpty ? "?" : name).prefix(1)).uppercased()).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            if picture.hasPrefix("https://"), let u = URL(string: picture) {
                CachedImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear }.clipShape(Circle())
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    private var color: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink, .green, .purple, .brown]
        let n = seed.utf8.prefix(6).reduce(0) { $0 &+ Int($1) }
        return palette[n % palette.count]
    }
}

extension AppModel {
    func startAddingAccount() {
        hideKeyboard()
        signInError = nil
        signInNote = nil
        addingAccount = true
    }

    func cancelAddingAccount() {
        nativeFlow.cancel()
        pendingCode = nil
        signInError = nil
        addingAccount = false
    }
}

extension AppModel {
    /// The open account's address here, when it has one a login link can carry (a member's
    /// `username@domain`; never a guest, never the demo).
    var linkAddress: MemberAddress? {
        guard !isDemo, !derive.amGuest, !guestReading, let a = accounts.open?.address, let m = MemberAddress.parse(a),
              m.domain == config.domain.lowercased(), LoginLink.isUsername(m.name) else { return nil }
        return m
    }
}

/// "Link a phone or tablet" (board home/link-device; SPEC 19.56): the QR code of
/// https://chat.<domain>/login/<username> for the open account. Nothing secret is in it: the
/// other device asks for the 6-digit code mailed to this account.
struct LinkDeviceScreen: View {
    @Environment(\.dismiss) private var dismiss
    let address: MemberAddress
    /// The device that scanned the code and is in ("iPad"): the confirmation (board
    /// messages/encryption-link-qr). Set by the demo only until the lead's contract says how
    /// this device learns it.
    var linked: String?

    private var link: String { "https://chat.\(address.domain)/login/\(address.name)" }

    var body: some View {
        if let linked { done(linked) } else { code }
    }

    private func done(_ device: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("\(device) is linked").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text("It can read your conversations, including earlier ones.").multilineTextAlignment(.center)
            Text("Scanning your code was the confirmation: nothing more to allow.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Spacer()
            // back to Accounts
            Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.brand).controlSize(.large)
                .accessibilityIdentifier("link-done")
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .navigationTitle("Link a phone or tablet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var code: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    if let img = QR.image(link) {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel("QR code to log in as \(address.description)")
                    }
                    Text(link).font(.footnote.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Scan this with the Belfry app on your other phone or tablet (Accounts › Scan an invite, or its camera) to log in there as \(address.description). For security it asks for the 6-digit code we send to your e-mail: nothing secret is in this code.")
            }
            Section { CopyRow(text: link, title: "Copy link") }
        }
        .navigationTitle("Link a phone or tablet")
        .navigationBarTitleDisplayMode(.inline)
    }
}
