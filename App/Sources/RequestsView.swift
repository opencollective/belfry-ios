import BelfryCore
import SwiftUI

// Requests (web Requests.tsx `RequestSections`, 98c33fc, docs/membership.md): the sections at the
// top of Members when something waits (no screen of their own any more; their count is on
// Members in the drawer and on ☰). Agents asking to join (belfry admins: "Let it in as my agent" / Decline), people
// asking to join the belfry (admins accept or decline; members vouch while the belfry accepts
// by vouches) and requests to every group I run (Accept / Decline) or am in when it accepts by
// vouches. Askers' words are shown as plain text.

struct RequestSections: View {
    @EnvironmentObject var model: AppModel
    @Binding var error: String?

    var body: some View {
        let _ = model.version
        let d = model.derive
        let admin = d.isCommunityAdmin
        let vouching = model.membership.accept == "vouches"
        let groups = d.groupRequests()
        SwiftUI.Group {
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
                            HStack(spacing: 8) {
                                if let pk = p.pubkey { Avatar(pubkey: pk, size: 28) }
                                Text(verbatim: p.name.isEmpty ? "Someone" : p.name).font(.body.weight(.semibold))
                            }
                            if p.isGuest { Text(guestLine(p)).font(.footnote).foregroundStyle(.secondary) }
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
                                if vouching || !admin {
                                    BusyButton(p.vouched ? "Take back my vouch" : "Vouch") { error = await model.vouchApplication(p.id, on: !p.vouched) }.buttonStyle(.bordered)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text("Asking to join \(model.config.name) · \(model.belfryRequests.count)") }
            }
            ForEach(groups) { x in
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
                                Text(vouchLine(who, x.group.vouches)).font(.footnote).foregroundStyle(.secondary)
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
        }
    }

    private func vouchLine(_ who: [String], _ needed: Int) -> String {
        var s = "\(who.count) of \(needed) \(needed == 1 ? "vouch" : "vouches")"
        if !who.isEmpty {
            let names: String = who.map { model.name($0) }.joined(separator: ", ")
            s += " · " + names
        }
        return s
    }
}

/// "Guest in #garden since 12 Nov, invited by Ana" (guestapply.py's card for stewards).
func guestLine(_ p: BelfryRequest) -> String {
    var s = "Guest"
    if !p.channels.isEmpty { s += " in " + p.channels.map { "#" + $0 }.joined(separator: ", ") }
    if p.since.count >= 10 { s += " since " + String(p.since.prefix(10)) }
    if !p.inviter.isEmpty { s += ", invited by " + p.inviter }
    return s
}
