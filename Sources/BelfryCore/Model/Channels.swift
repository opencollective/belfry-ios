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
        let relayKey = events.first { $0.kind == 39000 && $0.tag("d") == g.id }?.pubkey
        let own = events.filter {
            $0.kind == 30078 && $0.tag("d") == Derive.webD + g.id && $0.tag("h") == g.id && (g.admins.contains($0.pubkey) || $0.pubkey == relayKey)
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
            if e.tags.contains(where: { $0.count > 1 && $0[0] == "p" && $0[1] == me }) || (npub.map { e.content.contains($0) } ?? false) {
                out.append(e)
            }
        }
        return Array(out.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}
