import BelfryCore
import Foundation

// Deleted and archived groups (SPEC 19.30): asking the groups relay whether it still has the
// groups this device knows (and the ones named by cards it knows nothing about), and archiving /
// unarchiving.

extension AppModel {
    /// Nothing is written in this group here: it is archived or deleted.
    func locked(_ id: String) -> Bool { derive.isLocked(id) }

    /// Asks the groups relay for the metadata (kind 39000) of ONLY, or of every channel and group
    /// this device knows: what it does not name is deleted. Never as a guest (the relay shows a
    /// guest only their own channels), never in the demo. At most once a minute for the full list.
    func checkGroups(_ only: [String]? = nil) async {
        guard let engine, !engine.localOnly, !guestReading, phase == .ready else { return }
        let d = derive
        if d.amGuest || d.isGuest(me) { return }
        if only == nil {
            if let at = presenceAt, Date().timeIntervalSince(at) < 60 { return }
            presenceAt = Date()
        }
        let ids = only ?? d.presenceCandidates()
        var now = groupsAbsent
        for q in GroupPresence.questions(ids) {
            let answer = await engine.query(.groups, [GroupPresence.filter(q)], timeout: 8)
            guard self.engine === engine else { return } // signed out or switched meanwhile
            if let next = derive.presenceAfter(asked: q, answer: answer, was: now) { now = next }
        }
        if now != groupsAbsent {
            groupsAbsent = now
            engine.db.set("groups-absent", now)
            version += 1
        }
    }

    /// A group opened that this device knows nothing about: ask the relay about it.
    func lookFor(_ id: String) {
        guard derive.groupState(id) == .unknown else { return }
        Task { await checkGroups([id]) }
    }

    /// Archive / unarchive (SPEC 19.30). My own 9002 keeping every setting when the relay lets me
    /// (its 39001, the creator, a belfry admin); an admin by role asks the belfry. Returns a fixed
    /// message when it did not work.
    func setArchived(_ id: String, _ on: Bool) async -> String? {
        guard let engine, let g = group(id) else { return "That did not work. Try again." }
        guard derive.mayArchive(g) else { return "Only the admins can change this." }
        if derive.mayModerate(g) || engine.localOnly {
            engine.enqueue(Actions.archive(g, on))
            version += 1
            return nil
        }
        do {
            let said = try await api.groupMeta(channel: id, archived: on)
            await refresh()
            if said == on { return nil }
            // a belfry from before archiving answers ok and changes nothing: look before saying so
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if derive.isArchived(id) == on { return nil }
            }
            return "This belfry can’t archive yet: it needs an update."
        } catch let x as ApiError {
            return x.message
        } catch {
            return BelfryAPI.network
        }
    }

    /// Whether nobody posted in channel ID (SPEC 19.35): what this device holds first, then the
    /// groups relay. nil = the relay did not answer (offline): the settings offer Archive.
    func channelIsEmpty(_ id: String) async -> Bool? {
        if derive.hasContent(id) { return false }
        guard let engine else { return nil }
        if engine.localOnly { return true }
        let answer = await engine.query(.groups, ChannelContent.filters(id), timeout: 8)
        guard self.engine === engine else { return nil }
        if derive.hasContent(id) { return false }
        return ChannelContent.empty(id, answer: answer)
    }

    /// Delete the empty channel ID (SPEC 19.35): `POST /group-delete`; the belfry publishes the
    /// 9008 and the channel shows deleted (19.30) once it arrives. A belfry without the route:
    /// my own 9008 when the relay lets me. Returns a fixed message when it did not work;
    /// `ChannelEnd.notEmpty` when someone wrote meanwhile (archive is offered then).
    func deleteChannel(_ id: String) async -> String? {
        guard let engine, let g = group(id) else { return "That did not work. Try again." }
        guard derive.mayEndChannel(g) else { return "Only the admins can change this." }
        if engine.localOnly {
            engine.enqueue(Actions.deleteGroup(id))
            version += 1
            return nil
        }
        do {
            try await api.groupDelete(channel: id)
            await refresh()
            return nil
        } catch let x as ApiError where x.code == "update_needed" {
            guard derive.mayModerate(g) else { return "Only the admins can change this." }
            engine.enqueue(Actions.deleteGroup(id))
            version += 1
            return nil
        } catch let x as ApiError {
            return x.code == "not_empty" ? ChannelEnd.notEmpty : x.message
        } catch {
            return BelfryAPI.network
        }
    }
}

enum ChannelEnd {
    static let notEmpty = "People wrote in this channel: archive it instead."
}
