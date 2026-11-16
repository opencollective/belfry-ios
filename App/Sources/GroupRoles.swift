import BelfryCore
import SwiftUI

// People of a channel, group or event (SPEC 19.29, Xavier 2026-11-15: "don't show that label
// icon. Tapping on a user should go right to show the profile of that person and if you are an
// admin of that event or channel allow to add / edit role of that person"). A row is the face,
// the name and the role there as secondary text when it isn't the default; the profile opened
// from such a list shows "In <group>" with the role, a picker for the group's admins and the
// belfry's admins (Member / Admin; in an event Attendee / Co-host / Steward), saved with
// POST /group-roles, and "Remove from <group>" (the 9001 path).

/// One person in a list of people: a tap opens the profile; MESSAGE adds a trailing button that
/// opens the direct conversation; CHECKED shows the check-in mark.
struct PersonRow: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    var title: String? = nil
    var detail: String? = nil
    var checked = false
    var message = false
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Avatar(pubkey: pubkey, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title ?? model.name(pubkey)).font(.body).foregroundStyle(.primary).lineLimit(1)
                        if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if checked {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Checked in")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Shows the profile")
            if message {
                Button { model.messageAuthor = pubkey } label: {
                    Image(systemName: "message").font(.body).frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.brand)
                .accessibilityLabel("Message \(model.name(pubkey))")
            }
        }
    }
}

/// "In <group>": the person's role in the group the profile was opened from.
struct GroupRoleSection: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    let groupId: String
    @State private var saving: String?
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        let d = model.derive
        if let g = model.group(groupId) {
            let e = g.isEvent ? d.eventOfGroup(groupId) : nil
            let title = g.type == .channel ? "#" + g.name : g.name
            let current = currentChoice(d, e)
            let isCreator = e?.creator == pubkey
            // the creator, the belfry's admins and the relay's keys administer it whatever the role
            let fixed = isCreator || (g.admins.contains(pubkey) && d.everywhere(groupId).contains(pubkey))
            let editable = d.canAdmin(g) && !fixed && !d.isAgent(pubkey) && !g.archived // archived: read only
            let inGroup = g.members.contains(pubkey) || g.admins.contains(pubkey) || (e.map { d.eventPeople($0).holders[pubkey] != nil } ?? false)
            Section {
                if editable {
                    ForEach(choices(e != nil), id: \.id) { c in choiceRow(c, current: current) }
                } else {
                    LabeledContent("Role", value: fixed && !isCreator ? (d.isBelfryAdmin(pubkey) ? "Admin of the belfry" : "Admin") : label(current, event: e != nil))
                }
                if editable && pubkey != model.me && inGroup {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Remove from \(title)", systemImage: "person.badge.minus")
                    }
                    .disabled(saving != nil)
                }
            } header: {
                Text("In \(title)")
            } footer: {
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                else if editable && e != nil { Text("Co-hosts can edit the event and decide who comes. Stewards check people in.") }
            }
            .confirmationDialog("Remove \(model.name(pubkey)) from \(title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
            } message: { Text("They can't read it any more.") }
        }
    }

    struct Choice { let id: String; let label: String; let role: GroupRole }

    private func choices(_ event: Bool) -> [Choice] {
        if event {
            return [Choice(id: "attendee", label: "Attendee", role: .member), Choice(id: "cohost", label: "Co-host", role: .admin),
                    Choice(id: "steward", label: "Steward", role: .steward)]
        }
        return [Choice(id: "member", label: "Member", role: .member), Choice(id: "admin", label: "Admin", role: .admin)]
    }

    /// The id of the current choice (an event's creator: "host").
    private func currentChoice(_ d: Derive, _ e: CalEvent?) -> String {
        if let e { return d.eventRole(e, pubkey).rawValue }
        return d.groupRole(groupId, pubkey) == .admin ? "admin" : "member"
    }

    private func label(_ id: String, event: Bool) -> String {
        if id == "host" { return "Host" }
        return choices(event).first { $0.id == id }?.label ?? (event ? "Attendee" : "Member")
    }

    private func choiceRow(_ c: Choice, current: String) -> some View {
        Button { pick(c, current: current) } label: {
            HStack {
                Text(c.label).foregroundStyle(.primary)
                Spacer()
                if saving == c.id {
                    ProgressView()
                } else if c.id == current {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving != nil)
        .accessibilityAddTraits(c.id == current ? .isSelected : [])
    }

    /// Out of the group through the belfry; an older belfry: the 9001 from here.
    private func remove() {
        saving = "remove"
        error = nil
        Task {
            error = await model.removeFromGroup(groupId, pubkey)
            saving = nil
        }
    }

    private func pick(_ c: Choice, current: String) {
        guard saving == nil, c.id != current else { return }
        saving = c.id
        error = nil
        Task {
            let e = await model.setGroupRole(groupId, pubkey, c.role)
            if e == nil { UINotificationFeedbackGenerator().notificationOccurred(.success) } else { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            error = e
            saving = nil
        }
    }
}
