import Foundation

// Regex helpers that behave like the web chat's JavaScript (UTF-16 offsets, like JS strings),
// hashtags, mentions and the composer's @ picker.

public struct Rx: @unchecked Sendable {
    public let re: NSRegularExpression
    /// Compiled patterns, kept: building an NSRegularExpression per message was a large part of
    /// opening a channel (offline first: CLAUDE.md).
    nonisolated(unsafe) private static var compiled = [String: NSRegularExpression]()
    private static let lock = NSLock()

    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        let key = "\(options.rawValue)|" + pattern
        Rx.lock.lock()
        if let r = Rx.compiled[key] { re = r; Rx.lock.unlock(); return }
        Rx.lock.unlock()
        let r = try! NSRegularExpression(pattern: pattern, options: options)
        Rx.lock.lock()
        if Rx.compiled.count > 500 { Rx.compiled.removeAll() }
        Rx.compiled[key] = r
        Rx.lock.unlock()
        re = r
    }

    public struct Match {
        public let ns: NSString
        public let result: NSTextCheckingResult
        public var range: NSRange { result.range }
        /// Group N's text, nil when it did not take part (JS undefined).
        public subscript(_ i: Int) -> String? {
            guard i < result.numberOfRanges else { return nil }
            let r = result.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        public var whole: String { ns.substring(with: result.range) }
    }

    public func matches(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { Match(ns: ns, result: $0) }
    }

    public func first(_ s: String) -> Match? {
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { Match(ns: ns, result: $0) }
    }

    public func test(_ s: String) -> Bool { first(s) != nil }

    public func replace(_ s: String, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}

public enum Topics {
    public static let hashtag = Rx("(^|[^\\p{L}\\p{N}_&/])#([\\p{L}\\p{N}_][\\p{L}\\p{N}_-]{0,48})")
    public static func norm(_ t: String) -> String {
        let l = t.lowercased()
        return l.hasPrefix("#") ? String(l.dropFirst()) : l
    }

    /// The hashtags of a text, lowercased, deduplicated, in order.
    public static func hashtags(_ text: String) -> [String] {
        var seen = Set<String>(), out = [String]()
        for m in hashtag.matches(text) {
            let t = norm(m[2] ?? "")
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}

public enum Mentions {
    public static let npubInText = Rx("nostr:(npub1[02-9ac-hj-np-z]{58})")
    public static let pickerQuery = Rx("(^|\\s)@([\\p{L}\\p{N}_.-]{0,30})$")

    /// p tags for the people a text mentions (nostr:npub…), deduplicated, first appearance first.
    public static func tags(_ text: String, skip: [String] = []) -> [Tag] {
        var seen = Set<String>(), out = [Tag]()
        for m in npubInText.matches(text) {
            guard let npub = m[1], let hex = Bech32.pubkey(npub: npub), !skip.contains(hex) else { continue }
            if seen.insert(hex).inserted { out.append(["p", hex]) }
        }
        return out
    }

    /// The query of an open @ picker, given the text before the caret; nil when none is open.
    public static func query(beforeCaret: String) -> String? {
        pickerQuery.first(beforeCaret)?[2]
    }

    /// Where the picked labels ("@OSV website agent", "#Garden") stand in TEXT, as UTF-16 ranges for
    /// the composer to mark (Xavier 2026-11-18: a name with spaces could not be told from the
    /// message). Longest labels first, never overlapping; exactly what `substitute` will replace.
    public static func ranges(in text: String, labels: [String]) -> [NSRange] {
        let ns = text as NSString
        var out = [NSRange]()
        var seen = Set<String>()
        for label in labels.sorted(by: { $0.utf16.count > $1.utf16.count }) where !label.isEmpty && seen.insert(label).inserted {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: label, options: [], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                if !out.contains(where: { NSIntersectionRange($0, r).length > 0 }) { out.append(r) }
                from = r.location + r.length
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    /// The composer's text as sent: each picked "@Name" (longest names first) → nostr:npub….
    public static func substitute(_ text: String, picked: [(name: String, pubkey: String)]) -> String {
        var out = text
        for p in picked.sorted(by: { $0.name.utf16.count > $1.name.utf16.count }) {
            guard let npub = Bech32.npub(p.pubkey) else { continue }
            out = out.components(separatedBy: "@" + p.name).joined(separator: "nostr:" + npub)
        }
        return out
    }
}

/// Folding for search: accents and case ignored.
public func fold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
}
