import BelfryCore
import SwiftUI

// Members (web Directory.tsx, 8f0ccb8 / 98c33fc): the first row of the drawer. At its top, only
// when something waits, the request sections (agents asking to join, people asking to join the
// belfry, requests to my groups: RequestsView.swift); then everyone in the belfry, their own
// agents under them, with search.

struct MembersDirectory: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var list: [DirMember]?
    @State private var failed = false
    @State private var demo = false
    @State private var error: String?
    @State private var inviting = false

    var body: some View {
        let _ = model.version
        let shown = filtered()
        let sections = Dictionary(grouping: shown) { letter(name($0.pubkey, $0.name)) }
        let letters = sections.keys.sorted { a, b in a == "#" ? false : b == "#" ? true : a < b }
        List {
            if query.isEmpty {
                // My card, as in Contacts
                Button { model.openProfile = model.me } label: {
                    HStack(spacing: 12) {
                        Avatar(pubkey: model.me, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.realName(model.me).isEmpty ? "You" : model.realName(model.me)).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            Text("My card").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // what waits for me, only when something does (web 98c33fc)
                RequestSections(error: $error)
            }
            if list == nil {
                HStack { if failed { Text("The list could not be loaded.") } else { ProgressView(); Text("Loading…") } }.foregroundStyle(.secondary)
            }
            ForEach(letters, id: \.self) { l in
                letterSection(l, sections[l] ?? [])
            }
            if list != nil {
                Text("\(shown.count) \(shown.count == 1 ? "member" : "members")").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .sectionIndex()
        .navigationTitle(PlaceNames.gates)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { DrawerButton() }
            // Xavier 2026-11-15: invite from here; only for who may invite members (no disabled button)
            if model.mayInviteMembers, inviteChannel != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { hideKeyboard(); inviting = true } label: { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel("Invite someone")
                        .accessibilityIdentifier("members-invite")
                }
            }
        }
        .sheet(isPresented: $inviting) {
            if let c = inviteChannel { InviteSheet(id: c, startAs: .member(role: model.roles.defaultRole, membership: "permanent")) }
        }
        .onAppear { if model.launch.screen == "membersinvite" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { inviting = true } } }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func letterSection(_ l: String, _ people: [DirMember]) -> some View {
        Section {
            ForEach(people) { m in
                Button { model.openProfile = m.pubkey } label: { row(m.pubkey, m.name, size: 40, detail: nil, role: model.roles.label(of: m.pubkey) ?? roleLabel(m.role)) }
                    .buttonStyle(.plain)
                ForEach(m.agents, id: \.pubkey) { a in
                    Button { model.openProfile = a.pubkey } label: { row(a.pubkey, a.name, size: 40, detail: "agent of \(name(m.pubkey, m.name))", role: nil) }
                        .buttonStyle(.plain)
                        .padding(.leading, 24)
                }
            }
        } header: { Text(l) }
        .indexLabel(l)
    }

    /// Where a member invited from here lands: #general, else the first public channel in the
    /// admins' order, else the first channel.
    private var inviteChannel: String? {
        if model.group(generalId) != nil { return generalId }
        let s = model.derive.channelSections()
        return s.pub.first?.id ?? s.members.first?.id
    }

    /// The letter a name files under (accents folded; anything else under #).
    private func letter(_ n: String) -> String {
        let f = n.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        guard let c = f.first, c.isLetter, c.isASCII else { return "#" }
        return String(c)
    }

    private var rule: String {
        model.membership.accept == "vouches"
            ? (model.membership.vouches == 1 ? "One vouch" : "\(model.membership.vouches) vouches") + " from members let someone in."
            : "Vouch for the people you know: the admins decide, and they see who vouched."
    }

    private func roleLabel(_ id: String?) -> String? {
        guard let id, id != Role.member else { return nil }
        return model.roles.role(id)?.label
    }

    private func name(_ pk: String, _ fallback: String) -> String {
        let n = model.realName(pk)
        return !n.isEmpty ? n : (!fallback.isEmpty ? fallback : model.name(pk))
    }

    private func filtered() -> [DirMember] {
        let q = query.jsTrim().lowercased()
        return (demo ? demoList() : (list ?? [])).filter { m in
            q.isEmpty || name(m.pubkey, m.name).lowercased().contains(q) || m.agents.contains { name($0.pubkey, $0.name).lowercased().contains(q) }
        }.sorted { name($0.pubkey, $0.name).localizedStandardCompare(name($1.pubkey, $1.name)) == .orderedAscending }
    }

    /// The demo: who is in its channels (worked out live: the demo's events arrive after launch).
    private func demoList() -> [DirMember] {
        let d = model.derive
        let keys = Set(model.groups.flatMap(\.members)).filter { !d.isGuest($0) && d.agentOwner($0) == nil }
        return keys.map { k in DirMember(pubkey: k, name: "", role: nil, agents: model.config.agents.filter { $0.value == k }.map { (pubkey: $0.key, name: "") }) }
    }

    private func row(_ pk: String, _ fallback: String, size: CGFloat, detail: String?, role: String?) -> some View {
        HStack(spacing: 10) {
            Avatar(pubkey: pk, size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(pk, fallback)).font(.body).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            if let role { Text(role).font(.subheadline).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        await model.loadRequests(force: true)
        await model.loadRoles()
        if model.engine?.localOnly == true {
            demo = true
            list = []
        } else {
            do { list = try await model.api.directory() } catch { failed = true }
        }
    }
}

extension View {
    /// The A–Z index on the right edge (iOS 26).
    @ViewBuilder func sectionIndex() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { self.listSectionIndexVisibility(.visible) } else { self }
        #else
        self
        #endif
    }

    @ViewBuilder func indexLabel(_ l: String) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { self.sectionIndexLabel(Text(l)) } else { self }
        #else
        self
        #endif
    }
}
