import BelfryCore
import SwiftUI

// Town's drawer (☰ or a swipe from the left, board iOS-Town 2; also Home's ☰ since 2026-11-17):
// the belfry's cover (when branding has one), its mark, name and member count, a gear for Belfry
// settings (stewards); search; Today (Home); The town (Square, Members with their requests,
// Charter); then the categories (SPEC 19.34: Community life, Building together and the stewards'
// own), each header with ＋ for a new channel in it (Community life for anyone who may create a
// channel, every category for stewards); a globe marks a public channel; Archived. Stewards
// long-press a channel and drag it to move it, within and across categories. At the bottom: you
// (face, name, name@domain): tap for Me, ⇅ for the accounts and belfries.
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
            if guest { guestList } else {
                search
                memberList
            }
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

    private var memberLine: String {
        let n = model.memberKeys.count
        return n == 1 ? "1 member" : "\(n) members"
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the town", text: $model.drawerQuery).font(.body).submitLabel(.search)
            if !model.drawerQuery.isEmpty {
                Button { model.drawerQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var memberList: some View {
        let d = model.derive
        let admin = d.isCommunityAdmin
        let chans = d.townChannels()
        let general = chans.first { $0.id == generalId }
        let byId = Dictionary(chans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let all = d.channelCategories()
        let cats = Categories.shown(all, admin: admin)
        let rows = Categories.flat(cats)
        let names = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let archived = d.myArchived()
        let requests = model.requestCount
        return List {
            if !model.drawerQuery.isEmpty {
                SearchResults(query: model.drawerQuery, open: open)
            } else {
                if model.access == .denied {
                    Section {
                        Label("This belfry doesn't let your key in yet. Ask a steward, or check your membership.", systemImage: "lock").font(.callout)
                    }
                }
                Section {
                    placeRow(icon: "sun.max", title: "Today", note: nil, badge: model.homeCount, on: onHome, action: today)
                        .accessibilityIdentifier("drawer-today")
                }
                Section {
                    if let general { townRow(general) }
                    placeRow(icon: "person.2", title: PlaceNames.members, note: nil, badge: requests, on: current == .members || current == .requests) { select(.members) }
                        .accessibilityIdentifier("drawer-members")
                    if d.charterGroup != nil || d.isCommunityAdmin {
                        let left = d.charterToAgree().count
                        placeRow(icon: "doc.text", title: "Charter", note: nil, badge: left, on: current == .charter) { select(.charter) }
                            .accessibilityIdentifier("drawer-charter")
                    }
                } header: { sectionTitle(PlaceNames.Section.town.title) }
                // the categories as one flat list (headers are rows) so a channel can be dragged
                // across them; only the belfry's admins can drag
                Section {
                    ForEach(rows, id: \.self) { r in
                        switch r {
                        case .header(let cid):
                            categoryHeader(cid, names[cid] ?? cid, admin: admin)
                                .moveDisabled(true)
                        case .channel(let cid):
                            if let g = byId[cid] {
                                townRow(g).moveDisabled(!admin)
                            }
                        }
                    }
                    .onMove(perform: admin ? mover(rows, all) : nil)
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
        .task { await model.loadRequests() }
    }

    /// A category's title, ＋ on its right for a new channel in it (Community life: anyone who may
    /// create a channel; every category: the belfry's admins).
    private func categoryHeader(_ id: String, _ name: String, admin: Bool) -> some View {
        HStack {
            sectionTitle(name)
            Spacer()
            if admin || id == ChannelCategory.life {
                Button { newChannel(id) } label: {
                    Image(systemName: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New channel in \(name)")
                .accessibilityIdentifier("category-add-" + id)
            }
        }
        .padding(.top, 10)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// A drag in the flat list: the categories rebuilt, published at once (latest wins).
    private func mover(_ rows: [CategoryRow], _ all: [ChannelCategory]) -> (IndexSet, Int) -> Void {
        { from, to in
            var flat = rows
            flat.move(fromOffsets: from, toOffset: to)
            model.setChannelLayout(Categories.rebuild(all, flat: flat))
        }
    }

    private var guestList: some View {
        let mine = model.guestChannels
        let open = model.openToEveryone
        return List {
            Section {
                Button(action: apply) {
                    Text(model.guestApplied ? "Request sent" : "Apply to become a member").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand)
                .disabled(model.guestApplied)
                .listRowBackground(Color.clear)
            }
            if !mine.isEmpty {
                Section { ForEach(mine) { townRow($0) } } header: { sectionTitle("You were invited to") }
            }
            if !open.isEmpty || !model.charterRules.isEmpty {
                Section {
                    if !model.charterRules.isEmpty {
                        placeRow(icon: "doc.text", title: "Charter", note: nil, badge: 0, on: current == .charter) { select(.charter) }
                    }
                    ForEach(open) { townRow($0) }
                } header: { sectionTitle("Open to everyone") }
            }
            Section {
                Text("Read-only for guests. Members also have the Square, its events, groups and more.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// A channel: #, its name (a globe when public), the unread count.
    private func townRow(_ g: Channel) -> some View {
        let n = model.unread(g.id)
        let on = current == .channel(g.id)
        return Button { select(.channel(g.id)) } label: {
            HStack(spacing: 12) {
                Image(systemName: "number").font(.body.weight(.medium)).foregroundStyle(.secondary).frame(width: 24)
                Text(g.name).font(.body.weight(n > 0 || on ? .semibold : .regular)).lineLimit(1)
                if model.derive.isPublic(g) {
                    Image(systemName: "globe").font(.caption).foregroundStyle(.secondary).accessibilityLabel("public")
                }
                Spacer(minLength: 4)
                if n > 0 { Text(n > 99 ? "99+" : "\(n)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(on ? Color.primary.opacity(0.08) : Color.clear)
        .accessibilityLabel(n > 0 ? "\(g.name), \(n) unread" : g.name)
    }

    private func placeRow(icon: String, title: String, note: String?, badge: Int, on: Bool, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(.secondary).frame(width: 24)
                Text(title).font(.body.weight(on ? .semibold : .regular)).foregroundStyle(muted ? .secondary : .primary)
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if badge > 0 { CountBadge(n: badge) }
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
