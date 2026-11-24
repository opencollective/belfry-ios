import Foundation

// Link previews built by the sender (SPEC 19.69; collective-belfry docs/link-previews-v2.md;
// vectors/link-previews.json = belfry-android's, copied byte for byte). The SENDER's device reads
// the page once while composing and puts what it found on the message; readers build the box from
// those tags alone and never fetch the page (nor the belfry's preview endpoint). A port of
// Android's core/preview (LinkPreviews.kt, PageMeta.kt, SafeFetch.kt, PreviewBuilder.kt).

/// The picture of a preview as the message carries it (its `imeta` entry with `purpose preview`).
/// `x` is the sha256 of what Blossom stores; `key` / `nonce` / `ox` only when it is encrypted
/// (AES-256-GCM like a file of a direct message), `mime` then the plain type.
public struct PreviewPicture: Equatable, Sendable, Codable {
    public let url: String
    public let mime: String
    public let width: Int?
    public let height: Int?
    public let x: String
    public var ox: String? = nil
    public var key: String? = nil
    public var nonce: String? = nil

    public init(url: String, mime: String, width: Int?, height: Int?, x: String, ox: String? = nil, key: String? = nil, nonce: String? = nil) {
        self.url = url; self.mime = mime; self.width = width; self.height = height; self.x = x; self.ox = ox; self.key = key; self.nonce = nonce
    }

    public var encrypted: Bool { key != nil }

    /// The `imeta` entry in the contract's order: url, m, dim, x, the encryption's, purpose.
    public func imeta() -> Tag {
        var t: Tag = ["imeta", "url \(url)", "m \(mime)"]
        if let w = width, let h = height { t.append("dim \(w)x\(h)") }
        t.append("x \(x)")
        if let key, let nonce, let ox {
            t += ["ox \(ox)", "encryption-algorithm aes-gcm", "decryption-key \(key)", "decryption-nonce \(nonce)"]
        }
        t.append("purpose " + LinkPreviews.purpose)
        return t
    }

    /// The picture from what was downloaded, or nil (shown without it): encrypted → x on the
    /// ciphertext, GCM's tag, ox on the plain bytes; plain → x on the bytes. Either way a PNG,
    /// JPEG, WebP or GIF by its first bytes.
    public func open(_ downloaded: Data) -> Data? {
        let plain: Data
        if encrypted {
            guard let key, let nonce, let ox, Crypto.sha256(downloaded).hex == x, let k = Data(hex: key), let n = Data(hex: nonce),
                  let p = DmFiles.decrypt(downloaded, key: k, nonce: n), Crypto.sha256(p).hex == ox else { return nil }
            plain = p
        } else {
            guard Crypto.sha256(downloaded).hex == x else { return nil }
            plain = downloaded
        }
        return PreviewImages.kind(plain) == nil ? nil : plain
    }
}

/// One preview: `url` is the link as written in the text (what a tap opens); title, description
/// and site are plain text, cleaned and cut. `picture` nil: none (or not shown).
public struct LinkPreview: Equatable, Sendable, Codable {
    public let url: String
    public let title: String
    public let description: String
    public let site: String
    public var picture: PreviewPicture? = nil

    public init(url: String, title: String, description: String, site: String, picture: PreviewPicture? = nil) {
        self.url = url; self.title = title; self.description = description; self.site = site; self.picture = picture
    }

