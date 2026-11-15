import BelfryCore
import SwiftUI

// Requests (web Requests.tsx, docs/membership.md): the first row of the channel list, its count
// also on ☰. Agents asking to join (belfry admins: "Let it in as my agent" / Decline), people
// asking to join the belfry (admins accept or decline; members vouch while the belfry accepts
// by vouches) and requests to every group I run (Accept / Decline) or am in when it accepts by
// vouches. Askers' words are shown as plain text.

struct RequestsView: View {
    @EnvironmentObject var model: AppModel
    @State private var error: String?

    var body: some View {
        let _ = model.version
        let d = model.derive
        let admin = d.isCommunityAdmin
        let vouching = model.membership.accept == "vouches"
        let groups = d.groupRequests()
        List {
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            if admin && !model.agentRequests.isEmpty {
                Section("Agents asking to join · \(model.agentRequests.count)") {
                    ForEach(model.agentRequests) { a in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Avatar(pubkey: a.pubkey, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: a.name.isEmpty ? "An agent" : a.name).font(.body.weight(.semibold))
                                    Text(a.forMe ? "Asks to be your agent" : "Asks to join").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if !a.about.isEmpty { Text(verbatim: a.about).font(.subheadline).foregroundStyle(.secondary) }
                            HStack {
                                BusyButton("Let it in as my agent") { error = await model.decideAgentRequest(a.id, approve: true) }.buttonStyle(.brand)
                                BusyButton("Decline", role: .destructive) { error = await model.decideAgentRequest(a.id, approve: false) }.buttonStyle(.bordered)
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if !model.belfryRequests.isEmpty {
                Section {
                    ForEach(model.belfryRequests) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: p.name.isEmpty ? "Someone" : p.name).font(.body.weight(.semibold))
                            if admin, let e = p.email { Text(verbatim: e).font(.footnote).foregroundStyle(.secondary) }
                            if !p.motivation.isEmpty { Text(verbatim: p.motivation).font(.subheadline).foregroundStyle(.secondary) }
                            if vouching {
                                Text("\(p.vouches) of \(model.membership.vouches) \(model.membership.vouches == 1 ? "vouch" : "vouches")").font(.footnote).foregroundStyle(.secondary)
                            }
                            HStack {
                                if admin {
                                    BusyButton("Accept") { error = await model.decideApplication(p.id, approve: true) }.buttonStyle(.brand)
                                    BusyButton("Decline", role: .destructive) { error = await model.decideApplication(p.id, approve: false) }.buttonStyle(.bordered)
                                }
                                if vouching {
                                    BusyButton(p.vouched ? "Take back my vouch" : "Vouch") { error = await model.vouchApplication(p.id, on: !p.vouched) }.buttonStyle(.bordered)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text("Asking to join \(model.config.name) · \(model.belfryRequests.count)") }
            }
            ForEach(groups, id: \.group.id) { x in
                Section {
                    ForEach(x.list, id: \.id) { a in
                        let mineToRun = x.group.admins.contains(model.me)
                        if mineToRun {
                            GroupRequestRow(group: x.group, pubkey: a.pubkey, answer: a.answer)
                        } else {
                            let who = d.vouchesFor(x.group, a)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) { Avatar(pubkey: a.pubkey, size: 28); Text(model.name(a.pubkey)).font(.subheadline.weight(.semibold)) }
                                if !a.answer.isEmpty { Text(verbatim: a.answer).font(.subheadline).foregroundStyle(.secondary) }
                                Text("\(who.count) of \(x.group.vouches) \(x.group.vouches == 1 ? "vouch" : "vouches")" + (who.isEmpty ? "" : " · " + who.map(model.name).joined(separator: ", ")))
                                    .font(.footnote).foregroundStyle(.secondary)
                                BusyButton(who.contains(model.me) ? "Take back my vouch" : "Vouch") { model.vouch(x.group, a, on: !who.contains(model.me)) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Button { model.openGroup = x.group.id } label: {
                        HStack(spacing: 6) { ChannelGlyph(group: x.group, size: 14); Text(x.group.name); Image(systemName: "chevron.right").font(.caption2) }
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.requestCount == 0 {
                ContentUnavailableView("Nothing waiting", systemImage: "tray",
                                       description: Text("People and agents asking to join show here, and requests to the groups you run."))
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
        .task { await model.loadRequests() }
        .refreshable { await model.loadRequests(); await model.refresh() }
    }
}
