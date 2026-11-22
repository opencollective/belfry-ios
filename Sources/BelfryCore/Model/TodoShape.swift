import Foundation

// The to-do in one shape (canvas one-shape/todo-*, 2026-11-22; wire: docs/one-shape.md §3).
// Due date: ["due", "<unix seconds>"] on the kind 2100; the author's newest kind 1010 edit
// replaces the tags (its due wins; an edit without one clears it). Shown first in the pull-down,
// never in the header. The conversation weaves in quiet lines: made, took it, assigned, done,
// reopened, set the due date.

public enum TodoDue {
    /// A positive integer `due` tag, else nil.
    public static func parse(_ tags: [Tag]) -> Int? {
        guard let t = tags.first(where: { $0.count >= 2 && $0[0] == "due" }), let n = Int(t[1]), n > 0 else { return nil }
        return n
    }

    public static let descriptionLimit = 2000

    /// The ["description", Markdown] tag, trimmed, ≤ 2000 units; empty = none.
    public static func description(_ tags: [Tag]) -> String? {
        guard let t = tags.first(where: { $0.count >= 2 && $0[0] == "description" }) else { return nil }
        let s = t[1].jsTrim().sliceUnits(descriptionLimit)
        return s.isEmpty ? nil : s
    }

    /// The description shown (vectors/one-shape.json "description"): the tag, else SOURCE (the
    /// message it was made from) trimmed, when not empty and not exactly the trimmed TITLE.
    public static func resolve(tags: [Tag], title: String, source: String?) -> String? {
        if let d = description(tags) { return d }
        guard let src = source?.jsTrim(), !src.isEmpty, src != title.jsTrim() else { return nil }
        return src
    }
}

/// One quiet line in a to-do's conversation, or a comment.
public struct TodoEntry: Hashable, Sendable, Identifiable {
    public enum What: Hashable, Sendable {
        case made(from: String?)          // the author of the message it was made from
        case claimed
        case assigned(to: String)
        case unassigned(who: String)
        case letGo
        case done
        case reopened
        case due(Int?)
        case comment(String)
    }
    public let id: String
    public let author: String
    public let at: Int
    public let what: What
}

public extension Derive {
    /// The author's newest kind 1010 edit per to-do id (among IDS).
    func todoEdits(_ ids: Set<String>) -> [String: NostrEvent] {
        guard !ids.isEmpty else { return [:] }
        var authorOf = [String: String]()
        for e in ofKind(2100) where ids.contains(e.id) { authorOf[e.id] = e.pubkey }
        var out = [String: NostrEvent]()
        for e in ofKind(Derive.editKind) {
            guard let id = e.tag("e"), ids.contains(id), authorOf[id] == e.pubkey, !isDeleted(e.id) else { continue }
            if let had = out[id], !(had.createdAt < e.createdAt || (had.createdAt == e.createdAt && had.id < e.id)) { continue }
            out[id] = e
        }
        return out
    }

    /// The to-do's own 2100 event.
    func todoEvent(_ taskId: String) -> NostrEvent? { ofKind(2100).first { $0.id == taskId } }

    /// The to-do's conversation, oldest first: the quiet lines and its comments.
    func todoLines(_ groupId: String, _ taskId: String) -> [TodoEntry] {
        guard let t = tasks(groupId).first(where: { $0.id == taskId }) else { return [] }
        let listId = Derive.listIdFor(groupId)
        var out = [TodoEntry]()
        let fromAuthor = t.source.flatMap { message(groupId, $0)?.ev.pubkey }
        out.append(TodoEntry(id: t.id, author: t.author, at: t.madeAt, what: .made(from: fromAuthor)))
        for e in inGroupSorted(groupId) where (e.kind == 2101 || e.kind == 2103) && e.tag("e") == taskId && e.tag("t") == listId {
            if e.kind == 2103 {
                out.append(TodoEntry(id: e.id, author: e.pubkey, at: e.createdAt, what: .comment(e.content.sliceUnits(2000))))
                continue
            }
            let w: TodoEntry.What?
            switch e.tag("action") ?? "" {
            case "claim": w = .claimed
            case "unclaim": w = .letGo
            case "assign": w = e.tag("p").flatMap { isHex64($0) ? TodoEntry.What.assigned(to: $0) : nil }
            case "unassign": w = e.tag("p").map { .unassigned(who: $0) }
            case "done": w = .done
            case "undone": w = .reopened
            default: w = nil
            }
            if let w { out.append(TodoEntry(id: e.id, author: e.pubkey, at: e.createdAt, what: w)) }
        }
        // each author edit that changed the due date
        var last = todoEvent(taskId).flatMap { TodoDue.parse($0.tags) }
        let edits = ofKind(Derive.editKind).filter { $0.tag("e") == taskId && $0.pubkey == t.author && !isDeleted($0.id) }
            .sorted(by: Derive.byTime)
        for e in edits {
            let due = TodoDue.parse(e.tags)
            if due != last { out.append(TodoEntry(id: e.id, author: e.pubkey, at: e.createdAt, what: .due(due))) }
            last = due
        }
        return out.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    /// The to-do's tags as they stand: its author's newest 1010 edit (without its own e / k), else the 2100's.
    func todoCurrentTags(_ taskId: String) -> [Tag] {
        if let e = todoEdits([taskId])[taskId] {
            var dropped = Set<String>()
            return e.tags.filter { t in
                guard let k = t.first, k == "e" || k == "k", !dropped.contains(k) else { return true }
                dropped.insert(k); return false
            }
        }
        return todoEvent(taskId)?.tags ?? []
    }

    /// What the to-do says beyond its title: its description, else the text of the message it was
    /// made from, when that says more than the title.
    func todoDescription(_ groupId: String, _ t: TodoTask) -> String? {
        let src = t.source.flatMap { message(groupId, $0) }.map { plainRefs($0.text, npub: "", links: false) }
        return TodoDue.resolve(tags: t.about.map { [["description", $0]] } ?? [], title: t.title, source: src)
    }
}

public extension Actions {
    /// The author edits the to-do: a kind 1010 naming the 2100 with its text, CURRENT tags (as
    /// they stand) kept except `due` and `description`, then the new ones (nil = none).
    static func editTask(_ task: NostrEvent, current: [Tag], title: String, due: Int?, description: String?) -> Draft {
        let kept = current.filter { $0.first != "due" && $0.first != "description" }
        let about = description.map { $0.jsTrim().sliceUnits(TodoDue.descriptionLimit) }.flatMap { $0.isEmpty ? nil : $0 }
        let tags: [Tag] = kept + [["e", task.id], ["k", "2100"]] + (due.map { [["due", String($0)]] } ?? [])
            + (about.map { [["description", $0]] } ?? [])
        return Draft(kind: Derive.editKind, content: title, tags: tags)
    }

    /// The due date only (the description as it stands is kept when it is in CURRENT).
    static func setTaskDue(_ task: NostrEvent, title: String, due: Int?, current: [Tag]? = nil) -> Draft {
        let cur = current ?? task.tags
        return editTask(task, current: cur, title: title, due: due, description: TodoDue.description(cur))
    }
}
