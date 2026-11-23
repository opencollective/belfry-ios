import Foundation

/// "Notes to myself" (docs/one-shape.md, section "Notes to myself", belfry-sh 70979a3; Xavier,
/// 2026-11-22 / 23): the first row of Messages, always. It is the ordinary direct conversation
/// whose only participant is me: a note is a kind 14 rumor of mine with exactly one `p` tag, my
/// own account (files: kind 15 the same way). No new kind, no typing events.
public enum Notes {
    public static let title = "Notes to myself"
    /// The row's line while there is no note.
    public static let emptyLine = "Only you can read these"
    /// The fixed first line of the screen, sealed.
    public static let sealedLine = "Encrypted for your own devices. Nobody else can read your notes, not the belfry's admins either."
    /// The same place on an account that does not seal (an agent, an account that holds its own
    /// key, a device that cannot seal): never the "nobody else" sentence there.
    public static let plainLine = "Private to your account. Not end-to-end encrypted on this account."

    /// Under the fixed line while there is no note (the lead, 2026-11-23; Messages canvas v7).
    public static let emptyHint = "Write anything you want to keep: ideas, lists, pictures, files."

    /// A note written before my devices' lock exists and it could not be made now: kept in the box.
    public static let notYet = "Can't save it yet: your notes are being locked for your devices. Try again in a moment."

    /// What happens to a note written now (vectors/sealed.json `notes.plans`).
    public enum Plan: String, Sendable {
        /// Sealed to my own head letterbox: one wrap, no signer call. Also when my chain is not `ready`.
        case seal
        /// I have a chain and this device is not in its head: it waits to be added, never the old way.
        case waitForDevice = "wait_for_device"
        /// No chain, on the relay's complete answer: the first-device path runs; the note is held
        /// as sending until my chain is anchored, then sealed.
        case makeChainThenSeal = "make_chain_then_seal"
        /// No chain known and the answer is not complete: nothing made, nothing sent.
        case hold
        /// An account that cannot seal: one old-style wrap to my own account.
        case oldWay = "old_way"
    }

    public static func plan(canSeal: Bool, hasChain: Bool, inHead: Bool, answered: Bool) -> Plan {
        if hasChain { return inHead ? .seal : .waitForDevice }
        if !canSeal { return .oldWay }
        return answered ? .makeChainThenSeal : .hold
    }

    /// The conversation id: the DM id of {me}.
    public static func conv(_ me: String) -> String { MailThreads.nostrConv(author: me, pTags: [me], me: me) }

    public static func isNotes(_ conv: String, me: String) -> Bool { !me.isEmpty && conv == Notes.conv(me) }
}
