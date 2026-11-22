import BelfryCore
import SwiftUI

// The channel's own screens (2026-11-17, the owner: "show a menu Groups > instead of listing the
// groups… since there is a > I expect the list to slide from the right"). The pull-down is the
// description and a menu of rows; each row pushes one of these screens on the channel's stack:
// Pinned, Events, To decide, To-dos, Photos, Files, Groups, Topics, Members (with Invite),
// Notifications, Log, Settings (those who may edit the channel). Channel info is gone.

enum ChannelPlace: String, Hashable, Identifiable {
    case pinned, events, proposals, todos, photos, files, groups, topics, members, notifications, log, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .events: return "Events"
        case .proposals: return "To decide"
        case .todos: return "To-dos"
        case .photos: return "Photos"
        case .files: return "Files"
        case .groups: return "Groups"
        case .topics: return "Topics"
        case .members: return "Members"
        case .notifications: return "Notifications"
        case .log: return "Log"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .pinned: return "pin"
        case .events: return "calendar"
        case .proposals: return "doc.text"
        case .todos: return "checklist"
        case .photos: return "photo.on.rectangle"
        case .files: return "doc"
        case .groups: return "hexagon"
        case .topics: return "number"
        case .members: return "person.2"
        case .notifications: return "bell"
        case .log: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// A channel's screen, pushed from its pull-down.
struct ChannelPlaceView: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let place: ChannelPlace
    /// Back to the channel, at a message (Pinned, Log) or a thread (Log); a topic filter (Topics).
    let go: (LogGo) -> Void
    let filter: (String) -> Void
    /// A to-do opened from the To-dos screen (its own screen, pushed).
    @State private var todo: TodoKey?

