import BelfryCore
import PhotosUI
import SwiftUI

// The event screen (SPEC 19.29, Xavier 2026-11-15: "Opening an event should show a header with
// the main event info and current rsvp status as part of the summary pull down already pulled
// half way that can be pulled further down or back up to reveal the chat about it"). One screen,
// pushed (Events, a card in a feed, a universal link, the drawer's Your events):
// - the header at three levels with the channel pull-down's mechanics (a handle that drags and
//   snaps, a tap toggles): half (it opens there: cover, title, when, where, my status as the main
//   control, who is going), up (the navigation bar names the event; the content takes the
//   screen), full (also hosted by, going / maybe, the description, the address, host tools);
// - under it Chat · Photos · People (a native segmented picker): the event group's feed and
//   composer, the photos with Add photos, the people with a message button.
// One shape (0.8.0, boards one-shape/event-default, -online, -tiny, -full, 2026-11-22): the
// levels are now tiny (up: the two-line header in the bar, my answer leading its icon row), mid
// (half, how it opens: the cover fitted to the width at 16:9 under the floating ‹ and •••, the
// title full width, when, where or the call with Join, hosted by, who's going, Going / Maybe /
// Can't go) and full (Directions, to-dos, files, photos, people, everything); the conversation
// is under the header (no tabs), people / photos / to-dos / files are pushed screens; scrolling
// the conversation up folds mid to tiny.
// Everything draws from the local log; the belfry's `viewer` block refreshes in the background
// and is kept per event (AppModel+Checkin).

enum EventLevel: Hashable { case up, half, full }

/// What the event pushes (one shape, 2026-11-22: no tabs any more; the conversation is under the
/// header, people / photos / to-dos / files are screens of their own).
enum EventSub: String, Hashable, Identifiable { case people, photos, todos, files; var id: String { rawValue } }

struct EventRoute: Hashable { let key: String; var ticket: String? = nil; /** A message of its chat to open at (a message link). */ var focus: String? = nil }

/// Finds the event (the local log first, then the belfry's API for guests) and shows it.
struct EventScreen: View {
    @EnvironmentObject var model: AppModel
    let key: String
    var ticket: String? = nil
    /// A message of its chat to open at (a message link, SPEC 19.61).
    var focus: String? = nil
    /// The open screen of the drawer (☰ instead of a back button).
    var root = false
    @State private var remote: ApiEvent?
    @State private var error: String?

    var body: some View {
        let _ = model.version
        let d = model.derive
        SwiftUI.Group {
            if let e = d.eventByKey(key) {
                EventScreenBody(e: e, api: nil, ticket: ticket, root: root, focus: focus)
            } else if let r = remote {
                EventScreenBody(e: r.calEvent(timeZone: .current, me: model.me), api: r, ticket: nil, root: root)
            } else if let error {
                ContentUnavailableView(error, systemImage: "calendar.badge.exclamationmark")
                    .toolbar { if root { ToolbarItem(placement: .topBarLeading) { DrawerButton() } } }
            } else {
                ProgressView()
            }
        }
        .task {
            guard d.eventByKey(key) == nil else { return }
            switch await model.remoteEvent(key) {
            case .success(let r): remote = r
            case .failure(let e): error = e.message
            }
        }
    }
}

