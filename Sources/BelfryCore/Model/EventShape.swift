import Foundation

// One shape for events (canvas one-shape/event-default, event-default-online, event-tiny,
// event-full; 2026-11-22): the pieces of the event's default (mid) view that are rules, not
// layout. The online line names the service only (never text from the URL beyond its host);
// Join is open from 10 minutes before the start until the end.

public enum EventShape {
    /// Join opens this long before the start.
    public static let joinEarly = 600
    /// An event with no end counts as this long for Join.
    public static let defaultLength = 3 * 3600

    /// "Jitsi", "Google Meet", "Zoom", "Teams", else the link's host ("Online" without one).
    public static func service(_ link: String) -> String { Actions.meetingLabel(link) }

    /// Is the call open to join at NOW?
    public static func joinOpen(start: Int, end: Int?, now: Int) -> Bool {
        let stop = max(end ?? (start + defaultLength), start)
        return now >= start - joinEarly && now <= stop
    }

    /// "Hosted by Lina", "Hosted by Lina and Ben", "Hosted by Lina, Ben and 2 more".
    public static func hostedBy(_ names: [String]) -> String? {
        let n = names.filter { !$0.isEmpty }
        switch n.count {
        case 0: return nil
        case 1: return "Hosted by " + n[0]
        case 2: return "Hosted by \(n[0]) and \(n[1])"
        case 3: return "Hosted by \(n[0]), \(n[1]) and \(n[2])"
        default: return "Hosted by \(n[0]), \(n[1]) and \(n.count - 2) more"
        }
    }

    /// "15 going · 3 maybe", "4 going", "3 maybe"; nil when nobody answered yet.
    public static func goingLine(going: Int, maybe: Int) -> String? {
        switch (going > 0, maybe > 0) {
        case (true, true): return "\(going) going · \(maybe) maybe"
        case (true, false): return "\(going) going"
        case (false, true): return "\(maybe) maybe"
        default: return nil
        }
    }
}

/// One line of the event's feed about an answer: "You're going", "Lina Moreau is going".
public struct RsvpLine: Hashable, Sendable {
    public let pubkey: String
    public let rsvp: Rsvp
    public let at: Int

    public init(pubkey: String, rsvp: Rsvp, at: Int) { self.pubkey = pubkey; self.rsvp = rsvp; self.at = at }

    /// The words after the name (or the whole line for me).
    public func text(name: String, me: Bool) -> String {
        switch (rsvp, me) {
        case (.accepted, true): return "You're going"
        case (.tentative, true): return "You might go"
        case (.declined, true): return "You can't go"
        case (.accepted, false): return name + " is going"
        case (.tentative, false): return name + " might go"
        case (.declined, false): return name + " can't go"
        }
    }
}

public extension Derive {
    /// Each person's current answer to E as a feed line, oldest first (ties by key).
    func rsvpLines(_ e: CalEvent) -> [RsvpLine] {
        e.rsvps.compactMap { k, r in
            e.rsvpEvents[k].map { RsvpLine(pubkey: k, rsvp: r, at: $0.createdAt) }
        }
        .sorted { $0.at != $1.at ? $0.at < $1.at : $0.pubkey < $1.pubkey }
    }
}
