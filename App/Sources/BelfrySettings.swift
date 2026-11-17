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
                    NavigationLink { BrandingSettings() } label: { Label("Branding", systemImage: "paintpalette") }
                    NavigationLink { RolesSettings() } label: { Label("Roles", systemImage: "person.badge.key") }
                    NavigationLink { MembershipSettingsView() } label: { Label("Membership", systemImage: "person.2.badge.gearshape") }
                    NavigationLink { ChannelsSettings() } label: { Label("Channels", systemImage: "list.bullet.indent") }
                        .accessibilityIdentifier("settings-channels")
                } footer: { Text("Mail, the website and add-ons are in the console: belfry.\(model.config.domain).") }
            }
            .navigationTitle(model.config.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if screen { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
                else { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
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

    var body: some View {
        let d = model.derive
        let names = Dictionary(d.townChannels().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let rows = Categories.flat(cats)
        List {
            Section {
                Label(model.group(generalId)?.name ?? "Square", systemImage: "number")
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
                Button { name = ""; adding = true } label: { Label("Add a category", systemImage: "plus") }
                    .accessibilityIdentifier("channels-add-category")
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
                        Label(names[cid] ?? cid, systemImage: "number")
                    }
                }
                .onMove { from, to in
                    var flat = rows
                    flat.move(fromOffsets: from, toOffset: to)
                    cats = Categories.rebuild(cats, flat: flat)
                    save()
                }
            } header: { Text("Channels") } footer: {
                Text(saved > 0 ? "Saved. Everyone sees the channels in this order." : "Hold a channel and drag it to move it, within a category or to another one.")
            }
        }
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
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
        }
    }

    private func save() {
        model.setChannelLayout(cats)
        saved += 1
    }
}