    var body: some View {
        let _ = model.version
        SwiftUI.Group {
            switch place {
            case .events: EventsScreen(channel: id, sheet: true)
            case .members: ChannelMembersScreen(id: id)
            default: list
            }
        }
        .navigationTitle(place.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $todo) { k in TodoScreen(key: k, go: go).overRoot() }
        .task {
            // screenshots: a to-do's own screen (and its Assign to…). The demo's to-dos may not be
            // derived yet when this appears (the dark pass of 44337540709 shot the list): wait for them.
            guard place == .todos, ["todo", "todoassign"].contains(model.launch.screen ?? "") else { return }
            for _ in 0..<40 {
                if todo != nil { return }
                // -todo done: the done one (canvas one-shape/todo-done)
                let args = ProcessInfo.processInfo.arguments
                let wantDone = args.firstIndex(of: "-todo").map { $0 + 1 < args.count && args[$0 + 1] == "done" } ?? false
                let list = model.derive.tasks(id)
                // an open one with a due date shows the mid level (canvas one-shape/todo-mid)
                if let t = (wantDone ? nil : list.first(where: { !$0.done && $0.due != nil })) ?? list.first(where: { $0.done == wantDone }) {
                    try? await Task.sleep(for: .milliseconds(600))
                    todo = TodoKey(group: id, task: t.id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var list: some View {
        List {
            switch place {
            case .pinned: PinnedSection(id: id, go: go)
            case .proposals: ProposalsSection(id: id)
            case .todos: TodosTab(id: id) { t in todo = TodoKey(group: id, task: t.id) }
            case .photos: PhotosSection(id: id)
            case .files: FilesTab(id: id)
            case .groups: GroupsSection(id: id)
            case .topics: TopicsSection(id: id, topic: Binding(get: { nil }, set: { if let t = $0 { filter(t) } }), done: {})
            case .notifications: FollowBell(id: id)
            case .log: LogTab(id: id) { g in go(g) }
            case .settings: SettingsTab(id: id)
            case .events, .members: EmptyView()
            }
        }
    }
}

/// The pinned messages: each opens the channel at it; admins unpin.
struct PinnedSection: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let go: (LogGo) -> Void
    var body: some View {
        let d = model.derive
        let pins = d.pinned(id)
        Section {
            if pins.isEmpty { Text("Nothing pinned.").foregroundStyle(.secondary) }
            ForEach(pins) { m in
                Button { go(.message(m.id)) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(pubkey: m.pubkey, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.pinLine(m)).font(.body).foregroundStyle(.primary).lineLimit(3)
                            Text(model.name(m.pubkey) + " · " + Format.day(m.at)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if d.canAdmin(model.group(id)) && !model.locked(id) {
                        Button("Unpin") { model.pin(m, in: id, false) }.tint(.orange)
                    }
                }
            }
        } footer: { Text("Tap one to see it in the channel.") }
    }
}

/// Open proposals made in this channel.
struct ProposalsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    var body: some View {
        let d = model.derive
        let all = d.proposalsIn(id)
        let props = all.filter { $0.status.isOpen } + all.filter { !$0.status.isOpen }
        Section {
            if props.isEmpty { Text("No proposals here.").foregroundStyle(.secondary) }
            ForEach(props) { p in
                NavigationLink(value: ChatRoute(id: p.groupId)) {
                    HStack {
                        ActionRow(icon: "doc.text", title: p.title, detail: p.status.label)
                        if p.votingNow { Text(d.myVote(p) == nil ? "Vote" : "Voted").font(.subheadline).foregroundStyle(d.myVote(p) == nil ? Color.brand : .secondary) }
                    }
                }
            }
        }
    }
}

/// The groups made in this channel: each pushes its chat (or its page when I'm not in it).
struct GroupsSection: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var body: some View {
        let pods = model.derive.pods(id)
        Section {
            if pods.isEmpty { Text("No groups here yet.").foregroundStyle(.secondary) }
            ForEach(pods) { p in
                let mine = p.members.contains(model.me) || p.admins.contains(model.me)
                SwiftUI.Group {
                    if mine {
                        NavigationLink(value: ChatRoute(id: p.id)) { row(p) }
                    } else {
                        NavigationLink(value: GroupRoute(id: p.id)) { row(p) }
                    }
                }
            }
        }
    }

    private func row(_ p: Channel) -> some View {
        HStack(spacing: 12) {
            PlaceGlyph(group: p)
            VStack(alignment: .leading, spacing: 1) {
                GroupTitle(group: p, id: p.id).font(.body.weight(.medium))
                Text(p.members.count == 1 ? "1 member" : "\(p.members.count) members").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// The channel's photos, newest first; a tap opens the lightbox.
struct PhotosSection: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var body: some View {
        let photos = model.derive.files(id).filter(\.isImage)
        Section {
            if photos.isEmpty { Text("No photos yet.").foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(photos, id: \.url) { m in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { MediaThumb(media: m, all: photos) }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .listRowInsets(EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3))
        }
    }
}

/// Members of the channel (Invite at the top for whoever may invite), who was active this month,
/// and Join / Leave at the bottom. A row pushes the profile (with the role here).
struct ChannelMembersScreen: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var invite = false
    @State private var asking = false
    @State private var profile: ProfileKey?

    var body: some View {
        let _ = model.version
        let d = model.derive
        let g = model.group(id)
        let mayInvite = !model.guestReading && g?.archived != true
        let active = d.recentlyActive(id)
        List {
            if mayInvite {
                Section {
                    Button { hideKeyboard(); invite = true } label: { Label("Invite someone", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("members-invite")
                }
            }
            // people asking to join a closed channel or group: at the top, for its stewards (and,
            // while it accepts by vouches, its members)
            if let g, !g.archived, g.isPod || g.closed {
                let reqs = d.canAdmin(g) ? g.applications : d.groupRequestsFor(g)
                if !reqs.isEmpty {
                    Section {
                        ForEach(reqs, id: \.id) { a in GroupRequestRow(group: g, pubkey: a.pubkey, answer: a.answer) }
                    } header: { Text("Asking to join · \(reqs.count)") }
                    .accessibilityIdentifier("members-requests")
                }
            }
            MembersTab(id: id) { profile = ProfileKey(pubkey: $0, group: id) }
            if !active.isEmpty {
                Section("Active in the last 30 days") {
                    ForEach(active, id: \.pubkey) { a in
                        PersonRow(pubkey: a.pubkey, title: a.pubkey == model.me ? "You" : model.name(a.pubkey), detail: Format.ago(a.at)) {
                            profile = ProfileKey(pubkey: a.pubkey, group: id)
                        }
                    }
                }
            }
            if let g, g.archived != true, !model.guestReading {
                if !g.members.contains(model.me), !g.admins.contains(model.me), !g.isPod {
                    if d.needsJoinBar(g) {
                        // a closed channel: ask, then wait for its stewards
                        if g.applications.contains(where: { $0.pubkey == model.me }) {
                            Section { Label("Pending: the channel's stewards will answer.", systemImage: "clock").foregroundStyle(.secondary) }
                        } else {
                            Section { Button { asking = true } label: { Label("Ask to join", systemImage: "person.crop.circle.badge.questionmark") } }
                        }
                    } else {
                        Section { ActionButtonRow(icon: "person.crop.circle.badge.plus", title: "Join") { model.join(id) } }
                    }
                }
                if g.isPod, g.members.contains(model.me) {
                    Section { ActionButtonRow(icon: "rectangle.portrait.and.arrow.right", title: "Leave the group", destructive: true) { model.leave(id) } }
                }
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $profile) { ProfileView(pubkey: $0.pubkey, pushed: true, group: $0.group).overRoot() }
        .sheet(isPresented: $invite) { InviteSheet(id: id) }
        .sheet(isPresented: $asking) { if let g { PodApplySheet(group: g) } }
        .task {
            await model.revalidateConfig()
            await model.askWhois(Array(g?.members ?? []).filter { model.derive.guestJoinKeys.contains($0) })
        }
        .onAppear { if model.launch.screen == "membersinvitech" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { invite = true } } }
    }
}

/// The counts the header and the pull-down show (from the local log only).
struct ChannelCounts {
    let active: Int
    let photos: Int
    let groups: Int
    let pins: Int
    let events: Int
    let proposals: Int
    let todos: Int
    let todosDone: Int
    let files: Int
    let topics: Int
    let members: Int

    @MainActor init(_ model: AppModel, _ id: String) {
        let d = model.derive
        let all = d.files(id)
        active = d.recentlyActive(id).count
        photos = all.filter(\.isImage).count
        groups = d.pods(id).count
        pins = d.pinned(id).count
        events = d.upcoming(id, now: .now).count
        proposals = d.proposalsIn(id).filter { $0.status.isOpen }.count
        let t = d.tasks(id)
        todos = t.count
        todosDone = t.filter(\.done).count
        files = all.filter { !$0.isImage }.count + d.dropLinks(id, now: .now).count
        let pinnedTopics = d.pinnedTopics(id).filter { $0 != Derive.announcement }
        topics = Set(pinnedTopics + d.topicCounts(id).map(\.topic)).count + (d.hasAnnouncements(id) ? 1 : 0)
        members = model.group(id)?.members.count ?? 0
    }
}

/// Under the channel's name: lock (members only) or globe (public), "6 active", then photos and
/// groups as small icon + count pairs, each only when there are any.
struct ChannelSubtitle: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var body: some View {
        let g = model.group(id)
        let c = ChannelCounts(model, id)
        let pub = model.derive.isPublic(g)
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: pub ? "globe" : "lock").imageScale(.small)
                Text("\(c.active) active")
            }
            if c.photos > 0 {
                HStack(spacing: 2) { Image(systemName: "photo").imageScale(.small); Text("\(c.photos)") }
            }
            if c.groups > 0 {
                HStack(spacing: 2) {
                    PodShape(members: 6).stroke(Color.secondary, lineWidth: 1.1).frame(width: 9, height: 9)
                    Text("\(c.groups)")
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(c, pub))
    }

    private func label(_ c: ChannelCounts, _ pub: Bool) -> String {
        var parts = [pub ? "Public" : "Members only", "\(c.active) active this month"]
        if c.photos > 0 { parts.append("\(c.photos) photos") }
        if c.groups > 0 { parts.append("\(c.groups) groups") }
        return parts.joined(separator: ", ")
    }
}
