import BelfryCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// Pictures show in the message (Xavier via the lead, 2026-11-22: "Images should be displayed
// inline instead of linked as a file"): a channel message, a thread reply, an e-mail card or
// thread in a channel, an e-mail in a Messages thread. One picture is large; several sent together
// are a 2 × 2 grid ("+N" on the fourth), as in direct messages; a tap opens the zoom viewer. Other
// files stay file rows, and so does a picture that can't be loaded or opened.

/// A message's attachments: its pictures (one large, or the grid), then everything else.
struct MediaBlock: View {
    let media: [Media]

    static func shows(_ m: Media) -> Bool {
        guard m.isImage, let u = URL(string: m.url) else { return false }
        return ["https", "http", MailPictureKeys.scheme].contains(u.scheme ?? "")
    }

    var body: some View {
        let pictures = media.filter(MediaBlock.shows)
        let others = media.filter { !MediaBlock.shows($0) }
        if pictures.count > 1 { PictureGrid(pictures: pictures) }
        else if let one = pictures.first { MediaView(media: one, all: pictures) }
        ForEach(others, id: \.url) { MediaView(media: $0, all: media) }
    }
}

/// Several pictures of one message (boards messages/email-pictures, one-shape/email-pictures,
/// canvas v179): two side by side; three = two and one wide under them; four or more = 2 × 2 with
/// "+N" on the fourth. A tap opens the viewer at that picture.
struct PictureGrid: View {
    @EnvironmentObject var model: AppModel
    let pictures: [Media]
    static let cell: CGFloat = 118
    static let gap: CGFloat = 4

    var body: some View {
        let c = PictureGrid.cell, g = PictureGrid.gap
        let rest = pictures.count - 4
        VStack(alignment: .leading, spacing: g) {
            HStack(spacing: g) { tile(0, c); tile(1, c) }
            if pictures.count == 3 { tile(2, c * 2 + g) }
            else if pictures.count > 3 { HStack(spacing: g) { tile(2, c); tile(3, c, more: rest) } }
        }
        .frame(width: c * 2 + g, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("picture-grid")
    }

    private func tile(_ i: Int, _ width: CGFloat, more: Int = 0) -> some View {
        let m = pictures[i]
        return CachedImage(url: URL(string: m.url)) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure: Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            default: Color.secondary.opacity(0.12)
            }
        }
        .frame(width: width, height: PictureGrid.cell)
        .background(Color.secondary.opacity(0.12))
        .overlay {
            if more > 0 {
                ZStack { Color.black.opacity(0.45); Text("+\(more)").font(.title2.weight(.semibold)).foregroundStyle(.white) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            hideKeyboard()
            model.lightbox = Lightbox(urls: pictures.map(\.url), index: i)
        }
        .accessibilityLabel(more > 0 ? "\(more + 1) more photos" : (m.name ?? "Photo \(i + 1) of \(pictures.count)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the photo")
    }
}

/// The names under which an e-mail's pictures are kept in the picture cache (never a web address:
/// nothing is fetched for them).
enum MailPictureKeys {
    static let scheme = "mailpic"
    static func key(_ rid: String, _ i: Int) -> String { "\(scheme)://\(rid)/\(i)" }
}

/// An e-mail's parts, read once (a large e-mail is fetched and opened on the device).
@MainActor final class MailPartsLoader: ObservableObject {
    struct Loaded {
        var pictures: [Media]
        var files: [MailPart]
    }
    @Published var loaded: Loaded?
    @Published var failed = false
    private var started = false
    private static var memo = [String: Loaded]()

    func load(_ dm: Dm, _ model: AppModel) {
        if loaded == nil, let m = MailPartsLoader.memo[dm.rid] { loaded = m }
        guard !started, loaded == nil else { return }
        started = true
        Task {
            guard let mail = await model.dms?.mail(dm) else { failed = true; started = false; return }
            let rid = dm.rid
            let out = await Task.detached(priority: .userInitiated) { () -> Loaded in
                var pictures = [Media](), files = [MailPart]()
                for (i, p) in mail.attachments.enumerated() {
                    // a picture that does not open stays a file row
                    if MailPictures.isPicture(type: p.type, name: p.name), let img = UIImage(data: p.data) {
                        let key = MailPictureKeys.key(rid, i)
                        ImageCache.shared.put(key, img)
                        pictures.append(Media(url: key, mime: "image/jpeg", name: p.name == "attachment" ? nil : p.name,
                                              w: Int(img.size.width * img.scale), h: Int(img.size.height * img.scale)))
                    } else {
                        files.append(p)
                    }
                }
                return Loaded(pictures: pictures, files: files)
            }.value
            MailPartsLoader.memo[rid] = out
            loaded = out
        }
    }

    func retry(_ dm: Dm, _ model: AppModel) { failed = false; load(dm, model) }
}

/// Under an e-mail's text in a Messages thread: its pictures in the message, its other files as
/// rows that open in the phone's viewer. Until the parts are read (or when they can't be): the
/// file rows by name, as before.
struct MailAttachments: View {
    @EnvironmentObject var model: AppModel
    let dm: Dm
    @StateObject private var loader = MailPartsLoader()

    var body: some View {
        let atts = dm.attachments ?? []
        VStack(alignment: dm.mine ? .trailing : .leading, spacing: 6) {
            if let l = loader.loaded {
                MediaBlock(media: l.pictures)
                ForEach(Array(l.files.enumerated()), id: \.offset) { _, p in MailFileRow(part: p, mine: dm.mine) }
            } else if loader.failed, dm.large != nil, dm.attachments == nil {
                Button { loader.retry(dm, model) } label: {
                    Label("This e-mail couldn't be loaded. Tap to try again.", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("mail-retry")
            } else if dm.large != nil, dm.attachments == nil {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading the e-mail…").font(.caption).foregroundStyle(.secondary) }
            } else {
                ForEach(atts, id: \.name) { a in
                    Label("\(a.name) · \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))", systemImage: "paperclip").font(.caption)
                }
            }
        }
        .onAppear { if !atts.isEmpty || dm.large != nil { loader.load(dm, model) } }
    }
}

/// A file of an e-mail: its name, "PDF · 1.2 MB"; a tap opens it in the phone's viewer.
struct MailFileRow: View {
    let part: MailPart
    let mine: Bool
    @State private var preview: URL?

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)).frame(width: 40, height: 46)
                    Image(systemName: "doc.text").font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 260)
            .background(mine ? Color.brand.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .quickLookPreview($preview)
        .accessibilityLabel("\(part.name), \(line)")
        .accessibilityIdentifier("mail-file")
    }

    private var line: String {
        // a picture that could not be shown in the message (canvas v179)
        if MailPictures.isPicture(type: part.type, name: part.name) { return "Picture · couldn't be opened" }
        let ext = (part.name as NSString).pathExtension.uppercased()
        let kind = ext.isEmpty ? (UTType(mimeType: part.type)?.preferredFilenameExtension?.uppercased() ?? "File") : ext
        return kind + " · " + ByteCountFormatter.string(fromByteCount: Int64(part.data.count), countStyle: .file)
    }

    private func open() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mail-open-" + Crypto.sha256(part.data).hex.prefix(16), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = part.name.replacingOccurrences(of: "/", with: "-")
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(mimeType: part.type)?.preferredFilenameExtension { name += "." + ext }
        let url = dir.appendingPathComponent(name)
        do { try part.data.write(to: url, options: .completeFileProtection); preview = url } catch {}
    }
}
