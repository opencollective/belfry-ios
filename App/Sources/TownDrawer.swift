import BelfryCore
import SwiftUI

// The menu (☰ or a swipe from the left; Navigation v2, boards nav2/drawer and drawer-unread,
// approved 2026-11-22): the belfry's cover (when branding has one), its mark, name and member
// count, a gear for Belfry settings (stewards); Today, Messages, Mentions, Calendar (each opens
// its place or screen); GROUPS (the groups I'm in, ＋ = new group, anyone); CHANNELS (＋ = Add a
// channel: pinned for everyone, pinned for me, then recent = mentioned / posted / reacted in the
// last 30 days, newest activity first; no "All channels", no follow); Archived; you at the
// bottom (tap for Me, ⇅ for the accounts and belfries). Unread like Discord: a row with new
// messages is bold with a count; Mentions has a red count.
// A guest's drawer (board iOS-Town 3): Apply first, the channels they were invited to, the places
// open to everyone, and their own row.

struct TownDrawer: View {
    @EnvironmentObject var model: AppModel
    let current: SidebarItem?
    /// Home is on screen (Today is the selected row).
    var onHome = false
    let select: (SidebarItem) -> Void
    var today: () -> Void = {}
    /// A new channel in that category.
    let newChannel: (String) -> Void
    let account: () -> Void
    let me: () -> Void
    let apply: () -> Void
    let open: (SearchTarget) -> Void
    /// A place of the bar (Messages, Calendar).
    var go: (AppTab) -> Void = { _ in }
    /// A screen pushed on the place on screen (Mentions, Add a channel).
    var push: (PlaceRoute) -> Void = { _ in }
    var newGroup: () -> Void = {}

