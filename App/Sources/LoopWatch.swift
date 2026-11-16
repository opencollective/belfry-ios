import Foundation
import os

// Diagnostics for the screenshot job only (launch argument -demo): counts how often views redraw
// and layout callbacks fire, logs anything above 40 per second, and logs when the main thread
// does not answer for 3 s (a stall, not a loop). Read in CI with
// `log show --predicate 'subsystem == "sh.belfry.app.watchdog"'` (scripts/screenshots.sh).

enum LoopWatch {
    static let on = CommandLine.arguments.contains("-demo")
    private static let log = Logger(subsystem: "sh.belfry.app.watchdog", category: "ui")
    nonisolated(unsafe) private static var counts = [String: Int]()
    nonisolated(unsafe) private static var started = false

    /// Counts one call of NAME (main thread).
    static func tick(_ name: String) {
        guard on else { return }
        counts[name, default: 0] += 1
        if !started { start() }
    }

    private static func start() {
        started = true
        log.notice("watchdog on")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let busy = counts.filter { $0.value > 40 }.sorted { $0.value > $1.value }
            if !busy.isEmpty { log.error("LOOP \(busy.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public)") }
            counts = [:]
        }
        let thread = Thread {
            while true {
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 3) == .timedOut {
                    log.error("STALL main thread did not answer for 3 s")
                    answered.wait()
                    log.error("STALL over")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        thread.start()
    }
}
