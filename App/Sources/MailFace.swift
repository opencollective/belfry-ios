import BelfryCore
import SwiftUI

// The Messages list: faces, not envelopes (one-shape.md, 2026-11-22; board home/messages). An
// outside e-mail correspondent's face is their picture from the belfry's avatar service
// (GET <api>/avatar/<sha256 of the trimmed, lowercased address>, no auth) when it answers 200,
// else a disc with their initials in a colour picked from the hash. Cached by hash: a picture
// for 30 days, "none" for 7 (a 404 that asks to come back sooner, a 429 or a failure: later,
// never "no picture"). At most three are fetched at a time, only for rows on screen. The app
// never contacts any other picture service.

enum MailFaces {
    static func hash(_ address: String) -> String {
        Crypto.sha256(Data(address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)).hex
    }

    static func key(_ hash: String) -> String { "mailface://" + hash }

    /// A colour from the hash (the same person always gets the same disc).
    static func tint(_ hash: String) -> Color {
        let v = hash.utf8.prefix(6).reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }
        return Color(hue: Double(v) / 360, saturation: 0.45, brightness: 0.62)
    }

    /// The first letters of the first and the last word of the name ("Ana Maria Silva" → "AS",
    /// "Lina" → "L"); no name: the first letter of the address (one-shape.md d85f408).
    static func initials(name: String?, address: String) -> String {
        MailInitials.of(name: name, address: address)
    }

    // ---- fetching: three at a time, remembered ----------------------------------------------

    private static let defaultsKey = "belfry-mailface-state"
    @MainActor private static var running = 0
    @MainActor private static var waiting = [CheckedContinuation<Void, Never>]()

    /// hash → (until, has picture): when to ask again.
    @MainActor private static var state: [String: [Double]] = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Double]]) ?? [:]

    @MainActor private static func remember(_ hash: String, days: Double, picture: Bool) {
        state[hash] = [Date().timeIntervalSince1970 + days * 86400, picture ? 1 : 0]
        if state.count > 2000 { state = state.filter { $0.value[0] > Date().timeIntervalSince1970 } }
        UserDefaults.standard.set(state, forKey: defaultsKey)
    }

    /// The face for ADDRESS, from the cache or the belfry (nil: none known now).
    @MainActor static func load(address: String, apiBase: String) async -> UIImage? {
        let h = hash(address)
        let now = Date().timeIntervalSince1970
        if let s = state[h], s.count == 2, s[0] > now {
            return s[1] == 1 ? await ImageCache.shared.load(key(h)) : nil
        }
        guard let url = URL(string: apiBase + "/avatar/" + h), url.scheme == "https" else { return nil }
        // at most three requests at a time (the belfry's API is rate-limited per address)
        if running >= 3 { await withCheckedContinuation { waiting.append($0) } }
        running += 1
        defer { running -= 1; if !waiting.isEmpty { waiting.removeFirst().resume() } }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 200, let img = UIImage(data: data) {
            ImageCache.shared.put(key(h), img)
            remember(h, days: 30, picture: true)
            return img
        }
        if http.statusCode == 404 {
            // "try later": a short max-age on the 404
            let cc = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            let age = cc.split(separator: ",").compactMap { p -> Double? in
                let t = p.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("max-age=") ? Double(t.dropFirst(8)) : nil
            }.first
            remember(h, days: age.map { min(7, max($0, 60) / 86400) } ?? 7, picture: false)
        }
        // 429, 5xx, no network: later, never "no picture"
        return nil
    }
}

/// An e-mail correspondent's face: the picture, else the initials disc; a small envelope on its
/// corner so e-mail stays recognisable.
struct MailFace: View {
    @EnvironmentObject var model: AppModel
    let address: String
    let name: String?
    var size: CGFloat = 40
    @State private var picture: UIImage?

    var body: some View {
        let h = MailFaces.hash(address)
        ZStack {
            if let picture {
                Image(uiImage: picture).resizable().scaledToFill()
            } else {
                MailFaces.tint(h)
                Text(MailFaces.initials(name: name, address: address)).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "envelope.fill").font(.system(size: size * 0.24, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size * 0.42, height: size * 0.42)
                .background(Color.secondary, in: Circle())
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
        // a row on screen asks; the demo and guests' reading mode ask nobody
        .task(id: address) {
            picture = ImageCache.shared.cached(MailFaces.key(h))
            guard picture == nil, !model.isDemo, !address.isEmpty else { return }
            picture = await MailFaces.load(address: address, apiBase: model.config.apiBase)
        }
    }
}
