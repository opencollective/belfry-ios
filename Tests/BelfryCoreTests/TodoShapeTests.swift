import XCTest
@testable import BelfryCore

private let A = String(repeating: "a", count: 64)
private let B = String(repeating: "b", count: 64)

private func ev(_ pk: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ c: String = "") -> NostrEvent {
    NostrEvent(id: Crypto.sha256("\(pk)\(kind)\(at)\(tags)\(c)").hex, pubkey: pk, createdAt: at, kind: kind, tags: tags, content: c)
}

/// The to-do in one shape: due date (vectors/one-shape.json "due"), the author's edit, the lines.
final class TodoShapeTests: XCTestCase {
    func testDueVector() throws {
        for c in try vector("one-shape").dict("due").list("cases") {
            XCTAssertEqual(TodoDue.parse(tags(c["tags"])), c.int("expect"), c.str("name") ?? "")
        }
    }

    func testTheAuthorsEditSetsAndClearsTheDueDate() throws {
        let task = ev(A, 2100, 100, Actions.taskTags("g") + [["q", "m1"]], "Bring the cable")
        let set = Actions.setTaskDue(task, title: "Bring the cable", due: 1795100000)
        XCTAssertEqual(set.kind, 1010)
        XCTAssertEqual(set.content, "Bring the cable")
        XCTAssertEqual(set.tags, Actions.taskTags("g") + [["q", "m1"], ["e", task.id], ["k", "2100"], ["due", "1795100000"]])
        let e1 = ev(A, 1010, 110, set.tags, set.content)
        var d = Derive(events: [task, e1], me: B)
        XCTAssertEqual(d.tasks("g").first?.due, 1795100000)
        // someone else's edit counts for nothing
        let other = ev(B, 1010, 120, Actions.setTaskDue(task, title: "x", due: 5).tags, "x")
        d = Derive(events: [task, e1, other], me: B)
        XCTAssertEqual(d.tasks("g").first?.due, 1795100000)
        // an edit without a due clears it, with a line each time
        let clear = ev(A, 1010, 130, Actions.setTaskDue(task, title: "Bring the cable", due: nil).tags, "Bring the cable")
        d = Derive(events: [task, e1, other, clear], me: B)
        XCTAssertNil(d.tasks("g").first?.due)
        let dues = d.todoLines("g", task.id).compactMap { l -> Int?? in if case .due(let x) = l.what { return x } else { return nil } }
        XCTAssertEqual(dues, [1795100000, nil])
    }

    func testLinesWeaveActionsAndComments() throws {
        let task = ev(A, 2100, 100, Actions.taskTags("g"), "Fix the gate")
        let claim = ev(B, 2101, 110, [["e", task.id], ["action", "claim"]] + Actions.taskTags("g"))
        let comment = ev(A, 2103, 120, [["e", task.id]] + Actions.taskTags("g"), "Thanks")
        let done = ev(B, 2101, 130, [["e", task.id], ["action", "done"]] + Actions.taskTags("g"))
        let d = Derive(events: [task, claim, comment, done], me: A)
        XCTAssertEqual(d.todoLines("g", task.id).map(\.what), [.made(from: nil), .claimed, .comment("Thanks"), .done])
        XCTAssertEqual(d.tasks("g").first?.doneAt, 130)
    }
}
