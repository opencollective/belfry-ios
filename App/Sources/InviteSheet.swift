import BelfryCore
import SwiftUI

// Invite people (web Invite.tsx, village-app 076dea1; canvas inviting/sheet-from-channel,
// sheet-external, sheet-from-members, Xavier 2026-11-18). From a channel, event or proposal:
// someone who is here already comes first; the link for someone from outside stays folded under
// "Or invite an external person" and is made only when that is opened. From Members: "Invite to
// <community>", no name search, the link at once, preset to a member with the default role,
// permanent. Since 2026-11-19 (canvas v45–v48) the external part is: "Invite as" radio rows (only
// the roles this person may give), one line that describes the link with Edit, the options Edit
// unfolds, and Copy link / Share… as two secondary buttons. Before: "Joins as" changes who they come in as (a guest for a day / week / month; my own
// agent; for those allowed, a member with a role); "Link" is the link itself (one person or up to
// 50, how long it can be opened; a Steward's or an agent's link is for one person).

struct InviteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    /// Opened from Members: an invitation to the belfry itself.
    let toBelfry: Bool
    @State private var who: JoinsAs = .guest(days: 1)
    @State private var outside: Bool
    @State private var people = 1
    @State private var linkDays = 1
    @State private var membership = "permanent"
    @State private var link: GuestLink?
    @State private var busy = false
    @State private var error: String?
    @State private var asked = 0
    @State private var agents: MyAgents?
    /// "Invite as" (boards inviting/sheet-external, canvas v45–v48): the row picked, the options
    /// unfolded by "Edit", a guest of this channel instead of a member (0 = no; else its days).
    @State private var role = InviteRole.member
    @State private var editing = false
    @State private var guestInstead = 0
    /// A custom role (e.g. Host) a Steward gives instead of the default one: its id.
    @State private var customRole: String?
    /// The membership answer is in: only then is a link made (never one the server would refuse).
    @State private var ready = false

    /// STARTAS: what the link is for when the sheet opens (the Members screen's button: a member,
    /// which also makes it the belfry's invitation).
    init(id: String, startAs: JoinsAs? = nil, external: Bool = false) {
        self.id = id
        toBelfry = startAs != nil
        _who = State(initialValue: startAs ?? .guest(days: 1))
        _outside = State(initialValue: startAs != nil || external)
    }

    var body: some View {
        let _ = model.version
        let g = model.group(id)
        let label = g.map { $0.named ? ($0.isPod || $0.isEvent || $0.isProposal ? $0.name : "#" + $0.name) : BelfryCore.Group.neutral(id) } ?? BelfryCore.Group.neutral(id)
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if toBelfry {
                        Section { top(label).listRowBackground(Color.clear) }
                        external(label)
                    } else {
                        InviteSomeoneHere(id: id, label: label)
                        Section {
                            Button {
                                withAnimation(.snappy(duration: 0.25)) { outside.toggle() }
                                if outside { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("invite-qr", anchor: .top) } } }
                            } label: { outsideRow }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("invite-external")
                            .accessibilityValue(outside ? "Open" : "Closed")
                            if outside { top(label).id("invite-qr") }
                        } footer: { if !outside { Text("No link is made until you open this.") } }
                        if outside { external(label) }
                    }
                }
            }
            .navigationTitle("Invite to \(toBelfry ? model.config.name : label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                if !model.derive.amGuest && !model.derive.isAgent(model.me) { agents = await model.myAgents() }
                await model.loadMembership()
                if model.mayInviteMembers { await model.loadRoles() }
                // Member by default for those who may invite members; a guest of the channel otherwise
                if !toBelfry { sync() }
                ready = true
            }
            .task(id: key) { if outside && ready { await fetch() } }
            .onChange(of: role) { _, _ in sync() }
            .onChange(of: membership) { _, _ in sync() }
            .onChange(of: guestInstead) { _, _ in sync() }
            .onChange(of: customRole) { _, _ in sync() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// A new link for every new choice, and only once the external part is open.
    private var key: String { "\(who)|\(people)|\(linkDays)|\(outside)|\(ready)" }

    /// The roles this person may give (`GET /membership` → may_invite_members is read first).
    private var roles: [InviteRole] {
        let d = model.derive
        return InviteChoices.roles(steward: d.isCommunityAdmin, mayInviteMembers: model.mayInviteMembers,
                                   mayAddAgent: (agents?.room ?? 0) > 0 || who == .agent)
    }

    /// What the link is for, from the rows and the options.
    private func sync() {
        guard !roles.isEmpty else { who = .guest(days: 1); return }
        if !roles.contains(role) { role = .member }
        switch role {
        case .agent: who = .agent
        case .steward:
            if people != 1 { people = 1 }
            who = .member(role: Role.admin, membership: membership)
        case .member:
            who = guestInstead > 0 && !toBelfry ? .guest(days: guestInstead) : .member(role: customRole ?? model.roles.defaultRole, membership: membership)
        }
    }

    /// The QR code and its address; for an agent, the text to paste to it.
    @ViewBuilder private func top(_ label: String) -> some View {
        if who == .agent { agentText } else { qr }
    }

    private var agentPrompt: String? {
        guard let u = link?.agentURL, u.hasPrefix("https://") else { return nil }
        return "Join \(model.config.name) as my agent: read \(u) and follow it."
    }

    private var agentText: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste this to your agent. It reads the instructions at the address, joins \(model.config.name) as your agent, and follows your channels. The link works once.")
                .font(.subheadline).foregroundStyle(.secondary)
            SwiftUI.Group {
                if let t = agentPrompt {
                    Text(t).font(.callout.monospaced()).textSelection(.enabled)
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Making the link…").foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityIdentifier("invite-agent-text")
    }

    /// Under the QR code: "Invite as" (only with more than one role to give), the line that
    /// describes the link with Edit, the options Edit unfolds, and the two buttons.
    @ViewBuilder private func external(_ label: String) -> some View {
        let roles = self.roles
        // a Steward also gives the belfry's own roles (e.g. Host): extra rows with their one line
        let custom = roles.contains(.steward) ? model.roles.roles.filter { $0.id != Role.member && $0.id != Role.admin && $0.id != model.roles.defaultRole } : []
        if roles.count > 1 {
            Section("Invite as") {
                ForEach(roles) { r in
                    if r == .agent {
                        ForEach(custom) { c in
                            roleRow(c.label, c.description, on: role == .member && customRole == c.id, id: "role-" + c.id) { customRole = c.id; role = .member }
                        }
                    }
                    roleRow(r.title, r.line, on: role == r && (r != .member || customRole == nil), id: r.rawValue) {
                        if r == .member { customRole = nil }
                        role = r
                    }
                }
                if !roles.contains(.agent) {
                    ForEach(custom) { c in
                        roleRow(c.label, c.description, on: role == .member && customRole == c.id, id: "role-" + c.id) { customRole = c.id; role = .member }
                    }
                }
            }
        }
        Section {
            if who != .agent {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(InviteChoices.line(who: who, people: people, linkDays: linkDays, channel: label))
                        .font(.subheadline).foregroundStyle(.primary)
                        .accessibilityIdentifier("invite-line")
                    Spacer(minLength: 4)
                    Button(editing ? "Done" : "Edit") { withAnimation(.snappy(duration: 0.2)) { editing.toggle() } }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("invite-edit")
                }
                if editing { options(label, roles) }
            }
        } footer: {
            if roles.isEmpty, !toBelfry { Text("Only stewards invite new members here.") }
        }
        Section {
            HStack(spacing: 10) {
                let text = who == .agent ? agentPrompt : link?.url
                CopyRow(text: text ?? "", title: who == .agent ? "Copy" : "Copy link")
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .disabled(text == nil)
                if let text, let u = URL(string: link?.url ?? "") {
                    SwiftUI.Group {
                        if who == .agent {
                            ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        } else {
                            ShareLink(item: u, subject: Text(label), message: Text("Join \(label) on \(model.config.name)")) {
                                Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {} label: { Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .disabled(true)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
    }

    private func roleRow(_ title: String, _ line: String, on: Bool, id: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundStyle(on ? Color.brand : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if !line.isEmpty { Text(line).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("invite-as-" + id)
    }

    /// What "Edit" unfolds: each row opens its list. A change makes a new code and link.
    @ViewBuilder private func options(_ label: String, _ roles: [InviteRole]) -> some View {
        let guest: Bool = { if case .guest = who { return true } else { return false } }()
        if role == .steward && !roles.isEmpty {
            LabeledContent("People", value: "One person")
        } else {
            Picker("People", selection: $people) {
                Text("One person").tag(1)
                Text("Up to 50 people").tag(50)
            }
            .pickerStyle(.navigationLink)
        }
        Picker("Works for", selection: $linkDays) {
            Text("24 hours").tag(1)
            Text("A week").tag(7)
            Text("A month").tag(30)
        }
        .pickerStyle(.navigationLink)
        if !roles.isEmpty {
            if !guest {
                Picker("Stays", selection: $membership) {
                    Text("Permanent").tag("permanent")
                    Text("One month").tag("month")
                    Text("One year").tag("year")
                }
                .pickerStyle(.navigationLink)
            }
            if role == .member && !toBelfry {
                Picker("Instead", selection: $guestInstead) {
                    Text("No: a member").tag(0)
                    Text("Guest of \(label) only, for a day").tag(1)
                    Text("Guest of \(label) only, for a week").tag(7)
                    Text("Guest of \(label) only, for a month").tag(30)
                }
                .pickerStyle(.navigationLink)
            }
        }
    }

    private var outsideRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "qrcode").font(.body).frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Or invite an external person").font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text("A link or a QR code for someone who is not in \(model.config.name) yet").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(outside ? 180 : 0))
        }
        .contentShape(Rectangle())
    }

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
        .listRowBackground(Color.clear)
        .animation(.easeOut(duration: 0.2), value: link)
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
                    choice(.agent, title: "My own agent", detail: agentLine(agents))
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

    private func agentLine(_ agents: MyAgents) -> String {
        if agents.room > 0 || who == .agent {
            return "For your AI agent: it joins as a member and stays for as long as you are one. Everyone sees it is yours."
        }
        let have = agents.limit == 1 ? "your agent" : "your \(agents.limit) agents"
        return "You have \(have) already. Remove one from its profile to bring another."
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
    /// Why the link is for one person only (a Steward's or an agent's link), or nil.
    let onlyOne: String?
    var body: some View {
        List {
            Section {
                row("One person", people == 1 || onlyOne != nil) { people = 1 }
                row("Up to 50 people", people == 50 && onlyOne == nil) { people = 50 }.disabled(onlyOne != nil)
            } header: { Text("How many people") } footer: { if let onlyOne { Text(onlyOne) } }
            Section {
                row("1 day", linkDays == 1) { linkDays = 1 }
                row("1 week", linkDays == 7) { linkDays = 7 }
                row("1 month", linkDays == 30) { linkDays = 30 }
            } header: { Text("The link can be opened for") } footer: { Text("How long they stay is chosen under “Joins as”. Picking a row goes back and makes a new link.") }
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

/// Invite someone who is here already (members, guests, agents): a direct message with the link, or
/// let in (web InviteMember: "Add as a guest" / "Send the link" / "Invite").
struct InviteSomeoneHere: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let label: String
    @State private var query = ""
    @State private var notes = [String: String]()

    var body: some View {
        let d = model.derive
        let g = model.group(id)
        let found = query.jsTrim().isEmpty ? [] : d.inviteCandidates(query)
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Invite a community member", text: $query).font(.body).textInputAutocapitalization(.words).autocorrectionDisabled()
                    .accessibilityIdentifier("invite-search")
            }
            ForEach(found, id: \.self) { pk in
                let here = d.inChannel(g, pk)
                HStack(spacing: 10) {
                    Avatar(pubkey: pk, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name(pk)).font(.body)
                        Text([d.kindLabel(pk), notes[pk] ?? d.inviteState(g, pk)].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if notes[pk] == nil && !(here && d.isGuest(pk)) {
                        BusyButton(d.isGuest(pk) ? "Add as a guest" : here ? "Send the link" : "Invite") { notes[pk] = await model.inviteHere(pk, to: id) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if !query.jsTrim().isEmpty && found.isEmpty {
                Text("Nobody here by that name. For someone new, invite an external person below.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Invite a community member:") } footer: {
            Text("They get the link to \(label) as a direct message. A guest of another channel is added here as a guest.")
        }
        .onAppear { if model.launch.screen == "invitesearch", query.isEmpty { query = "L" } } // screenshots
    }
}
