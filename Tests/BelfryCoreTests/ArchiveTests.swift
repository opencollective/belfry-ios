import Foundation
import XCTest
@testable import BelfryCore

// Deleted and archived groups (SPEC 19.30, the belfry's contract of 2026-11-16).

private let ME = String(repeating: "a", count: 64)
private let ANA = String(repeating: "b", count: 64)
private let RELAY = String(repeating: "d", count: 64)
private var n = 0

private func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
    n += 1
    return NostrEvent(id: String(format: "%064x", 70000 + n), pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
}

private func meta(_ id: String, _ name: String, _ at: Int = 100) -> NostrEvent { ev(RELAY, 39000, at, [["d", id], ["name", name]]) }
private func card(_ pod: String, _ text: String, _ at: Int = 200) -> NostrEvent { ev(ANA, 9, at, [["h", "general"], ["pod", pod]], text) }

private func world(_ events: [NostrEvent], absent: [String: Int] = [:], pending: Set<String> = [], admins: Set<String> = []) -> Derive {
    Derive(events: events, context: WorldContext(me: ME, communityAdmins: admins, pending: pending, groupsAbsent: absent))
}

final class ArchiveTests: XCTestCase {
    let pod = "pod-canal-41ec"

    func testDeletedBy9008() {
        let d = world([
            meta("general", "general"), meta(pod, "Canal"),
            ev(ANA, 9007, 90, [["h", pod]]),
            card(pod, "⬡ New pod: Canal · Along the water"),
            ev(ANA, 9, 300, [["h", pod], ["p", ME]], "hello"),
            ev(ANA, 9008, 400, [["h", pod]]),
        ])
        XCTAssertEqual(d.groupState(pod), .deleted)
        XCTAssertTrue(d.isDeleted(pod))
        XCTAssertNil(d.group(pod))
        XCTAssertFalse(d.groups().contains { $0.id == pod })
        XCTAssertFalse(d.allGroups().contains { $0.id == pod })
        XCTAssertTrue(d.pods("general").isEmpty)
        XCTAssertTrue(d.channelSections().orphans.isEmpty)
        // the card stays in the parent; a mention in the deleted group is in no list
        XCTAssertEqual(d.messages("general").count, 1)
        XCTAssertTrue(d.mentionsOfMe().isEmpty)
        XCTAssertTrue(d.lockedGroups.contains(pod))
        XCTAssertEqual(d.groupState("general"), .open)
    }

    func testAbsentIsUnknownUntilTheRelayAnswered() {
        // the case of #demo on belfry.sh: a card, and nothing at all about its group
        let events = [meta("general", "general"), card(pod, "⬡ New pod: Canal")]
        let before = world(events)
        XCTAssertEqual(before.groupState(pod), .unknown)
        XCTAssertFalse(before.isDeleted(pod))
        XCTAssertEqual(before.presenceCandidates(), [pod])

        // an answer without #general proves nothing (a timeout, a relay that refused)
        XCTAssertNil(before.presenceAfter(asked: [pod], answer: []))
        // the relay answered: it has #general and no such group
        let absent = before.presenceAfter(asked: [pod], answer: [meta("general", "general")])
        XCTAssertEqual(absent, [pod: 0])
        let after = world(events, absent: absent ?? [:])
        XCTAssertEqual(after.groupState(pod), .deleted)
        XCTAssertEqual(after.groupState("general"), .open)
        // a group never asked about stays unknown
        XCTAssertEqual(after.groupState("pod-other-0000"), .unknown)
    }

    func testAbsenceWithAStaleCopyAndComingBack() {
        // this device still holds the group's metadata; the relay no longer has the group
        let events = [meta("general", "general"), meta("garden", "garden", 100), ev(ANA, 9007, 90, [["h", "garden"]]), ev(ANA, 9, 150, [["h", "garden"]], "hi")]
        let d = world(events)
        XCTAssertEqual(d.groupState("garden"), .open)
        XCTAssertEqual(d.presenceCandidates(), ["garden"])
        let absent = d.presenceAfter(asked: ["garden"], answer: [meta("general", "general")]) ?? [:]
        XCTAssertEqual(absent, ["garden": 100])
        let gone = world(events, absent: absent)
        XCTAssertEqual(gone.groupState("garden"), .deleted)
        XCTAssertFalse(gone.channelSections().members.contains { $0.id == "garden" })
        // something newer about it arrives (made again, or the answer was wrong): it is there
        let back = world(events + [meta("garden", "garden", 500)], absent: absent)
        XCTAssertEqual(back.groupState("garden"), .open)
        // and the next answer that names it clears the mark; it is asked again while marked
        XCTAssertEqual(gone.presenceCandidates(), ["garden"])
        XCTAssertEqual(gone.presenceAfter(asked: ["garden"], answer: [meta("general", "general"), meta("garden", "garden")]), [:])
        // #general is never deleted by absence
        XCTAssertEqual(world(events, absent: ["general": 999]).groupState("general"), .open)
    }

    func testAGroupIAmCreatingIsNeverAbsent() {
        let made = ev(ME, 9007, 100, [["h", pod]])
        let events = [meta("general", "general"), made, ev(ME, 9002, 100, [["h", pod], ["name", "Canal"], ["about", ""]])]
        let d = world(events, absent: [pod: 100], pending: [made.id])
        XCTAssertEqual(d.groupState(pod), .open)
        XCTAssertFalse(d.presenceCandidates().contains(pod))
    }

