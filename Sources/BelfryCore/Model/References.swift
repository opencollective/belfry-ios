import Foundation

// References in a message (SPEC 19.49 = Android 19.44; vectors/references.json; the web chat's
// src/core/refs.ts is the reference implementation since 2026-11-20): any address of this
// belfry's chat (a channel and its pages, a to-do, a message, an event, a person), its event
// pages, its drop box links, and nostr:naddr of a group, an event or a proposal. Xavier: links to
// things in the belfry never show as a raw link.
// Inside the text a reference reads as its name; the last one, when the text ends with it, comes
// out of the text and shows as a preview box under it.

/// What a reference points to.
public enum RefTarget: Hashable, Sendable {
    /// A NIP-29 group by its id (a channel, a group, an event's chat, a proposal's chat).
    case group(String)
    /// An event by its page's link (slug or d) or by its coord.
    case event(link: String?, coord: String?)
    /// A proposal by its coord.
    case proposal(String)
    /// A to-do of a channel (its 2100's id).
    case todo(group: String, task: String)
    /// One message: of a channel (GROUP) or of an event's chat (the event's LINK).
    case message(group: String?, link: String?, id: String)
    /// A person by their key (hex).
    case person(String)
    /// A drop box link by its token.
    case drop(String)
}

public enum RefPart: Hashable, Sendable {
    case text(String)
    /// Inside the text: shown as its name.
    case ref(RefTarget)
    /// The last reference, at the very end: a preview box under the text.
    case box(RefTarget)
}

public enum References {
    static let urlRx = Rx("https?://[^\\s<>()]+[^\\s<>().,;:!?'\"]")
    static let naddrRx = Rx("nostr:(naddr1[02-9ac-hj-np-z]{20,400})")

    /// Any address of the chat: what follows "#/".
    static func hashRx(_ domain: String) -> Rx {
        let d = NSRegularExpression.escapedPattern(for: domain)
        return Rx("^https://(?:chat\\.\(d)|\(d)/chat)/#/([^?#\\s]{1,600})$")
    }

    static func eventRx(_ domain: String) -> Rx {
        let d = NSRegularExpression.escapedPattern(for: domain)
        return Rx("^https://(?:chat\\.\(d)|\(d))/events/([A-Za-z0-9_-]{1,80})/?$")
    }

    static func dropRx(_ domain: String) -> Rx {
        let d = NSRegularExpression.escapedPattern(for: domain)
        return Rx("^https://\(d)/drop/([A-Za-z0-9_-]{8,100})/?$")
    }

    static let hexRx = Rx("^[0-9a-f]{64}$")
    static let linkRx = Rx("^[A-Za-z0-9_-]{1,80}$")
    static let taskRx = Rx("^[A-Za-z0-9_-]{1,100}$")
    static let coordRx = Rx("^3192[23]:[0-9a-f]{64}:[^\\s]{1,200}$")
    /// A channel's pages that show the channel itself.
    static let groupPages: Set<String> = ["group", "info", "about", "members", "images", "photos", "files", "todos", "log", "events"]

    /// A chat route (what follows "#/") as a reference; nil for the app's places, a ticket, …
    /// (refs.ts routeRef, step for step).
    static func route(_ path: String) -> RefTarget? {
        let raw = Rx("/+$").replace(path, with: "").components(separatedBy: "/")
        var seg = [String]()
        for x in raw {
            guard let d = x.removingPercentEncoding, !d.isEmpty, d.utf16.count <= 200 else { return nil }
            seg.append(d)
        }
        func at(_ i: Int) -> String? { i < seg.count ? seg[i] : nil }
        let more = Array(seg.dropFirst(4))
        guard let a = at(0), let b = at(1) else { return nil }
        let c = at(2), d = at(3)
        if a == "c", b.utf16.count <= 120 {
            guard let c else { return .group(b) }
            if c == "todo", let d, more.isEmpty, taskRx.test(d) { return .todo(group: b, task: d) }
            if c == "m" || c == "thread", let d, hexRx.test(d), more.isEmpty || more == ["reply"] { return .message(group: b, link: nil, id: d) }
            if groupPages.contains(c), d == nil || (c == "info" && d == "members" && more.isEmpty) { return .group(b) }
            if c == "t", d != nil, more.isEmpty { return .group(b) }
            return nil
        }
        if a == "cal", c == nil, coordRx.test(b) { return .event(link: nil, coord: b) }
        if a == "events", linkRx.test(b) {
            guard let c else { return .event(link: b, coord: nil) }
            if c == "m", let d, hexRx.test(d), more.isEmpty { return .message(group: nil, link: b, id: d) }
            return nil // a ticket (/t/<code>) stays a link
        }
        if a == "u", c == nil {
            if hexRx.test(b) { return .person(b) }
            if let pk = Bech32.pubkey(npub: b) { return .person(pk) }
        }
        return nil
    }

