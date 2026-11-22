import XCTest

/// Belfry settings.
final class SettingsShots: ShotCase {
    /// Settings → Channels: the empty Tool library offers Delete, confirmed in the app; it leaves
    /// the list. The Shared kitchen (messages) offers Archive (SPEC 19.35).
    func testDeleteEmptyChannel() {
        let app = launch("settingschannels")
        let kitchen = app.buttons["channels-row-kitchen-7d10"].firstMatch
        XCTAssertTrue(kitchen.waitForExistence(timeout: 10), "no Shared kitchen row in Settings → Channels")
        kitchen.tap()
        let end = app.buttons["channel-end"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5), "no end row for the kitchen")
        // the row says "Delete or archive…" until the check answers; a slow simulator (dark run of
        // 44317206359) showed "Archive the channel" on screen while a 10 s predicate on the resolved
        // element never saw it: ask the tree afresh for the row with those words, for up to 30 s
        XCTAssertTrue(endRow(app, "Archive the channel").waitForExistence(timeout: 30), "the kitchen's row does not offer Archive")
        shot("57-channel-archive-row")
        app.buttons["Cancel"].firstMatch.tap()
        sleep(1)
        // the Tool library is at the end of Community life, below the fold of a lazy list
        let tools = app.buttons["channels-row-tools-2b8e"].firstMatch
        for _ in 0..<4 where !tools.isHittable { app.swipeUp(); sleep(1) }
        XCTAssertTrue(tools.waitForExistence(timeout: 5), "no Tool library row")
        tools.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(endRow(app, "Delete the channel").waitForExistence(timeout: 30), "the Tool library's row does not offer Delete")
        end.tap()
        let confirm = app.buttons["channel-end-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation")
        shot("57-channel-delete-confirm")
        confirm.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tools)
        waitForExpectations(timeout: 30)
    }

    /// The channel-end row of Settings → Channels whose label holds TEXT (a fresh query each time).
    private func endRow(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.buttons.matching(identifier: "channel-end").matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
