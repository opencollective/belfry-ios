import BelfryCore
import PhotosUI
import SwiftUI

// Profiles (SPEC 19.5, 19.16): picture, name, address, about, tags, place, guest / agent chips,
// shared channels, Message; Make it my agent / Remove; the admin switch. Edit my profile
// (username through the belfry, picture ≤ 512 px, tags with suggestions, place from the belfry's
// list). Me: my card, address, key, signed-in devices, outbox, sign out.

/// A profile to push; GROUP: opened from that channel's / group's / event's people (the profile
/// then shows the person's role there, SPEC 19.29).
struct ProfileKey: Identifiable, Hashable {
    let pubkey: String
    var group: String? = nil
    var id: String { pubkey + "|" + (group ?? "") }
}

/// Opens a profile on the stack of the screen or sheet it is tapped in (set by `profileStack()`);
/// the default pushes on the main screen's stack (through `model.openProfile`).
struct ShowProfileKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
extension EnvironmentValues {
    var showProfile: ((String) -> Void)? {
        get { self[ShowProfileKey.self] }
        set { self[ShowProfileKey.self] = newValue }
    }
}

/// Inside a sheet's own NavigationStack: profiles tapped in it are pushed on that stack.
struct ProfileStack: ViewModifier {
    @State private var shown: ProfileKey?
    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $shown) { ProfileView(pubkey: $0.pubkey, pushed: true, group: $0.group) }
            .environment(\.showProfile) { pk in hideKeyboard(); shown = ProfileKey(pubkey: pk) }
    }
}

extension View {
    func profileStack() -> some View { modifier(ProfileStack()) }
}

/// Opens PK's profile where the tap happened: the sheet's own stack, else the main screen's.
@MainActor struct OpenProfile {
    let env: ((String) -> Void)?
    let model: AppModel
    func callAsFunction(_ pk: String) { if let env { env(pk) } else { model.openProfile = pk } }
}

