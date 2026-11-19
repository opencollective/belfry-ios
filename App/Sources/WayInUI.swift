import BelfryCore
import SwiftUI

// The way in, as the web's (SPEC 19.59; boards onboarding/login, login-unknown, apply-name,
// username-states, apply-email, apply-code, apply-pending-name, apply-declined): one pushed screen
// whose content is the step. Log in: e-mail → code → the chat. Apply: name, username, why, the
// charter → e-mail → code → "Your request is pending", which opens the chat by itself once a
// steward says yes. An address proven while logging in is not asked a second code to apply.

enum WayInStart: Hashable { case login, apply, pending }

struct WayInFlow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase
    let community: BelfryConfig
    let start: WayInStart
    /// Back to the belfry's start screen.
    let leave: () -> Void
    /// This belfry doesn't have these calls: the older screens.
    let older: (WayInStart) -> Void

    enum Step: Equatable { case email, code, unknown, form, pending, declined }
    @State private var step = Step.email
    /// The e-mail and code steps are those of applying (after the form), not of logging in.
    @State private var applying = false
    @State private var email = ""
    @State private var digits = ""
    @State private var name = ""
    @State private var username = ""
    /// The username was typed by hand: the name no longer fills it.
    @State private var usernameTouched = false
    @State private var check: UsernameCheck?
    @State private var checking = false
    @State private var why = ""
    @State private var rules: [Agreement]?
    @State private var ticked: Set<String> = []
    @State private var proof: String?
    @State private var waiting = WayInAnswer.Pending()
    @State private var error: String?
    @State private var busy = false
    @State private var resendAt = Date()
    @State private var loaded = false
    @FocusState private var codeFocused: Bool

    private var shot: Bool { model.launch.signin != nil }
    private var mail: String { email.jsTrim().lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .email: emailStep
            case .code: codeStep
            case .unknown: unknownStep
            case .form: formStep
            case .pending: pendingStep
            case .declined: declinedStep
            }
        }
        .animation(.snappy(duration: 0.2), value: step)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            switch start {
            case .login: step = .email
            case .apply: step = .form
            case .pending: step = .pending
            }
            if shot { fillShot() }
            if start == .login, let p = model.wayInPrefill {
                model.wayInPrefill = nil
                email = p
                Task { await sendCode() }
            }
        }
        // "Your request is pending": asked every 5 s while it is on screen, and when the app comes back
        .task(id: step == .pending) {
            guard step == .pending, !shot else { return }
            while !Task.isCancelled, step == .pending {
                await askStatus()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: phase) { _, p in if p == .active, step == .pending, !shot { Task { await askStatus() } } }
    }

    // ---- e-mail -----------------------------------------------------------------------------

    private var emailStep: some View {
        SwiftUI.Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(applying ? "Your e-mail" : "Log in").font(.largeTitle.bold())
                Text(applying ? "We send a 6-digit code to check it’s yours. The stewards’ answer comes here too."
                     : "We send a 6-digit code to your e-mail. No password.")
                    .foregroundStyle(.secondary)
            }
            field("Your e-mail") {
                TextField(text: $email, prompt: Text(verbatim: applying ? "you@example.org" : "you@example.org or name@\(community.domain)")) { Text("Your e-mail") }
                    .font(.body)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { Task { await sendCode() } }
                    .accessibilityLabel("Your e-mail")
                    .accessibilityIdentifier("wayin-email")
                    .onChange(of: email) { _, v in error = nil; if v.count > 200 { email = String(v.prefix(200)) } }
            }
            errorLine
            BusyButton { await sendCode() } label: { Text("Send me a code").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.brand)
                .disabled(!GuestJoinForm.looksLikeEmail(email) || busy)
                .accessibilityIdentifier("wayin-send")
            if applying {
                Button("Back to the form") { error = nil; step = .form }.font(.body.weight(.medium))
            }
        }
    }

    @MainActor private func sendCode() async {
        guard GuestJoinForm.looksLikeEmail(email), !busy, !shot else { return }
        hideKeyboard()
        busy = true
        defer { busy = false }
        error = nil
        let a = applying
            ? await model.wayIn(.applyStart, community, WayIn.applyBody(email: mail, motivation: why, name: name, username: username,
                                                                         agreed: (rules ?? []).map(\.id), proof: nil))
            : await model.wayIn(.loginStart, community, WayIn.loginBody(email: mail))
        take(a)
        if a.screen == .code { resendAt = Date().addingTimeInterval(30) }
    }

    // ---- the code -----------------------------------------------------------------------------

    private var codeStep: some View {
        SwiftUI.Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Check your e-mail").font(.largeTitle.bold())
                Text("We sent a 6-digit code to \(mail). It can take a minute.").foregroundStyle(.secondary)
            }
            CodeBoxes(digits: $digits, enabled: !busy, focused: $codeFocused, bad: error != nil && digits.isEmpty) { Task { await verify() } }
            if busy { HStack(spacing: 10) { ProgressView(); Text(applying ? "Sending your request…" : "Logging you in…") } }
            errorLine
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = max(0, Int(resendAt.timeIntervalSince(context.date).rounded(.up)))
                    ActionButtonRow(icon: "envelope", title: wait > 0 ? "Send a new code (in \(wait) s)" : "Send a new code") {
                        digits = ""
                        await sendCode()
                    }
                    .disabled(wait > 0 || busy)
                    .opacity(wait > 0 ? 0.5 : 1)
                }
                Button { error = nil; digits = ""; step = .email } label: { ActionRow(icon: "chevron.left", title: "Use another address") }
                    .buttonStyle(.plain)
                    .disabled(busy)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { codeFocused = true } }
    }

    @MainActor private func verify() async {
        guard !busy, NativeSignIn.isCode(digits), !shot else { return }
        busy = true
        defer { busy = false }
        error = nil
        codeFocused = false
        let a = await model.wayIn(applying ? .applyVerify : .loginVerify, community, WayIn.codeBody(email: mail, code: digits))
        if a.clearsCode { digits = ""; codeFocused = true }
        take(a)
    }

    // ---- no account here yet ------------------------------------------------------------------

    private var unknownStep: some View {
        SwiftUI.Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("No account here yet").font(.largeTitle.bold())
                Text("\(mail) is confirmed, but it isn’t a member of \(community.name).").foregroundStyle(.secondary)
            }
            Button { applying = true; error = nil; step = .form } label: { Text("Apply to join").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.brand)
                .accessibilityIdentifier("wayin-apply")
            Button("Use another address") { proof = nil; digits = ""; error = nil; applying = false; step = .email }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
        }
    }

    // ---- the form: a name, a username, why, the charter ----------------------------------------

    private var allTicked: Bool { rules.map { r in r.allSatisfy { ticked.contains($0.id) } } ?? false }
    private var formFilled: Bool {
        !GuestJoinForm.cleanName(name).isEmpty && !why.jsTrim().isEmpty && (username.jsTrim().isEmpty || check?.state == .available || check == nil)
    }

    private var formStep: some View {
        SwiftUI.Group {
            Text("Apply to join \(community.name)").font(.largeTitle.bold())
            field("Your name") {
                TextField("First and last name", text: $name)
                    .font(.body)
                    .textContentType(.name)
                    .accessibilityLabel("Your name")
                    .accessibilityIdentifier("wayin-name")
                    .onChange(of: name) { _, v in error = nil; if v.count > 100 { name = String(v.prefix(100)) } }
            }
            UsernameField(community: community, name: name, username: $username, touched: $usernameTouched, check: $check, checking: $checking)
            field("Why would you like to join?") {
                TextField("A few words", text: $why, axis: .vertical)
                    .font(.body)
                    .lineLimit(3...8)
                    .accessibilityLabel("Why would you like to join?")
                    .accessibilityIdentifier("wayin-why")
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
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5))
                    }
                } else {
                    HStack(spacing: 10) { ProgressView(); Text("Loading the charter…").foregroundStyle(.secondary) }
                }
            }
            errorLine
            BusyButton { await submitForm() } label: {
                Text(rules.map { r in allTicked ? "Continue" : "Tick each agreement (\(r.filter { ticked.contains($0.id) }.count) of \(r.count))" } ?? "Continue")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.brand)
            .disabled(!allTicked || !formFilled || busy)
            .accessibilityIdentifier("wayin-continue")
            HStack(spacing: 4) {
                Text("I’m already a member ·").foregroundStyle(.secondary)
                Button("Log in") { applying = false; proof = nil; error = nil; step = .email }.font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
        }
        .task { if rules == nil, !shot { await loadCharter() } }
    }

    @MainActor private func loadCharter() async {
        if let list = try? await BelfryAPI(config: community, signer: nil).publicCharter() {
            rules = list.map(\.agreement).sorted { a, b in a.order != b.order ? a.order < b.order : a.addedAt < b.addedAt }
        } else {
            rules = nil
            error = ApplyForm.network
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if rules == nil, step == .form { await loadCharter() }
        }
    }

    /// The form is filled: with an address proven just before, the request goes at once; else the e-mail.
    @MainActor private func submitForm() async {
        guard allTicked, formFilled, !shot else { return }
        hideKeyboard()
        error = nil
        applying = true
        guard let proof else { step = .email; return }
        busy = true
        defer { busy = false }
        let a = await model.wayIn(.applyStart, community, WayIn.applyBody(email: mail, motivation: why, name: name, username: username,
                                                                           agreed: (rules ?? []).map(\.id), proof: proof))
        if a.screen == .withoutProof {
            // the proof is too old: a code, as for anyone
            self.proof = nil
            await sendCode()
            return
        }
        take(a)
    }

    // ---- pending, declined ---------------------------------------------------------------------

    private var pendingStep: some View {
        SwiftUI.Group {
            Text("Your request is pending").font(.largeTitle.bold())
            let shown = waiting.name.isEmpty ? GuestJoinForm.cleanName(name) : waiting.name
            let user = waiting.username.isEmpty ? username.jsTrim().lowercased() : waiting.username
            let address = waiting.email.isEmpty ? mail : waiting.email
            HStack(spacing: 12) {
                Text(String((shown.isEmpty ? "?" : shown).prefix(1)).uppercased())
                    .font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(Color.secondary, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if !shown.isEmpty { Text(shown).font(.headline) }
                    if !user.isEmpty { Text("@" + user).foregroundStyle(.secondary) }
                    if !address.isEmpty { Text(address).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            let message = waiting.motivation.isEmpty ? why.jsTrim() : waiting.motivation
            if !message.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your message").font(.subheadline.weight(.semibold))
                    Text(verbatim: message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Text("Once approved, you will be logged in to \(community.name) on this phone. To log in on another device, just enter your e-mail\(address.isEmpty ? "" : " " + address) there to receive a new 6-digit code.")
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("wayin-pending")
            errorLine
        }
    }

    @MainActor private func askStatus() async {
        let a = await model.wayIn(.applyStatus, community, [:])
        switch a.screen {
        case .pending: if let p = a.pending { waiting = p }; error = nil
        case .stay: break // no connection just now: asked again in 5 s
        case .older: break
        default: take(a)
        }
    }

    private var declinedStep: some View {
        SwiftUI.Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Not this time").font(.largeTitle.bold())
                Text("The stewards of \(community.name) didn’t accept your request.").foregroundStyle(.secondary)
            }
            Button { model.wayInPending(nil); applying = true; proof = nil; error = nil; step = .form } label: {
                Text("Ask again").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            Button("Back to \(community.name)") { model.wayInPending(nil); leave() }.font(.body.weight(.medium)).frame(maxWidth: .infinity)
        }
    }

    // ---- an answer → the next screen -----------------------------------------------------------

    @MainActor private func take(_ a: WayInAnswer) {
        switch a.screen {
        case .code: digits = ""; step = .code
        case .signedIn:
            if let s = a.session { model.wayInSignedIn(s, community, said: mail) } else { error = WayIn.words["other"] }
        case .pending:
            if let p = a.pending { waiting = p }
            model.wayInPending(community)
            step = .pending
        case .unknown: proof = a.proof; step = .unknown
        case .declined: model.wayInPending(nil); step = .declined
        case .start:
            // a state we don't know keeps the request's mark: asked again on the next open
            if !a.asksAgain { model.wayInPending(nil) }
            leave()
        case .logIn:
            // approved, the session went to another device: log in with the address, filled in
            model.wayInPending(nil)
            if let n = a.nip05 { email = n }
            applying = false; proof = nil; digits = ""; step = .email
        case .signInInstead:
            // the account holds its own key: the older sign-in knows how
            if let n = a.nip05 { UserDefaults.standard.set(n, forKey: "last-address") }
            older(.login)
        case .withoutProof: proof = nil; applying = true; step = .email
        case .stay:
            error = a.message
            // a taken username while sending: back to the form, with what to try
            if !a.suggestions.isEmpty || a.message == WayIn.words["username_invalid"] || a.message == WayIn.words["username_reserved"] {
                check = UsernameCheck(username: username.jsTrim().lowercased(), state: a.suggestions.isEmpty ? .invalid : .taken,
                                      reason: a.message == WayIn.words["username_reserved"] ? "reserved" : nil, suggestions: a.suggestions)
                step = .form
            }
        case .older: older(start == .pending ? .login : (applying || start == .apply ? .apply : .login))
        }
    }

    // ---- parts ---------------------------------------------------------------------------------

    @ViewBuilder private var errorLine: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                .accessibilityIdentifier("wayin-error")
        }
    }

    private func field<F: View>(_ label: String, @ViewBuilder _ content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold))
            content()
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Screenshots (`-signin wayin-…`): made-up values, nothing sent.
    private func fillShot() {
        email = "lina.moreau@example.org"
        name = "Lina Moreau"
        username = "lina"
        check = UsernameCheck(username: "lina", state: .available, reason: nil, suggestions: [])
        why = "I run a repair café in Ghent and want to help with the workshops."
        let demo = [("We look after each other", "Kind words and good faith, also when we disagree."),
                    ("What's said here stays here", "Ask before sharing a message, a photo or a name outside the belfry."),
                    ("Shared things come back", "Return tools within a week, clean and working.")]
        let list = PublicAgreement.parseList(["agreements": demo.enumerated().map { i, r in
            ["id": String(repeating: String(i + 1), count: 64), "title": r.0, "about": r.1, "order": i] as [String: Any]
        }])
        rules = list.map(\.agreement)
        ticked = Set(list.prefix(2).map(\.id))
        waiting = WayInAnswer.Pending(name: name, username: username, email: email, motivation: why)
        switch model.launch.signin {
        case "wayin-code": digits = "427"; step = .code
        case "wayin-unknown": step = .unknown
        case "wayin-declined": step = .declined
        default: break
        }
    }
}

