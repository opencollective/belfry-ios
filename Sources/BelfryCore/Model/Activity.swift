import Foundation

// Activity previews (canvas one-shape/action-previews, 2026-11-22; docs/one-shape.md §3): an
// action about an item shows in a channel's feed as one line, "<first name> <verb>: <item>",
// that opens a small preview of the item with its quick action. Collapsed by default; a preview
// that needs me starts open (a to-do on me, an event I haven't answered, a vote I haven't cast).
// Whether one is open is remembered on the device only.

public enum ActivityItem: Hashable, Sendable {
    /// A to-do (its id).
    case todo(String)
    /// A calendar event (its coordinate).
    case event(String)
    /// A proposal (its coordinate).
    case proposal(String)
}

public struct Activity: Hashable, Sendable, Identifiable {
    /// The event that is the action.
    public let id: String
    public let at: Int
    public let who: String
    /// "made a to-do", "finished", "is going", "might go", "voted".
    public let verb: String
    public let title: String
    public let item: ActivityItem
    /// The SF Symbol of the item's kind.
    public var icon: String {
        switch item {
        case .todo: return verb == Activity.finished ? "checkmark.circle" : "checklist"
        case .event: return "calendar"
        case .proposal: return "checkmark.seal"
        }
    }

    public static let madeTodo = "made a to-do"
    public static let finished = "finished"
    public static let going = "is going"
    public static let maybe = "might go"
    public static let voted = "voted"
}

public extension Derive {
    /// A channel's activity lines, oldest first: to-dos made and finished, answers to the events
    /// whose card was sent here (going / maybe), votes on its proposals.
    func activities(_ groupId: String) -> [Activity] {
        if let c = activitiesCache[groupId] { return c }
        var out = [Activity]()
        let listId = Derive.listIdFor(groupId)
        let titles = Dictionary(tasks(groupId).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        for e in sortedEvents where (e.kind == 2100 || e.kind == 2101) && e.tag("t") == listId && e.tag("h") == groupId {
            if e.kind == 2100, let t = titles[e.id] {
                out.append(Activity(id: e.id, at: e.createdAt, who: e.pubkey, verb: Activity.madeTodo, title: t, item: .todo(e.id)))
            } else if e.kind == 2101, e.tag("action") == "done", let tid = e.tag("e"), let t = titles[tid] {
                out.append(Activity(id: e.id, at: e.createdAt, who: e.pubkey, verb: Activity.finished, title: t, item: .todo(tid)))
            }
        }
        for ev in calendar where ev.channels.contains(groupId) {
            for (pk, r) in ev.rsvpEvents {
                let s = ev.rsvps[pk]
                guard s == .accepted || s == .tentative else { continue }
                out.append(Activity(id: r.id, at: r.createdAt, who: pk, verb: s == .accepted ? Activity.going : Activity.maybe,
                                    title: ev.title, item: .event(ev.coord)))
            }
        }
        for p in proposalsIn(groupId) {
            guard let poll = p.poll else { continue }
            var latest = [String: NostrEvent]()
            for x in ofKind(1018) where x.tag("e") == poll.ev.id {
                if let o = latest[x.pubkey], o.createdAt > x.createdAt { continue }
                latest[x.pubkey] = x
            }
            for (pk, x) in latest where poll.votes[pk] != nil {
                out.append(Activity(id: x.id, at: x.createdAt, who: pk, verb: Activity.voted, title: p.title, item: .proposal(p.coord)))
            }
        }
        out.sort { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
        activitiesCache[groupId] = out
        return out
    }

    /// The preview starts open: the item waits for me (a to-do on me and not done; an event to
    /// come I haven't answered; a proposal open for votes I haven't voted on).
    func activityNeedsMe(_ a: Activity, groupId: String, now: Int) -> Bool {
        guard !me.isEmpty else { return false }
        switch a.item {
        case .todo(let tid):
            guard let t = tasks(groupId).first(where: { $0.id == tid }) else { return false }
            return !t.done && t.assignee == me
        case .event(let coord):
            guard let ev = calendar.first(where: { $0.coord == coord }) else { return false }
            return (ev.end ?? ev.start) > now && ev.rsvps[me] == nil
        case .proposal(let coord):
            guard let p = proposals.first(where: { $0.coord == coord }) else { return false }
            return p.status == .voting && p.poll != nil && myVote(p) == nil
        }
    }
}