/// A profile as a contact card (Contacts): the face, the name, the address, round actions, then
/// About, Tags, Place, Role, Agents / Owner, Channels in common. Pushed on a stack (back swipe
/// returns), never a bottom sheet; `pushed: false` only where nothing else can hold it.
struct ProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let pubkey: String
    var pushed = false
    /// Opened from this group's people: "In <group>" with the role there.
    var group: String? = nil
    @State private var edit = false
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        if pushed { card } else { NavigationStack { card.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } } } }
    }

    private var card: some View {
        let _ = model.version
        let d = model.derive
        let p = d.profiles()[pubkey]
        let x = d.extras[pubkey]
        let me = pubkey == model.me
        let address = p?.nip05.flatMap { $0.contains("@") ? $0 : nil }
        return List {
            Section {
                VStack(spacing: 8) {
                    Avatar(pubkey: pubkey, size: 104)
                    Text(me ? (model.realName(pubkey).isEmpty ? "You" : model.realName(pubkey)) : model.name(pubkey))
                        .font(.title.bold()).multilineTextAlignment(.center)
                    if let address { Text(address).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack(spacing: 12) {
                        if !me && !d.isGuest(model.me) {
                            RoundAction(symbol: "message.fill", title: "Message") { model.messageAuthor = pubkey; if !pushed { dismiss() } }
                        }
                        if let address, !me {
                            RoundAction(symbol: "envelope.fill", title: "E-mail") {
                                if let u = URL(string: "mailto:" + address) { UIApplication.shared.open(u) }
                            }
                        }
                        if let n = Bech32.npub(pubkey) {
                            ShareLink(item: address ?? n) { RoundActionLabel(symbol: "square.and.arrow.up", title: "Share") }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if let about = p?.about, !about.isEmpty { Section("About") { MarkdownText(text: about) } }
            if let x, !x.tags.isEmpty {
                Section("Tags") { FlowRow(spacing: 6) { ForEach(x.tags, id: \.self) { Chip(text: "#" + $0) } } }
            }
            if let place = x?.place { Section("Place") { Label(People.placeLabel(place), systemImage: "mappin.and.ellipse") } }
            RoleSection(pubkey: pubkey) { error = $0 }
            if let group, model.group(group) != nil { GroupRoleSection(pubkey: pubkey, groupId: group) }
            if let owner = d.agentOwner(pubkey) {
                Section("Owner") {
                    ProfileRow(pubkey: owner, detail: owner == model.me ? "You" : nil)
                    if owner == model.me || d.isCommunityAdmin {
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove this agent…", systemImage: "person.badge.minus") }
                    }
                }
            } else if me && !d.isGuest(model.me) && !d.isAgent(model.me) && !model.guestReading {
                // Add an agent (members only): the button, or my agent with Remove
                AgentSection()
            } else {
                let theirs = model.config.agents.filter { $0.value == pubkey }.map(\.key).sorted()
                if !theirs.isEmpty {
                    Section("Agents") { ForEach(theirs, id: \.self) { a in ProfileRow(pubkey: a, detail: "Agent") } }
                }
            }
            if !me, model.mayMakeMine(pubkey) {
                Section {
                    BusyButton { error = await model.setMyAgent(pubkey, mine: true) } label: { Label("Make it my agent", systemImage: "person.badge.key") }
                } footer: { Text("It joins as yours: it stays while you do.") }
            }
            let shared = d.sharedGroups(pubkey)
            if !shared.isEmpty {
                Section(me ? "Your channels" : "Channels in common") {
                    ForEach(shared) { g in
                        Button { if !pushed { dismiss() }; openChannel(g.id, nil) } label: {
                            HStack(spacing: 10) { ChannelGlyph(group: g, size: 18); Text(g.name).foregroundStyle(.primary) }
                        }
                    }
                }
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if me { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { edit = true } } } }
        .sheet(isPresented: $edit) { EditProfileView() }
        .confirmationDialog("Remove this agent?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { error = await model.setMyAgent(pubkey, mine: false) } }
        } message: { Text("It is taken out of every channel. This can't be undone.") }
        .task {
            await model.revalidateConfig()
            await model.askWhois([pubkey])
            await model.loadRoles()
        }
    }
}

/// A round action under a contact's name (Contacts' Message / Mail / Share).
struct RoundActionLabel: View {
    let symbol: String
    let title: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 52, height: 40)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title).font(.caption2)
        }
        .foregroundStyle(Color.brand)
        .frame(minWidth: 64)
    }
}

struct RoundAction: View {
    let symbol: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { RoundActionLabel(symbol: symbol, title: title) }.buttonStyle(.plain)
    }
}

/// Someone as a row that opens their profile.
struct ProfileRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.showProfile) private var showProfile
    let pubkey: String
    var detail: String?
    var body: some View {
        Button { (showProfile ?? { model.openProfile = $0 })(pubkey) } label: {
            HStack(spacing: 10) {
                Avatar(pubkey: pubkey, size: 32)
                Text(model.name(pubkey)).foregroundStyle(.primary)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
        }
    }
}

