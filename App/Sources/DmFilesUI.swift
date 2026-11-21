import AVFoundation
import BelfryCore
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// Pictures, files and audio recordings in a direct message (boards messages/attach-plus,
// attach-thread, attach-sending, attach-sealed; vectors/dm-files.json). A picture shows on its own,
// rounded, no bubble; several sent together are one 2 × 2 block ("+N" on the fourth); a file is its
// name and "PDF · 1.2 MB"; a recording is play, a waveform, the duration. What I send is dimmed
// until it is out, the progress on the line under it only.

/// A run of a conversation: files sent together (and their caption), or one message.
struct DmBlock: Identifiable {
    var files: [Dm]
    var caption: Dm?
    var id: String { files.first?.rid ?? caption?.rid ?? UUID().uuidString }
}

enum DmBlocks {
    static func of(_ list: [Dm]) -> [DmBlock] {
        let by = Dictionary(list.map { ($0.rid, $0) }, uniquingKeysWith: { a, _ in a })
        let pieces = list.map { DmFiles.Piece(id: $0.rid, kind: $0.kind == DmFiles.kind ? 15 : $0.kind, author: $0.from, at: $0.at, group: $0.group) }
        return DmFiles.bubbles(pieces).map { b in DmBlock(files: b.files.compactMap { by[$0] }, caption: b.caption.flatMap { by[$0] }) }
    }
}

/// The files of one block, on my side or theirs, with the send line under it when it is mine and not out.
struct DmFilesBlock: View {
    @EnvironmentObject var model: AppModel
    let files: [Dm]

    var body: some View {
        let mine = files.first?.mine == true
        let pictures = files.filter { $0.file?.isPicture == true }
        let others = files.filter { $0.file?.isPicture != true }
        let pending = files.first { $0.pending == true }
        let failed = files.first { $0.failed != nil }
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if pictures.count == 1, let f = pictures.first?.file { DmPicture(file: f, width: 240, all: pictures.compactMap(\.file), index: 0) }
            else if pictures.count > 1 { DmPictureGrid(files: pictures.compactMap(\.file)) }
            ForEach(others) { d in
                if let f = d.file {
                    if f.isAudio { DmAudioRow(file: f, mine: mine) } else { DmFileRow(file: f, mine: mine) }
                } else {
                    Label(DmFiles.unreadable, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            HStack(spacing: 6) {
                Text(Format.time(files.first?.at ?? 0)).font(.caption2).foregroundStyle(.secondary)
                if let f = failed {
                    Label("Not sent", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.red).help(f.failed ?? "")
                    Button("Retry") { model.dms?.retryFile(f) }.font(.caption2.weight(.semibold))
                } else if let p = pending {
                    SendLineView(id: p.rid, tries: model.dmTries(p.rid), font: .caption2, icon: false)
                }
            }
        }
        .opacity(mine && (pending != nil || failed != nil) ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The plain bytes of a file of a direct message, loaded once (this device's copy, or downloaded
/// and checked). FAILED: "This file can't be opened".
@MainActor final class DmFileLoader: ObservableObject {
    @Published var data: Data?
    @Published var failed = false
    private var started = false

    func load(_ f: DmFile, _ model: AppModel) {
        guard !started else { return }
        started = true
        Task {
            let d = await model.dms?.plain(f)
            data = d
            failed = d == nil
        }
    }
}

struct DmPicture: View {
    @EnvironmentObject var model: AppModel
    let file: DmFile
    var width: CGFloat = 240
    var height: CGFloat? = nil
    var all: [DmFile] = []
    var index = 0
    var overlay: String? = nil
    @StateObject private var loader = DmFileLoader()
    @State private var open = false

    var body: some View {
        let ratio = file.size2.map { CGFloat($0.h) / CGFloat($0.w) } ?? 0.75
        let h = height ?? min(320, width * ratio)
        ZStack {
            if let d = loader.data, let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFill()
            } else if loader.failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.title2)
                    Text(DmFiles.unreadable).font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary).padding(8)
            } else {
                Color(.secondarySystemBackground)
            }
            if let overlay {
                Color.black.opacity(0.45)
                Text(overlay).font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: width, height: h)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { if loader.data != nil { open = true } }
        .onAppear { loader.load(file, model) }
        .fullScreenCover(isPresented: $open) { DmPictureViewer(files: all.isEmpty ? [file] : all, start: index) }
        .accessibilityElement()
        .accessibilityLabel("Picture")
        .accessibilityAddTraits(.isButton)
    }
}

/// Several pictures sent together: a 2 × 2 grid, "+N" on the fourth.
struct DmPictureGrid: View {
    let files: [DmFile]
    var body: some View {
        let cell: CGFloat = 118
        let shown = Array(files.prefix(4))
        let rest = files.count - 4
        LazyVGrid(columns: [GridItem(.fixed(cell), spacing: 4), GridItem(.fixed(cell), spacing: 4)], spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, f in
                DmPicture(file: f, width: cell, height: cell, all: files, index: i, overlay: i == 3 && rest > 0 ? "+\(rest)" : nil)
            }
        }
        .frame(width: cell * 2 + 4)
    }
}

/// Full screen: swipe between the block's pictures; Save and Share.
struct DmPictureViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let files: [DmFile]
    let start: Int
    @State private var page = 0
    @State private var images = [String: UIImage]()
    @State private var saved = false

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                    SwiftUI.Group {
                        if let img = images[f.ox] { Image(uiImage: img).resizable().scaledToFit() } else { ProgressView().tint(.white) }
                    }
                    .tag(i)
                    .task { if images[f.ox] == nil, let d = await model.dms?.plain(f), let img = UIImage(data: d) { images[f.ox] = img } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: files.count > 1 ? .automatic : .never))
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let img = current {
                        Button {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                            saved = true
                        } label: { Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "square.and.arrow.down") }
                        .sensoryFeedback(.success, trigger: saved) { _, n in n }
                        Spacer()
                        ShareLink(item: Image(uiImage: img), preview: SharePreview("Picture", image: Image(uiImage: img))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
            .onChange(of: page) { _, _ in saved = false }
        }
        .onAppear { page = start }
    }

    private var current: UIImage? { files.indices.contains(page) ? images[files[page].ox] : nil }
}

