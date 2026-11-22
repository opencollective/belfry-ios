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

    /// The first element of LIST that can be tapped, waiting up to TIMEOUT seconds for one.
    private func hittable(_ list: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            for i in 0..<min(list.count, 6) {
                let e = list.element(boundBy: i)
                if e.exists && e.isHittable { return e }
            }
            usleep(500_000)
        } while Date() < end
        return nil
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
        // the demo's database can keep an earlier run's move: drag it to the other side of the
        // header. The simulator sometimes takes the drag as a scroll: up to five tries.
        func kitchenRow() -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shared kitchen")).firstMatch }
        func headerRow() -> XCUIElement { app.staticTexts["MAKING & MENDING"].firstMatch }
        let below = kitchenRow().frame.minY > headerRow().frame.minY
        var crossed = false
        for _ in 1...5 where !crossed {
            let k = kitchenRow(), h = headerRow()
            guard k.isHittable, h.isHittable else { break }
            let target = h.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: below ? -90 : 70))
            k.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.6, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.8)
            sleep(2)
            crossed = (kitchenRow().frame.minY > headerRow().frame.minY) != below
        }
        shot("54-drawer-drag")
        XCTAssertTrue(crossed, "Shared kitchen did not cross the Making & mending header in five tries")
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
    /// Round 7: a to-do row opens its own screen (not the tick); Assign to… puts it on someone,
    /// Unassign takes it off again.
    func testTodoAssign() {
        let app = launch("todos")
        let row = app.buttons["todo-open"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no to-do row")
        row.tap()
        let assign = app.buttons["todo-assign"].firstMatch
        XCTAssertTrue(assign.waitForExistence(timeout: 5), "the to-do's screen did not open")
        shot("58-todo")
        assign.tap()
        let person = app.buttons.matching(identifier: "assign-person").element(boundBy: 1)
        XCTAssertTrue(person.waitForExistence(timeout: 5), "no one to assign")
        shot("58-todo-assign")
        person.tap()
        let unassign = app.buttons["todo-unassign"].firstMatch
        XCTAssertTrue(unassign.waitForExistence(timeout: 5), "assigning did not show Unassign")
        unassign.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Nobody on it yet'"), evaluatedWith: app.descendants(matching: .any)["todo-who"].firstMatch)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["todo-claim"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Round 7: a member link shows "You're invited…" (no channel); Sign up → name, e-mail, the
    /// code (demo 123456) → a member: no guest Home, no application form.
    func testMemberLinkSignUp() {
        let app = XCUIApplication()
        app.launchArguments = ["-join", "member"]
        app.launch()
        let signup = app.buttons["member-signup"].firstMatch
        XCTAssertTrue(signup.waitForExistence(timeout: 15), "no member invite screen")
        XCTAssertTrue(app.staticTexts["member-invite-title"].exists)
        shot("59-member-invite")
        signup.tap()
        let name = app.textFields["The name people here will see"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 15), "the Join sheet did not open")
        name.tap()
        name.typeText("Lou")
        let email = app.textFields["you@example.org"].firstMatch
        email.tap()
        email.typeText("lou@example.org")
        app.buttons["Continue"].firstMatch.tap()
        let code = app.textFields["6-digit code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 8), "no code step")
        sleep(1)
        code.tap()
        code.typeText("123456")
        let home = app.descendants(matching: .any)["home-date"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 15), "not in the belfry after the code")
        sleep(2)
        XCTAssertFalse(app.buttons["guest-apply"].exists, "a member saw the application form")
        XCTAssertFalse(app.buttons["member-signup"].exists, "still on the invite screen")
        shot("59-member-in")
    }
}
