import Foundation

// What a picture view shows for an address (the profile bug of 2026-11-18: "after updating my
// profile… my past messages should show immediately my new avatar"). A view kept its loaded
// picture in its own state; when its address changed to one already in the memory cache (the
// profile screen, or another row, had just loaded it), its "already have a picture" check
// returned early and the OLD picture stayed. The picture now always belongs to an address: a
// view shows it only while it is for the address it is asked for.

public struct PictureSlot<Picture> {
    /// The address the held picture is for.
    public private(set) var url: String?
    public private(set) var picture: Picture?

    public init(url: String?, picture: Picture?) {
        self.url = picture == nil ? nil : url
        self.picture = picture
    }

    /// What to show for WANT: the held picture when it is WANT's, else the cache's copy, else nothing
    /// (the placeholder), never another address's picture.
    public func shown(for want: String?, cached: (String) -> Picture?) -> Picture? {
        guard let want else { return nil }
        if url == want, let picture { return picture }
        return cached(want)
    }

    /// Does WANT still need loading?
    public func needsLoad(_ want: String?) -> Bool { want != nil && (url != want || picture == nil) }

    public mutating func hold(_ p: Picture?, for u: String) {
        url = p == nil ? nil : u
        picture = p
    }
}
