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
            let agents = admin ? model.agentRequests : []
            let shown = agents.count + model.belfryRequests.count + groups.reduce(0) { $0 + $1.list.count }
            // the number: a request I vouched for no longer waits for me; a steward counts them all
            let count = agents.count + model.belfryRequests.filter { admin || !$0.vouched }.count + d.groupRequestCount()
            if shown > 0 {
                // one section for everything that waits for me (board home/members)
                Section {
                    ForEach(agents) { a in agentRow(a) }
                    ForEach(model.belfryRequests) { p in belfryRow(p, admin: admin, vouching: vouching) }
                    ForEach(groups) { x in
                        ForEach(x.list, id: \.id) { a in groupRow(x.group, a, d) }
                    }
                } header: {
                    Text(count > 0 ? "Waiting for you · \(count)" : "Waiting for you")
                } footer: {
                    Text("Stewards see every request to join the belfry. Everyone sees requests for groups they are in, and vouches when the group asks for vouches.")
                }
            }
        }
    }

    private func agentRow(_ a: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BotMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: a.name.isEmpty ? "An agent" : a.name).font(.body.weight(.semibold))
                        Chip(text: "agent")
                    }
                    Text(a.forMe ? "Asks to be your agent" : "Asks to join \(model.config.name)").font(.footnote).foregroundStyle(.secondary)
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

    private func belfryRow(_ p: BelfryRequest, admin: Bool, vouching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let pk = p.pubkey { Avatar(pubkey: pk, size: 32) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: p.name.isEmpty ? "Someone" : p.name).font(.body.weight(.semibold))
                        if p.isGuest { Chip(text: "guest") }
                    }
                    Text(asksLine(p, vouching: vouching)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if p.isGuest { Text(guestLine(p)).font(.footnote).foregroundStyle(.secondary) }
            // "@lina · lina.moreau@example.org" (the e-mail for stewards only)
            let who = p.whoLine(showEmail: admin)
            if !who.isEmpty { Text(verbatim: who).font(.footnote).foregroundStyle(.secondary) }
            if !p.motivation.isEmpty { Text(verbatim: p.motivation).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                if admin {
                    BusyButton("Accept") { error = await model.decideApplication(p.id, approve: true) }.buttonStyle(.brand)
                    BusyButton("Decline", role: .destructive) { error = await model.decideApplication(p.id, approve: false) }.buttonStyle(.bordered)
                }
                if vouching || !admin {
                    BusyButton(p.vouched ? "Take back my vouch" : "Vouch") { error = await model.vouchApplication(p.id, on: !p.vouched) }.buttonStyle(.bordered)
                }
                // "1 vouch" beside the buttons: the count, no names
                if !vouching, p.vouches > 0 { Text(p.vouches == 1 ? "1 vouch" : "\(p.vouches) vouches").font(.footnote).foregroundStyle(.secondary) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// "Asks to join Riverside Commons" (+ " · 1 of 2 vouches" while the belfry accepts by vouches).
    private func asksLine(_ p: BelfryRequest, vouching: Bool) -> String {
        let s = "Asks to join \(model.config.name)"
        guard vouching else { return s }
        return s + " · \(p.vouches) of \(model.membership.vouches) \(model.membership.vouches == 1 ? "vouch" : "vouches")"
    }

    @ViewBuilder private func groupRow(_ g: Channel, _ a: BelfryCore.Application, _ d: Derive) -> some View {
        if g.admins.contains(model.me) {
            GroupRequestRow(group: g, pubkey: a.pubkey, answer: a.answer, asks: "Asks to join \(g.name)")
        } else {
            let who = d.vouchesFor(g, a)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Avatar(pubkey: a.pubkey, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name(a.pubkey)).font(.body.weight(.semibold))
                        Text("Asks to join \(g.name) · " + vouchLine(who, g.vouches)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !a.answer.isEmpty { Text(verbatim: a.answer).font(.subheadline).foregroundStyle(.secondary) }
                BusyButton(who.contains(model.me) ? "Take back my vouch" : "Vouch") { model.vouch(g, a, on: !who.contains(model.me)) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.vertical, 2)
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

/// An agent's face where it has none of its own yet: the bot mark on grey (board home/members).
struct BotMark: View {
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: "cpu").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white)
            .frame(width: size, height: size).background(Color.gray, in: Circle())
            .accessibilityHidden(true)
    }
}
