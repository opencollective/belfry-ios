import Foundation

// One shape's e-mail thread (collective-belfry docs/one-shape.md §4; vectors/one-shape.json
// sections replyAll, threadState, drafts): Reply all is the only reply, Answered is automatic,
// internal drafts.

public enum MailReplyAll {
    public static let maxRecipients = 20

    public struct Recipients: Equatable, Sendable {
        public var rcptTo: [String]
        public var to: String?
        public var cc: [String]
    }

    /// Is ADDRESS at the belfry's own DOMAIN (the domain or any host under it)?
    public static func isOwn(_ address: String, domain: String) -> Bool {
        let d = domain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !d.isEmpty, let at = address.lastIndex(of: "@") else { return false }
        let host = address[address.index(after: at)...].lowercased()
        return host == d || host.hasSuffix("." + d)
    }

    /// The sender (mail-from of the latest received e-mail), then each ["to"…], then each ["cc"…]
    /// of that card in tag order; trimmed, lowercased, ours left out, duplicates keep the first,
    /// at most 20. To = the first, Cc = the rest.
    public static func recipients(mailFrom: String, tags: [Tag], domain: String) -> Recipients {
        var out = [String]()
        func add(_ a: String) {
            let x = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !x.isEmpty, x.contains("@"), !isOwn(x, domain: domain), !out.contains(x), out.count < maxRecipients else { return }
            out.append(x)
        }
        add(mailFrom)
        for t in tags where t.count >= 2 && t[0] == "to" { add(t[1]) }
        for t in tags where t.count >= 2 && t[0] == "cc" { add(t[1]) }
        return Recipients(rcptTo: out, to: out.first, cc: Array(out.dropFirst()))
    }
}

public enum MailThreadState {
    public struct Label: Sendable { public let id: String; public let at: Int; public let value: String
        public init(id: String, at: Int, value: String) { self.id = id; self.at = at; self.value = value } }

    /// open | answered | closed: the newest label's value (ties: the higher id), open with none;
    /// open again when the newest received e-mail is newer than the newest answered or closed label.
    public static func state(received: [Int], labels: [Label]) -> String {
        let status = labels.filter { ["open", "answered", "closed"].contains($0.value) }
        guard let newest = status.max(by: { ($0.at, $0.id) < ($1.at, $1.id) }) else { return "open" }
        let settled = status.filter { $0.value != "open" }.map(\.at).max()
        if let settled, let last = received.max(), last > settled { return "open" }
        return newest.value
    }
}

public enum MailDrafts {
    public static let tag = "mail-draft"

    public struct Draft: Sendable { public let id: String; public let pubkey: String
        public init(id: String, pubkey: String) { self.id = id; self.pubkey = pubkey } }

    /// The drafts still shown: not named by a sent card's ["draft", id], not deleted by their author.
    public static func visible(_ drafts: [Draft], sentTags: [[Tag]], deletions: [(pubkey: String, e: String)]) -> [String] {
        var sent = Set<String>()
        for tags in sentTags { for t in tags where t.count >= 2 && t[0] == "draft" { sent.insert(t[1]) } }
        return drafts.filter { d in !sent.contains(d.id) && !deletions.contains { $0.pubkey == d.pubkey && $0.e == d.id } }.map(\.id)
    }

    public static func isDraft(_ e: NostrEvent) -> Bool { e.kind == 1111 && e.hasTag(tag, "1") }
}

/// Who an e-mail was for (["to"/"cc", address, name] on the inbox and sent cards).
public struct MailParty: Hashable, Sendable {
    public let address: String
    public let name: String
    public var shown: String { name.isEmpty ? address : name }
}

public extension MailItem {
    func parties(_ kind: String) -> [MailParty] {
        m.ev.tags.filter { $0.count >= 2 && $0[0] == kind }.map { MailParty(address: $0[1].lowercased(), name: $0.count >= 3 ? $0[2] : "") }
    }
    var toList: [MailParty] { parties("to") }
    var ccList: [MailParty] { parties("cc") }
    /// The draft a sent card came from.
    var draftId: String? { m.ev.tag("draft").flatMap { $0.isEmpty ? nil : $0 } }
}

public extension InboxThread {
    /// Reply all: who it goes to (old cards without to/cc: the sender only).
    func replyAll(domain: String) -> MailReplyAll.Recipients {
        guard let li = lastIn else { return .init(rcptTo: [], to: nil, cc: []) }
        return MailReplyAll.recipients(mailFrom: li.address, tags: li.m.ev.tags, domain: domain)
    }
}

extension Derive {
    /// The internal drafts of a thread still shown (kind 1111 on its first card, mail-draft), oldest first.
    public func mailDrafts(_ groupId: String, _ t: InboxThread) -> [Message] {
        let all = threadReplies(groupId, t.id).filter { MailDrafts.isDraft($0.ev) }
        let sent = t.mails.filter { $0.dir == .outgoing }.map { $0.m.ev.tags }
        let keep = Set(MailDrafts.visible(all.map { .init(id: $0.id, pubkey: $0.ev.pubkey) }, sentTags: sent, deletions: []))
        return all.filter { keep.contains($0.id) }
    }

    /// The thread's activity lines: who took it, Marked answered, Closed, Reopened (labels).
    public func mailActivity(_ groupId: String, _ t: InboxThread) -> [MailActivity] {
        let ids = Set(t.ids)
        return inGroupSorted(groupId).filter { e in
            e.kind == 1985 && !deleted().contains(e.id) && ids.contains(e.tag("e") ?? "")
                && e.tags.contains { $0.count >= 2 && $0[0] == "L" && $0[1] == Derive.inboxNS }
        }.compactMap { e in
            guard let v = e.tags.first(where: { $0.count >= 3 && $0[0] == "l" && $0[2] == Derive.inboxNS })?[1] else { return nil }
            return MailActivity(id: e.id, at: e.createdAt, by: e.pubkey, value: v, assignee: e.tag("p").flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

public struct MailActivity: Hashable, Sendable, Identifiable {
    public let id: String
    public let at: Int
    public let by: String
    /// open, answered, closed, assigned
    public let value: String
    public let assignee: String?
}

public extension Actions {
    /// Answered (one-shape.md §4): set by the app that sent the reply, after the delivered report.
    static func markAnswered(_ group: String, card: String) -> Draft {
        Draft(kind: 1985, tags: [["h", group], ["L", Derive.inboxNS], ["l", "answered", Derive.inboxNS], ["e", card]])
    }

    /// An internal draft: a kind 1111 on the thread's first card with ["mail-draft", "1"].
    static func mailDraft(_ group: String, card: NostrEvent, text: String) -> Draft {
        var d = postThreadReply(group, rootId: card.id, rootPubkey: card.pubkey, rootKind: card.kind, text: text)
        d.tags.append([MailDrafts.tag, "1"])
        return d
    }
}
