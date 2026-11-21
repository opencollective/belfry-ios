import BelfryCore
import SwiftUI

// The line under a message that is not out yet (SPEC 19.50, the same words on the three apps):
// "Sending…"; after 5 s "Still sending… · connecting / encrypting / uploading 2.2 of 4.8 MB /
// waiting for the server"; after 30 s "Not sent yet · Retry". Offline: "Waiting for the connection…".
// Read again every second while it shows (the trace's steps and the clock).

struct SendLineView: View {
    @EnvironmentObject var model: AppModel
    /// The send: a direct message's rumor id, else the outbox item's local id.
    let id: String
    let tries: Int
    var font: Font = .caption
    var icon = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let l = model.sendLine(id, tries: tries)
            HStack(spacing: 8) {
                if icon { Label(l.text, systemImage: "clock") } else { Text(l.text) }
                if l.retry {
                    Text("·").accessibilityHidden(true)
                    Button("Retry") { model.retrySends() }.font(font.weight(.semibold))
                        .accessibilityIdentifier("send-retry")
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("send-line")
        }
    }
}

extension AppModel {
    /// What the line under the send ID says now.
    func sendLine(_ id: String, tries: Int) -> SendLine {
        if launch.screen == "sendstill" { return SendLine(text: "Still sending… · waiting for the server") }
        if launch.screen == "sendnotyet" { return SendLine(text: "Not sent yet", retry: true) }
        guard let e = engine, !isDemo else { return SendLine(text: "Sending…") }
        return SendState.line(failed: false, tries: tries, progress: e.trace.progress(id), now: e.trace.now, online: e.online)
    }

    /// The most tries among a direct message's wraps.
    func dmTries(_ rid: String) -> Int { engine?.outboxItems().filter { $0.dm == rid }.map(\.tries).max() ?? 0 }

    /// "Not sent yet · Retry": every socket asked now, a fresh 30 s, a pass at once.
    func retrySends() { engine?.retryNow() }
}

/// About Belfry → Diagnostics: each socket's state and quiet time, and the last 20 sends' timing
/// (no content, name or key), with Copy.
struct DiagnosticsScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let sockets = model.engine?.socketStates() ?? []
            let lines = model.engine?.trace.lines() ?? []
            List {
                Section {
                    ForEach(sockets, id: \.name) { s in
                        LabeledContent(s.name, value: s.state + (s.quiet.map { " · quiet \($0) s" } ?? ""))
                    }
                } header: { Text("Connections") }
                Section {
                    if lines.isEmpty {
                        Text("Nothing sent yet since the app started.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, l in
                            Text(l).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                } header: { Text("Last sends") } footer: {
                    Text("How long each step of a send took. No message, name or key is kept.")
                }
                Section {
                    CopyRow(text: report(sockets, lines), title: "Copy")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func report(_ sockets: [(name: String, state: String, quiet: Int?)], _ lines: [String]) -> String {
        let head = "Belfry for iPhone \(AboutScreen.version) (\(AboutScreen.build))"
        let s = sockets.map { "\($0.name): \($0.state)" + ($0.quiet.map { ", quiet \($0) s" } ?? "") }
        return ([head] + s + [""] + lines).joined(separator: "\n")
    }
}
