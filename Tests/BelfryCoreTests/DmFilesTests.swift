import XCTest
@testable import BelfryCore

/// vectors/dm-files.json (belfry-android's, sha256 02feb5a4…d210): files in direct messages, kind 15.
final class DmFilesTests: XCTestCase {
    private func hex(_ s: String?) -> Data { Data(hex: s ?? "") ?? Data() }

    func testCipher() throws {
        for c in try vector("dm-files").list("crypto") {
            let note = c.str("note") ?? ""
            let cipher = try DmFiles.encrypt(hex(c.str("plain_hex")), key: hex(c.str("key")), nonce: hex(c.str("nonce")))
            XCTAssertEqual(cipher.hex, c.str("ciphertext_hex"), note)
            XCTAssertEqual(Crypto.sha256(cipher).hex, c.str("x"), note)
            XCTAssertEqual(Crypto.sha256(hex(c.str("plain_hex"))).hex, c.str("ox"), note)
            XCTAssertEqual(DmFiles.decrypt(cipher, key: hex(c.str("key")), nonce: hex(c.str("nonce")))?.hex, c.str("plain_hex"), note)
        }
    }

    /// The sender's rumors: the ciphertext, the tags in their order, the id, who it is wrapped to.
    func testSend() throws {
        let v = try vector("dm-files")
        let me = v.dict("people").str("me")!
        let send = v.dict("send")
        var cases: [[String: Any]] = ["picture", "file", "audio"].map { send.dict($0) }
        cases += send.dict("group").list("files")
        for c in cases {
            let r = c.dict("rumor")
            let want = tags(r["tags"])
            let others = want.filter { $0.first == "p" }.map { $0[1] }
            let f = try XCTUnwrap(DmFiles.parse(tags: want, content: r.str("content")!))
            let (cipher, made) = try DmFiles.prepare(hex(c.str("plain_hex")), mime: f.mime, name: f.name, dim: f.dim, duration: f.duration, group: f.group,
                                                    key: hex(f.key), nonce: hex(f.nonce))
            XCTAssertEqual(cipher.hex, c.str("ciphertext_hex"))
            var out = made
            out.url = r.str("content")!
            out.blurhash = f.blurhash
            out.thumb = f.thumb
            out.thumbNonce = f.thumbNonce
            XCTAssertEqual(DmFiles.tags(others: others, file: out), want)
            let rumor = GiftWrap.rumor(kind: 15, pubkey: me, tags: want, content: r.str("content")!, createdAt: r.int("created_at")!)
            XCTAssertEqual(rumor.id, r.str("id"))
            if let to = c["wrapped_to"] as? [String] { XCTAssertEqual(to, others + [me]) }
        }
        // the thumbnail: the file's key, its own nonce
        let pic = send.dict("picture"), th = pic.dict("thumb")
        let pf = try XCTUnwrap(DmFiles.parse(tags: tags(pic.dict("rumor")["tags"]), content: ""))
        XCTAssertEqual(try DmFiles.encrypt(hex(th.str("plain_hex")), key: hex(pf.key), nonce: hex(th.str("nonce"))).hex, th.str("ciphertext_hex"))
        // the caption: a kind 14 with the group's tag
        let cap = send.dict("group").dict("caption")
        XCTAssertEqual(GiftWrap.rumor(kind: 14, pubkey: me, tags: tags(cap["tags"]), content: cap.str("content")!, createdAt: cap.int("created_at")!).id, cap.str("id"))
        // a group's files: created_at strictly increasing
        let at = send.dict("group").list("files").map { $0.dict("rumor").int("created_at")! }
        XCTAssertEqual(at, at.sorted())
        XCTAssertEqual(Set(at).count, at.count)
        // a reaction on a file: k 15
        let rx = send.dict("reaction").dict("rumor")
        let target = pic.dict("rumor")
        XCTAssertEqual(DmReactions.addTags(message: target.str("id")!, author: me, participants: [me, rx.str("pubkey")!], me: rx.str("pubkey")!, kind: 15), tags(rx["tags"]))
    }

    func testRead() throws {
        for c in try vector("dm-files").list("read") {
            let note = c.str("note") ?? ""
            let e = c.dict("expect")
            let ok = (e["ok"] as? Bool) ?? false
            let down = hex(c.str("downloaded_hex"))
            let f = DmFiles.parse(tags: tags(c["tags"]), content: "https://blossom.example.org/x")
            let plain: Data?
            if (c["thumb"] as? Bool) == true { plain = f.flatMap { DmFiles.openThumb($0, downloaded: down) } }
            else { plain = f.flatMap { DmFiles.open($0, downloaded: down) } }
            if ok { XCTAssertEqual(plain?.hex, e.str("plain_hex"), note) } else { XCTAssertNil(plain, note) }
        }
        XCTAssertEqual(DmFiles.unreadable, try vector("dm-files").str("unreadable"))
    }

    func testBubbles() throws {
        let b = try vector("dm-files").dict("bubbles")
        let pieces = b.list("rumors").map { DmFiles.Piece(id: $0.str("id")!, kind: $0.int("kind")!, author: $0.str("pubkey")!, at: $0.int("created_at")!, group: $0.str("group")) }
        let got = DmFiles.bubbles(pieces)
        let want = b.list("expect")
        XCTAssertEqual(got.map(\.files), want.map { $0.strs("files") })
        XCTAssertEqual(got.map(\.caption), want.map { $0.str("caption") })
    }

    func testNames() throws {
        for c in try vector("dm-files").list("names") {
            XCTAssertEqual(DmFiles.shownName(c.str("name"), mime: c.str("mime")!), c.str("shown"), c.str("name") ?? "nil")
        }
    }

    func testLastLineAndSize() {
        let f = DmFile(url: "", mime: "application/pdf", key: "", nonce: "", x: "", ox: "", size: 1_200_000, name: "Garden plan 2027.pdf")
        XCTAssertEqual(DmFiles.lastLine([f]), "File: Garden plan 2027.pdf")
        XCTAssertEqual(DmFiles.typeAndSize(f), "PDF · 1.2 MB")
        let p = DmFile(url: "", mime: "image/jpeg", key: "", nonce: "", x: "", ox: "", size: 10)
        XCTAssertEqual(DmFiles.lastLine([p]), "Picture")
        XCTAssertEqual(DmFiles.lastLine([p, p, p]), "3 pictures")
        let a = DmFile(url: "", mime: "audio/mp4", key: "", nonce: "", x: "", ox: "", size: 10, duration: 42)
        XCTAssertEqual(DmFiles.lastLine([a]), "Audio recording · 0:42")
        XCTAssertEqual(DmFiles.tooLarge(guest: false), "This file is too large (25 MB at most)")
    }
}
