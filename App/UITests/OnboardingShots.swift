import XCTest

/// Joining with a link.
final class OnboardingShots: ShotCase {
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
