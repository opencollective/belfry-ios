import Foundation

// Channel references (SPEC 19.14; the web chat's model.ts channelRef / channelOfNaddr / plainRefs,
// belfry-chat 4d5682d). A channel picked after "#" in the composer is written as `nostr:naddr1…`
// (kind 39000, the group's metadata, by the relay's key, d = group id, the groups relay as hint)
// and shown as "#name" that opens the channel. A "#word" typed by hand stays a topic.

public enum ChannelRefs {
    public static let kind = 39000
    /// A reference in a text; group 1 = the bare naddr.
    public static let naddrRx = Rx("nostr:(naddr1[02-9ac-hj-np-z]{20,400})")
    static let npubLoose = Rx("nostr:npub1[02-9ac-hj-np-z]+")
    static let picker = Rx("(^|[^\\p{L}\\p{N}_&/])#([\\p{L}\\p{N}_-]{0,30})$")

    /// The group id an naddr (without `nostr:`) points to, if it is a NIP-29 group's metadata.
    public static func groupOf(_ naddr: String) -> String? {
        guard let a = Nip19.decodeNaddr(naddr), a.kind == kind else { return nil }
        return a.identifier
    }

    /// The query of an open # picker, given the text before the caret; nil when none is open.
    public static func query(beforeCaret: String) -> String? { picker.first(beforeCaret)?[2] }

    /// The text as sent: each picked "#Name" (longest first) → its `nostr:naddr…`.
    /// Several picks may share a label (two references to channels whose names are unknown, both
    /// "#channel"): their occurrences take the refs in order, the last ref for any extra one.
    public static func substitute(_ text: String, picked: [(label: String, ref: String)]) -> String {
        var out = text
        var labels = [String](), refs = [String: [String]]()
        for p in picked {
            if refs[p.label] == nil { labels.append(p.label) }
            if !(refs[p.label] ?? []).contains(p.ref) { refs[p.label, default: []].append(p.ref) }
        }
        for label in labels.sorted(by: { $0.utf16.count > $1.utf16.count }) {
            let rs = refs[label]!
            let parts = out.components(separatedBy: label)
            if parts.count == 1 { continue }
            var joined = parts[0]
            for (k, part) in parts.dropFirst().enumerated() { joined += rs[min(k, rs.count - 1)] + part }
            out = joined
        }
        return out
    }

    /// Replaces every match of RE in TEXT by what F returns for it.
    static func replaceAll(_ re: Rx, in text: String, _ f: (Rx.Match) -> String) -> String {
        let ms = re.matches(text)
        if ms.isEmpty { return text }
        let ns = text as NSString
        var out = ""
        var at = 0
        for m in ms {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += f(m)
            at = m.range.location + m.range.length
        }
        out += ns.substring(from: at)
        return out
    }

    /// A channel whose name is not known in a reference: the kind's word, never the id ("#channel",
    /// "#group", "#event", "#proposal"; the lead, 2026-11-18, vectors/channel-refs.json "plain").
    /// The naddr stays behind it, so editing and sending again loses nothing.
    static func unknownLabel(_ id: String) -> String { Group.kindWord(id) }

    /// One-line previews (plainRefs): mentions as NPUB, channel references as "#name" (NAMEOF gives
    /// a known channel's name; the kind's word otherwise), other naddrs as they are.
    public static func plain(_ text: String, npub: String = "@…", nameOf: (String) -> String?) -> String {
        let noKeys = replaceAll(npubLoose, in: text) { _ in npub }
        return replaceAll(naddrRx, in: noKeys) { m in
            guard let id = groupOf(m[1] ?? "") else { return m.whole }
            return "#" + (nameOf(id).flatMap { $0.isEmpty ? nil : $0 } ?? ChannelRefs.unknownLabel(id))
        }
    }
}

/// A channel the # picker offers, with the reference a pick writes.
public struct ChannelPick: Hashable, Sendable { public let group: Group; public let ref: String }

extension Derive {
    /// "nostr:naddr1…" for a channel, or nil when its metadata hasn't been seen.
    public func channelRef(_ id: String) -> String? {
        guard let pubkey = metaAuthors[id] else { return nil }
        let relays = ctx.groupsRelay.isEmpty ? [] : [ctx.groupsRelay]
        return Nip19.naddr(Nip19.Addr(kind: ChannelRefs.kind, pubkey: pubkey, identifier: id, relays: relays)).map { "nostr:" + $0 }
    }

    /// Text for one-line previews: mentions as "@…" (or NPUB), channel references as "#name".
    public func plainRefs(_ text: String, npub: String = "@…") -> String {
        ChannelRefs.plain(text, npub: npub) { self.group($0)?.name }
    }

    /// What a channel reference shows: the channel when it is known here.
    public func channelOfRef(_ naddr: String) -> Group? { ChannelRefs.groupOf(naddr).flatMap { group($0) } }

    /// The # picker: channels (not events' chats) whose id starts with the query or whose name has
    /// a word that does; most recently active first; at most 6.
    public func channelCandidates(_ query: String, limit: Int = 6) -> [ChannelPick] {
        let q = query.lowercased()
        let words = Rx("[\\s_-]+")
        return groups()
            .filter { g in !g.isEvent && (g.id.lowercased().hasPrefix(q) || words.replace(g.name.lowercased(), with: " ").split(separator: " ").contains { $0.hasPrefix(q) }) }
            .compactMap { g in channelRef(g.id).map { ChannelPick(group: g, ref: $0) } }
            .enumerated().sorted { $0.element.group.lastActivity != $1.element.group.lastActivity ? $0.element.group.lastActivity > $1.element.group.lastActivity : $0.offset < $1.offset }
            .prefix(limit).map(\.element)
    }

    /// For editing: each reference shown again as "#Name"; returns the text and the picks to send back.
    public func unsubstituteChannels(_ text: String) -> (text: String, picked: [(label: String, ref: String)]) {
        var picked = [(label: String, ref: String)]()
        let out = ChannelRefs.replaceAll(ChannelRefs.naddrRx, in: text) { m in
            guard let id = ChannelRefs.groupOf(m[1] ?? "") else { return m.whole }
            let label = "#" + ((group(id)?.named == true ? group(id)!.name : nil) ?? ChannelRefs.unknownLabel(id))
            if !picked.contains(where: { $0.label == label && $0.ref == m.whole }) { picked.append((label, m.whole)) }
            return label
        }
        return (out, picked)
    }

    /// A bare naddr as previews name it: "#name", "#channel" for a channel whose name is unknown, else as written.
    public func refLabel(_ naddr: String) -> String {
        if let id = ChannelRefs.groupOf(naddr) { return "#" + ((group(id)?.named == true ? group(id)!.name : nil) ?? ChannelRefs.unknownLabel(id)) }
        return "nostr:" + naddr
    }
}
