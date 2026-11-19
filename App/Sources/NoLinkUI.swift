import BelfryCore
import SwiftUI

// Signed out with no link (boards onboarding/no-link-belfry, no-link, apply-form, apply-sent): the
// app asks for a belfry's address (a `name@address` goes straight to the code), then shows that
// belfry's Welcome: Log in · Apply to join · I have an invite code. Applying sends `POST /apply`
// (no account; the answer comes by e-mail). Every step is a pushed screen; back never pushes.

/// The screens pushed from "Find your community".
enum NoLinkStep: Hashable {
    case welcome(BelfryConfig)
    case login(BelfryConfig?)
    case apply(BelfryConfig)
    case sent(BelfryConfig)
    case inviteCode(BelfryConfig)
    /// Log in, Apply to join or the pending screen, the web's way (SPEC 19.59).
    case wayIn(BelfryConfig, WayInStart)
}

extension BelfryConfig {
    /// A made-up belfry for the screenshots of the signed-out screens.
    static var shot: BelfryConfig {
        var c = BelfryConfig.defaults(domain: "riverside.example")
        c.name = "Riverside Commons"
        return c
    }
}

/// onboarding/no-link-belfry: the belfry's address (or name@address), Scan an invitation, Try the demo.
struct FindScreen: View {
    @EnvironmentObject var model: AppModel
    @Binding var path: [NoLinkStep]
    @AppStorage("last-belfry") private var address = ""
    @AppStorage("last-address") private var memberAddress = ""
    @State private var error: String?
    @State private var scanning = false
    @FocusState private var focused: Bool

    private var typed: String { address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            BelfryMark().frame(width: 64, height: 64).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to your community").font(.largeTitle.bold())
                Text("Enter your community e-mail or your community’s address to get started.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("E-mail or domain").font(.subheadline.weight(.semibold))
                TextField("name@belfry.sh or belfry.sh", text: $address)
                    .font(.body)
                    .textContentType(.URL)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focused)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit { Task { await go() } }
                    .disabled(model.busy)
                    .accessibilityLabel("E-mail or domain")
                    .accessibilityIdentifier("find-address")
            }
            if let note = model.signInNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            if let e = error ?? model.signInError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            // locks on the tap (model.busy) and shows progress until the belfry answered
            Button { Task { await go() } } label: {
                HStack {
                    if model.busy { ProgressView().tint(Theme.onAccent) }
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.brand)
            .disabled(model.busy || typed.isEmpty)
            .accessibilityIdentifier("find-continue")
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Button { hideKeyboard(); scanning = true } label: {
                    ActionRow(icon: "qrcode.viewfinder", title: "Scan a QR code", detail: "An invitation, or the code your community’s chat shows to link a phone")
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                Button { model.startDemo() } label: {
                    ActionRow(icon: "person.2", title: "Try the demo", detail: "A made-up community, kept on this device")
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
            Text("Got an invitation link? Open it on this phone.").font(.footnote).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $scanning) {
            InviteScanner { url in
                scanning = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.handle(url: url) }
            }
        }
    }

    @MainActor private func go() async {
        guard !model.busy, !typed.isEmpty else { return }
        focused = false
        error = nil
        model.signInError = nil
        if model.launch.signin != nil { return }
        model.busy = true
        defer { model.busy = false }
        // an e-mail: its belfry's Log in, the code asked at once (an older belfry falls back to the
        // native sign-in from there); a belfry's address: its start screen
        if let a = MemberAddress.parse(typed) {
            memberAddress = typed
            guard let c = try? await Discovery.fetch(domain: a.domain) else {
                error = "No belfry answered at \(a.domain). Type your community’s address (like belfry.sh), or your address there."
                return
            }
            model.wayInPrefill = typed
            path = [.welcome(c), .wayIn(c, .login)]
            return
        }
        let domain = NoLink.domain(typed)
        guard Discovery.isDomain(domain), let c = try? await Discovery.fetch(domain: domain) else {
            error = NoLink.notFound
            return
        }
        path.append(.welcome(c))
    }
}

/// onboarding/no-link: the belfry's Welcome.
struct CommunityWelcome: View {
    let community: BelfryConfig
    @Binding var path: [NoLinkStep]

