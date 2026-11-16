import BelfryCore
import SwiftUI

// A thread's own screen ("Open thread"; Reply opens it with its box focused, as the web chat
// does since chat-source 85ede89), and the search sheet of a channel (this channel or all).

struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let rootId: String
    var focusReply = false
    /// Layout callbacks write here, never view state (see ChannelView).
    @State private var feedPos = FeedPosition()
    @State private var actionsFor: Message?
    @State private var editing: Message?
    @State private var focusBox = 0

    var body: some View {
        let _ = model.version
        let d = model.derive
        let root = d.message(group, rootId)
        let replies = d.threadReplies(group, rootId)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let root {
                        MessageRow(m: root, group: group, first: true, reactions: d.reactions(group)[root.id] ?? [], thread: nil, threadOpen: false,
                                   announce: d.isAnnouncement(root, d.group(group)), todo: d.todosBySource(group)[root.id],
                                   onThread: {}, onOpenThread: {}, onReply: {}, onHold: { hold(root) })
                        HStack {
                            Text(replies.isEmpty ? "No replies yet" : "\(replies.count) \(replies.count == 1 ? "reply" : "replies")")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            VStack { Divider() }
                        }
                        .padding(.horizontal)
                    } else {
                        ContentUnavailableView("This message is gone", systemImage: "bubble.left")
                    }
                    ForEach(replies) { r in
                        ReplyRow(group: group, r: r) { hold(r) }.padding(.horizontal).id(r.id)
                    }
                    // the end (the composer sits under the scroll view)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .initialScrollAnchorBottom()
            .onChange(of: replies.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                model.markThreadRead(group, rootId)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                feedPos.settle { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                model.markThreadRead(group, rootId)
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .bottomBar {
            if model.guestReading {
                GuestBar(group: group)
            } else if model.locked(group) {
                ArchivedFooter()
            } else if let root {
                Composer(group: group, placeholder: replies.isEmpty ? "Reply (starts a thread)" : "Reply in the thread", autoFocus: focusReply, threadMode: true, focusTrigger: focusBox, draftKey: "t:\(group):\(rootId)") { text, _, _ in
                    model.reply(text, in: group, to: root)
                }
            }
        }
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $actionsFor) { m in
            MessageActions(m: m, group: group, onReply: {}, onOpenThread: {}, onEdit: { editing = m })
        }
        .sheet(item: $editing) { m in EditSheet(m: m, group: group) }
        .environment(\.messageMenu, MessageMenuHandlers(
            reply: { _ in focusBox += 1 },
            openThread: { _ in },
            edit: { m in editing = m },
            sheet: { m, delete in model.launchDelete = delete; actionsFor = m }))
        .onChange(of: actionsFor != nil || editing != nil) { _, open in if open { hideKeyboard() } }
    }

    func hold(_ m: Message) { if model.guestReading { model.joinAsked = true } else if !model.locked(group) { actionsFor = m } }
}

/// Search this channel or all (accent-folded words; tap a result to see it in its channel).
struct ChannelSearch: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: String
    let open: (String, String) -> Void
    @State private var query = ""
    @State private var everywhere = false
    @FocusState private var focused: Bool

    var body: some View {
        let hits = model.derive.search(query, channel: everywhere ? nil : channel)
        let words = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        NavigationStack {
            List {
                Section {
                    Picker("Where", selection: $everywhere) {
                        Text("This channel").tag(false)
                        Text("All channels").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if !words.isEmpty {
                    Section(hits.isEmpty ? "Nothing found" : "\(hits.count == 200 ? "200+" : String(hits.count)) \(hits.count == 1 ? "result" : "results")") {
                        ForEach(hits, id: \.m.id) { h in
                            Button { open(h.groupId, h.m.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Avatar(pubkey: h.m.pubkey, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(model.name(h.m.pubkey)).font(.subheadline.bold())
                                            if everywhere, let g = model.group(h.groupId) { Text(g.isPod ? g.name : "#" + g.name).font(.caption).foregroundStyle(.secondary) }
                                            Spacer()
                                            Text(Format.short(h.m.at)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(marked(model.derive.plainRefs(h.m.text), words)).font(.subheadline).lineLimit(3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: everywhere ? "Search all channels" : "Search this channel")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if model.launch.screen == "chsearch" && query.isEmpty { query = "ladder" } }
        }
    }

    /// The words found, marked (bold, bronze), accents and case ignored.
    func marked(_ text: String, _ words: [String]) -> AttributedString {
        var a = AttributedString(text)
        let folded = fold(text)
        guard folded.count == text.count else { return a }
        for w in words where !w.isEmpty {
            var from = folded.startIndex
            while let r = folded.range(of: w, range: from..<folded.endIndex) {
                let lo = folded.distance(from: folded.startIndex, to: r.lowerBound)
                let len = folded.distance(from: r.lowerBound, to: r.upperBound)
                let s = a.index(a.startIndex, offsetByCharacters: lo)
                let e = a.index(s, offsetByCharacters: len)
                a[s..<e].foregroundColor = .brand
                a[s..<e].inlinePresentationIntent = .stronglyEmphasized
                from = r.upperBound
            }
        }
        return a
    }
}
