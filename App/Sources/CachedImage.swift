import BelfryCore
import CryptoKit
import SwiftUI
import UIKit

// Offline first (CLAUDE.md): avatars, photos, logos and covers come from a cache on the phone —
// memory, then a file per address in Caches/images — and only then from the network, once. A
// picture seen before shows at once, with the network off too. AsyncImage's look and phases.

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private var inflight = [String: Task<UIImage?, Never>]()
    private let lock = NSLock()

    init() {
        memory.totalCostLimit = 80 * 1024 * 1024
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ url: String) -> URL {
        dir.appendingPathComponent(SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Keeps IMAGE as URL's picture (the demo's photos, made on the device).
    func put(_ url: String, _ image: UIImage) {
        if let data = image.jpegData(compressionQuality: 0.8) { try? data.write(to: file(url), options: .atomic) }
        memory.setObject(image, forKey: url as NSString)
    }

    /// In memory only (for the first frame).
    func cached(_ url: String) -> UIImage? { memory.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if let m = cached(url) { return m }
        lock.lock()
        if let t = inflight[url] { lock.unlock(); return await t.value }
        let f = file(url)
        let t = Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let d = try? Data(contentsOf: f), let img = UIImage(data: d) { return img }
            guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { return nil }
            var req = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            req.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400, let img = UIImage(data: data) else { return nil }
            try? data.write(to: f, options: .atomic)
            return img
        }
        inflight[url] = t
        lock.unlock()
        let img = await t.value
        lock.lock(); inflight[url] = nil; lock.unlock()
        if let img { memory.setObject(img, forKey: url as NSString, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
        return img
    }
}

struct CachedImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content
    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0.absoluteString) })
    }

    var body: some View {
        content(image.map { .success(Image(uiImage: $0)) } ?? (failed ? .failure(URLError(.cannotDecodeContentData)) : .empty))
            .task(id: url) {
                guard let url else { failed = true; return }
                if image != nil, ImageCache.shared.cached(url.absoluteString) != nil { return }
                if let img = await ImageCache.shared.load(url.absoluteString) { image = img } else { failed = true }
            }
    }
}

extension CachedImage {
    init<I: View, P: View>(url: URL?, @ViewBuilder content: @escaping (Image) -> I, @ViewBuilder placeholder: @escaping () -> P) where Content == _ConditionalContent<I, P> {
        self.init(url: url) { phase in
            if let img = phase.image { content(img) } else { placeholder() }
        }
    }
}