    var body: some View {
        VStack(spacing: 0) {
            BelfryMark().frame(width: 64, height: 74).accessibilityHidden(true)
            Text(community.name).font(.title.bold()).multilineTextAlignment(.center)
                .padding(.top, 20)
                .accessibilityIdentifier("welcome-name")
            // the belfry's own words about itself, else what a belfry is (board onboarding/start)
            Text((community.branding?.description).flatMap { $0.isEmpty ? nil : $0 } ?? "Channels, events and files for its members. No password: a 6-digit code by e-mail.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 10).padding(.bottom, 28)
            Button { path.append(.wayIn(community, .login)) } label: { Text("Log in").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.brand)
                .accessibilityIdentifier("welcome-login")
            Button("Apply to join") { path.append(.wayIn(community, .apply)) }
                .font(.body.weight(.medium))
                .padding(.top, 20)
                .accessibilityIdentifier("welcome-apply")
        }
        .padding(.top, 60)
    }
}

/// "I have an invite code": the invitation's link or its code, or scan it.
struct InviteCodeScreen: View {
    @EnvironmentObject var model: AppModel
    let community: BelfryConfig
    @State private var text = ""
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your invitation").font(.largeTitle.bold())
                Text("Paste the link you received, or type its code.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Invitation link or code").font(.subheadline.weight(.semibold))
                TextField(text: $text, prompt: Text(verbatim: "https://chat.\(community.domain)/join/…")) { Text("Invitation link or code") }
                    .font(.body)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Invitation link or code")
                    .onChange(of: text) { _, v in error = nil; if v.count > 400 { text = String(v.prefix(400)) } }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            BusyButton {
                guard let url = NoLink.invite(text, domain: community.domain) else { error = NoLink.notAnInvite; return }
                hideKeyboard()
                model.handle(url: url)
            } label: { Text("Open the invitation").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.brand)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Button { hideKeyboard(); scanning = true } label: { ActionRow(icon: "qrcode.viewfinder", title: "Scan its QR code") }
                .buttonStyle(.plain)
        }
        .sheet(isPresented: $scanning) {
            InviteScanner { url in
                scanning = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.handle(url: url) }
            }
        }
    }
}

/// onboarding/apply-form: e-mail, why, the charter in round ticks; the button counts the ticks until all are.
struct ApplyFormScreen: View {
    @EnvironmentObject var model: AppModel
    let community: BelfryConfig
    /// The request went through.
    let onSent: () -> Void
    /// "I'm a member: log in".
    let onLogIn: () -> Void
    /// Logged in already, not a member yet ("Almost in"): its own heading and line, the e-mail
    /// the belfry knows for this account filled in and locked, no "log in" under the form.
    var heading = "Apply to join"
    var intro: String? = nil
    var knownEmail: String? = nil
    var offersLogin = true
    @State private var email = ""
    @State private var why = ""
    @State private var rules: [Agreement]?
    @State private var ticked: Set<String> = []
    @State private var error: String?
    @State private var loadFailed = false

