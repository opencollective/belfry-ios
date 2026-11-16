import Foundation

// The channel list's order and sections (web src/core/order.ts, model.ts webPage /
// isPublicChannel) and the @Mentions list (web src/ui/Mentions.tsx).

/// A channel's web settings: 30078 d=belfry:web:<id> with h=<id>, by one of its admins or the
/// relay's key (which set up the default channels). Absent = members only.
public struct WebPage: Hashable, Sendable {
    public var on: Bool
    public var slug: String
    /// "public" or "members"
    public var visibility: String
    /// thread | event | proposal | request: the channel takes this one type of post (nil = any).
    public var posts: String?
}

public extension Derive {
    static let webD = "belfry:web:"
    static let orderD = "belfry:channel-order"
    static let postTypes = ["thread", "event", "proposal", "request"]

    func webPage(_ g: Group?) -> WebPage? {
        guard let g else { return nil }
        if let c = webCache[g.id] { return c }
        let w = computeWebPage(g)
        webCache[g.id] = w
        return w
    }

    private func computeWebPage(_ g: Group) -> WebPage? {
        let relayKey = metaAuthors[g.id]
        let own = (webEvents[Derive.webD + g.id] ?? []).filter {
            $0.tag("h") == g.id && (g.admins.contains($0.pubkey) || $0.pubkey == relayKey)
        }.sorted(by: Derive.byTime)
        guard let last = own.last else { return nil }
        let c = (try? JSONSerialization.jsonObject(with: Data((last.content.isEmpty ? "{}" : last.content).utf8))) as? [String: Any] ?? [:]
        let vis = c["visibility"] as? String
        let members = vis == "members" || (vis == nil && c["list"] as? String == "own")
        let posts = (c["posts"] as? String).flatMap { Derive.postTypes.contains($0) ? $0 : nil }
        let slug = c["slug"].map { "\($0)" } ?? ""
        return WebPage(on: (c["on"] as? Bool) ?? ((c["on"] as? Int).map { $0 != 0 } ?? false), slug: slug, visibility: members ? "members" : "public", posts: posts)
    }

    /// A public channel: its page is on and anyone on the web reads it. Everything else is members only.
    func isPublic(_ g: Group?) -> Bool {
        guard let w = webPage(g) else { return false }
        return w.on && w.visibility == "public"
    }

    /// "Public · <domain>/<slug>" or "Members only" (the line under a channel's name).
    func visibilityLine(_ g: Group?) -> String {
        guard let g, let w = webPage(g), w.on else { return "Members only" }
        let slug = w.slug.isEmpty ? g.id : w.slug
        return (w.visibility == "public" ? "Public · " : "Members only · ") + ctx.domain + "/" + slug
    }

    /// The order the belfry's admins dragged the channels into: their latest 30078
    /// d=belfry:channel-order on the community relay, content {"order": [ids]}.
    func channelOrder() -> [String] {
        let own = events.filter { $0.kind == 30078 && $0.tag("d") == Derive.orderD && communityAdmins.contains($0.pubkey) }
            .sorted(by: Derive.byTime)
        guard let last = own.last,
              let obj = (try? JSONSerialization.jsonObject(with: Data(last.content.utf8))) as? [String: Any],
              let order = obj["order"] as? [Any] else { return [] }
        return Array(order.compactMap { $0 as? String }.prefix(1000))
    }

    /// LIST in the admins' order (stable: channels it doesn't name keep their place, after).
    func inOrder(_ list: [Group], order: [String]? = nil) -> [Group] {
        let o = order ?? channelOrder()
        var at = [String: Int]()
        for (i, id) in o.enumerated() where at[id] == nil { at[id] = i }
        return list.enumerated().sorted { a, b in
            (at[a.element.id] ?? 1_000_000 + a.offset) < (at[b.element.id] ?? 1_000_000 + b.offset)
        }.map(\.element)
    }

    /// The channel list (drawer): public channels, then members-only ones, each in the admins'
    /// order; groups (pods) and proposals I am in nest under the channel they were posted in.
    func channelSections() -> (pub: [Group], members: [Group], nested: [String: [Group]], orphans: [Group]) {
        let all = groups()
        let chans = all.filter { $0.type == .channel }
        let pods = all.filter { ($0.isPod || $0.isProposal) && ($0.members.contains(me) || $0.admins.contains(me)) }
        let ids = Set(all.map(\.id))
        var nested = [String: [Group]]()
        for p in pods { if let parent = p.parent, ids.contains(parent) { nested[parent, default: []].append(p) } }
        let orphans = pods.filter { $0.parent == nil || !ids.contains($0.parent!) }
        let order = channelOrder()
        return (inOrder(chans.filter { isPublic($0) }, order: order), inOrder(chans.filter { !isPublic($0) }, order: order), nested, orphans)
    }

