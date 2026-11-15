import XCTest

// Screens that only a touch can open (native menus), for the screenshot job: the composer's ＋
// menu and a held message's menu, in demo mode. Each writes a PNG into $SHOTS_DIR (the CI
// passes TEST_RUNNER_SHOTS_DIR) named with $SHOTS_SUFFIX (light / dark).

final class MenuShots: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", screen]
        app.launch()
        sleep(5)
        return app
    }

    private func shot(_ name: String) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SHOTS_DIR"], !dir.isEmpty else { return }
        let suffix = env["SHOTS_SUFFIX"].map { $0.isEmpty ? "" : "-" + $0 } ?? ""
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

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
        let msg = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'message-row' AND label CONTAINS %@", "read it tonight")).firstMatch
        XCTAssertTrue(msg.waitForExistence(timeout: 10))
        XCTAssertTrue(msg.isHittable, "the message row is not on screen")
        msg.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 4), "the message's menu did not open")
        sleep(1)
        shot("51-message-menu")
    }

    func testDrawerSwipe() {
        let app = launch("feed")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(2)
        shot("52-drawer-swipe")
    }

    func testKeyboardComposer() {
        let app = launch("composer")
        let field = app.descendants(matching: .any).matching(identifier: "composer-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Hello from the demo")
        sleep(2)
        shot("53-composer-typing")
    }

    /// The event's header: dragged up (the chat takes the screen), then all the way down.
    func testEventHeaderDrag() {
        let app = launch("event")
        sleep(2)
        let handle = app.descendants(matching: .any).matching(identifier: "event-handle").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "the event screen did not open")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -500)))
        sleep(2)
        shot("80-event-dragged-up")
        let h2 = app.descendants(matching: .any).matching(identifier: "event-handle").firstMatch
        let from2 = h2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from2.press(forDuration: 0.05, thenDragTo: from2.withOffset(CGVector(dx: 0, dy: 800)))
        sleep(2)
        shot("81-event-dragged-full")
    }

    /// The event's chat with the keyboard up (the header steps out of the way).
    func testEventChatTyping() {
        let app = launch("event")
        sleep(2)
        // the channel under the pushed event screen has a composer too: take the one on screen
        let fields = app.descendants(matching: .any).matching(identifier: "composer-field")
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 10))
        guard let field = fields.allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("no composer on screen"); return }
        field.tap()
        field.typeText("On my way")
        sleep(2)
        shot("82-event-chat-typing")
    }
}
