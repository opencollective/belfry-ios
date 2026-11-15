import Foundation
import XCTest
@testable import BelfryCore

/// Offline first (CLAUDE.md): opening a channel is drawn from the local log in the same frame.
/// A log of ~20 000 events; budgets are generous for CI machines but real.
final class PerformanceTests: XCTestCase {
    static func bigLog(me: String) -> [NostrEvent] {
        var out = [NostrEvent]()
        var n = 0
        func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
            n += 1
            return NostrEvent(id: String(format: "%064x", n), pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
        }
        let relay = String(repeating: "f", count: 64)
        let people = (0..<50).map { String(format: "%062x%02x", 7, $0) } + [me]
        for p in people { out.append(ev(p, 0, 1000, [], "{\"name\":\"Person \(p.suffix(2))\"}")) }
        let base = 1_760_000_000
        for c in 0..<12 {
            let g = "channel-\(c)"
            out.append(ev(relay, 39000, base, [["d", g], ["name", g]]))
            out.append(ev(relay, 39001, base, [["d", g], ["p", people[0], "admin"]]))
            out.append(ev(relay, 39002, base, [["d", g]] + people.map { ["p", $0] }))
            var last = [String]()
            for i in 0..<1250 {
                let at = base + c * 10 + i * 60
                let m = ev(people[i % people.count], 9, at, [["h", g]], "Message \(i) in #\(g) with some words and nostr:npub1 mentions #topic\(i % 7)")
                out.append(m)
                last.append(m.id)
                if i % 5 == 0 { out.append(ev(people[(i + 1) % people.count], 7, at + 5, [["h", g], ["e", m.id], ["p", m.pubkey], ["k", "9"]], "👍")) }
                if i % 9 == 0 { out.append(ev(people[(i + 2) % people.count], 1111, at + 9, [["h", g], ["E", m.id], ["e", m.id], ["K", "9"], ["k", "9"], ["P", m.pubkey]], "A reply")) }
            }
        }
        return out
    }

    func time(_ label: String, _ f: () -> Void) -> Double {
        let t = Date()
        f()
        let ms = Date().timeIntervalSince(t) * 1000
        print("perf: \(label) \(Int(ms)) ms")
        return ms
    }

    func testOpeningAChannelIsQuick() {
        let me = String(repeating: "a", count: 64)
        let log = PerformanceTests.bigLog(me: me)
        XCTAssertGreaterThan(log.count, 19_000)
        print("perf: \(log.count) events")
        // a fresh snapshot (after any change of the log) and the first channel opened on it
        var d = Derive(events: log, me: me)
        let first = time("snapshot + groups + feedRows(channel-3)") {
            _ = d.groups()
            _ = d.feedRows("channel-3")
        }
        // another channel on the same snapshot
        let second = time("feedRows(channel-7) on the same snapshot") { _ = d.feedRows("channel-7") }
        // the drawer: sections, unread counts, mentions
        let drawer = time("drawer (sections, mentions, unread)") {
            _ = d.channelSections()
            _ = d.mentionsOfMe()
            for g in d.groups() { _ = d.unreadIn(g.id, .empty, now: Int.now) }
        }
        d = Derive(events: log + [NostrEvent(id: String(repeating: "e", count: 64), pubkey: me, createdAt: Int.now, kind: 9, tags: [["h", "channel-3"]], content: "new")], me: me)
        let after = time("a new message arrives: snapshot + feedRows(channel-3)") { _ = d.feedRows("channel-3") }
        XCTAssertLessThan(second, 150, "another channel on the same snapshot")
        XCTAssertLessThan(first, 1500, "first channel on a fresh snapshot")
        XCTAssertLessThan(after, 1500)
        XCTAssertLessThan(drawer, 1500)
    }

    func testLoadingTheStoreIsQuick() throws {
        let me = String(repeating: "a", count: 64)
        let log = PerformanceTests.bigLog(me: me)
        let path = NSTemporaryDirectory() + "perf-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try Database(path: path)
        _ = time("store 20k events") { db.add(log) }
        var loaded = [NostrEvent]()
        let ms = time("load 20k events from disk") { loaded = db.allEvents() }
        XCTAssertEqual(loaded.count, log.count)
        XCTAssertLessThan(ms, 3000)
    }
}
