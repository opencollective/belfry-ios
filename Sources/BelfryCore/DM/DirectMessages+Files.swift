import Foundation

// Sending and reading files in direct messages (vectors/dm-files.json). A file waits on this
// device until it is out: kept under its plain sha256 in the app's private folder, listed in
// `dm-file-queue`. Its steps (encrypting, uploading, then the wraps through the outbox) go to the
// send trace; the bubble shows the same line as a text message. The upload is resumed after a
// restart or Retry; a refused upload (4xx except 401 / 408 / 429) fails it.

/// A file chosen to send.
public struct OutgoingFile: Sendable {
    public var data: Data
    public var mime: String
    public var name: String?
    public var dim: String?
    public var duration: Int?
    public init(data: Data, mime: String, name: String?, dim: String? = nil, duration: Int? = nil) {
        self.data = data; self.mime = mime; self.name = name; self.dim = dim; self.duration = duration
    }
}

/// A file not out yet (stored in `dm-file-queue`). After the upload it keeps its key, nonce and
/// URL, so a retry wraps the same rumor and never uploads again.
struct QueuedFile: Codable, Hashable, Sendable {
    var localId: String
    var conv: String
    var file: DmFile
    var createdAt: Int
    var uploaded = false
    /// Its rumor's id once uploaded (the bubble's and the trace's id from then on).
    var rid: String?
    var key: String { rid ?? localId }
}

