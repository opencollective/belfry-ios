import Foundation

// Links in people's text (SPEC 9, 19.36 note): which addresses are links and where a tap goes.
// The rule is the Markdown subset's own (Markdown.inlineRx, the web's markdown.tsx): http(s)
// only, no spaces, < > ( ) end it, and the last character is not . , ; : ! ? ' " (a sentence's
// punctuation stays outside). A bare host without a scheme is not a link.

public enum Links {
    public static let urlRx = Rx("https?://[^\\s<>()]+[^\\s<>().,;:!?'\"]")

    /// The bare addresses in TEXT, in order.
    public static func find(_ text: String) -> [String] { urlRx.matches(text).map(\.whole) }

    /// Every address Markdown makes a link of in TEXT (bare ones and [label](href)), in order.
    public static func inMarkdown(_ text: String) -> [String] {
        var out = [String]()
        func walk(_ nodes: [MDInline]) {
            for n in nodes {
                switch n {
                case .link(let href, let c): out.append(href); walk(c)
                case .bold(let c), .italic(let c), .strike(let c): walk(c)
                default: break
                }
            }
        }
        for b in Markdown.parse(text) {
            switch b {
            case .paragraph(let lines), .quote(let lines): lines.forEach(walk)
            case .heading(_, let c): walk(c)
            case .list(_, let items): items.forEach(walk)
            case .code: break
            }
        }
        return out
    }

    /// Where a tapped link goes.
    public enum Target: Equatable, Sendable {
        /// A channel of this belfry (`#/c/<id>` on its chat).
        case channel(String)
        /// A guest link or an event / ticket link of this belfry's chat: the app handles it.
        case app
        /// Anything else: the browser.
        case browser
    }

    /// The target of URL on the belfry DOMAIN.
    public static func target(_ url: URL, domain: String) -> Target {
        guard !domain.isEmpty, let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .browser }
        let d = domain.lowercased()
        let chat = host == "chat." + d
        // the web chat's own routes: #/c/<id>[/…]
        if chat || host == d, let f = url.fragment, f.hasPrefix("/c/") {
            let id = f.dropFirst(3).split(separator: "/").first.map(String.init)?.removingPercentEncoding ?? ""
            if !id.isEmpty { return .channel(id) }
        }
        guard chat else { return .browser }
        let parts = url.path.split(separator: "/")
        if parts.count >= 2, parts[0] == "join" || parts[0] == "events" { return .app }
        return .browser
    }
}
