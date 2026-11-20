import Foundation

/// The words of the Encryption screens (boards messages/encryption-*, 2026-11-20). Text only:
/// the keys, the devices and the wire format come with the lead's contract (docs/sealed.md).
public enum SealedWords {
    public static func devices(_ n: Int) -> String { n == 1 ? "1 device" : "\(n) devices" }

    /// "5 people · 11 devices", under the title of a group's screen.
    public static func summary(people: Int, devices n: Int) -> String { "\(people) people · \(devices(n))" }

    /// "today", "yesterday", else "on 2 Nov".
    public static func dayWord(_ at: Int, now: Int, calendar: Calendar = .current) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(at)), n = Date(timeIntervalSince1970: TimeInterval(now))
        if calendar.isDate(d, inSameDayAs: n) { return "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: n), calendar.isDate(d, inSameDayAs: y) { return "yesterday" }
        return "on " + date(at, calendar: calendar)
    }

    /// "2 Nov"
    public static func date(_ at: Int, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMM"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    /// The grey line under another person: "Added a device yesterday" / "Removed a device on 2 Nov";
    /// nothing once the change is more than 30 days old.
    public static func change(added: Bool, at: Int, now: Int, calendar: Calendar = .current) -> String? {
        guard at <= now, now - at <= 30 * 86400 else { return nil }
        return (added ? "Added a device " : "Removed a device ") + dayWord(at, now: now, calendar: calendar)
    }

    /// One of my devices: "Added 12 Aug", "Added 2 Oct · from iPhone".
    public static func added(_ at: Int, from: String? = nil, calendar: Calendar = .current) -> String {
        "Added " + date(at, calendar: calendar) + (from.map { " · from " + $0 } ?? "")
    }
}
