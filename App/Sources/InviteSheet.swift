import BelfryCore
import SwiftUI

// Invite people to a channel (web Invite.tsx, the canvas's option C: the link first). The QR and
// the link are there at once, for the safest choice: a guest of this channel for a day. "Joins
// as" changes who they come in as (a guest for a day / week / month; my own agent; for those
// allowed, a member of the belfry with a role, for a month / a year / for good); "Link" is the
// link itself (one person or up to 50; how long it can be opened). Under it: someone who is
// here already, by name.

struct InviteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var who: JoinsAs = .guest(days: 1)
    @State private var people = 1
    @State private var linkDays = 1
    @State private var membership = "permanent"
    @State private var link: GuestLink?
    @State private var busy = false
    @State private var error: String?
    @State private var asked = 0
    @State private var agents: MyAgents?

    var body: some View {
        let _ = model.version
        let g = model.group(id)
        let label = g.map { $0.isPod || $0.isEvent || $0.isProposal ? $0.name : "#" + $0.name } ?? id
        let (asName, asLine) = who.line(channel: label, community: model.config.name, roles: model.roles)
        let n = who.people(people)
        NavigationStack {
            List {
                Section {
                    qr.listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink {
                        JoinsAsPicker(id: id, label: label, who: $who, membership: $membership, agents: agents)
                    } label: {
                        LabeledContent {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(asName).foregroundStyle(.primary)
                                Text(asLine).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        } label: { Text("Joins as") }
                    }
                    NavigationLink {
                        LinkPicker(people: $people, linkDays: $linkDays, onlyOne: n == 1 && people == 50)
                    } label: {
                        LabeledContent("Link") {
                            Text("\(n == 1 ? "One person" : "Up to 50 people"), \(linkDays == 1 ? "1 day" : linkDays == 7 ? "1 week" : "1 month")")
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section {
                    if let link {
                        CopyRow(text: link.url, title: "Copy link")
                        if let u = URL(string: link.url) {
                            ShareLink(item: u, subject: Text(label), message: Text("Join \(label) on \(model.config.name)")) {
                                Label("Share…", systemImage: "square.and.arrow.up")
                            }
                        }
                    } else {
                        Label("Copy link", systemImage: "doc.on.doc").foregroundStyle(.secondary)
                        Label("Share…", systemImage: "square.and.arrow.up").foregroundStyle(.secondary)
                    }
                } footer: { Text(hint(label)) }
                InviteSomeoneHere(id: id)
            }
            .navigationTitle("Invite to \(label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                if !model.derive.amGuest && !model.derive.isAgent(model.me) { agents = await model.myAgents() }
                await model.loadMembership()
                if model.mayInviteMembers { await model.loadRoles() }
            }
            .task(id: key) { await fetch() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var key: String { "\(who)|\(people)|\(linkDays)" }

    private var qr: some View {
        VStack(spacing: 10) {
            ZStack {
                if let img = QR.image(link?.url ?? "https://chat.example.org/join/" + String(repeating: "0", count: 32)) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .opacity(link == nil ? 0.15 : 1)
                        .accessibilityLabel(link == nil ? "" : "QR code of the invite link")
                }
                if link == nil && busy {
                    ProgressView().controlSize(.large).accessibilityLabel("Making the link")
                } else if link == nil, let error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle").font(.title).foregroundStyle(.secondary)
                        Text(error).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.primary)
                        BusyButton("Retry") { await fetch() }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(24)
                }
            }
            Text(link?.url ?? (busy ? "Making the link…" : "—"))
                .font(.footnote.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).multilineTextAlignment(.center).lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: link)
    }

    private func hint(_ label: String) -> String {
        switch who {
        case .agent:
            return "Give this link to your agent within \(JoinsAs.daysWord(linkDays)): it reads the instructions there and joins with its own key. It works once."
        case .member(let r, _):
            return "They read \(label) at once and join \(model.config.name) as \(model.roles.role(r)?.label ?? "Member") with their name and e-mail address. Someone who is a member already just gets the channel."
        case .guest:
            return "They read \(label) at once and join with a name and an e-mail address; someone who has an account joins with it. Everyone here sees who invited them."
        }
    }

    /// A link for the current choice (a newer choice wins over an answer still on its way).
    private func fetch() async {
        asked += 1
        let n = asked
        busy = true; error = nil; link = nil
        let got = await model.makeInvite(id, who: who, people: people, linkDays: linkDays)
        guard n == asked else { return }
        busy = false
        switch got {
        case .success(let l): link = l
        case .failure(let e): error = e.message
        }
    }
}

/// "Joins as": a guest for a day, a week or a month; my own agent; a member with a role.
struct JoinsAsPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    let label: String
    @Binding var who: JoinsAs
    @Binding var membership: String
    let agents: MyAgents?

    var body: some View {
        let g = model.group(id)
        let admin = model.derive.isCommunityAdmin
        List {
            Section(g?.isPod == true ? "Into \(label) only, as a guest" : "Guest of \(label)") {
                ForEach([1, 7, 30], id: \.self) { d in
                    choice(.guest(days: d), title: "For \(JoinsAs.daysWord(d))")
                }
            }
            if let agents, agents.limit > 0 {
                Section {
                    choice(.agent, title: "My own agent",
                           detail: agents.room > 0 || who == .agent
                               ? "For your AI agent: it joins as a member and stays for as long as you are one. Everyone sees it is yours."
                               : "You have \(agents.limit == 1 ? "your agent" : "your \(agents.limit) agents") already. Remove one from its profile to bring another.")
                        .disabled(agents.room <= 0 && who != .agent)
                }
            }
            if model.mayInviteMembers {
                Section {
                    Picker("Membership", selection: $membership) {
                        Text("One month").tag("month"); Text("One year").tag("year"); Text("Permanent").tag("permanent")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: membership) { _, m in if case .member(let r, _) = who { who = .member(role: r, membership: m) } }
                    let roles = admin ? model.roles.roles : model.roles.roles.filter { $0.id == model.roles.defaultRole }
                    ForEach(roles) { r in
                        choice(.member(role: r.id, membership: membership), title: r.label,
                               detail: r.description.isEmpty ? (r.powers ? "Everything, plus settings and roles." : nil) : r.description,
                               badge: r.isDefault ? "Default" : nil)
                    }
                    if admin {
                        NavigationLink { RolesSettings() } label: { Label("Edit roles…", systemImage: "pencil") }
                    }
                } header: { Text("Member of \(model.config.name)") }
            } else if g?.isPod == true {
                Section {} footer: { Text("This brings people into \(label) only. Only admins of \(model.config.name) make someone a member of \(model.config.name).") }
            }
        }
        .navigationTitle("Joins as")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ w: JoinsAs, title: String, detail: String? = nil, badge: String? = nil) -> some View {
        Button {
            who = w
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).foregroundStyle(.primary)
                        if let badge { Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 1).background(Color.secondary.opacity(0.12), in: Capsule()) }
                    }
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if same(w, who) { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(same(w, who) ? .isSelected : [])
    }

    /// A member choice is the same role whatever the length (the length is the picker above).
    private func same(_ a: JoinsAs, _ b: JoinsAs) -> Bool {
        if case .member(let r1, _) = a, case .member(let r2, _) = b { return r1 == r2 }
        return a == b
    }
}