/// A file: its name (cut in the middle), "PDF · 1.2 MB"; a tap opens it in the phone's viewer.
struct DmFileRow: View {
    @EnvironmentObject var model: AppModel
    let file: DmFile
    let mine: Bool
    @State private var preview: URL?
    @State private var opening = false
    @State private var failed = false

    var body: some View {
        Button { Task { await open() } } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)).frame(width: 40, height: 46)
                    if opening { ProgressView() } else { Image(systemName: "doc.text").font(.title3).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.shownName).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(failed ? DmFiles.unreadable : DmFiles.typeAndSize(file)).font(.caption).foregroundStyle(failed ? .red : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 260)
            .background(mine ? Color.brand.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(opening)
        .quickLookPreview($preview)
        .accessibilityLabel("\(file.shownName), \(DmFiles.typeAndSize(file))")
    }

    private func open() async {
        opening = true
        defer { opening = false }
        guard let url = await DmFileCopies.copy(file, model) else { failed = true; return }
        failed = false
        preview = url
    }
}

/// A plain copy with its shown name in the app's temporary folder, for the viewer and the player.
enum DmFileCopies {
    @MainActor static func copy(_ f: DmFile, _ model: AppModel) async -> URL? {
        guard let d = await model.dms?.plain(f) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dm-open-" + String(f.ox.prefix(16)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = f.shownName
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(mimeType: f.mime)?.preferredFilenameExtension { name += "." + ext }
        let url = dir.appendingPathComponent(name)
        do { try d.write(to: url, options: .completeFileProtection) } catch { return nil }
        return url
    }
}

