import Foundation

// Reactions to direct messages (SPEC 19.50 = Android 19.45; the web's dm.ts;
// vectors/dm-reactions.json copied byte for byte from belfry-android). A reaction is an unsigned
// kind 7 rumor, gift-wrapped like the message; taking it back is a wrapped kind 5 rumor naming it.

/// One chip under a bubble.
public struct DmChip: Hashable, Sendable {
    public let emoji: String
    /// Who gave it, in the order they first did.
    public let who: [String]
    /// The viewer gave it.
    public let mine: Bool
}

/// What this phone has read of reactions: the reactions by their rumor id, and the kind 5s read
/// (wraps come in any order: a kind 5 read before its reaction still takes it back).
public struct DmReactions: Codable, Hashable, Sendable {
    public struct One: Codable, Hashable, Sendable {
        public let target: String
        public let author: String
        public let emoji: String
        public let at: Int
    }
    public private(set) var reactions = [String: One]()
    /// A kind 5's target → who sent one for it.
    public private(set) var takenBack = [String: [String]]()

    public init() {}

    /// A rumor of kind 7 or 5; true when it was one of these (it is never a message).
    @discardableResult
    public mutating func apply(_ rumor: NostrEvent) -> Bool {
        if rumor.kind == 7 {
            // readers key on the last e tag
            guard let target = rumor.tags.last(where: { $0.first == "e" && $0.count > 1 })?[1] else { return true }
            let raw = rumor.content
            let emoji = raw.isEmpty || raw == "+" ? "👍" : raw
            guard emoji.utf16.count <= 16 else { return true }
            if takenBack[rumor.id]?.contains(rumor.pubkey) == true { return true }
            reactions[rumor.id] = One(target: target, author: rumor.pubkey, emoji: emoji, at: rumor.createdAt)
            return true
        }
        if rumor.kind == 5 {
            for t in rumor.tags where t.first == "e" && t.count > 1 {
                let id = t[1]
                // it counts only from the reaction's author
                if let r = reactions[id] { if r.author == rumor.pubkey { reactions[id] = nil } else { continue } }
                if takenBack[id]?.contains(rumor.pubkey) != true { takenBack[id, default: []].append(rumor.pubkey) }
            }
            return true
        }
        return false
    }

    /// The chips of message TARGET for VIEWER: one per person per emoji; by count, most first
    /// (ties: first given first); who in the order they first gave it.
    public func chips(_ target: String, viewer: String) -> [DmChip] {
        let list = reactions.filter { $0.value.target == target }.sorted { a, b in a.value.at != b.value.at ? a.value.at < b.value.at : a.key < b.key }
        var order = [String]()
        var who = [String: [String]]()
        for (_, r) in list {
            if who[r.emoji] == nil { order.append(r.emoji) }
            if who[r.emoji]?.contains(r.author) != true { who[r.emoji, default: []].append(r.author) }
        }
        let ranked = order.enumerated().sorted { a, b in
            let ca = who[a.element]!.count, cb = who[b.element]!.count
            return ca != cb ? ca > cb : a.offset < b.offset
        }
        return ranked.map { DmChip(emoji: $0.element, who: who[$0.element]!, mine: who[$0.element]!.contains(viewer)) }
    }

    /// The viewer's reaction rumor with EMOJI on TARGET, if any (to take it back).
    public func mine(_ target: String, emoji: String, viewer: String) -> String? {
        reactions.first { $0.value.target == target && $0.value.author == viewer && $0.value.emoji == emoji }?.key
    }

    /// The rumor's tags for adding EMOJI to the message (its id, its author, everyone in the
    /// conversation): `e` with the author, `p` the author, `k` 14, then `p` for the others.
    public static func addTags(message: String, author: String, participants: [String], me: String) -> [Tag] {
        [["e", message, "", author], ["p", author], ["k", "14"]] + participants.filter { $0 != author && $0 != me }.map { ["p", $0] }
    }

    /// The rumor's tags for taking reaction REACTION back.
    public static func removeTags(reaction: String, participants: [String], me: String) -> [Tag] {
        [["e", reaction], ["k", "7"]] + participants.filter { $0 != me }.map { ["p", $0] }
    }
}
