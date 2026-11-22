import Foundation

// An e-mail's parts for the Messages thread (pictures inline, 2026-11-22). A small e-mail is its
// rumor's content (kept with the message). A large one is on the file server, encrypted: it is
// fetched and opened on this device the first time it is shown, kept in the app's private folder
// (so it opens offline afterwards), and its text, sender name and attachment list replace the
// placeholder in the thread.

extension DirectMessages {
    var mailDir: URL {
        let d = engine.attachmentsDir.appendingPathComponent("mail", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func mailPath(_ rid: String) -> URL { mailDir.appendingPathComponent(rid + ".eml") }

    /// Demo and tests: a large e-mail's text as if it had been fetched.
    public func keepMail(_ raw: String, for rid: String) {
        try? Data(raw.utf8).write(to: mailPath(rid), options: .completeFileProtection)
    }

    /// The e-mail DM as it was sent (nil: not an e-mail, or it can't be fetched or opened now).
    public func mail(_ dm: Dm) async -> ParsedMail? {
        guard dm.kind == 1301 else { return nil }
        if let raw = dm.raw, !raw.isEmpty { return MIME.parse(raw) }
        let path = mailPath(dm.rid)
        if let d = try? Data(contentsOf: path) { return adopt(MIME.parse(String(decoding: d, as: UTF8.self)), for: dm.rid) }
        guard let l = dm.large, !engine.localOnly, let u = URL(string: l.url), u.scheme == "https" else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200,
              let raw = l.open(data) else { return nil }
        try? Data(raw.utf8).write(to: path, options: .completeFileProtection)
        return adopt(MIME.parse(raw), for: dm.rid)
    }

    /// A large e-mail was opened: its text and attachment list take the placeholder's place.
    @discardableResult
    func adopt(_ m: ParsedMail, for rid: String) -> ParsedMail {
        lock.lock()
        guard var d = items[rid], d.raw == nil else { lock.unlock(); return m }
        let before = d
        d.text = m.text
        if !m.subject.isEmpty { d.subject = m.subject }
        let name = MIME.address(m.from).name
        if !name.isEmpty { d.fromName = name }
        d.messageId = m.headers["message-id"] ?? d.messageId
        d.references = m.headers["references"] ?? d.references
        d.attachments = m.attachments.map { Dm.AttachmentInfo(name: $0.name, type: $0.type, size: $0.data.count) }
        let changed = d != before
        if changed { items[rid] = d }
        lock.unlock()
        if changed { save() }
        return m
    }
}
