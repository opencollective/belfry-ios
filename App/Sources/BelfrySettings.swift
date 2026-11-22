import BelfryCore
import PhotosUI
import SwiftUI

// Belfry settings, for its admins (web Settings.tsx; the gear at the top of the drawer opens it):
// Branding, Roles, Membership, Channels (their order and categories, SPEC 19.34).

struct BelfrySettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// An open screen from the drawer (☰, no Done) rather than a sheet.
    var screen = false

    var body: some View {
        if screen { content } else { NavigationStack { content } }
    }

    private var content: some View {
            List {
                Section {
                    NavigationLink { BrandingSettings() } label: { row("paintpalette", "Branding", "Logo, cover, colours, description") }
                    NavigationLink { RolesSettings() } label: { row("person.badge.key", "Roles", model.roles.roles.map(\.label).joined(separator: " · ")) }
                    NavigationLink { MembershipSettingsView() } label: {
                        row("person.2.badge.gearshape", "Membership",
                            (model.membership.invite == "members" ? "Members invite" : "Stewards invite") + " · " + (model.membership.accept == "vouches" ? "members vouch" : "stewards accept"))
                    }
                    NavigationLink { ChannelsSettings() } label: { row("list.bullet.indent", "Channels", "Categories, order, archive or delete") }
                        .accessibilityIdentifier("settings-channels")
                } header: { Text(model.config.name) }
                // the rest is the belfry's console, in the browser (board home/belfry-settings)
                Section {
                    ForEach(BelfrySettings.console, id: \.path) { c in
                        Button { if let u = URL(string: "https://belfry.\(model.config.domain)" + c.path) { UIApplication.shared.open(u) } } label: {
                            HStack {
                                Label(c.title, systemImage: c.icon).foregroundStyle(.primary)
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right.square").font(.footnote).foregroundStyle(.tertiary).accessibilityLabel("Opens in the browser")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("In the console") } footer: { Text("These open belfry.\(model.config.domain) in the browser.") }
            }
            .task { await model.loadRoles(); await model.loadMembership() }
            .navigationTitle("Belfry settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if screen { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
                else { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
    }
}

extension BelfrySettings {
    /// The console's pages a steward is sent to (the same four as Android).
    static let console: [(title: String, path: String, icon: String)] = [
        ("Mail", "/plugins/email", "envelope"), ("Website", "/website", "globe"),
        ("Plugins and sales", "/plugins", "puzzlepiece.extension"), ("Add people", "/members/add", "person.badge.plus"),
    ]

    func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
        } icon: { Image(systemName: icon) }
    }
}

/// Logo, cover image, two colours and the line under the community's name (web Branding.tsx).
struct BrandingSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var b = Branding()
    @State private var primary = Color.accentColor
    @State private var secondary = Color.gray
    @State private var usePrimary = false
    @State private var useSecondary = false
    @State private var logoItem: PhotosPickerItem?
    @State private var coverItem: PhotosPickerItem?
    @State private var uploading: String?
    @State private var error: String?
    @State private var saved = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                image("Logo", b.logo, $logoItem, square: true)
                image("Cover", b.cover, $coverItem, square: false)
            } footer: { Text("The logo stands before the community's name; the cover at the top of the channel list.") }
            Section {
                Toggle("Primary colour", isOn: $usePrimary).tint(Theme.toggle)
                if usePrimary { ColorPicker("Primary", selection: $primary, supportsOpacity: false) }
                Toggle("Secondary colour", isOn: $useSecondary).tint(Theme.toggle)
                if useSecondary { ColorPicker("Secondary", selection: $secondary, supportsOpacity: false) }
            } footer: { Text("Primary: buttons and links. Without it the belfry looks neutral, black on white.") }
            Section("Description") {
                TextField("The line under the community's name on its homepage", text: $b.description, axis: .vertical).lineLimit(2...5).font(.body)
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            Section {
                BusyButton { await save() } label: { Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "square.and.arrow.down") }
                    .disabled(uploading != nil)
            }
        }
        .navigationTitle("Branding")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            var cur = model.config.branding ?? Branding()
            if model.engine?.localOnly != true, let fresh = try? await model.api.branding() { cur = fresh }
            b = cur
            if let (r, g, bl) = Branding.rgb(cur.primary) { primary = Color(red: r, green: g, blue: bl); usePrimary = true }
            if let (r, g, bl) = Branding.rgb(cur.secondary) { secondary = Color(red: r, green: g, blue: bl); useSecondary = true }
        }
        .onChange(of: logoItem) { _, i in if let i { Task { await upload(i, logo: true) } } }
        .onChange(of: coverItem) { _, i in if let i { Task { await upload(i, logo: false) } } }
    }

    private func image(_ title: String, _ url: String, _ item: Binding<PhotosPickerItem?>, square: Bool) -> some View {
        HStack(spacing: 12) {
            if let u = URL(string: url), !url.isEmpty {
                CachedImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: square ? 44 : 78, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.12))
                    .frame(width: square ? 44 : 78, height: 44).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            Text(title)
            Spacer()
            if uploading == title { ProgressView() }
            PhotosPicker(selection: item, matching: .images) { Text(url.isEmpty ? "Choose" : "Change") }.disabled(uploading != nil)
            if !url.isEmpty {
                Button(role: .destructive) { if square { b.logo = "" } else { b.cover = "" } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Remove the \(title.lowercased())")
            }
        }
    }

    private func upload(_ item: PhotosPickerItem, logo: Bool) async {
        uploading = logo ? "Logo" : "Cover"
        defer { uploading = nil; if logo { logoItem = nil } else { coverItem = nil } }
        guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { error = "That picture could not be read."; return }
        let jpeg = img.resizedToFit(logo ? 512 : 1600).jpegData(compressionQuality: 0.85) ?? data
        guard let engine = model.engine, !engine.localOnly else { error = "Demo: pictures stay on this phone."; return }
        do {
            let url = try await engine.upload(jpeg, name: logo ? "logo.jpg" : "cover.jpg", mime: "image/jpeg", sha: Crypto.sha256(jpeg).hex)
            if logo { b.logo = url } else { b.cover = url }
        } catch { self.error = "The picture could not be uploaded. Try again." }
    }

    private func save() async {
        error = nil
        let change: [String: String] = ["logo": b.logo, "cover": b.cover, "primary": usePrimary ? primary.hex : "", "secondary": useSecondary ? secondary.hex : "", "description": b.description]
        if model.engine?.localOnly == true {
            model.config.branding = Branding.clean(change)
            saved = true
            return
        }
        do {
            let got = try await model.api.saveBranding(change)
            model.config.branding = got.isEmpty ? nil : got
            await model.revalidateConfig(force: true)
            saved = true
        } catch let e as ApiError { error = e.message } catch { self.error = BelfryAPI.network }
    }
}