    /// What TOKEN (an address, or `nostr:naddr1…`) points to; nil when it isn't a reference: it
    /// stays as written.
    public static func target(_ token: String, domain: String) -> RefTarget? {
        if token.hasPrefix("nostr:") {
            guard let a = Nip19.decodeNaddr(String(token.dropFirst(6))) else { return nil }
            switch a.kind {
            case 39000: return .group(a.identifier)
            case 31922, 31923: return .event(link: nil, coord: "\(a.kind):\(a.pubkey):\(a.identifier)")
            case 30023: return .proposal("\(a.kind):\(a.pubkey):\(a.identifier)")
            default: return nil
            }
        }
        guard !domain.isEmpty else { return nil }
        if let m = hashRx(domain).first(token), let path = m[1] { return route(path) }
        if let m = eventRx(domain).first(token), let link = m[1] { return .event(link: link, coord: nil) }
        if let m = dropRx(domain).first(token), let t = m[1] { return .drop(t) }
        return nil
    }

    /// TEXT as parts: text, a reference inside the text, and the box (the last reference, when
    /// the text trimmed of trailing white space ends with it).
    public static func parts(_ text: String, domain: String) -> [RefPart] {
        let ns = text as NSString
        var found = [(start: Int, end: Int, t: RefTarget)]()
        for re in [naddrRx, urlRx] {
            for m in re.matches(text) {
                if let t = target(m.whole, domain: domain) { found.append((m.range.location, m.range.location + m.range.length, t)) }
            }
        }
        found.sort { $0.start < $1.start }
        var out = [RefPart]()
        func push(_ s: String) {
            if s.isEmpty { return }
            if case .text(let l)? = out.last { out[out.count - 1] = .text(l + s) } else { out.append(.text(s)) }
        }
        let trimmedEnd = (trimEnd(text) as NSString).length
        var last = 0
        for (i, f) in found.enumerated() {
            if f.start < last { continue }
            push(ns.substring(with: NSRange(location: last, length: f.start - last)))
            if i == found.count - 1 && f.end == trimmedEnd {
                if case .text(let l)? = out.last {
                    let t = trimEnd(l)
                    if t.isEmpty { out.removeLast() } else { out[out.count - 1] = .text(t) }
                }
                out.append(.box(f.t))
            } else {
                out.append(.ref(f.t))
            }
            last = f.end
        }
        if case .box? = out.last { return out }
        push(ns.substring(from: last))
        return out
    }

    /// A message's text as its box shows it: one line of at most 160 units.
    public static func excerpt(_ text: String) -> String {
        let s = Rx("\\s+").replace(text, with: " ").jsTrim()
        let ns = s as NSString
        return ns.length > 160 ? ns.substring(to: 159) + "…" : s
    }

    /// JavaScript's `s.replace(/\s+$/u, '')`.
    static func trimEnd(_ s: String) -> String { Rx("\\s+$").replace(s, with: "") }

