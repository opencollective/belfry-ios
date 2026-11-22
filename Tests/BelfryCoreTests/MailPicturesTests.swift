import XCTest
@testable import BelfryCore

/// Pictures show in the message (the lead, 2026-11-22; canvas v179 n-email-pictures).
final class MailPicturesTests: XCTestCase {
    func testAPictureByItsTypeOrByItsNameWhenTheTypeIsGeneric() {
        for t in ["image/jpeg", "IMAGE/PNG", "image/gif", "image/webp", "image/heic", "image/heif; charset=binary"] {
            XCTAssertTrue(MailPictures.isPicture(type: t, name: nil), t)
        }
        XCTAssertTrue(MailPictures.isPicture(type: "application/octet-stream", name: "IMG_0042.HEIC"))
        XCTAssertTrue(MailPictures.isPicture(type: "", name: "photo.jpeg"))
        XCTAssertTrue(MailPictures.isPicture(type: nil, name: "a.b.webp"))
        // a named type that is not a picture wins over the name; other images are files
        XCTAssertFalse(MailPictures.isPicture(type: "application/pdf", name: "scan.jpg"))
        XCTAssertFalse(MailPictures.isPicture(type: "image/svg+xml", name: "logo.svg"))
        XCTAssertFalse(MailPictures.isPicture(type: "application/octet-stream", name: "notes.pdf"))
        XCTAssertFalse(MailPictures.isPicture(type: "", name: "jpg"))
    }

    func testAMailsPicturesComeInItsOrderAndFilesStayFiles() {
        let png = Data([0x89, 0x50, 0x4e, 0x47]).base64EncodedString()
        let raw = [
            "From: Lou <lou@example.org>", "Subject: Park", "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"b1\"", "",
            "--b1", "Content-Type: multipart/related; boundary=\"b2\"", "",
            "--b2", "Content-Type: text/html; charset=utf-8", "", "<p>Look <img src=\"cid:one\"></p>",
            "--b2", "Content-Type: image/png", "Content-ID: <one>", "Content-Transfer-Encoding: base64", "", png,
            "--b2--",
            "--b1", "Content-Type: application/pdf; name=\"plan.pdf\"", "Content-Disposition: attachment; filename=\"plan.pdf\"", "Content-Transfer-Encoding: base64", "", png,
            "--b1", "Content-Type: application/octet-stream; name=\"IMG_1.HEIC\"", "Content-Disposition: attachment; filename=\"IMG_1.HEIC\"", "Content-Transfer-Encoding: base64", "", png,
            "--b1--", "",
        ].joined(separator: "\r\n")
        let m = MIME.parse(raw)
        XCTAssertEqual(m.text, "Look")
        let (pictures, files) = MailPictures.split(m.attachments)
        // the picture pasted into the HTML (no file name) first, then the attached one
        XCTAssertEqual(pictures.map(\.type), ["image/png", "application/octet-stream"])
        XCTAssertEqual(pictures.map(\.name), ["attachment", "IMG_1.HEIC"])
        XCTAssertEqual(files.map(\.name), ["plan.pdf"])
    }

    func testALargeMailOpensWithItsKeyAndNotWithAnother() throws {
        let key = Data((0..<32).map { UInt8($0) }), nonce = Data((0..<12).map { UInt8($0) })
        let raw = "From: a@x.org\r\nSubject: Big\r\n\r\nHello"
        let sealed = try Crypto.aesGCMSeal(key: key, nonce: nonce, plain: Data(raw.utf8))
        let tags: [Tag] = [["x", "00"], ["url", "https://blossom.example.org/abc"], ["decryption-key", key.base64EncodedString()], ["decryption-nonce", nonce.base64EncodedString()]]
        let l = try XCTUnwrap(LargeMail(tags: tags))
        XCTAssertEqual(l.open(sealed), raw)
        XCTAssertNil(l.open(Data(sealed.reversed())))
        // not https, or a short key: no large mail (the placeholder stays)
        XCTAssertNil(LargeMail(tags: [["url", "http://x/abc"], ["decryption-key", key.base64EncodedString()], ["decryption-nonce", nonce.base64EncodedString()]]))
        XCTAssertNil(LargeMail(tags: [["url", "https://x/abc"], ["decryption-key", "AAAA"], ["decryption-nonce", nonce.base64EncodedString()]]))
    }

    func testAChannelFileIsAPictureByItsImetaTypeOrItsAddress() {
        XCTAssertTrue(Media(url: "https://b.example.org/abc.bin", mime: "image/jpeg").isImage)
        XCTAssertTrue(Media(url: "https://b.example.org/abc.heic", mime: "").isImage)
        XCTAssertTrue(Media(url: "https://b.example.org/abc", mime: "application/octet-stream", name: "IMG_2.JPG").isImage)
        XCTAssertFalse(Media(url: "https://b.example.org/abc.pdf", mime: "application/pdf", name: "a.pdf").isImage)
    }
}

final class TodoPicturesTests: XCTestCase {
    func testACommentThatIsOnlyAPictureSaysSo() {
        let pic = Media(url: "https://b.example.org/a.jpg", mime: "image/jpeg")
        let pdf = Media(url: "https://b.example.org/a.pdf", mime: "application/pdf", name: "a.pdf")
        XCTAssertEqual(TodoEntry.addedLine([pic]), "added a picture")
        XCTAssertEqual(TodoEntry.addedLine([pic, pic]), "added 2 pictures")
        XCTAssertEqual(TodoEntry.addedLine([pdf]), "added a file")
        XCTAssertEqual(TodoEntry.addedLine([pic, pdf]), "added 2 files")
        XCTAssertNil(TodoEntry.addedLine([]))
    }
}

final class MailInitialsTests: XCTestCase {
    func testFirstAndLastWordElseTheAddress() {
        XCTAssertEqual(MailInitials.of(name: "Ana Maria Silva", address: "ana@example.org"), "AS")
        XCTAssertEqual(MailInitials.of(name: "Lina", address: "lina@example.org"), "L")
        XCTAssertEqual(MailInitials.of(name: "  lou   martin ", address: "x@example.org"), "LM")
        XCTAssertEqual(MailInitials.of(name: nil, address: "park@example.org"), "P")
        XCTAssertEqual(MailInitials.of(name: "", address: "9lives@example.org"), "9")
    }
}
