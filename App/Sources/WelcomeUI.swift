import BelfryCore
import PhotosUI
import SwiftUI

// A new member's first minutes (board Join-Member 1–3; web Charter.tsx WelcomeFlow): Welcome
// (the belfry's mark, name, description, who let you in) → the charter, each agreement ticked on
// its own ("4 of 6 agreed" until all are) → name and photo, with Skip. When it shows:
// AppModel.welcomeDue (this device saw the account's guest become a member, a charter exists, the
// person never ticked an agreement: the belfry signs the ticks a guest gave when applying, so a
// just-accepted member isn't asked again).

struct WelcomeFlow: View {
    @EnvironmentObject var model: AppModel
    @State private var step = Step.hello
    @State private var ticked = Set<String>()
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var picture: Data?
    @State private var error: String?
    @State private var loaded = false

    enum Step { case hello, charter, profile }

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                switch step {
                case .hello: hello
                case .charter: charter
                case .profile: profile
                }
            }
            .animation(.snappy, value: step)
        }
        .interactiveDismissDisabled()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            ticked = Set(model.charterRules.filter { $0.agreed[model.me] != nil }.map(\.id))
            name = model.realName(model.me)
            if model.launch.screen == "welcomecharter" { step = .charter; ticked = Set(model.charterRules.prefix(4).map(\.id)) }
            if model.launch.screen == "welcomeprofile" { step = .profile }
        }
    }

    private var hello: some View {
        let rules = model.charterRules
        let community = model.config.name
        return VStack(spacing: 18) {
            Spacer()
            BelfryLogo(size: 64).frame(width: 104, height: 104).background(Color.brand.opacity(0.1), in: Circle())
            Text("Welcome to \(community)").font(.largeTitle.bold()).multilineTextAlignment(.center)
            if let about = model.config.branding?.description, !about.isEmpty {
                Text(about).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let by = model.welcomeInviter {
                HStack(spacing: 8) { Avatar(pubkey: by, size: 28); Text("\(model.name(by)) let you in").font(.subheadline) }
            }
            if !rules.isEmpty {
                Text("Next: \(community)'s charter, \(rules.count == 1 ? "one short agreement" : "\(rules.count) short agreements").")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            Button { step = rules.isEmpty ? .profile : .charter } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.brand)
                .accessibilityIdentifier("welcome-continue")
        }
        .padding(24)
    }

    private var charter: some View {
        let rules = model.charterRules
        let all = rules.allSatisfy { ticked.contains($0.id) }
        return List {
            Section {
                Text(rules.count == 1 ? "One short agreement. Tick it if you agree." : "\(rules.count) short agreements. Tick each one you agree to.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(rules) { r in
                    let on = ticked.contains(r.id)
                    Button { if on { ticked.remove(r.id) } else { ticked.insert(r.id) } } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(on ? Color.brand : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                if !r.about.isEmpty { Text(r.about).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Our charter")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            BusyButton {
                for r in rules where r.agreed[model.me] == nil { model.agree(r, true) }
                step = .profile
            } label: { Text(all ? "Continue" : "\(ticked.count) of \(rules.count) agreed").frame(maxWidth: .infinity) }
            .buttonStyle(.brand)
            .disabled(!all)
            .padding()
            .background(.bar)
        }
    }

    private var profile: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        VStack(spacing: 6) {
                            if let picture, let img = UIImage(data: picture) {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 96, height: 96).clipShape(Circle())
                            } else {
                                Avatar(pubkey: model.me, size: 96)
                            }
                            Text("Add a photo").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Name", text: $name).font(.body).textContentType(.name)
            } footer: {
                Text("This is how people in \(model.config.name) see you. About, place and tags can wait: they're in your profile whenever you want.")
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            Section {
                BusyButton {
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if picture != nil || (!n.isEmpty && n != model.realName(model.me)) {
                        if let e = await model.saveProfile(name: n.isEmpty ? model.realName(model.me) : n, about: model.derive.aboutOf(model.me), picture: picture) {
                            error = e
                            return
                        }
                    }
                    model.welcomeDone()
                } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.brand)
            }
        }
        .navigationTitle("Your profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Skip") { model.welcomeDone() } } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { if let data = try? await item.loadTransferable(type: Data.self) { picture = Images.jpeg(data, max: 512) } }
        }
    }
}
