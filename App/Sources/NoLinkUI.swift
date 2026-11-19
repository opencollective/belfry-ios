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
                Text("Find your community").font(.largeTitle.bold())
                Text("A belfry is your community’s own place. Type its address, or scan the QR code someone shows you.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Belfry address").font(.subheadline.weight(.semibold))
                TextField("belfry.sh", text: $address)
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
                    .accessibilityLabel("Belfry address")
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
                    ActionRow(icon: "qrcode.viewfinder", title: "Scan an invitation", detail: "The QR code someone shows you")
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
        // a member's address goes straight to the code; a belfry's address to its Welcome
        if MemberAddress.parse(typed) != nil {
            memberAddress = typed
            if let e = await model.requestCode(typed) {
                // an older belfry: its own screen offers the browser sign-in
                if e.failure == .unsupported { path.append(.login(nil)) } else { error = e.display }
            }
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
            Text("Channels, events and files for its members. No password: a 6-digit code by e-mail.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 10).padding(.bottom, 28)
            Button { path.append(.login(community)) } label: { Text("Log in").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.brand)
                .accessibilityIdentifier("welcome-login")
            Button { path.append(.apply(community)) } label: {
                Text("Apply to join").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .overlay(Capsule().strokeBorder(Color.primary, lineWidth: 1.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityIdentifier("welcome-apply")
            Button("I have an invite code") { path.append(.inviteCode(community)) }
                .font(.body.weight(.medium))
                .padding(.top, 22)
                .accessibilityIdentifier("welcome-code")
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
                TextField("https://chat.\(community.domain)/join/…", text: $text)
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
    @Binding var path: [NoLinkStep]
    @State private var email = ""
    @State private var why = ""
    @State private var rules: [Agreement]?
    @State private var ticked: Set<String> = []
    @State private var error: String?
    @State private var loadFailed = false

    private var api: BelfryAPI { BelfryAPI(config: community, signer: nil) }
    private var allTicked: Bool { rules.map { r in r.allSatisfy { ticked.contains($0.id) } } ?? false }
    private var filled: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Apply to join").font(.largeTitle.bold())
            field("Your e-mail") {
                TextField("you@example.org", text: $email)
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
            Button("I’m a member: log in") {
                // back to the Welcome, then on to Log in: back never pushes a second copy
                path = [.welcome(community), .login(community)]
            }
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
        }
        .task { if rules == nil { await load() } }
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
        if model.launch.signin != nil {
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
        guard let rules, model.launch.signin == nil else { return }
        hideKeyboard()
        error = nil
        guard filled else { error = ApplyForm.missing; return }
        do {
            try await api.applyToJoin(email: email, motivation: why, agreed: rules.map(\.id))
            // the form is done: back from "Thank you" goes to the Welcome
            path = [.welcome(community), .sent(community)]
        } catch { self.error = (error as? ApiError)?.message ?? ApplyForm.other }
    }
}

/// onboarding/apply-sent.
struct ApplySentScreen: View {
    let community: BelfryConfig
    @Binding var path: [NoLinkStep]

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
            Button { path = [.welcome(community)] } label: { Text("Done").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.top, 100)
        .navigationBarBackButtonHidden()
    }
}
