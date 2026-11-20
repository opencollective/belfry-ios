import BelfryCore
import SwiftUI

// iPhone, 2026-11-16 (the owner approved the canvas "One belfry, five places"): a bottom bar
// Home · Calendar · Create (＋) · Groups · Town. Each place has its own navigation stack; the bar
// sits at the root of each (a safe-area inset of the root screen), so a pushed chat, event or
// profile covers it and it slides away with the root, and it hides while the keyboard is up.
// Guests: Home · Calendar · Town (no Create, no Groups). iPad keeps the split view.

enum AppTab: String, CaseIterable, Hashable {
    case home, calendar, groups, town

    var title: String {
        switch self {
        case .home: return "Home"
        case .calendar: return "Calendar"
        case .groups: return "Groups"
        case .town: return "Town"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .calendar: return "calendar"
        case .groups: return "person.2"
        case .town: return "building.columns"
        }
    }

    /// The selected place's symbol (the calendar has no filled one).
    var selectedIcon: String { self == .calendar ? "calendar" : icon + ".fill" }
}

/// The floating bar: four places and the ＋ in the middle (members).
struct TabBar: View {
    @EnvironmentObject var model: AppModel
    static let height: CGFloat = 66

    var body: some View {
        let guest = model.derive.amGuest || model.guestReading
        HStack(spacing: 0) {
            item(.home)
            item(.calendar)
            if !guest {
                Button {
                    hideKeyboard()
                    model.createFirst = model.tab == .calendar ? .event : model.tab == .groups ? .group : .message
                    model.showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 52, height: 52)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Create")
                .accessibilityIdentifier("tab-create")
                item(.groups)
            }
            item(.town)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
    }

    private func item(_ t: AppTab) -> some View {
        let on = model.tab == t
        return Button {
            if t == .town, !(model.derive.amGuest || model.guestReading) {
                // Town always opens the belfry's main channel, never the last open one; a second
                // tap there goes to the newest message
                model.townTapOnTown = model.tab == .town
                if model.tab != .town { model.tab = .town }
                model.townTapped += 1
            } else if model.tab == t { model.tabReselected += 1 } else { model.tab = t }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: on ? t.selectedIcon : t.icon).font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                    .overlay(alignment: .topTrailing) { badge(t) }
                Text(t.title).font(.caption2.weight(on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Color.brand : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(on ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("tab-" + t.rawValue)
    }

    @ViewBuilder private func badge(_ t: AppTab) -> some View {
        if t == .home, model.homeCount > 0 {
            Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: 6, y: -2).accessibilityHidden(true)
        }
    }
}

/// The bar under a place's root screen; gone while the keyboard is up.
struct TabBarInset: ViewModifier {
    @State private var keyboard = false
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TabBar()
                    // fixed in both directions (CLAUDE.md layout rules): nothing around the
                    // chat's composer measures the bar
                    .frame(height: keyboard ? 0 : TabBar.height)
                    .frame(maxWidth: .infinity)
                    .opacity(keyboard ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!keyboard)
                    .accessibilityHidden(keyboard)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
    }
}

extension View {
    /// Only on iPhone (the compact layout): the root of a place gets the bar.
    func tabBarInset(_ on: Bool = true) -> some View { modifier(OptionalTabBar(on: on)) }
}

private struct OptionalTabBar: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.modifier(TabBarInset()) } else { content }
    }
}

/// The belfry's logo from its branding, else the Arms.
struct BelfryLogo: View {
    @EnvironmentObject var model: AppModel
    var size: CGFloat = 24
    var body: some View {
        if let logo = model.config.branding?.logo, !logo.isEmpty, let url = URL(string: logo), logo.hasPrefix("https://") {
            CachedImage(url: url) { $0.resizable().scaledToFit() } placeholder: { BelfryMark() }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            BelfryMark().frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

/// A place's large title screen with ☰ top left (Calendar, Groups): the same Town drawer as Home
/// (2026-11-17, for consistency with Home; it replaced the belfry's name with ⌄). Switching
/// belfry or account is on the person row at the drawer's bottom.
struct PlaceChrome: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
    }
}

extension View {
    func placeChrome(_ title: String) -> some View { modifier(PlaceChrome(title: title)) }
    /// Home (2026-11-17): ☰ top left (the Town drawer), the date as the list's first row instead
    /// of a navigation title ("Home" stays for the back buttons of pushed screens, not shown).
    func homeChrome() -> some View {
        navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                ToolbarItem(placement: .topBarLeading) { DrawerButton() }
            }
    }
}

/// A group (or proposal) route's chat, pushed over a place (Home, Groups, Calendar): the chat,
/// or "deleted"; a group I'm not in shows its page (Join / Apply).
struct ChatRoute: Hashable { let id: String; var focus: String? = nil }

/// The routes every place's stack knows.
struct PlaceDestinations: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: ProfileKey.self) { k in ProfileView(pubkey: k.pubkey, pushed: true, group: k.group) }
            .navigationDestination(for: EventRoute.self) { r in EventScreen(key: r.key, ticket: r.ticket) }
            .navigationDestination(for: GroupRoute.self) { r in GroupPage(id: r.id) }
            .navigationDestination(for: ChannelRoute.self) { r in ChannelScreen(id: r.id, pushed: true) }
            .navigationDestination(for: ChatRoute.self) { r in ChannelScreen(id: r.id, focus: r.focus, pushed: true) }
            .navigationDestination(for: PlaceRoute.self) { r in r.view }
            .navigationDestination(for: ConvRoute.self) { r in ConversationView(conv: r.conv) }
            .navigationDestination(for: TodoKey.self) { k in TodoScreen(key: k) }
    }
}

/// Screens a place pushes by name (the Home tiles, the drawer's town rows, the person row).
enum PlaceRoute: Hashable {
    case messages, mentions, todos, members, charter, me, settings, archived, events, channels, accounts, about, almostIn

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .messages: MessagesView()
        case .mentions: MentionsView()
        case .todos: MyTodosView()
        case .members: MembersDirectory()
        case .charter: CharterView()
        case .me: AccountSheet(pushed: true)
        case .accounts: AccountsSheet(pushed: true, openMe: {})
        case .about: AboutScreen(close: {})
        case .almostIn: AlmostInScreen()
        case .settings: BelfrySettings(screen: true)
        case .archived: ArchivedScreen()
        case .events: EventsScreen()
        case .channels: ChannelsSettings()
        }
    }
}

extension View {
    func placeDestinations() -> some View { modifier(PlaceDestinations()) }
}
