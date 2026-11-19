import Foundation

// The ONE line under a channel's name, what it summarises and its pull-down (SPEC 19.13; the
// web's ui/ChannelLine.tsx, village-app 30e775b), and a pod's mark (19.12).

/// A pod's mark: a regular polygon with one side per member, 3 at least; 13 and more draw a circle.
public enum PodShapes {
    public static func sides(_ members: Int) -> Int { min(12, max(3, members)) }
    public static func isCircle(_ members: Int) -> Bool { members > 12 }
}

/// Everything the line and its pull-down show about a channel.
public struct ChannelFacts {
    public let group: Group?
    public let pods: [Group]
    /// Open proposals of this channel (draft, feedback, voting).
    public let proposals: [Proposal]
    public let events: [CalEvent]
    public let pins: [Message]
    /// To-dos not done yet.
    public let todos: [TodoTask]
    public let active: [ActiveMember]
    /// The proposal this channel is the chat of.
    public let own: Proposal?
}

public enum LineIcon: String, Sendable { case people, topic, proposal, pod, event, pin, todo }

/// What tapping the line's pill does.
public enum LineAction: Hashable, Sendable {
    case showAll
    /// Open the pull-down (the vote is in it).
    case open
    /// The people asking to join.
    case review
    case openProposal(String)
    case openEvent(String)
    /// The channel's to-dos.
    case todos
}

public struct LineCount: Hashable, Sendable {
    public let kind: String
    public let n: Int
    public let plus: Bool
    public let label: String
}

/// The line: BOLD then TEXT, an optional PILL (a question when ASK, doing ACTION), counts at the right.
public struct ChannelLine: Hashable, Sendable {
    public var icon: LineIcon
    public var bold: String
    public var text: String
    public var pill: String?
    public var ask = false
    public var action: LineAction?
    /// A second line under the first (the to-dos' parts); it may wrap.
    public var detail: String?
    /// Nothing asks for attention: shown muted.
    public var quiet = false
    public var counts: [LineCount] = []
    /// Members of the pod, when the icon is its shape.
    public var podMembers = 0

    public init(_ icon: LineIcon, _ bold: String, _ text: String, pill: String? = nil, ask: Bool = false, action: LineAction? = nil, quiet: Bool = false, podMembers: Int = 0) {
        self.icon = icon
        self.bold = bold
        self.text = text
        self.pill = pill
        self.ask = ask
        self.action = action
        self.quiet = quiet
        self.podMembers = podMembers
    }
}

public func peopleLine(_ n: Int) -> String {
    n > 0 ? "\(n) \(n == 1 ? "person" : "people") active this month" : "Nobody active this month yet"
}

func membersWord(_ n: Int) -> String { "\(n) \(n == 1 ? "member" : "members")" }
func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

extension Derive {
    public func channelFacts(_ groupId: String, now: Int) -> ChannelFacts {
        let g = group(groupId)
        let subs = groups().filter { $0.parent == groupId }
        return ChannelFacts(
            group: g,
            pods: subs.filter(\.isPod),
            proposals: subs.filter(\.isProposal).compactMap { proposalFor($0.id) }.filter { $0.status.isOpen },
            events: upcoming(groupId, now: now),
            pins: pinned(groupId),
            todos: tasks(groupId).filter { !$0.done },
            active: recentlyActive(groupId, now: now),
            own: g?.isProposal == true ? proposalFor(groupId) : nil)
    }

