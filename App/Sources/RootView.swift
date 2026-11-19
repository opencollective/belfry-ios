import BelfryCore
import SwiftUI

// iPhone: the web's phone layout. The open channel (or Messages, @Mentions) fills the screen; ☰
// (or a swipe from the left edge) slides it to the right and shows the channel drawer under it:
// the belfry's name, Upcoming events, @Mentions, Direct messages, Public channels and Members
// only in the admins' order, and you at the bottom. iPad: the same list as a split view's sidebar.

enum SidebarItem: Hashable {
    case channel(String)
    case messages
    case mentions
    case requests
    case members
    case events
    case settings
    /// The archived channels and groups (the last row of the channel list, SPEC 19.30).
    case archived
    /// The charter's agreements (Town drawer, SPEC 19.32).
    case charter
}

extension SidebarItem {
    var key: String {
        switch self {
        case .channel(let id): return "c:" + id
        case .messages: return "messages"
        case .mentions: return "mentions"
        case .requests, .members: return "members"
        case .events: return "events"
        case .settings: return "settings"
        case .archived: return "archived"
        case .charter: return "charter"
        }
    }

    /// The screen a stored key names (a channel only while it is still there).
    init?(key: String, groups: [Channel]) {
        switch key {
        case "messages": self = .messages
        case "mentions": self = .mentions
        case "members": self = .members
        case "events": self = .events
        case "settings": self = .settings
        case "archived": self = .archived
        case "charter": self = .charter
        default:
            guard key.hasPrefix("c:") else { return nil }
            let id = String(key.dropFirst(2))
            guard groups.isEmpty || groups.contains(where: { $0.id == id }) else { return nil }
            self = .channel(id)
        }
    }
}

struct SearchTarget: Hashable { let channel: String; let message: String }
struct EventKey: Identifiable { let key: String; var id: String { key } }

/// Opens the channel drawer (iPhone); nil where there is none (iPad's sidebar is always there).
struct OpenDrawerKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var openDrawer: (() -> Void)? {
        get { self[OpenDrawerKey.self] }
        set { self[OpenDrawerKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selection: SidebarItem?
    @State private var newChannel = false
    /// The category a new channel goes into (the ＋ of a category header).
    @State private var newChannelCategory: String?
    @State private var account = false
    /// The accounts on this phone (behind "you" at the drawer's bottom, SPEC 19.24).
    @State private var switcher = false
    @State private var notifications = false
    @State private var applying = false
    @State private var focus: SearchTarget?
    @State private var visibility = NavigationSplitViewVisibility.automatic
    /// Town's stack (and the iPad's detail).
    @State private var path = NavigationPath()
    @State private var homePath = NavigationPath()
    @State private var calendarPath = NavigationPath()
    @State private var groupsPath = NavigationPath()
    @State private var drawer = false

    private var phone: Bool { hSize != .regular }
    /// The stack of the place on screen (Town's on iPad).
    private var current: Binding<NavigationPath> {
        guard phone else { return $path }
        switch model.tab {
        case .home: return $homePath
        case .calendar: return $calendarPath
        case .groups: return $groupsPath
        case .town: return $path
        }
    }

    private func push<V: Hashable>(_ v: V) { current.wrappedValue.append(v) }

    var body: some View {
        withSheets
            .fullScreenCover(item: $model.lightbox) { LightboxView(box: $0) }
            .sheet(isPresented: $model.joinAsked) { JoinSheet() }
            .sheet(isPresented: $newChannel) {
                NewChannelSheet(category: newChannelCategory) { id in
                    if phone { model.tab = .town }
                    selection = .channel(id)
                }
            }
            .sheet(isPresented: $account) { AccountSheet() }
            .sheet(item: $model.todoDraft) { t in CreateSheet(kind: .todo, parent: t.group, todoFrom: t) }
            .sheet(isPresented: $switcher) {
                AccountsSheet { switcher = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openMe() } }
            }
            .onChange(of: model.showAccounts) { _, on in if on { model.showAccounts = false; openAccounts() } }
            .onChange(of: model.showAlmostIn) { _, on in if on { model.showAlmostIn = false; closeDrawer(); push(PlaceRoute.almostIn) } }
            .sheet(isPresented: $model.showCreate) {
                CreateMenuSheet(start: model.tab == .town ? model.townChannel : generalId, first: model.createFirst) { id in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openFromCreate(id) }
                }
            }
            .fullScreenCover(isPresented: $model.addingAccount) {
                SignInView(domainHint: nil, onCancel: { model.cancelAddingAccount() })
            }
            .sheet(isPresented: $notifications) { NavigationStack { NotificationsView() } }
            .sheet(isPresented: $applying) { BecomeMemberSheet() }
            .sheet(isPresented: $model.showAddAgent) { AddAgentSheet() }
            .sheet(item: $model.fullMail) { FullMailSheet(ref: $0) }
            .fullScreenCover(isPresented: $model.welcomeShown) { WelcomeFlow() }
            // a new member's first minutes (web welcomeDue): checked on start and when a guest becomes a member
            .onChange(of: model.derive.amGuest) { _, _ in checkWelcome() }
            .onChange(of: model.charterRules.count) { _, _ in checkWelcome() }
            .task { try? await Task.sleep(nanoseconds: 1_500_000_000); checkWelcome() }
    }

