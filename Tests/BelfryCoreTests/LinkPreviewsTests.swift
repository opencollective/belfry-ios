import XCTest
@testable import BelfryCore

// vectors/link-previews.json (belfry-android's, sha256 bc719210…fa39b, copied byte for byte):
// which link, the page's text, charsets, the fetch rules, pictures by their bytes, the tags, reading.

final class LinkPreviewsTests: XCTestCase {
    func testVectorFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("vectors/link-previews.json"))
        XCTAssertEqual(Crypto.sha256(data).hex, "bc7192106aabde0bf296afa267a5d16d1bb0b5891123b187cc6b0b4c8bafa39b")
    }

    func testLinks() throws {
        let v = try vector("link-previews")
        let domain = v.str("domain") ?? "", files = v.str("files") ?? ""
        for c in v.list("links") {
            XCTAssertEqual(LinkPreviews.outsideLink(c.str("text") ?? "", tags: tags(c["tags"]), domain: domain, files: files), c.str("link"), c.str("name") ?? "")
        }
    }

    func testHTML() throws {
        for c in try vector("link-previews").list("html") {
            let m = PageMeta.parse(c.str("html") ?? "", base: c.str("final_url") ?? "")
            let n = c.str("name") ?? ""
            XCTAssertEqual(m.title, c.str("title"), n)
            XCTAssertEqual(m.description, c.str("description"), n)
            XCTAssertEqual(m.site, c.str("site"), n)
            XCTAssertEqual(m.image, c.str("image"), n)
        }
    }

    func testCharsets() throws {
        for c in try vector("link-previews").list("charsets") {
            let html = PageMeta.decode(Data(hex: c.str("bytes") ?? "") ?? Data(), contentType: c.str("content_type"))
            XCTAssertEqual(PageMeta.parse(html, base: "https://a.example/").title, c.str("title"), c.str("name") ?? "")
        }
    }

    func testURLsAndAddresses() throws {
        let v = try vector("link-previews")
        for c in v.list("urls") {
            XCTAssertEqual(FetchRules.url(c.str("url") ?? "") != nil, c["ok"] as? Bool, c.str("url") ?? "")
        }
        for c in v.list("addresses") {
            XCTAssertEqual(FetchRules.allowed(c.str("address") ?? ""), c["ok"] as? Bool, c.str("address") ?? "")
        }
    }

    func testPictures() throws {
        for c in try vector("link-previews").list("pictures") {
            XCTAssertEqual(PreviewImages.kind(Data(hex: c.str("hex") ?? "") ?? Data()), c.str("type"), c.str("name") ?? "")
        }
    }

    /// The tags a sender puts on its message, and the picture it uploads (encrypted with a fixed key).
    func testTags() async throws {
        let v = try vector("link-previews")
        let blossom = v.str("blossom") ?? ""
        for c in v.list("tags") {
            let pv = c.dict("preview"), n = c.str("name") ?? ""
            var picture: PreviewPicture?
            let pic = c["picture"] as? [String: Any]
            if let pic {
                let plain = try XCTUnwrap(Data(hex: pic.str("plain") ?? ""))
                if let key = pic.str("key"), let nonce = pic.str("nonce") {
                    let cipher = try DmFiles.encrypt(plain, key: try XCTUnwrap(Data(hex: key)), nonce: try XCTUnwrap(Data(hex: nonce)))
                    XCTAssertEqual(cipher.hex, pic.str("ciphertext"), n)
                    picture = PreviewPicture(url: pic.str("url") ?? "", mime: pic.str("mime") ?? "", width: pic.int("width"), height: pic.int("height"),
                                             x: Crypto.sha256(cipher).hex, ox: Crypto.sha256(plain).hex, key: key, nonce: nonce)
                    XCTAssertEqual(picture?.open(cipher), plain, n)
                } else {
                    picture = PreviewPicture(url: pic.str("url") ?? "", mime: pic.str("mime") ?? "", width: pic.int("width"), height: pic.int("height"), x: Crypto.sha256(plain).hex)
                    XCTAssertEqual(picture?.open(plain), plain, n)
                    XCTAssertNil(picture?.open(plain + Data([0])), "a changed byte")
                }
            }
            let p = LinkPreview(url: pv.str("url") ?? "", title: pv.str("title") ?? "", description: pv.str("description") ?? "", site: pv.str("site") ?? "", picture: picture)
            XCTAssertEqual(p.tags(), tags(c["tags"]), n)
            // and read back as written
            XCTAssertEqual(LinkPreviews.read("see " + p.url, tags: p.tags(), blossom: blossom)?.picture, picture, n)
        }
    }

    func testRead() throws {
        let v = try vector("link-previews")
        let blossom = v.str("blossom") ?? ""
        for c in v.list("read") {
            let n = c.str("name") ?? ""
            let got = LinkPreviews.read(c.str("text") ?? "", tags: tags(c["tags"]), blossom: blossom)
            guard let shown = c["shown"] as? [String: Any] else { XCTAssertNil(got, n); continue }
            let g = try XCTUnwrap(got, n)
            XCTAssertEqual(g.url, shown.str("url"), n)
            XCTAssertEqual(g.title, shown.str("title"), n)
            XCTAssertEqual(g.description, shown.str("description"), n)
            XCTAssertEqual(g.site, shown.str("site"), n)
            XCTAssertEqual(g.siteLine, shown.str("site_line"), n)
            if let sp = shown["picture"] as? [String: Any] {
                let gp = try XCTUnwrap(g.picture, n)
                XCTAssertEqual(gp.url, sp.str("url"), n)
                XCTAssertEqual(gp.mime, sp.str("mime"), n)
                XCTAssertEqual(gp.width, sp.int("width"), n)
                XCTAssertEqual(gp.height, sp.int("height"), n)
                XCTAssertEqual(gp.encrypted, sp["encrypted"] as? Bool, n)
            } else {
                XCTAssertNil(g.picture, n)
            }
        }
    }

    /// The whole build on fake networks: the page, its picture, the upload; refusals on the way.
    func testBuild() async throws {
        struct Table: PreviewResolver { let t: [String: [String]]; func resolve(_ h: String) async -> [String] { t[h] ?? [] } }
        final class Net: PreviewNet, @unchecked Sendable {
            var asked = [String]()
            let answers: [String: NetAnswer]
            init(_ a: [String: NetAnswer]) { answers = a }
            func get(_ url: URL, host: String, addresses: [String], accept: String, maxBytes: Int, timeout: TimeInterval) async -> NetAnswer? {
                asked.append(url.absoluteString)
                return answers[url.absoluteString]
            }
        }
        struct Enc: PictureEncoder {
            func encode(_ bytes: Data, mime: String) -> EncodedPicture? { EncodedPicture(bytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), mime: "image/jpeg", width: 1200, height: 630) }
        }
        let page = "<html><head><meta property=og:title content='Street library'><meta property=og:image content='/og.png'></head></html>"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])
        let net = Net([
            "https://a.example/x": NetAnswer(status: 301, location: "https://www.a.example/y"),
            "https://www.a.example/y": NetAnswer(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8)),
            "https://www.a.example/og.png": NetAnswer(status: 200, contentType: "image/png", body: png),
        ])
        let fetch = SafeFetch(net: net, resolver: Table(t: ["a.example": ["93.184.215.14"], "www.a.example": ["93.184.215.14"], "evil.example": ["10.0.0.1"]]))
        let b = PreviewBuilder(fetch: fetch, encoder: Enc(), upload: { d, _ in "https://blossom.belfry.example/" + Crypto.sha256(d).hex }, blossom: "https://blossom.belfry.example")
        let p = await b.build("https://a.example/x", mode: .plain)
        XCTAssertEqual(p?.title, "Street library")
        XCTAssertEqual(p?.url, "https://a.example/x", "the link as written")
        XCTAssertEqual(p?.picture?.mime, "image/jpeg")
        XCTAssertNil(p?.picture?.key)
        let e = await b.build("https://a.example/x", mode: .encrypted)
        XCTAssertNotNil(e?.picture?.key, "encrypted in a direct message")
        // a name that resolves to a private address is never asked
        if case .refused(let why) = await fetch.page("https://evil.example/") { XCTAssertEqual(why, .address) } else { XCTFail() }
        XCTAssertFalse(net.asked.contains { $0.contains("evil") })
        // an upload somewhere else: no picture
        let off = PreviewBuilder(fetch: fetch, encoder: Enc(), upload: { _, _ in "https://elsewhere.example/x" }, blossom: "https://blossom.belfry.example")
        let q = await off.build("https://a.example/x", mode: .plain)
        XCTAssertNotNil(q)
        XCTAssertNil(q?.picture)
    }
}

