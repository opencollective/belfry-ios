import AVFoundation
import BelfryCore
import SwiftUI

// Audio in messages (web 59c4b10, SPEC 19.23): an attachment whose type starts with audio/ is a
// player in the feed: play / pause, position / length, one at a time, nothing fetched before
// play. The web records Opus in WebM (Chrome, Firefox) or AAC in MP4 (Safari); AVPlayer plays
// AAC/MP4 (and Opus in CAF / MP4 on iOS 17+), not WebM: such a recording says it can't play here.

@MainActor
final class AudioCenter: ObservableObject {
    static let shared = AudioCenter()
    @Published private(set) var current: String?
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var length: Double = 0
    @Published private(set) var failed = Set<String>()
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    func toggle(_ url: String) {
        if current == url, let player {
            if playing { player.pause(); playing = false } else { player.play(); playing = true }
            return
        }
        stop()
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "file" else { failed.insert(url); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: u)
        let p = AVPlayer(playerItem: item)
        player = p
        current = url
        position = 0
        length = 0
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite { self.length = d }
                if self.player?.currentItem?.status == .failed { self.failed.insert(url); self.stop() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        p.play()
        playing = true
    }

    func seek(_ to: Double) {
        player?.seek(to: CMTime(seconds: to, preferredTimescale: 600))
        position = to
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player = nil
        current = nil
        playing = false
        position = 0
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A recording in a message: ▶︎ / ❚❚, the position over the length, a slider while playing.
struct AudioRow: View {
    @ObservedObject private var center = AudioCenter.shared
    let media: Media

    var body: some View {
        let on = center.current == media.url
        let failed = center.failed.contains(media.url)
        HStack(spacing: 10) {
            Button { center.toggle(media.url) } label: {
                Image(systemName: on && center.playing ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(failed)
            .accessibilityLabel(on && center.playing ? "Pause the recording" : "Play the recording")
            VStack(alignment: .leading, spacing: 2) {
                if on && center.length > 0 {
                    Slider(value: Binding(get: { center.position }, set: { center.seek($0) }), in: 0...max(center.length, 0.1))
                        .controlSize(.mini)
                        .accessibilityLabel("Position")
                } else {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                }
                Text(failed ? "This recording can’t play on this phone." : on ? "\(AudioCenter.clock(center.position)) / \(AudioCenter.clock(center.length))" : (media.name ?? "Recording"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
