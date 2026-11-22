import BelfryCore
import SwiftUI

// A thread in a direct message (canvas one-shape/dm-thread, 2026-11-22; one-shape.md §3): Reply
// on a message opens it. Two header lines only: the beginning of the message that started it,
// then the icon row (👥 people · 💬 replies). The message on top, the replies below, then "Reply
// in the thread". A reply is a kind 14 with ["e", root, "", "root"], wrapped like any other 14.

struct DmThreadRoute: Hashable, Identifiable {
    let conv: String
    let root: String
    var id: String { conv + "/" + root }
}

/// "2 replies" under a message that has a thread, with the faces of who replied.
struct RepliesLine: View {
    let dm: Dm
    let replies: [Dm]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").imageScale(.small)
                Text(replies.count == 1 ? "1 reply" : "\(replies.count) replies").fontWeight(.semibold)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: dm.mine ? .trailing : .leading)
        .accessibilityIdentifier("dm-replies")
    }
}

struct DmThreadView: View {
    @EnvironmentObject var model: AppModel
    let conv: String
    let root: String
    @State private var text = ""
    @State private var error: String?
    @State private var sending = 0

    var body: some View {
        let _ = model.version
        let list = model.dms?.thread(conv) ?? []
        let top = list.first { $0.rid == root }
        let replies = list.filter { $0.root == root && $0.rid != root }
        let locked = model.lockedHere(conv)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let top {
                        Bubble(dm: top)
                        Text(replies.count == 1 ? "1 reply" : "\(replies.count) replies")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) { Divider() }
                    }
                    ForEach(replies) { d in Bubble(dm: d) }
                }
                .padding()
                Color.clear.frame(height: 1).id("thread-end")
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: replies.count) { _, _ in DispatchQueue.main.async { withAnimation(.snappy) { proxy.scrollTo("thread-end", anchor: .bottom) } } }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                OneHeader(title: DmThreadView.title(top?.text ?? ""), items: items(replies), chevron: false)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("dm-thread-header")
            }
        }
        .onAppear { model.markConversationRead(conv) }
        .bottomBar {
            if locked {
                Text("You can write here once this device is added.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .composerBackground(compact: false)
            } else {
                composer
            }
        }
    }

    /// The beginning of the message that started the thread (thread names: not in this version).
    static func title(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return one.count > 34 ? String(one.prefix(33)).trimmingCharacters(in: .whitespaces) + "…" : one
    }

    private func items(_ replies: [Dm]) -> [HeaderItem] {
        let people = MailThreads.peers(conv).filter { $0 != model.me }.count + 1
        return [HeaderItem(key: "people", icon: "person.2", text: "\(people)", label: "\(people) people"),
                HeaderItem.count("comments", "bubble.left", replies.count, "reply", "replies")].compactMap { $0 }
    }

    private var composer: some View {
        let can = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 6) {
            if let error { Text(error).font(.caption).foregroundStyle([DirectMessages.cantCheck, Sealed.tooLong].contains(error) ? Color.secondary : Color.red).multilineTextAlignment(.center) }
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Reply in the thread", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...8)
                    .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 8)
                    .frame(minHeight: 38)
                    .accessibilityIdentifier("dm-thread-field")
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(can ? Theme.onAccent : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(can ? Theme.accent : Color.secondary.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .disabled(!can)
                .accessibilityLabel("Send")
            }
            .composerField()
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .composerBackground(compact: false)
        .sensoryFeedback(.impact(weight: .light), trigger: sending)
    }

    /// The text leaves the box at once (a double tap can't send twice); a refusal puts it back.
    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let dms = model.dms else { return }
        error = nil
        sending += 1
        text = ""
        Task {
            do { try await dms.send(t, in: conv, root: root) } catch {
                text = t
                self.error = (error as? BelfryError)?.errorDescription ?? "Not sent. Try again."
            }
        }
    }
}
