import BelfryCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Link previews built by the sender (SPEC 19.69; docs/link-previews-v2.md; canvas Channels,
// boards channels/og-*). Writing in a channel, a thread or an open group: the composer's first
// outside link is read FROM THIS PHONE once it has stood for a moment (the page and its picture,
// through `PinnedNet`: only public addresses, the ones it checked), the picture re-encoded and put
// on the belfry's Blossom; the preview stands above the field with ✕ and goes with the message.
// Reading: the box comes from the message's tags alone; its picture only from the belfry's Blossom,
// checked. Nothing is ever fetched for a message someone else sent. Not yet in direct messages.

/// JPEG, the longest side at most 1200 px, at most 300 kB (quality stepped down until it fits).
struct ImageIOEncoder: PictureEncoder {
    func encode(_ bytes: Data, mime: String) -> EncodedPicture? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: LinkPreviews.pictureSide]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        for q in [0.8, 0.65, 0.5, 0.35, 0.2] {
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dst) else { return nil }
            if out.length <= LinkPreviews.pictureOutMax { return EncodedPicture(bytes: out as Data, mime: "image/jpeg", width: img.width, height: img.height) }
        }
        return nil
    }
}

/// The previews of this session: building mine, the pictures of what I read.
@MainActor
final class LinkPreviewCenter: ObservableObject {
    enum Built: Equatable { case building, found(LinkPreview), none }
    /// The composer's previews, by link and mode (`key`).
    @Published private(set) var built = [String: Built]()
    static func key(_ link: String, _ mode: PreviewMode) -> String { (mode == .encrypted ? "e|" : "p|") + link }
    func state(_ link: String, _ mode: PreviewMode) -> Built? { built[LinkPreviewCenter.key(link, mode)] }
    @Published private(set) var pictures = [String: UIImage]()
    private var asking = Set<String>()
    weak var model: AppModel?

    private var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("link-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The composer's link stood for a moment: read it (once per link).
    func build(_ link: String, mode: PreviewMode = .plain) {
        let key = LinkPreviewCenter.key(link, mode)
        guard let m = model, built[key] == nil, let engine = m.engine, !m.guestReading else { return }
        built[key] = .building
        if m.isDemo {
            // the demo's world: a made-up page, nothing is asked
            built[key] = LinkPreviews.hostOf(link) == "toolshare.example"
                ? .found(LinkPreview(url: link, title: "How a street tool library lends 400 drills a year",
                                     description: "Neighbours started lending their tools from a garage.", site: "ToolShare Journal"))
                : Built.none
            return
        }
        let blossom = m.config.blossom
        let keepDir = dir
        let builder = PreviewBuilder(
            fetch: SafeFetch(net: PinnedNet(), resolver: SystemResolver()), encoder: ImageIOEncoder(),
            upload: { data, mime in
                try await engine.upload(data, name: mime.hasPrefix("image/") ? "preview." + mime.dropFirst(6) : "preview", mime: mime, sha: Crypto.sha256(data).hex)
            },
            blossom: blossom,
            keep: { x, plain in try? plain.write(to: keepDir.appendingPathComponent(x)) })
        Task {
            let p = await builder.build(link, mode: mode)
            self.built[key] = p.map { .found($0) } ?? Built.none
        }
    }

    /// The picture of a preview I read: kept, else downloaded from the belfry's Blossom only
    /// (no redirect followed), checked (x, decryption, ox).
    func picture(_ p: PreviewPicture) {
        guard pictures[p.x] == nil, !asking.contains(p.x), let m = model else { return }
        if let d = try? Data(contentsOf: dir.appendingPathComponent(p.x)), let img = UIImage(data: d) { pictures[p.x] = img; return }
        guard let o = LinkPreviews.originOf(m.config.blossom), LinkPreviews.originOf(p.url) == o, let url = URL(string: p.url) else { return }
        asking.insert(p.x)
        let keep = dir.appendingPathComponent(p.x)
        Task {
            defer { asking.remove(p.x) }
            guard let got = await LinkPreviewCenter.download(url), let plain = p.open(got), let img = UIImage(data: plain) else { return }
            try? plain.write(to: keep)
            pictures[p.x] = img
        }
    }

    nonisolated static func download(_ url: URL) async -> Data? {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? { nil }
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpShouldHandleCookies = false
        guard let (data, resp) = try? await URLSession.shared.data(for: req, delegate: NoRedirect()),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count <= LinkPreviews.pictureReadMax else { return nil }
        return data
    }
}

/// The box: the picture (if any), "‹site› · ‹host›", the title, two lines of description; a tap opens the link.
struct LinkPreviewCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    let p: LinkPreview
    /// Above the composer: small, one line each, no description.
    var compact = false
    var local: UIImage? = nil

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                if let img = shown {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.title.isEmpty ? p.description : p.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(p.siteLine).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            Button { if let u = URL(string: p.url) { openURL(u) } } label: {
                VStack(alignment: .leading, spacing: 0) {
                    if let pic = p.picture {
                        Color.secondary.opacity(0.12)
                            .aspectRatio(p.ratio, contentMode: .fit)
                            .overlay { if let img = shown { Image(uiImage: img).resizable().scaledToFill() } }
                            .clipped()
                            .accessibilityHidden(true)
                            .onAppear { model.linkPreviews.picture(pic) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.siteLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !p.title.isEmpty { Text(p.title).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading) }
                        if !p.description.isEmpty { Text(p.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 300, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.secondary.opacity(0.25)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("link-preview")
        }
    }

    private var shown: UIImage? { local ?? p.picture.flatMap { model.linkPreviews.pictures[$0.x] } }
}

/// Above the composer's field: the preview of the link being typed, with ✕ to send it without.
struct ComposerLinkPreview: View {
    @ObservedObject var center: LinkPreviewCenter
    let link: String
    /// A direct message's preview: its picture encrypted.
    var mode: PreviewMode = .plain
    let dismiss: () -> Void

    var body: some View {
        SwiftUI.Group {
            switch center.state(link, mode) {
            case .found(let p):
                HStack(spacing: 8) {
                    LinkPreviewCard(p: p, compact: true)
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                            .frame(width: 32, height: 32).background(Color.secondary.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send the link without its preview")
                    .accessibilityIdentifier("composer-preview-off")
                }
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.25)))
            case .building:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the link…").font(.footnote).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            default:
                Color.clear.frame(height: 0)
            }
        }
        // read once the link has stood for a moment, not at every key
        .task(id: link) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { center.build(link, mode: mode) }
        }
    }
}

extension AppModel {
    /// Do messages of GROUP get a preview from me: a channel or an open group (not a private group,
    /// whose pictures would have to be encrypted: not yet).
    func previewsIn(_ group: String) -> Bool {
        guard !group.isEmpty, let g = self.group(group) else { return false }
        // format 3: no preview where writes are encrypted or wait (its picture would go clear, §23)
        if encEngine?.previewEncrypted(group) == true || engine?.encExpected == true && encEngine == nil { return false }
        return !g.isPrivate
    }

