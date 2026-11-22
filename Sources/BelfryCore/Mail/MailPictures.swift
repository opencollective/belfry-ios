import Foundation

// Pictures in a message show in the message (Xavier via the lead, 2026-11-22: "Images should be
// displayed inline instead of linked as a file"): everywhere an attachment's type is an image
// (jpeg, png, gif, webp, heic) it is a picture, one large or several in a grid, tap = the zoom
// viewer; pictures inline in an HTML mail come after the text, in the mail's order. Other files
// stay file rows; a picture that can't be loaded or decrypted is a file row too.

public enum MailPictures {
    static let types: Set<String> = ["image/jpeg", "image/jpg", "image/pjpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif"]
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]

    /// A picture by its type; with no type, or a generic one (some mail clients send
    /// application/octet-stream), by its file name's extension.
    public static func isPicture(type: String?, name: String?) -> Bool {
        let t = (type ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if types.contains(t) { return true }
        guard t.isEmpty || t == "application/octet-stream" || t == "binary/octet-stream" else { return false }
        let n = (name ?? "").split(separator: "?").first.map(String.init) ?? ""
        guard let dot = n.lastIndex(of: ".") else { return false }
        return extensions.contains(n[n.index(after: dot)...].lowercased())
    }

    /// A mail's parts in its order: the pictures, then the other files.
    public static func split(_ parts: [MailPart]) -> (pictures: [MailPart], files: [MailPart]) {
        (parts.filter { isPicture(type: $0.type, name: $0.name) }, parts.filter { !isPicture(type: $0.type, name: $0.name) })
    }
}

/// The letters on a face without a picture (one-shape.md "The Messages list: faces, not envelopes").
public enum MailInitials {
    /// The first letters of the first and the last word of the name ("Ana Maria Silva" → "AS",
    /// "Lina" → "L"); no name: the first letter of the address.
    public static func of(name: String?, address: String) -> String {
        let words = (name ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if let first = words.first?.first {
            let last = words.count > 1 ? words.last?.first : nil
            return (String(first) + (last.map(String.init) ?? "")).uppercased()
        }
        let a = address.trimmingCharacters(in: .whitespaces)
        return a.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }
}

/// A large e-mail kept on the file server (SPEC 8: `x`, `url`, `decryption-key`,
/// `decryption-nonce`; AES-256-GCM, key and nonce base64).
public struct LargeMail: Codable, Hashable, Sendable {
    public let url: String
    public let key: String
    public let nonce: String
    public let x: String?

    public init?(tags: [Tag]) {
        func v(_ n: String) -> String? { tags.first { $0.count >= 2 && $0[0] == n }?[1] }
        guard let url = v("url"), url.hasPrefix("https://"), let key = v("decryption-key"), let nonce = v("decryption-nonce"),
              Data(base64Encoded: key)?.count == 32, Data(base64Encoded: nonce) != nil else { return nil }
        self.url = url; self.key = key; self.nonce = nonce; self.x = v("x")
    }

    /// The e-mail as it was sent, from what the file server returned (nil: it does not open).
    public func open(_ downloaded: Data) -> String? {
        guard let k = Data(base64Encoded: key), let n = Data(base64Encoded: nonce),
              let plain = try? Crypto.aesGCMOpen(key: k, nonce: n, sealed: downloaded) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }
}
