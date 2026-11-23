import BelfryCore
import SwiftUI

@main
struct BelfryApp: App {
    @StateObject private var model = AppModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // offline first: what was fetched once stays on the phone (images also in ImageCache)
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            SwiftUI.Group {
                if let o = model.opening {
                    // a guest link: one loading screen until its channel can be drawn (SPEC 19.26)
                    OpeningScreen(opening: o)
                } else if model.phase == .signedOut, let mi = model.memberInvite {
                    // a member link, not used yet: sign up or log in, no channel behind it (SPEC 19.43)
                    MemberInviteScreen(invite: mi)
                } else {
                    switch model.phase {
                    case .signedOut:
                        // a code is on its way: that screen first, a guest link waits behind it
                        if model.pendingCode == nil, !model.inviteSignInFirst, let invite = model.pendingInvite {
                            if let p = model.inviteProblem { InviteProblemScreen(problem: p) }
                            else { OpeningScreen(opening: Opening()).onAppear { model.openInvite(invite) } }
                        } else {
                            SignInView(domainHint: model.signInDomainHint ?? model.pendingInvite?.domain)
                        }
                    case .ready:
                        if model.guestReading, model.sessionMemberLink != nil { MemberInviteScreen() } else { RootView() }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let t = model.toast {
                    Text(t).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("toast")
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.snappy, value: model.toast)
            .environmentObject(model)
            .tint(Theme.accent)
            .onOpenURL { model.handle(url: $0) }
            // signed in after a members-only event link: the event opens
            .onChange(of: model.phase) { _, p in if p == .ready { model.openRememberedEvent() } }
            .onAppear {
                AppDelegate.model = model
                if let t = AppDelegate.pendingTap { AppDelegate.pendingTap = nil; model.openPush(t) }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { act in if let u = act.webpageURL { model.handle(url: u) } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.readSync?.flush() }
                if phase == .active {
                    model.wake()
                    if model.phase == .ready { Task { await model.checkPush() } }
                }
            }
        }
    }
}

