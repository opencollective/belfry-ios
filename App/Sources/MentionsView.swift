import BelfryCore
import SwiftUI

// @Mentions (web src/ui/Mentions.tsx): the latest messages that name me, from every channel; a
// tap opens the message where it is (the channel at that message, or its thread). Opening the
// list marks them seen (the drawer's badge counts the ones after).

struct MentionsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    @State private var seenBefore = 0

    var body: some View {
        let _ = model.version
        let list = model.mentions
        List {
            if list.isEmpty {
                ContentUnavailableView("No mentions yet", systemImage: "at",
                                       description: Text("When someone writes @you in a channel, it shows here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(list, id: \.id) { e in
                Button { open(e) } label: { row(e, fresh: e.createdAt > seenBefore) }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle("@Mentions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
        .refreshable { await model.refresh() }
        .onAppear {
            seenBefore = model.mentionsSeenAt
            model.markMentionsSeen()
        }
    }

    private func row(_ e: NostrEvent, fresh: Bool) -> some View {
        let h = e.tag("h") ?? ""
        let g = model.group(h)
        return HStack(alignment: .top, spacing: 12) {
            Avatar(pubkey: e.pubkey, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.name(e.pubkey)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(place(g, h)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    if e.kind == 1111 { Text("in a thread").font(.footnote).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Text(Format.short(e.createdAt)).font(.footnote).foregroundStyle(.secondary)
                }
                Text(preview(e.content)).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
            }
            if fresh { Circle().fill(Theme.accent).frame(width: 8, height: 8).padding(.top, 6).accessibilityLabel("New") }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func place(_ g: Channel?, _ h: String) -> String {
        guard let g else { return "#" + h }
        return g.label
    }

    /// nostr:npub… as @Name, channel addresses as #name, no Markdown marks, one line.
    private func preview(_ text: String) -> String {
        var t = text
        for m in Rx("nostr:(npub1[02-9ac-hj-np-z]+)").matches(text) {
            if let npub = m[1], let hex = Bech32.pubkey(npub: npub) { t = t.replacingOccurrences(of: m.whole, with: "@" + model.name(hex)) }
        }
        let plain = Rx("\\*\\*|__|~~|`").replace(model.derive.plainRefs(t), with: "")
        return plain.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func open(_ e: NostrEvent) {
        guard let h = e.tag("h") else { return }
        if e.kind == 1111, let root = e.tag("E") ?? e.tag("e") {
            model.openThread = ThreadRoute(group: h, root: root)
            openChannel(h, nil)
        } else {
            openChannel(h, e.id)
        }
    }
}