    private func openChat(_ id: String, _ linked: String?) {
        closeDrawer()
        // a message link (board channels/message-link): a message of the feed is scrolled to; a
        // thread reply opens its thread; anything else says "This message isn't available"
        var message = linked
        if let mid = linked {
            switch model.derive.messagePlace(id, mid) {
            case .message: break
            case .reply(let root):
                message = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.openThread = ThreadRoute(group: id, root: root, focus: mid) }
            case .missing:
                message = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { model.missingMessage = id } }
            }
        }
        // a chat pushes over the place it was opened from (Home, Calendar, Groups)
        if phone && model.tab != .town {
            pushChat(id, message)
            return
        }
        focus = message.map { SearchTarget(channel: id, message: $0) }
        if selection == .channel(id) { path = NavigationPath() } else { selection = .channel(id) }
    }

    private var routed: some View {
        layout
        .environment(\.openChannel) { id, message in openChat(id, message) }
        // links in people's text (SPEC 19.36 note): this belfry's channel / guest / event links
        // open here, the rest in the browser
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "belfry-channel", let gid = url.pathComponents.last?.removingPercentEncoding { openChat(gid, nil); return .handled }
            if url.scheme == "belfry-event", let c = url.pathComponents.last?.removingPercentEncoding { model.openEvent = c; return .handled }
            if url.scheme == "belfry-user", let pk = url.pathComponents.last, isHex64(pk) { model.openProfile = pk; return .handled }
            switch Links.target(url, domain: model.config.domain) {
            case .channel(let gid): openChat(gid, nil); return .handled
            case .message(let gid, let mid): openChat(gid, mid); return .handled
            case .app: model.handle(url: url); return .handled
            case .browser: return .systemAction
            }
        })
        .onChange(of: model.pushRoute) { _, r in
            guard let r else { return }
            model.pushRoute = nil
            push(r)
        }
        .onChange(of: model.tabReselected) { _, _ in current.wrappedValue = NavigationPath(); closeDrawer() }
        .onChange(of: model.tab) { _, t in
            closeDrawer()
            if !model.isDemo { UserDefaults.standard.set(t.rawValue, forKey: AppModel.perAccount("belfry-last-tab")) }
        }
        .onChange(of: selection) { _, v in
            if case .channel(let id) = v { model.townChannel = id }
            path = NavigationPath()
            // offline first: the next start opens here, from disk, before any network work
            if let v, !model.isDemo { UserDefaults.standard.set(v.key, forKey: AppModel.perAccount("belfry-last-screen")) }
        }
        .onChange(of: model.messageAuthor) { _, pk in
            guard let pk else { return }
            model.messageAuthor = nil
            let conv = MailThreads.nostrConv(author: pk, pTags: [], me: model.me)
            if phone {
                // Messages and the conversation, pushed on the place on screen
                push(PlaceRoute.messages)
                push(ConvRoute(conv: conv))
                return
            }
            selection = .messages
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                var p = NavigationPath()
                p.append(ConvRoute(conv: conv))
                path = p
            }
        }
    }

    private var withSheets: some View {
        withLife
        // an event slides in on the main screen's stack (its screen: header, chat, photos, people)
        .onChange(of: model.openEvent) { _, k in
            guard let k else { return }
            model.openEvent = nil
            let ticket = model.openEventTicket
            model.openEventTicket = nil
            closeDrawer()
            push(EventRoute(key: k, ticket: ticket))
        }
        .sheet(item: Binding(get: { model.showEvents.map { EventKey(key: $0) } }, set: { model.showEvents = $0?.key })) { k in
            EventsList(channel: k.key.isEmpty ? nil : k.key)
        }
        // a group's page slides in on the main screen's stack, never a bottom sheet; an archived
        // group opens read only; a deleted one says so (SPEC 19.30)
        .onChange(of: model.openGroup) { _, id in
            guard let id else { return }
            model.openGroup = nil
            hideKeyboard()
            closeDrawer()
            if model.derive.isArchived(id) { push(ChannelRoute(id: id)) } else { push(GroupRoute(id: id)) }
        }
        // a profile slides in on the main screen's stack (Contacts), never a bottom sheet
        .onChange(of: model.openProfile) { _, pk in
            guard let pk else { return }
            model.openProfile = nil
            closeDrawer()
            push(ProfileKey(pubkey: pk))
        }
        .sheet(item: Binding(get: { model.guestReading ? nil : model.pendingInvite }, set: { if $0 == nil { model.pendingInvite = nil } })) { inv in
            JoinWithAccountSheet(invite: inv)
        }
    }

    private var withPush: some View {
        routed
        .onChange(of: model.pushOpen) { _, p in
            guard let p else { return }
            model.pushOpen = nil
            closeDrawer()
            if let id = p.channel {
                if phone { model.tab = .town }
                focus = p.message.map { SearchTarget(channel: id, message: $0) }
                if let root = p.thread { model.openThread = ThreadRoute(group: id, root: root) }
                if selection == .channel(id) { path = NavigationPath() } else { selection = .channel(id) }
            } else if phone {
                model.tab = .home
                homePath = NavigationPath()
                homePath.append(PlaceRoute.messages)
            } else {
                selection = .messages
            }
        }
        .onChange(of: model.joinedChannel) { _, id in
            guard let id else { return }
            model.joinedChannel = nil
            if phone { model.tab = .town }
            selection = .channel(id)
        }
    }

    private var withLife: some View {
        withPush
        // no keyboard over a sheet
        .onChange(of: model.openProfile) { _, v in if v != nil { hideKeyboard() } }
        .onChange(of: model.openEvent) { _, v in if v != nil { hideKeyboard() } }
        .onChange(of: model.joinAsked) { _, v in if v { hideKeyboard() } }
        .alert(model.website ?? "", isPresented: Binding(get: { model.website != nil }, set: { if !$0 { model.website = nil } })) {
            Button("OK") { model.website = nil }
        }
        .onAppear {
            if selection == nil, !model.isDemo, let k = UserDefaults.standard.string(forKey: AppModel.perAccount("belfry-last-screen")) {
                selection = SidebarItem(key: k, groups: model.groups)
            }
            if selection == nil { selection = firstChannel() }
            if !model.isDemo, let t = UserDefaults.standard.string(forKey: AppModel.perAccount("belfry-last-tab")).flatMap(AppTab.init(rawValue:)) {
                model.tab = t
            }
            if model.guestReading || model.derive.amGuest, model.tab == .groups { model.tab = .home }
            applyLaunchScreen()
            // a guest link's channel, set while the loading screen stood here
            if let id = model.joinedChannel { model.joinedChannel = nil; selection = .channel(id) }
        }
        .onChange(of: model.version) { _, _ in if selection == nil { selection = firstChannel() } }
    }

    @ViewBuilder private var layout: some View {
        if hSize == .regular {
            NavigationSplitView(columnVisibility: $visibility) {
                drawerList(inDrawer: false)
            } detail: {
                detail
            }
        } else {
            // only the place on screen is built (its stack's path is kept here): four lists in
            // the tree made every UI query of the tests time out
            SwiftUI.Group {
                switch model.tab {
                case .home:
                    // Home's ☰ opens the same Town drawer (2026-11-17)
                    DrawerContainer(open: $drawer, edgeSwipe: homePath.isEmpty) {
                        drawerList(inDrawer: true)
                    } main: {
                        NavigationStack(path: $homePath) { HomeView().tabBarInset().placeDestinations() }
                            .environment(\.openDrawer) { openDrawer() }
                    }
                case .calendar:
                    // Calendar and Groups have the same ☰ and drawer as Home (2026-11-17)
                    DrawerContainer(open: $drawer, edgeSwipe: calendarPath.isEmpty) {
                        drawerList(inDrawer: true)
                    } main: {
                        NavigationStack(path: $calendarPath) { CalendarView().tabBarInset().placeDestinations() }
                            .environment(\.openDrawer) { openDrawer() }
                    }
                case .groups:
                    DrawerContainer(open: $drawer, edgeSwipe: groupsPath.isEmpty) {
                        drawerList(inDrawer: true)
                    } main: {
                        NavigationStack(path: $groupsPath) { GroupsView().tabBarInset().placeDestinations() }
                            .environment(\.openDrawer) { openDrawer() }
                    }
                case .town:
                    DrawerContainer(open: $drawer, edgeSwipe: path.isEmpty) {
                        drawerList(inDrawer: true)
                    } main: {
                        detail.environment(\.openDrawer) { openDrawer() }
                    }
                }
            }
            .environment(\.openConversation) { conv in push(ConvRoute(conv: conv)) }
        }
    }

    /// A channel, group or event's chat pushed on the place on screen.
    private func pushChat(_ id: String, _ message: String?) {
        if Channel.typeOf(id) == .event, let e = model.derive.eventOfGroup(id), e.isNew {
            push(EventRoute(key: e.coord))
        } else {
            push(ChatRoute(id: id, focus: message))
        }
    }

    /// Create → Message: the channel with the keyboard up.
    private func openFromCreate(_ id: String) {
        model.focusComposer = id
        if phone && model.tab != .town { pushChat(id, nil) } else { selection = .channel(id) }
    }

    private func checkWelcome() {
        if !model.welcomeShown && model.welcomeDue() { hideKeyboard(); model.welcomeShown = true }
    }

    /// Accounts: a screen pushed on the place on screen (iPhone; rows open screens, never sheets),
    /// the sheet on iPad.
    private func openAccounts() {
        closeDrawer()
        if phone { push(PlaceRoute.accounts) } else { switcher = true }
    }

    /// Me: pushed on the place on screen (phone), the sheet on iPad.
    private func openMe() {
        closeDrawer()
        if phone { push(PlaceRoute.me) } else { account = true }
    }

    private var detail: some View {
        NavigationStack(path: $path) {
            SwiftUI.Group {
            switch selection {
            case .channel(let id):
                // an event's group opens as the event (Your events in the drawer)
                if Channel.typeOf(id) == .event, let e = model.derive.eventOfGroup(id), e.isNew {
                    EventScreen(key: e.coord, root: true).id(id)
                } else {
                    // the channel, or "This group has been deleted"
                    ChannelScreen(id: id, focus: focus?.channel == id ? focus?.message : nil)
                }
            case .messages: MessagesView()
            case .mentions: MentionsView()
            case .requests: MembersDirectory()
            case .members: MembersDirectory()
            case .events: EventsScreen()
            case .settings: BelfrySettings(screen: true)
            case .archived: ArchivedScreen()
            case .charter: CharterView().toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
            case nil: ContentUnavailableView("Pick a channel", systemImage: "number", description: Text("Your community's channels are in the list."))
                    .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
            }
            }
            .tabBarInset(phone)
            .placeDestinations()
        }
        .environment(\.openConversation) { conv in
            if phone { path.append(ConvRoute(conv: conv)); return }
            var p = NavigationPath()
            p.append(ConvRoute(conv: conv))
            path = p
        }
    }

    private func drawerList(inDrawer: Bool) -> some View {
        ChannelDrawer(current: model.tab != .town && phone ? nil : selection, inDrawer: inDrawer,
                      onHome: phone && model.tab == .home,
                      select: { item in
                          // from the drawer of Home, Calendar or Groups: the row opens in Town
                          if phone && model.tab != .town {
                              path = NavigationPath()
                              selection = item
                              model.tab = .town
                              return
                          }
                          if selection == item { path = NavigationPath() } else { selection = item }
                          closeDrawer()
                      },
                      today: {
                          homePath = NavigationPath()
                          if model.tab == .home { closeDrawer() } else { model.tab = .home }
                      },
                      newChannel: { hideKeyboard(); newChannelCategory = nil; newChannel = true },
                      newChannelIn: { c in hideKeyboard(); newChannelCategory = c; newChannel = true },
                      account: { hideKeyboard(); openAccounts() },
                      openMe: { hideKeyboard(); openMe() },
                      apply: { hideKeyboard(); applying = true },
                      open: { target in
                          focus = target
                          selection = .channel(target.channel)
                          closeDrawer()
                      })
    }

    private func openDrawer() {
        hideKeyboard()
        withAnimation(.snappy(duration: 0.25)) { drawer = true }
    }

    private func closeDrawer() {
        guard drawer else { return }
        withAnimation(.snappy(duration: 0.2)) { drawer = false }
    }

    /// Where the app opens: #general, else the first channel.
    private func firstChannel() -> SidebarItem? {
        let chans = model.groups.filter { $0.type == .channel }
        guard let g = chans.first(where: { $0.name == "general" }) ?? chans.first else { return nil }
        return .channel(g.id)
    }

    private func applyLaunchScreen() {
        // screenshots: the earlier screens are Town's; the places of the bottom bar have their own
        if model.launch.screen != nil { model.tab = .town }
        switch model.launch.guest {
        case "home": model.tab = .home
        case "calendar": model.tab = .calendar
        case "applied":
            model.tab = .home
            model.applyState = ApplyStatus(application: MyApplication(id: 1, state: "new", vouches: 1, needed: 2,
                                                                      vouchedBy: [.init(pubkey: Demo.signer("dev").pubkey, name: "Dev Patel")]),
                                           until: Int.now + 7 * 86400, accept: "vouches")
        case "apply":
            model.tab = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { applying = true }
        case "drawer":
            model.tab = .town
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
        case .some: model.tab = .town
        case nil: break
        }
        switch model.launch.screen {
        case "home", "homecalm": model.tab = .home
        case "calendar": model.tab = .calendar
        case "groups": model.tab = .groups
        case "groupsall":
            model.tab = .groups // GroupsView picks All from the launch screen
        case "create":
            model.tab = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.createFirst = .message; model.showCreate = true }
        case "town": selection = .channel(generalId)
        case "towndrawer":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
        case "mytodos":
            model.tab = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { homePath.append(PlaceRoute.todos) }
        case "charter": selection = .charter
        case "charterhome":
            model.tab = .home
        case "whoagreed": selection = .charter // CharterView opens the first rule's list
        case "agreement": selection = .charter // CharterView opens the new agreement form
        case "myprofile":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openProfile = model.me }
        case "addagent":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openProfile = model.me } // ProfileView opens the sheet
        case "mailfeed": selection = .channel("hello-79f0")
        case "mailthread", "mailreply", "mailcomment":
            selection = .channel("hello-79f0")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let t = model.derive.mailThreads("hello-79f0").list.first { model.openThread = ThreadRoute(group: "hello-79f0", root: t.id) }
            }
        case "fullmail":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let m = model.derive.messages(generalId).last { if case .memberMail = $0.special { return true } else { return false } }
                if let m, case .memberMail(let subject, let o?) = m.special { model.fullMail = FullMailRef(subject: subject, original: o) }
            }
        case "meplace":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { path.append(PlaceRoute.me) }
        case "feed", "thread", "details", "invite", "invitesearch", "inviteexternal", "actions", "pulldown", "pullfull", "menu", "delete", "edit", "threadscreen", "chsearch", "add", "composer", "composermention": selection = .channel(generalId)
        case "drawer", "channels":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
        case "pod": selection = .channel("pod-seed-swap-5e1d")
        case "pullempty", "pullemptyclosed": selection = .channel("kitchen-7d10")
        case "group":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openGroup = "pod-seed-swap-5e1d" }
        // SPEC 19.30: the cards of a deleted and an archived group, a link to the deleted one,
        // the archived one read only, the Archived list
        case "groupcards": selection = .channel(generalId) // ChannelView scrolls to the cards
        case "groupdeleted": selection = .channel(Demo.deletedGroup)
        case "grouparchived":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openGroup = Demo.archivedGroup }
        case "archivedlist": selection = .archived
        case "mycard":
            selection = .members
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openProfile = model.me }
        case "rolepicker":
            selection = .members
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openProfile = Demo.signer("dev").pubkey }
        case "profile":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openProfile = Demo.signer("ana").pubkey }
        case "notifications":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { notifications = true }
        case "accounts", "about":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { openAccounts(); if model.launch.screen == "about" && phone { push(PlaceRoute.about) } }
        case "editprofile", "me":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { account = true }
        case "members", "todos", "todo", "todoassign", "files", "log", "chsettings", "pinned", "membersinvitech": selection = .channel(generalId)
        case "website", "websitethread", "notify", "chvisibility", "chpublic": selection = .channel("website")
        case "closedask", "closedpending", "closedrequests": selection = .channel("board-5d1e")
        case "settingsfailed", "settingsfailedalert": selection = .channel("garden-3f2a")
        case "homedrawer":
            model.tab = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
        case "calendardrawer":
            model.tab = .calendar
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
        case "settingschannels", "channelend", "channelendconfirm", "channelarchive":
            selection = .settings
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { path.append(PlaceRoute.channels) }
        case "proposal", "proposalup", "proposalfull": selection = .channel("prop-quiet-hours-after-22-00-7f3a2b")
        case "events": selection = .events
        case "eventhost":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openEvent = "2026-gwday1" }
        case "meeting", "meetingpeople":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openEvent = "2026-mtg001" }
        case "meetingform":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.launchMeetingForm = true }
        case "eventform":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.launchEventForm = true }
        case "event", "eventup", "eventfull", "eventphotos", "eventpeople", "ticket", "checkin", "eventrole":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openEvent = "repair-cafe" }
        case "checkincard":
            // a ticket link opened by Sam (the café's steward): the check-in card for Chloé's ticket
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let e = model.derive.eventByLink("repair-cafe") {
                    model.openEventTicket = AppModel.demoTicketCode(e.d, Demo.signer("chloe").pubkey)
                }
                model.openEvent = "repair-cafe"
            }
        case "membersinvite": selection = .members
        case "messages", "conversation", "mail": selection = .messages
        case "mentions": selection = .mentions
        case "requests": selection = .requests
        case "directory": selection = .members
        case "settings":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { selection = .settings; closeDrawer() }
        case "search":
            selection = .channel(generalId)
            model.drawerQuery = "ladder"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
        default: break
        }
    }
}

