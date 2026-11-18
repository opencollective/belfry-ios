import BelfryCore
import Foundation

// Belfry member links (SPEC 19.43; collective-belfry docs/roles.md "Member links"; web village-app
// 2e9a76b MemberInviteScreen + guestjoin.ts becameMember). A link made with "Joins as: Member"
// shows no channel: one screen "You're invited to <community> as <role>", Sign up (name + e-mail →
// code: the code makes this key a member) or Log in (the usual sign-in, then the link is used by
// that account). Opened signed out, the link is read first (GET /channel-invites/<token>) and is
// not used until Sign up: Log in must not spend a one-person link on a throwaway key.
// When `/guest/save/verify` answers `member: true` (or a guest-only call answers `not_guest` and
// the register says member) the app stops being a guest at once: the register's word is kept
// (`kinds[me]`), the session forgets its guest channel, guest-only state goes, and every
// subscription asks from the start (the relay now lets this key read every open channel).

/// A member link opened signed out and not used yet.
struct MemberInvite: Equatable {
    let invite: PendingInvite
    let info: InviteInfo
    var member: MemberLinkInfo { info.member ?? MemberLinkInfo(role: "member", label: "Member", membership: "permanent") }
}

extension AppModel {
    /// The member link this session came with, while it is still a guest's (reading or saving).
    var sessionMemberLink: MemberLinkInfo? { session?.memberLink }

    /// "Sign up" on the member invite: use the link with a new key (guest mode, reading), then the
    /// Join sheet (name + e-mail → code). Nothing of the channel is shown meanwhile.
    func memberSignUp() {
        guard let mi = memberInvite else { return }
        memberInvite = nil
        signUpForMember = true
        openInvite(mi.invite, member: mi.info.member)
    }

    /// "I have an account: log in": the sign-in first; the link waits (`pendingInvite`) and is used
    /// by that account afterwards (the Join with your account sheet).
    func memberLogIn() {
        guard let mi = memberInvite else { return }
        memberInvite = nil
        pendingInvite = mi.invite
        inviteSignInFirst = true
        signInDomainHint = mi.invite.domain
    }

    /// "Not now" on the member invite: forget the link.
    func dropMemberInvite() {
        memberInvite = nil
        pendingInvite = nil
        inviteProblem = nil
    }

    /// The register says I am a member (a member link was used, or I was one already): no guest
    /// state anywhere any more. Safe to call twice.
    func becameMember() {
        guard !me.isEmpty else { return }
        let channel = session?.guestChannel
        var k = kinds
        k[me] = "member"
        kinds = k
        engine?.db.set("kinds", k)
        finishJoining()
        updateSession { s in
            s.reading = nil
            s.guestChannel = nil
            s.memberLink = nil
        }
        applyState = nil
        AppModel.store(nil as ApplyStatus?, "belfry-apply-status")
        coHostToken = nil
        pendingInvite = nil
        memberInvite = nil
        signUpForMember = false
        // a new member's first minutes (web welcomeDue: "saw its guest become a member")
        UserDefaults.standard.set(me, forKey: AppModel.perAccount("belfry-was-guest"))
        // the relay now lets this key read every open channel: ask everything again
        engine?.catchUpFromStart()
        joinedChannel = channel ?? generalId
        describeAccount()
        version += 1
        Task {
            await self.revalidateConfig(force: true)
            await self.askWhois([self.me])
            await self.refresh()
        }
    }

    /// A guest-only call answered `not_guest`: am I a member already? Then become one here and
    /// say so (true); else false (the caller shows its message).
    func memberAlready() async -> Bool {
        if isDemo { return false }
        guard let got = try? await api.whois([me]), let k = got[me] else { return false }
        if k == "member" || k == "agent" {
            becameMember()
            return true
        }
        return false
    }
}
