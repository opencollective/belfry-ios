import BelfryCore
import Foundation

// Tickets, check-in and roles in a group (SPEC 19.29, the belfry's contract of 2026-11-15):
// what the belfry says about me per event (`viewer`, kept on the phone so my ticket's QR shows
// offline), the check-in list (seeded from the stored copy and the groups key's labels, then
// `POST /events/<d>/attendees`), checking in by code or person, and `POST /group-roles`.
// The demo does all of it on the device (the groups key is the demo's own).

extension AppModel {
    /// The demo's ticket code for PK at event D (lowercase base32 of a hash, as the belfry's shape).
    static func demoTicketCode(_ d: String, _ pk: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        let bytes = [UInt8](Crypto.sha256("demo-ticket:\(d):\(pk)").prefix(10))
        var out = "", buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        return out
    }

    func ticketURL(_ e: CalEvent, code: String) -> String { "https://chat.\(config.domain)/events/\(e.link)/t/\(code)" }

    /// What I know of myself at E: the stored answer, or (demo) worked out on the device.
    func viewer(_ e: CalEvent) -> EventViewer? { eventViewers[e.d] }

    /// May I check people in at E: the belfry's word when it gave one, else the relay's roles.
    func mayCheckIn(_ e: CalEvent) -> Bool {
        if let v = viewer(e), v.at > 0, !isDemo { return v.mayCheckIn || derive.mayCheckIn(e) }
        return derive.mayCheckIn(e)
    }

    /// The stored viewer block first (offline first), then the belfry's in the background.
    func loadViewer(_ e: CalEvent) async {
        if eventViewers[e.d] == nil, let v = engine?.db.get("event-viewer:" + e.d, as: EventViewer.self) { eventViewers[e.d] = v }
        if let l = engine?.db.get("event-attendees:" + e.d, as: AttendeeList.self), attendeeLists[e.d] == nil { attendeeLists[e.d] = l }
        if isDemo || engine?.localOnly == true { eventViewers[e.d] = demoViewer(e); return }
        guard !guestReading else { return }
        remoteEvents[e.link] = nil
        guard case .success(let a) = await remoteEvent(e.link), let m = a.me else { return }
        let v = EventViewer(m, at: .now)
        eventViewers[e.d] = v
        engine?.db.set("event-viewer:" + e.d, v)
    }

    private func demoViewer(_ e: CalEvent) -> EventViewer {
        let d = derive
        let ticket = heldTickets(e)[me]
        let code = ticket.map { _ in AppModel.demoTicketCode(e.d, me) }
        let role = d.eventRole(e, me)
        let roles = role == .attendee ? [] : [role.rawValue]
        return EventViewer(ticket: ticket, ticketCode: code, ticketURL: code.map { ticketURL(e, code: $0) },
                           checkedIn: d.checkIns(e.groupId)[me], roles: roles, mayCheckIn: d.mayCheckIn(e), at: .now)
    }

    /// The check-in list: the last answer with the relay's newer check-ins laid over it, else the
    /// ticket holders the relay knows.
    func attendees(_ e: CalEvent) -> AttendeeList {
        let d = derive
        let labels = d.ticketLabels(e.groupId)
        var people: [Attendee]
        if let stored = attendeeLists[e.d] {
            people = stored.people
        } else {
            let titles = Dictionary(d.tickets(e).map { ($0.d, $0.title) }, uniquingKeysWith: { a, _ in a })
            people = heldTickets(e).map { pk, t in
                Attendee(pubkey: pk, name: d.displayName(pk), ticket: t, ticketTitle: titles[t] ?? (t.hasSuffix(":free") ? "Going" : "Ticket"),
                         rsvp: e.rsvps[pk]?.rawValue, checkedIn: nil, role: d.eventRole(e, pk) == .attendee ? "member" : d.eventRole(e, pk).rawValue)
            }
        }
        for i in people.indices {
            guard let l = labels[people[i].pubkey], l.at >= (people[i].checkedIn ?? 0) else { continue }
            people[i].checkedIn = l.on ? l.at : nil
        }
        people.sort { $0.name.lowercased() < $1.name.lowercased() }
        return AttendeeList(people: people, going: people.count, checkedIn: people.filter { $0.checkedIn != nil }.count)
    }

    /// Who holds a ticket at E: the 9000s with `ticket`, and on an event without ticket types the
    /// members whose own RSVP says going (the free ticket `<d>:free`, as the belfry counts them).
    func heldTickets(_ e: CalEvent) -> [String: String] {
        let d = derive
        var held = d.eventPeople(e).holders
        if d.tickets(e).allSatisfy(\.implicit) {
            for (pk, r) in e.rsvps where r == .accepted && held[pk] == nil { held[pk] = e.d + ":free" }
        }
        return held
    }

    /// The belfry's list (hosts, co-hosts, stewards). Returns a fixed message on failure.
    func loadAttendees(_ e: CalEvent) async -> String? {
        if isDemo || engine?.localOnly == true { return nil }
        do {
            let l = try await api.attendees(d: e.d)
            attendeeLists[e.d] = l
            engine?.db.set("event-attendees:" + e.d, l)
            return nil
        } catch let x as ApiError { return x.message } catch { return BelfryAPI.network }
    }

