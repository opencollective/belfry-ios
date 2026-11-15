import BelfryCore
import PhotosUI
import SwiftUI

// Belfry settings, for its admins (web Settings.tsx; the community's name at the top of the
// drawer opens it, as in Discord): Branding, Roles, Membership, the order of the channels.

struct BelfrySettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// An open screen from the drawer (☰, no Done) rather than a sheet.
    var screen = false
    @State private var ordering = false

    var body: some View {
        if screen { content } else { NavigationStack { content } }
    }

    private var content: some View {
            List {
                Section {
                    NavigationLink { BrandingSettings() } label: { Label("Branding", systemImage: "paintpalette") }
                    NavigationLink { RolesSettings() } label: { Label("Roles", systemImage: "person.badge.key") }
                    NavigationLink { MembershipSettingsView() } label: { Label("Membership", systemImage: "person.2.badge.gearshape") }
                    Button { ordering = true } label: { Label("Order of the channels", systemImage: "arrow.up.arrow.down") }
                } footer: { Text("Mail, the website and add-ons are in the console: belfry.\(model.config.domain).") }
            }
            .navigationTitle(model.config.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if screen { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
                else { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .sheet(isPresented: $ordering) { ChannelOrderSheet() }
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
