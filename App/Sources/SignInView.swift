import BelfryCore
import SwiftUI

// Signing in (SPEC 19.20): the member's address name@domain, then the 6-digit code the belfry
// mails, typed here. No browser. The belfry's own sign-in page in the system browser session
// (SPEC 2) stays as a second row, and is what an older belfry gets. The member's key stays on
// the belfry; this phone holds a session key.

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    /// A guest link's domain: the placeholder names it.
    var domainHint: String?
    /// "Add an account" (SPEC 19.24): over the app, with Cancel; the open account stays meanwhile.
    var onCancel: (() -> Void)? = nil
    /// The screens pushed from "Find your community" (kept while a code is typed).
    @State private var path: [NoLinkStep] = []

    /// No link and no account being added: the app asks which belfry first (onboarding/no-link-belfry).
    private var finds: Bool {
        onCancel == nil && domainHint == nil && model.launch.signin != "older"
    }

    var body: some View {
        NavigationStack(path: $path) {
            page {
                if let pending = model.pendingCode {
                    CodeScreen(pending: pending)
                } else if finds {
                    FindScreen(path: $path)
                } else {
                    AddressScreen(domainHint: domainHint, adding: onCancel != nil)
                }
            }
            .navigationDestination(for: NoLinkStep.self) { step in
                page(hideBack: { if case .sent = step { return true } else { return false } }()) {
                    // a code on its way shows over whatever was pushed
                    if let pending = model.pendingCode {
                        CodeScreen(pending: pending)
                    } else {
                        switch step {
                        case .welcome(let c): CommunityWelcome(community: c, path: $path)
                        case .login(let c): AddressScreen(domainHint: c?.domain, adding: true, community: c)
                        // replacing the path: back from "Thank you" or from Log in goes to the Welcome, never to a second copy
                        case .apply(let c): ApplyFormScreen(community: c, onSent: { path = [.welcome(c), .sent(c)] }, onLogIn: { path = [.welcome(c), .login(c)] })
                        case .sent(let c): ApplySentScreen { path = [.welcome(c)] }
                        case .inviteCode(let c): InviteCodeScreen(community: c)
                        }
                    }
                }
            }
            .onAppear { if path.isEmpty, let p = NoLinkStep.shot(model.launch.signin) { path = p } }
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                }
            }
        }
    }

    private func page<V: View>(hideBack: Bool = false, @ViewBuilder _ content: () -> V) -> some View {
        ScrollView {
            content()
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        // a code on its way: the code screen has its own way back
        .navigationBarBackButtonHidden(hideBack || model.pendingCode != nil)
    }
}

extension NoLinkStep {
    /// `-signin welcome|apply|sent|invitecode|login`: the pushed screens with a made-up belfry, for screenshots.
    static func shot(_ name: String?) -> [NoLinkStep]? {
        switch name {
        case "welcome": return [.welcome(.shot)]
        case "apply": return [.welcome(.shot), .apply(.shot)]
        case "sent": return [.welcome(.shot), .sent(.shot)]
        case "invitecode": return [.welcome(.shot), .inviteCode(.shot)]
        case "login": return [.welcome(.shot), .login(.shot)]
        default: return nil
        }
    }
}