/// ☰ at the top left of the screen under the drawer, with the count of what waits for me.
struct DrawerButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openDrawer) private var openDrawer
    var body: some View {
        if let openDrawer {
            // the town's unread channels only: messages, mentions and requests are on Home
            let n = model.townUnread
            Button(action: openDrawer) {
                Image(systemName: "line.3.horizontal")
                    .overlay(alignment: .topTrailing) {
                        if n > 0 {
                            Text(n > 99 ? "99+" : "\(n)")
                                .font(.caption2.weight(.bold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                .background(Color.red, in: Capsule())
                                .offset(x: 10, y: -8)
                        }
                    }
            }
            .accessibilityLabel(n > 0 ? "Channels, \(n) new" : "Channels")
            .accessibilityIdentifier("drawer-button")
        }
    }
}

/// The phone's drawer: under the page, which slides right (250 ms) to show it; follows a finger
/// from the left edge (at the root of the stack) and back; a tap on the page's visible strip,
/// or a drag to the left, closes it (web Phone.tsx / drawer.ts).
struct DrawerContainer<Drawer: View, Main: View>: View {
    @Binding var open: Bool
    var edgeSwipe: Bool
    @ViewBuilder var drawer: () -> Drawer
    @ViewBuilder var main: () -> Main
    @State private var drag: CGFloat = 0
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.86, 360)
            let x = max(0, min(width, (open ? width : 0) + drag))
            let p = x / width
            ZStack(alignment: .leading) {
                // always in the tree too, for the same reason (hidden while closed)
                drawer()
                    .frame(width: width)
                    .offset(x: (p - 1) * width * 0.25)
                    .opacity(p > 0 || open ? 1 : 0)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
                main()
                    .frame(width: geo.size.width)
                    .allowsHitTesting(!open && !dragging)
                    .accessibilityHidden(open)
                    .overlay {
                        // always in the tree: a shade put in mid-animation appears at the page's
                        // final place (a grey strip) instead of riding with it
                        Color.black.opacity(0.28 * p)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { setOpen(false) }
                            .gesture(closeDrag(width))
                            .allowsHitTesting(p > 0)
                            .accessibilityHidden(p == 0)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Close the channels")
                    }
                    .shadow(color: .black.opacity(0.18 * p), radius: 16)
                    .offset(x: x)
                if !open && edgeSwipe {
                    // a thin strip on the left edge, clear of the top bar (☰) and the composer (＋)
                    Color.clear
                        .frame(width: 14)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(openDrag(width))
                        .padding(.top, 110)
                        .padding(.bottom, 130)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func openDrag(_ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                guard v.translation.width > 0 else { return }
                if !dragging { dragging = true; hideKeyboard() }
                drag = v.translation.width
            }
            .onEnded { v in
                let go = v.translation.width > width / 3 || v.predictedEndTranslation.width > width / 2
                finish(go)
            }
    }

    private func closeDrag(_ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                dragging = true
                drag = min(0, v.translation.width)
            }
            .onEnded { v in
                let close = v.translation.width < -width / 3 || v.predictedEndTranslation.width < -width / 2
                finish(!close)
            }
    }

    private func finish(_ isOpen: Bool) {
        withAnimation(.snappy(duration: isOpen ? 0.25 : 0.2)) {
            open = isOpen
            drag = 0
        }
        dragging = false
    }

    private func setOpen(_ v: Bool) { finish(v) }
}

