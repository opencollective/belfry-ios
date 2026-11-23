import XCTest
@testable import BelfryCore

// Link previews (collective-belfry docs/link-previews.md): which link of a message is asked
// about, what of the belfry's answer is kept, and for how long.

final class LinkPreviewsTests: XCTestCase {
    let domain = "belfry.sh"
    let api = "https://belfry.belfry.sh/api/v1"

    func testWhichLink() {
        func l(_ t: String, skip: [String] = []) -> String? { LinkPreviews.link(in: t, domain: domain, skip: skip) }
        XCTAssertEqual(l("This is what we could become: https://toolshare.example/stories/street-library"), "https://toolshare.example/stories/street-library")
        XCTAssertEqual(l("Two: https://a.example/x and https://b.example/y"), "https://a.example/x", "only the first")
        XCTAssertNil(l("no link here"))
        XCTAssertNil(l("http://plain.example/x"), "https only")
        XCTAssertNil(l("https://chat.belfry.sh/#/c/general"), "the belfry's own links have their own cards")
        XCTAssertNil(l("https://belfry.sh/about"))
        XCTAssertEqual(l("https://chat.belfry.sh/#/c/general then https://b.example/y"), "https://b.example/y")
        XCTAssertNil(l("https://192.168.1.4/x"))
        XCTAssertNil(l("https://localhost/x"))
        XCTAssertNil(l("https://user:pw@a.example/x"))
        XCTAssertNil(l("https://a.example:8443/x"))
        XCTAssertEqual(l("https://notbelfry.sh/x"), "https://notbelfry.sh/x")
        let file = "https://blossom.example/abc.jpg"
        XCTAssertNil(l(file, skip: [file]), "a file already shown")
    }

    func testPreviewNoneTag() {
        func msg(_ tags: [Tag]) -> Message {
            Derive.parseMedia(NostrEvent(id: String(repeating: "1", count: 64), pubkey: String(repeating: "a", count: 64), createdAt: 1, kind: 9, tags: tags, content: "see https://a.example/x"))
        }
        XCTAssertEqual(LinkPreviews.link(of: msg([["h", "g"]]), domain: domain), "https://a.example/x")
        XCTAssertNil(LinkPreviews.link(of: msg([["h", "g"], ["preview", "none"]]), domain: domain))
    }

    func testAnswer() {
        let body: [String: Any] = ["url": "https://toolshare.example/stories/street-library", "title": " How a street  tool library lends ", "description": "Neighbours…",
                                   "site_name": "ToolShare Journal", "image": "https://belfry.belfry.sh/api/v1/link-preview/image/" + String(repeating: "a", count: 64),
                                   "image_width": 1200, "image_height": 630]
        guard case .found(let p) = LinkPreviews.answer(status: 200, body: body, apiBase: api) else { return XCTFail() }
        XCTAssertEqual(p.title, "How a street tool library lends")
        XCTAssertEqual(p.imageWidth, 1200)
        XCTAssertNotNil(p.image)
        XCTAssertEqual(p.siteLine(link: "https://www.toolshare.example/x"), "ToolShare Journal · toolshare.example")
        XCTAssertEqual(LinkPreview(url: "x").siteLine(link: "https://toolshare.example/x"), "toolshare.example")
        // a picture anywhere else is never loaded
        var outside = body
        outside["image"] = "https://toolshare.example/og.png"
        guard case .found(let q) = LinkPreviews.answer(status: 200, body: outside, apiBase: api) else { return XCTFail() }
        XCTAssertNil(q.image)
        XCTAssertNil(q.imageWidth)
        outside["image"] = "http://belfry.belfry.sh/api/v1/link-preview/image/x"
        guard case .found(let r) = LinkPreviews.answer(status: 200, body: outside, apiBase: api) else { return XCTFail() }
        XCTAssertNil(r.image)
        // nothing to say
        XCTAssertEqual(LinkPreviews.answer(status: 200, body: ["url": "https://a.example", "title": NSNull(), "description": NSNull()], apiBase: api), LinkPreviewAnswer.none)
        XCTAssertEqual(LinkPreviews.answer(status: 404, body: ["error": "none"], apiBase: api), LinkPreviewAnswer.none)
        XCTAssertEqual(LinkPreviews.answer(status: 422, body: ["error": "invalid"], apiBase: api), LinkPreviewAnswer.none)
        for s in [401, 403, 429, 503, 0] { XCTAssertEqual(LinkPreviews.answer(status: s, body: nil, apiBase: api), .later) }
    }

    func testAddress() {
        XCTAssertEqual(LinkPreviews.address(apiBase: api, link: "https://a.example/x?y=1&z=é"),
                       api + "/link-preview?url=https%3A%2F%2Fa.example%2Fx%3Fy%3D1%26z%3D%C3%A9")
    }

    func testKept() {
        var c = LinkPreviewCache()
        let p = LinkPreview(url: "https://a.example", title: "A")
        c.keep("a", .found(p), now: 1000)
        c.keep("b", .none, now: 1000)
        c.keep("c", .later, now: 1000)
        XCTAssertEqual(c.state("a", now: 1000 + 86_399), .found(p))
        XCTAssertNil(c.state("a", now: 1000 + 86_400), "a day")
        XCTAssertEqual(c.state("b", now: 1000 + 3_599), LinkPreviewState.none)
        XCTAssertNil(c.state("b", now: 1000 + 3_600), "an hour for nothing")
        XCTAssertNil(c.state("c", now: 1000), "later is not kept")
    }
}