    /// Messages and thread replies that tag me (p) or name my npub, newest first (web mentions()).
    func mentionsOfMe(limit: Int = 100) -> [NostrEvent] {
        guard !me.isEmpty else { return [] }
        let npub = Bech32.npub(me).map { "nostr:" + $0 }
        var seen = Set<String>()
        var out = [NostrEvent]()
        for e in events where (e.kind == 9 || e.kind == 1111) && e.pubkey != me && e.tag("h") != nil && !seen.contains(e.id) {
            seen.insert(e.id)
            if let h = e.tag("h"), isDeleted(h) { continue } // a deleted group is in no list
            if e.tags.contains(where: { $0.count > 1 && $0[0] == "p" && $0[1] == me }) || (npub.map { e.content.contains($0) } ?? false) {
                out.append(e)
            }
        }
        return Array(out.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}

/// The requests to one group that I can act on.
public struct GroupRequests: Identifiable, Hashable, Sendable {
    public let group: Group
    public let list: [Application]
    public var id: String { group.id }
}

// ---- vouches (docs/membership.md "Groups that accept by vouches") ------------------------------

public extension Derive {
    static let vouchNS = "belfry/vouch"

    /// Per request (the 9021's id): each author's latest vouch label ("vouch" / "withdrawn").
    func vouchLabels() -> [String: [String: (v: String, at: Int)]] {
        var out = [String: [String: (v: String, at: Int)]]()
        for e in events where e.kind == 1985 && e.tag("L") == Derive.vouchNS {
            guard let req = e.tag("e"), let v = e.tag("l") else { continue }
            var m = out[req] ?? [:]
            if let was = m[e.pubkey], was.at > e.createdAt { continue }
            m[e.pubkey] = (v, e.createdAt)
            out[req] = m
        }
        return out
    }

    /// Who vouches for application A in group G now: members of G (of the belfry: not guests or
    /// agents, where this app knows), never the applicant.
    func vouchesFor(_ g: Group, _ a: Application) -> [String] {
        guard let m = vouchLabels()[a.id] else { return [] }
        return m.filter { pk, x in x.v == "vouch" && pk != a.pubkey && g.members.contains(pk) && !isGuest(pk) && !isAgent(pk) }.map(\.key).sorted()
    }

    /// Requests to group G I can act on: all when I'm one of its admins; while it accepts by
    /// vouches, its members see them to vouch (web groupRequestsFor).
    func groupRequestsFor(_ g: Group) -> [Application] {
        guard g.closed, !g.applications.isEmpty else { return [] }
        if g.admins.contains(me) { return g.applications }
        if g.vouches > 0 && g.members.contains(me) && !isGuest(me) && !isAgent(me) { return g.applications.filter { $0.pubkey != me } }
        return []
    }

    func groupRequests() -> [GroupRequests] {
        groups().map { GroupRequests(group: $0, list: groupRequestsFor($0)) }.filter { !$0.list.isEmpty }
    }

    /// Group requests waiting for me (admins: all; vouchers: the ones I haven't vouched for).
    func groupRequestCount() -> Int {
        groupRequests().reduce(0) { n, x in
            n + (x.group.admins.contains(me) ? x.list.count : x.list.filter { !vouchesFor(x.group, $0).contains(me) }.count)
        }
    }
}

public extension Actions {
    /// A vouch (or its withdrawal) for a request to join a closed group.
    static func vouch(_ groupId: String, requestId: String, applicant: String, on: Bool = true) -> Draft {
        Draft(kind: 1985, tags: [["h", groupId], ["L", Derive.vouchNS], ["l", on ? "vouch" : "withdrawn", Derive.vouchNS], ["e", requestId], ["p", applicant]])
    }

    /// The admins' order of the channel list (30078 d=belfry:channel-order on the community relay).
    static func channelOrder(_ ids: [String]) -> Draft {
        Draft(.main, kind: 30078, content: JSON.encode(["order": Array(ids.prefix(1000))]), tags: [["d", Derive.orderD]])
    }
}