    private func fmt(_ pattern: String, _ at: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = ctx.timeZone
        f.dateFormat = pattern
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    /// "Today" or "Thu 12 Nov".
    public func lineDay(_ at: Int, now: Int) -> String { dayKey(at) == dayKey(now) ? "Today" : fmt("EEE d MMM", at) }
    public func lineTime(_ at: Int) -> String { fmt("HH:mm", at) }

    /// "18:00 – 21:00", "18:00" or "All day".
    public func lineWhen(_ e: CalEvent) -> String {
        if e.allDay { return "All day" }
        // an end at the start (or in the same minute) says nothing: the start alone
        if let end = e.end, end > e.start, lineTime(end) != lineTime(e.start) || dayKey(end) != dayKey(e.start) {
            return lineTime(e.start) + " – " + lineTime(end)
        }
        return lineTime(e.start)
    }

    func dayAt(_ e: CalEvent, now: Int) -> String { lineDay(e.start, now: now) + (e.allDay ? "" : " " + lineTime(e.start)) }

    /// The line, first match (SPEC 19.13).
    public func channelLine(_ groupId: String, now: Int, topic: String? = nil, hiddenPins: Set<String> = []) -> ChannelLine {
        let f = channelFacts(groupId, now: now)
        let g = f.group
        var shown = ""
        var line = ChannelLine(.people, "", peopleLine(f.active.count), quiet: true)
        let pin = f.pins.first { !hiddenPins.contains($0.id) }
        let next = f.events.first
        let unanswered = f.events.first { stateLabel($0) == nil && $0.status != .cancelled }
        let toVote = f.proposals.first { needsMyVote($0) }

        if let topic {
            return ChannelLine(.topic, "Showing ", (topic == Derive.announcement ? "announcements" : "#" + topic) + " only", pill: "Show all", ask: true, action: .showAll)
        } else if g?.isProposal == true {
            if let p = f.own {
                let mine = p.poll?.votes[me]
                if p.votingNow {
                    line = ChannelLine(.proposal, "Voting", " · \(p.tally["yes"] ?? 0) yes · \(p.tally["no"] ?? 0) no", pill: mine.map(cap) ?? "Vote", ask: mine == nil, action: mine == nil ? .open : nil)
                } else {
                    line = ChannelLine(.proposal, cap(p.status.rawValue), " · version \(p.version) · by \(displayName(p.author))")
                }
            }
        } else if let g, g.isPod, canAdmin(g), !g.applications.isEmpty {
            let k = g.applications.count
            line = ChannelLine(.pod, "\(k) \(k == 1 ? "person asks" : "people ask") to join", " · " + membersWord(g.members.count), pill: "Review", ask: true, action: .review, podMembers: g.members.count)
        } else if let p = toVote {
            line = ChannelLine(.proposal, p.title, "", pill: "Vote", ask: true, action: .openProposal(p.groupId)); shown = "proposal"
        } else if let e = unanswered, e.start - now < 7 * 86400 {
            line = ChannelLine(.event, dayAt(e, now: now), " · " + e.title, pill: "RSVP", ask: true, action: .openEvent(e.coord)); shown = "event"
        } else if let pin {
            line = ChannelLine(.pin, "", pinLine(pin))
        } else if let e = next {
            let mine = stateLabel(e)
            line = ChannelLine(.event, dayAt(e, now: now), " · " + e.title, pill: mine ?? "RSVP", ask: mine == nil, action: .openEvent(e.coord)); shown = "event"
        } else if let p = f.proposals.first {
            line = ChannelLine(.proposal, p.title, " · " + p.status.rawValue); shown = "proposal"
        } else if let g, g.isPod {
            line = ChannelLine(.pod, "", membersWord(g.members.count) + (g.archived ? "" : " · " + (g.closed ? "by application" : "open to join")), quiet: true, podMembers: g.members.count)
        }
        line.counts = [
            LineCount(kind: "events", n: f.events.count - (shown == "event" ? 1 : 0), plus: shown == "event", label: "more events"),
            LineCount(kind: "proposals", n: f.proposals.count - (shown == "proposal" ? 1 : 0), plus: shown == "proposal", label: "more open proposals"),
            LineCount(kind: "pods", n: f.pods.count, plus: false, label: "groups"),
            LineCount(kind: "todos", n: f.todos.count, plus: false, label: "to do"),
        ].filter { $0.n > 0 }
        return line
    }

    /// The line under the header only when it must drive attention (SPEC 19.13 as of 2026-11-17,
    /// the owner: "keep that line whenever we need to drive the attention… in normal times we can
    /// remove it"): a topic filter, my vote in this proposal, people asking to join a group I run,
    /// a vote I haven't cast, an event I haven't answered within 7 days, a pinned message I haven't
    /// hidden, then the to-dos in parts (`todoLine`). Anything else: nil (no line;
    /// the counts are in the header's subtitle). No counts on it.
    public func attentionLine(_ groupId: String, now: Int, topic: String? = nil, hiddenPins: Set<String> = []) -> ChannelLine? {
        let f = channelFacts(groupId, now: now)
        let g = f.group
        if let topic {
            return ChannelLine(.topic, "Showing ", (topic == Derive.announcement ? "announcements" : "#" + topic) + " only", pill: "Show all", ask: true, action: .showAll)
        }
        if g?.isProposal == true, let p = f.own, p.votingNow, p.poll?.votes[me] == nil {
            return ChannelLine(.proposal, "Voting", " · \(p.tally["yes"] ?? 0) yes · \(p.tally["no"] ?? 0) no", pill: "Vote", ask: true, action: .open)
        }
        if let g, g.isPod, canAdmin(g), !g.applications.isEmpty {
            let k = g.applications.count
            return ChannelLine(.pod, "\(k) \(k == 1 ? "person asks" : "people ask") to join", " · " + membersWord(g.members.count), pill: "Review", ask: true, action: .review, podMembers: g.members.count)
        }
        if let p = f.proposals.first(where: { needsMyVote($0) }) {
            return ChannelLine(.proposal, p.title, "", pill: "Vote", ask: true, action: .openProposal(p.groupId))
        }
        if let e = f.events.first(where: { stateLabel($0) == nil && $0.status != .cancelled }), e.start - now < 7 * 86400 {
            return ChannelLine(.event, dayAt(e, now: now), " · " + e.title, pill: "RSVP", ask: true, action: .openEvent(e.coord))
        }
        if let pin = f.pins.first(where: { !hiddenPins.contains($0.id) }) {
            return ChannelLine(.pin, "", pinLine(pin))
        }
        return todoLine(groupId, now: now)
    }

    /// "Up next" (assigned, not started) as its own part: a draft on the canvas until the owner
    /// confirms assign = up next / claim = working now. Off: those to-dos count as unclaimed.
    public static var todoUpNext = false

    /// The channel's to-dos in parts (board channels/header-todos; #issues 8ec8c3b5): unclaimed
    /// (open, nobody's), up next (given to someone, or put down, not being worked on), in progress
    /// (claimed and not idle), closed today (done since DAYSTART, the viewer's midnight).
    public func todoCounts(_ groupId: String, dayStart: Int) -> TodoCounts {
        var c = TodoCounts()
        for t in tasks(groupId) {
            if t.done { if let at = t.doneAt, at >= dayStart { c.closedToday += 1 } }
            else if t.assignee == nil { c.unclaimed += 1 }
            else if t.claimed && !t.idle { c.inProgress += 1 }
            else if Derive.todoUpNext { c.upNext += 1 }
            else { c.unclaimed += 1 }
        }
        return c
    }

    /// The to-dos' line: "6 to-dos" and, under it, the parts. Nil when every part is 0.
    public func todoLine(_ groupId: String, now: Int, dayStart: Int? = nil) -> ChannelLine? {
        let c = todoCounts(groupId, dayStart: dayStart ?? Derive.midnight(before: now))
        guard c.total > 0 else { return nil }
        var line = ChannelLine(.todo, c.total == 1 ? "1 to-do" : "\(c.total) to-dos", "", action: .todos)
        line.detail = c.parts
        return line
    }

    /// The viewer's midnight before NOW.
    public static func midnight(before now: Int, calendar: Calendar = .current) -> Int {
        Int(calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now))).timeIntervalSince1970)
    }
}

/// A channel's to-dos in parts; the total is their sum.
public struct TodoCounts: Hashable, Sendable {
    public var unclaimed = 0
    public var upNext = 0
    public var inProgress = 0
    public var closedToday = 0
    public init(unclaimed: Int = 0, upNext: Int = 0, inProgress: Int = 0, closedToday: Int = 0) {
        self.unclaimed = unclaimed; self.upNext = upNext; self.inProgress = inProgress; self.closedToday = closedToday
    }
    public var total: Int { unclaimed + upNext + inProgress + closedToday }
    /// "2 unclaimed, 1 up next, 2 in progress, 1 closed today"; a part at 0 is left out.
    public var parts: String {
        [(unclaimed, "unclaimed"), (upNext, "up next"), (inProgress, "in progress"), (closedToday, "closed today")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }
}
