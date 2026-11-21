import BelfryCore
import SwiftUI

// Typing indicators (SPEC 19.66; boards messages/typing-channel, typing-dm, typing-thread,
// typing-texts, typing-list, typing-setting). One line under the last message, above the composer,
// laid over the feed so it never moves it; three dots that animate in turn (still under Reduce
// Motion); "typing…" in a one-to-one conversation's row; Me → Privacy → "Show others when I'm typing".

@MainActor final class TypingCenter: ObservableObject {
    @Published private(set) var version = 0
    private var board = TypingBoard()
    private var senders = [String: TypingSender]()
    private var expiry: Task<Void, Never>?
    weak var model: AppModel?

    static let shareKey = "typing-share"
    /// The device's setting, on by default.
    static var share: Bool {
        get { UserDefaults.standard.object(forKey: shareKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shareKey) }
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    func typers(_ place: String) -> [String] {
        if let s = model?.launch.screen, s.hasPrefix("typing") { return demo(place, s) }
        return board.typers(place, now: now)
    }

    // ---- sending ----------------------------------------------------------------------------------

    /// A keystroke in the composer of PLACE left TEXT in it.
    func key(place: String, text: String, restored: Bool = false, editing: Bool = false) {
        guard TypingCenter.share, let m = model, !m.isDemo, !m.guestReading else { return }
        var s = senders[place] ?? TypingSender()
        let out = s.key(text, now: now, restored: restored, editing: editing)
        senders[place] = s
        if let out { send(place, stop: out == .stop) }
    }

    /// The composer of PLACE was emptied without sending.
    func cleared(place: String) {
        guard TypingCenter.share, let m = model, !m.isDemo else { return }
        var s = senders[place] ?? TypingSender()
        let out = s.cleared(now: now)
        senders[place] = s
        if out == .stop { send(place, stop: true) }
    }

    /// The message went: it clears the indicator by itself.
    func sent(place: String) { senders[place]?.sent() }

    private func send(_ place: String, stop: Bool) {
        guard let m = model, let e = m.engine else { return }
        if place.hasPrefix("dm:") {
            let conv = String(place.dropFirst(3))
            Task { await m.dms?.sendTyping(in: conv, stop: stop) }
            return
        }
        // "h:<group>" or "h:<group>/e:<root>"
        let body = place.dropFirst(2)
        let parts = body.components(separatedBy: "/e:")
        let group = parts[0], root = parts.count > 1 ? parts[1] : nil
        if m.locked(group) { return }
        Task {
            guard let ev = await e.signTyping(EventTemplate(kind: Typing.kind, content: "", tags: Typing.tags(group: group, root: root, stop: stop), createdAt: .now)) else { return }
            await e.publishTyping(ev, to: .groups)
        }
    }

    // ---- receiving --------------------------------------------------------------------------------

    /// A kind 20100 from the groups relay or a 21059 wrap from the community relay.
    nonisolated func receive(_ ev: NostrEvent) {
        Task { @MainActor in
            guard let m = self.model else { return }
            if ev.kind == Typing.kind, let h = ev.tag("h") {
                // people not in the group (or removed) never show
                guard let g = m.derive.group(h), m.derive.inChannel(g, ev.pubkey) else { return }
                self.take(place: Typing.place(group: h, root: ev.tag("e")), author: ev.pubkey, createdAt: ev.createdAt, stop: Typing.isStop(ev.tags))
            } else if ev.kind == Typing.wrapKind, let t = await m.dms?.openTyping(ev) {
                self.take(place: Typing.place(conv: t.conv), author: t.author, createdAt: t.createdAt, stop: t.stop)
            }
        }
    }

    private func take(place: String, author: String, createdAt: Int, stop: Bool) {
        guard let me = model?.me else { return }
        if board.event(place: place, author: author, createdAt: TimeInterval(createdAt), stop: stop, now: now, me: me) { changed() }
    }

    /// A message of AUTHOR landed in PLACE (or in any thread of the group, for a channel message).
    func message(place: String, author: String) {
        board.message(place: place, author: author)
        changed()
    }

    private func changed() {
        version += 1
        expiry?.cancel()
        board.prune(now: now)
        // read again when the next person stops showing
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Typing.showFor * 1_000_000_000) + 100_000_000)
            guard !Task.isCancelled else { return }
            self?.changed()
        }
    }

    /// The screenshots' made-up typers.
    private func demo(_ place: String, _ screen: String) -> [String] {
        guard let m = model else { return [] }
        let ana = Demo.signer("ana").pubkey, ben = Demo.signer("ben").pubkey, chloe = Demo.signer("chloe").pubkey
        switch screen {
        case "typingdm", "typinglist": return place.hasPrefix("dm:") && place.contains(ana) ? [ana] : []
        case "typingtwo": return place.hasPrefix("h:") && !place.contains("/e:") ? [ana, ben] : []
        case "typingmany": return place.hasPrefix("h:") ? [ana, ben, chloe] : []
        default: return place.hasPrefix("h:") && m.isDemo ? [ana] : []
        }
    }
}

/// "Lina Moreau is typing…" with the names semibold, and the dots.
struct TypingLine: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: TypingCenter
    let place: String
    @State private var said = ""

    var body: some View {
        let names = center.typers(place).map { model.name($0) }
        let line = Typing.text(names)
        HStack(spacing: 6) {
            if !names.isEmpty {
                TypingDots()
                text(names).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .padding(.horizontal, 16)
        .opacity(names.isEmpty ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
        .accessibilityHidden(names.isEmpty)
        .accessibilityIdentifier("typing-line")
        .onChange(of: line) { _, l in
            // VoiceOver: politely, once per change of names
            guard !l.isEmpty, l != said else { return }
            said = l
            let a = NSAttributedString(string: l, attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low])
            UIAccessibility.post(notification: .announcement, argument: a)
        }
    }

    private func text(_ names: [String]) -> Text {
        switch names.count {
        case 1: return Text(names[0]).fontWeight(.semibold) + Text(" is typing…")
        case 2: return Text(names[0]).fontWeight(.semibold) + Text(" and ") + Text(names[1]).fontWeight(.semibold) + Text(" are typing…")
        default: return Text("Several people are typing…")
        }
    }
}

/// Three dots that light in turn over 1.2 s; still when the system asks for reduced motion.
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: still)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().frame(width: 5, height: 5)
                        .opacity(still ? 0.6 : (Int(t / 0.4) == i ? 1 : 0.35))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Me → Privacy: "Show others when I'm typing", per device.
struct PrivacyScreen: View {
    @State private var share = TypingCenter.share
    var body: some View {
        Form {
            Section {
                Toggle("Show others when I'm typing", isOn: $share)
                    .tint(Theme.toggle)
                    .accessibilityIdentifier("typing-toggle")
            } footer: {
                Text("When this is off, this phone doesn't tell anyone you're typing. You still see when others are.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: share) { _, v in TypingCenter.share = v }
    }
}
