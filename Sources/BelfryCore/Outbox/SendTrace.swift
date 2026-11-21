import Foundation

// What a send that is not out yet says, and each send's timing (SPEC 19.50, ported from Android's
// core/outbox/SendTrace.kt so the three apps read alike).

/// A send that is not out yet: since when (seconds, the trace's clock) and what it is doing now.
public struct SendProgress: Hashable, Sendable {
    public var since: TimeInterval
    public var step: String
    public init(since: TimeInterval, step: String) { self.since = since; self.step = step }
}

/// The line under a message that is not out yet; RETRY: show Retry next to it.
public struct SendLine: Hashable, Sendable {
    public var text: String
    public var retry: Bool = false
    public init(text: String, retry: Bool = false) { self.text = text; self.retry = retry }
}

/// "Sending…"; after 5 s "Still sending…" and what it is doing; after 30 s "Not sent yet" with
/// Retry. Offline: waiting for the connection. Refused for good: "Not sent" (with Retry).
public enum SendState {
    public static let still: TimeInterval = 5
    public static let notYet: TimeInterval = 30
    public static let prepare = "preparing"
    public static let sign = "signing"
    public static let uploadStep = "uploading"
    public static let again = "trying again"
    public static let checking = "checking the connection"
    public static let connecting = "connecting"
    public static let relayWait = "waiting for the relay"

    /// The words people see for a step (the same on the three apps, the lead 2026-11-21):
    /// connecting, encrypting, uploading 2.2 of 4.8 MB, waiting for the server. Never "signer" or
    /// "relay": the trace keeps the exact step.
    public static func shown(_ step: String) -> String {
        if step == checking || step == connecting || step == again { return "connecting" }
        if step == prepare { return "encrypting" }
        if step.hasPrefix(uploadStep) { return step }
        return "waiting for the server"
    }

    /// "uploading 2.2 of 4.8 MB"
    public static func uploading(_ sent: Int64, _ total: Int64) -> String { "\(uploadStep) \(mb(sent)) of \(mb(total)) MB" }

    static func mb(_ n: Int64) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(n) / 1_000_000) }

    public static func line(failed: Bool, tries: Int, progress p: SendProgress?, now: TimeInterval, online: Bool) -> SendLine {
        if failed { return SendLine(text: "Not sent", retry: true) }
        if !online { return SendLine(text: "Waiting for the connection…") }
        // tried before and not going now (after a restart): it waits for the connection
        guard let p else { return SendLine(text: tries > 0 ? "Waiting for the connection…" : "Sending…") }
        let first = tries > 0 ? "Sending again…" : "Sending…"
        let waited = now - p.since
        if waited < still { return SendLine(text: first) }
        if waited < notYet { return SendLine(text: "Still sending… · " + shown(p.step)) }
        return SendLine(text: "Not sent yet", retry: true)
    }

    /// In how many seconds `line` says something else without any news (nil: never).
    public static func nextChange(_ p: SendProgress?, now: TimeInterval) -> TimeInterval? {
        guard let p else { return nil }
        let waited = now - p.since
        if waited < still { return still - waited }
        if waited < notYet { return notYet - waited }
        return nil
    }
}

/// Each send's timing: the steps it went through and how long each took, the last 20 attempts,
/// for About Belfry → Diagnostics. Never any content, name or key: what kind of thing it was, the
/// step names, durations and the outcome's class.
public final class SendTrace: @unchecked Sendable {
    public static let keep = 20

    private final class Run {
        let label: String
        let startedAt: TimeInterval
        let wallAt: Date
        var parts = [String]()
        var step: String?
        var stepAt: TimeInterval
        init(label: String, startedAt: TimeInterval, wallAt: Date) { self.label = label; self.startedAt = startedAt; self.wallAt = wallAt; self.stepAt = startedAt }
    }

