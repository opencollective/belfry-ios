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
    @State private var open = false

    /// Three native ways to show the switcher (Xavier, 26 Nov: the system menu "is ugly, very far
    /// from the canvas"); the demo screens todaysheet / todaypopover / todaymenu2 show each, until
    /// he picks one. Elsewhere: the menu as before.
    enum Style { case menu, sheet, popover, menu2 }
    private var style: Style {
        switch model.launch.screen {
        case "todaysheet": return .sheet
        case "todaypopover": return .popover
        case "todaymenu2": return .menu2
        default: return .menu
        }
    }

    var body: some View {
        SwiftUI.Group {
            switch style {
            case .menu: oldMenu
            case .menu2: menu2
            case .sheet:
                Button { open = true } label: { label }.buttonStyle(.plain)
                    .sheet(isPresented: $open) {
                        AccountSwitchSheet(rows: rows, current: currentSlot, pick: pick)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    }
            case .popover:
                Button { open = true } label: { label }.buttonStyle(.plain)
                    .popover(isPresented: $open, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                        AccountSwitchCard(rows: rows, current: currentSlot, pick: pick)
                            .presentationCompactAdaptation(.popover)
                    }
            }
        }
        .accessibilityLabel("\(model.config.name): switch account or belfry")
        .accessibilityIdentifier("today-belfry")
        .onChange(of: model.version) { _, _ in if switching == currentSlot { switching = nil } }
        .task {
            // screenshots: the switcher open (a sheet or a popover opens without a touch)
            if style == .sheet || style == .popover { try? await Task.sleep(nanoseconds: 1_200_000_000); open = true }
        }
    }

    private func pick(_ p: AccountSwitchPick) {
        open = false
        switch p {
        case .account(let slot):
            guard slot != currentSlot else { return }
            switching = slot
            model.switchToToday(slot)
        case .add: model.addingAccount = true
        case .manage: model.showAccounts = true
        }
    }

    private var label: some View {
        let address = model.isDemo ? "sam@demo.belfry.sh" : (model.derive.myAddress ?? "")
        return VStack(spacing: 1) {
            HStack(spacing: 6) {
                BelfryCrest(logo: model.config.branding?.logo ?? "").frame(width: 20, height: 22)
                Text(model.config.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
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

    /// As shipped in 29927820.
    private var oldMenu: some View {
        Menu {
            Section {
                ForEach(rows, id: \.slot) { a in
                    Button { pick(.account(a.slot)) } label: {
                        Text(AccountSwitch.title(a))
                        Text(AccountSwitch.sub(a))
                        if a.slot == currentSlot { Image(systemName: "checkmark") }
                    }
                }
            }
            Section {
                Button { pick(.add) } label: { Label("Add an account", systemImage: "plus") }
                Button { pick(.manage) } label: { Label("Accounts", systemImage: "person.2") }
            }
        } label: { label }
    }

    /// The system menu, tidied: each belfry's tile as the row's icon, a short line that never wraps
    /// (role · domain), the open one picked like a Picker's checkmark.
    private var menu2: some View {
        Menu {
            Picker("Belfry", selection: Binding(get: { currentSlot }, set: { pick(.account($0)) })) {
                ForEach(rows, id: \.slot) { a in
                    Label {
                        Text(AccountSwitch.title(a))
                        Text(AccountSwitch.short(a))
                    } icon: { Image(uiImage: AccountSwitch.tileImage(a)) }
                    .tag(a.slot)
                }
            }
            .pickerStyle(.inline)
            Section {
                Button { pick(.add) } label: { Label("Add an account", systemImage: "person.crop.circle.badge.plus") }
                Button { pick(.manage) } label: { Label("Accounts", systemImage: "gearshape") }
            }
        } label: { label }
    }

    private var currentSlot: String { model.accounts.current ?? "" }

    /// The accounts on this phone; the demo shows the board's three and a long address.
    private var rows: [AccountEntry] {
        if model.isDemo {
            var a = AccountEntry(slot: "", domain: "demo.belfry.sh", pubkey: nil)
            a.community = "Riverside Commons"; a.address = "sam@demo.belfry.sh"; a.role = "Steward"
            var b = AccountEntry(slot: "demo-2", domain: "hillsidemakers.example", pubkey: nil)
            b.community = "Hillside Makers"; b.address = "sam@hillsidemakers.example"; b.role = "Member"
            var o = AccountEntry(slot: "demo-4", domain: "opensourcevillage.org", pubkey: nil)
            o.community = "Open Source Village"; o.address = "sam@opensourcevillage.org"; o.role = "Steward"
            var c = AccountEntry(slot: "demo-3", domain: "demo.belfry.sh", pubkey: nil)
            c.community = "Riverside Commons"; c.address = "repaircafe@demo.belfry.sh"; c.guest = true
            return [a, b, o, c]
        }
        return model.accounts.accounts
    }
}

enum AccountSwitchPick { case account(String), add, manage }

enum AccountSwitch {
    static func title(_ a: AccountEntry) -> String { a.community.isEmpty ? a.domain : a.community }
    static func role(_ a: AccountEntry) -> String { a.guest ? "Guest" : (a.role ?? "") }
    /// "sam@demo.belfry.sh · Steward"
    static func sub(_ a: AccountEntry) -> String {
        [a.address.isEmpty ? a.domain : a.address, role(a)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// "Steward · belfry.sh": short enough for a menu row
    static func short(_ a: AccountEntry) -> String {
        let who = a.address.split(separator: "@").first.map(String.init) ?? ""
        return [role(a), who.isEmpty ? a.domain : who + "@" + a.domain].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// A belfry's tile: the first letter on a colour of its own (from its domain), until belfries'
    /// logos are kept per account.
    static func color(_ a: AccountEntry) -> Color {
        let palette: [Color] = [.indigo, .orange, .teal, .pink, .green, .blue, .purple, .brown]
        let h = a.domain.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
    static func letter(_ a: AccountEntry) -> String { String(title(a).first ?? "B").uppercased() }
    @MainActor static func tileImage(_ a: AccountEntry) -> UIImage {
        let r = ImageRenderer(content: AccountTile(entry: a, size: 28))
        r.scale = 3
        return (r.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
    }
}

/// The belfry's tile in the switcher (a guest's account: a small badge).
struct AccountTile: View {
    let entry: AccountEntry
    var size: CGFloat = 32
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(AccountSwitch.color(entry).gradient)
            .frame(width: size, height: size)
            .overlay(Text(AccountSwitch.letter(entry)).font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// One account's row: its tile, the belfry, your address there · role on ONE line, a checkmark
/// on the open one.
struct AccountSwitchRow: View {
    let entry: AccountEntry
    let current: Bool
    var body: some View {
        HStack(spacing: 12) {
            AccountTile(entry: entry)
            VStack(alignment: .leading, spacing: 1) {
                Text(AccountSwitch.title(entry)).font(.body.weight(current ? .semibold : .regular)).foregroundStyle(.primary).lineLimit(1)
                Text(AccountSwitch.sub(entry)).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if current { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// A: a sheet from the bottom (medium height), like an account switcher in Mail or Instagram.
struct AccountSwitchSheet: View {
    let rows: [AccountEntry]
    let current: String
    let pick: (AccountSwitchPick) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows, id: \.slot) { a in
                        Button { pick(.account(a.slot)) } label: { AccountSwitchRow(entry: a, current: a.slot == current) }
                    }
                }
                Section {
                    Button { pick(.add) } label: { Label("Add an account", systemImage: "person.crop.circle.badge.plus") }
                    Button { pick(.manage) } label: {
                        HStack { Label("Accounts", systemImage: "gearshape"); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Switch belfry")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.primary)
        }
    }
}

/// B: a card hanging from the header (a popover kept as one on the phone): the board's shape.
struct AccountSwitchCard: View {
    let rows: [AccountEntry]
    let current: String
    let pick: (AccountSwitchPick) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.slot) { a in
                Button { pick(.account(a.slot)) } label: { AccountSwitchRow(entry: a, current: a.slot == current).padding(.horizontal, 16).padding(.vertical, 10) }
                    .buttonStyle(.plain)
                Divider().padding(.leading, 60)
            }
            Button { pick(.add) } label: {
                Label("Add an account", systemImage: "person.crop.circle.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().padding(.leading, 16)
            Button { pick(.manage) } label: {
                HStack { Label("Accounts", systemImage: "gearshape"); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                    .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .frame(width: 330)
        .padding(.vertical, 4)
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
