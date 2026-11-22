import Foundation

// Replies in a direct message (one-shape.md §3, vectors/one-shape.json "dmReply"): a kind 14 rumor
// with ["e", <root rumor id>, "", "root"], wrapped like any other 14 (sealed conversations: sealed
// like any 14). Apps show it under its root; one whose root is unknown here shows in line.

public enum DmThreads {
    public static func rootTag(_ root: String) -> Tag { ["e", root, "", "root"] }

    /// The root a rumor's tags name (the e tag marked "root"), if any.
    public static func root(_ tags: [Tag]) -> String? {
        tags.first { $0.count >= 4 && $0[0] == "e" && $0[3] == "root" && !$0[1].isEmpty }?[1]
    }

    /// LIST (oldest first) split into what the conversation shows in line and the replies under
    /// each root. A reply goes under its root when that root is in LIST and is not a reply itself;
    /// else it shows in line.
    public static func split(_ list: [Dm]) -> (main: [Dm], replies: [String: [Dm]]) {
        let roots = Set(list.filter { $0.root == nil }.map(\.rid))
        var main = [Dm](), replies = [String: [Dm]]()
        for d in list {
            if let r = d.root, r != d.rid, roots.contains(r) { replies[r, default: []].append(d) } else { main.append(d) }
        }
        return (main, replies)
    }
}
