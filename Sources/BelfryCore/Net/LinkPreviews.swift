import Foundation

// Link previews of outside pages (collective-belfry docs/link-previews.md @9a7d29e; canvas
// Channels, boards channels/og-*). A message with an outside https link shows a box under it: the
// page's picture, site, title, two lines of description. The app NEVER fetches an outside page or
// picture: it asks the belfry (`GET /link-preview?url=…`, NIP-98), and loads only pictures the
// belfry serves from its own address. Only the first outside link of a message gets a preview;
// none in private messages (asking would tell the belfry which link was sent: the lead,
// 2026-11-23) nor in a private group; `["preview","none"]` on a message: none (the composer's ✕).

public struct LinkPreview: Equatable, Sendable, Codable {
    /// The page after redirects (what a tap opens is still the link in the message).
    public var url: String
    public var title: String?
    public var about: String?
    public var site: String?
    /// The picture, at the belfry's own address only.
    public var image: String?
    public var imageWidth: Int?
    public var imageHeight: Int?

    public init(url: String, title: String? = nil, about: String? = nil, site: String? = nil, image: String? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil) {
        self.url = url; self.title = title; self.about = about; self.site = site; self.image = image
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
    }

    /// "ToolShare Journal · toolshare.example" (the site's name, then the link's host).
    public func siteLine(link: String) -> String {
        let host = LinkPreviews.host(link) ?? ""
        guard let s = site, !s.isEmpty, s.lowercased() != host else { return host }
        return host.isEmpty ? s : s + " · " + host
    }
}

/// What the device knows about a link's preview.
public enum LinkPreviewState: Equatable, Sendable {
    case loading
    case none
    case found(LinkPreview)
}

public enum LinkPreviewAnswer: Equatable, Sendable {
    case found(LinkPreview)
    /// Nothing to show (404 `none`, 422 `invalid`): the plain link, kept for an hour.
    case none
    /// 429, 503, no connection, anything else: ask again later, nothing kept.
    case later
}

public enum LinkPreviews {
    public static let keepFound = 86_400
    public static let keepNone = 3_600
    public static let noneTag: Tag = ["preview", "none"]
    static let digitsRx = Rx("^[0-9.]+$")

    /// The host of an https link, lower case, without "www.".
    public static func host(_ link: String) -> String? {
        guard let h = URL(string: link)?.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Is HOST the belfry's own (its domain and every subdomain)? Those have their own cards.
    static func own(_ host: String, domain: String) -> Bool {
        let d = domain.lowercased()
        return !d.isEmpty && (host == d || host.hasSuffix("." + d))
    }

    /// May the belfry be asked about LINK: https, a host with a dot that is no IP literal, no
    /// credentials, the default port, not the belfry's own, 2000 characters at most.
    public static func asks(_ link: String, domain: String) -> Bool {
        guard link.count <= 2000, let u = URL(string: link), u.scheme?.lowercased() == "https", let host = u.host?.lowercased(), !host.isEmpty,
              u.user == nil, u.password == nil, u.port == nil || u.port == 443 else { return false }
        if !host.contains(".") || host.contains(":") || digitsRx.test(host) { return false }
        return !own(host, domain: domain)
    }

    /// The link of TEXT that gets a preview: its first outside https link, when it is not a file
    /// already shown (SKIP: the message's attachments). Nil: no preview.
    public static func link(in text: String, domain: String, skip: [String] = []) -> String? {
        for l in Links.find(text) where asks(l, domain: domain) && !skip.contains(l) { return l }
        return nil
    }

    /// The link of a message that gets a preview; nil with `["preview","none"]`.
    public static func link(of m: Message, domain: String) -> String? {
        if m.ev.tags.contains(where: { $0.count > 1 && $0[0] == "preview" && $0[1] == "none" }) { return nil }
        return link(in: m.text, domain: domain, skip: m.media.map(\.url))
    }

    /// The belfry's answer. API_BASE: the picture is kept only when it is served from the same
    /// origin as the API (https, that host), so no outside address is ever loaded.
    public static func answer(status: Int, body: [String: Any]?, apiBase: String) -> LinkPreviewAnswer {
        if status == 404 || status == 422 { return .none }
        guard (200...299).contains(status), let b = body, let url = b["url"] as? String, url.count <= 2000 else { return .later }
        func text(_ k: String, _ n: Int) -> String? {
            guard let s = b[k] as? String else { return nil }
            let t = Cards.label(s, n)
            return t.isEmpty ? nil : t
        }
        var p = LinkPreview(url: url, title: text("title", 200), about: text("description", 300), site: text("site_name", 100))
        if let img = b["image"] as? String, img.count <= 500, let u = URL(string: img), let api = URL(string: apiBase),
           u.scheme == "https", let h = u.host?.lowercased(), h == api.host?.lowercased(), u.port == api.port {
            p.image = img
            func side(_ k: String) -> Int? { (b[k] as? NSNumber).map(\.intValue).flatMap { (1...20_000).contains($0) ? $0 : nil } }
            if let w = side("image_width"), let h = side("image_height") { p.imageWidth = w; p.imageHeight = h }
        }
        if p.title == nil && p.about == nil { return .none }
        return .found(p)
    }

    /// The call's address: the link percent-encoded as one query value.
    public static func address(apiBase: String, link: String) -> String? {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~")
        guard let q = link.addingPercentEncoding(withAllowedCharacters: ok) else { return nil }
        return apiBase + "/link-preview?url=" + q
    }
}

/// What the device keeps: a preview for a day, "none" for an hour.
public struct LinkPreviewCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var at: Int
        public var preview: LinkPreview?
    }
    public var entries = [String: Entry]()
    public init() {}

    public func state(_ link: String, now: Int = .now) -> LinkPreviewState? {
        guard let e = entries[link] else { return nil }
        if let p = e.preview { return now - e.at < LinkPreviews.keepFound ? .found(p) : nil }
        return now - e.at < LinkPreviews.keepNone ? LinkPreviewState.none : nil
    }

    public mutating func keep(_ link: String, _ a: LinkPreviewAnswer, now: Int = .now) {
        switch a {
        case .found(let p): entries[link] = Entry(at: now, preview: p)
        case .none: entries[link] = Entry(at: now, preview: nil)
        case .later: break
        }
        // a phone's worth: the newest 500
        if entries.count > 600 {
            let old = entries.sorted { $0.value.at < $1.value.at }.prefix(entries.count - 500).map(\.key)
            for k in old { entries[k] = nil }
        }
    }
}

extension BelfryAPI {
    /// The preview of an outside page, asked of the belfry (never of the page).
    public func linkPreview(_ link: String) async -> LinkPreviewAnswer {
        guard LinkPreviews.asks(link, domain: config.domain), let url = LinkPreviews.address(apiBase: base, link: link) else { return .none }
        guard let a = try? await signed(url) else { return .later }
        return LinkPreviews.answer(status: a.status, body: a.body, apiBase: base)
    }
}
