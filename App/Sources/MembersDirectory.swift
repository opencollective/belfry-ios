import BelfryCore
import SwiftUI

// Members (web Directory.tsx, 8f0ccb8 / 98c33fc): the first row of the drawer. At its top, only
// when something waits, the request sections (agents asking to join, people asking to join the
// belfry, requests to my groups: RequestsView.swift); then everyone in the belfry, their own
// agents folded into their row ("+ 2 agents"; Xavier, 2026-11-20, board home/members), with search.

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
                // what waits for me, only when something does (web 98c33fc)
                RequestSections(error: $error)
            }
            if list == nil {
                HStack { if failed { Text("The list could not be loaded.") } else { ProgressView(); Text("Loading…") } }.foregroundStyle(.secondary)
            }
            if list != nil, !shown.isEmpty {
                Text(shown.count == 1 ? "1 person" : "\(shown.count) people").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(letters, id: \.self) { l in
                letterSection(l, sections[l] ?? [])
            }
        }
        .listStyle(.plain)
        .sectionIndex()
        .navigationTitle(PlaceNames.members)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .drawerItem()
        // "add one" is an icon top right, never a first row (Xavier, 2026-11-22: "adding a new
        // member should be top right like creating a new group"); only for who may invite
        .toolbar {
            if model.mayInviteMembers, inviteChannel != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { hideKeyboard(); inviting = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Invite someone")
                        .accessibilityIdentifier("members-invite")
                }
            }
        }
        .sheet(isPresented: $inviting) {
            if let c = inviteChannel { InviteSheet(id: c, startAs: .member(role: model.roles.defaultRole, membership: "permanent")) }
        }
        // screenshots: a member's row with "+ N agents" (found by the member's name), and an
        // agent's name typed: its member shows, the agent named under it
        .onAppear {
            guard query.isEmpty else { return }
            if model.launch.screen == "membersagents" { query = "sam" }
            if model.launch.screen == "memberssearch" { query = "minutes" }
        }
        .onAppear { if model.launch.screen == "membersinvite" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { inviting = true } } }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func letterSection(_ l: String, _ people: [DirMember]) -> some View {
        Section {
            // a member's agents have no row of their own: a grey second line on the member's row
            // (their profile lists them); an agent that belongs to nobody here is in the list itself
            ForEach(people) { m in
                Button { model.openProfile = m.pubkey } label: { row(m.pubkey, m.name, size: 40, detail: agentsLine(m), role: roleLine(m)) }
                    .buttonStyle(.plain)
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

    /// "You · Steward", "Steward", "Gardener"; nothing for a plain member.
    private func roleLine(_ m: DirMember) -> String? {
        let role = model.roles.label(of: m.pubkey) ?? roleLabel(m.role)
        let parts = [m.pubkey == model.me ? "You" : nil, role].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "+ 1 agent" / "+ 2 agents"; while a search matches an agent's name and not the member's,
    /// the agents that match, the match in bold ("+ **Comp**ost bot").
    private func agentsLine(_ m: DirMember) -> AttributedString? {
        guard !m.agents.isEmpty else { return nil }
        let q = query.jsTrim().lowercased()
        let hits = q.isEmpty || name(m.pubkey, m.name).lowercased().contains(q) ? [] : m.agents.map { name($0.pubkey, $0.name) }.filter { $0.lowercased().contains(q) }
        guard !hits.isEmpty else { return AttributedString(m.agents.count == 1 ? "+ 1 agent" : "+ \(m.agents.count) agents") }
        var out = AttributedString("+ ")
        for (i, n) in hits.enumerated() {
            if i > 0 { out += AttributedString(", ") }
            var part = AttributedString(n)
            if let r = part.range(of: q, options: .caseInsensitive) {
                part[r].font = .footnote.weight(.semibold)
                part[r].foregroundColor = .primary
            }
            out += part
        }
        return out
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
        // their agents as the app knows them (belfry.json `agents`, whois, the join lines)
        return keys.map { k in DirMember(pubkey: k, name: "", role: nil, agents: d.agentsOf(k).map { (pubkey: $0, name: "") }) }
    }

    private func row(_ pk: String, _ fallback: String, size: CGFloat, detail: AttributedString?, role: String?) -> some View {
        HStack(spacing: 10) {
            Avatar(pubkey: pk, size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(pk, fallback)).font(.body).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            if let role { Text(role).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
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
            do { list = try await model.api.directory(); model.setDirectoryCount(list?.count ?? 0) } catch { failed = true }
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