/// Who can invite members, and how requests to join are accepted (docs/membership.md).
struct MembershipSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        let m = model.membership
        Form {
            Section {
                Picker("Who can invite members", selection: Binding(get: { m.invite }, set: { v in save(invite: v) })) {
                    Text("Admins only").tag("admins"); Text("Any member").tag("members")
                }
            } footer: { Text("Any member: with the default role only.") }
            Section {
                Picker("Requests to join are accepted by", selection: Binding(get: { m.accept }, set: { v in save(accept: v) })) {
                    Text("The admins").tag("admins"); Text("Members vouching").tag("vouches")
                }
                if m.accept == "vouches" {
                    Stepper("\(m.vouches) \(m.vouches == 1 ? "vouch" : "vouches") needed", value: Binding(get: { m.vouches }, set: { v in save(vouches: v) }), in: 1...5)
                }
            }
            if busy { Section { ProgressView() } }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
        }
        .disabled(busy)
        .navigationTitle("Membership")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadMembership() }
    }

    private func save(invite: String? = nil, accept: String? = nil, vouches: Int? = nil) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            if model.engine?.localOnly == true {
                var m = model.membership
                if let invite { m.invite = invite }
                if let accept { m.accept = accept }
                if let vouches { m.vouches = vouches }
                model.membership = m
            } else {
                do { model.membership = try await model.api.setMembership(invite: invite, accept: accept, vouches: vouches) }
                catch let e as ApiError { error = e.message } catch { self.error = BelfryAPI.network }
            }
            busy = false
        }
    }
}

extension Color {
    /// #rrggbb (sRGB).
    var hex: String {
        let c = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func h(_ v: CGFloat) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b)
    }
}

extension UIImage {
    /// At most SIDE points on the longer side.
    func resizedToFit(_ side: CGFloat) -> UIImage {
        let s = max(size.width, size.height)
        guard s > side else { return self }
        let k = side / s
        let to = CGSize(width: size.width * k, height: size.height * k)
        return UIGraphicsImageRenderer(size: to).image { _ in draw(in: CGRect(origin: .zero, size: to)) }
    }
}

