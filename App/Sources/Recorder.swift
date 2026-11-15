import AVFoundation
import BelfryCore
import SwiftUI

// Audio recording (web 59c4b10 Recorder.tsx; SPEC 19.25): ＋ → Audio recording. Records AAC, one
// channel, 32 kHz, 48 kbit/s into a CAF file on the device (a file cut by a crash still holds
// what was recorded, unlike an MP4 whose index comes last); Post makes an .m4a from it without
// re-encoding (AVAssetExportSession passthrough) and sends it through the outbox as the web does:
// content "🎙 Recording · <clock>", the file as an attachment. Pause / resume; a call or an alarm
// pauses it and it resumes by itself unless paused by hand. The app's `audio` background mode
// keeps it recording with the screen locked.

@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording, paused, stopped, failed(String) }
    @Published var state: State = .idle
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pausedByHand = false
    private(set) var file: URL?
    let started = Date()

    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func start() async {
        let ok = await AVAudioApplication.requestRecordPermission()
        guard ok else { state = .failed("The microphone is off for Belfry. Turn it on in Settings."); return }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard free > 50_000_000 else { state = .failed("Not enough free space on this phone to record."); return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            let f = Recorder.dir.appendingPathComponent(Recorder.fileName(started) + ".caf")
            let r = try AVAudioRecorder(url: f, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 32000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000,
            ])
            r.delegate = self
            guard r.record() else { state = .failed("The microphone could not start."); return }
            recorder = r
            file = f
            state = .recording
            UIApplication.shared.isIdleTimerDisabled = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let r = self?.recorder { self?.elapsed = r.currentTime > 0 ? r.currentTime : self?.elapsed ?? 0 } }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        } catch {
            state = .failed("The microphone could not start.")
        }
    }

    func pause() { pausedByHand = true; recorder?.pause(); state = .paused }
    func resume() { pausedByHand = false; if recorder?.record() == true { state = .recording } }

    func stop() {
        if let r = recorder { elapsed = max(elapsed, r.currentTime) }
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state != .idle { state = .stopped }
    }

    func discard() {
        stop()
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        state = .idle
    }

    @objc nonisolated private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began: if self.state == .recording { self.recorder?.pause(); self.state = .paused }
            case .ended: if self.state == .paused && !self.pausedByHand { if self.recorder?.record() == true { self.state = .recording } }
            @unknown default: break
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.stop() }
    }

    /// The .m4a to post (passthrough, no re-encoding); nil when it could not be made.
    func m4a() async -> URL? {
        guard let file else { return nil }
        let out = Recorder.dir.appendingPathComponent(Recorder.fileName(started) + ".m4a")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: file)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return nil }
        ex.outputURL = out
        ex.outputFileType = .m4a
        await ex.export()
        return ex.status == .completed ? out : nil
    }

    /// recording-YYYY-MM-DD-HHMM in the phone's time zone.
    static func fileName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "recording-" + f.string(from: d)
    }
}

struct RecorderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let group: String
    @StateObject private var rec = Recorder()
    @State private var posting = false
    @State private var error: String?
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                ZStack {
                    Circle().fill(Color.red.opacity(rec.state == .recording ? 0.15 : 0.06)).frame(width: 160, height: 160)
                        .scaleEffect(rec.state == .recording ? 1.05 : 1)
                        .animation(rec.state == .recording ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: rec.state)
                    Image(systemName: "mic.fill").font(.system(size: 52)).foregroundStyle(rec.state == .recording ? Color.red : Color.secondary)
                }
                .accessibilityHidden(true)
                Text(AudioCenter.clock(rec.elapsed)).font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                Text(status).font(.subheadline).foregroundStyle(.secondary)
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote) }
                Spacer()
                controls
            }
            .padding()
            .navigationTitle("Audio recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if rec.state == .idle { dismiss() } else { confirmDiscard = true } }
                }
            }
            .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { rec.discard(); dismiss() }
            }
            .interactiveDismissDisabled(rec.state != .idle)
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }

    private var status: String {
        switch rec.state {
        case .idle: return "Tap to start. It keeps recording with the screen locked."
        case .recording: return "Recording…"
        case .paused: return "Paused"
        case .stopped: return "Done: post it in the channel, or discard it."
        case .failed(let m): return m
        }
    }

    @ViewBuilder private var controls: some View {
        switch rec.state {
        case .idle, .failed:
            BusyButton { await rec.start() } label: { Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity) }
                .buttonStyle(.brand).controlSize(.large)
        case .recording, .paused:
            HStack(spacing: 12) {
                Button { rec.state == .recording ? rec.pause() : rec.resume() } label: {
                    Label(rec.state == .recording ? "Pause" : "Resume", systemImage: rec.state == .recording ? "pause.fill" : "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Button { rec.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand).controlSize(.large)
            }
        case .stopped:
            HStack(spacing: 12) {
                Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                BusyButton { await post() } label: { Label("Post", systemImage: "arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand).controlSize(.large)
            }
        }
    }

    private func post() async {
        error = nil
        let name = Recorder.fileName(rec.started)
        var data: Data?, mime = "audio/mp4", file = name + ".m4a"
        if let m4a = await rec.m4a() { data = try? Data(contentsOf: m4a) }
        if data == nil, let caf = rec.file { data = try? Data(contentsOf: caf); mime = "audio/x-caf"; file = name + ".caf" }
        guard let data, let a = model.saveAttachment(data, name: file, mime: mime, width: nil, height: nil) else {
            error = "The recording could not be read. Try again."
            return
        }
        model.post("🎙 Recording · " + AudioCenter.clock(rec.elapsed), in: group, attachments: [a])
        rec.discard()
        dismiss()
    }
}
