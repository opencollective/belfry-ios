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

    var body: some View {
        let _ = model.version
        let shown = filtered()
        List {
            // what waits for me, only when something does (web 98c33fc)
            RequestSections(error: $error)
            Section {
                if list == nil { HStack { if failed { Text("The list could not be loaded.") } else { ProgressView(); Text("Loading…") } }.foregroundStyle(.secondary) }
                ForEach(shown) { m in
                    Button { model.openProfile = m.pubkey } label: { row(m.pubkey, m.name, size: 36, detail: model.profiles[m.pubkey]?.nip05, role: model.roles.label(of: m.pubkey) ?? roleLabel(m.role)) }
                        .buttonStyle(.plain)
                    ForEach(m.agents, id: \.pubkey) { a in
                        Button { model.openProfile = a.pubkey } label: { row(a.pubkey, a.name, size: 28, detail: "\(name(m.pubkey, m.name))'s agent", role: nil) }
                            .buttonStyle(.plain)
                            .padding(.leading, 28)
                    }
                }
            } header: { Text(list == nil ? model.config.name : "\(shown.count) in \(model.config.name)") }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search members")
        .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
        .task { await load() }
        .refreshable { await load() }
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
        }.sorted { name($0.pubkey, $0.name).localizedCaseInsensitiveCompare(name($1.pubkey, $1.name)) == .orderedAscending }
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
                Text(name(pk, fallback)).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            if let role { Chip(text: role) }
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
