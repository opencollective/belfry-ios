import BelfryCore
import SwiftUI

// New group (boards groups/new, groups/new-pick, canvas v183; one-shape.md "Groups: open, closed,
// private"): the ＋ of Groups opens the form directly: Name, What is it working on?, and who can
// join (Open · Any member can join / Closed · Members apply to join / Private · Only invited
// people). After Create, a grid of the belfry's members (the directory, not guests) to add: Add N
// people, or Skip. The question people answer and who accepts are in the group's Settings (Closed
// only). A private group is in no list for those who are not in it.

struct NewGroupScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var about = ""
    @State private var access = GroupAccess.open
    @State private var made: GroupPick?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).font(.body).focused($focused)
                    .accessibilityIdentifier("group-name")
                TextField("What is it working on?", text: $about, axis: .vertical).lineLimit(2...5).font(.body)
                    .accessibilityIdentifier("group-about")
            }
            Section("Who can join") {
                ForEach(GroupAccess.allCases, id: \.self) { a in
                    Button { access = a } label: {
                        HStack(spacing: 12) {
                            Image(systemName: a == .open ? "door.left.hand.open" : a == .closed ? "hand.raised" : "lock")
                                .foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).foregroundStyle(.primary)
                                Text(a.line).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if access == a { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(access == a ? .isSelected : [])
                    .accessibilityIdentifier("group-access-" + a.rawValue)
                }
            }
        }
        .navigationTitle("New group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                BusyButton("Create") { create() }
                    .disabled(name.jsTrim().isEmpty)
                    .accessibilityIdentifier("group-create")
            }
        }
        .navigationDestination(item: $made) { p in NewGroupPickScreen(group: p.id) }
        .onAppear {
            if model.launch.screen == "groupnew" { name = "Tool library crew"; about = "Keeps the shared tools in order"; access = .closed }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
        }
    }

    private func create() {
        hideKeyboard()
        let id = model.createGroup(name: name.jsTrim(), about: about.jsTrim(), access: access)
        made = GroupPick(id: id)
    }
}

struct GroupPick: Hashable, Identifiable { let id: String }

/// After the form: who is added now. A grid of faces, a search field, Add N people / Skip.
struct NewGroupPickScreen: View {
    @EnvironmentObject var model: AppModel
    let group: String
    @State private var people: [DirMember]?
    @State private var picked = Set<String>()
    @State private var query = ""
    @State private var failed = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8, alignment: .top)]

    var body: some View {
        let list = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if people == nil && !failed { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                if failed {
                    Label("The members couldn't be loaded. You can add people later from the group.", systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(list) { m in
                        let on = picked.contains(m.pubkey)
                        Button { if on { picked.remove(m.pubkey) } else { picked.insert(m.pubkey) } } label: {
                            VStack(spacing: 6) {
                                Avatar(pubkey: m.pubkey, size: 56)
                                    .overlay(alignment: .bottomTrailing) {
                                        if on {
                                            Image(systemName: "checkmark.circle.fill").font(.title3)
                                                .foregroundStyle(.white, Color.brand)
                                                .background(Color(uiColor: .systemBackground), in: Circle())
                                                .offset(x: 4, y: 4)
                                        }
                                    }
                                    .opacity(on ? 1 : 0.92)
                                Text(name(m)).font(.caption).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name(m))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("group-pick-" + m.pubkey.prefix(8))
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 8)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search members")
        .navigationTitle("Add people")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip") { open() }.accessibilityIdentifier("group-pick-skip")
            }
            ToolbarItem(placement: .confirmationAction) {
                BusyButton(picked.isEmpty ? "Add" : (picked.count == 1 ? "Add 1 person" : "Add \(picked.count) people")) {
                    model.addPeople(Array(picked), to: group)
                    open()
                }
                .disabled(picked.isEmpty)
                .accessibilityIdentifier("group-pick-add")
            }
        }
        .task { await load() }
    }

    private var shown: [DirMember] {
        let q = query.jsTrim().lowercased()
        return (people ?? []).filter { $0.pubkey != model.me && (q.isEmpty || name($0).lowercased().contains(q)) }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    private func name(_ m: DirMember) -> String {
        let n = model.realName(m.pubkey)
        return n.isEmpty ? (m.name.isEmpty ? model.name(m.pubkey) : m.name) : n
    }

    /// The new group opens as a place of its own; the form and this screen leave the stack.
    private func open() {
        hideKeyboard()
        model.tabReselected += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { model.joinedChannel = group }
    }

    private func load() async {
        if model.engine?.localOnly == true {
            // the demo: the people of its channels (guests and agents left out)
            let d = model.derive
            let keys = Set(model.groups.flatMap(\.members)).filter { !d.isGuest($0) && d.agentOwner($0) == nil }
            people = keys.map { DirMember(pubkey: $0, name: "", role: nil, agents: []) }
            if model.launch.screen == "groupnewpick" { picked = Set(keys.filter { $0 != model.me }.sorted().prefix(2)) }
            return
        }
        do { people = try await model.api.directory() } catch { failed = true; people = [] }
    }
}