    /// The link's host without `www.`.
    public var host: String {
        guard let h = LinkPreviews.hostOf(url) else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// "ToolShare Journal · toolshare.example"; the host alone when the page names no site (or names itself by its host).
    public var siteLine: String {
        var parts = [String]()
        for p in [site, host] where !p.isEmpty && !parts.contains(p) { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    /// The picture's box, width over height: its own shape between 3:2 and 12:5, 2:1 without a size.
    public var ratio: Double { LinkPreviews.ratio(picture?.width, picture?.height) }

    /// What the message carries: the `preview` tag, then the picture's `imeta` entry.
    public func tags() -> [Tag] { [["preview", url, title, description, site]] + (picture.map { [$0.imeta()] } ?? []) }
}

/// How a preview's picture is stored: in the clear (a channel, an open group) or encrypted (a direct message, a private group).
public enum PreviewMode: Sendable { case plain, encrypted }

public enum LinkPreviews {
    public static let noPreview: Tag = ["preview", "none"]
    public static let purpose = "preview"
    public static let titleMax = 200
    public static let descriptionMax = 300
    public static let siteMax = 100
    public static let pageMax = 512 * 1024
    public static let pictureInMax = 5 * 1024 * 1024
    public static let pictureOutMax = 300 * 1024
    public static let pictureSide = 1200
    /// A reader downloads at most this (a picture made by another client may be a little larger).
    public static let pictureReadMax = 1024 * 1024
    public static let redirects = 3
    public static let timeout: TimeInterval = 5

    public static func hasNoPreview(_ tags: [Tag]) -> Bool { tags.contains { $0.count >= 2 && $0[0] == "preview" && $0[1] == "none" } }
    public static func isPreviewImeta(_ t: Tag) -> Bool { t.first == "imeta" && t.contains("purpose " + purpose) }
    /// The tags that make the preview: `preview` ones and the preview's `imeta` entry.
    public static func wireTags(_ tags: [Tag]) -> [Tag] { tags.filter { ($0.count >= 2 && $0[0] == "preview") || isPreviewImeta($0) } }

    // the web's MEDIA (src/core/linkpreview.ts): pictures and files show as themselves
    static let media = Rx("\\.(jpe?g|png|gif|webp|avif|heic|svg|mp4|mov|webm|m4a|mp3|ogg|wav|pdf)(\\?|#|$)", [.caseInsensitive])

    /// The host of an https address with no credentials, lower case, without a trailing dot.
    public static func hostOf(_ url: String) -> String? {
        guard let c = URLComponents(string: url), c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              var h = c.host?.lowercased() else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? nil : h
    }

    /// HOST is the belfry's own: its domain or any name under it.
    public static func isOwn(_ host: String, domain: String) -> Bool {
        let d = domain.lowercased()
        return !d.isEmpty && (host == d || host.hasSuffix("." + d))
    }

    /// The first link to an outside page in TEXT, or nil: `https://` only, not something of this
    /// belfry, not a file (the message's `imeta` urls, anything on FILES' host, an address that ends
    /// like a picture, a recording or a PDF), not one of SKIP. Nil too for `["preview","none"]`.
    public static func outsideLink(_ text: String, tags: [Tag], domain: String, files: String = "", skip: [String] = []) -> String? {
        if text.isEmpty || hasNoPreview(tags) { return nil }
        var attached = Set<String>()
        for t in tags where t.first == "imeta" { for p in t where p.hasPrefix("url ") { attached.insert(String(p.dropFirst(4))) } }
        let fileHost = files.isEmpty ? nil : hostOf(files)
        for u in Links.find(text) {
            guard u.hasPrefix("https://") else { continue }
            if attached.contains(u) || skip.contains(u) || media.test(u) { continue }
            guard let host = hostOf(u) else { continue }
            if isOwn(host, domain: domain) || host == fileHost { continue }
            return u
        }
        return nil
    }

    /// `https://host` of an https address on the default port with no credentials, else nil.
    public static func originOf(_ url: String) -> String? {
        guard let c = URLComponents(string: url), c.scheme?.lowercased() == "https", let h = c.host?.lowercased(), !h.isEmpty,
              c.user == nil, c.password == nil, c.port == nil || c.port == 443 else { return nil }
        return "https://" + h
    }

    static let ws = Rx("[\\s\\u00a0\\u2028\\u2029]+")

    /// Whitespace collapsed, trimmed, at most MAX characters (code points, never half of one).
    public static func words(_ v: String?, _ max: Int) -> String {
        cut(ws.replace(v ?? "", with: " ").trimmingCharacters(in: .whitespaces), max)
    }

    public static func cut(_ s: String, _ max: Int) -> String {
        let scalars = s.unicodeScalars
        guard scalars.count > max else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.prefix(max))
        var r = String(out)
        while let last = r.unicodeScalars.last, CharacterSet.whitespaces.contains(last) { r.unicodeScalars.removeLast() }
        return r
    }

    public static func ratio(_ w: Int?, _ h: Int?) -> Double {
        guard let w, let h, w > 0, h > 0 else { return 2 }
        return min(2.4, max(1.5, Double(w) / Double(h)))
    }

    static func hex(_ s: String?, bytes: Int) -> String? {
        guard let s, s.count == bytes * 2, s.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return s
    }

    static let shownTypes: Set<String> = ["image/jpeg", "image/webp", "image/png", "image/gif"]

    /// An `imeta` entry with `purpose preview` as a picture to show, or nil: its URL on the
    /// belfry's Blossom (BLOSSOM's origin exactly; LOCAL: the demo's own prefix), an image type, `x`
    /// (64 hex); with any encryption field, all of `ox`, `encryption-algorithm aes-gcm`,
    /// `decryption-key`, `decryption-nonce`.
    public static func pictureOf(_ t: Tag, blossom: String, local: String? = nil) -> PreviewPicture? {
        guard isPreviewImeta(t) else { return nil }
        var f = [String: String]()
        for p in t.dropFirst() {
            guard let sp = p.firstIndex(of: " "), sp > p.startIndex else { continue }
            let k = String(p[..<sp])
            if f[k] == nil { f[k] = String(p[p.index(after: sp)...]) }
        }
        guard let url = f["url"], !url.contains(where: { $0.isWhitespace }) else { return nil }
        let fromLocal = local.map { url.hasPrefix($0) } ?? false
        if !fromLocal {
            guard let o = originOf(blossom), originOf(url) == o else { return nil }
        }
        guard let mime = f["m"]?.lowercased(), shownTypes.contains(mime), let x = hex(f["x"], bytes: 32) else { return nil }
        let dim = f["dim"]?.components(separatedBy: "x")
        let w = dim.flatMap { $0.count > 0 ? Int($0[0]) : nil }.flatMap { (1...20_000).contains($0) ? $0 : nil }
        let h = dim.flatMap { $0.count > 1 ? Int($0[1]) : nil }.flatMap { (1...20_000).contains($0) ? $0 : nil }
        let sized = w != nil && h != nil && dim?.count == 2
        let enc = ["ox", "encryption-algorithm", "decryption-key", "decryption-nonce"].contains { f[$0] != nil }
        if !enc { return PreviewPicture(url: url, mime: mime, width: sized ? w : nil, height: sized ? h : nil, x: x) }
        guard f["encryption-algorithm"] == "aes-gcm", let ox = hex(f["ox"], bytes: 32), let key = hex(f["decryption-key"], bytes: 32),
              let nonce = hex(f["decryption-nonce"], bytes: 12) else { return nil }
        return PreviewPicture(url: url, mime: mime, width: sized ? w : nil, height: sized ? h : nil, x: x, ox: ox, key: key, nonce: nonce)
    }

    /// What a reader shows for a message (TEXT as it reads now, TAGS of its latest version): nil =
    /// a plain link. Nothing is fetched because of this, but the picture (from the belfry's Blossom).
    public static func read(_ text: String, tags: [Tag], blossom: String, local: String? = nil) -> LinkPreview? {
        if hasNoPreview(tags) { return nil }
        guard let t = tags.first(where: { $0.count >= 2 && $0[0] == "preview" }) else { return nil }
        let url = t[1]
        guard url.hasPrefix("https://"), !url.contains(where: { $0.isWhitespace }), hostOf(url) != nil, text.contains(url) else { return nil }
        let title = words(t.count > 2 ? t[2] : nil, titleMax)
        let description = words(t.count > 3 ? t[3] : nil, descriptionMax)
        if title.isEmpty && description.isEmpty { return nil }
        let site = words(t.count > 4 ? t[4] : nil, siteMax)
        let picture = tags.first(where: isPreviewImeta).flatMap { pictureOf($0, blossom: blossom, local: local) }
        return LinkPreview(url: url, title: title, description: description, site: site, picture: picture)
    }

    /// The https address A resolved against BASE (relative, protocol-relative, absolute), or nil.
    public static func absolute(_ a: String?, base: String) -> String? {
        guard let s = a?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, let b = URL(string: base),
              let r = URL(string: s, relativeTo: b)?.absoluteURL, r.scheme?.lowercased() == "https", r.host != nil else { return nil }
        return r.absoluteString
    }
}

/// Pictures by their first bytes (png / jpeg / webp / gif, nothing else).
public enum PreviewImages {
    public static func kind(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47, b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 6, let s = String(bytes: b[0..<6], encoding: .isoLatin1), s == "GIF87a" || s == "GIF89a" { return "image/gif" }
        if b.count >= 12, String(bytes: b[0..<4], encoding: .isoLatin1) == "RIFF", String(bytes: b[8..<12], encoding: .isoLatin1) == "WEBP" { return "image/webp" }
        return nil
    }
}

// ---- what a page says about itself ------------------------------------------------------------

/// `og:*` first, then `twitter:*`, then `<title>` and `<meta name="description">`. Plain text:
/// tags stripped, entities decoded, whitespace collapsed, cut; `image` absolute https or nil.
public struct PageMeta: Equatable, Sendable {
    public let title: String
    public let description: String
    public let site: String
    public let image: String?
    public var usable: Bool { !title.isEmpty || !description.isEmpty }

    static let comment = Rx("<!--.*?-->", [.dotMatchesLineSeparators])
    static let script = Rx("<(script|style|noscript|template)\\b[^>]*>.*?</\\1\\s*>", [.dotMatchesLineSeparators, .caseInsensitive])
    static let titleRx = Rx("<title\\b[^>]*>(.*?)</title\\s*>", [.dotMatchesLineSeparators, .caseInsensitive])
    static let metaRx = Rx("<meta\\b([^>]*)>", [.dotMatchesLineSeparators, .caseInsensitive])
    static let attrRx = Rx("([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*(?:=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+)))?")
    static let tagRx = Rx("<[^>]*>")
    static let charsetRx = Rx("charset\\s*=\\s*[\"']?([-a-zA-Z0-9_:.]+)", [.caseInsensitive])

    /// The page's text: the charset of CONTENT_TYPE, else a `<meta charset>` in its first 1024
    /// bytes, else UTF-8; a byte order mark goes.
    public static func decode(_ bytes: Data, contentType: String?) -> String {
        let head = String(data: bytes.prefix(1024), encoding: .isoLatin1) ?? ""
        let named = contentType.flatMap { charsetRx.first($0)?[1] } ?? charsetRx.first(head)?[1]
        var enc = String.Encoding.utf8
        if let n = named {
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        var s = String(data: bytes, encoding: enc) ?? String(decoding: bytes, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    static func attrs(_ s: String) -> [String: String] {
        var out = [String: String]()
        for m in attrRx.matches(s) {
            let k = (m[1] ?? "").lowercased()
            if k.isEmpty || out[k] != nil { continue }
            out[k] = m[2] ?? m[3] ?? m[4] ?? ""
        }
        return out
    }

    /// Plain text of a value: tags stripped, entities decoded, whitespace collapsed, at most MAX.
    public static func text(_ v: String?, _ max: Int) -> String {
        LinkPreviews.words(Entities.decode(tagRx.replace(v ?? "", with: " ")), max)
    }

    /// HTML of a page whose final address is BASE.
    public static func parse(_ html: String, base: String) -> PageMeta {
        let clean = script.replace(comment.replace(html, with: " "), with: " ")
        var meta = [String: String]()
        for m in metaRx.matches(clean) {
            let a = attrs(m[1] ?? "")
            guard let content = a["content"] else { continue }
            for k in [a["property"], a["name"]].compactMap({ $0 }) {
                let key = k.trimmingCharacters(in: .whitespaces).lowercased()
                if !key.isEmpty && meta[key] == nil { meta[key] = content }
            }
        }
        func first(_ max: Int, _ keys: String...) -> String {
            for k in keys { let t = text(meta[k], max); if !t.isEmpty { return t } }
            return ""
        }
        var title = first(LinkPreviews.titleMax, "og:title", "twitter:title")
        if title.isEmpty { title = text(titleRx.first(clean)?[1], LinkPreviews.titleMax) }
        let description = first(LinkPreviews.descriptionMax, "og:description", "twitter:description", "description")
        let site = first(LinkPreviews.siteMax, "og:site_name", "application-name")
        var image: String?
        for k in ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"] {
            guard let v = meta[k].map({ Entities.decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }), !v.isEmpty else { continue }
            image = LinkPreviews.absolute(v, base: base)
            break
        }
        return PageMeta(title: title, description: description, site: site, image: image)
    }
}

/// HTML character references: numeric ones and the named ones pages put in titles. Unknown names stay as written.
public enum Entities {
    static let ref = Rx("&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});")
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "agrave": "à", "aacute": "á", "acirc": "â", "ccedil": "ç",
        "iacute": "í", "oacute": "ó", "ocirc": "ô", "uacute": "ú", "ntilde": "ñ",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "Eacute": "É", "euro": "€", "pound": "£", "deg": "°", "times": "×",
    ]

    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in ref.matches(s) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let v = m[1] ?? ""
            if v.hasPrefix("#") {
                let hexed = v.count > 1 && (v.dropFirst().first == "x" || v.dropFirst().first == "X")
                let cp = (hexed ? UInt32(v.dropFirst(2), radix: 16) : UInt32(v.dropFirst())) ?? 0xFFFD
                let ok = (1...0x10FFFF).contains(cp) && !(0xD800...0xDFFF).contains(cp)
                out.unicodeScalars.append(Unicode.Scalar(ok ? cp : 0xFFFD) ?? "\u{FFFD}")
            } else {
                out += named[v] ?? m.whole
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

// ---- the fetching rules (SSRF) -------------------------------------------------------------------

public enum FetchRules {
    static let ipv4 = Rx("^[0-9]+(\\.[0-9]+){3}$")
    static let numeric = Rx("^[0-9.]+$|^0x[0-9a-f.x]+$", [.caseInsensitive])
    static let blockedSuffixes = [".localhost", ".local", ".internal", ".arpa", ".home.arpa", ".lan", ".onion"]

    /// URL when a preview may ask it, else nil: `https` only, port 443, no user name or password, a
    /// name (not an IP literal, not a bare number), with a dot, not localhost or a local-only suffix.
    public static func url(_ url: String) -> URL? {
        guard let c = URLComponents(string: url), c.scheme?.lowercased() == "https", c.port == nil || c.port == 443,
              c.user == nil, c.password == nil, var h = c.host?.lowercased(), let u = c.url else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        if h.isEmpty || h.contains(":") || h.hasPrefix("[") || ipv4.test(h) || numeric.test(h) { return nil }
        if !h.contains(".") { return nil }
        if h == "localhost" || blockedSuffixes.contains(where: { h.hasSuffix($0) }) { return nil }
        return u
    }

    static func v4Allowed(_ b: [UInt8]) -> Bool {
        let a = b[0], c = b[1], d = b[2]
        switch true {
        case a == 0, a == 10, a == 127: return false
        case a == 100 && (64...127).contains(c): return false
        case a == 169 && c == 254: return false
        case a == 172 && (16...31).contains(c): return false
        case a == 192 && c == 0 && d == 0, a == 192 && c == 0 && d == 2, a == 192 && c == 88 && d == 99, a == 192 && c == 168: return false
        case a == 198 && (c == 18 || c == 19), a == 198 && c == 51 && d == 100, a == 203 && c == 0 && d == 113: return false
        case a >= 224: return false
        default: return true
        }
    }

    /// The address's bytes (4 or 16), from its text.
    public static func bytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// ADDRESS (4 or 16 bytes) may be connected to for a preview: public unicast only.
    public static func allowed(_ b: [UInt8]) -> Bool {
        if b.count == 4 { return v4Allowed(b) }
        guard b.count == 16 else { return false }
        func zero(_ r: Range<Int>) -> Bool { r.allSatisfy { b[$0] == 0 } }
        if zero(0..<10) && b[10] == 0xff && b[11] == 0xff { return v4Allowed(Array(b[12..<16])) }
        if zero(0..<12) { return false }
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && zero(4..<12) { return v4Allowed(Array(b[12..<16])) }
        if b[0] == 0x01 && b[1] == 0x00 && zero(2..<8) { return false }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 { return false }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }
        if b[0] == 0x20 && b[1] == 0x02 { return v4Allowed(Array(b[2..<6])) }
        if b[0] & 0xfe == 0xfc { return false }
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }
        if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return false }
        if b[0] == 0xff { return false }
        return true
    }

    public static func allowed(_ address: String) -> Bool { bytes(address).map(allowed) ?? false }

    /// Every address the name resolved to must be allowed, and there must be one.
    public static func allAllowed(_ addresses: [String]) -> Bool { !addresses.isEmpty && addresses.allSatisfy(allowed) }

    public static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
}

/// Names to addresses (the system's resolver in the app, a table in tests and the demo).
public protocol PreviewResolver: Sendable {
    func resolve(_ host: String) async -> [String]
}

/// One answer: BODY at most the bytes asked for; `overflow` = there were more.
public struct NetAnswer: Sendable {
    public var status: Int
    public var location: String?
    public var contentType: String?
    public var contentLength: Int?
    public var body: Data
    public var overflow: Bool
    public init(status: Int, location: String? = nil, contentType: String? = nil, contentLength: Int? = nil, body: Data = Data(), overflow: Bool = false) {
        self.status = status; self.location = location; self.contentType = contentType; self.contentLength = contentLength; self.body = body; self.overflow = overflow
    }
}

/// One GET, never following a redirect, connecting ONLY to ADDRESSES for HOST (what was resolved
/// and approved), no cookies, no credentials, within TIMEOUT; reads at most MAX bytes of the body.
/// Nil: no answer.
public protocol PreviewNet: Sendable {
    func get(_ url: URL, host: String, addresses: [String], accept: String, maxBytes: Int, timeout: TimeInterval) async -> NetAnswer?
}

/// The preview's fetches: every hop checked by `FetchRules.url`, its name resolved and refused
/// unless every address is public, then asked of exactly those addresses; at most 3 redirects;
/// 5 s for the whole of one fetch.
public struct SafeFetch: Sendable {
    public enum Why: String, Sendable { case url, resolve, address, noAnswer, status, redirects, timeout, type, size }
    public enum Result: Sendable {
        case ok(finalURL: String, answer: NetAnswer)
        case refused(Why)
    }

    let net: PreviewNet
    let resolver: PreviewResolver
    let timeout: TimeInterval

    public init(net: PreviewNet, resolver: PreviewResolver, timeout: TimeInterval = LinkPreviews.timeout) {
        self.net = net; self.resolver = resolver; self.timeout = timeout
    }

    func follow(_ start: String, accept: String, maxBytes: Int) async -> Result {
        let end = Date().addingTimeInterval(timeout)
        var current = start
        for hop in 0...LinkPreviews.redirects {
            guard let u = FetchRules.url(current), var host = u.host?.lowercased() else { return .refused(.url) }
            while host.hasSuffix(".") { host.removeLast() }
            let addresses = await resolver.resolve(host)
            if addresses.isEmpty { return .refused(.resolve) }
            if !FetchRules.allAllowed(addresses) { return .refused(.address) }
            let left = end.timeIntervalSinceNow
            if left <= 0 { return .refused(.timeout) }
            guard let a = await net.get(u, host: host, addresses: addresses, accept: accept, maxBytes: maxBytes, timeout: left) else { return .refused(.noAnswer) }
            if FetchRules.redirectStatuses.contains(a.status) {
                if hop == LinkPreviews.redirects { return .refused(.redirects) }
                guard let loc = a.location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty,
                      let next = URL(string: loc, relativeTo: u)?.absoluteURL else { return .refused(.status) }
                current = next.absoluteString
                continue
            }
            if a.status != 200 { return .refused(.status) }
            return .ok(finalURL: u.absoluteString, answer: a)
        }
        return .refused(.redirects)
    }

    /// The page: `text/html` only, its first 512 kB.
    public func page(_ url: String) async -> Result {
        let r = await follow(url, accept: "text/html", maxBytes: LinkPreviews.pageMax)
        guard case .ok(_, let a) = r else { return r }
        let type = a.contentType?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return type == "text/html" ? r : .refused(.type)
    }

    /// The picture: at most 5 MB (more: refused), a PNG, JPEG, WebP or GIF by its first bytes.
    public func picture(_ url: String) async -> Result {
        let r = await follow(url, accept: "image/png,image/jpeg,image/webp,image/gif", maxBytes: LinkPreviews.pictureInMax)
        guard case .ok(_, let a) = r else { return r }
        if a.overflow || a.body.count > LinkPreviews.pictureInMax || (a.contentLength ?? 0) > LinkPreviews.pictureInMax { return .refused(.size) }
        return PreviewImages.kind(a.body) == nil ? .refused(.type) : r
    }
}

// ---- building one on the sender's device ---------------------------------------------------------

/// A picture re-encoded for upload: JPEG or WebP, its size in pixels.
public struct EncodedPicture: Sendable {
    public let bytes: Data
    public let mime: String
    public let width: Int
    public let height: Int
    public init(bytes: Data, mime: String, width: Int, height: Int) { self.bytes = bytes; self.mime = mime; self.width = width; self.height = height }
}

/// Re-encodes a downloaded picture (the app's: ImageIO): JPEG, the longest side at most 1200 px,
/// at most 300 kB. Nil: it can't (the preview goes without a picture).
public protocol PictureEncoder: Sendable {
    func encode(_ bytes: Data, mime: String) -> EncodedPicture?
}

/// The page, what it says, then its picture: downloaded, re-encoded, checked, encrypted when
/// `.encrypted` (a fresh key and nonce), uploaded; kept only when its URL is on the belfry's
/// Blossom. Nothing usable → nil. A picture that fails in any way → the preview without it.
public struct PreviewBuilder: Sendable {
    let fetch: SafeFetch
    let encoder: PictureEncoder?
    let upload: @Sendable (Data, String) async throws -> String
    let blossom: String
    let local: String?
    let keyNonce: (@Sendable () -> (Data, Data))?
    let keep: @Sendable (String, Data) -> Void

    public init(fetch: SafeFetch, encoder: PictureEncoder?, upload: @escaping @Sendable (Data, String) async throws -> String, blossom: String,
                local: String? = nil, keyNonce: (@Sendable () -> (Data, Data))? = nil, keep: @escaping @Sendable (String, Data) -> Void = { _, _ in }) {
        self.fetch = fetch; self.encoder = encoder; self.upload = upload; self.blossom = blossom; self.local = local; self.keyNonce = keyNonce; self.keep = keep
    }

    public func build(_ url: String, mode: PreviewMode) async -> LinkPreview? {
        guard case .ok(let final, let a) = await fetch.page(url) else { return nil }
        let html = PageMeta.decode(a.body.prefix(LinkPreviews.pageMax), contentType: a.contentType)
        let meta = PageMeta.parse(html, base: final)
        guard meta.usable else { return nil }
        let picture = await meta.image.asyncMap { await self.picture($0, mode: mode) } ?? nil
        return LinkPreview(url: url, title: meta.title, description: meta.description, site: meta.site, picture: picture)
    }

    func onBlossom(_ u: String) -> Bool {
        if let local, u.hasPrefix(local) { return true }
        guard let o = LinkPreviews.originOf(blossom) else { return false }
        return LinkPreviews.originOf(u) == o
    }

    func accept(_ e: EncodedPicture) -> Bool {
        (e.mime == "image/jpeg" || e.mime == "image/webp") && PreviewImages.kind(e.bytes) == e.mime &&
            (1...LinkPreviews.pictureSide).contains(e.width) && (1...LinkPreviews.pictureSide).contains(e.height) &&
            (1...LinkPreviews.pictureOutMax).contains(e.bytes.count)
    }

    func picture(_ image: String, mode: PreviewMode) async -> PreviewPicture? {
        guard let encoder, case .ok(_, let a) = await fetch.picture(image), let kind = PreviewImages.kind(a.body),
              let e = encoder.encode(a.body, mime: kind), accept(e) else { return nil }
        do {
            if mode == .encrypted {
                let (k, n) = keyNonce?() ?? (Crypto.random(32), Crypto.random(12))
                let cipher = try DmFiles.encrypt(e.bytes, key: k, nonce: n)
                let u = try await upload(cipher, "application/octet-stream")
                guard onBlossom(u) else { return nil }
                let x = Crypto.sha256(cipher).hex
                keep(x, e.bytes)
                return PreviewPicture(url: u, mime: e.mime, width: e.width, height: e.height, x: x, ox: Crypto.sha256(e.bytes).hex, key: k.hex, nonce: n.hex)
            }
            let u = try await upload(e.bytes, e.mime)
            guard onBlossom(u) else { return nil }
            let x = Crypto.sha256(e.bytes).hex
            keep(x, e.bytes)
            return PreviewPicture(url: u, mime: e.mime, width: e.width, height: e.height, x: x)
        } catch { return nil }
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        switch self {
        case .some(let w): return await f(w)
        case .none: return nil
        }
    }
}
