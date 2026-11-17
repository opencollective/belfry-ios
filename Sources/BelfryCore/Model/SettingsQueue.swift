import Foundation

// A channel's settings saved through the outbox (SPEC 19.37): shown at once, sent in order when
// there is a connection, and only a final refusal shows (an error mark by the channel's name with
// "Try again" / "Discard"). Discarding drops the queued change, so the channel reads what the
// relay has again.

public enum SettingsQueue {
    public enum Part: String, Sendable { case meta, inbox }

    /// Which part of a channel's settings ITEM changes, or nil when it is something else.
    public static func part(_ item: OutboxItem) -> Part? {
        if item.kind == 9002 { return .meta }
        if item.kind == 30078, item.tags.contains(where: { $0.count >= 2 && $0[0] == "d" && $0[1] == Derive.inboxD }) { return .inbox }
        return nil
    }

    static func group(_ item: OutboxItem) -> String? {
        item.tags.first { $0.count >= 2 && $0[0] == "h" }?[1]
    }

    /// The settings changes of CHANNEL that failed for good (oldest first).
    public static func failed(_ items: [OutboxItem], channel: String) -> [OutboxItem] {
        items.filter { $0.status == .failed && part($0) != nil && group($0) == channel }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The settings changes of CHANNEL still on their way (nothing special shows for them).
    public static func queued(_ items: [OutboxItem], channel: String) -> [OutboxItem] {
        items.filter { $0.status == .queued && part($0) != nil && group($0) == channel }
    }

    /// One sentence on what failed: fixed text by part and by the kind of refusal (never the
    /// relay's or the server's own words).
    public static func message(_ item: OutboxItem) -> String {
        let what = part(item) == .inbox ? "The e-mail setting wasn't saved" : "The new name and description weren't saved"
        let msg = item.error ?? ""
        let code = HttpCall.code(of: msg)
        if code == "not_allowed" || code == "forbidden" || Outbox.permanentWords.test(msg) || msg.hasPrefix("restricted:") || msg.hasPrefix("blocked:") {
            return what + ": you're not allowed to change this channel."
        }
        if code == "archived" { return what + ": the channel is archived." }
        if code == "not_found" { return what + ": the channel is no longer there." }
        if code == "invalid" || msg.hasPrefix("invalid:") { return what + ": the belfry didn't accept them." }
        return what + ": the belfry refused the change."
    }
}
