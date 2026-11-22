import XCTest

/// Direct messages.
final class DmShots: ShotCase {
    /// One shape (boards one-shape/dm-actions, dm-thread): holding a direct message gives Reply ·
    /// Copy text (no to-do, no Pin in a DM this build); Reply opens the message's thread.
    func testDmMenu() {
        let app = launch("conversation")
        // the conversation itself, not its row in the list (whose line holds the same words: a
        // press on the row only opened the conversation)
        XCTAssertTrue(app.descendants(matching: .any)["dm-header"].firstMatch.waitForExistence(timeout: 20), "the conversation did not open")
        sleep(1)
        let msgs = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "new phone"))
        XCTAssertTrue(msgs.firstMatch.waitForExistence(timeout: 20), "the conversation has no such message")
        let msg = hittable(msgs, timeout: 20)
        XCTAssertNotNil(msg, "the message is not on screen")
        guard let msg else { return }
        msg.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 6), "the message's menu has no Reply")
        XCTAssertFalse(app.buttons["Make a to-do"].exists, "a DM's menu offers a to-do")
        XCTAssertFalse(app.buttons["Pin"].exists, "a DM's menu offers Pin")
        sleep(1)
        shot("58-dm-menu")
        app.buttons["Reply"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dm-thread-field"].firstMatch.waitForExistence(timeout: 8), "Reply did not open the thread")
        sleep(1)
        shot("59-dm-thread-new")
    }
}