struct EventScreenBody: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let api: ApiEvent?
    let ticket: String?
    let root: Bool
    var focus: String? = nil
    @State private var level: EventLevel = .half
    @State private var sub: EventSub?
    @State private var drag: CGFloat = 0
    @State private var halfContentH: CGFloat = 0
    /// The page's height below the bar and the bar's height (see body).
    @State private var page = PageBox(top: 0, width: 0, height: 0)
    /// The header is out of the tree once it has been pulled up (after its animation).
    @State private var headerGone = false
    @State private var showTicket = false
    @State private var checkingIn = false
    @State private var scanCard: String?
    @State private var getTickets = false
    @State private var editing = false
    @State private var ticketsSheet = false
    @State private var cancelSheet = false
    @State private var confirmDelete = false
    @State private var coHost: String?
    @State private var profile: ProfileKey?
    @State private var error: String?
    @State private var launched = false

    static let handleH: CGFloat = 22

    struct Heights { let up, half, full: CGFloat }
    struct PageBox: Equatable, Sendable { let top: CGFloat; let width: CGFloat; let height: CGFloat }

    var body: some View {
        let _ = LoopWatch.tick("EventScreenBody")
        let d = model.derive
        let access = hasAccess(d)
        let total = page.height
        let hs = heights(total: total, access: access)
        let h = height(hs, access: access)
        // Nothing of the page leaves the safe area. The cover under the navigation bar is a
        // background decoration (it never takes part in layout); the header shows a clear gap of
        // the cover's height over it. (Content that ignored the top safe area, measured by a
        // GeometryReader around it, froze the app when the keyboard rose in the event's chat:
        // UIKit's safe-area and keyboard layout never settled, 2026-11-16.)
        Color.clear
            .onGeometryChange(for: PageBox.self) { PageBox(top: $0.safeAreaInsets.top.rounded(), width: $0.size.width.rounded(), height: $0.size.height.rounded()) } action: { p in
                LoopWatch.tick("page"); if p != page { page = p }
            }
            .background(alignment: .top) {
                EventBackdrop(e: e, height: page.top + coverGap)
                    .ignoresSafeArea(edges: .top)
                    .opacity(access && level == .up ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    header(d, h: h, hs: hs, access: access)
                    if access {
                        handle(hs)
                        // a fixed height: a flexible content area made every stack above it measure
                        // the chat (and the composer's text view) at several sizes per pass, which
                        // multiplied level by level until the main thread was busy for good
                        content(hidden: level == .full && drag == 0, height: max(0, total - h - EventScreenBody.handleH))
                    }
                }
                .opacity(page.height > 0 ? 1 : 0)
            }
        .overlay(alignment: .top) {
            if let code = scanCard, model.mayCheckIn(e) {
                CheckInCard(e: e, code: code) { withAnimation { scanCard = nil } }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle(e.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbar(d) }
        .navigationDestination(item: $profile) { ProfileView(pubkey: $0.pubkey, pushed: true, group: $0.group).overRoot() }
        .navigationDestination(item: $sub) { s in subScreen(s).overRoot() }
        .environment(\.showProfile) { pk in openProfile(pk) }
        .fullScreenCover(isPresented: $showTicket) { MyTicketView(e: e) }
        .fullScreenCover(isPresented: $checkingIn) { CheckInScreen(e: e) }
        .sheet(isPresented: $getTickets) { GetTicketsSheet(e: e, api: api) }
        .sheet(isPresented: $editing) { EventFormSheet(editing: e, channel: nil) }
        .sheet(isPresented: $ticketsSheet) { TicketsSheet(e: e) }
        .sheet(isPresented: $cancelSheet) { CancelEventSheet(e: e) }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteEvent(e) }
        } message: { Text("It disappears for everyone. This can't be undone.") }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            // typing in the event's chat: the header steps out of the way
            LoopWatch.tick("keyboardWillShow")
            LoopWatch.mark("keyboardWillShow level=\(level)")
            if access && sub == nil && level != .up { withAnimation(.snappy(duration: 0.25)) { level = .up } }
        }
        .onChange(of: level) { _, l in
            if l == .up {
                // once the pull-up has finished; back in at once (at height 0) when it comes down
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if level == .up { headerGone = true } }
            } else {
                headerGone = false
            }
        }
        .onChange(of: drag) { _, v in if v != 0 { headerGone = false } }
        .onChange(of: showTicket || checkingIn || getTickets || editing) { _, open in if open { hideKeyboard() } }
        .task(id: e.d) { await model.loadViewer(e) }
        .onAppear(perform: applyLaunch)
    }

    // ---- levels --------------------------------------------------------------------------------

    private func hasAccess(_ d: Derive) -> Bool {
        guard !e.remote, let g = model.group(e.groupId) else { return false }
        return d.inChannel(g, model.me) || d.isHost(e) || d.eventPeople(e).holders[model.me] != nil
    }

    private func heights(total: CGFloat, access: Bool) -> Heights {
        guard access else { return Heights(up: total, half: total, full: total) }
        let up: CGFloat = 0
        let measured = halfContentH > 0 ? halfContentH : 320
        let full = max(up + 120, total - EventScreenBody.handleH)
        let half = min(full, max(up + 120, min(measured, total * 0.72)))
        return Heights(up: up, half: half, full: full)
    }

    private func height(_ hs: Heights, access: Bool) -> CGFloat {
        guard access else { return hs.full }
        let base: CGFloat
        switch level {
        case .up: base = hs.up
        case .half: base = hs.half
        case .full: base = hs.full
        }
        return max(hs.up, min(hs.full, base + drag))
    }

    private func handle(_ hs: Heights) -> some View {
        Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(width: page.width, height: EventScreenBody.handleH)
            .background(PDSurface.color)
            .overlay(alignment: .bottom) { Divider() }
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { v in drag = v.translation.height }
                .onEnded { v in
                    let base: CGFloat = level == .full ? hs.full : level == .half ? hs.half : hs.up
                    let end = base + v.predictedEndTranslation.height
                    let next: EventLevel = end < (hs.up + hs.half) / 2 ? .up : end < (hs.half + hs.full) / 2 ? .half : .full
                    withAnimation(.snappy(duration: 0.28)) { level = next; drag = 0 }
                })
            .onTapGesture { withAnimation(.snappy(duration: 0.28)) { level = level == .full ? .half : level == .half ? .full : .half } }
            .accessibilityElement()
            .accessibilityIdentifier("event-handle")
            .accessibilityLabel(level == .full ? "Show less" : "Show everything about the event")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation { level = level == .full ? .half : .full } }
            .accessibilityAction(named: "Show the chat") { withAnimation { level = .up } }
            // ⌃ and ⌄ at its ends (Xavier, 2026-11-22: "When pulling down fully, there should be a
            // way to push back up mid way, then all the way"); drag and tap stay. Overlays: they
            // take no part in the handle's fixed frame.
            .overlay(alignment: .leading) {
                handleArrow("chevron.up", "Show less", "event-handle-up", off: level == .up) { level = level == .full ? .half : .up }
            }
            .overlay(alignment: .trailing) {
                handleArrow("chevron.down", "Show more", "event-handle-down", off: level == .full) { level = level == .up ? .half : .full }
            }
    }

    private func handleArrow(_ symbol: String, _ label: String, _ id: String, off: Bool, _ step: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy(duration: 0.28)) { step() } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 56, height: EventScreenBody.handleH)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(off ? 0.25 : 1)
        .disabled(off)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // ---- the header ------------------------------------------------------------------------------

    @ViewBuilder private func header(_ d: Derive, h: CGFloat, hs: Heights, access: Bool) -> some View {
        if headerGone {
            // pulled up (the keyboard is up, or the chat takes the screen): nothing of the header
            // stays to be laid out with every change of the chat
            Color.clear.frame(width: page.width, height: 0)
        } else {
            headerBody(d, h: h, hs: hs, access: access)
        }
    }

    private func headerBody(_ d: Derive, h: CGFloat, hs: Heights, access: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    halfPart(d, access: access)
                        .id("event-top")
                        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { h in
                            // only real changes (a sub-point wobble redrew the screen for nothing)
                            LoopWatch.tick("halfContentH")
                            if abs(h - halfContentH) >= 1 { halfContentH = h }
                        }
                    // kept in the tree at every level (clipped away): nothing pops in while pulling
                    EventFullPart(e: e, api: api, error: $error, coHost: $coHost, open: openProfile,
                                  showPeople: { hideKeyboard(); sub = .people }, push: { hideKeyboard(); sub = $0 },
                                  edit: { editing = true }, tickets: { ticketsSheet = true }, cancel: { cancelSheet = true },
                                  delete: { confirmDelete = true })
                        .background(PDSurface.color)
                }
            }
            .scrollDisabled(access && level != .full)
            .scrollBounceBehavior(.basedOnSize)
            .noTopEdgeEffect()
            .onChange(of: level) { _, l in
                if l != .full { withAnimation(.snappy) { proxy.scrollTo("event-top", anchor: .top) } }
                // screenshots: the address and its buttons, at the bottom of the full level
                else if model.launch.screen == "eventaddress" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo("event-address", anchor: .bottom) } }
            }
        }
        .opacity(access ? min(1, max(0, (h - hs.up) / 60)) : 1)
        // width and height both fixed: the stacks around never measure the header's content
        .frame(width: page.width, height: h, alignment: .top)
        .clipped()
        .accessibilityHidden(access && level == .up)
    }

    /// The cover fitted to the width at 16:9, from the top of the screen (under the bar): the
    /// part of it below the bar is a clear gap at the top of the header.
    private var coverGap: CGFloat {
        guard e.hasCover, page.width > 0 else { return 0 }
        return max(0, (page.width * 9 / 16).rounded() - page.top)
    }

    /// Mid, how it opens (board one-shape/event-default): the title over the full width (26 pt),
    /// when, where (a maps link, or the call with Join), hosted by, who's going (People), then
    /// Going / Maybe / Can't go with my answer highlighted.
    private func halfPart(_ d: Derive, access: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // the cover itself is the page's backdrop (under the bar too): a clear gap shows it
            Color.clear.frame(height: coverGap).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if e.meeting { Text("Meeting · members only").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(e.title).font(.system(size: 26, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                EventInfoRows(e: e, api: api)
                if let hosted = hostedLine(d) {
                    Text(hosted).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                goingLine(d, access: access)
                EventStatusControl(e: e, api: api, showTicket: { showTicket = true }, getTickets: { getTickets = true },
                                   checkIn: { checkingIn = true })
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PDSurface.color)
        }
    }

    private func hostedLine(_ d: Derive) -> String? {
        let hosts = d.eventPeopleList(e).hosts.filter { d.eventRole(e, $0) != .steward }
        let names = hosts.map { pk in api?.hosts.first { $0.first == pk }?.last.flatMap { $0.isEmpty ? nil : $0 } ?? model.name(pk) }
        return EventShape.hostedBy(names)
    }

    private func goingLine(_ d: Derive, access: Bool) -> some View {
        let going = e.goingKeys
        let maybe = e.rsvps.filter { $0.value == .tentative && !going.contains($0.key) }.count
        let text = EventShape.goingLine(going: e.going, maybe: maybe) ?? ""
        return Button {
            hideKeyboard()
            if access { sub = .people } else { withAnimation(.snappy(duration: 0.28)) { level = .full } }
        } label: {
            HStack(spacing: 10) {
                FacePile(keys: Array(going.prefix(5)))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                if access { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(text.isEmpty ? 0 : 1)
        .frame(height: text.isEmpty ? 0 : nil)
        .accessibilityHidden(text.isEmpty)
        .accessibilityLabel(text + ". Show the people.")
        .accessibilityIdentifier("event-going")
    }

    // ---- the content ---------------------------------------------------------------------------

    /// The conversation about the event, under the header (a plain stack: see CLAUDE.md, the
    /// event-chat freeze). Scrolling it up folds the header to the tiny one.
    private func content(hidden: Bool, height: CGFloat) -> some View {
        ChannelView(id: e.groupId, focus: focus, embedded: true)
            .frame(width: page.width, height: height)
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                if level == .half && v.translation.height < -60 && abs(v.translation.width) < 40 {
                    withAnimation(.snappy(duration: 0.28)) { level = .up }
                }
            })
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }

    /// People, photos, to-dos and files: screens of their own, pushed.
    @ViewBuilder private func subScreen(_ s: EventSub) -> some View {
        switch s {
        case .people:
            EventPeopleTab(e: e, open: openProfile, checkIn: { checkingIn = true })
                .navigationTitle("People").navigationBarTitleDisplayMode(.inline)
        case .photos:
            EventPhotosTab(e: e).navigationTitle("Photos").navigationBarTitleDisplayMode(.inline)
        case .todos, .files:
            ChannelPlaceView(id: e.groupId, place: s == .todos ? .todos : .files, go: { _ in sub = nil }, filter: { _ in sub = nil })
        }
    }

    // ---- toolbar -------------------------------------------------------------------------------

    @ToolbarContentBuilder private func toolbar(_ d: Derive) -> some ToolbarContent {
        if root { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
        ToolbarItem(placement: .principal) {
            // tiny (board one-shape/event-tiny): the title, then my answer, the date in the
            // accent colour, 👥 going, open to-dos, files
            OneHeader(title: e.title, items: tinyItems(d), chevron: false) {
                withAnimation(.snappy(duration: 0.28)) { level = .half }
            }
            .opacity(level == .up ? 1 : 0)
            .accessibilityHidden(level != .up)
            .accessibilityIdentifier("event-tiny")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let u = URL(string: d.eventURL(e)), e.isNew {
                    ShareLink(item: u, subject: Text(e.title)) { Label("Share the event", systemImage: "square.and.arrow.up") }
                }
                if model.mayCheckIn(e) {
                    Button { checkingIn = true } label: { Label("Check people in", systemImage: "qrcode.viewfinder") }
                }
                if model.viewer(e)?.ticketCode != nil {
                    Button { showTicket = true } label: { Label("Show my ticket", systemImage: "ticket") }
                }
                if d.isHost(e) && e.isNew && !e.remote {
                    Button { editing = true } label: { Label("Edit the event", systemImage: "pencil") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("event-more")
        }
    }

    /// The tiny header's row: ✓ Going (my answer) · 📅 Thu 4 Dec · 7 PM · 👥 15 · ✓ 2 · 📁 1.
    private func tinyItems(_ d: Derive) -> [HeaderItem] {
        var items = [HeaderItem]()
        if let r = d.myRsvp(e) {
            let icon = r == .accepted ? "checkmark" : r == .tentative ? "questionmark" : "xmark"
            items.append(HeaderItem(key: "answer", icon: icon, text: r.label, label: "You answered " + r.label,
                                    tint: r == .accepted ? .green : .secondary))
        } else if let s = d.stateLabel(e), !s.isEmpty {
            // a ticket, an application: my state leads the row the same way
            items.append(HeaderItem(key: "answer", icon: "checkmark", text: s, label: s, tint: .green))
        }
        let when = d.lineDay(e.start, now: .now) + " · " + d.lineWhen(e)
        items.append(HeaderItem(key: "lead", icon: "calendar", text: when, label: when, accent: true))
        if let p = HeaderItem.count("people", "person.2", e.going, "going", "going") { items.append(p) }
        if let t = HeaderItem.count("todos", "checkmark.circle", d.tasks(e.groupId).filter { !$0.done }.count, "open to-do", "open to-dos") { items.append(t) }
        let files = d.files(e.groupId).filter { !$0.isImage }.count
        if let f = HeaderItem.count("files", "folder", files, "file", "files") { items.append(f) }
        return items
    }

    private func openProfile(_ pk: String) {
        hideKeyboard()
        profile = ProfileKey(pubkey: pk, group: model.group(e.groupId) != nil ? e.groupId : nil)
    }

    // ---- screenshots ---------------------------------------------------------------------------

    private func applyLaunch() {
        if let ticket, !launched { launched = true; scanCard = ticket }
        guard !model.launchEventDone else { return }
        let s = model.launch.screen ?? ""
        guard s.hasPrefix("event") || ["ticket", "checkin", "eventrole", "meetingpeople"].contains(s) else { return }
        model.launchEventDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            switch s {
            case "eventup": withAnimation { level = .up }
            // no animation: the picture is taken at a fixed time after launch
            case "eventtiny": level = .up
            case "eventfull", "eventaddress": withAnimation { level = .full }
            case "eventphotos": sub = .photos
            case "eventpeople", "meetingpeople": sub = .people
            case "ticket": showTicket = true
            case "checkin": checkingIn = true
            case "eventrole": openProfile(Demo.signer("ana").pubkey)
            default: break
            }
        }
    }
}

extension CalEvent {
    var hasCover: Bool { (cover ?? "").hasPrefix("https://") }
}

/// The cover, from the top of the screen (under the bar, where ‹ and ••• float on it) to the
/// header's gap: a background decoration only. Fitted to the width, never cropped sideways (the
/// same picture, blurred, fills what a narrow one leaves). Without a cover, the page's surface.
struct EventBackdrop: View {
    let e: CalEvent
    let height: CGFloat
    var body: some View {
        if let c = e.cover, let u = URL(string: c), e.hasCover {
            Color.secondary.opacity(0.12)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .overlay { CachedImage(url: u) { $0.resizable().scaledToFill().blur(radius: 24).opacity(0.6) } placeholder: { Color.clear } }
                .overlay { CachedImage(url: u) { $0.resizable().scaledToFit() } placeholder: { Color.clear } }
                .clipped()
                // the floating buttons read over any picture
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color.black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom).frame(height: 90)
                }
                .accessibilityHidden(true)
        } else {
            PDSurface.color.frame(height: height).accessibilityHidden(true)
        }
    }
}

/// When and where: the day and the time (the zone only when it isn't mine), the place (tap: maps),
/// the online link.
struct EventInfoRows: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let api: ApiEvent?

    var body: some View {
        let d = model.derive
        VStack(alignment: .leading, spacing: 8) {
            row("calendar", when(d))
            if let l = e.location, !l.isEmpty {
                Button { openMaps(l) } label: { row("mappin.and.ellipse", l, tint: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Maps")
            }
            // online (board one-shape/event-default-online): "Online · Jitsi" links to the call,
            // Join on the same line, open from 10 minutes before the start until the end
            ForEach(e.links, id: \.self) { l in
                if let u = URL(string: l) { onlineRow(u, EventShape.service(l)) }
            }
            if e.links.isEmpty && (api?.online ?? false) {
                row("video", "The online link shows once you have a place")
            }
        }
    }

    private func onlineRow(_ u: URL, _ service: String) -> some View {
        let open = EventShape.joinOpen(start: e.start, end: e.end, now: .now)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "video").foregroundStyle(.secondary).frame(width: 22)
            Link(destination: u) {
                Text("Online · " + service).font(.body).foregroundStyle(Color.brand).lineLimit(1)
            }
            .accessibilityHint("Opens the call")
            Spacer(minLength: 8)
            Link(destination: u) {
                Text("Join").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(open ? Color.blue : Color.secondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(open ? Color.white : Color.secondary)
            }
            .disabled(!open)
            .accessibilityLabel(open ? "Join the call" : "Join opens 10 minutes before the start")
            .accessibilityIdentifier("event-join")
        }
    }

    private func when(_ d: Derive) -> String {
        var s = d.lineDays(e, now: .now) ?? (d.lineDay(e.start, now: .now) + " · " + d.lineWhen(e))
        if let tz = e.tz, let zone = TimeZone(identifier: tz), zone.secondsFromGMT() != TimeZone.current.secondsFromGMT() {
            s += " (your time)"
        }
        return s
    }

    private func row(_ symbol: String, _ text: String, tint: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            Text(text).font(.body).foregroundStyle(tint ? Color.brand : Color.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func openMaps(_ place: String) {
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: place)]
        if let u = c.url { UIApplication.shared.open(u) }
    }
}

/// My status as the main control: Show my ticket, Get tickets, Going / Maybe / Can't go, my
/// application; "Check people in" on the event's days for hosts, co-hosts and stewards.
struct EventStatusControl: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let api: ApiEvent?
    let showTicket: () -> Void
    let getTickets: () -> Void
    let checkIn: () -> Void

    var body: some View {
        let d = model.derive
        let now = Int.now
        VStack(alignment: .leading, spacing: 10) {
            if e.status == .cancelled {
                Label("Cancelled" + (e.statusReason.map { ": " + $0 } ?? ""), systemImage: "xmark.octagon").foregroundStyle(.red)
            } else if d.stillGoing(e) {
                HStack(spacing: 8) {
                    Text("Changed · still going?").font(.subheadline.weight(.semibold))
                    Spacer()
                    BusyButton("Yes") { model.rsvp(e, .accepted) }.buttonStyle(.brand)
                    BusyButton("No") { model.rsvp(e, .declined) }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            } else if d.isOpen(e, now: now) {
                main(d)
            } else {
                Text("This event is over.").font(.subheadline).foregroundStyle(.secondary)
            }
            if model.mayCheckIn(e) && d.onEventDays(e, now: now) && e.status != .cancelled {
                Button(action: checkIn) {
                    Label("Check people in", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("event-checkin")
            }
        }
    }

    @ViewBuilder private func main(_ d: Derive) -> some View {
        let people = d.eventPeople(e)
        let state = api?.myState ?? d.myState(e, people)
        let real = (api.map { $0.tickets.map(\.ticket) } ?? d.tickets(e)).filter { !$0.implicit }
        if model.viewer(e)?.ticketCode != nil {
            wide("Show my ticket", symbol: "ticket", action: showTicket)
        } else if e.hosts.contains(model.me) || (d.isHost(e) && !e.meeting) {
            let asking = people.applications.count
            Text(asking > 0 ? "You’re hosting · \(asking) \(asking == 1 ? "person asks" : "people ask") for a place" : e.meeting ? "You’re hosting this meeting" : "You’re hosting")
                .font(.subheadline.weight(.semibold))
        } else {
            switch state {
            case .applied, .waitlist:
                HStack {
                    // asked for a priced ticket: the hosts confirm the payment
                    let asked = people.applications.first { $0.pubkey == model.me }?.ticket
                    let paying = state == .applied && real.first { $0.d == asked }?.price(now: .now).priced == true
                    Text(paying ? "Waiting for the host to confirm your payment" : (state.line ?? "")).font(.subheadline)
                    Spacer()
                    BusyButton("Withdraw", role: .destructive) { model.withdraw(e) }.buttonStyle(.bordered).controlSize(.small)
                }
            case .declined:
                Text(state.line ?? "").font(.subheadline).foregroundStyle(.secondary)
            default:
                if let held = people.holders[model.me] {
                    // a ticket, from a belfry that gives no code yet: no QR to show
                    Label("You have a place · " + (real.first { $0.d == held }?.title ?? "Ticket"), systemImage: "ticket")
                        .font(.subheadline.weight(.semibold))
                } else if !real.isEmpty {
                    wide("Get tickets", symbol: "ticket", action: getTickets)
                } else {
                    RsvpControl(e: e)
                }
            }
        }
    }

    private func wide(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .buttonStyle(.brand)
        .controlSize(.large)
    }
}

/// Going / Maybe / Can't go as three equal buttons; mine filled.
struct RsvpControl: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    var body: some View {
        let mine = model.derive.myRsvp(e)
        HStack(spacing: 8) {
            ForEach(Rsvp.allCases, id: \.self) { r in
                if mine == r {
                    BusyButton { model.rsvp(e, r) } label: { Text(r.label).frame(maxWidth: .infinity) }
                        .buttonStyle(.brand)
                        .accessibilityAddTraits(.isSelected)
                } else {
                    BusyButton { model.rsvp(e, r) } label: { Text(r.label).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.large)
    }
}

/// A few faces overlapping.
struct FacePile: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: -8) {
            ForEach(keys, id: \.self) { k in
                Avatar(pubkey: k, size: 26)
                    .overlay(Circle().stroke(PDSurface.color, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// What the header shows when pulled fully down: hosted by, asking (hosts), going, maybe, the
/// description, the address with Share, the hosts' tools.
struct EventFullPart: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let api: ApiEvent?
    @Binding var error: String?
    @Binding var coHost: String?
    let open: (String) -> Void
    let showPeople: () -> Void
    var push: (EventSub) -> Void = { _ in }
    let edit: () -> Void
    let tickets: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        let d = model.derive
        let lists = d.eventPeopleList(e)
        let hosts = lists.hosts.filter { d.eventRole(e, $0) != .steward }
        let host = d.isHost(e) && e.isNew && !e.remote
        let photos = d.files(e.groupId).filter(\.isImage).count
        let files = d.files(e.groupId).filter { !$0.isImage }.count
        let todos = d.tasks(e.groupId).filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            // full (board one-shape/event-full): the place with Directions, then everything
            if let l = e.location, !l.isEmpty { directions(l) }
            if !e.remote, model.group(e.groupId) != nil {
                PDRow(symbol: "checkmark.circle", title: "To-dos", value: todos > 0 ? "\(todos) open" : nil) { push(.todos) }
                PDDivider()
                PDRow(symbol: "folder", title: "Files", value: files > 0 ? "\(files)" : nil) { push(.files) }
                PDDivider()
                PDRow(symbol: "photo.on.rectangle", title: "Photos", value: photos > 0 ? "\(photos)" : nil) { push(.photos) }
                PDDivider()
                PDRow(symbol: "person.2", title: "People", value: "\(e.going)") { push(.people) }
                    .accessibilityIdentifier("event-people")
            }
            if !e.creator.isEmpty {
                PDHeader(text: "Hosted by")
                ForEach(hosts, id: \.self) { pk in
                    PersonRow(pubkey: pk, title: hostName(pk), detail: pk == e.creator ? "Host" : "Co-host") { open(pk) }
                        .padding(.horizontal, 16).padding(.vertical, 5)
                }
            }
            if host && !e.remote {
                let asking = d.eventPeople(e).applications
                if !asking.isEmpty {
                    PDHeader(text: "Asking · \(asking.count)")
                    ForEach(asking, id: \.pubkey) { a in DecideRow(e: e, a: a) { error = $0 }.padding(.horizontal, 16).padding(.vertical, 6) }
                }
            }
            people("Going", lists.going)
            people("Maybe", lists.maybe)
            if !e.description.isEmpty {
                PDHeader(text: "About")
                MarkdownText(text: e.description).padding(.horizontal, 16)
            }
            if e.isNew { address(d).id("event-address") }
            if host { hostTools() }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.subheadline).padding(16)
            }
        }
        .padding(.bottom, 28)
    }

    /// "The hall, 12 Mill Lane" and Directions (Maps).
    private func directions(_ place: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary).frame(width: 28)
            Text(place).font(.body).lineLimit(2)
            Spacer(minLength: 8)
            Button {
                var c = URLComponents(string: "https://maps.apple.com/")!
                c.queryItems = [URLQueryItem(name: "daddr", value: place)]
                if let u = c.url { UIApplication.shared.open(u) }
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("event-directions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func hostName(_ pk: String) -> String? {
        api?.hosts.first { $0.first == pk }?.last.flatMap { $0.isEmpty ? nil : $0 }
    }

    @ViewBuilder private func people(_ title: String, _ keys: [String]) -> some View {
        if !keys.isEmpty {
            PDHeader(text: "\(title) · \(keys.count)")
            ForEach(Array(keys.prefix(30)), id: \.self) { pk in
                PersonRow(pubkey: pk, title: pk == model.me ? "You" : nil) { open(pk) }
                    .padding(.horizontal, 16).padding(.vertical, 5)
            }
            if keys.count > 30 {
                PDRow(symbol: "person.2", title: "All \(keys.count) in People", action: showPeople)
            }
        }
    }

    private func address(_ d: Derive) -> some View {
        let url = d.eventURL(e)
        return VStack(alignment: .leading, spacing: 10) {
            PDHeader(text: "Address")
            Text(url).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.horizontal, 16)
            LinkButtons(url: url, subject: e.title, message: e.title)
                .padding(.horizontal, 16)
        }
    }

    private func hostTools() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PDHeader(text: "For hosts")
            PDRow(symbol: "pencil", title: "Edit the event", action: edit)
            PDDivider()
            PDRow(symbol: "ticket", title: "Tickets", value: "\(model.derive.tickets(e).filter { !$0.implicit }.count)", action: tickets)
            PDDivider()
            BusyButton {
                switch await model.coHostLink(e) {
                case .success(let u): coHost = u; UIPasteboard.general.string = u; UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failure(let x): error = x.message
                }
            } label: {
                PDRowLabel(symbol: "person.badge.plus", title: "Invite a co-host", subtitle: coHost == nil ? "A link for one person, for a day" : "Link copied: send it to them")
            }
            .buttonStyle(.plain)
            PDDivider()
            if e.status == .cancelled {
                BusyButton { model.setEventStatus(e, .scheduled) } label: { PDRowLabel(symbol: "arrow.uturn.backward", title: "Reopen the event") }
                    .buttonStyle(.plain)
            } else {
                PDRow(symbol: "xmark.octagon", title: "Cancel the event", chevron: false, action: cancel)
            }
            if e.creator == model.me {
                PDDivider()
                Button(role: .destructive, action: delete) { PDRowLabel(symbol: "trash", title: "Delete the event", destructive: true) }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// A pull-down row's look, for rows that run work (inside a BusyButton).
struct PDRowLabel: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var destructive = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body).foregroundStyle(destructive ? Color.red : Color.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body).foregroundStyle(destructive ? Color.red : Color.primary)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .padding(.vertical, subtitle == nil ? 0 : 4)
        .contentShape(Rectangle())
    }
}

/// The ticket types to take or apply for (the existing join / apply flows).
struct GetTicketsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    let api: ApiEvent?
    @State private var applying: Ticket?

    var body: some View {
        let d = model.derive
        let people = d.eventPeople(e)
        let list = (api.map { $0.tickets.map(\.ticket) } ?? d.tickets(e)).filter { !$0.implicit }
        NavigationStack {
            List {
                Section {
                    ForEach(list) { t in
                        TicketRow(e: e, t: t, people: people, held: people.holders[model.me] == t.d) { applying = t }
                    }
                } footer: { Text("Your ticket shows here once you have it, with its QR code for the door.") }
            }
            .navigationTitle("Tickets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $applying) { t in ApplySheet(e: e, t: t, full: (people.placesLeft(t) ?? 1) <= 0) }
            .onChange(of: people.holders[model.me]) { _, held in
                // a ticket arrived: refresh what the belfry says (its code for the QR)
                if held != nil { Task { await model.loadViewer(e) } }
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }
}

/// The event's photos, newest first, three to a row; Add photos sends them as a message.
struct EventPhotosTab: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    @State private var picked = [PhotosPickerItem]()
    @State private var sending = false

    var body: some View {
        let photos = model.derive.files(e.groupId).filter(\.isImage).filter { $0.url.hasPrefix("https://") || $0.url.hasPrefix("http://") }
        let urls = photos.map(\.url)
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text(photos.isEmpty ? "No photos yet" : photos.count == 1 ? "1 photo" : "\(photos.count) photos")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if !photos.isEmpty { add }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                if photos.isEmpty {
                    ContentUnavailableView {
                        Label("Add the first photos", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Everyone in the event sees them.")
                    } actions: { add }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { i, m in
                            Color.secondary.opacity(0.12)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { CachedImage(url: URL(string: m.url)) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { hideKeyboard(); model.lightbox = Lightbox(urls: urls, index: i) }
                                .accessibilityElement()
                                .accessibilityLabel("Photo \(i + 1) of \(photos.count)")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder private var add: some View {
        if model.guestReading {
            Button { model.joinAsked = true } label: { Label("Add photos", systemImage: "plus") }.buttonStyle(.bordered)
        } else {
            PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .images) {
                HStack(spacing: 6) {
                    if sending { ProgressView().controlSize(.small) } else { Image(systemName: "plus") }
                    Text(sending ? "Adding…" : "Add photos")
                }
            }
            .buttonStyle(.bordered)
            .disabled(sending)
            .accessibilityIdentifier("event-add-photos")
            .onChange(of: picked) { _, items in send(items) }
        }
    }

    /// The picked photos go out as one message through the outbox (uploaded when it flushes).
    private func send(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !sending else { return }
        sending = true
        Task {
            var atts = [Attachment]()
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = Images.jpeg(data, max: 2048) else { continue }
                let img = UIImage(data: jpeg)
                let w = img.map { Int($0.size.width * $0.scale) }, h = img.map { Int($0.size.height * $0.scale) }
                if let a = model.saveAttachment(jpeg, name: "photo-\(Int.now)-\(atts.count).jpg", mime: "image/jpeg", width: w, height: h) { atts.append(a) }
            }
            if !atts.isEmpty {
                model.post("", in: e.groupId, attachments: atts)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            picked = []
            sending = false
        }
    }
}

/// The event's people: hosts (Host / Co-host / Steward), going, maybe; a check for those who may
/// check people in; a message button on each row.
struct EventPeopleTab: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let open: (String) -> Void
    let checkIn: () -> Void

    var body: some View {
        let d = model.derive
        let lists = d.eventPeopleList(e)
        let checks = model.mayCheckIn(e) ? d.checkIns(e.groupId) : [:]
        let canMessage = !d.isGuest(model.me)
        List {
            if e.meeting {
                MeetingPeopleSection(e: e)
            } else {
                Section {
                    ForEach(lists.hosts, id: \.self) { pk in
                        row(pk, detail: d.eventRole(e, pk).label, checks: checks, message: canMessage)
                    }
                } header: {
                    Text("Hosts")
                } footer: {
                    // who may check people in sees how far it got (Check people in: the ⋯ menu)
                    if model.mayCheckIn(e) { Text("\(checks.count) of \(model.attendees(e).people.count) checked in") }
                }
                Section("Going · \(lists.going.count)") {
                    if lists.going.isEmpty { Text("Nobody yet.").foregroundStyle(.secondary) }
                    ForEach(lists.going, id: \.self) { pk in row(pk, detail: nil, checks: checks, message: canMessage) }
                }
                if !lists.maybe.isEmpty {
                    Section("Maybe · \(lists.maybe.count)") {
                        ForEach(lists.maybe, id: \.self) { pk in row(pk, detail: nil, checks: checks, message: canMessage) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.showProfile) { pk in open(pk) }
    }

    private func row(_ pk: String, detail: String?, checks: [String: Int], message: Bool) -> some View {
        PersonRow(pubkey: pk, title: pk == model.me ? "You" : nil, detail: detail, checked: checks[pk] != nil,
                  message: message && pk != model.me) { open(pk) }
    }
}

extension View {
    /// The iOS 26 navigation bar blurs what scrolls under it: not over the event's cover.
    @ViewBuilder func noTopEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { self.scrollEdgeEffectHidden(true, for: .top) } else { self }
        #else
        self
        #endif
    }
}
