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
        answers(app, after: "focusing the composer")
        // a first tap can land while the screen settles: tap again until the keyboard is up
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
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
    /// The app answers within seconds after WHAT: a hang (the main thread never idle) takes the
    /// whole query timeout, a slow simulator a few seconds.
    private func answers(_ app: XCUIApplication, after what: String, file: StaticString = #filePath, line: UInt = #line) {
        let t0 = Date()
        _ = app.navigationBars.count
        let took = Date().timeIntervalSince(t0)
        XCTAssertLessThan(took, 20, "the app did not answer for \(Int(took)) s after \(what): it hangs", file: file, line: line)
    }

    /// The event's chat with the keyboard up (the header steps out of the way), three times: focus,
    /// type, dismiss. The app must answer within seconds after each step (a freeze was seen here).
    func testEventChatTyping() {
        let app = launch("event")
        sleep(2)
        for round in 1...3 {
            // the channel under the pushed event screen has a composer too: the event's own is the
            // last one in the tree
            let fields = app.descendants(matching: .any).matching(identifier: "composer-field")
            XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 10))
            guard let field = fields.allElementsBoundByIndex.last else { XCTFail("no composer on screen"); return }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            // the screen right after the tap, twice (no query: these work while the app hangs)
            if round == 1 { sleep(1); shot("83-after-tap-a"); sleep(2); shot("83-after-tap-b") }
            answers(app, after: "focusing the composer (round \(round))")
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard (round \(round))")
            field.typeText(round == 1 ? "On my way" : " and more")
            answers(app, after: "typing (round \(round))")
            if round == 1 { sleep(2); shot("82-event-chat-typing") }
            // the feed dismisses the keyboard when dragged down
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
            sleep(1)
            answers(app, after: "dismissing the keyboard (round \(round))")
        }
    }

    /// A steward holds a channel in the drawer and drags it into another category (SPEC 19.34).
    func testDrawerDrag() {
        let app = launch("towndrawer")
        sleep(2)
        let kitchen = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shared kitchen")).firstMatch
        XCTAssertTrue(kitchen.waitForExistence(timeout: 10), "the drawer shows no Shared kitchen row")
        let header = app.staticTexts["MAKING & MENDING"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the drawer shows no Making & mending category")
        guard kitchen.isHittable, header.isHittable else { XCTFail("the drawer's rows are not on screen"); return }
        let before = kitchen.frame.minY
        let target = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 70))
        kitchen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(2)
        shot("54-drawer-drag")
        let moved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shared kitchen")).firstMatch
        XCTAssertTrue(moved.exists)
        XCTAssertGreaterThan(moved.frame.minY, header.frame.minY, "Shared kitchen did not move under Making & mending (it was at \(before))")
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
}
