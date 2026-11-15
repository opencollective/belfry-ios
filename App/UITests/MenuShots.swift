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
}
