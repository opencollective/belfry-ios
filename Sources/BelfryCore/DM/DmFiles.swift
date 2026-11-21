import CryptoKit
import Foundation

// Pictures, files and audio recordings in direct messages (the lead's contract 2026-11-21; NIP-17
// kind 15; vectors/dm-files.json, belfry-android's). Each file is one kind 15 rumor wrapped like a
// kind 14. The device encrypts the file with AES-256-GCM (a fresh 32-byte key and 12-byte nonce,
// no associated data, the 16-byte tag appended) and uploads only the ciphertext. Readers download,
// check x, decrypt, check ox: any mismatch or a missing / malformed tag is "This file can't be
// opened", never the bytes.

/// A file of a kind 15 rumor, as its tags say.
public struct DmFile: Codable, Hashable, Sendable {
    public var url: String
    public var mime: String
    public var key: String
    public var nonce: String
    public var x: String
    public var ox: String
    public var size: Int
    public var name: String?
    public var dim: String?
    public var blurhash: String?
    public var thumb: String?
    public var thumbNonce: String?
    public var duration: Int?
    public var group: String?

    public init(url: String, mime: String, key: String, nonce: String, x: String, ox: String, size: Int, name: String? = nil, dim: String? = nil,
                blurhash: String? = nil, thumb: String? = nil, thumbNonce: String? = nil, duration: Int? = nil, group: String? = nil) {
        self.url = url; self.mime = mime; self.key = key; self.nonce = nonce; self.x = x; self.ox = ox; self.size = size; self.name = name
        self.dim = dim; self.blurhash = blurhash; self.thumb = thumb; self.thumbNonce = thumbNonce; self.duration = duration; self.group = group
    }

