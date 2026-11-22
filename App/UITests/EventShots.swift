import XCTest

/// The event screen.
final class EventShots: ShotCase {
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
}