    private let lock = NSLock()
    private var runs = [String: Run]()
    private var kept = [String]()
    private var current = [String: SendProgress]()
    private let clock: () -> TimeInterval
    private let wall: () -> Date
    private let zone: TimeZone
    /// The sends' progress changed (any thread).
    public var onChange: (() -> Void)?

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, wall: @escaping () -> Date = Date.init, zone: TimeZone = .current) {
        self.clock = clock
        self.wall = wall
        self.zone = zone
    }

    public var now: TimeInterval { clock() }

    /// Sends not out yet, by message (a direct message's rumor id, else the outbox item's local id).
    public var progress: [String: SendProgress] { lock.lock(); defer { lock.unlock() }; return current }
    public func progress(_ id: String) -> SendProgress? { lock.lock(); defer { lock.unlock() }; return current[id] }

    /// ID is now at STEP (started now if it was not going). LABEL says what it is ("DM", "message"…).
    public func step(_ id: String, label: String, _ step: String) {
        lock.lock()
        let now = clock()
        let r = runs[id] ?? Run(label: label, startedAt: now, wallAt: wall())
        runs[id] = r
        // the upload's progress: the same step goes on, only its words change
        if step.hasPrefix(SendState.uploadStep), r.step?.hasPrefix(SendState.uploadStep) == true {
            if var p = current[id], p.step != step { p.step = step; current[id] = p; lock.unlock(); onChange?(); return }
            lock.unlock(); return
        }
        close(r, now)
        r.step = step
        r.stepAt = now
        current[id] = SendProgress(since: current[id]?.since ?? now, step: step)
        lock.unlock()
        onChange?()
    }

    /// ID's attempt ended (OUTCOME: "OK", "refused", "retry (<class>)"); LEFT: it still waits.
    public func end(_ id: String, _ outcome: String, left: Bool) {
        lock.lock()
        let now = clock()
        if let r = runs.removeValue(forKey: id) {
            close(r, now)
            push("\(hms(r.wallAt)) \(r.label) · " + (r.parts + ["→ \(outcome) \(SendTrace.secs(now - r.startedAt))"]).joined(separator: " · "))
        }
        if !left { current[id] = nil }
        else if outcome.hasPrefix("retry"), var p = current[id] { p.step = SendState.again; current[id] = p }
        lock.unlock()
        onChange?()
    }

    /// Forgets ID (out, discarded).
    public func forget(_ id: String) {
        lock.lock(); runs[id] = nil; let had = current.removeValue(forKey: id) != nil; lock.unlock()
        if had { onChange?() }
    }

    /// Keeps only the sends in IDS (what is left in the outbox).
    public func keepOnly(_ ids: Set<String>) {
        lock.lock()
        let gone = current.keys.filter { !ids.contains($0) }
        for k in gone { current[k] = nil }
        lock.unlock()
        if !gone.isEmpty { onChange?() }
    }

    /// Everything that waits starts counting again (Retry, back online): a fresh 30 s.
    public func restart() {
        lock.lock()
        let now = clock()
        for k in current.keys { current[k]?.since = now }
        lock.unlock()
        onChange?()
    }

    /// A line of its own (a slow signer request, a dropped socket).
    public func note(_ text: String) {
        lock.lock(); push("\(hms(wall())) \(text)"); lock.unlock()
    }

    /// The last 20 lines, oldest first.
    public func lines() -> [String] { lock.lock(); defer { lock.unlock() }; return kept }

    private func close(_ r: Run, _ now: TimeInterval) {
        if let s = r.step { r.parts.append((s.hasPrefix(SendState.uploadStep) ? SendState.uploadStep : s) + " " + SendTrace.secs(now - r.stepAt)) }
        r.step = nil
    }

    private func push(_ line: String) {
        kept.append(line)
        if kept.count > SendTrace.keep { kept.removeFirst(kept.count - SendTrace.keep) }
    }

    private func hms(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    public static func secs(_ s: TimeInterval) -> String { String(format: "%.1fs", locale: Locale(identifier: "en_US_POSIX"), s) }

    /// What kind of thing an outbox item is, for the trace (never its content).
    public static func label(_ item: OutboxItem) -> String {
        if item.dm != nil { return "DM" }
        if item.target == .api { return ("API " + (item.http.flatMap { URL(string: $0.url)?.path } ?? "")).trimmingCharacters(in: .whitespaces) }
        switch item.kind {
        case 30078: return "read state"
        case 9, 11, 1111: return "message"
        case 7: return "reaction"
        default: return "kind \(item.kind)"
        }
    }
}
