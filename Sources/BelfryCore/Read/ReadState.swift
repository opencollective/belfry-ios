import Foundation

// Read state across devices (SPEC 19.27; web readcore.ts, Android core/read/ReadState.kt): what a
// person has read up to when, per channel (`c`), thread (`t`) and direct-message conversation
// (`d`), plus the start `s` and the @Mentions mark `m`. One kind 30078 `d` = belfry:read per
// person, NIP-44 to oneself, on the community relay; merged highest-wins. vectors/readstate.json.
// Every number = read up to and including that unix second.

public struct ReadState: Equatable, Sendable {
    public var s: Int = 0
    public var m: Int = 0
    public var c: [String: Int] = [:]
    public var t: [String: Int] = [:]
    public var d: [String: Int] = [:]
    /// Fields a newer client wrote, kept as they are (their JSON text).
    public var extra: [String: String] = [:]

    public init(s: Int = 0, m: Int = 0, c: [String: Int] = [:], t: [String: Int] = [:], d: [String: Int] = [:], extra: [String: String] = [:]) {
        self.s = s; self.m = m; self.c = c; self.t = t; self.d = d; self.extra = extra
    }

    public static let readD = "belfry:read"
    public static let kind = 30078
    public static let day = 86400
    public static let keepDays = 90
    public static let maxWeight = 40000
    public static let maxKey = 200
    public static let sections: [Character] = ["c", "t", "d"]
    static let reserved: Set<String> = ["v", "s", "m", "c", "t", "d"]
    public static let empty = ReadState()

    public func section(_ sec: Character) -> [String: Int] {
        switch sec { case "c": return c; case "t": return t; case "d": return d; default: return [:] }
    }

    mutating func setSection(_ sec: Character, _ map: [String: Int]) {
        switch sec { case "c": c = map; case "t": t = map; case "d": d = map; default: break }
    }

    static func q(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The text before encryption: unknown fields (sorted), then v s m c t d, keys sorted, no spaces.
    public func serialize() -> String {
        var out = "{"
        for k in extra.keys.sorted() where !ReadState.reserved.contains(k) {
            out += ReadState.q(k) + ":" + (extra[k] ?? "null") + ","
        }
        out += "\"v\":1,\"s\":\(s),\"m\":\(m)"
        for sec in ReadState.sections {
            let map = section(sec)
            out += ",\"\(sec)\":{" + map.keys.sorted().map { ReadState.q($0) + ":\(map[$0]!)" }.joined(separator: ",") + "}"
        }
        return out + "}"
    }

    /// Read KEY of SEC (c, t, d or m) up to AT, never backwards.
    public func mark(_ sec: Character, _ key: String, _ at: Int) -> ReadState {
        let a = max(0, at)
        var r = self
        if sec == "m" { if a > m { r.m = a }; return r }
        guard ReadState.sections.contains(sec), a > 0, !key.isEmpty, key.utf16.count <= ReadState.maxKey, (section(sec)[key] ?? 0) < a else { return self }
        var map = section(sec)
        map[key] = a
        r.setSection(sec, map)
        return r
    }

    /// Below this everything counts as read: 90 days ago, and for c / t / m also `s`.
    public func floor(_ sec: Character, now: Int) -> Int {
        let old = now - ReadState.keepDays * ReadState.day
        return sec == "d" ? old : max(old, s)
    }

    public func readUpTo(_ sec: Character, _ key: String, now: Int) -> Int {
        let own = sec == "m" ? m : (section(sec)[key] ?? 0)
        return max(own, floor(sec, now: now))
    }

    static func weight(_ key: String) -> Int { key.utf8.count + 16 }

    /// Drop marks at or under their floor, then the oldest c / t marks while too heavy (raising s), then d.
    public func prune(now: Int) -> ReadState {
        struct E { let sec: Character; let key: String; let at: Int }
        var list = [E]()
        for sec in ReadState.sections { for (k, at) in section(sec) where at > floor(sec, now: now) { list.append(E(sec: sec, key: k, at: at)) } }
        let order: [Character: Int] = ["c": 0, "t": 1, "d": 2]
        list.sort { a, b in
            let da = a.sec == "d" ? 1 : 0, db = b.sec == "d" ? 1 : 0
            if da != db { return da < db }
            if a.at != b.at { return a.at < b.at }
            if order[a.sec]! != order[b.sec]! { return order[a.sec]! < order[b.sec]! }
            return Array(a.key.utf16).lexicographicallyPrecedes(Array(b.key.utf16))
        }
        var w = list.reduce(0) { $0 + ReadState.weight($1.key) }
        var newS = s
        var i = 0
        while w > ReadState.maxWeight && i < list.count {
            let e = list[i]; i += 1
            w -= ReadState.weight(e.key)
            if e.sec != "d" { newS = max(newS, e.at) }
        }
        var out = self
        out.s = newS
        var maps: [Character: [String: Int]] = ["c": [:], "t": [:], "d": [:]]
        for e in list[i...] where e.at > out.floor(e.sec, now: now) { maps[e.sec]![e.key] = e.at }
        out.c = maps["c"]!; out.t = maps["t"]!; out.d = maps["d"]!
        return out
    }

    static func num(_ x: Any?) -> Int {
        guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return 0 }
        let v = n.doubleValue
        guard v.isFinite, v > 0 else { return 0 }
        return Int(v.rounded(.down))
    }

    /// The decrypted content; anything unreadable is dropped, never thrown.
    public static func parse(_ json: String) -> ReadState {
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else { return .empty }
        return parse(object: o)
    }

    public static func parse(object: Any) -> ReadState {
        guard let o = object as? [String: Any] else { return .empty }
        var r = ReadState()
        for (k, v) in o {
            switch k {
            case "v": break
            case "s": r.s = num(v)
            case "m": r.m = num(v)
            case "c", "t", "d":
                var map = [String: Int]()
                for (key, at) in v as? [String: Any] ?? [:] {
                    let n = num(at)
                    if n > 0, !key.isEmpty, key.utf16.count <= maxKey { map[key] = n }
                }
                r.setSection(Character(k), map)
            default:
                if let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) {
                    r.extra[k] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        return r
    }

    /// Every number the highest of the two; unknown fields REMOTE's first.
    public static func merge(_ local: ReadState, _ remote: ReadState) -> ReadState {
        func mx(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] { a.merging(b) { max($0, $1) } }
        return ReadState(s: max(local.s, remote.s), m: max(local.m, remote.m), c: mx(local.c, remote.c), t: mx(local.t, remote.t),
                         d: mx(local.d, remote.d), extra: local.extra.merging(remote.extra) { _, r in r })
    }

    /// Does REMOTE already say everything LOCAL says? False → publish merge(local, remote).prune(now).
    public static func covers(_ remote: ReadState, _ local: ReadState, now: Int) -> Bool {
        if local.s > remote.s || local.m > max(remote.m, remote.floor("m", now: now)) { return false }
        for sec in sections {
            for (k, at) in local.section(sec) where at > local.floor(sec, now: now) && at > remote.readUpTo(sec, k, now: now) { return false }
        }
        return true
    }
}
