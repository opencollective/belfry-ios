import BelfryCore
import SwiftUI

// A group's page (web GroupPage.tsx, 2026-11-14): the card a new group leaves in its parent opens
// it: what the group is, who is in it and who runs it, Follow (its announcements by e-mail), and
// Join (open) / Apply to join (closed) / Pending / You're in. Being in a group makes nobody a
// member of the belfry. ("Group" is what the protocol still calls a pod: ids pod-…)

struct GroupKey: Identifiable, Hashable { let id: String }

struct GroupPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.showProfile) private var showProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let id: String
    @State private var asking = false
    @State private var shownProfile: ProfileKey?

    var body: some View {
        let _ = model.version
        let g = model.group(id)
        NavigationStack {
            List {
                if let g {
                    let parent = g.parent.flatMap { model.group($0) }
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                ChannelGlyph(group: g, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.name).font(.title3.bold())
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
                        action(g)
                    }
                    FollowBell(id: id)
                    Section {
                        if g.members.isEmpty { Text("Nobody yet.").foregroundStyle(.secondary) }
                        ForEach(Array(g.members).sorted { model.name($0) < model.name($1) }, id: \.self) { p in
                            Button { shownProfile = ProfileKey(pubkey: p) } label: {
                                HStack(spacing: 10) {
                                    Avatar(pubkey: p, size: 32)
                                    Text(model.name(p)).foregroundStyle(.primary)
                                    if g.admins.contains(p) { Chip(text: "Admin") }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        let others = g.admins.filter { !g.members.contains($0) }
                        if !others.isEmpty {
                            let names: String = others.map { model.name($0) }.joined(separator: ", ")
                            Text("Also run by \(names).").font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("Who’s in · \(g.members.count)") }
                    if model.derive.canAdmin(g), !g.applications.isEmpty {
                        Section("Asking to join · \(g.applications.count)") {
                            ForEach(g.applications, id: \.pubkey) { a in GroupRequestRow(group: g, pubkey: a.pubkey, answer: a.answer) }
                        }
                    }
                } else {
                    ContentUnavailableView("This group isn’t here yet", systemImage: "hexagon", description: Text("It shows once the relay sends it."))
                }
            }
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $asking) { if let g { PodApplySheet(group: g) } }
            .navigationDestination(item: $shownProfile) { ProfileView(pubkey: $0.pubkey, pushed: true) }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
        .presentationDragIndicator(.visible)
    }

    private func subtitle(_ g: Channel, _ parent: Channel?) -> String {
        var s = "Group"
        if let p = parent { s += " in " + (p.isPod ? p.name : "#" + p.name) }
        s += " · "
        s += g.closed ? "by request" : "open to members"
        return s
    }

    @ViewBuilder private func action(_ g: Channel) -> some View {
        let inIt = g.members.contains(model.me)
        let mine = g.applications.contains { $0.pubkey == model.me }
        if inIt {
            HStack {
                Label("You’re in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Open \(g.name)") { dismiss(); openChannel(id, nil) }.buttonStyle(.brand).controlSize(.small)
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
                    BusyButton("Join") { model.join(id); dismiss(); openChannel(id, nil) }.buttonStyle(.brand).controlSize(.small)
                }
                Button("Have a look") { dismiss(); openChannel(id, nil) }.buttonStyle(.bordered).controlSize(.small)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Avatar(pubkey: pubkey, size: 28)
                Text(model.name(pubkey)).font(.subheadline.weight(.semibold))
                if let k = model.derive.kindLabel(pubkey) { Text(k).font(.caption).foregroundStyle(.secondary) }
            }
            if !answer.isEmpty { Text(verbatim: answer).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                BusyButton("Accept") { model.admit(group.id, pubkey) }.buttonStyle(.brand)
                BusyButton("Decline", role: .destructive) { model.declineApplicant(group.id, pubkey) }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
