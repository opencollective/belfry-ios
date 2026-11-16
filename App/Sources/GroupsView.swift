import BelfryCore
import SwiftUI

// Groups (2026-11-16, board iOS-CalGroups): My groups (default: the ones I joined) · Active (mine
// with activity in the last 30 days) · All (every group of the belfry; the ones I'm not in show
// Join, or "by application" for a closed one). Newest activity first; the shape is today's (a
// side per member). A tap pushes the group's chat (or its page when I'm not in it). Archived
// stays one row at the end.

enum GroupsList: String, CaseIterable, Hashable {
    case mine, active, all
    var title: String { self == .mine ? "My groups" : self == .active ? "Active" : "All" }
}

struct GroupsView: View {
    @EnvironmentObject var model: AppModel
    @State private var list = GroupsList.mine

    var body: some View {
        let _ = model.version
        let d = model.derive
        let groups = rows(list)
        let archived = d.myArchived()
        List {
            Section {
                Picker("Which groups", selection: $list) {
                    ForEach(GroupsList.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            Section {
                if groups.isEmpty {
                    Text(empty).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(groups) { g in GroupRow(group: g) }
            }
            if !archived.isEmpty {
                Section {
                    NavigationLink(value: PlaceRoute.archived) {
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox").frame(width: 40, height: 40)
                            Text("Archived")
                            Spacer()
                            Text("\(archived.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .placeChrome("Groups")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { hideKeyboard(); model.createFirst = .group; model.showCreate = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New group")
            }
        }
        .refreshable { await model.refresh() }
        .onAppear { if model.launch.screen == "groupsall" { list = .all } }
    }

    private var empty: String {
        switch list {
        case .mine: return "You're in no group yet. All shows the belfry's groups."
        case .active: return "None of your groups had news this month."
        case .all: return "No groups yet. Make the first one with ＋."
        }
    }

    private func rows(_ l: GroupsList) -> [Channel] {
        let d = model.derive
        let me = model.me
        let pods = d.groups().filter { $0.isPod }
        let mine = pods.filter { $0.members.contains(me) || $0.admins.contains(me) }
        let since = Int.now - activeDays * 86400
        let out: [Channel]
        switch l {
        case .mine: out = mine
        case .active: out = mine.filter { $0.lastActivity >= since }
        case .all: out = pods
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }
}

private struct GroupRow: View {
    @EnvironmentObject var model: AppModel
    let group: Channel

    var body: some View {
        let me = model.me
        let joined = group.members.contains(me) || group.admins.contains(me)
        let applied = group.applications.contains { $0.pubkey == me }
        if joined {
            NavigationLink(value: ChatRoute(id: group.id)) { PlaceLine(group: group, subtitle: line(joined: true)) }
        } else {
            HStack {
                NavigationLink(value: GroupRoute(id: group.id)) { PlaceLine(group: group, subtitle: line(joined: false)) }
                if !group.closed && !model.locked(group.id) {
                    BusyButton { model.join(group.id) } label: { Text("Join") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if applied {
                    Text("Asked").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func line(joined: Bool) -> String {
        var parts = [String]()
        if let p = group.parent, let g = model.group(p) { parts.append(g.name) }
        let n = group.members.count
        parts.append(n == 1 ? "1 member" : "\(n) members")
        if group.closed && !joined { parts.append("by application") }
        return parts.joined(separator: " · ")
    }
}
