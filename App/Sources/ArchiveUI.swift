import BelfryCore
import SwiftUI

// Deleted and archived groups (SPEC 19.30): the card a group leaves in its parent, the screen a
// link to a deleted group opens, the banner of an archived group, and the Archived list (a screen
// opened from the last row of the channel list).

/// A channel pushed on the main stack (an archived group opened from its card or the Archived list).
struct ChannelRoute: Hashable { let id: String }
/// A group's page, pushed on the main stack.
struct GroupRoute: Hashable { let id: String }

/// What a route to a channel shows: the channel, or that it has been deleted.
struct ChannelScreen: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var focus: String?
    var pushed = false
    var body: some View {
        let _ = model.version
        if model.derive.isDeleted(id) {
            GroupGone(root: !pushed)
        } else {
            ChannelView(id: id, focus: focus, pushed: pushed).id(id)
        }
    }
}

/// "This group has been deleted": all a link to a deleted group shows. No composer, no
/// pull-down, no settings; the way back is the back button, or ☰ and #general at the root.
struct GroupGone: View {
    @Environment(\.openChannel) private var openChannel
    var root = false
    var body: some View {
        ContentUnavailableView {
            Label("This group has been deleted", systemImage: "trash")
        } description: {
            Text("Its messages are gone with it.")
        } actions: {
            if root { Button("Go to #general") { openChannel(generalId, nil) }.buttonStyle(.bordered) }
        }
        .navigationTitle("Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if root { ToolbarItem(placement: .topBarLeading) { DrawerButton() } } }
        .accessibilityIdentifier("group-gone")
    }
}

/// The card a new group left in its parent channel. Open: tappable, opens the group's page.
/// Archived: greyed, "Archived", opens the group read only. Deleted: greyed, "This group has been
/// deleted", not a button at all. Unknown (nothing known yet, the relay has not answered): as an
/// open one, with no sentence about the relay.
struct GroupCard: View {
    @EnvironmentObject var model: AppModel
    let id: String
    /// The card's own text ("⬡ New group: Canal · …"): the name when the group is gone.
    let text: String

    var body: some View {
        let d = model.derive
        let state = d.groupState(id)
        let g = d.group(id)
        let name: String = g?.name ?? Derive.cardName(text) ?? "A group"
        switch state {
        case .deleted:
            frame(g: nil, name: name, line: "This group has been deleted", chevron: false)
                .opacity(0.55)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group-card-deleted")
        case .archived:
            Button { hideKeyboard(); model.openGroup = id } label: {
                frame(g: g, name: name, line: "Archived", chevron: true).opacity(0.6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("group-card-archived")
        case .open, .unknown:
            Button { hideKeyboard(); model.openGroup = id } label: {
                frame(g: g, name: name, line: g.map(openLine) ?? "Group", chevron: true)
            }
            .buttonStyle(.plain)
            .onAppear { if state == .unknown { model.lookFor(id) } }
        }
    }

    private func openLine(_ g: Channel) -> String {
        let n = g.members.count
        return "\(n) \(n == 1 ? "member" : "members") · \(g.closed ? "by application" : "open to join")"
    }

    private func frame(g: Channel?, name: String, line: String, chevron: Bool) -> some View {
        CardFrame {
            HStack(spacing: 10) {
                if let g {
                    ChannelGlyph(group: g, size: 26)
                } else {
                    PodShape(members: 6).stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .frame(width: 26, height: 26).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline.weight(.semibold))
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if chevron { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
        }
    }
}

/// Under an archived group's header: "Archived · read only", and Unarchive for those who may.
struct ArchivedBanner: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var error: String?
    var body: some View {
        let g = model.group(id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text("Archived · read only").font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                if model.derive.mayArchive(g) {
                    BusyButton("Unarchive") { error = await model.setArchived(id, false) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("unarchive")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .floatingBar()
        .accessibilityIdentifier("archived-banner")
    }
}

/// Where an archived group's message box would be.
struct ArchivedFooter: View {
    var body: some View {
        Text("Nobody can post here while it is archived.")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal).padding(.vertical, 12)
            .background(.bar)
    }
}

/// The Archived list: the last row of the channel list opens it (a screen, with ☰). A tap opens
/// the group read only, where Unarchive is.
struct ArchivedScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let _ = model.version
        let list = model.derive.myArchived()
        List {
            if list.isEmpty {
                ContentUnavailableView("Nothing is archived", systemImage: "archivebox",
                                       description: Text("An archived channel or group leaves the channel list. It shows here, read only."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(list) { g in
                        NavigationLink(value: ChannelRoute(id: g.id)) {
                            HStack(spacing: 12) {
                                ChannelGlyph(group: g, size: 22).frame(width: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.isPod ? g.name : "#" + g.name).font(.body).lineLimit(1)
                                    Text(line(g)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Read only. Nobody can post in an archived channel or group; its admins can unarchive it.")
                }
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
    }

    private func line(_ g: Channel) -> String {
        var s = g.isPod ? "Group" : "Channel"
        if let p = g.parent, g.isPod, let parent = model.group(p) { s += " in " + (parent.isPod ? parent.name : "#" + parent.name) }
        if g.lastActivity > 0 { s += " · last message " + Format.short(g.lastActivity) }
        return s
    }
}

/// "Archive this group" in a group's settings, with the confirmation.
struct ArchiveSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var asking = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let g = model.group(id)
        let word = g?.isPod == true ? "group" : "channel"
        let name: String = g.map { $0.isPod ? $0.name : "#" + $0.name } ?? "it"
        Section {
            Button { asking = true } label: {
                HStack {
                    ActionRow(icon: "archivebox", title: "Archive this \(word)")
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("archive")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } footer: {
            Text("A softer way than deleting: it leaves the channel list and becomes read only.")
        }
        .alert("Archive \(name)?", isPresented: $asking) {
            Button("Archive") {
                guard !busy else { return }
                busy = true
                Task {
                    error = await model.setArchived(id, true)
                    busy = false
                    if error == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves the channel list and nobody can post in it. You can unarchive it later.")
        }
    }
}
