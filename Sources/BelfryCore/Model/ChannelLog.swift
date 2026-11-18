import Foundation

// A channel's log (web ChannelInfo.tsx `logItem`, c6579a0; Android core/model/ChannelLog.kt,
// SPEC 19.23): one line per Nostr event carrying the channel's `h`, newest first: who did what.
// Heartbeats ("working" / "idle" on a todo) and "seen" markers are left out. The web's words.

public enum LogGo: Hashable, Sendable {
    case message(String)
    case thread(String)
    case todos
    case members
}

public struct LogItem: Hashable, Sendable, Identifiable {
    public let ev: NostrEvent
    public let icon: String
    public let text: String
    public var detail: String?
    public var go: LogGo?
    public var id: String { ev.id }
}

public enum ChannelLog {
    static let labelWords = [
        "pinned": "pinned a message", "unpinned": "unpinned a message", "attended": "checked someone in",
        "absent": "marked someone not there", "saved": "saved their account", "member": "became a member",
        "cancelled": "cancelled the event", "scheduled": "reopened the event", "assigned": "assigned a mail",
        "done": "closed a mail", "open": "reopened a mail",
    ]
    static let taskWords = ["claim": "took a todo", "unclaim": "let go of a todo", "done": "marked a todo done", "undone": "reopened a todo", "delete": "deleted a todo", "assign": "gave a todo to someone", "unassign": "took someone off a todo"]

    /// On one line, at most N UTF-16 units ("…" at the cut).
    public static func short(_ text: String, _ n: Int = 80) -> String {
        let x = Rx("\\s+").replace(text, with: " ").jsTrim()
        return (x as NSString).length > n ? x.sliceUnits(n - 1) + "…" : x
    }

    /// The line for one event; nil for what the log leaves out. TITLES: todo id → title.
    public static func item(_ e: NostrEvent, titles: [String: String], name: (String) -> String) -> LogItem? {
        let toMessage = e.tag("e").map { LogGo.message($0) }
        func line(_ icon: String, _ text: String, _ detail: String? = nil, _ go: LogGo? = nil) -> LogItem {
            LogItem(ev: e, icon: icon, text: text, detail: detail.flatMap { $0.isEmpty ? nil : $0 }, go: go)
        }
        switch e.kind {
        case 9:
            let here = LogGo.message(e.id)
            let media = e.tags.filter { $0.first == "imeta" }.map { t in t.first { $0.hasPrefix("m ") }.map { String($0.dropFirst(2)) } ?? "" }
            if e.tag("pod") != nil { return line("⬡", "created a group", short(e.content, 200), here) }
            if e.tag("proposal") != nil { return line("📄", "made a proposal", short(e.content, 200), here) }
            if media.contains(where: { $0.hasPrefix("audio/") }) { return line("🎙", "posted a recording", short(e.content, 200), here) }
            if media.contains(where: { $0.hasPrefix("image/") }) { return line("🖼", media.count > 1 ? "posted \(media.count) photos" : "posted a photo", short(e.content, 200), here) }
            if !media.isEmpty { return line("📎", "posted a file", short(e.content, 200), here) }
            if e.tag("mail-from") != nil { return line("✉️", "an e-mail came in", short((e.tag("subject") ?? "").isEmpty ? e.content : e.tag("subject")!, 200), here) }
            return line("💬", "posted a message", short(e.content, 200), here)
        case 1111: return line("↩️", "replied in a thread", short(e.content, 200), .thread(e.tag("E") ?? e.id))
        case 1010: return line("✏️", "edited a message", short(e.content, 200), toMessage)
        case 7:
            let c = e.content
            return line(!c.isEmpty && (c as NSString).length <= 4 && c != "+" ? c : "👍", "reacted", nil, toMessage)
        case 5, 9005: return line("🗑", e.tag("k") == "7" ? "took back a reaction" : "deleted something")
        case 2100: return line("☑️", "made a todo", short((e.tag("title") ?? "").isEmpty ? e.content : e.tag("title")!, 200), .todos)
        case 2101:
            guard let w = taskWords[e.tag("action") ?? ""] else { return nil }
            return line(e.tag("action") == "done" ? "✅" : "☑️", w, titles[e.tag("e") ?? ""], .todos)
        case 2103: return line("💬", "commented on a todo", short(e.content, 200), .todos)
        case 9000:
            let admin = e.tags.contains { $0.count >= 3 && $0[0] == "p" && $0[2] == "admin" }
            return line("👋", admin ? "made someone an admin" : "added someone", e.tag("p").map(name), .members)
        case 9001: return line("🚪", "removed someone", e.tag("p").map(name), .members)
        case 9021: return line("🙋", "asked to join", short(e.content, 200))
        case 9022: return line("🚪", "left")
        case 9002: return line("⚙️", "changed the channel", [e.tag("name"), e.tag("about")].compactMap { $0 }.filter { !$0.isEmpty }.map { short($0, 120) }.joined(separator: " · "))
        case 9007: return line("✨", "created the channel")
        case 1985:
            let l = e.tags.first { $0.first == "l" }.flatMap { $0.count > 1 ? $0[1] : nil } ?? ""
            if e.tag("L") == "#t" { return line("#", "changed the pinned topics") }
            return line(l == "pinned" || l == "unpinned" ? "📌" : l == "attended" ? "✅" : "🏷", labelWords[l] ?? "labelled something \(l)", e.tag("p").map(name), toMessage)
        case 30078:
            let d = e.tag("d") ?? ""
            return d.hasPrefix("seen:") ? nil : line("⚙️", "changed a setting", d)
        case 31922, 31923:
            let meeting = e.hasTag("t", "meeting")
            return line(meeting ? "👥" : "📅", meeting ? "set the meeting" : "set the event", e.tag("title"))
        case 31925:
            let s = e.tag("status")
            return line("📅", "answered " + (s == "accepted" ? "going" : s == "declined" ? "can't go" : "maybe"))
        default: return line("•", "kind \(e.kind)")
        }
    }
}

public extension Derive {
    /// Everything that happened in a channel, newest first (at most LIMIT lines).
    func channelLog(_ groupId: String, limit: Int = 1000) -> [LogItem] {
        let titles = Dictionary(tasks(groupId).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var out = [LogItem]()
        for e in sortedEvents.reversed() where e.tag("h") == groupId {
            if let it = ChannelLog.item(e, titles: titles, name: { displayName($0) }) { out.append(it) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Who a log line is by: the relay signs joins and channel changes itself, so its key reads as the community.
    func logWho(_ groupId: String, _ pubkey: String) -> String {
        if pubkey != me, pubkey == metaAuthors[groupId] || pubkey == ctx.groupsKey, !ctx.communityName.isEmpty { return ctx.communityName }
        return displayName(pubkey)
    }
}
