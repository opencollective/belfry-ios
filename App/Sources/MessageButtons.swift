import BelfryCore
import SwiftUI

// Buttons on a message (SPEC 19.36, collective-belfry docs/actions.md): native bordered buttons
// under the text (primary = prominent, danger = destructive), all locked with a spinner after a
// tap until the answer (or 20 s: "No answer yet."), my answer as a line under them, and for
// everyone the closing answer instead of the buttons. The press is published at once, not
// through the outbox.

struct MessageButtonsView: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String
    @State private var sending: String?
    @State private var unsent = false
    @State private var asking: MessageButton?
    /// Bumped when a press's 20 seconds are up, so the view reads the state again.
    @State private var waited = 0

    var body: some View {
        let d = model.derive
        let buttons = d.buttons(m)
        if !buttons.isEmpty {
            let st = d.buttonState(m)
            let _ = waited
            let now = Int.now
            VStack(alignment: .leading, spacing: 6) {
                if st.closed {
                    Label(st.closedText.isEmpty ? "Done." : st.closedText, systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("buttons-closed")
                } else {
                    let locked = sending != nil || st.locked(now: now) || model.locked(group)
                    FlowRow(spacing: 8) {
                        ForEach(buttons) { b in button(b, st: st, locked: locked, now: now) }
                    }
                    if buttons.contains(where: { !$0.known }) {
                        Text(Buttons.unknownActionText).font(.caption).foregroundStyle(.secondary)
                    }
                    if unsent {
                        Label(Buttons.unsentText, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                    } else if let mine = st.mine {
                        result(mine, timedOut: st.timedOut(now: now))
                    }
                }
            }
            .padding(.top, 2)
            .task(id: st.mine?.press) {
                // the 20 seconds of my latest press: then "No answer yet." and the buttons unlock
                guard let p = st.mine, p.status == .waiting else { return }
                let left = Buttons.answerWait - (Int.now - p.pressedAt)
                guard left > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(left) * 1_000_000_000 + 200_000_000)
                waited += 1
            }
            .confirmationDialog(asking.map { question($0) } ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible, presenting: asking) { b in
                Button(verb(b), role: b.style == .danger ? .destructive : nil) { press(b) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    func button(_ b: MessageButton, st: ButtonState, locked: Bool, now: Int) -> some View {
        let spinning = sending == b.id || (st.locked(now: now) && st.mine?.button == b.id)
        let label = HStack(spacing: 6) {
            Text(b.label).lineLimit(1)
            if spinning { ProgressView().controlSize(.mini) }
        }
        SwiftUI.Group {
            if b.style == .primary {
                Button(role: nil) { tap(b) } label: { label }.buttonStyle(.borderedProminent)
            } else {
                Button(role: b.style == .danger ? .destructive : nil) { tap(b) } label: { label }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .disabled(locked || !b.known)
        .accessibilityIdentifier("button-" + b.id)
    }

    @ViewBuilder
    func result(_ mine: ButtonState.Mine, timedOut: Bool) -> some View {
        switch mine.status {
        case .ok:
            if !mine.text.isEmpty { Label(mine.text, systemImage: "checkmark").font(.footnote).foregroundStyle(.secondary) }
        case .error:
            Label(mine.text, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                .accessibilityIdentifier("buttons-error")
        case .waiting:
            if timedOut { Text(Buttons.timeoutText).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    func question(_ b: MessageButton) -> String {
        if b.isBelfry { return Buttons.confirmText(b.action, domain: model.config.domain) ?? b.label + "?" }
        return b.label + "?"
    }

    func verb(_ b: MessageButton) -> String { b.isBelfry ? Buttons.confirmVerb(b.action) : b.label }

    func tap(_ b: MessageButton) {
        // a reading guest: the Join sheet (SPEC 19.26)
        if model.guestReading { model.joinAsked = true; return }
        hideKeyboard()
        if b.isBelfry || b.style == .danger { asking = b } else { press(b) }
    }

    func press(_ b: MessageButton) {
        guard sending == nil else { return }
        sending = b.id
        unsent = false
        Task { @MainActor in
            let ok = await model.pressButton(m, in: group, b)
            sending = nil
            unsent = !ok
        }
    }
}

extension AppModel {
    /// Publishes my press of B on M at once (not through the outbox): false when it couldn't be sent.
    func pressButton(_ m: Message, in group: String, _ b: MessageButton) async -> Bool {
        guard let engine else { return false }
        let d = Buttons.press(messageId: m.ev.id, author: m.ev.pubkey, group: group, button: b.id)
        guard let press = try? await engine.publishNow(d) else { return false }
        if isDemo { demoAnswer(m, group: group, b, press: press) }
        return true
    }

    /// The demo's belfry (or the message's made-up author) answers a moment later.
    private func demoAnswer(_ m: Message, group: String, _ b: MessageButton, press: NostrEvent) {
        let who: LocalSigner
        if b.isBelfry { who = Demo.signer("groups") }
        else if let k = (Demo.people.map(\.0) + ["helper"]).first(where: { Demo.signer($0).pubkey == m.ev.pubkey }) { who = Demo.signer(k) }
        else { return }
        let publish = b.action == Buttons.websitePublish
        var tags: [Tag] = [["L", Buttons.resultNS], ["l", "ok", Buttons.resultNS], ["e", m.ev.id], ["press", press.id], ["p", press.pubkey], ["h", group]]
        if publish { tags.append(["closed", "1"]) }
        let text = publish ? "Published by \(realNameOrKey(me))." : "Noted."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let e = try? who.signNow(EventTemplate(kind: 1985, content: text, tags: tags, createdAt: Int.now)) else { return }
            self.engine?.add([e], verify: false)
        }
    }
}