    func testArchivedByTheLatest9002AndUnarchive() {
        let base = [
            meta("general", "general"), meta("garden", "garden"), meta(pod, "Canal"),
            ev(ME, 9007, 90, [["h", pod]]),
            ev(ME, 9002, 95, [["h", pod], ["name", "Canal"], ["about", "Along the water"], ["closed"], ["prompt", "Why?"], ["vouches", "2"]]),
            card(pod, "⬡ New pod: Canal"),
            ev(ANA, 9, 300, [["h", pod]], "boats"),
            ev(ME, 9002, 400, [["h", pod], ["name", "Canal"], ["about", "Along the water"], ["closed"], ["prompt", "Why?"], ["vouches", "2"], ["archived", "1"]]),
        ]
        let d = world(base)
        XCTAssertEqual(d.groupState(pod), .archived)
        XCTAssertTrue(d.isArchived(pod) && d.isLocked(pod))
        // in no list, still there for a card, a link, search
        XCTAssertFalse(d.groups().contains { $0.id == pod })
        XCTAssertTrue(d.pods("general").isEmpty)
        XCTAssertTrue(d.channelCandidates("canal").isEmpty)
        XCTAssertEqual(d.group(pod)?.name, "Canal")
        XCTAssertEqual(d.archivedGroups().map(\.id), [pod])
        XCTAssertEqual(d.myArchived().map(\.id), [pod])
        XCTAssertEqual(d.search("boats").map(\.groupId), [pod])
        XCTAssertEqual(d.messages(pod).count, 1)
        XCTAssertTrue(d.mayArchive(d.group(pod)))
        XCTAssertFalse(d.mayArchive(d.group("general")))

        // a later 9002 that says nothing about it changes nothing; "0" unarchives; latest wins
        let quiet = world(base + [ev(ME, 9002, 500, [["h", pod], ["name", "Canal 2"], ["about", ""]])])
        XCTAssertEqual(quiet.groupState(pod), .archived)
        XCTAssertEqual(quiet.group(pod)?.name, "Canal 2")
        let open = world(base + [ev(ME, 9002, 600, [["h", pod], ["name", "Canal"], ["about", ""], ["archived", "0"]])])
        XCTAssertEqual(open.groupState(pod), .open)
        XCTAssertTrue(open.groups().contains { $0.id == pod })
        XCTAssertTrue(open.archivedGroups().isEmpty)
        let again = world(base + [ev(ME, 9002, 600, [["h", pod], ["archived", "0"]]), ev(ME, 9002, 700, [["h", pod], ["archived", "1"]])])
        XCTAssertEqual(again.groupState(pod), .archived)
        // #general can't be archived, whatever a 9002 says
        let g = world(base + [ev(ME, 9002, 800, [["h", "general"], ["name", "general"], ["archived", "1"]])])
        XCTAssertEqual(g.groupState("general"), .open)
    }

    func testArchiveDraftsKeepEverySetting() {
        let d = world([
            meta("general", "general"), ev(ME, 9007, 90, [["h", pod]]),
            ev(ME, 9002, 95, [["h", pod], ["name", "Canal"], ["about", "Along the water"], ["picture", "https://x/p.png"], ["closed"], ["prompt", "Why?"], ["vouches", "2"]]),
        ])
        let g = d.group(pod)!
        let on = Actions.archive(g, true)
        XCTAssertEqual(on.kind, 9002)
        XCTAssertEqual(on.tags, [["h", pod], ["name", "Canal"], ["about", "Along the water"], ["picture", "https://x/p.png"], ["closed"], ["prompt", "Why?"], ["vouches", "2"], ["archived", "1"]])
        var archived = g
        archived.archived = true
        XCTAssertEqual(Actions.archive(archived, false).tags.last, ["archived", "0"])
        // any other edit of an archived group keeps it archived; an open one says nothing
        XCTAssertEqual(Actions.groupMeta(archived, name: "Quay").tags.last, ["archived", "1"])
        XCTAssertFalse(Actions.groupMeta(g, name: "Quay").tags.contains { $0.first == "archived" })
    }

    func testNothingIsQueuedForALockedGroup() {
        let locked: Set<String> = [pod]
        XCTAssertTrue(GroupLock.refuses(Draft(kind: 9, content: "hi", tags: [["h", pod]]), locked: locked))
        XCTAssertTrue(GroupLock.refuses(Draft(kind: 7, content: "+", tags: [["h", pod], ["e", "x"]]), locked: locked))
        XCTAssertTrue(GroupLock.refuses(Draft(kind: 9002, tags: [["h", pod], ["name", "Quay"], ["archived", "1"]]), locked: locked))
        XCTAssertTrue(GroupLock.refuses(Actions.seen(pod), locked: locked))
        XCTAssertFalse(GroupLock.refuses(Draft(kind: 9002, tags: [["h", pod], ["name", "Canal"], ["archived", "0"]]), locked: locked))
        XCTAssertFalse(GroupLock.refuses(Draft(kind: 9, content: "hi", tags: [["h", "general"]]), locked: locked))
        XCTAssertFalse(GroupLock.refuses(Draft(kind: 9, content: "hi", tags: [["h", pod]]), locked: []))
    }

    func testCardNameAndQuestions() {
        XCTAssertEqual(Derive.cardName("⬡ New pod: Canal · Along the water"), "Canal")
        XCTAssertEqual(Derive.cardName("⬡ New group: Seed swap"), "Seed swap")
        XCTAssertNil(Derive.cardName("Come to the canal"))
        XCTAssertNil(Derive.cardName("⬡ New pod: "))
        let ids = (0..<150).map { "pod-\($0)" } + ["general"]
        let q = GroupPresence.questions(ids)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q[0].count, 101)
        XCTAssertEqual(q[0].first, "general")
        XCTAssertEqual(q[1].count, 51)
        XCTAssertTrue(GroupPresence.questions([]).isEmpty)
    }
}