/// The channel list: the drawer on iPhone, the sidebar on iPad.
struct ChannelDrawer: View {
    @EnvironmentObject var model: AppModel
    let current: SidebarItem?
    let inDrawer: Bool
    var onHome = false
    let select: (SidebarItem) -> Void
    var today: () -> Void = {}
    let newChannel: () -> Void
    var newChannelIn: (String) -> Void = { _ in }
    let account: () -> Void
    var openMe: () -> Void = {}
    var apply: () -> Void = {}
    let open: (SearchTarget) -> Void
    @FocusState private var searching: Bool
    @State private var settings = false

    var body: some View {
        if inDrawer { TownDrawer(current: current, onHome: onHome, select: select, today: today, newChannel: newChannelIn, account: account, me: openMe, apply: apply, open: open) } else { sidebar }
    }

    /// iPad's sidebar: the list as it was before the bottom bar (Members, events, mentions,
    /// messages, the channels).
    @ViewBuilder private var sidebar: some View {
        let _ = model.version
        let d = model.derive
        let s = d.channelSections()
        let next = d.eventsIn(.upcoming, now: .now, channel: nil).first
        let nextLine: String = next.map { d.lineDay($0.start, now: .now) + " · " + $0.title } ?? "Upcoming, yours, the ones you host"
        let dmLine: String = "And e-mail" + (d.myAddress.map { " · " + $0 } ?? "")
        VStack(spacing: 0) {
            header
            if let cover = model.config.branding?.cover, !cover.isEmpty, let u = URL(string: cover) {
                CachedImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                    .frame(height: 96).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .accessibilityHidden(true)
            }
            searchField
            List {
                if !model.drawerQuery.isEmpty {
                    SearchResults(query: model.drawerQuery, open: open)
                } else {
                    if model.access == .denied {
                        Section {
                            Label("You’re logged in, but not a member of \(model.config.name) yet.", systemImage: "lock")
                                .font(.callout)
                            Button("Apply to join") { model.showAlmostIn = true }
                        }
                    }
                    Section {
                        if !d.amGuest {
                            // Members first; what waits for me sits at the top of it (web 98c33fc)
                            let n = model.requestCount
                            DrawerRow(icon: "person.3", title: "Members",
                                      detail: n > 0 ? "\(n) \(n == 1 ? "request" : "requests") waiting for you" : "Everyone in \(model.config.name)",
                                      badge: n, on: current == .members || current == .requests) { select(.members) }
                        }
                        DrawerRow(icon: "calendar", title: "Upcoming events",
                                  detail: nextLine,
                                  on: current == .events) { select(.events) }
                        DrawerRow(icon: "at", title: "@Mentions", detail: "Where people named you, in every channel",
                                  badge: model.newMentions, on: current == .mentions) { select(.mentions) }
                        DrawerRow(icon: "envelope", title: "Direct messages",
                                  detail: dmLine,
                                  badge: model.unreadDMs, on: current == .messages) { select(.messages) }
                    }
                    if !s.pub.isEmpty {
                        Section {
                            ForEach(s.pub) { g in tree(g, nested: s.nested) }
                        } header: { sectionTitle("Public channels", s.pub.count) }
                    }
                    if !s.members.isEmpty || !s.orphans.isEmpty {
                        Section {
                            ForEach(s.members) { g in tree(g, nested: s.nested) }
                            ForEach(s.orphans) { g in row(g, depth: 0) }
                        } header: { sectionTitle("Members only", s.members.count + s.orphans.count) }
                    }
                    let mine = d.yourEvents(now: .now)
                    if !mine.isEmpty {
                        Section {
                            ForEach(mine) { e in
                                Button { select(.channel(e.groupId)) } label: {
                                    HStack(spacing: 12) {
                                        DateChip(at: e.start).scaleEffect(0.75).frame(width: 34, height: 34)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(e.title).font(.body.weight(.medium)).lineLimit(1)
                                            Text(model.derive.stateLabel(e) ?? d.lineDay(e.start, now: .now)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(current == .channel(e.groupId) ? Color.primary.opacity(0.08) : Color.clear)
                            }
                        } header: { sectionTitle("Your events", mine.count) }
                    }
                    Section {
                        Button(action: newChannel) { Label("Create a channel", systemImage: "plus") }
                            .listRowBackground(Color.clear)
                    }
                    // the very last row, only while something is archived: it opens a screen
                    let archived = d.myArchived()
                    if !archived.isEmpty {
                        Section {
                            DrawerRow(icon: "archivebox", title: "Archived",
                                      detail: archived.count == 1 ? "1 channel or group, read only" : "\(archived.count) channels and groups, read only",
                                      on: current == .archived) { select(.archived) }
                                .accessibilityIdentifier("drawer-archived")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.refresh(); await model.loadRequests(force: true) }
            .task { await model.loadRequests() }
            Divider()
            me
        }
        .background(Color(uiColor: inDrawer ? .secondarySystemBackground : .systemBackground).ignoresSafeArea())
        .sheet(isPresented: $settings) { BelfrySettings() }
        .onChange(of: model.launchSettings) { _, on in if on { model.launchSettings = false; settings = true } }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        let brand = model.config.branding
        return HStack(spacing: 10) {
            if let logo = brand?.logo, !logo.isEmpty, let url = URL(string: logo) {
                CachedImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            }
            if model.derive.isCommunityAdmin {
                // the belfry's admins: its name opens the settings, as in Discord
                Button { hideKeyboard(); select(.settings) } label: {
                    HStack(spacing: 4) {
                        Text(model.config.name).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.config.name) settings")
            } else {
                Text(model.config.name).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            Button(action: newChannel) {
                Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 36, height: 36).glass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New channel")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all channels", text: $model.drawerQuery).font(.body).focused($searching)
                .submitLabel(.search)
            if !model.drawerQuery.isEmpty {
                Button { model.drawerQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var me: some View {
        Button(action: account) {
            HStack(spacing: 10) {
                Avatar(pubkey: model.me, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.realName(model.me).isEmpty ? "You" : model.realName(model.me)).font(.body.weight(.semibold)).lineLimit(1)
                    Text(model.derive.myAddress ?? model.config.domain).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                ConnectionDot()
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Me: your profile and settings")
    }

    private func sectionTitle(_ t: String, _ n: Int) -> some View {
        HStack { Text(t); Spacer(); Text("\(n)").monospacedDigit() }
            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
    }

    private func tree(_ g: BelfryCore.Group, nested: [String: [BelfryCore.Group]], depth: Int = 0) -> AnyView {
        AnyView(SwiftUI.Group {
            row(g, depth: depth)
            if depth < 4 {
                ForEach(nested[g.id] ?? []) { c in tree(c, nested: nested, depth: depth + 1) }
            }
        })
    }

    private func row(_ g: BelfryCore.Group, depth: Int) -> some View {
        Button { select(.channel(g.id)) } label: { ChannelRow(group: g, isPublic: model.derive.isPublic(g)) }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * 18)
            .listRowBackground(current == .channel(g.id) ? Color.primary.opacity(0.08) : Color.clear)
    }
}

/// A row at the top of the drawer: icon, title, a line, a count.
struct DrawerRow: View {
    let icon: String
    let title: String
    let detail: String
    var badge = 0
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body.weight(.medium)).frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).lineLimit(1)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if badge > 0 { CountBadge(n: badge) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(on ? Color.primary.opacity(0.08) : Color.clear)
    }
}

struct CountBadge: View {
    let n: Int
    var body: some View {
        Text(n > 99 ? "99+" : "\(n)").font(.caption.weight(.bold)).monospacedDigit()
            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
            .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
            .accessibilityLabel("\(n) new")
    }
}

/// Green when the relays answer, grey offline, a spinner while connecting; nothing in demo mode.
struct ConnectionDot: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let _ = model.version
        if model.isDemo {
            Text("Demo").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.12), in: Capsule())
        } else if !model.online {
            Image(systemName: "wifi.slash").foregroundStyle(.secondary).accessibilityLabel("Offline: messages wait on this phone")
        } else if model.engine?.relaysUp != true {
            ProgressView().controlSize(.mini).accessibilityLabel("Connecting")
        }
    }
}

struct ChannelRow: View {
    @EnvironmentObject var model: AppModel
    let group: Channel
    var isPublic = false

    var unreadN: Int { model.unread(group.id) }

    var body: some View {
        let last = model.derive.messages(group.id).last
        HStack(spacing: 12) {
            SwiftUI.Group {
                if isPublic && group.type == .channel {
                    Image(systemName: "globe").font(.body.weight(.medium)).accessibilityLabel("Public")
                } else if group.type == .channel {
                    Image(systemName: "number").font(.body.weight(.medium))
                } else {
                    ChannelGlyph(group: group, size: 22)
                }
            }
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                GroupTitle(group: group, id: group.id).font(.body.weight(unreadN > 0 ? .bold : .medium)).lineLimit(1)
                if let last {
                    Text("\(model.name(last.ev.pubkey)): \(preview(last.text))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if unreadN > 0 {
                Text(unreadN > 99 ? "99+" : "\(unreadN)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unreadN > 0 ? "\(group.named ? group.name : "Unnamed") channel, \(unreadN) unread" : "\(group.named ? group.name : "Unnamed") channel")
    }

    func preview(_ t: String) -> String {
        let plain = Rx("\\*\\*|__|~~|`").replace(t, with: "")
        return model.derive.plainRefs(plain).replacingOccurrences(of: "\n", with: " ")
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let _ = model.version
        status.labelStyle(.titleAndIcon)
    }

    @ViewBuilder var status: some View {
        if model.isDemo {
            Label("Demo: nothing leaves this phone", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
        } else if !model.online {
            Label("Offline: messages wait on this phone", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
        } else if model.engine?.relaysUp != true {
            Label("Connecting…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }
}

struct SearchResults: View {
    @EnvironmentObject var model: AppModel
    let query: String
    let open: (SearchTarget) -> Void

    var body: some View {
        let words = fold(query).split(separator: " ").map(String.init)
        let hits = results(words)
        Section(hits.isEmpty ? "Nothing found" : "\(hits.count == 200 ? "200+" : String(hits.count)) \(hits.count == 1 ? "result" : "results")") {
            ForEach(hits) { hit in
                let gid = hit.channel, m = hit.message
                Button { open(SearchTarget(channel: gid, message: m.id)) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(pubkey: m.ev.pubkey, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model.name(m.ev.pubkey)).font(.subheadline.bold())
                                Text(model.group(gid).map { $0.named ? $0.icon + $0.name : model.derive.label(gid) } ?? model.derive.label(gid)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(model.derive.plainRefs(m.text)).font(.subheadline).lineLimit(3).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    struct Hit: Identifiable { let channel: String; let message: Message; var id: String { message.id } }

    func results(_ words: [String]) -> [Hit] {
        guard !words.isEmpty else { return [] }
        return model.derive.search(query).map { Hit(channel: $0.groupId, message: $0.m) }
    }
}

struct NewChannelSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    /// The category it goes into (a category's ＋; by a belfry admin the order event follows).
    var category: String? = nil
    let created: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).font(.body)
                TextField("What is it about?", text: $about, axis: .vertical).lineLimit(2...5).font(.body)
                if let category, let c = model.derive.channelCategories().first(where: { $0.id == category }) {
                    Section { Label(c.name, systemImage: "folder") } header: { Text("Category") }
                }
            }
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let id = model.createChannel(name: name.trimmingCharacters(in: .whitespaces), about: about.trimmingCharacters(in: .whitespaces), category: category)
                        dismiss()
                        created(id)
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .solidSheet()
    }
}

struct Avatar: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    var size: CGFloat = 36

    var body: some View {
        let p = model.profiles[pubkey]
        let name = Derive.realName(pubkey, model.profiles)
        ZStack {
            Circle().fill(color)
            if let pic = p?.picture, let url = URL(string: pic), pic.hasPrefix("https://") {
                CachedImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { initials(name) }
                    .clipShape(Circle())
            } else {
                initials(name)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    func initials(_ name: String) -> some View {
        Text(String((name.isEmpty ? "?" : name).prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
    }

    var color: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink, .green, .purple, .brown]
        let n = pubkey.utf8.prefix(6).reduce(0) { $0 &+ Int($1) }
        return palette[n % palette.count]
    }
}