/// "Pick a username:" (board onboarding/username-states): filled from the first name until it is
/// typed by hand, checked with the belfry as it changes: available / Checking… / "Taken. Try …" /
/// the rule. The address it makes is said under it.
struct UsernameField: View {
    @EnvironmentObject var model: AppModel
    let community: BelfryConfig
    let name: String
    @Binding var username: String
    @Binding var touched: Bool
    @Binding var check: UsernameCheck?
    @Binding var checking: Bool
    /// A new member picks theirs: the call is signed by their own key.
    var mine = false

    private var typed: String { username.jsTrim().lowercased() }
    private var shot: Bool { model.launch.signin != nil || model.launch.screen != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a username:").font(.subheadline.weight(.semibold))
            HStack(spacing: 4) {
                TextField("username", text: Binding(get: { username }, set: { v in
                    if v != username { touched = true }
                    username = String(v.prefix(30))
                }))
                .font(.body)
                .textContentType(.username)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Username")
                .accessibilityIdentifier("wayin-username")
                Text("@" + community.domain).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            if !typed.isEmpty {
                if checking {
                    Text("Checking…").font(.footnote).foregroundStyle(.secondary)
                } else if let check, check.username == typed {
                    HStack(spacing: 6) {
                        Text(check.line(domain: community.domain)).font(.footnote)
                            .foregroundStyle(check.state == .available ? Color.green : Color.red)

                    }
                    .accessibilityIdentifier("wayin-username-line")
                    // up to three suggestions, in the belfry's order, each one tap
                    if check.state != .available, !check.suggestions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(check.suggestions, id: \.self) { s in
                                Button(s) { username = s; touched = true }
                                    .font(.footnote.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Text("This is your address here: \(typed)@\(community.domain). You log in with it, people mention you as @\(typed), and it receives your direct messages and e-mails.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        // the name fills it until it is typed by hand
        .task(id: name) {
            guard !touched, !shot, !GuestJoinForm.cleanName(name).isEmpty else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled || touched { return }
            if let s = UsernameCheck.suggested(await model.usernameCheck(community, ["name": GuestJoinForm.cleanName(name)], mine: mine)), !touched {
                username = s
            }
        }
        .task(id: typed) {
            guard !typed.isEmpty, !shot else { return }
            if check?.username == typed { return }
            checking = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            var body: [String: Any] = ["username": typed]
            let n = GuestJoinForm.cleanName(name)
            if !n.isEmpty { body["name"] = n }
            let got = UsernameCheck.parse(await model.usernameCheck(community, body, mine: mine))
            if Task.isCancelled { return }
            // the belfry lower-cases and trims: the line is for what is typed
            if let got { check = UsernameCheck(username: typed, state: got.state, reason: got.reason, suggestions: got.suggestions) } else { check = nil }
            checking = false
        }
    }
}

/// After a member invitation's code (board onboarding/member-link-name): "Welcome to <belfry>.
/// <e-mail> is confirmed. One last thing: how people will know you here." A name and a username,
/// then the chat (`POST /welcome`, by the new member's own key).
struct WelcomeNameScreen: View {
    @EnvironmentObject var model: AppModel
    let email: String
    @State private var name = ""
    @State private var username = ""
    @State private var touched = false
    @State private var check: UsernameCheck?
    @State private var checking = false
    @State private var error: String?

    private var ready: Bool {
        !GuestJoinForm.cleanName(name).isEmpty && !username.jsTrim().isEmpty && !checking && (check == nil || check?.state == .available)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BelfryMark().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to \(model.config.name)").font(.largeTitle.bold())
                    Text("\(email.isEmpty ? "Your e-mail" : email) is confirmed. One last thing: how people will know you here.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your name").font(.subheadline.weight(.semibold))
                    TextField("First and last name", text: $name)
                        .font(.body)
                        .textContentType(.name)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Your name")
                        .onChange(of: name) { _, v in error = nil; if v.count > 100 { name = String(v.prefix(100)) } }
                }
                UsernameField(community: model.config, name: name, username: $username, touched: $touched, check: $check, checking: $checking, mine: true)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
                BusyButton {
                    hideKeyboard()
                    error = nil
                    let a = await model.setNameAndUsername(name: name, username: username)
                    switch a.screen {
                    case .signedIn, .older: model.nameAsked = nil
                    default:
                        // set already (another device did it): nothing more to ask
                        if a.message == WayIn.words["already_set"] { model.nameAsked = nil; return }
                        error = a.message
                        if !a.suggestions.isEmpty { check = UsernameCheck(username: username.jsTrim().lowercased(), state: .taken, suggestions: a.suggestions) }
                    }
                } label: { Text("Go to the chat").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.brand)
                    .disabled(!ready)
                    .accessibilityIdentifier("welcome-name-go")
                Button("Not now") { model.nameAsked = nil }.font(.body.weight(.medium)).frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled()
        .onAppear {
            if name.isEmpty {
                let n = model.realName(model.me)
                // the name starts from the address: only a real one is kept
                name = n.contains("@") || n.isEmpty ? "" : n
            }
        }
    }
}

/// The e-mail whose member invitation was just confirmed (the name step is asked once).
struct NameAsked: Identifiable, Equatable {
    let email: String
    var id: String { email }
}
