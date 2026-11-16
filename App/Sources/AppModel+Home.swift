import BelfryCore
import Foundation

// What Home, Calendar and Groups read (2026-11-16): my to-dos across channels, unread places,
// the events coming up and their state in words, a guest's end date, the charter's reminder.

struct TodoRef: Identifiable, Hashable {
    let group: String
    let task: TodoTask
    var id: String { task.id }
}

/// Calendar's three lists (members) or two (guests).
enum CalendarList: String, CaseIterable, Hashable {
    case mine, invited, discover, publicEvents, going

    var title: String {
        switch self {
        case .mine: return "My calendar"
        case .invited: return "Invited"
        case .discover: return "Discover"
        case .publicEvents: return "Public events"
        case .going: return "Going"
        }
    }
}

extension AppModel {
    /// To-dos in the channels and groups I'm in: on me first, then open ones nobody took.
    var myTodos: (onMe: [TodoRef], open: [TodoRef]) {
        let d = derive
        var onMe = [TodoRef](), open = [TodoRef]()
        for g in d.groups() where g.id != Derive.charterId && d.inChannel(g, me) {
            for t in d.tasks(g.id) where !t.done {
                if t.assignee == me { onMe.append(TodoRef(group: g.id, task: t)) } else if t.assignee == nil { open.append(TodoRef(group: g.id, task: t)) }
            }
        }
        return (onMe, open)
    }

    /// The listed channels and groups with something unread, newest activity first.
    func unreadPlaces() -> [Channel] {
        derive.groups().filter { $0.id != Derive.charterId && !$0.isEvent && unread($0.id) > 0 }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The town's channels with something unread (☰'s count in Town).
    var townUnread: Int {
        derive.groups().filter { $0.type == .channel && $0.id != Derive.charterId && unread($0.id) > 0 }.count
    }

    /// The red dot on Home: something waits for me.
    var homeCount: Int {
        if derive.amGuest { return 0 }
        return requestCount + newMentions + unreadDMs + myTodos.onMe.count + derive.charterToAgree().count
    }

    /// Events I'm part of in the next 7 days (hosting, going, maybe, applied, invited and not answered).
    func comingUp(now: Int = .now) -> [CalEvent] {
        let d = derive
        let until = d.startOfDay(now) + 8 * 86400
        return d.eventsIn(.upcoming, now: now).filter { e in
            guard e.start < until, e.status != .cancelled else { return false }
            return isMine(e) || isInvited(e)
        }
    }

    func isMine(_ e: CalEvent) -> Bool {
        let d = derive
        if e.hosts.contains(me) { return true }
        switch d.myState(e) {
        case .host, .ticket, .maybe, .applied, .waitlist: return true
        default: return d.myRsvp(e) == .accepted || d.myRsvp(e) == .tentative
        }
    }

    /// A meeting I was asked to and haven't answered.
    func isInvited(_ e: CalEvent) -> Bool {
        e.invited.contains(me) && derive.myRsvp(e) == nil && !isMine(e)
    }

    func calendar(_ list: CalendarList, now: Int = .now) -> [CalEvent] {
        let all = derive.eventsIn(.upcoming, now: now).filter { $0.status != .cancelled || isMine($0) }
        switch list {
        case .mine, .going: return all.filter { isMine($0) }
        case .invited: return all.filter { isInvited($0) }
        case .discover: return all.filter { !isMine($0) && !isInvited($0) }
        case .publicEvents:
            let mine = Set(derive.groups().filter { $0.members.contains(me) || $0.reading.contains(me) }.map(\.id))
            return all.filter { e in e.visibility == .public || e.channels.contains { c in mine.contains(c) } }
        }
    }

    /// An event's state in words (no buttons on rows): "you host · check-in today", "going",
    /// "invited · not answered yet", "14 going".
    func eventStatus(_ e: CalEvent, now: Int = .now) -> String {
        let d = derive
        if e.status == .cancelled { return "cancelled" }
        let today = d.startOfDay(e.start) == d.startOfDay(now)
        if e.hosts.contains(me) { return today && e.isNew ? "you host · check-in today" : "you host" }
        switch d.myState(e) {
        case .ticket: return "going"
        case .maybe: return "maybe"
        case .applied: return "applied"
        case .waitlist: return "on the waitlist"
        case .cant: return "can't go"
        case .declined: return "not this time"
        default: break
        }
        if let r = d.myRsvp(e) { return r.label.lowercased() }
        if isInvited(e) { return "invited · not answered yet" }
        if e.visibility == .public { return "open to all" }
        return e.going > 0 ? "\(e.going) going" : "not answered yet"
    }

    /// Where an event is: its place, else "Online meeting" / "Meeting".
    func eventPlace(_ e: CalEvent) -> String? {
        if let l = e.location, !l.isEmpty { return l }
        if e.meeting { return e.links.isEmpty ? "Meeting" : "Online meeting" }
        return nil
    }

    /// A guest's last day (the `guest` tag of the newest 9000 that let me in), nil if unknown.
    var guestUntil: Date? {
        let d = derive
        let mine = d.events.filter { $0.kind == 9000 && $0.tag("p") == me && ($0.tag("guest") ?? "").count == 10 }
            .sorted(by: Derive.byTime)
        guard let s = mine.last?.tag("guest") else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// "Guest until Mon 23 November" / "Guest".
    var guestLine: String {
        guard let u = guestUntil else { return "Guest" }
        return "Guest until " + u.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
    }

    /// "7 days left" (or "Last day").
    var guestDaysLeft: String? {
        guard let u = guestUntil else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: u).day ?? 0
        if days <= 0 { return "Last day" }
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    /// The channels a guest was let into.
    var guestChannels: [Channel] {
        derive.groups().filter { ($0.members.contains(me) || $0.reading.contains(me)) && !$0.isEvent && $0.id != Derive.charterId }
    }

    /// The belfry's public places a guest can read here (public channels they aren't in).
    var openToEveryone: [Channel] {
        let d = derive
        let mine = Set(guestChannels.map(\.id))
        return d.groups().filter { $0.type == .channel && d.isPublic($0) && !mine.contains($0.id) }
    }

    /// Members of the belfry (the Square's people, guests and agents left out): "38 of 41 members".
    var memberKeys: Set<String> {
        let d = derive
        let base = d.group(generalId)?.members ?? []
        return Set(base.filter { !d.isGuest($0) && !d.isAgent($0) })
    }

    /// A guest asks to become a member on the same account. The belfry has only the web form
    /// (pass.<domain>/apply, which makes a new person) and no signed call for a guest yet
    /// (SERVER-NEEDS 10): refused in words, except in the demo.
    func applyAsGuest(answer: String) async -> String? {
        if engine?.localOnly != false {
            guestApplied = true
            return nil
        }
        return "\(config.name) can't take a guest's request from the app yet. Ask the person who invited you, or a steward."
    }
}