/// Screen 1: one field, the address.
struct AddressScreen: View {
    @EnvironmentObject var model: AppModel
    var domainHint: String?
    var adding = false
    /// "Log in" from a belfry's Welcome: its name on top; a bare name gets its address.
    var community: BelfryConfig? = nil
    @AppStorage("last-address") private var address = ""
    @State private var auth = WebAuth()
    @State private var error: String?
    /// An older belfry (no session API): the main button opens the browser sign-in.
    @State private var offerBrowser = false
    @State private var scanning = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            BelfryMark()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(community.map { "Log in to \($0.name)" } ?? "Your community's chat")
                    .font(.largeTitle.bold())
                Text("Type your address in your community. A 6-digit code goes to your e-mail; no password.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Your address").font(.subheadline.weight(.semibold))
                TextField("name@" + (domainHint ?? "belfry.sh"), text: $address)
                    .font(.body)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focused)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(go)
                    .disabled(model.busy)
                    .accessibilityLabel("Your address")
                    .onChange(of: address) { _, _ in
                        if model.launch.signin == nil { offerBrowser = false }
                    }
            }
            if let note = model.signInNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if let e = error ?? model.signInError {
                Label(e, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            // locks on the tap (model.busy) and shows progress until the belfry answered
            Button(action: go) {
                HStack {
                    if model.busy { ProgressView().tint(Theme.onAccent) }
                    Text(offerBrowser ? "Sign in with the browser" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.brand)
            .disabled(model.busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Your key stays on the belfry; this phone only gets a session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                if !offerBrowser {
                    ActionButtonRow(icon: "globe", title: "Sign in with the browser instead", detail: "On your community's own sign-in page") {
                        await browser()
                    }
                    .disabled(model.busy)
                }
                Button { hideKeyboard(); scanning = true } label: {
                    ActionRow(icon: "qrcode.viewfinder", title: "Scan an invitation", detail: "The QR code someone shows you")
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                if !adding {
                    Button { model.startDemo() } label: {
                        ActionRow(icon: "person.2", title: "Try the demo", detail: "A made-up community. Everything in it stays on this device.")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                }
            }
        }
        .sheet(isPresented: $scanning) {
            InviteScanner { url in
                scanning = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.handle(url: url) }
            }
        }
        .onAppear {
            if model.launch.signin == "older" {
                address = "maya@riverside.example"
                offerBrowser = true
                error = SessionFailure.unsupported.message
            }
        }
    }

    private func go() {
        guard !model.busy else { return }
        focused = false
        error = nil
        model.signInError = nil
        if model.launch.signin != nil { return }
        model.busy = true
        Task { @MainActor in
            if offerBrowser {
                await browser()
            } else if let e = await model.requestCode(fullAddress) {
                if e.failure == .unsupported { offerBrowser = true }
                error = e.display
            }
            model.busy = false
        }
    }

    /// What was typed; on a belfry's own Log in a bare name is completed with its address.
    private var fullAddress: String {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = community, !t.isEmpty, !t.contains("@"), !t.contains(".") { return t + "@" + c.domain }
        return t
    }

    /// The belfry's own page (SPEC 2), at the domain of the address typed (or a bare domain).
    private func browser() async {
        error = nil
        model.signInError = nil
        let typed = fullAddress.lowercased()
        guard let domain = MemberAddress.parse(typed)?.domain ?? (Discovery.isDomain(typed) ? typed : nil) else {
            error = "Type your address first, like name@belfry.sh."
            return
        }
        focused = false
        await model.signIn(domain: domain, auth: auth)
    }
}

/// Screen 2: the six digits of the code.
private struct CodeScreen: View {
    @EnvironmentObject var model: AppModel
    let pending: PendingCode
    @State private var digits = ""
    @State private var verifying = false
    @State private var error: String?
    /// The last code was not right (the boxes say so until the next digit).
    @State private var wrong = false
    @State private var note: String?
    /// The digits are right as far as we know (no connection, too many tries): the same code again.
    @State private var canRetry = false
    /// "Send a new code" is locked for 30 s after each send.
    @State private var resendAt = Date().addingTimeInterval(30)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            BelfryMark()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the code").font(.largeTitle.bold())
                // the address is what the person typed (checked); `to` passed the mask check
                Text("We sent a 6-digit code to \(pending.to ?? "your e-mail address") to sign in as \(pending.address). It works for 10 minutes.")
                    .foregroundStyle(.secondary)
            }
            CodeBoxes(digits: $digits, enabled: !verifying, focused: $focused, bad: wrong) { Task { await submit() } }
            if verifying {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Signing you in…")
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            } else if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if canRetry && !verifying {
                BusyButton { await submit() } label: { Text("Try again").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.brand)
            }
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = max(0, Int(resendAt.timeIntervalSince(context.date).rounded(.up)))
                    ActionButtonRow(icon: "envelope", title: wait > 0 ? "Send a new code (in \(wait) s)" : "Send a new code") {
                        await resend()
                    }
                    .disabled(wait > 0 || verifying)
                    .opacity(wait > 0 ? 0.5 : 1)
                }
                Button { model.cancelCode() } label: { ActionRow(icon: "chevron.left", title: "Use another address") }
                    .buttonStyle(.plain)
                    .disabled(verifying)
            }
        }
        .onAppear {
            if model.launch.signin == "code" { digits = "427" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
        }
    }

    private func submit() async {
        guard !verifying, NativeSignIn.isCode(digits) else { return }
        if model.launch.signin != nil { return }
        verifying = true
        error = nil
        note = nil
        focused = false
        let e = await model.verifyCode(digits)
        verifying = false
        guard let e else { return }
        if e.failure.endsTheRequest { return } // the model went back to screen 1 with its message
        error = e.display
        switch e.failure {
        case .wrongCode:
            digits = ""
            wrong = true
            canRetry = false
            focused = true
        case .signer:
            // the code is spent and the belfry's signer was down: a new code, at once
            digits = ""
            canRetry = false
            resendAt = Date()
        default:
            canRetry = true
        }
    }

    private func resend() async {
        if model.launch.signin != nil { return }
        error = nil
        note = nil
        if let e = await model.resendCode() {
            if !e.failure.endsTheRequest { error = e.display }
            return
        }
        digits = ""
        canRetry = false
        note = "A new code is on its way."
        resendAt = Date().addingTimeInterval(30)
        focused = true
    }
}

