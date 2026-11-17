import BelfryCore
import SwiftUI

// Belfry settings → Channels → a channel (SPEC 19.35; web Categories.tsx ChannelMoveSheet /
// EndChannelSheet, 2026-11-17): a channel nobody wrote in can be deleted, one with messages is
// archived instead, each after an in-app confirmation saying what happens. Never #general.

struct ChannelEndSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String

    enum Content { case checking, empty, used, unknown }
    @State private var content = Content.checking
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        let name = "#" + (model.group(id)?.name ?? id)
        let delete = content == .empty
        NavigationStack {
            Form {
                if !confirming {
                    Section {
                        Button {
                            error = nil
                            withAnimation(.snappy(duration: 0.2)) { confirming = true }
                        } label: {
                            HStack {
                                ActionRow(icon: content == .used || content == .unknown ? "archivebox" : "trash",
                                          title: rowTitle, detail: rowDetail, destructive: content != .checking)
                                if content == .checking { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(content == .checking)
                        .accessibilityIdentifier("channel-end")
                    } footer: {
                        Text("Moving a channel: hold it and drag it in the list.")
                    }
                } else {
                    Section {
                        Text(delete
                             ? "Nobody wrote in it yet. It goes for everyone, with its settings. This can’t be undone."
                             : "People wrote in it. It leaves the channel list and becomes read only; its messages stay. Unarchive it any time from its page.")
                        if content == .unknown {
                            Text("The channel could not be checked for messages, so it is archived (nothing is lost).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ActionButtonRow(icon: delete ? "trash" : "archivebox",
                                        title: delete ? "Delete the channel" : "Archive the channel",
                                        destructive: true) { await run(delete) }
                            .accessibilityIdentifier("channel-end-confirm")
                        Button { withAnimation(.snappy(duration: 0.2)) { confirming = false } } label: {
                            ActionRow(icon: "arrow.uturn.backward", title: "Keep it")
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(confirming ? (delete ? "Delete \(name)?" : "Archive \(name)?") : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .task(id: id) { await check() }
        .sensoryFeedback(.success, trigger: done)
    }

    @State private var done = 0

    private var rowTitle: String {
        switch content {
        case .checking: return "Delete or archive…"
        case .empty: return "Delete the channel"
        case .used, .unknown: return "Archive the channel"
        }
    }

    private var rowDetail: String {
        switch content {
        case .checking: return "Checking for messages"
        case .empty: return "Nobody wrote in it yet"
        case .used: return "It has messages: they stay readable, nobody can post"
        case .unknown: return "It could not be checked for messages: archiving loses nothing"
        }
    }

    private func check() async {
        switch await model.channelIsEmpty(id) {
        case .some(true): content = .empty
        case .some(false): content = .used
        case .none: content = .unknown
        }
        if model.launch.screen == "channelendconfirm" { confirming = true }
    }

    private func run(_ delete: Bool) async {
        error = nil
        let failed: String?
        if delete { failed = await model.deleteChannel(id) } else { failed = await model.setArchived(id, true) }
        guard let failed else {
            done += 1
            dismiss()
            return
        }
        if failed == ChannelEnd.notEmpty { content = .used } // someone wrote meanwhile: archive is offered now
        error = failed
    }
}