final class DmPreviewTests: XCTestCase {
    /// A direct message carries the preview inside its rumor; a picture in the clear never goes.
    func testPrivatePreview() {
        let p: Tag = ["preview", "https://a.example/x", "T", "D", "S"]
        let clear: Tag = ["imeta", "url https://blossom.b.example/1", "m image/jpeg", "x " + String(repeating: "a", count: 64), "purpose preview"]
        let sealed: Tag = ["imeta", "url https://blossom.b.example/2", "m image/jpeg", "x " + String(repeating: "a", count: 64), "ox " + String(repeating: "b", count: 64),
                           "encryption-algorithm aes-gcm", "decryption-key " + String(repeating: "c", count: 64), "decryption-nonce " + String(repeating: "d", count: 24), "purpose preview"]
        XCTAssertEqual(DirectMessages.privatePreview([p, clear]), [p], "the picture in the clear is dropped")
        XCTAssertEqual(DirectMessages.privatePreview([p, sealed]), [p, sealed])
        XCTAssertEqual(DirectMessages.privatePreview([LinkPreviews.noPreview]), [LinkPreviews.noPreview])
        XCTAssertEqual(DirectMessages.privatePreview([]), [])
        // and read back from a rumor
        let rumor = GiftWrap.rumor(kind: 14, pubkey: String(repeating: "1", count: 64), tags: [["p", String(repeating: "2", count: 64)], p, sealed], content: "see https://a.example/x", createdAt: 1)
        let d = DmReader.dm(from: rumor, me: String(repeating: "2", count: 64), bridge: nil, known: [])
        XCTAssertEqual(d?.previewTags, [p, sealed])
        XCTAssertEqual(LinkPreviews.read(d?.text ?? "", tags: d?.previewTags ?? [], blossom: "https://blossom.b.example")?.picture?.encrypted, true)
    }
}