    /// The text to draw (the box taken out, the references inside left as written: the text view
    /// names them) and the box, if any.
    public static func split(_ text: String, domain: String) -> (text: String, box: RefTarget?) {
        let ps = parts(text, domain: domain)
        guard case .box(let b)? = ps.last else { return (text, nil) }
        // everything before the box, as written
        let ns = text as NSString
        let trimmed = (trimEnd(text) as NSString).length
        // the box's token is the last reference token: find where it starts
        var start = trimmed
        for re in [naddrRx, urlRx] {
            for m in re.matches(text) where m.range.location + m.range.length == trimmed && target(m.whole, domain: domain) != nil {
                start = min(start, m.range.location)
            }
        }
        return (trimEnd(ns.substring(to: start)), b)
    }
}

/// Where a reference opens.
public enum RefOpen: Hashable, Sendable {
    case channel(String)
    case event(String)
    /// A message of a channel: the channel scrolled to it (or its thread).
    case message(group: String, id: String)
    case todo(group: String, task: String)
    case person(String)
    /// A page outside the app (a drop box).
    case url(String)
}

/// A reference as it is shown: its name inside the text, and the lines of its box.
public struct RefShown: Hashable, Sendable {
    public enum Kind: String, Sendable { case channel, group, event, proposal, todo, message, person, drop, locked, deleted, unknown }
    public var kind: Kind
    /// Inside the text: "#Garden", "Repair café", "Quiet hours after 22:00"; never an id or a slug.
    public var name: String
    /// The box: its title and the line under it ("Channel · 12 members", "Proposal in #Townsquare").
    public var title: String
    public var line: String
    public var about: String = ""
    /// Nil: nothing to open (not here yet, can't open it, deleted).
    public var open: RefOpen?
    /// An event: the app's own event card is its box.
    public var event: EventRef?
    /// A person, or a message's author: their face is the box's picture.
    public var face: String?
    /// A to-do that is done.
    public var done = false
    /// A drop box: until when it takes files (unix seconds).
    public var until: Int?
}

