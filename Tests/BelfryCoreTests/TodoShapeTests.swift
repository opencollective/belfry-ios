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

/// The to-do's description (the lead's ruling, docs/one-shape.md): ["description", Markdown ≤ 2000]
/// on the 2100, changed by its author's 1010 like the due date; none → the source message's text.
final class TodoDescriptionTests: XCTestCase {
    func testTagThenEditThenTheDueKeepsIt() throws {
        let task = ev(A, 2100, 100, Actions.taskTags("g") + [["description", "  Bring the **reel** "]], "Bring the cable")
        var d = Derive(events: [task], me: A)
        XCTAssertEqual(d.tasks("g").first?.about, "Bring the **reel**")
        // the author changes it; the due date set later keeps it (current tags = the edit's)
        let e1 = Actions.editTask(task, current: d.todoCurrentTags(task.id), title: task.content, due: nil, description: "From the store room")
        XCTAssertEqual(e1.tags, Actions.taskTags("g") + [["e", task.id], ["k", "2100"], ["description", "From the store room"]])
        let ev1 = ev(A, 1010, 110, e1.tags, e1.content)
        d = Derive(events: [task, ev1], me: A)
        XCTAssertEqual(d.tasks("g").first?.about, "From the store room")
        XCTAssertEqual(d.todoCurrentTags(task.id), Actions.taskTags("g") + [["description", "From the store room"]])
        let e2 = Actions.setTaskDue(task, title: task.content, due: 1795100000, current: d.todoCurrentTags(task.id))
        let ev2 = ev(A, 1010, 120, e2.tags, e2.content)
        d = Derive(events: [task, ev1, ev2], me: A)
        XCTAssertEqual(d.tasks("g").first?.about, "From the store room")
        XCTAssertEqual(d.tasks("g").first?.due, 1795100000)
        // emptied: none, and an edit by someone else counts for nothing
        let e3 = Actions.editTask(task, current: d.todoCurrentTags(task.id), title: task.content, due: 1795100000, description: "  ")
        XCTAssertFalse(e3.tags.contains { $0.first == "description" })
        let other = ev(B, 1010, 140, Actions.editTask(task, current: [], title: "x", due: nil, description: "nope").tags, "x")
        d = Derive(events: [task, ev1, ev2, ev(A, 1010, 130, e3.tags, e3.content), other], me: A)
        XCTAssertNil(d.tasks("g").first?.about)
        XCTAssertEqual(d.tasks("g").first?.due, 1795100000)
    }

    func testLimitAndFallback() throws {
        let long = String(repeating: "a", count: 2100)
        XCTAssertEqual(TodoDue.description([["description", long]])?.utf16.count, 2000)
        XCTAssertNil(TodoDue.description([["description", ""]]))
        // no description: the message it was made from, when it says more than the title
        let msg = ev(B, 9, 90, [["h", "g"]], "Bring the extension reel from the store room")
        let task = ev(A, 2100, 100, Actions.taskTags("g") + [["q", msg.id]], "Bring the reel")
        let d = Derive(events: [msg, task], me: A)
        let t = try XCTUnwrap(d.tasks("g").first)
        XCTAssertEqual(d.todoDescription("g", t), "Bring the extension reel from the store room")
        let same = ev(A, 2100, 101, Actions.taskTags("g") + [["q", msg.id]], "Bring the extension reel from the store room")
        let d2 = Derive(events: [msg, same], me: A)
        XCTAssertNil(d2.todoDescription("g", try XCTUnwrap(d2.tasks("g").first)))
    }
}

final class TodoDescriptionVectorTests: XCTestCase {
    func testVector() throws {
        for c in try vector("one-shape").dict("description").list("cases") {
            XCTAssertEqual(TodoDue.resolve(tags: tags(c["tags"]), title: c.str("title") ?? "", source: c.str("source")),
                           c.str("expect"), c.str("name") ?? "")
        }
    }
}
