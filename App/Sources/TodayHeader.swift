import BelfryCore
import SwiftUI

// Today says which belfry you're in and who you are there (canvas Home v13+, boards
// home/today-belfry, -dark, -tap; Xavier, 25 Nov): in the header, level with ☰ and centred, the
// belfry's mark (its logo, else the crest), its name with ⌄, and under it your address here. A tap
// drops the accounts menu: one row per account (mark, belfry, your address there · role), the open
// one checked; then Add an account and Accounts ›. Switching lands on that belfry's Today
// (switch-3). No red dot yet: this phone keeps no unread state of the accounts that are not open,
// and nothing polls them (Xavier hasn't decided on it).

struct TodayBelfryHeader: View {
    @EnvironmentObject var model: AppModel
    @State private var switching: String?

    var body: some View {
        let address = model.isDemo ? "sam@demo.belfry.sh" : (model.derive.myAddress ?? "")
        Menu {
            Section {
                ForEach(rows, id: \.slot) { a in
                    Button {
                        guard a.slot != currentSlot else { return }
                        switching = a.slot
                        model.switchToToday(a.slot)
                    } label: {
                        Text(a.community.isEmpty ? a.domain : a.community)
                        Text(sub(a))
                        if a.slot == currentSlot { Image(systemName: "checkmark") }
                    }
                }
            }
            Section {
                Button { model.addingAccount = true } label: { Label("Add an account", systemImage: "plus") }
                Button { model.showAccounts = true } label: { Label("Accounts", systemImage: "person.2") }
            }
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    BelfryCrest(logo: model.config.branding?.logo ?? "").frame(width: 20, height: 22)
                    Text(model.config.name).font(.headline).lineLimit(1)
                    if switching != nil { ProgressView().controlSize(.mini) } else {
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if !address.isEmpty {
                    Text(address).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 240)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(model.config.name): switch account or belfry")
        .accessibilityIdentifier("today-belfry")
        .onChange(of: model.version) { _, _ in if switching == currentSlot { switching = nil } }
    }

    private var currentSlot: String { model.accounts.current ?? "" }

    /// The accounts on this phone; the demo shows the board's three.
    private var rows: [AccountEntry] {
        if model.isDemo {
            var a = AccountEntry(slot: "", domain: "demo.belfry.sh", pubkey: nil)
            a.community = "Riverside Commons"; a.address = "sam@demo.belfry.sh"; a.role = "Steward"
            var b = AccountEntry(slot: "demo-2", domain: "hillsidemakers.example", pubkey: nil)
            b.community = "Hillside Makers"; b.address = "sam@hillsidemakers.example"; b.role = "Member"
            var c = AccountEntry(slot: "demo-3", domain: "demo.belfry.sh", pubkey: nil)
            c.community = "Riverside Commons"; c.address = "repaircafe@demo.belfry.sh"; c.guest = true
            return [a, b, c]
        }
        return model.accounts.accounts
    }

    /// "sam@demo.belfry.sh · Steward" (a guest: "· Guest").
    private func sub(_ a: AccountEntry) -> String {
        let role = a.guest ? "Guest" : (a.role ?? "")
        return [a.address.isEmpty ? a.domain : a.address, role].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The belfry's mark: its logo when it has one, else the crest.
struct BelfryCrest: View {
    let logo: String
    var body: some View {
        if let u = URL(string: logo), !logo.isEmpty {
            CachedImage(url: u) { phase in
                if let i = phase.image { i.resizable().scaledToFit() } else { BelfryMark() }
            }
            .accessibilityHidden(true)
        } else {
            BelfryMark().accessibilityHidden(true)
        }
    }
}

extension AppModel {
    /// Another account, landing on its Today (canvas switch-3), whatever screen was open.
    func switchToToday(_ slot: String) {
        if isDemo { tab = .home; return }
        switchAccount(slot)
    }
}
