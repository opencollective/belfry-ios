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
    /// Since start, never reset: read by the stall thread to see what runs while the main thread hangs.
    nonisolated(unsafe) private static var totals = [String: Int]()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false

    /// Logs NAME at once (to see the last thing that ran before a stall).
    static func mark(_ name: String) {
        guard on else { return }
        log.error("MARK \(name, privacy: .public)")
    }

    /// Counts one call of NAME (main thread).
    static func tick(_ name: String) {
        guard on else { return }
        lock.lock()
        counts[name, default: 0] += 1
        totals[name, default: 0] += 1
        lock.unlock()
        if !started { start() }
    }

    private static func start() {
        started = true
        log.notice("watchdog on")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            lock.lock()
            let busy = counts.filter { $0.value > 40 }.sorted { $0.value > $1.value }
            counts = [:]
            lock.unlock()
            if !busy.isEmpty { log.error("LOOP \(busy.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public)") }
        }
        let thread = Thread {
            while true {
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 3) == .timedOut {
                    log.error("STALL main thread did not answer for 3 s")
                    // while it hangs: do the counters still move (an update loop) or not (one call)?
                    var n = 0
                    while answered.wait(timeout: .now() + 2) == .timedOut, n < 30 {
                        n += 1
                        lock.lock()
                        let t = totals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                        lock.unlock()
                        log.error("STALL totals \(t, privacy: .public)")
                    }
                    if n >= 30 { answered.wait() }
                    log.error("STALL over")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        thread.start()
    }
}
