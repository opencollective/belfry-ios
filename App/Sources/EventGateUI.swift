import SwiftUI
import BelfryCore

/// An event link opened by someone signed out (boards events/members-only-join, -login; Xavier's
/// request to the web, for iPhone via the lead 2026-11-23). Only the domain and the link are kept.
struct PendingEvent: Equatable {
    let domain: String
    let link: String
    var code: String?
    /// nil: being checked.
    var answer: EventGate?
    /// The belfry's document, once the event is known to be for members (its name, its log-in).
    var community: BelfryConfig?
}

extension AppModel {
    private static let pendingEventKey = "belfry-pending-event"

    /// Signed out, an event link: what is it? Public: its web page in the browser. For members:
    /// the members screen. No such event: said, never the members screen.
    func openEventSignedOut(domain: String, link: String, code: String?) {
        pendingEvent = PendingEvent(domain: domain, link: link, code: code)
        Task { await checkPendingEvent() }
    }

    func checkPendingEvent() async {
        guard var p = pendingEvent else { return }
        p.answer = nil
        pendingEvent = p
        var answer = EventGate.membersOnly
        if launch.signin != "members" { answer = await EventGate.check(domain: p.domain, link: p.link) }
        guard pendingEvent?.link == p.link, pendingEvent?.domain == p.domain else { return }
        switch answer {
        case .open:
            pendingEvent = nil
            if let u = URL(string: "https://\(p.domain)/events/\(p.link)") { UIApplication.shared.open(u) }
        case .notFound:
            pendingEvent = nil
            showToast("This link doesn’t lead anywhere.")
        case .membersOnly:
            p.answer = .membersOnly
            if launch.signin == "members" { p.community = .shot } else {
                let fetched = try? await Discovery.fetch(domain: p.domain)
                p.community = fetched ?? .defaults(domain: p.domain)
            }
            pendingEvent = p
            // remembered through the log-in or the application: opened after the code
            UserDefaults.standard.set(["domain": p.domain, "link": p.link, "at": String(Int.now)], forKey: AppModel.pendingEventKey)
        case .cantCheck:
            p.answer = .cantCheck
            pendingEvent = p
        }
    }

    /// Signed in: the event a members-only link named opens (kept at most a week).
    func openRememberedEvent() {
        defer { pendingEvent = nil }
        guard phase == .ready, let m = UserDefaults.standard.dictionary(forKey: AppModel.pendingEventKey) as? [String: String],
              let domain = m["domain"], let link = m["link"] else { return }
        UserDefaults.standard.removeObject(forKey: AppModel.pendingEventKey)
        guard domain == config.domain, Int.now - (Int(m["at"] ?? "") ?? 0) < 7 * 86400 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openEvent = link }
    }
}

/// "This event is for members" (board events/members-only-join): the two ways in. Also the
/// moments before the answer and when it can't be checked.
struct MembersEventScreen: View {
    @EnvironmentObject var model: AppModel
    let pending: PendingEvent
    @Binding var path: [NoLinkStep]

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            switch pending.answer {
            case .membersOnly:
                let c = pending.community ?? .defaults(domain: pending.domain)
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
                    .frame(width: 64, height: 64).background(Color.secondary.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Text("This event is for members").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Members see the details, answer and join the conversation.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { path = [.login(c)] } label: { Text("I have an account: sign in").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.brand)
                    .padding(.top, 8)
                    .accessibilityIdentifier("members-event-signin")
                Button("Apply to join \(c.name.isEmpty ? pending.domain : c.name)") { path = [.apply(c)] }
                    .accessibilityIdentifier("members-event-apply")
            case .cantCheck:
                Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("This event can’t be checked right now").font(.title3.bold()).multilineTextAlignment(.center)
                BusyButton("Try again") { await model.checkPendingEvent() }.buttonStyle(.brand)
                Button("Not now") { model.pendingEvent = nil }
            default:
                ProgressView()
                Text("Opening the event…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .navigationTitle(pending.community?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}
