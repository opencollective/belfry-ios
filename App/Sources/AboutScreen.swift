import BelfryCore
import SwiftUI

// About Belfry (board home/about), pushed from Accounts: the mark, "Belfry for iPhone", the
// version, where new builds arrive, belfry.sh, and the belfry of Belfry in three states: join it
// (the Apply form for belfry.sh), switch to the account that is in it, or open its Townsquare.

struct AboutScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    @Environment(\.openURL) private var openURL
    /// Closes Accounts (the sheet this screen is pushed in).
    let close: () -> Void
    @State private var home: BelfryConfig?
    @State private var sent = false
    @State private var error: String?

    static let homeDomain = "belfry.sh"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// This account is in the belfry of Belfry.
    private var here: Bool { !model.isDemo && model.config.domain == AboutScreen.homeDomain }
    /// Another account on this phone that is.
    private var other: AccountEntry? {
        model.accounts.accounts.first { $0.domain == AboutScreen.homeDomain && (model.isDemo || $0.slot != Keychain.slot) }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    BelfryMark().frame(width: 64, height: 70).accessibilityHidden(true)
                    Text("Belfry for iPhone").font(.title2.bold()).padding(.top, 10)
                    Text("Version \(AboutScreen.version)" + (AboutScreen.build.isEmpty ? "" : " (\(AboutScreen.build))"))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("about-version")
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                Button { openTestFlight() } label: {
                    row("arrow.down.circle", "Open TestFlight", "New builds arrive there")
                }
                .buttonStyle(.plain)
            } header: { Text("Updates") }
            Section {
                Button { if let u = URL(string: "https://\(AboutScreen.homeDomain)") { openURL(u) } } label: {
                    row("globe", AboutScreen.homeDomain, "The project’s website")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-website")
                SwiftUI.Group {
                    if here {
                        Button { close(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openChannel(generalId, nil) } } label: {
                            row("person.2", "The belfry of Belfry", "You’re in it with this account")
                        }
                        .buttonStyle(.plain)
                    } else if let other {
                        Button { model.switchAccount(other.slot); close() } label: {
                            row("person.2", "Switch to the belfry of Belfry", other.name.isEmpty ? AboutScreen.homeDomain : other.name, chevron: false)
                        }
                        .buttonStyle(.plain)
                    } else {
                        BusyButton { await join() } label: {
                            row("person.2", "Join the belfry of Belfry", "Apply to join \(AboutScreen.homeDomain)")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .accessibilityIdentifier("about-join")
            } header: { Text("Belfry") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let error { Text(error).foregroundStyle(.red) }
                    Text("Belfry is open source software a community runs on its own server.")
                }
            }
        }
        .navigationTitle("About Belfry")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $home) { c in
            ScrollView {
                SwiftUI.Group {
                    if sent {
                        ApplySentScreen { home = nil }
                    } else {
                        ApplyFormScreen(community: c, onSent: { sent = true }, onLogIn: {
                            close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.startAddingAccount() }
                        })
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String, chevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }

    /// The TestFlight app when it is on this phone, else its page.
    private func openTestFlight() {
        guard let app = URL(string: "itms-beta://"), let web = URL(string: "https://testflight.apple.com/") else { return }
        UIApplication.shared.open(app, options: [:]) { ok in if !ok { UIApplication.shared.open(web) } }
    }

    @MainActor private func join() async {
        error = nil
        sent = false
        if model.launch.screen != nil { home = .shot; return }
        do { home = try await Discovery.fetch(domain: AboutScreen.homeDomain) }
        catch { self.error = "No connection to \(AboutScreen.homeDomain). Try again." }
    }
}