    var body: some View {
        let _ = model.version
        let guest = model.derive.amGuest || model.guestReading
        VStack(spacing: 0) {
            if let cover = model.config.branding?.cover, !cover.isEmpty, cover.hasPrefix("https://"), let u = URL(string: cover) {
                CachedImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                    .frame(height: 96).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16).padding(.top, 4)
                    .accessibilityHidden(true)
            }
            header(guest: guest)
            // no search field here (Xavier 2026-11-18, boards channels/drawer, drawer-steward):
            // search is each channel's magnifier
            if guest { guestList } else { memberList }
            Divider()
            youRow(guest: guest)
        }
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func header(guest: Bool) -> some View {
        HStack(spacing: 10) {
            BelfryLogo(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.config.name).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                Text(guest ? model.guestLine : memberLine).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if !guest && model.derive.isCommunityAdmin {
                Button { select(.settings) } label: {
                    Image(systemName: "gearshape").font(.body.weight(.semibold)).frame(width: 36, height: 36).glass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Belfry settings")
                .accessibilityIdentifier("drawer-settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// From the belfry's directory (the last answer, kept); nothing until it is known.
    private var memberLine: String {
        // the demo counts its own people, as they arrive
        let known: Int? = model.isDemo ? Optional(model.memberKeys.count) : model.directoryCount
        guard let n = known, n > 0 else { return "" }
        return n == 1 ? "1 member" : "\(n) members"
    }

    private var memberList: some View {
        let d = model.derive
        let m = model.menu
        let everyone = Set(model.pinnedForEveryone)
        let groups = model.myGroups
        let archived = d.myArchived()
        return List {
            Group {
                if model.access == .denied {
                    Section {
                        Label("You’re logged in, but not a member of \(model.config.name) yet.", systemImage: "lock").font(.callout)
                        Button("Apply to join") { model.showAlmostIn = true }.accessibilityIdentifier("almost-in")
                    }
                }
                Section {
                    placeRow(icon: "sun.max", title: "Today", note: nil, badge: 0, on: onHome, action: today)
                        .accessibilityIdentifier("drawer-today")
                    placeRow(icon: "bubble.left.and.bubble.right", title: "Messages", note: nil, badge: model.unreadDMs, on: model.tab == .messages) { go(.messages) }
                        .accessibilityIdentifier("drawer-messages")
                    placeRow(icon: "at", title: "Mentions", note: nil, badge: model.newMentions, red: true, on: current == .mentions) { push(.mentions) }
                        .accessibilityIdentifier("drawer-mentions")
                    placeRow(icon: "calendar", title: "Calendar", note: nil, badge: 0, on: model.tab == .calendar) { go(.calendar) }
                        .accessibilityIdentifier("drawer-calendar")
                    // Members and Charter stay in the menu (they left it in 0.8.0 by mistake: the
                    // member directory had no other way in; the lead, 2026-11-22)
                    placeRow(icon: "person.2", title: PlaceNames.members, note: nil, badge: model.requestCount, on: current == .members || current == .requests) { push(.members) }
                        .accessibilityIdentifier("drawer-members")
                    if d.charterGroup != nil || d.isCommunityAdmin {
                        placeRow(icon: "doc.text", title: "Charter", note: nil, badge: d.charterToAgree().count, on: current == .charter) { push(.charter) }
                            .accessibilityIdentifier("drawer-charter")
                    }
                }
                Section {
                    sectionHeader("Groups", add: "New group", id: "drawer-new-group", action: newGroup)
                    ForEach(groups) { g in townRow(g, glyph: true) }
                }
                Section {
                    sectionHeader("Channels", add: "Add a channel", id: "drawer-add-channel") { push(.addChannel) }
                    ForEach(m.pinned, id: \.self) { id in
                        if let g = d.group(id) { townRow(g, pin: everyone.contains(id) || id == generalId ? .everyone : .mine) }
                    }
                    ForEach(m.recent, id: \.self) { id in
                        if let g = d.group(id) { townRow(g) }
                    }
                }
                Section {
                    if !archived.isEmpty {
                        placeRow(icon: "archivebox", title: "Archived", note: nil, badge: 0, on: current == .archived, muted: true) { select(.archived) }
                            .accessibilityIdentifier("drawer-archived")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.refresh(); await model.loadRequests(force: true) }
        .task { await model.loadRequests(); await model.loadDirectoryCount() }
    }

    /// A section's title in small caps, ＋ on its right.
    private func sectionHeader(_ name: String, add: String, id: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(name.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(add)
            .accessibilityIdentifier(id)
        }
        .padding(.top, 10)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private var guestList: some View {
        let mine = model.guestChannels
        let open = model.openToEveryone
        return List {
            Section {
                placeRow(icon: "sun.max", title: "Today", note: nil, badge: 0, on: onHome, action: today)
                    .accessibilityIdentifier("drawer-today")
            }
            Section {
                Button(action: apply) {
                    Text(model.guestApplied ? "Request sent" : "Apply to become a member").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand)
                .disabled(model.guestApplied)
                .listRowBackground(Color.clear)
            }
            if !mine.isEmpty {
                Section { sectionTitle("You were invited to"); ForEach(mine) { townRow($0) } }
            }
            if !open.isEmpty || !model.charterRules.isEmpty {
                Section {
                    sectionTitle("Open to everyone")
                    if !model.charterRules.isEmpty {
                        placeRow(icon: "doc.text", title: "Charter", note: nil, badge: 0, on: current == .charter) { select(.charter) }
                    }
                    ForEach(open) { townRow($0) }
                }
            }
            Section {
                Text("Read-only for guests. Members also have the Townsquare, every channel and Members.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 10)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }

    enum PinMark { case none, everyone, mine }

    /// A channel (#) or group (its glyph): the name (a globe when public), 📌 when pinned, the
    /// unread count; bold with news.
    private func townRow(_ g: Channel, pin: PinMark = .none, glyph: Bool = false) -> some View {
        let n = model.unread(g.id)
        let on = current == .channel(g.id)
        let name = g.named ? g.name : BelfryCore.Group.kindTitle(g.id)
        return Button { select(.channel(g.id)) } label: {
            HStack(spacing: 12) {
                if glyph { ChannelGlyph(group: g, size: 22).frame(width: 24) }
                else { Image(systemName: "number").font(.body.weight(.medium)).foregroundStyle(.secondary).frame(width: 24) }
                GroupTitle(group: g, id: g.id).font(.body.weight(n > 0 || on ? .semibold : .regular)).lineLimit(1)
                if model.derive.isPublic(g) {
                    Image(systemName: "globe").font(.caption).foregroundStyle(.secondary).accessibilityLabel("public")
                }
                if pin != .none {
                    Image(systemName: "pin").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(pin == .everyone ? "pinned for everyone" : "pinned for you")
                }
                Spacer(minLength: 4)
                if n > 0 { Text(n > 99 ? "99+" : "\(n)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary) }
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(on ? Color.primary.opacity(0.08) : Color.clear)
        .accessibilityLabel(n > 0 ? "\(name), \(n) unread" : name)
        .accessibilityIdentifier("drawer-channel-" + g.id)
    }

    private func placeRow(icon: String, title: String, note: String?, badge: Int, red: Bool = false, on: Bool, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(.secondary).frame(width: 24)
                Text(title).font(.body.weight(on || (badge > 0 && !red) ? .semibold : .regular)).foregroundStyle(muted ? .secondary : .primary)
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if badge > 0 {
                    if red {
                        Text(badge > 99 ? "99+" : "\(badge)").font(.caption.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(Color.red, in: Capsule()).foregroundStyle(.white)
                            .accessibilityLabel("\(badge) new")
                    } else { Text(badge > 99 ? "99+" : "\(badge)").font(.subheadline.weight(.semibold)).monospacedDigit() }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(on ? Color.primary.opacity(0.08) : Color.clear)
    }

    /// You: face, name, address (or "Guest · 7 days left"); tap for Me; ⇅ for accounts.
    private func youRow(guest: Bool) -> some View {
        let name = model.realName(model.me).isEmpty ? "You" : model.realName(model.me)
        let line = guest ? (["Guest", model.guestDaysLeft].compactMap { $0 }.joined(separator: " · ")) : (model.derive.myAddress ?? model.config.domain)
        return HStack(spacing: 10) {
            Button(action: me) {
                HStack(spacing: 10) {
                    Avatar(pubkey: model.me, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.body.weight(.semibold)).lineLimit(1)
                        Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    ConnectionDot()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Me: \(name)")
            .accessibilityIdentifier("drawer-me")
            Button(action: account) {
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch account or belfry")
            .accessibilityIdentifier("drawer-switch")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