public extension Derive {
    /// How reference T reads for me (SPEC 19.49): the name, the box's lines, where it opens.
    func refShown(_ t: RefTarget) -> RefShown {
        switch t {
        case .person(let pk):
            let n5 = profiles()[pk]?.nip05 ?? ""
            let name = displayName(pk)
            return RefShown(kind: .person, name: "@" + (realName(pk).isEmpty ? name : realName(pk)), title: name,
                            line: isGuest(pk) ? "Guest" : n5.contains("@") ? n5 : isAgent(pk) ? "Agent" : "Person",
                            open: .person(pk), face: pk)
        case .drop(let token):
            let url = RefOpen.url(dropURL(token))
            guard let e = events.first(where: { $0.kind == 30078 && $0.tag("d") == "drop:" + token }) else {
                return RefShown(kind: .drop, name: "a drop box", title: "Drop box", line: "Send files without an account", open: url)
            }
            let until = Int(Double(e.tag("expiration") ?? "") ?? 0)
            if (until > 0 && until < Int.now) || deleted().contains(e.id) || deleted().contains("30078:\(e.pubkey):drop:\(token)") {
                return RefShown(kind: .deleted, name: "an ended drop box", title: "An ended drop box", line: "")
            }
            let g = e.tag("h").flatMap { group($0) }
            return RefShown(kind: .drop, name: "the drop box" + (g.map { " of " + $0.label } ?? ""), title: "Drop box",
                            line: g.map { "Files go to " + $0.label } ?? "Send files without an account", open: url, until: until > 0 ? until : nil)
        case .todo(let gid, let task):
            guard let g = group(gid) else {
                return isDeleted(gid) ? RefShown(kind: .deleted, name: "a deleted to-do", title: "A deleted to-do", line: "")
                    : RefShown(kind: .unknown, name: "To-do", title: "To-do", line: "")
            }
            guard inChannel(g, me) else {
                return RefShown(kind: .locked, name: "a to-do in a closed channel", title: "A to-do in a closed channel", line: "Only its members can open it")
            }
            guard let t = tasks(gid).first(where: { $0.id == task }) else { return RefShown(kind: .unknown, name: "To-do", title: "To-do", line: "") }
            let who = t.done ? "Done" : t.assignee == nil ? "Nobody on it yet" : t.assignee == me ? "You are on it" : displayName(t.assignee!) + " is on it"
            return RefShown(kind: .todo, name: (t.done ? "☑ " : "☐ ") + t.title, title: t.title, line: "To-do in " + g.label + " · " + who,
                            open: .todo(group: gid, task: task), done: t.done)
        case .message(let group, let link, let id):
            let ev = link.flatMap { eventByLink($0) }
            let gid = group ?? ev?.groupId
            let g = gid.flatMap { self.group($0) }
            if let gid, g == nil, isDeleted(gid) { return RefShown(kind: .deleted, name: "a deleted message", title: "A deleted message", line: "") }
            if let g, !inChannel(g, me) {
                return RefShown(kind: .locked, name: "a message in a closed channel", title: "A message in a closed channel", line: "Only its members can open it")
            }
            if deleted().contains(id) { return RefShown(kind: .deleted, name: "a deleted message", title: "A deleted message", line: "") }
            guard let g, let m = message(g.id, id) else { return RefShown(kind: .unknown, name: "Message", title: "Message", line: "") }
            let e = ev ?? eventOfGroup(g.id)
            let who = m.pubkey == me ? "you" : displayName(m.pubkey)
            return RefShown(kind: .message, name: "a message from " + who, title: displayName(m.pubkey),
                            line: "Message in " + (e?.title ?? g.label), about: References.excerpt(plainRefs(m.text)),
                            open: .message(group: g.id, id: id), face: m.pubkey)
        case .event(let link, let coord):
            let ref = EventRef(coord: coord, link: link)
            if let e = coord.flatMap({ calEvent($0) }) ?? link.flatMap({ eventByLink($0) }) {
                return RefShown(kind: .event, name: e.title, title: e.title, line: "Event", open: .event(e.coord), event: EventRef(coord: e.coord))
            }
            return RefShown(kind: .unknown, name: "Event", title: "Event", line: "", open: nil, event: ref)
        case .proposal(let coord):
            guard let p = proposals.first(where: { $0.coord == coord }) else {
                return RefShown(kind: .unknown, name: "Proposal", title: "Proposal", line: "")
            }
            return shown(p)
        case .group(let id):
            if isDeleted(id) {
                let w = "a deleted " + Group.kindWord(id)
                return RefShown(kind: .deleted, name: w, title: cap(w), line: "")
            }
            guard let g = group(id) else {
                // not here yet: the kind's word (vectors/channel-refs.json: "#channel")
                let w = "#" + Group.kindWord(id)
                return RefShown(kind: .unknown, name: w, title: w, line: "")
            }
            guard inChannel(g, me) else {
                let w = g.isPod ? "a closed group" : "a members-only channel"
                return RefShown(kind: .locked, name: w, title: cap(w), line: "Only members of \(ctx.communityName.isEmpty ? "this belfry" : ctx.communityName) can open it")
            }
            // an event's chat reads as its event, a proposal's chat as its proposal
            if g.isEvent, let e = eventOfGroup(id) { return refShown(.event(link: nil, coord: e.coord)) }
            if g.isProposal, let p = proposals.first(where: { $0.groupId == id }) { return shown(p) }
            let name = "#" + (g.named ? g.name : Group.kindWord(id))
            let word = g.isPod ? "Group" : "Channel"
            return RefShown(kind: g.isPod ? .group : .channel, name: name, title: name, line: word + " · " + membersWord(g.members.count),
                            about: g.about, open: .channel(id))
        }
    }

    private func shown(_ p: Proposal) -> RefShown {
        let parent = group(p.groupId)?.parent.map { label($0) }
        return RefShown(kind: .proposal, name: p.title, title: p.title, line: parent.map { "Proposal in " + $0 } ?? "Proposal", open: .channel(p.groupId))
    }
}
