import BelfryCore
import SwiftUI

// iPhone, Navigation v2 (canvas nav2/channel, approved 2026-11-22; Xavier: "keep the bottom
// buttons but remove the + from there as it is redundant, replace it with Messages"): a bottom
// bar Today · Calendar · Messages · Groups · Town, from you to others. Messages and Groups carry
// red counts; Town has none. Creating is the ＋ by the message box (and the ＋ of GROUPS and
// CHANNELS in the menu). Each place has its own navigation stack; the bar sits at the root of
// each (a safe-area inset of the root screen), so a pushed chat, event or profile covers it, and
// it hides while the keyboard is up. Guests: Today · Calendar · Town. iPad keeps the split view.

enum AppTab: String, CaseIterable, Hashable {
    // "home" stays the stored name of Today (belfry-last-tab)
    case home, calendar, messages, groups, town

    var title: String {
        switch self {
        case .home: return "Today"
        case .calendar: return "Calendar"
        case .messages: return "Messages"
        case .groups: return "Groups"
        case .town: return "Town"
        }
    }

    var icon: String {
        switch self {
        case .home: return "sun.max"
        case .calendar: return "calendar"
        case .messages: return "bubble.left.and.bubble.right"
        case .groups: return "person.2"
        case .town: return "building.columns"
        }
    }

    /// The selected place's symbol (the calendar has no filled one).
    var selectedIcon: String { self == .calendar ? "calendar" : icon + ".fill" }
}

/// The floating bar: five places (members), three (guests).
struct TabBar: View {
    @EnvironmentObject var model: AppModel
    static let height: CGFloat = 66

    var body: some View {
        let guest = model.derive.amGuest || model.guestReading
        HStack(spacing: 0) {
            item(.home)
            item(.calendar)
            if !guest {
                item(.messages)
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
        let n = count(t)
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
                    .overlay(alignment: .topTrailing) { badge(n) }
                Text(t.title).font(.caption2.weight(on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Color.brand : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(on ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(n > 0 ? "\(t.title), \(n) new" : t.title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("tab-" + t.rawValue)
    }

    /// Red counts: Messages (conversations with new messages), Groups (my groups with news).
    private func count(_ t: AppTab) -> Int {
        switch t {
        case .messages: return model.unreadDMs
        case .groups: return model.groupsUnread
        default: return 0
        }
    }

    @ViewBuilder private func badge(_ n: Int) -> some View {
        if n > 0 {
            Text(n > 99 ? "99+" : "\(n)")
                .font(.system(size: 11, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 17, minHeight: 17)
                .background(Color.red, in: Capsule())
                .offset(x: 12, y: -6)
                .fixedSize()
                .accessibilityHidden(true)
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
            .drawerItem()
    }
}

extension View {
    func placeChrome(_ title: String) -> some View { modifier(PlaceChrome(title: title)) }
    /// Home (2026-11-17): ☰ top left (the Town drawer), the date as the list's first row instead
    /// of a navigation title ("Home" stays for the back buttons of pushed screens, not shown).
    func homeChrome() -> some View {
        navigationTitle("Today")
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
            .navigationDestination(for: EventRoute.self) { r in EventScreen(key: r.key, ticket: r.ticket, focus: r.focus) }
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
    case messages, mentions, todos, members, charter, me, settings, archived, events, channels, accounts, about, almostIn, devices, linked, addChannel

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .messages: MessagesView()
        case .devices: DevicesView()
        // screenshots: "iPad is linked" (the demo has no address of its own to link)
        case .linked:
            if let a = MemberAddress.parse("sam@demo.belfry.sh") { LinkDeviceScreen(address: a, linked: "iPad") }
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
        case .addChannel: AddChannelScreen()
        }
    }
}

extension View {
    func placeDestinations() -> some View { modifier(PlaceDestinations()) }
}
