import Foundation

/// What an event link is, asked by someone with no session (the lead, 2026-11-23; boards
/// events/members-only-join, -login): `GET https://belfry.<domain>/api/v1/events/<link>` with NO
/// Authorization header.
public enum EventGate: Equatable, Sendable {
    /// 200: public or visible by its link. The web page shows it.
    case open
    /// 403 {"error":"members_only"}: it exists and is for members.
    case membersOnly
    /// 404: no such event. Never the members screen.
    case notFound
    /// 503, no answer, anything else: it can't be checked now.
    case cantCheck

    public static func url(domain: String, link: String) -> URL? {
        guard Discovery.isDomain(domain), EventLinks.slugRx.test(link) || EventLinks.isD(link) else { return nil }
        return URL(string: "https://belfry.\(domain.lowercased())/api/v1/events/\(link)")
    }

    /// The answer's meaning (pure: tested).
    public static func read(status: Int, body: Data) -> EventGate {
        switch status {
        case 200: return .open
        case 403:
            let err = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            return err == "members_only" ? .membersOnly : .cantCheck
        case 404: return .notFound
        default: return .cantCheck
        }
    }

    public static func check(domain: String, link: String, session: URLSession = .shared) async -> EventGate {
        guard let u = url(domain: domain, link: link) else { return .notFound }
        var r = URLRequest(url: u)
        r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: r), let http = resp as? HTTPURLResponse else { return .cantCheck }
        return read(status: http.statusCode, body: data)
    }
}
