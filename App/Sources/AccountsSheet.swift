import BelfryCore
import SwiftUI

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
                        picture: "", open: true, initial: model.me)
                }
                ForEach(model.accounts.accounts) { a in
                    let isOpen = !model.isDemo && a.slot == Keychain.slot
                    Button {
                        if !isOpen { model.switchAccount(a.slot) }
                        if !pushed { dismiss() }
                    } label: {
                        row(name: a.name.isEmpty ? a.domain : a.name, line: a.line, picture: a.picture, open: isOpen, initial: a.pubkey ?? a.domain)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOpen ? .isSelected : [])
                }
            } header: { Text("On this phone") } footer: {
                Text("Each account has its own messages and notifications. One is open at a time.")
            }
            Section {
                Button {
                    if !pushed { dismiss() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (pushed ? 0 : 0.4)) { model.startAddingAccount() }
                } label: { twoLines("person.crop.circle.badge.plus", "Add an account", "Another belfry, or another you here") }
                    .buttonStyle(.plain)
                Button { hideKeyboard(); scanning = true } label: { twoLines("qrcode.viewfinder", "Scan an invite", nil) }
                    .buttonStyle(.plain)
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

    private func row(name: String, line: String, picture: String, open: Bool, initial: String) -> some View {
        HStack(spacing: 12) {
            AccountFace(name: name, picture: picture, seed: initial)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
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
