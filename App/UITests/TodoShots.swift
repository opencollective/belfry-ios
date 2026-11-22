import XCTest

/// To-dos.
final class TodoShots: ShotCase {
    /// Round 7, in one shape (2026-11-22): a to-do row opens its own screen (not the tick); ••• →
    /// Assign to… puts it on someone (the header's row names them), ••• → Unassign takes it off
    /// again ("Unassigned"), and ••• then offers Claim it.
    func testTodoAssign() {
        let app = launch("todos")
        let row = app.buttons["todo-open"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no to-do row")
        row.tap()
        let more = app.buttons["todo-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the to-do's screen did not open")
        shot("58-todo")
        more.tap()
        let assign = app.buttons["Assign to…"].firstMatch
        XCTAssertTrue(assign.waitForExistence(timeout: 5), "no Assign to… in •••")
        assign.tap()
        let person = app.buttons.matching(identifier: "assign-person").element(boundBy: 1)
        XCTAssertTrue(person.waitForExistence(timeout: 5), "no one to assign")
        shot("58-todo-assign")
        person.tap()
        let header = app.buttons["todo-header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "no header after assigning")
        expectation(for: NSPredicate(format: "NOT (label CONTAINS 'Unassigned')"), evaluatedWith: header)
        waitForExpectations(timeout: 8)
        more.tap()
        let unassign = app.buttons["Unassign"].firstMatch
        XCTAssertTrue(unassign.waitForExistence(timeout: 5), "assigning did not offer Unassign")
        unassign.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Unassigned'"), evaluatedWith: header)
        waitForExpectations(timeout: 8)
        more.tap()
        XCTAssertTrue(app.buttons["Claim it"].firstMatch.waitForExistence(timeout: 5))
    }
}
