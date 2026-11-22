import XCTest

/// The bottom bar and the menu (Navigation v2).
final class NavShots: ShotCase {
    func testDrawerSwipe() {
        let app = launch("feed")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(2)
        shot("52-drawer-swipe")
    }

    /// Navigation v2 (boards nav2/drawer, 2026-11-22): the menu has Today, Messages, Mentions,
    /// Calendar, GROUPS and CHANNELS (the main channel first, then the pinned ones), and its ＋ on
    /// CHANNELS pushes Add a channel. (Categories and dragging channels left the menu.)
    func testMenuRows() {
        let app = launch("towndrawer")
        sleep(2)
        for id in ["drawer-today", "drawer-messages", "drawer-mentions", "drawer-calendar", "drawer-new-group", "drawer-add-channel"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].firstMatch.waitForExistence(timeout: 10), "the menu has no \(id)")
        }
        let general = app.descendants(matching: .any)["drawer-channel-general"].firstMatch
        let kitchen = app.descendants(matching: .any)["drawer-channel-kitchen-7d10"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 5), "the main channel is not in the menu")
        XCTAssertTrue(kitchen.exists, "the channel pinned for everyone is not in the menu")
        XCTAssertLessThan(general.frame.minY, kitchen.frame.minY, "the main channel is not first")
        shot("54-menu")
        app.descendants(matching: .any)["drawer-add-channel"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["add-channel-name"].firstMatch.waitForExistence(timeout: 6), "＋ on CHANNELS did not open Add a channel")
    }

    /// Home's ☰ opens the Town drawer, Today selected.
    func testHomeDrawer() {
        let app = launch("home")
        let button = app.buttons["drawer-button"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Home has no ☰")
        button.tap()
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["drawer-today"].firstMatch.waitForExistence(timeout: 5), "the drawer has no Today row")
        shot("55-home-drawer-tap")
    }

    /// A screen pushed on a place shows only ‹, never ☰ too (Xavier, 2026-11-22): Messages from Home.
    func testPushedHasNoDrawer() {
        let app = launch("homemessages")
        XCTAssertTrue(app.buttons["New message"].firstMatch.waitForExistence(timeout: 10), "Messages was not pushed on Home")
        sleep(1)
        XCTAssertFalse(app.buttons["drawer-button"].exists, "Messages pushed on Home still shows ☰")
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).exists, "Messages pushed on Home has no ‹")
        shot("57-home-messages-pushed")
    }

    /// Calendar and Groups have the same ☰ and drawer as Home (2026-11-17); no belfry switcher.
    func testCalendarAndGroupsDrawer() {
        for screen in ["calendar", "groups"] {
            let app = launch(screen)
            XCTAssertFalse(app.buttons["belfry-switch"].exists, "\(screen) still has the belfry switcher")
            let button = app.buttons["drawer-button"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(screen) has no ☰")
            button.tap()
            sleep(1)
            XCTAssertTrue(app.descendants(matching: .any)["drawer-today"].firstMatch.waitForExistence(timeout: 5), "\(screen): the drawer has no Today row")
            shot("56-\(screen)-drawer")
            app.terminate()
        }
    }
}
