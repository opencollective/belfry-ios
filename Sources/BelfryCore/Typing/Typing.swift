import Foundation

// Typing indicators (collective-belfry docs/typing.md @7750419; SPEC 19.66; vectors/typing.json,
// written here from tools/vectors/typing.py). Kind 20100, never kept: who types where, for a few
// seconds. The rules are pure so the three apps match.

public enum Typing {
    public static let kind = 20100
    public static let wrapKind = 21059
    /// Seconds between two typing events for one place.
    public static let sendGap: TimeInterval = 4
    /// Seconds a person shows as typing after their latest event.
    public static let showFor: TimeInterval = 6
    /// An event further than this from now (past or future) is ignored.
    public static let skew: TimeInterval = 10
    /// A stop goes only if a typing event went out this recently.
    public static let stopWindow: TimeInterval = 6
    /// A relay that refused one: no typing events to it for this long.
    public static let refusedPause: TimeInterval = 30
    /// The signer may take this long for a typing event; then it is dropped.
    public static let signerWait: TimeInterval = 3

    /// "Lina Moreau is typing…", "Lina Moreau and Ben Okafor are typing…", "Several people are typing…".
    public static func text(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "Several people are typing…"
        }
    }

    public static func accepted(createdAt: TimeInterval, now: TimeInterval) -> Bool { abs(now - createdAt) <= skew }

    /// Where a typing event belongs: a group's conversation, a thread of it, a direct conversation.
    public static func place(group: String, root: String?) -> String { "h:" + group + (root.map { "/e:" + $0 } ?? "") }
    public static func place(conv: String) -> String { "dm:" + conv }

    /// The tags of a channel's typing event.
    public static func tags(group: String, root: String?, stop: Bool) -> [Tag] {
        var t: [Tag] = [["h", group]]
        if let root { t.append(["e", root]) }
        if stop { t.append(["status", "stop"]) }
        return t
    }

    /// A direct message's typing rumor's tags: p for every other participant.
    public static func dmTags(others: [String], stop: Bool) -> [Tag] {
        others.map { ["p", $0] } + (stop ? [["status", "stop"]] : [])
    }

    public static func isStop(_ tags: [Tag]) -> Bool { tags.contains { $0.count >= 2 && $0[0] == "status" && $0[1] == "stop" } }
}

/// What this device sends for one composer: a typing event at most every 4 s while it holds text,
/// a stop when it is emptied without sending soon after one.
public struct TypingSender: Sendable {
    public enum Out: Equatable, Sendable { case typing, stop }
    private var last: TimeInterval?

    public init() {}

    /// A keystroke left TEXT in the field. RESTORED (a draft put back) or EDITING (an older
    /// message): nothing.
    public mutating func key(_ text: String, now: TimeInterval, restored: Bool = false, editing: Bool = false) -> Out? {
        if restored || editing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if let l = last, now - l < Typing.sendGap { return nil }
        last = now
        return .typing
    }

    /// The field was emptied without sending.
    public mutating func cleared(now: TimeInterval) -> Out? {
        defer { last = nil }
        if let l = last, now - l < Typing.stopWindow { return .stop }
        return nil
    }

    /// The message went: it clears the indicator by itself.
    public mutating func sent() { last = nil }
}

/// Who types where, from the events and messages that arrive.
public struct TypingBoard: Sendable {
    private struct Entry: Sendable { var until: TimeInterval; var since: TimeInterval }
    private var places = [String: [String: Entry]]()

    public init() {}

    /// A typing event of AUTHOR for PLACE. False when it was ignored (mine, stale, from the future).
    @discardableResult
    public mutating func event(place: String, author: String, createdAt: TimeInterval, stop: Bool, now: TimeInterval, me: String) -> Bool {
        guard author != me, Typing.accepted(createdAt: createdAt, now: now) else { return false }
        if stop { places[place]?[author] = nil; return true }
        var p = places[place] ?? [:]
        let since = (p[author].map { $0.until > now } ?? false) ? p[author]!.since : now
        p[author] = Entry(until: now + Typing.showFor, since: since)
        places[place] = p
        return true
    }

    /// A message of AUTHOR landed in PLACE (kind 9, 1111, 14 or 15).
    public mutating func message(place: String, author: String) {
        places[place]?[author] = nil
    }

    /// Who types in PLACE now, who started first first.
    public func typers(_ place: String, now: TimeInterval) -> [String] {
        (places[place] ?? [:]).filter { $0.value.until > now }.sorted { $0.value.since != $1.value.since ? $0.value.since < $1.value.since : $0.key < $1.key }.map(\.key)
    }

    /// When the next person stops showing in PLACE (nil: nobody types).
    public func nextExpiry(_ place: String, now: TimeInterval) -> TimeInterval? {
        (places[place] ?? [:]).values.map(\.until).filter { $0 > now }.min()
    }

    /// Drops what has expired everywhere.
    public mutating func prune(now: TimeInterval) {
        for (k, v) in places { let live = v.filter { $0.value.until > now }; places[k] = live.isEmpty ? nil : live }
    }
}
