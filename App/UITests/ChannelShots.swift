import XCTest

/// A channel: the composer's ＋ menu, a held message's menu, the keyboard.
final class ChannelShots: ShotCase {
    func testAddMenu() {
        let app = launch("composer")
        let add = app.buttons["composer-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        sleep(2)
        shot("50-add-menu")
    }

    func testMessageMenu() {
        let app = launch("feed")
        // a message row of the feed (the drawer, kept in the tree, holds the same words in a preview)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'message-row' AND label CONTAINS %@", "read it tonight"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
        // a slow simulator may still be scrolling the feed to its end (or drawing the drawer's
        // copy first): wait for a copy that is on screen instead of asserting at once
        let msg = hittable(rows, timeout: 30)
        XCTAssertNotNil(msg, "the message row is not on screen")
        guard let msg else { return }
        // hold the message's text, not the row's centre: the face and the name above it open the
        // profile on a tap (run 44411728520: the hold ended on the profile, no menu)
        msg.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8)).press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 6), "the message's menu did not open")
        sleep(1)
        shot("51-message-menu")
    }

    func testKeyboardComposer() {
        let app = launch("composer")
        let field = app.descendants(matching: .any).matching(identifier: "composer-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        answers(app, after: "focusing the composer")
        // a first tap can land while the screen settles: tap again until the keyboard is up
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        field.typeText("Hello from the demo")
        sleep(2)
        shot("53-composer-typing")
    }
}