/// Channels (SPEC 19.34): the town (fixed), the categories (rename, add, delete, reorder) and the
/// channels under their categories (drag to reorder or move to another category). Each change is
/// published at once (the admins' 30078 d=belfry:channel-order; latest wins).
struct ChannelsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var cats = [ChannelCategory]()
    @State private var loaded = false
    @State private var renaming: ChannelCategory?
    @State private var name = ""
    @State private var adding = false
    @State private var saved = 0
    @State private var ending: String?

    var body: some View {
        let d = model.derive
        let names = Dictionary(d.townChannels().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // a channel deleted or archived meanwhile leaves the list (its category keeps the rest)
        let rows = Categories.flat(cats).filter { r in
            if case .channel(let cid) = r { return names[cid] != nil }
            return true
        }
        List {
            Section {
                Label(model.group(generalId)?.name ?? "Townsquare", systemImage: "number")
                Label(PlaceNames.members, systemImage: "person.2")
                Label("Charter", systemImage: "doc.text")
            } header: { Text("The town") } footer: { Text("The town's places stay first and keep their names.") }
            .foregroundStyle(.secondary)
            Section {
                ForEach(cats) { c in
                    Button { name = c.name; renaming = c } label: {
                        HStack {
                            Label(c.name, systemImage: "folder").foregroundStyle(.primary)
                            Spacer()
                            Text("\(c.channels.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .deleteDisabled(c.isBuiltIn)
                    .accessibilityHint("Rename")
                }
                .onMove { from, to in cats.move(fromOffsets: from, toOffset: to); save() }
                .onDelete { idx in
                    for id in idx.map({ cats[$0].id }) { cats = Categories.remove(id, cats) }
                    save()
                }
            } header: { Text("Categories") } footer: {
                Text("Tap one to rename it. Deleting a category moves its channels to \(ChannelCategory.defaultNames[ChannelCategory.life]!).")
            }
            Section {
                ForEach(rows, id: \.self) { r in
                    switch r {
                    case .header(let cid):
                        Text((cats.first { $0.id == cid }?.name ?? cid).uppercased())
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .listRowBackground(Color.clear)
                            .moveDisabled(true)
                    case .channel(let cid):
                        // tap: delete it when nobody wrote in it, else archive it (SPEC 19.35)
                        Button { ending = cid } label: {
                            HStack {
                                Label(names[cid] ?? cid, systemImage: "number").foregroundStyle(.primary)
                                Spacer()
                                if d.mayEndChannel(model.group(cid)) {
                                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(!d.mayEndChannel(model.group(cid)))
                        .accessibilityIdentifier("channels-row-" + cid)
                        .accessibilityHint("Delete or archive")
                    }
                }
                .onMove { from, to in
                    var flat = rows
                    flat.move(fromOffsets: from, toOffset: to)
                    cats = Categories.rebuild(cats, flat: flat)
                    save()
                }
            } header: { Text("Channels") } footer: {
                Text(saved > 0 ? "Saved. Everyone sees the channels in this order." : "Hold a channel and drag it to move it, within a category or to another one. Tap one to delete it (when nobody wrote in it) or archive it.")
            }
        }
        .sheet(item: Binding(get: { ending.map(EndingID.init) }, set: { ending = $0?.id })) { e in
            ChannelEndSheet(id: e.id)
        }
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.inline)
        // "add one" is an icon top right, never a row (Xavier, 2026-11-22): ＋ = a new category
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button { name = ""; adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a category")
                    .accessibilityIdentifier("channels-add-category")
            }
        }
        .sensoryFeedback(.success, trigger: saved)
        .alert("Rename the category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let r = renaming, !n.isEmpty, let i = cats.firstIndex(where: { $0.id == r.id }) { cats[i].name = String(n.prefix(60)); save() }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("New category", isPresented: $adding) {
            TextField("Name", text: $name)
            Button("Add") {
                let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                if !n.isEmpty { cats.append(ChannelCategory(id: Categories.newId(n), name: n, channels: [])); save() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            cats = model.derive.channelCategories()
            // screenshots: an empty channel's sheet / its confirmation; a channel with messages
            let shot: String? = switch model.launch.screen {
            case "channelend", "channelendconfirm": "tools-2b8e"
            case "channelarchive": "kitchen-7d10"
            default: nil
            }
            if let shot { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ending = shot } }
        }
    }

    private func save() {
        model.setChannelLayout(cats)
        saved += 1
    }
}

private struct EndingID: Identifiable { let id: String }
