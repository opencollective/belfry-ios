import XCTest

// Screens that only a touch can open (native menus), for the screenshot job, in demo mode. Each
// test writes a PNG into $SHOTS_DIR (the CI passes TEST_RUNNER_SHOTS_DIR) named with $SHOTS_SUFFIX
// (light / dark). One class per area (2026-11-22, Xavier: run less per change): NavShots,
// ChannelShots, EventShots, TodoShots, DmShots, OnboardingShots, SettingsShots. scripts/ci-plan.py
// maps the changed source files to the tests; a change to one of these files runs that file's tests.

class ShotCase: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// A failed check leaves a picture of the screen as it was ("fail-<test>-<n>"), next to the
    /// other screenshots: what the app showed is the first thing to know about a failure.
    private var failures = 0
    override func record(_ issue: XCTIssue) {
        failures += 1
        if failures <= 2 { shot("fail-" + name.replacingOccurrences(of: "-[", with: "").replacingOccurrences(of: "]", with: "").replacingOccurrences(of: " ", with: "-") + "-\(failures)") }
        super.record(issue)
    }

    func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", screen]
        app.launch()
        sleep(5)
        return app
    }

    /// The first element of LIST that can be tapped, waiting up to TIMEOUT seconds for one.
    func hittable(_ list: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
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

    func shot(_ name: String) {
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

    /// The event's chat with the keyboard up (the header steps out of the way).
    /// The app answers within seconds after WHAT: a hang (the main thread never idle) takes the
    /// whole query timeout, a slow simulator a few seconds.
    func answers(_ app: XCUIApplication, after what: String, file: StaticString = #filePath, line: UInt = #line) {
        let t0 = Date()
        _ = app.navigationBars.count
        let took = Date().timeIntervalSince(t0)
        XCTAssertLessThan(took, 20, "the app did not answer for \(Int(took)) s after \(what): it hangs", file: file, line: line)
    }
}
