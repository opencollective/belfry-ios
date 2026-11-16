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
}

/// The floating bar: four places and the ＋ in the middle (members).
struct TabBar: View {
    @EnvironmentObject var model: AppModel

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
            if model.tab == t { model.tabReselected += 1 } else { model.tab = t }
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
                    .opacity(keyboard ? 0 : 1)
                    .frame(height: keyboard ? 0 : nil)
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

/// The belfry's mark and name at the top of Home, Calendar and Groups: it switches belfry
/// (the accounts on this phone).
struct BelfrySwitchButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { hideKeyboard(); model.showAccounts = true } label: {
            HStack(spacing: 6) {
                BelfryLogo(size: 24)
                Text(model.config.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.config.name): switch belfry or account")
        .accessibilityIdentifier("belfry-switch")
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

/// A place's large title screen with the belfry's name above it (Home, Calendar, Groups).
struct PlaceChrome: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .topBarLeading) { BelfrySwitchButton() } }
    }
}

extension View {
    func placeChrome(_ title: String) -> some View { modifier(PlaceChrome(title: title)) }
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
    }
}

/// Screens a place pushes by name (the Home tiles, the drawer's town rows, the person row).
enum PlaceRoute: Hashable {
    case messages, mentions, todos, gates, charter, me, settings, archived, events

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .messages: MessagesView()
        case .mentions: MentionsView()
        case .todos: MyTodosView()
        case .gates: MembersDirectory()
        case .charter: CharterView()
        case .me: AccountSheet(pushed: true)
        case .settings: BelfrySettings(screen: true)
        case .archived: ArchivedScreen()
        case .events: EventsScreen()
        }
    }
}

extension View {
    func placeDestinations() -> some View { modifier(PlaceDestinations()) }
}