    /// The composer's link that would get a preview in GROUP (nil: none).
    func composerPreviewLink(_ text: String, group: String) -> String? {
        guard text.contains("https://"), previewsIn(group) else { return nil }
        return LinkPreviews.outsideLink(text, tags: [], domain: config.domain, files: config.blossom)
    }

    /// The tags a message about to be sent in GROUP carries for its preview: the preview built for
    /// its link, or `["preview","none"]` after ✕, or nothing.
    func previewTags(_ text: String, group: String, off: String?) -> [Tag] {
        guard let link = composerPreviewLink(text, group: group) else { return [] }
        if off == link { return [LinkPreviews.noPreview] }
        if case .found(let p) = linkPreviews.state(link, .plain) { return p.tags() }
        return []
    }

    // ---- direct messages: inside the rumor, the picture encrypted (Notes too; never an e-mail) ----

    func dmPreviewLink(_ text: String, conv: String) -> String? {
        guard text.contains("https://"), !MailThreads.isMail(conv) else { return nil }
        return LinkPreviews.outsideLink(text, tags: [], domain: config.domain, files: config.blossom)
    }

    func dmPreviewTags(_ text: String, conv: String, off: String?) -> [Tag] {
        guard let link = dmPreviewLink(text, conv: conv) else { return [] }
        if off == link { return [LinkPreviews.noPreview] }
        if case .found(let p) = linkPreviews.state(link, .encrypted) { return p.tags() }
        return []
    }

    func preview(of d: Dm) -> LinkPreview? {
        guard d.kind == 14, let t = d.previewTags, !t.isEmpty else { return nil }
        return LinkPreviews.read(d.text, tags: t, blossom: config.blossom)
    }

    /// What a message shows: from its tags alone.
    func preview(of m: Message) -> LinkPreview? {
        guard m.special == .none, !m.previewTags.isEmpty else { return nil }
        return LinkPreviews.read(m.text, tags: m.previewTags, blossom: config.blossom)
    }
}