    public var isPicture: Bool { mime.lowercased().hasPrefix("image/") }
    public var isAudio: Bool { mime.lowercased().hasPrefix("audio/") }
    /// "1200x800" → (1200, 800)
    public var size2: (w: Int, h: Int)? {
        guard let d = dim?.split(separator: "x"), d.count == 2, let w = Int(d[0]), let h = Int(d[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }
    /// The name shown (the names section).
    public var shownName: String { DmFiles.shownName(name, mime: mime) }
}

public enum DmFiles {
    public static let kind = 15
    public static let maxBytes = 25_000_000
    public static let guestMaxBytes = 5_000_000
    public static let unreadable = "This file can't be opened"
    public static func tooLarge(guest: Bool) -> String { guest ? "This file is too large (5 MB at most)" : "This file is too large (25 MB at most)" }

    // ---- the cipher ------------------------------------------------------------------------------

    /// AES-256-GCM: the ciphertext with its 16-byte tag appended. KEY 32 bytes, NONCE 12 bytes.
    public static func encrypt(_ plain: Data, key: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 12 else { throw BelfryError.crypto("bad key or nonce") }
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
        return box.ciphertext + box.tag
    }

    /// The plain bytes, or nil when anything is off (a wrong key, a changed byte, a short input).
    public static func decrypt(_ cipher: Data, key: Data, nonce: Data) -> Data? {
        guard key.count == 32, nonce.count == 12, cipher.count >= 16, let n = try? AES.GCM.Nonce(data: nonce) else { return nil }
        let body = cipher.prefix(cipher.count - 16), tag = cipher.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: n, ciphertext: body, tag: tag) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    /// A fresh key and nonce for one file.
    public static func freshKey() -> (key: Data, nonce: Data) { (Crypto.random(32), Crypto.random(12)) }
    public static func freshNonce() -> Data { Crypto.random(12) }
    /// A group tag: 16 hex.
    public static func freshGroup() -> String { Crypto.random(8).hex }

    // ---- the rumor's tags ------------------------------------------------------------------------

    /// The tags in the contract's order: p per other participant, file-type, encryption-algorithm,
    /// decryption-key, decryption-nonce, x, ox, size, then name, dim, blurhash, thumb + thumb-nonce,
    /// duration, group.
    public static func tags(others: [String], file f: DmFile) -> [Tag] {
        var t: [Tag] = others.map { ["p", $0] }
        t += [["file-type", f.mime], ["encryption-algorithm", "aes-gcm"], ["decryption-key", f.key], ["decryption-nonce", f.nonce],
              ["x", f.x], ["ox", f.ox], ["size", String(f.size)]]
        if let n = f.name { t.append(["name", n]) }
        if let d = f.dim { t.append(["dim", d]) }
        if let b = f.blurhash { t.append(["blurhash", b]) }
        if let u = f.thumb, let n = f.thumbNonce { t.append(["thumb", u]); t.append(["thumb-nonce", n]) }
        if let d = f.duration { t.append(["duration", String(d)]) }
        if let g = f.group { t.append(["group", g]) }
        return t
    }

    static func hex(_ s: String?, bytes: Int) -> String? {
        guard let s, s.count == bytes * 2, let d = Data(hex: s), d.count == bytes else { return nil }
        return s.lowercased()
    }

    /// The file a kind 15 rumor carries; nil when a tag the reader needs is missing or malformed.
    public static func parse(tags: [Tag], content: String) -> DmFile? {
        func v(_ k: String) -> String? { tags.first { $0.count >= 2 && $0[0] == k }?[1] }
        guard v("encryption-algorithm") == "aes-gcm",
              let mime = v("file-type"), !mime.isEmpty,
              let key = hex(v("decryption-key"), bytes: 32),
              let nonce = hex(v("decryption-nonce"), bytes: 12),
              let x = hex(v("x"), bytes: 32),
              let ox = hex(v("ox"), bytes: 32),
              let size = v("size").flatMap(Int.init), size >= 0 else { return nil }
        let thumbNonce = hex(v("thumb-nonce"), bytes: 12)
        return DmFile(url: content.trimmingCharacters(in: .whitespacesAndNewlines), mime: mime, key: key, nonce: nonce, x: x, ox: ox, size: size,
                      name: v("name"), dim: v("dim"), blurhash: v("blurhash"), thumb: thumbNonce == nil ? nil : v("thumb"), thumbNonce: thumbNonce,
                      duration: v("duration").flatMap(Int.init), group: v("group").flatMap { hex($0, bytes: 8) })
    }

    /// The plain file from what was downloaded: x checked, decrypted, ox checked; nil otherwise.
    public static func open(_ f: DmFile, downloaded: Data) -> Data? {
        guard Crypto.sha256(downloaded).hex == f.x, let key = Data(hex: f.key), let nonce = Data(hex: f.nonce),
              let plain = decrypt(downloaded, key: key, nonce: nonce), Crypto.sha256(plain).hex == f.ox else { return nil }
        return plain
    }

    /// The thumbnail: the file's key, its own nonce (GCM's tag checks it).
    public static func openThumb(_ f: DmFile, downloaded: Data) -> Data? {
        guard let n = f.thumbNonce, let key = Data(hex: f.key), let nonce = Data(hex: n) else { return nil }
        return decrypt(downloaded, key: key, nonce: nonce)
    }

    /// One file ready to go: its ciphertext and the file as the rumor will say it (URL set after upload).
    public static func prepare(_ plain: Data, mime: String, name: String?, dim: String? = nil, duration: Int? = nil, group: String? = nil,
                               key: Data? = nil, nonce: Data? = nil) throws -> (cipher: Data, file: DmFile) {
        let k = key ?? Crypto.random(32), n = nonce ?? Crypto.random(12)
        let cipher = try encrypt(plain, key: k, nonce: n)
        let f = DmFile(url: "", mime: mime, key: k.hex, nonce: n.hex, x: Crypto.sha256(cipher).hex, ox: Crypto.sha256(plain).hex, size: plain.count,
                       name: name, dim: dim, duration: duration, group: group)
        return (cipher, f)
    }

    // ---- names -----------------------------------------------------------------------------------

    static let directionMarks: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    /// The last path segment, without control characters or direction marks, trimmed, at most 200
    /// UTF-16 units; else File / Picture / Audio recording.
    public static func shownName(_ name: String?, mime: String) -> String {
        var s = name ?? ""
        if let i = s.lastIndex(where: { $0 == "/" || $0 == "\\" }) { s = String(s[s.index(after: i)...]) }
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars where !(u.properties.generalCategory == .control) && !directionMarks.contains(u.value) { scalars.append(u) }
        s = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.utf16.count > 200 {
            var out = ""
            for ch in s { if out.utf16.count + ch.utf16.count > 200 { break }; out.append(ch) }
            s = out
        }
        if !s.isEmpty { return s }
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return "Picture" }
        if m.hasPrefix("audio/") { return "Audio recording" }
        return "File"
    }

    /// "PDF · 1.2 MB"
    public static func typeAndSize(_ f: DmFile) -> String {
        let ext = (f.name.flatMap { n -> String? in let e = (n as NSString).pathExtension; return e.isEmpty ? nil : e }) ?? f.mime.split(separator: "/").last.map(String.init) ?? ""
        let mb = Double(f.size) / 1_000_000
        let size = mb >= 0.1 ? String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), mb) : "\(max(1, f.size / 1000)) KB"
        return ext.isEmpty ? size : ext.uppercased() + " · " + size
    }

    // ---- bubbles ---------------------------------------------------------------------------------

    public struct Piece: Hashable, Sendable {
        public var id: String
        public var kind: Int
        public var author: String
        public var at: Int
        public var group: String?
        public init(id: String, kind: Int, author: String, at: Int, group: String?) { self.id = id; self.kind = kind; self.author = author; self.at = at; self.group = group }
    }

    public struct Bubble: Hashable, Sendable {
        public var files: [String]
        public var caption: String?
        public var at: Int
    }

    /// Rumors as they arrived (any order) → bubbles in time order: a group (same author, same group)
    /// is one bubble, its files by created_at (ties: rumor id), the kind 14 with the group its
    /// caption; a bubble's time is its first rumor's.
    public static func bubbles(_ pieces: [Piece]) -> [Bubble] {
        let ordered = pieces.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
        var out = [Bubble]()
        var byGroup = [String: Int]()
        for p in ordered {
            if let g = p.group {
                let key = p.author + "/" + g
                if let i = byGroup[key] {
                    if p.kind == 15 { out[i].files.append(p.id) } else if out[i].caption == nil { out[i].caption = p.id } else { out.append(Bubble(files: [], caption: p.id, at: p.at)) }
                    continue
                }
                byGroup[key] = out.count
            }
            out.append(p.kind == 15 ? Bubble(files: [p.id], caption: nil, at: p.at) : Bubble(files: [], caption: p.id, at: p.at))
        }
        return out
    }

    /// The conversation list's last line for a bubble of FILES: "Picture", "3 pictures",
    /// "File: Garden plan 2027.pdf", "Audio recording · 0:42".
    public static func lastLine(_ files: [DmFile]) -> String {
        guard let f = files.first else { return "" }
        if files.count > 1 {
            if files.allSatisfy(\.isPicture) { return "\(files.count) pictures" }
            return "\(files.count) files"
        }
        if f.isPicture { return "Picture" }
        if f.isAudio { return "Audio recording" + (f.duration.map { " · " + clock($0) } ?? "") }
        return "File: " + f.shownName
    }

    /// 42 → "0:42"
    public static func clock(_ s: Int) -> String { "\(s / 60):" + String(format: "%02d", s % 60) }
}
