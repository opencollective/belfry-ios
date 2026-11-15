import BelfryCore
import SwiftUI

// The ONE line under a channel's name (SPEC 19.13, the web's ChannelLine.tsx) and what it pulls
// down: Pinned, Coming up, To decide, To do, Pods, Topics, the people line, the description.
// The pull-down comes from the top, as on the web (ChannelHeader.tsx): the line, then a short
// level, then the full one; drag the handle, tap the line or the title, or tap outside to close.

struct ChannelLineBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    let topic: String?
    let open: () -> Void
    let showAll: () -> Void
    let review: () -> Void
    var pulled = false
    var pull: () -> Void = {}

    var body: some View {
        let line = model.derive.channelLine(id, now: .now, topic: topic, hiddenPins: model.hiddenPins)
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 6) {
                    LineIconView(line: line)
                    (Text(line.bold).fontWeight(.semibold) + Text(line.text))
                        .font(.footnote)
                        .foregroundStyle(line.quiet ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(line.counts, id: \.kind) { c in
                        HStack(spacing: 2) {
                            Image(systemName: countIcon(c.kind)).font(.caption2)
                            Text(c.plus ? "+\(c.n)" : "\(c.n)").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(c.n) \(c.label)")
                    }
                }
            }
            .buttonStyle(.plain)
            if let pill = line.pill {
                Button { act(line.action) } label: {
                    Text(pill).font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(line.ask ? Color.brand : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(line.ask ? Theme.onAccent : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(line.action == nil)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .lineBackground()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 12).onEnded { v in
            if v.translation.height > 24, !pulled { pull() }
        })
        .accessibilityElement(children: .contain)
    }

    func act(_ a: LineAction?) {
        switch a {
        case .showAll?: showAll()
        case .open?: open()
        case .review?: review()
        case .openProposal(let g)?: openChannel(g, nil)
        case .openEvent(let c)?: model.openEvent = c
        case nil: break
        }
    }

    func countIcon(_ k: String) -> String {
        switch k {
        case "events": return "calendar"
        case "proposals": return "doc.text"
        case "pods": return "hexagon"
        default: return "checklist"
        }
    }
}

struct LineIconView: View {
    let line: ChannelLine
    var body: some View {
        switch line.icon {
        case .pod:
            PodShape(members: line.podMembers).stroke(Color.secondary, lineWidth: 1.4).frame(width: 14, height: 14)
        default:
            Image(systemName: symbol).font(.caption).foregroundStyle(line.ask ? Color.brand : Color.secondary)
        }
    }
    var symbol: String {
        switch line.icon {
        case .people: return "person.2"
        case .topic: return "number"
        case .proposal: return "doc.text"
        case .pod: return "hexagon"
        case .event: return "calendar"
        case .pin: return "pin"
        }
    }
}

enum PullLevel { case closed, short, full }

extension View {
    /// The line's bar: iOS 26 lets the scroll edge effect show it; before, a bar material.
    @ViewBuilder func lineBackground() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { self } else { self.background(.bar).overlay(alignment: .bottom) { Divider() } }
        #else
        self.background(.bar).overlay(alignment: .bottom) { Divider() }
        #endif
    }
}

/// The panel that comes down from the line: a short level and a full one; the handle follows the
/// finger and snaps to the nearest level (up past the short one closes it).
struct PullDownPanel: View {
    let id: String
    @Binding var level: PullLevel
    @Binding var topic: String?
    let openDetails: () -> Void
    let showMessage: (String) -> Void
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height - 24
            let short = min(full, max(260, geo.size.height * 0.55))
            let base: CGFloat = level == .full ? full : level == .short ? short : 0
            let h = max(0, min(full, base + drag))
            ZStack(alignment: .top) {
                if level != .closed || drag != 0 {
                    Color.black.opacity(0.25 * min(1, h / max(1, short)))
                        .ignoresSafeArea(edges: .bottom)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Close")
                        .transition(.opacity)
                }
                if level != .closed {
                    VStack(spacing: 0) {
                        PullDownList(id: id, topic: $topic, close: close, openDetails: openDetails, showMessage: showMessage)
                            .frame(maxHeight: .infinity)
                        handle(short: short, full: full)
                    }
                    .frame(height: h, alignment: .top)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .allowsHitTesting(level != .closed)
    }

    private func handle(short: CGFloat, full: CGFloat) -> some View {
        Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { v in drag = v.translation.height }
                .onEnded { v in
                    let base: CGFloat = level == .full ? full : short
                    let end = base + v.predictedEndTranslation.height
                    let next: PullLevel = end < short * 0.55 ? .closed : end < (short + full) / 2 ? .short : .full
                    withAnimation(.snappy(duration: 0.28)) { level = next; drag = 0 }
                })
            .onTapGesture { withAnimation(.snappy(duration: 0.28)) { level = level == .full ? .short : .full } }
            .accessibilityElement()
            .accessibilityLabel(level == .full ? "Show less" : "Show everything")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation { level = level == .full ? .short : .full } }
    }

    private func close() { withAnimation(.snappy(duration: 0.25)) { level = .closed; drag = 0 } }
}

