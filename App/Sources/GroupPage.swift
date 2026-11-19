import BelfryCore
import SwiftUI

// A group's page (web GroupPage.tsx, 2026-11-14): the card a new group leaves in its parent opens
// it: what the group is, who is in it and who runs it, Follow (its announcements by e-mail), and
// Join (open) / Apply to join (closed) / Pending / You're in. Being in a group makes nobody a
// member of the belfry. ("Group" is what the protocol still calls a pod: ids pod-…)
// Since 2026-11-16 it is a screen pushed on the main stack (`GroupRoute`), never a sheet. A
// deleted group shows only that it has been deleted; an archived one is read only (SPEC 19.30).

struct GroupPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    @State private var asking = false
    @State private var shownProfile: ProfileKey?

    var body: some View {
        let _ = model.version
        let g = model.group(id)
        let state = model.derive.groupState(id)
        if state == .deleted {
            GroupGone()
        } else {
            page(g, archived: state == .archived)
        }
    }

    private func page(_ g: Channel?, archived: Bool) -> some View {
            List {
                if let g {
                    let parent = g.parent.flatMap { model.group($0) }
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                ChannelGlyph(group: g, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    GroupTitle(group: g, id: g.id).font(.title3.bold())
                                    Text(subtitle(g, parent))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if g.about.isEmpty {
                                Text("No description yet.").font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                MarkdownText(text: g.about).font(.subheadline)
                            }
                        }
                        .padding(.vertical, 4)
                        if archived { archivedAction(g) } else { action(g) }
                    }
                    if !archived { FollowBell(id: id) }
                    Section {
                        if g.members.isEmpty { Text("Nobody yet.").foregroundStyle(.secondary) }
                        ForEach(Array(g.members).sorted { model.name($0) < model.name($1) }, id: \.self) { p in
                            PersonRow(pubkey: p, detail: model.derive.adminWord(id, p)) { shownProfile = ProfileKey(pubkey: p, group: id) }
                        }
                        let others = g.admins.filter { !g.members.contains($0) }
                        if !others.isEmpty {
                            let names: String = others.map { model.name($0) }.joined(separator: ", ")
                            Text("Also run by \(names).").font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("Who’s in · \(g.members.count)") }
                    if !archived, model.derive.canAdmin(g), !g.applications.isEmpty {
                        Section("Asking to join · \(g.applications.count)") {
                            ForEach(g.applications, id: \.pubkey) { a in GroupRequestRow(group: g, pubkey: a.pubkey, answer: a.answer) }
                        }
                    }
                } else {
                    // nothing known about it and the relay has not said yet: never "deleted" on a guess
                    ContentUnavailableView("Nothing to show yet", systemImage: "hexagon", description: Text(unknownLine))
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $asking) { if let g { PodApplySheet(group: g) } }
            .navigationDestination(item: $shownProfile) { ProfileView(pubkey: $0.pubkey, pushed: true, group: $0.group) }
            .onAppear { model.lookFor(id) }
    }

    private var unknownLine: String {
        if !model.online { return "You’re offline." }
        if model.guestReading || model.derive.amGuest { return "There is nothing about this group here." }
        return "Looking for this group."
    }

    /// An archived group: read only, whoever I am in it.
    @ViewBuilder private func archivedAction(_ g: Channel) -> some View {
        HStack {
            Label("Archived · read only", systemImage: "archivebox").foregroundStyle(.secondary)
            Spacer()
            Button("Read \(g.named ? g.name : BelfryCore.Group.neutral(g.id))") { model.openGroup = id }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func subtitle(_ g: Channel, _ parent: Channel?) -> String {
        var s = "Group"
        if let p = parent { s += " in " + p.label }
        // an archived group takes nobody: no "open to members" (its banner says it is archived)
        if !g.archived { s += " · " + (g.closed ? "by application" : "open to members") }
        return s
    }

    @ViewBuilder private func action(_ g: Channel) -> some View {
        let inIt = g.members.contains(model.me)
        let mine = g.applications.contains { $0.pubkey == model.me }
        if inIt {
            HStack {
                Label("You’re in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Open \(g.named ? g.name : BelfryCore.Group.neutral(g.id))") { openChannel(id, nil) }.buttonStyle(.brand).controlSize(.small)
            }
        } else if mine {
            VStack(alignment: .leading, spacing: 4) {
                Label("Pending", systemImage: "clock").font(.body.weight(.semibold))
                Text("Request sent. Its admins will answer.").font(.footnote).foregroundStyle(.secondary)
            }
        } else if model.guestReading {
            Text("Join this belfry’s channel first.").font(.footnote).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                if g.closed {
                    Button("Apply to join") { asking = true }.buttonStyle(.brand).controlSize(.small)
                } else {
                    BusyButton("Join") { model.join(id); openChannel(id, nil) }.buttonStyle(.brand).controlSize(.small)
                }
                Button("Have a look") { openChannel(id, nil) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

/// Someone asking to join a group I run: their answer (plain text), Accept / Decline.
struct GroupRequestRow: View {
    @EnvironmentObject var model: AppModel
    let group: Channel
    let pubkey: String
    let answer: String
    /// "Asks to join Garden crew": on Members, where requests of several groups share a section.
    var asks: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Avatar(pubkey: pubkey, size: asks == nil ? 28 : 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(model.name(pubkey)).font(asks == nil ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                        if let k = model.derive.kindLabel(pubkey) { Text(k).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let asks { Text(asks).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if !answer.isEmpty { Text(verbatim: answer).font(.subheadline).foregroundStyle(.secondary) }
            // every admin of it (the relay's list, its creator, by role, a belfry admin) answers
            // through the belfry (board channels/closed-requests; docs/membership.md)
            if model.derive.canAdmin(group) {
                HStack {
                    BusyButton("Accept") { error = await model.decideGroupRequest(group, pubkey, approve: true) }.buttonStyle(.brand)
                    BusyButton("Decline", role: .destructive) { error = await model.decideGroupRequest(group, pubkey, approve: false) }.buttonStyle(.bordered)
                }
                .controlSize(.small)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .padding(.vertical, 2)
    }
}