/// Six boxes over one numeric field with no length limit: the field takes the typing, a paste
/// ("123 456", "Code: 123456", a new code over a full row: `NativeSignIn.next`) and the system's
/// code suggestion; the boxes show it. The sixth digit calls COMPLETE.
struct CodeBoxes: View {
    @Binding var digits: String
    let enabled: Bool
    var focused: FocusState<Bool>.Binding
    /// The code just typed was not right: the empty boxes are outlined in red (board onboarding/sign-in-code).
    var bad = false
    let complete: () -> Void
    /// What the boxes held after the last change (a seventh digit bounced back to the same six
    /// does not call COMPLETE again).
    @State private var accepted = ""

    var body: some View {
        let typed = Array(digits)
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    Text(i < typed.count ? String(typed[i]) : " ")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(bad && typed.isEmpty ? Color.red : focused.wrappedValue && enabled && i == min(typed.count, 5) ? Color.brand : Color.clear, lineWidth: 2)
                        )
                }
            }
            .accessibilityHidden(true)
            TextField("", text: $digits)
                .font(.body)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 54)
                .focused(focused)
                .disabled(!enabled)
                .accessibilityLabel("6-digit code")
                .onChange(of: digits) { _, new in
                    // a paste ("123 456", "Code: 123456") fills all six; a whole code pasted over a
                    // full row replaces it; one more digit typed into a full row changes nothing
                    let d = NativeSignIn.next(old: accepted, raw: new)
                    if d != new { digits = d; return } // comes back here with the digits alone
                    guard d != accepted else { return }
                    accepted = d
                    if d.count == 6 { complete() }
                }
                .onAppear { accepted = digits }
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { focused.wrappedValue = true } }
    }
}

/// The Arms mark, the same drawing as the belfry's pages (collective-belfry theme.py, viewBox
/// 64 × 70): a shield, a crenellated tower with its door, a line of water. The shield takes the
/// tint (the belfry's primary colour, else ink); the tower the secondary colour when it stands
/// out on the shield, else white or near-black.
struct BelfryMark: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / 64, size.height / 70)
            let ox = (size.width - 64 * k) / 2, oy = (size.height - 70 * k) / 2
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
            let shieldColor = Theme.accent
            let towerColor = BelfryMark.tower

            var shield = Path()
            shield.move(to: pt(8, 6))
            shield.addQuadCurve(to: pt(10, 4), control: pt(8, 4))
            shield.addLine(to: pt(54, 4))
            shield.addQuadCurve(to: pt(56, 6), control: pt(56, 4))
            shield.addLine(to: pt(56, 30))
            shield.addCurve(to: pt(32, 65), control1: pt(56, 47), control2: pt(45, 59))
            shield.addCurve(to: pt(8, 30), control1: pt(19, 59), control2: pt(8, 47))
            shield.closeSubpath()
            ctx.fill(shield, with: .color(shieldColor))

            let outline: [(Double, Double)] = [
                (22, 43), (22, 24), (20, 24), (20, 18), (24, 18), (24, 21), (27, 21), (27, 18),
                (31, 18), (31, 21), (33, 21), (33, 18), (37, 18), (37, 21), (40, 21), (40, 18),
                (44, 18), (44, 24), (42, 24), (42, 43),
            ]
            var tower = Path()
            tower.move(to: pt(outline[0].0, outline[0].1))
            for p in outline.dropFirst() { tower.addLine(to: pt(p.0, p.1)) }
            tower.closeSubpath()
            ctx.fill(tower, with: .color(towerColor))

            var door = Path()
            door.move(to: pt(29, 43))
            door.addLine(to: pt(29, 38))
            door.addArc(center: pt(32, 38), radius: 3 * k, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            door.addLine(to: pt(35, 43))
            door.closeSubpath()
            ctx.fill(door, with: .color(shieldColor))

            var water = Path()
            water.move(to: pt(16, 49))
            water.addQuadCurve(to: pt(24, 49), control: pt(20, 46.5))
            water.addQuadCurve(to: pt(32, 49), control: pt(28, 51.5))
            water.addQuadCurve(to: pt(40, 49), control: pt(36, 46.5))
            water.addQuadCurve(to: pt(48, 49), control: pt(44, 51.5))
            ctx.stroke(water, with: .color(towerColor), style: StrokeStyle(lineWidth: 2.2 * k, lineCap: .round))
        }
        .aspectRatio(64.0 / 70.0, contentMode: .fit)
    }

    /// The tower's colour: the secondary colour when its contrast with the primary is at least
    /// 2.2 (the pages' rule), else the text colour on the tint.
    private static var tower: Color {
        guard let b = Theme.branding, let p = Branding.rgb(b.primary), let s = Branding.rgb(b.secondary) else { return Theme.onAccent }
        let lp = luminance(p), ls = luminance(s)
        let ratio = (max(lp, ls) + 0.05) / (min(lp, ls) + 0.05)
        return ratio >= 2.2 ? Color(red: s.0, green: s.1, blue: s.2) : Theme.onAccent
    }

    private static func luminance(_ c: (Double, Double, Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }
}