/// A recording: play / pause, a waveform that fills as it plays, the duration. It never leaves the
/// conversation.
struct DmAudioRow: View {
    @EnvironmentObject var model: AppModel
    let file: DmFile
    let mine: Bool
    @StateObject private var player = DmAudioPlayer()

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await player.toggle(file, model) } } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.brand.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let done = player.progress
                HStack(spacing: 2) {
                    ForEach(0..<28, id: \.self) { i in
                        Capsule().fill(Double(i) / 28 < done ? Color.primary : Color.secondary.opacity(0.4))
                            .frame(width: 3, height: DmAudioRow.bar(file.ox, i))
                    }
                }
                .frame(height: 26)
            }
            .accessibilityHidden(true)
            Text(player.failed ? "Can't be opened" : DmFiles.clock(file.duration ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(mine ? Color.brand.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio recording, \(DmFiles.clock(file.duration ?? 0))")
        .onDisappear { player.stop() }
    }

    /// A bar's height, the same for a file every time (from its hash).
    static func bar(_ ox: String, _ i: Int) -> CGFloat {
        let bytes = Array(ox.utf8)
        let v = bytes.isEmpty ? 0 : Int(bytes[i % bytes.count]) % 16
        return 6 + CGFloat(v) * 1.25
    }
}

@MainActor final class DmAudioPlayer: ObservableObject {
    @Published var playing = false
    @Published var failed = false
    private var player: AVAudioPlayer?

    var progress: Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
    }

    func toggle(_ f: DmFile, _ model: AppModel) async {
        if let p = player {
            if p.isPlaying { p.pause(); playing = false } else { p.play(); playing = true }
            return
        }
        guard let d = await model.dms?.plain(f), let p = try? AVAudioPlayer(data: d) else { failed = true; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = p
        p.play()
        playing = true
        Task { @MainActor in
            while let p = self.player, p.isPlaying { try? await Task.sleep(nanoseconds: 250_000_000) }
            self.playing = false
        }
    }

    func stop() { player?.stop(); playing = false }
}

/// The ＋ of a conversation: Photos, File, Audio recording (board messages/attach-plus).
struct DmAddMenu: View {
    @EnvironmentObject var model: AppModel
    let conv: String
    @Binding var error: String?
    @State private var photoPicker = false
    @State private var photos = [PhotosPickerItem]()
    @State private var filePicker = false
    @State private var recording = false

    var body: some View {
        Menu {
            Button { hideKeyboard(); photoPicker = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            Button { hideKeyboard(); filePicker = true } label: { Label("File", systemImage: "doc") }
            Button { hideKeyboard(); recording = true } label: { Label("Audio recording", systemImage: "mic") }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Color.secondary.opacity(0.15), in: Circle())
        }
        .accessibilityLabel("Add a picture, a file or a recording")
        .accessibilityIdentifier("dm-add")
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item]) { r in
            if case .success(let url) = r { sendFile(url) }
        }
        .sheet(isPresented: $recording) {
            RecorderSheet(group: "") { data, mime, name, seconds in
                send([OutgoingFile(data: data, mime: mime, name: name, duration: seconds)])
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photos = []
        Task {
            var out = [OutgoingFile]()
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let img = UIImage(data: data)
                let jpeg = img?.jpegData(compressionQuality: 0.85) ?? data
                let dim = img.map { "\(Int($0.size.width * $0.scale))x\(Int($0.size.height * $0.scale))" }
                out.append(OutgoingFile(data: jpeg, mime: "image/jpeg", name: nil, dim: dim))
            }
            send(out)
        }
    }

    private func sendFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { error = DmFiles.unreadable; return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // a video goes as a file: no inline video for now
        send([OutgoingFile(data: data, mime: mime, name: url.lastPathComponent)])
    }

    private func send(_ files: [OutgoingFile]) {
        guard !files.isEmpty, let dms = model.dms else { return }
        let guest = model.derive.amGuest
        let limit = guest ? DmFiles.guestMaxBytes : DmFiles.maxBytes
        if files.contains(where: { $0.data.count > limit }) { error = DmFiles.tooLarge(guest: guest); return }
        error = nil
        Task { @MainActor in
            do { try await dms.sendFiles(files, in: conv, guest: guest) }
            catch { self.error = (error as? BelfryError)?.errorDescription ?? "Not sent. Try again." }
        }
    }
}
