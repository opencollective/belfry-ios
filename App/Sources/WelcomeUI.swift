import BelfryCore
import SwiftUI

// A new member's first minutes (board Join-Member 1–3; web Charter.tsx WelcomeFlow): Welcome
// (the belfry's mark, name, description, who let you in) → the charter, each agreement ticked on
// its own ("4 of 6 agreed" until all are) → the chat (no name-and-photo step since 2026-11-19:
// the name is the one given when joining, the photo the initial). When it shows:
// AppModel.welcomeDue (this device saw the account's guest become a member, a charter exists, the
// person never ticked an agreement: the belfry signs the ticks a guest gave when applying, so a
// just-accepted member isn't asked again).

struct WelcomeFlow: View {
    @EnvironmentObject var model: AppModel
    @State private var step = Step.hello
    @State private var ticked = Set<String>()
    @State private var error: String?
    @State private var loaded = false

    enum Step { case hello, charter }

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                switch step {
                case .hello: hello
                case .charter: charter
                }
            }
            .animation(.snappy, value: step)
        }
        .interactiveDismissDisabled()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            ticked = Set(model.charterRules.filter { $0.agreed[model.me] != nil }.map(\.id))
            if model.launch.screen == "welcomecharter" { step = .charter; ticked = Set(model.charterRules.prefix(4).map(\.id)) }
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
                Text("Then: \(rules.count == 1 ? "one short agreement" : "\(rules.count) short agreements") · the chat")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            Button { if rules.isEmpty { finish() } else { step = .charter } } label: { Text("Continue").frame(maxWidth: .infinity) }
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
                    TickAgreementRow(rule: r, on: on) { if on { ticked.remove(r.id) } else { ticked.insert(r.id) } }
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
                finish()
            } label: { Text(all ? "Continue" : "\(ticked.count) of \(rules.count) agreed").frame(maxWidth: .infinity) }
            .buttonStyle(.brand)
            .disabled(!all)
            .padding()
            .background(.bar)
        }
    }

    /// The charter is ticked: straight to the belfry's first channel, the composer ready. No
    /// name-and-photo step (board onboarding/welcome-profile, Xavier 2026-11-19: "don't get in
    /// the way… the sooner they get to the chat the better"); Edit profile stays behind the
    /// person's own face.
    private func finish() {
        model.welcomeDone()
        if model.launch.screen == nil {
            model.focusComposer = generalId
            model.joinedChannel = generalId
        }
    }
}