    /// Check someone in by their ticket's CODE or their PUBKEY, or UNDO it.
    func checkIn(_ e: CalEvent, code: String? = nil, pubkey: String? = nil, undo: Bool = false, peek: Bool = false) async -> Result<CheckInResult, ApiError> {
        if isDemo || engine?.localOnly == true { return demoCheckIn(e, code: code, pubkey: pubkey, undo: undo, peek: peek) }
        do {
            let r = try await api.checkIn(d: e.d, code: code, pubkey: pubkey, undo: undo, peek: peek)
            if peek { return .success(r) }
            var list = attendeeLists[e.d] ?? attendees(e)
            if let i = list.people.firstIndex(where: { $0.pubkey == r.person.pubkey }) { list.people[i] = r.person } else { list.people.append(r.person) }
            list.checkedIn = list.people.filter { $0.checkedIn != nil }.count
            attendeeLists[e.d] = list
            engine?.db.set("event-attendees:" + e.d, list)
            if r.person.pubkey == me, var v = eventViewers[e.d] { v.checkedIn = r.person.checkedIn; eventViewers[e.d] = v }
            return .success(r)
        } catch let x as ApiError { return .failure(x) } catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    private func demoCheckIn(_ e: CalEvent, code: String?, pubkey: String?, undo: Bool, peek: Bool) -> Result<CheckInResult, ApiError> {
        let list = attendees(e)
        let who = list.people.first { p in
            if let code { return AppModel.demoTicketCode(e.d, p.pubkey) == code }
            return p.pubkey == pubkey
        }
        guard var person = who else { return .failure(ApiError("no_ticket", 404, "Not a ticket for this event")) }
        if peek { return .success(CheckInResult(person: person, already: person.checkedIn != nil)) }
        let already = !undo && person.checkedIn != nil
        if !already {
            let at = Int.now
            let v = undo ? "not-checked-in" : "checked-in"
            let tags: [Tag] = [["L", Derive.ticketNS], ["l", v, Derive.ticketNS], ["p", person.pubkey], ["h", e.groupId], ["by", me]]
            if let ev = try? Demo.signer("groups").signNow(EventTemplate(kind: 1985, tags: tags, createdAt: at)) { engine?.add([ev], verify: false) }
            person.checkedIn = undo ? nil : at
        }
        return .success(CheckInResult(person: person, already: already))
    }

    /// Change PK's role in GROUP (admin / steward / member). Returns a fixed message on failure.
    func setGroupRole(_ groupId: String, _ pk: String, _ role: GroupRole) async -> String? {
        if isDemo || engine?.localOnly == true { demoGroupRole(groupId, pk, role); return nil }
        do {
            _ = try await api.setGroupRole(channel: groupId, pubkey: pk, role: role)
            await refresh()
            return nil
        } catch let x as ApiError { return x.message } catch { return BelfryAPI.network }
    }

    /// Take PK out of GROUP (`role: removed` through the belfry; an older belfry or the demo: 9001).
    func removeFromGroup(_ groupId: String, _ pk: String) async -> String? {
        if isDemo || engine?.localOnly == true { declineApplicant(groupId, pk); return nil }
        do {
            try await api.removeFromGroup(channel: groupId, pubkey: pk)
            await refresh()
            return nil
        } catch let x as ApiError where x.code == "update_needed" {
            declineApplicant(groupId, pk)
            return nil
        } catch let x as ApiError { return x.message } catch { return BelfryAPI.network }
    }

    private func demoGroupRole(_ groupId: String, _ pk: String, _ role: GroupRole) {
        guard let g = group(groupId) else { return }
        let at = Int.now
        var admins = g.admins
        if role == .admin { admins.insert(pk) } else { admins.remove(pk) }
        var evs = [NostrEvent]()
        if admins != g.admins, let x = try? Demo.signer("relay").signNow(EventTemplate(kind: 39001, tags: [["d", groupId]] + admins.sorted().map { ["p", $0, "admin"] }, createdAt: at)) {
            evs.append(x)
        }
        if Channel.typeOf(groupId) == .event {
            let v = role == .steward ? "steward" : "none"
            let tags: [Tag] = [["L", Derive.groupRoleNS], ["l", v, Derive.groupRoleNS], ["p", pk], ["h", groupId], ["by", me]]
            if let x = try? Demo.signer("groups").signNow(EventTemplate(kind: 1985, tags: tags, createdAt: at)) { evs.append(x) }
        }
        engine?.add(evs, verify: false)
    }

    /// A group's name / description / picture / access (SPEC 19.29): my own 9002 keeping every other
    /// tag when the relay lets me (its 39001, the creator, a belfry admin); else the belfry's
    /// POST /group-meta (an admin by role). Errors come back in `website` as a fixed message.
    func editGroupMeta(_ id: String, name: String? = nil, about: String? = nil, picture: String? = nil, closed: Bool? = nil, prompt: String? = nil) {
        guard let g = group(id) else { return }
        if derive.mayModerate(g) || engine?.localOnly == true {
            engine?.enqueue(Actions.groupMeta(g, name: name, about: about, picture: picture, closed: closed, prompt: prompt))
            return
        }
        Task {
            do { try await api.groupMeta(channel: id, name: name, about: about, picture: picture, closed: closed, prompt: prompt); await refresh() }
            catch let x as ApiError { website = x.message } catch { website = BelfryAPI.network }
        }
    }

    /// An event address or a ticket link opened from outside: only the domain, link and code.
    func handleTicketURL(_ url: URL) -> Bool {
        guard let x = TicketScan.eventLink(url) else { return false }
        if phase == .ready && x.domain == config.domain {
            openEventTicket = x.code
            openEvent = x.link
        } else if phase == .ready {
            website = "This event is in another community."
        }
        return true
    }
}