/// The person's role (docs/roles.md): Member by default, Admin, or a custom role with its line;
/// "Guest" / "Agent of X" for those. For a belfry admin it opens the role picker.
struct RoleSection: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    let report: (String?) -> Void
    @State private var picking = false

    var body: some View {
        let d = model.derive
        Section("Role") {
            roleRows(d)
        }
        .navigationDestination(isPresented: $picking) { RoleChoiceList(pubkey: pubkey, report: report) }
        .onAppear { if model.launch.screen == "rolepicker", d.isCommunityAdmin { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picking = true } } }
    }

    @ViewBuilder private func roleRows(_ d: Derive) -> some View {
        SwiftUI.Group {
            if let owner = d.agentOwner(pubkey) {
                LabeledContent("Agent", value: "of " + model.realNameOrKey(owner))
            } else if d.isGuest(pubkey) && !d.isBelfryAdmin(pubkey) {
                if d.isCommunityAdmin && d.noAdminReason(pubkey) == nil {
                    Button { picking = true } label: { LabeledContent("Guest", value: "Make a member…") }
                } else {
                    LabeledContent("Guest", value: d.noAdminReason(pubkey) == nil ? "" : "No e-mail yet")
                }
            } else {
                let role = currentRole
                if d.isCommunityAdmin {
                    Button { picking = true } label: {
                        HStack { roleLine(role).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    roleLine(role)
                }
            }
        }
    }

    var currentRole: Role? {
        if model.derive.isBelfryAdmin(pubkey) { return model.roles.role(Role.admin) ?? Role.builtins[1] }
        return model.roles.role(model.roles.members[pubkey] ?? Role.member) ?? Role.builtins[0]
    }

    func roleLine(_ r: Role?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r?.label ?? "Member")
            if let desc = r?.description, !desc.isEmpty { Text(desc).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

/// The role picker (web RolePicker.tsx): the roles with a checkmark on the current one; Admin
/// goes through /admins, any other role through /member-roles; the row locks while it saves.
struct RoleChoiceList: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    let report: (String?) -> Void
    @State private var saving: String?
    @State private var error: String?

    var body: some View {
        let d = model.derive
        let current = d.isBelfryAdmin(pubkey) ? Role.admin : (d.isGuest(pubkey) ? nil : (model.roles.members[pubkey] ?? Role.member))
        List {
            Section {
                ForEach(model.roles.roles) { r in
                    Button { pick(r.id, current: current) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.label).foregroundStyle(.primary)
                                if !r.description.isEmpty { Text(r.description).font(.footnote).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if saving == r.id { ProgressView() } else if r.id == current { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving != nil)
                }
            } footer: { Text("Steward is the only role with powers. A guest given a role becomes a member.") }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            Section { NavigationLink { RolesSettings() } label: { Label("Edit roles…", systemImage: "pencil") } }
        }
        .navigationTitle("Role")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadRoles() }
    }

    private func pick(_ id: String, current: String?) {
        guard saving == nil, id != current else { return }
        saving = id
        error = nil
        Task {
            var e: String?
            if id == Role.admin {
                e = await model.setAdmin(pubkey, true)
            } else if model.engine?.localOnly == true {
                if current == Role.admin { e = await model.setAdmin(pubkey, false) }
                model.roles.members[pubkey] = id
            } else {
                do { try await model.api.setMemberRole(pubkey, role: id); await model.revalidateConfig(force: true) }
                catch let x as ApiError { e = x.message } catch { e = BelfryAPI.network }
            }
            await model.loadRoles(force: true)
            if e == nil { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            error = e
            report(e)
            saving = nil
        }
    }
}

struct EditProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var about = ""
    @State private var tags = [String]()
    @State private var newTag = ""
    @State private var share: Share = .city
    @State private var place: Place?
    @State private var photo: PhotosPickerItem?
    @State private var picture: Data?
    @State private var error: String?
    @State private var loaded = false
    @State private var placePicker = false

    var body: some View {
        let d = model.derive
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photo, matching: .images) {
                            VStack {
                                if let picture, let img = UIImage(data: picture) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 80, height: 80).clipShape(Circle())
                                } else {
                                    Avatar(pubkey: model.me, size: 80)
                                }
                                Text("Change picture").font(.caption)
                            }
                        }
                        Spacer()
                    }
                }
                Section("Name") { TextField("Your name", text: $name).font(.body) }
                Section {
                    HStack(spacing: 2) {
                        TextField("username", text: $username).font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("@" + model.config.domain).foregroundStyle(.secondary)
                    }
                } header: { Text("Username") } footer: { Text("Your address here, and your e-mail address.") }
                Section("About") { TextField("A few words about you (Markdown)", text: $about, axis: .vertical).lineLimit(3...8).font(.body) }
                Section("Tags") {
                    if !tags.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(tags, id: \.self) { t in
                                Button { tags.removeAll { $0 == t } } label: { Chip(text: "#" + t, icon: "xmark", tint: .brand) }.buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(t)")
                            }
                        }
                    }
                    HStack {
                        TextField("Add a tag", text: $newTag).font(.body).textInputAutocapitalization(.never).onSubmit(addTag)
                        Button("Add", action: addTag).disabled(People.cleanTag(newTag).isEmpty)
                    }
                    let suggestions = d.allTags.map(\.tag).filter { !tags.contains($0) && (newTag.isEmpty || $0.hasPrefix(People.cleanTag(newTag))) }.prefix(8)
                    if !suggestions.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(Array(suggestions), id: \.self) { t in
                                Button { tags = People.cleanTags(tags + [t]) } label: { Chip(text: "+ #" + t) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    Picker("Show", selection: $share) {
                        Text("My city").tag(Share.city)
                        Text("Only my country").tag(Share.country)
                        Text("Nothing").tag(Share.none)
                    }
                    if share != .none {
                        Button { placePicker = true } label: {
                            ActionRow(icon: "mappin.and.ellipse", title: place.map { share == .country ? People.countryName($0.country) : People.placeLabel($0) } ?? "Pick a place")
                        }
                    }
                } header: { Text("Where you are") } footer: { Text("Picked from a list of cities, never from your phone's location.") }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { BusyButton("Save") { await save() }.disabled(name.jsTrim().isEmpty) }
            }
            .sheet(isPresented: $placePicker) { PlacePicker { place = $0 } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { picture = Images.jpeg(data, max: 512) }
                }
            }
            .onAppear(perform: load)
        }
    }

    var currentUsername: String {
        let n5 = model.derive.profiles()[model.me]?.nip05 ?? ""
        return String(n5.split(separator: "@").first ?? "")
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        let d = model.derive
        name = model.realName(model.me)
        about = d.aboutOf(model.me)
        username = currentUsername
        if let x = d.extras[model.me] {
            tags = x.tags
            share = x.share
            place = x.place
        }
    }

    func addTag() {
        tags = People.cleanTags(tags + [newTag])
        newTag = ""
    }

    func save() async {
        error = nil
        if username.jsTrim().lowercased() != currentUsername, !username.jsTrim().isEmpty {
            if let e = await model.setUsername(username) { error = e; return }
        }
        if let e = await model.saveProfile(name: name, about: about, picture: picture) { error = e; return }
        model.saveExtras(tags: tags, share: share, place: share == .none ? nil : place)
        dismiss()
    }
}

