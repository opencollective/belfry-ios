import BelfryCore
import Foundation

// Meetings (web core/meetings.ts, SPEC 19.23): make one from a channel's ＋, invite more, add
// someone by name (the belfry makes an account), hand a held account over, check people in.

extension AppModel {
    /// A new meeting from CHANNEL; people not on the belfry get an account each once its chat is
    /// on the relay. Returns its d and a fixed message when someone could not be added.
    func createMeeting(_ m: MeetingForm, named: [NamedPerson], channel: String) async -> (String, String?) {
        let d = EventLinks.newD(now: .now)
        let drafts = Meetings.create(m, channel: channel, d: d, me: me, groupsRelay: config.groupsRelay)
        for dr in drafts { engine?.enqueue(dr) }
        let people = named.filter { !$0.name.jsTrim().isEmpty }
        guard !people.isEmpty else { return (d, nil) }
        var keys = [String]()
        for n in people {
            switch await accountFor("ev-" + d, n) {
            case .success(let k): keys.append(k)
            case .failure(let e):
                addTags(drafts, keys)
                let who = n.name.jsTrim()
                return (d, "The meeting is made, but \(who) could not be added: \(e.message) Add them from the meeting.")
            }
        }
        // a second later than the first version, so the newer one wins
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        addTags(drafts, keys)
        return (d, nil)
    }

    /// One new version of the event just made (its first draft's tags) with KEYS invited.
    private func addTags(_ drafts: [Draft], _ keys: [String]) {
        guard !keys.isEmpty, var v = drafts.first(where: { $0.target == .main }) else { return }
        v.tags += keys.map { ["p", $0, "", "invited"] }
        engine?.enqueue(v)
    }

    /// An account for someone who isn't on the belfry, put in GROUP (retried while its chat isn't
    /// on the relay yet). Demo: a key of our own, put in the chat the way the belfry does it.
    func accountFor(_ group: String, _ n: NamedPerson) async -> Result<String, ApiError> {
        if engine?.localOnly == true {
            let pk = Keys.generateSecret().hex
            var tags: [Tag] = [["h", group], ["p", pk, "member"], ["guest", ""], ["invited-by", me], ["name", String(n.name.jsTrim().prefix(100))]]
            if (n.email ?? "").isEmpty { tags.append(["unsaved", "1"]) }
            engine?.enqueue(Draft(kind: 9000, tags: tags))
            return .success(pk)
        }
        do { return .success(try await api.meetingGuestRetrying(channel: group, n).pubkey) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    func inviteToMeeting(_ e: CalEvent, _ keys: [String]) {
        for dr in Meetings.invite(e, keys) { engine?.enqueue(dr) }
    }

    /// Someone added by name joins meeting E. Nil, or a fixed message.
    func addByName(_ e: CalEvent, _ n: NamedPerson) async -> String? {
        switch await accountFor(e.groupId, n) {
        case .success(let k): inviteToMeeting(e, [k]); return nil
        case .failure(let x): return x.message
        }
    }

    /// Hand a name-only account I made to its person. Nil, or a fixed message.
    func handOver(_ e: CalEvent, pubkey: String, email: String) async -> String? {
        if engine?.localOnly == true {
            engine?.enqueue(Draft(kind: 1985, tags: [["h", e.groupId], ["L", Derive.guestNS], ["l", "saved", Derive.guestNS], ["p", pubkey]]))
            return nil
        }
        do { try await api.meetingHandOver(pubkey: pubkey, email: email); return nil }
        catch let x as ApiError { return x.message } catch { return BelfryAPI.network }
    }

    /// The maker (or a belfry admin) takes someone off a meeting before it starts.
    func removeFromMeeting(_ e: CalEvent, _ pubkey: String) {
        for dr in Meetings.remove(e, pubkey: pubkey) { engine?.enqueue(dr) }
    }

    func checkIn(_ e: CalEvent, _ pubkey: String, on: Bool) { engine?.enqueue(Meetings.checkIn(e, pubkey: pubkey, on: on)) }
}
