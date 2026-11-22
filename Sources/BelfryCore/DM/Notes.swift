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

    /// A note written before my devices' lock exists and it could not be made now: kept in the box.
    public static let notYet = "Can't save it yet: your notes are being locked for your devices. Try again in a moment."

    /// The conversation id: the DM id of {me}.
    public static func conv(_ me: String) -> String { MailThreads.nostrConv(author: me, pTags: [me], me: me) }

    public static func isNotes(_ conv: String, me: String) -> Bool { !me.isEmpty && conv == Notes.conv(me) }
}