/// A city from the belfry's list (GET /places), a place a member adds, or a country only.
struct PlacePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pick: (Place) -> Void
    @State private var query = ""
    @State private var results = [Place]()
    @State private var adding = false
    @State private var newName = ""
    @State private var near: Place?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if adding {
                    Section {
                        TextField("The place's name", text: $newName).font(.body)
                        Text(near.map { "Near \(People.placeLabel($0))" } ?? "Search the nearest city above, then pick it").font(.caption).foregroundStyle(.secondary)
                        BusyButton("Add the place") {
                            guard let near else { return }
                            switch await model.addPlace(name: newName.jsTrim(), country: near.country, near: near.placeId ?? "") {
                            case .success(let p): pick(p); dismiss()
                            case .failure(let e): error = e.message
                            }
                        }
                        .disabled(newName.jsTrim().isEmpty || near == nil)
                    }
                }
                Section {
                    ForEach(results) { p in
                        Button {
                            if adding { near = p } else { pick(p); dismiss() }
                        } label: { ActionRow(icon: "mappin", title: p.name ?? p.country, detail: [p.region, People.countryName(p.country)].compactMap { $0 }.joined(separator: ", ")) }
                    }
                }
                if !adding {
                    Section { Button { adding = true } label: { ActionRow(icon: "plus", title: "My place is not in the list") } }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: adding ? "Nearest city" : "City")
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                results = await model.searchPlaces(query)
            }
            .navigationTitle("Where you are")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Me: my card (edit), address, key, signed-in devices, the outbox, sign out.
