import Foundation

// What a ticket type (kind 30402) costs now (SPEC 19.51; collective-belfry docs/checkin.md
// "Ticket prices"; vectors/ticket-prices.json, written by running the server's price_of).
// A priced ticket is never self-served: the person asks, the host admits once it is settled.

public struct TicketPrice: Hashable, Sendable, Codable {
    /// It carries a price (also one that can't be read): asked for, never taken.
    public var priced = false
    /// A decimal string ("50", "15.50"); empty when the price can't be read or it is not on sale.
    public var amount = ""
    /// An ISO code in capitals, "HOUR", or the host's own label as written.
    public var currency = ""
    /// Percent, only on an ISO currency; empty = none stated.
    public var vat = ""
    public var vatIncluded = false
    /// When the current price ends, or the next one starts.
    public var until: Int?
    /// False: it has dated prices and none of them is now.
    public var onSale = true
    /// `can_pay` + `checkout_url` of `GET /events/<link>` (docs/sales.md §10): the page where this
    /// viewer can buy it now, an https address; nil = it is asked for from the hosts.
    public var checkout: String?

    public init() {}

    /// The words shown: "Free", "€50 + 21% VAT", "€60.50 incl. 21% VAT", "2 hours", "3 Time credits",
    /// "Paid" (a price that can't be read), "Not on sale now".
    public var line: String {
        if !priced { return "Free" }
        if !onSale { return "Not on sale now" }
        if amount.isEmpty { return "Paid" }
        var out: String
        if currency == "EUR" { out = "€" + amount }
        else if currency == "HOUR" { out = amount + (amount == "1" ? " hour" : " hours") }
        else { out = amount + " " + currency }
        if !vat.isEmpty { out += vatIncluded ? " incl. \(vat)% VAT" : " + \(vat)% VAT" }
        return out
    }

    static let amountRx = Rx("^\\d{1,7}(\\.\\d{1,2})?$")
    static let currencyRx = Rx("^[A-Za-z0-9][A-Za-z0-9 ]{0,11}$")
    static let tsRx = Rx("^\\d{9,11}$")
    static let isoRx = Rx("^[A-Za-z]{3}$")
    static let vatRx = Rx("^\\d{1,2}(\\.\\d{1,2})?$")

    /// A readable (amount, currency), or nil.
    static func amount(_ rawIn: String, _ curIn: String) -> (String, String)? {
        let raw = rawIn.trimmingCharacters(in: .whitespacesAndNewlines)
        var cur = curIn.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard amountRx.test(raw), currencyRx.test(cur) else { return nil }
        let parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var whole = String(parts[0].drop { $0 == "0" })
        if whole.isEmpty { whole = "0" }
        var frac = parts.count > 1 ? String(parts[1]) : ""
        while frac.hasSuffix("0") { frac.removeLast() }
        let amount = whole + (frac.isEmpty ? "" : "." + frac.padding(toLength: 2, withPad: "0", startingAt: 0))
        if ["HOUR", "HOURS"].contains(cur.uppercased()) { cur = "HOUR" } else if isoRx.test(cur) { cur = cur.uppercased() }
        return (amount, cur)
    }

    static func ts(_ s: String) -> Int? { tsRx.test(s) ? Int(s) : nil }

    /// The price of a ticket with TAGS at NOW (the server's `price_of`).
    public static func of(tags: [Tag], now: Int) -> TicketPrice {
        var out = TicketPrice()
        let base = tags.first { $0.first == "price" }
        let dated = tags.filter { $0.first == "price_at" }
        if base == nil && dated.isEmpty { return out }
        var unreadable = false
        var rows = [(amount: String, currency: String, from: Int?, until: Int?, plain: Bool)]()
        func at(_ t: Tag, _ i: Int) -> String { t.count > i ? t[i] : "" }
        for t in dated {
            let got = amount(at(t, 1), at(t, 2))
            let start = at(t, 3).trimmingCharacters(in: .whitespacesAndNewlines)
            let end = at(t, 4).trimmingCharacters(in: .whitespacesAndNewlines)
            if got == nil || (!start.isEmpty && ts(start) == nil) || (!end.isEmpty && ts(end) == nil) { unreadable = true; continue }
            rows.append((got!.0, got!.1, ts(start), ts(end), false))
        }
        if let base {
            if let got = amount(at(base, 1), at(base, 2)) { rows.append((got.0, got.1, nil, nil, true)) } else { unreadable = true }
        }
        if unreadable { out.priced = true; return out }
        guard let i = rows.firstIndex(where: { r in (r.from == nil || r.from! <= now) && (r.until == nil || now < r.until!) }) else {
            // dated prices only, none of them now
            out.priced = true
            out.onSale = false
            return out
        }
        let cur = rows[i]
        if (Double(cur.amount) ?? 0) == 0 { return out }
        out.priced = true
        out.amount = cur.amount
        out.currency = cur.currency
        out.until = cur.until
        if cur.until == nil, cur.plain {
            // the plain price holds until the next dated one starts
            out.until = rows.dropLast().compactMap { $0.from }.filter { $0 > now }.min()
        }
        if let vat = tags.first(where: { $0.first == "vat" }), Rx("^[A-Z]{3}$").test(cur.currency) {
            let rate = at(vat, 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if vatRx.test(rate) {
                var r = rate
                if r.contains(".") { while r.hasSuffix("0") { r.removeLast() }; if r.hasSuffix(".") { r.removeLast() } }
                out.vat = r
                out.vatIncluded = vat.count > 2 && vat[2] == "included"
            }
        }
        return out
    }

    /// From `GET /events/<link>`: a ticket's `price` (or null), `on_sale`, `needs_payment`.
    public static func from(api x: [String: Any]) -> TicketPrice {
        var out = TicketPrice()
        out.priced = x["needs_payment"] as? Bool ?? false
        out.onSale = x["on_sale"] as? Bool ?? true
        if let p = x["price"] as? [String: Any] {
            out.priced = true
            // fixed shapes only: anything else reads as a price that can't be read
            if let got = amount(p["amount"] as? String ?? "", p["currency"] as? String ?? "") {
                out.amount = got.0
                out.currency = got.1
                let v = p["vat"] as? String ?? ""
                if vatRx.test(v), Rx("^[A-Z]{3}$").test(got.1) { out.vat = v; out.vatIncluded = p["vat_included"] as? Bool ?? false }
                out.until = (p["until"] as? NSNumber)?.intValue
            }
        }
        // bought through the checkout only when the belfry says this viewer can, and gives a page
        if out.priced, out.onSale, x["can_pay"] as? Bool == true, let u = x["checkout_url"] as? String,
           u.count <= 2000, let url = URL(string: u), url.scheme == "https", url.host?.isEmpty == false {
            out.checkout = u
        }
        return out
    }
}