extension DirectMessages {
    /// The app's private folder for files of direct messages (plain, by their sha256).
    var filesDir: URL {
        let d = engine.attachmentsDir.appendingPathComponent("dm", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func plainPath(_ ox: String) -> URL { filesDir.appendingPathComponent(ox) }

    var queue: [String: QueuedFile] {
        get { db.get("dm-file-queue", as: [String: QueuedFile].self) ?? [:] }
        set { db.set("dm-file-queue", newValue) }
    }

    private func updateQueue(_ f: (inout [String: QueuedFile]) -> Void) {
        lock.lock(); var q = queue; f(&q); queue = q; lock.unlock()
    }

    /// Sends FILES to CONV, each its own kind 15 (several, or with a CAPTION: one group, created_at
    /// strictly increasing, the caption a kind 14 after them). Over 25 MB (5 MB for a guest) nothing
    /// is sent: it throws "This file is too large (25 MB at most)".
    public func sendFiles(_ files: [OutgoingFile], caption: String? = nil, in conv: String, guest: Bool = false) async throws {
        try engine.guestMode.check()
        let limit = guest ? DmFiles.guestMaxBytes : DmFiles.maxBytes
        guard files.allSatisfy({ $0.data.count <= limit }) else { throw BelfryError.invalid(DmFiles.tooLarge(guest: guest)) }
        let to = MailThreads.peers(conv).filter { $0 != me }
        guard !files.isEmpty, !to.isEmpty, to.allSatisfy(isHex64) else { throw BelfryError.invalid("This is not a valid Nostr key.") }
        onSend?()
        let text = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let group = files.count > 1 || !text.isEmpty ? DmFiles.freshGroup() : nil
        var ids = [String]()
        for o in files {
            let ox = Crypto.sha256(o.data).hex
            try o.data.write(to: plainPath(ox))
            let f = DmFile(url: "", mime: o.mime, key: "", nonce: "", x: "", ox: ox, size: o.data.count, name: o.name, dim: o.dim, duration: o.duration, group: group)
            let q = QueuedFile(localId: "local-" + Crypto.random(8).hex, conv: conv, file: f, createdAt: engine.nextCreatedAt())
            var d = Dm(rid: q.localId, conv: conv, from: me, mine: true, at: q.createdAt, kind: DmFiles.kind, text: DmFiles.lastLine([f]))
            d.file = f
            d.group = group
            d.pending = true
            lock.lock(); items[q.localId] = d; lock.unlock()
            updateQueue { $0[q.localId] = q }
            ids.append(q.localId)
        }
        save()
        if !text.isEmpty { try await send(text, in: conv, group: group) }
        Task { for id in ids { await self.run(id) } }
    }

    /// Every file still waiting goes again (after a restart, Retry, back online).
    public func resumeFiles() {
        lock.lock()
        let waiting = queue.values.sorted { $0.createdAt < $1.createdAt }
        for q in waiting { items[q.key]?.failed = nil; items[q.key]?.pending = true }
        lock.unlock()
        let ids = waiting.map(\.localId)
        guard !ids.isEmpty else { return }
        save()
        Task { for id in ids { await self.run(id) } }
    }

    private static let runningLock = NSLock()
    nonisolated(unsafe) private static var running = Set<String>()

    /// One file: encrypted and uploaded (once), then its rumor wrapped to everyone and to me
    /// through the outbox. A transient failure waits 1, 2, 4, 8, 16, 30 s and tries again (six times
    /// in this run; Retry or the next start goes on); a refusal marks it "Not sent".
    func run(_ id: String) async {
        DirectMessages.runningLock.lock()
        let fresh = DirectMessages.running.insert(id).inserted
        DirectMessages.runningLock.unlock()
        guard fresh else { return }
        defer { DirectMessages.runningLock.lock(); DirectMessages.running.remove(id); DirectMessages.runningLock.unlock() }
        let trace = engine.trace
        let local = engine.localOnly
        for attempt in 0..<6 {
            lock.lock(); let q = queue[id]; lock.unlock()
            guard var q else { return }
            do {
                if !q.uploaded {
                    if !local { trace.step(id, label: "DM", SendState.prepare) }
                    let plain = try Data(contentsOf: plainPath(q.file.ox))
                    let (cipher, prepared) = try DmFiles.prepare(plain, mime: q.file.mime, name: q.file.name, dim: q.file.dim, duration: q.file.duration, group: q.file.group)
                    let url: String
                    if local {
                        url = "https://blossom.demo.belfry.sh/" + prepared.x
                    } else {
                        trace.step(id, label: "DM", SendState.uploading(0, Int64(cipher.count)))
                        url = try await engine.upload(cipher, name: "file", mime: "application/octet-stream", sha: prepared.x) { sent, total in
                            trace.step(id, label: "DM", SendState.uploading(sent, total))
                        }
                    }
                    var f = prepared
                    f.url = url
                    q.file = f
                    q.uploaded = true
                    let done = q
                    updateQueue { $0[id] = done }
                }
                let to = MailThreads.peers(q.conv).filter { $0 != me }
                let rumor = GiftWrap.rumor(kind: DmFiles.kind, pubkey: me, tags: DmFiles.tags(others: to, file: q.file), content: q.file.url, createdAt: q.createdAt)
                if q.rid == nil {
                    q.rid = rumor.id
                    let named = q
                    updateQueue { $0[id] = named }
                }
                // the bubble takes the rumor's id (my own copy coming back finds it)
                lock.lock()
                var d = items.removeValue(forKey: id) ?? items[rumor.id] ?? Dm(rid: rumor.id, conv: q.conv, from: me, mine: true, at: q.createdAt, kind: DmFiles.kind, text: "")
                d.rid = rumor.id
                d.file = q.file
                d.text = DmFiles.lastLine([q.file])
                d.pending = local ? nil : true
                d.failed = nil
                // the rumor stays with the message: a wrap queued before a restart can be checked again
                d.rumor = Sealed.json(rumor)
                items[rumor.id] = d
                lock.unlock()
                save()
                if !local, id != rumor.id { trace.rename(id, rumor.id) }
                // sealed like a kind 14 in a sealed conversation, never the old way into one
                try await deliver(rumor, to: to, conv: q.conv)
                updateQueue { $0[id] = nil }
                return
            } catch {
                let msg = (error as? BelfryError)?.relayMessage ?? "timeout: \(error.localizedDescription)"
                lock.lock(); let key = queue[id]?.key ?? id; lock.unlock()
                if Outbox.classify(msg) == .failed {
                    lock.lock(); items[key]?.failed = msg; lock.unlock()
                    if !local { trace.end(key, "refused", left: false) }
                    save()
                    return
                }
                if !local { trace.end(key, "retry (" + String(String(msg.split(separator: ":").first ?? "").prefix(24)) + ")", left: true) }
                try? await Task.sleep(nanoseconds: UInt64(SyncEngine.step(attempt) * 1_000_000_000))
            }
        }
    }

    /// Retry on a file that is not out: every waiting file goes again.
    public func retryFile(_ d: Dm) {
        lock.lock(); items[d.rid]?.failed = nil; items[d.rid]?.pending = true; lock.unlock()
        save()
        resumeFiles()
    }

    /// The plain bytes of F: from this device's private folder, else downloaded, x checked,
    /// decrypted, ox checked, and kept. Nil: "This file can't be opened" (or no connection).
    public func plain(_ f: DmFile) async -> Data? {
        let path = plainPath(f.ox)
        if let d = try? Data(contentsOf: path), Crypto.sha256(d).hex == f.ox { return d }
        guard !engine.localOnly, let u = URL(string: f.url), u.scheme == "https" else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200,
              let plain = DmFiles.open(f, downloaded: data) else { return nil }
        try? plain.write(to: path, options: .completeFileProtection)
        return plain
    }

    /// The thumbnail of F (the file's key, its own nonce), or nil.
    public func thumb(_ f: DmFile) async -> Data? {
        guard let t = f.thumb, let u = URL(string: t), u.scheme == "https", !engine.localOnly else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return DmFiles.openThumb(f, downloaded: data)
    }

    /// Demo mode: a file in CONV from FROM (or mine), its plain bytes kept here, never uploaded.
    public func demoFile(_ data: Data, mime: String, name: String?, dim: String? = nil, duration: Int? = nil, group: String? = nil,
                         in conv: String, from: String, at: Int) {
        let ox = Crypto.sha256(data).hex
        try? data.write(to: plainPath(ox))
        let f = DmFile(url: "https://blossom.demo.belfry.sh/" + ox, mime: mime, key: String(repeating: "0", count: 64), nonce: String(repeating: "0", count: 24),
                       x: ox, ox: ox, size: data.count, name: name, dim: dim, duration: duration, group: group)
        let rid = Crypto.sha256(Data((ox + from + String(at)).utf8)).hex
        var d = Dm(rid: rid, conv: conv, from: from, mine: from == me, at: at, kind: DmFiles.kind, text: DmFiles.lastLine([f]))
        d.file = f
        d.group = group
        lock.lock(); items[rid] = d; lock.unlock()
        save()
    }

    /// Demo mode: a caption of GROUP.
    public func demoText(_ text: String, group: String?, in conv: String, from: String, at: Int, pending: Bool = false) {
        let rid = Crypto.sha256(Data((text + from + String(at)).utf8)).hex
        var d = Dm(rid: rid, conv: conv, from: from, mine: from == me, at: at, kind: 14, text: text)
        d.group = group
        d.pending = pending ? true : nil
        lock.lock(); items[rid] = d; lock.unlock()
        save()
    }

    /// Demo mode: the file sends of CONV are on their way (the sending board).
    public func demoPendingFiles(in conv: String) {
        lock.lock()
        for (k, d) in items where d.conv == conv && d.kind == DmFiles.kind && d.mine { items[k]?.pending = true }
        lock.unlock()
        save()
    }
}