struct AccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var edit = false
    @State private var copied = false
    /// Pushed from the Town drawer's last row (your face and name): Me as a screen, no Done.
    var pushed = false

    var body: some View {
        if pushed {
            content
        } else {
            NavigationStack { content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
        }
    }

    private var content: some View {
        let _ = model.version
        let queued = model.engine?.outboxItems() ?? []
        return List {
                Section {
                    Button { if pushed { model.openProfile = model.me } else { edit = true } } label: {
                        HStack(spacing: 14) {
                            Avatar(pubkey: model.me, size: 56)
                            VStack(alignment: .leading) {
                                Text(model.realName(model.me).isEmpty ? "You" : model.realName(model.me)).font(.headline)
                                Text(model.derive.myAddress ?? model.config.domain).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pushed { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) } else { Text("Edit").font(.subheadline).foregroundStyle(Color.brand) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if model.unsavedGuest {
                    Section { SaveAccountCard() }
                }
                Section("Community") {
                    LabeledContent("Name", value: model.config.name)
                    LabeledContent("Address", value: model.config.domain)
                    if let n = Bech32.npub(model.me) {
                        Button {
                            UIPasteboard.general.string = n
                            copied = true
                        } label: {
                            LabeledContent("Your key") { Text(copied ? "Copied" : String(n.prefix(16)) + "…").font(.caption.monospaced()) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    NavigationLink { NotificationsView() } label: {
                        ActionRow(icon: "bell", title: "Notifications", detail: model.pushState == .on ? "On" : model.pushState == .denied ? "Off in Settings" : "Turn on")
                    }
                    NavigationLink { DevicesView() } label: { ActionRow(icon: "iphone", title: "Signed-in devices") }
                    if !queued.isEmpty {
                        ActionRow(icon: "tray.and.arrow.up", title: "\(queued.count) waiting to be sent",
                                  detail: queued.contains { $0.status == .failed } ? "Some could not be sent: Retry or Discard them where they are" : nil)
                    }
                }
                Section {
                    Button(model.isDemo ? "Leave the demo" : "Sign out", role: .destructive) { confirm = true }
                } footer: {
                    Text("Signing out ends this phone's session and removes this belfry's messages from it. Your key stays on the belfry.")
                }
            }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Sign out of \(model.config.name)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { dismiss(); Task { await model.signOutEverywhere() } }
            }
            .sheet(isPresented: $edit) { EditProfileView() }
            .onAppear { if model.launch.screen == "editprofile" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { edit = true } } }
        }
}

/// Signed-in devices: the sessions open on my key; end one (this device is marked).
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var list: [SessionInfo]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            if let list {
                ForEach(list) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.applicationName.isEmpty ? "An app" : s.applicationName).font(.subheadline.weight(.semibold))
                            Text([s.device, s.lastActivity.map { "last used " + $0.prefix(10) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.bunkerPubkey == model.mySessionKey {
                            Text("This device").font(.caption).foregroundStyle(.secondary)
                        } else {
                            BusyButton("End", role: .destructive) {
                                if let e = await model.endSession(s.bunkerPubkey) { error = e } else { await load() }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Signed-in devices")
        .task { await load() }
    }

    func load() async {
        switch await model.sessions() {
        case .success(let l): list = l
        case .failure(let e): error = e.message; list = []
        }
    }
}

/// A guest who joined with a name only (an event's guest, an older link) saves their account:
/// Save opens the same sheet as joining from guest mode, with the e-mail only (SPEC 19.26).
struct SaveAccountCard: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var open = false
    @State private var savedAs: String?

    var body: some View {
        HStack(spacing: 10) {
            if let savedAs {
                Label("Saved. Sign in with \(savedAs) on any device.", systemImage: "checkmark.circle").foregroundStyle(.green)
                    .font(compact ? .caption : .subheadline)
            } else {
                Text(model.coHostToken != nil ? "To host this event, save your account with your e-mail." : "Save your account: add your e-mail to come back from any device.")
                    .font(compact ? .caption : .subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Save") { open = true }
                    .buttonStyle(.brand)
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $open) { JoinSheet(saveOnly: true) { savedAs = $0 } }
    }
}
