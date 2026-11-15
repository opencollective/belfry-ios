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
    @State private var account = false
    @State private var notifications = false
    @State private var focus: SearchTarget?
    @State private var visibility = NavigationSplitViewVisibility.automatic
    @State private var path = NavigationPath()
    @State private var drawer = false

    var body: some View {
        withSheets
            .fullScreenCover(item: $model.lightbox) { LightboxView(box: $0) }
            .sheet(isPresented: $model.joinAsked) { JoinSheet() }
            .sheet(isPresented: $newChannel) { NewChannelSheet { id in selection = .channel(id) } }
            .sheet(isPresented: $account) { AccountSheet() }
            .sheet(isPresented: $notifications) { NavigationStack { NotificationsView() } }
    }

    private var routed: some View {
        layout
        .environment(\.openChannel) { id, message in
            focus = message.map { SearchTarget(channel: id, message: $0) }
            if selection == .channel(id) { path = NavigationPath() } else { selection = .channel(id) }
            closeDrawer()
        }
        .onChange(of: selection) { _, _ in path = NavigationPath() }
        .onChange(of: model.messageAuthor) { _, pk in
            guard let pk else { return }
            model.messageAuthor = nil
            selection = .messages
            let conv = MailThreads.nostrConv(author: pk, pTags: [], me: model.me)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                var p = NavigationPath()
                p.append(ConvRoute(conv: conv))
                path = p
            }
        }
    }

    private var withSheets: some View {
        withLife
        .sheet(item: Binding(get: { model.openEvent.map { EventKey(key: $0) } }, set: { model.openEvent = $0?.key })) { k in
            EventPage(key: k.key)
        }
        .sheet(item: Binding(get: { model.showEvents.map { EventKey(key: $0) } }, set: { model.showEvents = $0?.key })) { k in
            EventsList(channel: k.key.isEmpty ? nil : k.key)
        }
        .sheet(item: Binding(get: { model.openGroup.map { GroupKey(id: $0) } }, set: { model.openGroup = $0?.id })) { k in
            GroupPage(id: k.id)
        }
        .sheet(item: Binding(get: { model.openProfile.map { ProfileKey(pubkey: $0) } }, set: { model.openProfile = $0?.pubkey })) { k in
            ProfileView(pubkey: k.pubkey)
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
                focus = p.message.map { SearchTarget(channel: id, message: $0) }
                if let root = p.thread { model.openThread = ThreadRoute(group: id, root: root) }
                if selection == .channel(id) { path = NavigationPath() } else { selection = .channel(id) }
            } else {
                selection = .messages
            }
        }
        .onChange(of: model.joinedChannel) { _, id in
            guard let id else { return }
            model.joinedChannel = nil
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
            if selection == nil { selection = firstChannel() }
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
            DrawerContainer(open: $drawer, edgeSwipe: path.isEmpty) {
                drawerList(inDrawer: true)
            } main: {
                detail.environment(\.openDrawer) { openDrawer() }
            }
        }
    }

    private var detail: some View {
        NavigationStack(path: $path) {
            switch selection {
            case .channel(let id): ChannelView(id: id, focus: focus?.channel == id ? focus?.message : nil).id(id)
            case .messages: MessagesView()
            case .mentions: MentionsView()
            case .requests: RequestsView()
            case nil: ContentUnavailableView("Pick a channel", systemImage: "number", description: Text("Your community's channels are in the list."))
                    .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
            }
        }
        .environment(\.openConversation) { conv in
            var p = NavigationPath()
            p.append(ConvRoute(conv: conv))
            path = p
        }
    }

    private func drawerList(inDrawer: Bool) -> some View {
        ChannelDrawer(current: selection, inDrawer: inDrawer,
                      select: { item in
                          if selection == item { path = NavigationPath() } else { selection = item }
                          closeDrawer()
                      },
                      newChannel: { hideKeyboard(); newChannel = true },
                      account: { hideKeyboard(); account = true },
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
        switch model.launch.screen {
        case "feed", "thread", "details", "invite", "actions", "pulldown", "pullfull", "menu", "delete", "edit", "threadscreen", "chsearch", "add", "composer": selection = .channel(generalId)
        case "drawer", "channels":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
        case "pod": selection = .channel("pod-seed-swap-5e1d")
        case "group":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openGroup = "pod-seed-swap-5e1d" }
        case "profile":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openProfile = Demo.signer("ana").pubkey }
        case "notifications":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { notifications = true }
        case "editprofile", "me":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { account = true }
        case "members", "todos", "files", "log": selection = .channel(generalId)
        case "proposal": selection = .channel("prop-quiet-hours-after-22-00-7f3a2b")
        case "events": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.showEvents = "" }
        case "eventhost":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openEvent = "2026-gwday1" }
        case "eventform":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.launchEventForm = true }
        case "event":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openEvent = "repair-cafe" }
        case "messages", "conversation", "mail": selection = .messages
        case "mentions": selection = .mentions
        case "requests": selection = .requests
        case "settings":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openDrawer() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model.launchSettings = true }
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
            let n = model.unreadDMs + model.newMentions + model.requestCount
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
                if p > 0 || open {
                    drawer()
                        .frame(width: width)
                        .offset(x: (p - 1) * width * 0.25)
                }
                main()
                    .frame(width: geo.size.width)
                    .allowsHitTesting(!open && !dragging)
                    .accessibilityHidden(open)
                    .overlay {
                        if p > 0 {
                            Color.black.opacity(0.28 * p)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { setOpen(false) }
                                .gesture(closeDrag(width))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel("Close the channels")
                        }
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
    let select: (SidebarItem) -> Void
    let newChannel: () -> Void
    let account: () -> Void
    let open: (SearchTarget) -> Void
    @FocusState private var searching: Bool
    @State private var ordering = false
    @State private var settings = false

    var body: some View {
        let _ = model.version
        let d = model.derive
        let s = d.channelSections()
        let next = d.eventsIn(.upcoming, now: .now, channel: nil).first
        let nextLine: String = next.map { d.lineDay($0.start, now: .now) + " · " + $0.title } ?? "Upcoming, yours, the ones you host"
        let dmLine: String = "And e-mail" + (d.myAddress.map { " · " + $0 } ?? "")
        VStack(spacing: 0) {
            header
            if let cover = model.config.branding?.cover, !cover.isEmpty, let u = URL(string: cover) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
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
                            Label("This belfry doesn't let your key in yet. Ask an admin, or check your membership.", systemImage: "lock")
                                .font(.callout)
                        }
                    }
                    Section {
                        if model.showRequests {
                            let n = model.requestCount
                            DrawerRow(icon: "tray", title: "Requests", detail: n > 0 ? "\(n) waiting for you" : "People and agents asking to join",
                                      badge: n, on: current == .requests) { select(.requests) }
                        }
                        DrawerRow(icon: "calendar", title: "Upcoming events",
                                  detail: nextLine,
                                  on: false) { model.showEvents = "" }
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
                        if d.isCommunityAdmin {
                            Button { hideKeyboard(); ordering = true } label: { Label("Order of the channels", systemImage: "arrow.up.arrow.down") }
                                .listRowBackground(Color.clear)
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
        .sheet(isPresented: $ordering) { ChannelOrderSheet() }
        .sheet(isPresented: $settings) { BelfrySettings() }
        .onChange(of: model.launchSettings) { _, on in if on { model.launchSettings = false; settings = true } }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        let brand = model.config.branding
        return HStack(spacing: 10) {
            if let logo = brand?.logo, !logo.isEmpty, let url = URL(string: logo) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            }
            if model.derive.isCommunityAdmin {
                // the belfry's admins: its name opens the settings, as in Discord
                Button { hideKeyboard(); settings = true } label: {
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
                Text(group.name).font(.body.weight(.medium)).lineLimit(1)
                if let last {
                    Text("\(model.name(last.ev.pubkey)): \(preview(last.text))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name) channel")
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
                                Text("\(model.group(gid)?.icon ?? "#")\(model.group(gid)?.name ?? gid)").font(.caption).foregroundStyle(.secondary)
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
    let created: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("What is it about?", text: $about, axis: .vertical).lineLimit(2...5)
            }
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let id = model.createChannel(name: name.trimmingCharacters(in: .whitespaces), about: about.trimmingCharacters(in: .whitespaces))
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
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { initials(name) }
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

/// The belfry's admins put the channels in order (web order.ts: 30078 d=belfry:channel-order).
/// Within Public and Members only; moving a channel across changes who reads it, which is its
/// own setting on the web (not here).
struct ChannelOrderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pub = [Channel]()
    @State private var members = [Channel]()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !pub.isEmpty {
                    Section("Public channels") {
                        ForEach(pub) { g in Label(g.name, systemImage: "globe") }
                            .onMove { pub.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
                Section {
                    ForEach(members) { g in Label(g.name, systemImage: "number") }
                        .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                } header: { Text("Members only") } footer: { Text("Everyone sees the channels in this order.") }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Order of the channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Save") {
                        model.setChannelOrder((pub + members).map(\.id))
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let s = model.derive.channelSections()
                pub = s.pub; members = s.members
            }
        }
    }
}