/// "Link": for one person or up to 50, and how long it can be opened.
struct LinkPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var people: Int
    @Binding var linkDays: Int
    let onlyOne: Bool
    var body: some View {
        List {
            Section("How many people") {
                row("One person", people == 1) { people = 1 }
                row("Up to 50 people", people == 50) { people = 50 }.disabled(onlyOne)
            }
            Section {
                row("1 day", linkDays == 1) { linkDays = 1 }
                row("1 week", linkDays == 7) { linkDays = 7 }
                row("1 month", linkDays == 30) { linkDays = 30 }
            } header: { Text("The link can be opened for") } footer: { Text("How long they stay is chosen under “Joins as”.") }
        }
        .navigationTitle("Link")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ t: String, _ on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button { pick(); dismiss() } label: {
            HStack {
                Text(t).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Invite someone who is here already (members, guests, agents): a DM with the link, or let in.
struct InviteSomeoneHere: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var query = ""
    @State private var notes = [String: String]()

    var body: some View {
        let d = model.derive
        let g = model.group(id)
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a name", text: $query).font(.body).textInputAutocapitalization(.words).autocorrectionDisabled()
            }
            ForEach(d.inviteCandidates(query), id: \.self) { pk in
                HStack(spacing: 10) {
                    Avatar(pubkey: pk, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name(pk)).font(.body)
                        Text([d.kindLabel(pk), notes[pk] ?? d.inviteState(g, pk)].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if notes[pk] == nil && !d.inChannel(g, pk) {
                        BusyButton(d.isGuest(pk) ? "Add" : "Invite") { notes[pk] = await model.inviteHere(pk, to: id) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if !query.jsTrim().isEmpty && d.inviteCandidates(query).isEmpty {
                Text("Nobody here by that name. For someone new, share the link above.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Or someone who is here already") }
    }
}