struct PullDownList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    @Binding var topic: String?
    let close: () -> Void
    let openDetails: () -> Void
    let showMessage: (String) -> Void
    @State private var newTodo = ""

    private func dismiss() { close() }

    var body: some View {
        let _ = model.version
        let d = model.derive
        let now = Int.now
        let f = d.channelFacts(id, now: now)
        let g = f.group
        List {
                if let about = g?.about, !about.isEmpty {
                    Section {
                        MarkdownText(text: about).font(.subheadline).lineLimit(6)
                        Text(d.visibilityLine(g)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let g, let p = g.parent, let parent = model.group(p) {
                    Section {
                        Button { dismiss(); openChannel(p, nil) } label: {
                            ActionRow(icon: "arrow.up.left", title: "\(g.isProposal ? "Proposal" : "Group") in \(parent.isPod ? parent.name : "# " + parent.name)")
                        }
                    }
                }
                if let p = f.own { ProposalSection(p: p) }
                if let g, g.isPod, d.canAdmin(g), !g.applications.isEmpty {
                    Section("\(g.applications.count) asking to join") {
                        ForEach(g.applications, id: \.pubkey) { a in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Avatar(pubkey: a.pubkey, size: 28); Text(model.name(a.pubkey)).font(.subheadline.weight(.semibold)) }
                                if !a.answer.isEmpty { Text(a.answer).font(.subheadline).foregroundStyle(.secondary) }
                                HStack {
                                    BusyButton("Let in") { model.admit(id, a.pubkey) }.buttonStyle(.brand)
                                    BusyButton("Decline", role: .destructive) { model.declineApplicant(id, a.pubkey) }.buttonStyle(.bordered)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                if !f.pins.isEmpty {
                    Section("Pinned") {
                        ForEach(f.pins) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Avatar(pubkey: m.pubkey, size: 20)
                                    Text(model.name(m.pubkey)).font(.caption.weight(.semibold))
                                    Text(Format.day(m.at)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(d.pinLine(m)).font(.subheadline).lineLimit(3)
                                HStack(spacing: 16) {
                                    Button("Show in the channel") { showMessage(m.id) }
                                    if !model.hiddenPins.contains(m.id) { Button("Got it, hide") { model.hidePin(m.id) } }
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if !f.events.isEmpty {
                    Section("Coming up") {
                        ForEach(f.events.prefix(3)) { e in
                            Button { dismiss(); model.openEvent = e.coord } label: {
                                HStack(spacing: 10) {
                                    DateChip(at: e.start)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(d.lineDay(e.start, now: now) + " · " + d.lineWhen(e)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let s = d.stateLabel(e) { Chip(text: s, tint: .brand) } else if e.status != .cancelled { Chip(text: "RSVP", tint: .brand) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if f.events.count > 3 {
                            Button { dismiss(); model.showEvents = id } label: { ActionRow(icon: "calendar", title: "All \(f.events.count) events") }
                        }
                    }
                }
                if !f.proposals.isEmpty {
                    Section("To decide") {
                        ForEach(f.proposals) { p in
                            Button { dismiss(); openChannel(p.groupId, nil) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.title).font(.subheadline.weight(.semibold))
                                        Text(p.status.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if p.votingNow { Chip(text: d.myVote(p) == nil ? "Vote" : "Voted", tint: d.myVote(p) == nil ? .brand : .secondary) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("To do") {
                    ForEach(f.todos.prefix(4)) { t in TodoRow(t: t, group: id) }
                    if f.todos.count > 4 {
                        Button { openDetails() } label: { ActionRow(icon: "checklist", title: "All \(f.todos.count) todos") }
                    }
                    HStack {
                        TextField("Add a todo", text: $newTodo).font(.body)
                        BusyButton {
                            model.addTodo(newTodo, in: id)
                            newTodo = ""
                        } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(newTodo.jsTrim().isEmpty)
                        .accessibilityLabel("Add the todo")
                    }
                }
                if !f.pods.isEmpty {
                    Section("Groups") {
                        ForEach(f.pods) { p in
                            Button { dismiss(); openChannel(p.id, nil) } label: {
                                HStack(spacing: 10) {
                                    ChannelGlyph(group: p, size: 22)
                                    Text(p.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(p.members.count) \(p.members.count == 1 ? "member" : "members")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                let photos = Array(d.files(id).filter(\.isImage).prefix(12))
                if !photos.isEmpty {
                    Section("Photos") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                            ForEach(photos, id: \.url) { m in
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay { MediaThumb(media: m, all: photos) }
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                }
                TopicsSection(id: id, topic: $topic) { dismiss() }
                Section {
                    if !f.active.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(f.active.prefix(24), id: \.pubkey) { a in
                                    Button { model.openProfile = a.pubkey } label: {
                                        VStack(spacing: 4) {
                                            Avatar(pubkey: a.pubkey, size: 40)
                                            Text(model.name(a.pubkey)).font(.caption2).lineLimit(1).frame(width: 56)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Button { openDetails() } label: {
                        ActionRow(icon: "person.2", title: peopleLine(f.active.count), detail: "Members, files, todos and settings")
                    }
                }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 4, for: .scrollContent)
    }
}

/// A photo filling its cell; a tap opens the lightbox.
struct MediaThumb: View {
    @EnvironmentObject var model: AppModel
    let media: Media
    var all: [Media] = []
    var body: some View {
        AsyncImage(url: URL(string: media.url)) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.12) }
            .contentShape(Rectangle())
            .onTapGesture {
                let urls = (all.isEmpty ? [media] : all).map(\.url)
                model.lightbox = Lightbox(urls: urls, index: urls.firstIndex(of: media.url) ?? 0)
            }
            .accessibilityLabel(media.name ?? "Photo")
            .accessibilityAddTraits(.isButton)
    }
}

/// A to-do with a box that ticks it off and who is on it.
struct TodoRow: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BusyButton {
                model.todo(t, in: group, t.done ? "undone" : "done")
            } label: {
                Image(systemName: t.done ? "checkmark.square.fill" : "square").font(.title3).foregroundStyle(t.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.done ? "Done. Mark as not done" : "Tick off")
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.subheadline).strikethrough(t.done)
                HStack(spacing: 6) {
                    if t.isWorking(now: Int.now), let since = t.workingSince { WorkingRing(since: since) }
                    Text(model.derive.todoWho(t)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !t.done {
                if t.assignee == model.me {
                    BusyButton("Let go") { model.todo(t, in: group, "unclaim") }.font(.caption).buttonStyle(.borderless)
                } else if t.assignee == nil {
                    BusyButton("I'll do it") { model.todo(t, in: group, "claim") }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
    }
}

/// Someone is on this todo now: a ring filling clockwise with the minutes of the current
/// stretch, "1h", "2h"… in it past an hour (web d6cfae1).
struct WorkingRing: View {
    let since: Int
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let mins = max(0, (Int(ctx.date.timeIntervalSince1970) - since) / 60)
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: CGFloat(mins % 60) / 60).stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                if mins >= 60 { Text("\(mins / 60)h").font(.system(size: 7, weight: .bold)) }
            }
            .frame(width: 16, height: 16)
            .accessibilityLabel("Being worked on for \(mins) minutes")
        }
    }
}

/// A proposal's own state: status, version, author, the vote while it is open, and its admins' status menu.
struct ProposalSection: View {
    @EnvironmentObject var model: AppModel
    let p: Proposal
    @State private var revise = false
    var body: some View {
        let d = model.derive
        let mine = d.myVote(p)
        Section("Proposal") {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.title).font(.headline)
                Text("\(p.status.label) · version \(p.version) · by \(model.name(p.author))").font(.caption).foregroundStyle(.secondary)
                if !p.summary.isEmpty { Text(p.summary).font(.subheadline) }
            }
            if !p.text.isEmpty { MarkdownText(text: p.text).font(.subheadline) }
            if let w = p.website {
                VStack(alignment: .leading, spacing: 6) {
                    if let link = websitePreviewLink(w, domain: model.config.domain), let u = URL(string: link) {
                        Link(destination: u) { Label("Preview this version", systemImage: "safari") }
                    }
                    Text(p.status == .passed ? "Passed: it is (or is about to be) live at \(model.config.domain)."
                         : "A new version of \(model.config.domain): it goes live once a belfry admin marks this proposal Passed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if p.votingNow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(p.tally["yes"] ?? 0) yes · \(p.tally["no"] ?? 0) no · \(p.tally["abstain"] ?? 0) abstain").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        ForEach(Proposal.voteOptions, id: \.id) { o in
                            if mine == o.id {
                                BusyButton(o.label) { model.vote(p, o.id) }.buttonStyle(.brand)
                            } else {
                                BusyButton(o.label) { model.vote(p, o.id) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if d.canDecide(p) {
                Menu {
                    ForEach(ProposalStatus.allCases.filter { $0 != p.status }, id: \.self) { s in
                        Button(s.label) { model.setStatus(p, s) }
                    }
                } label: { ActionRow(icon: "flag", title: "Change the status", detail: p.status.label) }
            }
            if p.author == model.me {
                Button { revise = true } label: { ActionRow(icon: "doc.badge.plus", title: "New version", detail: "Version \(p.version + 1)") }
            }
        }
        .sheet(isPresented: $revise) { ReviseProposalSheet(p: p) }
    }
}

/// A new version of my proposal: the text replaced, a note in its chat, a new vote while under vote.
struct ReviseProposalSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let p: Proposal
    @State private var title = ""
    @State private var summary = ""
    @State private var text = ""
    @State private var note = ""
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).font(.body)
                    TextField("In one line", text: $summary).font(.body)
                    TextField("The proposal (Markdown)", text: $text, axis: .vertical).lineLimit(4...14).font(.body)
                }
                Section { TextField("What changed (optional)", text: $note, axis: .vertical).lineLimit(1...4).font(.body) } footer: { Text(p.status == .voting ? "A new vote opens for version \(p.version + 1)." : "Everyone in its chat sees the new version.") }
            }
            .navigationTitle("Version \(p.version + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Publish") { model.reviseProposal(p, title: title.jsTrim(), summary: summary.jsTrim(), text: text.jsTrim(), note: note); dismiss() }
                        .disabled(title.jsTrim().isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                title = p.title; summary = p.summary; text = p.text
            }
        }
    }
}

/// The channel's topics: pinned first, then by use; tap filters the channel, Pin / Unpin.
struct TopicsSection: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @Binding var topic: String?
    let done: () -> Void
    var body: some View {
        let d = model.derive
        let pinned = d.pinnedTopics(id).filter { $0 != Derive.announcement }
        let counts = d.topicCounts(id)
        let rest = counts.filter { !pinned.contains($0.topic) }
        if !pinned.isEmpty || !rest.isEmpty || d.hasAnnouncements(id) {
            Section("Topics") {
                if d.hasAnnouncements(id) {
                    Button { topic = Derive.announcement; done() } label: { ActionRow(icon: "megaphone", title: "Announcements") }
                }
                ForEach(pinned, id: \.self) { t in row(t, counts.first { $0.topic == t }?.count ?? 0, pinned: true) }
                ForEach(rest.prefix(12), id: \.topic) { c in row(c.topic, c.count, pinned: false) }
            }
        }
    }

    func row(_ t: String, _ n: Int, pinned: Bool) -> some View {
        HStack {
            Button { topic = t; done() } label: { ActionRow(icon: pinned ? "pin" : "number", title: "#" + t, detail: "\(n) \(n == 1 ? "message" : "messages")") }
                .buttonStyle(.plain)
            BusyButton(pinned ? "Unpin" : "Pin") { model.pinTopic(t, in: id, !pinned) }.font(.caption).buttonStyle(.borderless)
        }
    }
}
