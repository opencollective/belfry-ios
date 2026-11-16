import Foundation

// A guest asks to become a member (collective-belfry docs/membership.md "A guest asks",
// guestapply.py; web src/core/apply.ts), the charter for people who can't read its group
// (docs/charter.md, GET /charter) and the public events for guests (docs/checkin.md).

public struct MyApplication: Codable, Hashable, Sendable {
    public var id: Int
    /// new | invited | accepted | declined
    public var state: String
    public var vouches: Int
    public var needed: Int
    /// (pubkey, name)
    public var vouchedBy: [Voucher]
    public struct Voucher: Codable, Hashable, Sendable { public var pubkey: String; public var name: String }
    public init(id: Int, state: String, vouches: Int, needed: Int, vouchedBy: [Voucher]) {
        self.id = id; self.state = state; self.vouches = vouches; self.needed = needed; self.vouchedBy = vouchedBy
    }
    public var isOpen: Bool { state == "new" || state == "invited" }
}

public struct ApplyStatus: Codable, Hashable, Sendable {
    public var application: MyApplication?
    /// When the guest's latest guest pass ends (unix); it doesn't run out while a request is open.
    public var until: Int?
    /// admins | vouches
    public var accept: String
    public init(application: MyApplication?, until: Int?, accept: String) { self.application = application; self.until = until; self.accept = accept }

    public static func parse(_ d: [String: Any]) -> ApplyStatus {
        var app: MyApplication?
        if let a = d["application"] as? [String: Any] {
            let vb = (a["vouched_by"] as? [[String: Any]] ?? []).compactMap { v -> MyApplication.Voucher? in
                guard let pk = v["pubkey"] as? String else { return nil }
                return MyApplication.Voucher(pubkey: pk, name: v["name"] as? String ?? "")
            }
            app = MyApplication(id: BelfryAPI.int(a["id"]) ?? 0, state: a["state"] as? String ?? "new",
                                vouches: BelfryAPI.int(a["vouches"]) ?? 0, needed: BelfryAPI.int(a["needed"]) ?? 0, vouchedBy: vb)
        }
        return ApplyStatus(application: app, until: BelfryAPI.int(d["until"]), accept: d["accept"] as? String == "vouches" ? "vouches" : "admins")
    }

    /// The request's state in words for the guest's Home (board Join-Apply 2).
    public var line: String? {
        guard let a = application else { return nil }
        switch a.state {
        case "accepted": return "You're a member now"
        case "declined": return "Not this time"
        default:
            if accept == "vouches" && a.needed > 0 { return "\(min(a.vouches, a.needed)) of \(a.needed) \(a.needed == 1 ? "vouch" : "vouches")" }
            return "Waiting for a steward"
        }
    }
}

/// An agreement as `GET /charter` gives it to people who can't read the group.
public struct PublicAgreement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var about: String
    public var order: Int?
    public var added: Int
    public var textAt: Int

    public static func parseList(_ d: [String: Any]) -> [PublicAgreement] {
        (d["agreements"] as? [[String: Any]] ?? []).compactMap { o in
            guard let id = o["id"] as? String, isHex64(id), let t = o["title"] as? String, !t.isEmpty else { return nil }
            return PublicAgreement(id: id, title: String(t.prefix(300)), about: String((o["about"] as? String ?? "").prefix(200)),
                                   order: BelfryAPI.int(o["order"]), added: BelfryAPI.int(o["added"]) ?? 0, textAt: BelfryAPI.int(o["text_at"]) ?? 0)
        }
    }

    /// As the app shows agreements (nobody's ticks: the public read has none).
    public var agreement: Agreement {
        Agreement(id: id, title: title, about: about, order: order ?? Int.max, author: "", addedAt: added, textAt: max(textAt, added))
    }
}

public extension BelfryAPI {
    static let applyErrors = [
        "guest_not_saved": "Save your e-mail first: the stewards need a way to reach you.",
        "not_guest": "Only guests apply from here.",
        "pending": "Your request is waiting already.",
        "invalid": "Write a few words (up to 2000 characters).",
        "unsupported": "This belfry can’t take a guest’s request from the app yet. Ask the person who invited you, or a steward.",
        "gone": "You are no longer a guest here.",
    ]

    private func applyCall(_ body: [String: Any]) async throws -> ApplyStatus {
        let a = try await signed(base + "/applications", method: "POST", json: body)
        if a.status == 409, a.error == "pending", let b = a.body { return ApplyStatus.parse(b) }
        if a.status == 404 || a.status == 405 { throw ApiError("unsupported", a.status, BelfryAPI.applyErrors["unsupported"]!) }
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.applyErrors, "That did not work. Try again.") }
        return ApplyStatus.parse(b)
    }

    /// Send the request: the answer and the agreements ticked on the way.
    func guestApply(answer: String, agreed: [String]) async throws -> ApplyStatus {
        let text = String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        return try await applyCall(["apply": ["answer": text, "agreed": agreed.filter(isHex64)]])
    }

    /// My latest request (or none) and how long I stay a guest.
    func applyStatus() async throws -> ApplyStatus { try await applyCall(["apply": "status"]) }

    /// The charter for people who can't read its group (no auth). 503 `unavailable` when the relay can't be read.
    func publicCharter() async throws -> [PublicAgreement] {
        let a = try await plain(base + "/charter")
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "The charter could not be read just now.") }
        return PublicAgreement.parseList(b)
    }

    /// The belfry's public events from FROM on (no auth), soonest first, at most 100.
    func publicEvents(from: Int) async throws -> [[String: Any]] {
        let a = try await plain(base + "/events?visibility=public&from=\(from)")
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "The events could not be read just now.") }
        return b["events"] as? [[String: Any]] ?? []
    }
}