    private var api: BelfryAPI { BelfryAPI(config: community, signer: nil) }
    /// A screenshot run: made-up agreements, nothing sent.
    private var shot: Bool { model.launch.signin != nil || model.launch.screen != nil }
    private var allTicked: Bool { rules.map { r in r.allSatisfy { ticked.contains($0.id) } } ?? false }
    private var filled: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(heading).font(.largeTitle.bold())
                if let intro { Text(intro).foregroundStyle(.secondary) }
            }
            field("Your e-mail") {
                TextField("you@example.org", text: $email)
                    .disabled(knownEmail != nil)
                    .foregroundStyle(knownEmail != nil ? Color.secondary : Color.primary)
                    .font(.body)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Your e-mail")
                    .accessibilityIdentifier("apply-email")
                    .onChange(of: email) { _, v in error = nil; if v.count > 200 { email = String(v.prefix(200)) } }
            }
            field("Why would you like to join?") {
                TextField("A few words", text: $why, axis: .vertical)
                    .font(.body)
                    .lineLimit(3...8)
                    .accessibilityLabel("Why would you like to join?")
                    .accessibilityIdentifier("apply-why")
                    .onChange(of: why) { _, v in error = nil; if v.count > 4000 { why = String(v.prefix(4000)) } }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Our charter: tick each agreement").font(.subheadline.weight(.semibold))
                if let rules {
                    if rules.isEmpty {
                        Text("This belfry has no charter yet.").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rules.enumerated()), id: \.element.id) { i, r in
                                if i > 0 { Divider().padding(.leading, 40) }
                                TickAgreementRow(rule: r, on: ticked.contains(r.id)) {
                                    if ticked.contains(r.id) { ticked.remove(r.id) } else { ticked.insert(r.id) }
                                }
                                .padding(.vertical, 10)
                                .accessibilityIdentifier("apply-tick-\(i)")
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5))
                    }
                } else if loadFailed {
                    BusyButton { await load() } label: { Text("Try again") }.buttonStyle(.bordered)
                } else {
                    HStack(spacing: 10) { ProgressView(); Text("Loading the charter…").foregroundStyle(.secondary) }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("apply-error")
            }
            BusyButton { await send() } label: {
                Text(rules == nil ? "Send my request" : ApplyForm.button(ticked: rules!.filter { ticked.contains($0.id) }.count, of: rules!.count))
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.brand)
            .disabled(!allTicked || !filled)
            .accessibilityIdentifier("apply-send")
            if offersLogin {
                Button("I’m a member: log in", action: onLogIn)
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
        }
        .task { if rules == nil { await load() } }
        .onChange(of: knownEmail, initial: true) { _, e in if let e, !e.isEmpty { email = e } }
    }

    private func field<F: View>(_ label: String, @ViewBuilder _ content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold))
            content()
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @MainActor private func load() async {
        if shot {
            // a screenshot: the board's three agreements, two ticked
            let demo = [("We look after each other", "Kind words and good faith, also when we disagree. Speak up when someone isn't treated well, and help them first."),
                        ("What's said here stays here", "Ask before sharing a message, a photo or a name outside the belfry. Public channels are the exception: they say so at the top."),
                        ("Shared things come back", "Return tools within a week, clean and working. Broken? Say so in #Tool library so someone can fix it.")]
            let list = PublicAgreement.parseList(["agreements": demo.enumerated().map { i, r in
                ["id": String(repeating: String(i + 1), count: 64), "title": r.0, "about": r.1, "order": i] as [String: Any]
            }])
            rules = list.map(\.agreement)
            ticked = Set(list.prefix(2).map(\.id))
            email = "lina@example.org"
            why = "I live on Mill Street and would love to help in the garden on Sundays."
            return
        }
        loadFailed = false
        error = nil
        do {
            rules = try await api.publicCharter().map(\.agreement)
                .sorted { a, b in a.order != b.order ? a.order < b.order : a.addedAt < b.addedAt }
        } catch {
            loadFailed = true
            self.error = (error as? ApiError).flatMap { $0.code == "network" ? nil : $0.message } ?? ApplyForm.network
        }
    }

    @MainActor private func send() async {
        guard let rules, !shot else { return }
        hideKeyboard()
        error = nil
        guard filled else { error = ApplyForm.missing; return }
        do {
            try await api.applyToJoin(email: email, motivation: why, agreed: rules.map(\.id))
            onSent()
        } catch { self.error = (error as? ApiError)?.message ?? ApplyForm.other }
    }
}

/// onboarding/apply-sent.
struct ApplySentScreen: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark").font(.title.weight(.semibold)).foregroundStyle(Theme.onAccent)
                .frame(width: 64, height: 64)
                .background(Theme.accent, in: Circle())
                .accessibilityHidden(true)
            Text("Thank you").font(.title.bold()).padding(.top, 20)
                .accessibilityIdentifier("apply-sent")
            Text("Your request is in. You get a confirmation by e-mail now, and the answer by e-mail too.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 10).padding(.bottom, 28)
            Button(action: onDone) { Text("Done").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.top, 100)
    }
}

/// Signed in, but the belfry's relay doesn't let this key in (not a member yet): "Almost in" with
/// the Apply form, the e-mail the belfry knows filled in and locked; then Thank you (board
/// onboarding/no-link, its last line; Android's NoAccessScreen).
struct AlmostInScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var known: String?
    @State private var sent = false

    var body: some View {
        ScrollView {
            SwiftUI.Group {
                if sent {
                    VStack(spacing: 0) {
                        Text("Thank you").font(.title.bold()).accessibilityIdentifier("apply-sent")
                        Text("Your request is in. You get a confirmation by e-mail now, and the answer by e-mail too.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.top, 10).padding(.bottom, 28)
                        check
                    }
                    .padding(.top, 80)
                } else {
                    ApplyFormScreen(community: model.config, onSent: { sent = true }, onLogIn: {},
                                    heading: "Almost in",
                                    intro: "You’re logged in" + (known.map { " as \($0)" } ?? "") + ", but you’re not a member of \(model.config.name) yet. Apply to join: the answer comes by e-mail.",
                                    knownEmail: known, offersLogin: false)
                    check.padding(.top, 12)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // the address the belfry mails this account at
            if known == nil, !model.isDemo, let e = try? await model.api.follows().email.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty { known = e }
        }
    }

    private var check: some View {
        BusyButton { model.wake(); try? await Task.sleep(nanoseconds: 1_500_000_000) } label: {
            Text("I’ve been let in: check again").frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("noaccess-check")
    }
}
