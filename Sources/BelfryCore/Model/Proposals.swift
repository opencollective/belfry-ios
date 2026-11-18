import Foundation

// Proposals (SPEC 19.8): NIP-23 kind 30023 text on the community relay, its own chat prop-…,
// status = NIP-32 label belfry/proposal-status, vote = NIP-88 kind 1068 / 1018 per version.

public enum ProposalStatus: String, Sendable, CaseIterable {
    case draft, feedback, voting, passed, rejected, closed
    public var label: String {
        switch self {
        case .draft: return "Draft"
        case .feedback: return "Open for feedback"
        case .voting: return "Open for votes"
        case .passed: return "Passed"
        case .rejected: return "Rejected"
        case .closed: return "Closed"
        }
    }
    public var isOpen: Bool { self == .draft || self == .feedback || self == .voting }
}

public struct Poll: Hashable, Sendable {
    public let ev: NostrEvent
    public let version: Int
    /// pubkey → option id ("yes", "no", "abstain")
    public let votes: [String: String]

    /// The choices this poll really has (its NIP-88 `option` tags, in order); the three default
    /// ones when it names none.
    public var options: [(id: String, label: String)] {
        var out = [(id: String, label: String)]()
        for t in ev.tags where t.count >= 2 && t[0] == "option" && !t[1].isEmpty && !out.contains(where: { $0.id == t[1] }) {
            out.append((t[1], t.count > 2 && !t[2].isEmpty ? t[2] : t[1]))
        }
        return out.isEmpty ? Proposal.voteOptions : out
    }
}

/// The address of a website version's preview (web previewLink): preview.<domain>/p/<npub>[@name].
public func websitePreviewLink(_ ref: String, domain: String) -> String? {
    guard let m = Rx("^nsite:(npub1[02-9ac-hj-np-z]{58})(?:/([a-z0-9-]{1,13}))?$").first(ref), let npub = m[1] else { return nil }
    return "https://preview.\(domain)/p/\(npub)" + (m[2].map { "@" + $0 } ?? "")
}

public struct Proposal: Hashable, Sendable, Identifiable {
    public let coord: String
    public let d: String
    public let ev: NostrEvent
    public let author: String
    public let groupId: String
    public let title: String
    public let summary: String
    public let text: String
    public let version: Int
    public let status: ProposalStatus
    public let poll: Poll?
    /// A new version of the website (its nsite ref), live once a belfry admin marks it Passed.
    public var website: String? = nil

    public var id: String { coord }
    public static let voteOptions: [(id: String, label: String)] = [("yes", "Yes"), ("no", "No"), ("abstain", "Abstain")]

    /// option id → count
    public var tally: [String: Int] {
        var out = [String: Int]()
        for v in (poll?.votes ?? [:]).values { out[v, default: 0] += 1 }
        return out
    }

    /// The choices to vote on: the current poll's own options (Yes / No / Abstain by default).
    public var options: [(id: String, label: String)] { poll?.options ?? Proposal.voteOptions }

    /// Votes are open on the current version.
    public var votingNow: Bool { status == .voting && poll != nil && poll!.version == version }
}

extension Derive {
    func computeProposals() -> [Proposal] {
        var latest = [String: NostrEvent](), order = [String]()
        for e in ofKind(30023) where e.hasTag("t", "proposal") {
            let coord = "30023:\(e.pubkey):\(e.tag("d") ?? "")"
            if let prev = latest[coord], !Derive.byTime(prev, e) { continue }
            if latest[coord] == nil { order.append(coord) }
            latest[coord] = e
        }
        let del = deleted()
        var out = [Proposal]()
        for coord in order {
            let e = latest[coord]!
            if del.contains(coord) { continue }
            let groupId = e.tag("h") ?? ""
            let g = group(groupId)
            let parent = g?.parent.flatMap { group($0) }
            func may(_ pk: String) -> Bool { pk == e.pubkey || (g?.admins.contains(pk) ?? false) || (parent?.admins.contains(pk) ?? false) }
            var status = ProposalStatus(rawValue: e.tag("status") ?? "") ?? .draft
            var statusAt = 0
            var pollEv: NostrEvent?
            for x in inGroup(groupId) {
                if x.kind == 1985, x.tag("L") == Derive.proposalNS, may(x.pubkey), x.createdAt >= statusAt,
                   let l = ProposalStatus(rawValue: x.tags.first(where: { $0.count >= 3 && $0[0] == "l" && $0[2] == Derive.proposalNS })?[1] ?? "") {
                    status = l
                    statusAt = x.createdAt
                }
                if x.kind == 1068, x.tag("a") == coord, pollEv == nil || Derive.byTime(pollEv!, x) { pollEv = x }
            }
            var poll: Poll?
            if let p = pollEv {
                var votes = [String: String](), at = [String: Int]()
                for x in ofKind(1018) where x.tag("e") == p.id {
                    if (at[x.pubkey] ?? -1) > x.createdAt { continue }
                    if let r = x.tag("response"), !r.isEmpty { votes[x.pubkey] = r; at[x.pubkey] = x.createdAt }
                }
                let v = Int(p.tag("version") ?? "") ?? 0
                poll = Poll(ev: p, version: v == 0 ? 1 : v, votes: votes)
            }
            let version = Int(e.tag("version") ?? "") ?? 0
            let title = e.tag("title") ?? ""
            out.append(Proposal(coord: coord, d: e.tag("d") ?? "", ev: e, author: e.pubkey, groupId: groupId,
                                title: title.isEmpty ? "Untitled proposal" : title, summary: e.tag("summary") ?? "", text: e.content,
                                version: version == 0 ? 1 : version, status: status, poll: poll,
                                website: e.tag("website").flatMap { $0.isEmpty ? nil : $0 }))
        }
        return out
    }

    /// The proposal whose chat this group is.
    public func proposalFor(_ groupId: String) -> Proposal? { proposals.first { $0.groupId == groupId } }

    public func proposalsIn(_ parent: String) -> [Proposal] { proposals.filter { group($0.groupId)?.parent == parent } }

    /// Who may change a proposal's status: its author and the admins of its chat or its parent.
    public func canDecide(_ p: Proposal) -> Bool {
        let g = group(p.groupId)
        let parent = g?.parent.flatMap { group($0) }
        return me == p.author || (g?.admins.contains(me) ?? false) || (parent?.admins.contains(me) ?? false)
    }

    public func myVote(_ p: Proposal) -> String? { p.poll?.votes[me] }
    public func needsMyVote(_ p: Proposal) -> Bool { p.votingNow && p.poll?.votes[me] == nil }

    /// "X of Y members have" voted (SPEC 19.39): X = votes on the current poll, Y = the members
    /// of the channel the proposal was made in (its parent; the proposal's own chat when it has
    /// none), counting the voters too; nil Y when that list is unknown (empty).
    public func voteTurnout(_ p: Proposal) -> (voted: Int, of: Int?) {
        let voters = Set((p.poll?.votes ?? [:]).keys)
        let g = group(p.groupId)
        let base = g?.parent.flatMap { group($0) } ?? g
        let members = (base?.members ?? []).filter { !isGuest($0) && !isAgent($0) }
        if members.isEmpty { return (voters.count, nil) }
        return (voters.count, members.union(voters).count)
    }
}
