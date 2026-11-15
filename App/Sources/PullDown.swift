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

/// The panel that comes down from under the navigation bar (one surface with it): a short level
/// and a full one; the handle follows the finger and snaps (up past the short level closes it).
/// Backdrop and panel stay in the tree while they animate (drawer fix 4c549e1).
struct PullDownPanel: View {
    let id: String
    @Binding var level: PullLevel
    @Binding var topic: String?
    let openDetails: (InfoTab) -> Void
    let invite: () -> Void
    let showMessage: (String) -> Void
    @State private var drag: CGFloat = 0
    @State private var contentH: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // the panel is as tall as its rows when they are few (an empty channel: four rows)
            let natural = contentH > 0 ? contentH + 24 : .infinity
            let full = min(geo.size.height - 24, natural)
            let short = min(full, max(200, geo.size.height * 0.5))
            let base: CGFloat = level == .full ? full : level == .short ? short : 0
            let h = max(0, min(full, base + drag))
            ZStack(alignment: .top) {
                Color.black.opacity(level == .closed && drag == 0 ? 0 : 0.18 * min(1, h / max(1, short)))
                    .ignoresSafeArea(edges: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .allowsHitTesting(level != .closed)
                    .accessibilityHidden(level == .closed)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Close")
                VStack(spacing: 0) {
                    // always there (measured, clipped to nothing while closed): nothing pops in
                    PullDownList(id: id, topic: $topic, full: level == .full, close: close, openDetails: openDetails, invite: invite, showMessage: showMessage)
                        .frame(maxHeight: .infinity, alignment: .top)
                    handle(short: short, full: full)
                }
                .frame(height: h, alignment: .top)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground }))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous))
                .overlay(alignment: .bottom) { if h > 0 { Divider() } }
                .accessibilityHidden(level == .closed)
            }
        }
        .allowsHitTesting(level != .closed)
        .onPreferenceChange(PDHeightKey.self) { contentH = $0 }
    }

    private func handle(short: CGFloat, full: CGFloat) -> some View {
        Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 24)
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

/// One plain row of the pull-down (system metrics: 44 pt, a 28 pt symbol column, body title,
/// a secondary value, a chevron where it navigates).
struct PDRow<Icon: View>: View {
    @ViewBuilder let icon: () -> Icon
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon().font(.body).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body).foregroundStyle(.primary).lineLimit(2)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let value { Text(value).font(.body).foregroundStyle(.secondary).monospacedDigit() }
                if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .padding(.vertical, subtitle == nil ? 0 : 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension PDRow where Icon == Image {
    init(symbol: String, title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = true, action: @escaping () -> Void) {
        self.init(icon: { Image(systemName: symbol) }, title: title, subtitle: subtitle, value: value, chevron: chevron, action: action)
    }
}

struct PDHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A hairline inset to the rows' text.
struct PDDivider: View {
    var body: some View { Divider().padding(.leading, 56) }
}

/// A small uppercase label over a section of several rows (as in Settings).
struct PDHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PullDownList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    @Binding var topic: String?
    var full = false
    let close: () -> Void
    let openDetails: (InfoTab) -> Void
    let invite: () -> Void
    let showMessage: (String) -> Void

    private func dismiss() { close() }

    var body: some View {
        let _ = model.version
        let d = model.derive
        let now = Int.now
        let f = d.channelFacts(id, now: now)
        let g = f.group
        let allTodos = d.tasks(id)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let about = g?.about, !about.isEmpty {
                    MarkdownText(text: about).font(.subheadline).foregroundStyle(.primary)
                        .lineLimit(full ? nil : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                }
                if let g, let p = g.parent, let parent = model.group(p) {
                    PDRow(symbol: "arrow.up.left", title: (g.isProposal ? "Proposal in " : "Group in ") + (parent.isPod ? parent.name : "#" + parent.name)) { dismiss(); openChannel(p, nil) }
                    PDDivider()
                }
                if let p = f.own { ProposalBlock(p: p); PDDivider() }
                if let g, g.isPod, d.canAdmin(g), !g.applications.isEmpty {
                    PDRow(symbol: "person.crop.circle.badge.questionmark", title: "Asking to join", value: "\(g.applications.count)") { dismiss(); model.openGroup = id }
                    PDDivider()
                }
                if !f.pins.isEmpty {
                    if f.pins.count > 1 { PDHeader(text: "Pinned") }
                    ForEach(f.pins) { m in
                        PDRow(symbol: "pin", title: d.pinLine(m), subtitle: model.name(m.pubkey) + " · " + Format.day(m.at)) { showMessage(m.id) }
                        PDDivider()
                    }
                }
                if !f.events.isEmpty {
                    let shown = Array(f.events.prefix(full ? 3 : 1))
                    if shown.count > 1 { PDHeader(text: "Coming up") }
                    ForEach(shown) { e in
                        PDRow(symbol: "calendar", title: e.title, subtitle: d.lineDay(e.start, now: now) + " · " + d.lineWhen(e), value: d.stateLabel(e)) { dismiss(); model.openEvent = e.coord }
                        PDDivider()
                    }
                    if f.events.count > shown.count {
                        PDRow(symbol: "calendar.badge.clock", title: "All events", value: "\(f.events.count)") { dismiss(); model.showEvents = id }
                        PDDivider()
                    }
                }
                if !f.proposals.isEmpty {
                    if f.proposals.count > 1 { PDHeader(text: "To decide") }
                    ForEach(f.proposals) { p in
                        PDRow(symbol: "doc.text", title: p.title, subtitle: p.status.label, value: p.votingNow ? (d.myVote(p) == nil ? "Vote" : "Voted") : nil) { dismiss(); openChannel(p.groupId, nil) }
                        PDDivider()
                    }
                }
                if !allTodos.isEmpty {
                    PDRow(symbol: "checklist", title: "Todos", value: "\(allTodos.filter(\.done).count) of \(allTodos.count) done") { openDetails(.todos) }
                    PDDivider()
                }
                if !f.pods.isEmpty {
                    if f.pods.count > 1 { PDHeader(text: "Groups") }
                    ForEach(f.pods) { p in
                        PDRow(icon: { PodShape(members: p.members.count).stroke(Color.secondary, lineWidth: 1.5).frame(width: 20, height: 20) },
                              title: p.name, value: "\(p.members.count)") { dismiss(); openChannel(p.id, nil) }
                        PDDivider()
                    }
                }
                if full {
                    let photos = Array(d.files(id).filter(\.isImage).prefix(12))
                    if !photos.isEmpty {
                        PDHeader(text: "Photos")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
                            ForEach(photos, id: \.url) { m in
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay { MediaThumb(media: m, all: photos) }
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    TopicRows(id: id, topic: $topic) { dismiss() }
                }
                if !model.guestReading {
                    PDRow(symbol: "person.badge.plus", title: "Invite someone") { invite() }
                    PDDivider()
                }
                PDRow(symbol: "person.2", title: "Members", value: "\(g?.members.count ?? 0)") { openDetails(.members) }
                PDDivider()
                PDRow(symbol: "info.circle", title: "Channel info") { openDetails(.about) }
            }
            .padding(.bottom, 4)
            .background(GeometryReader { g in Color.clear.preference(key: PDHeightKey.self, value: g.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A proposal's own state in its pull-down: title, status, the vote while it is open.
struct ProposalBlock: View {
    @EnvironmentObject var model: AppModel
    let p: Proposal
    @State private var revise = false
    var body: some View {
        let d = model.derive
        let mine = d.myVote(p)
        VStack(alignment: .leading, spacing: 8) {
            Text(p.title).font(.headline)
            Text("\(p.status.label) · version \(p.version) · by \(model.name(p.author))").font(.footnote).foregroundStyle(.secondary)
            if p.votingNow {
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
            if let w = p.website, let link = websitePreviewLink(w, domain: model.config.domain), let u = URL(string: link) {
                Link(destination: u) { Label("Preview this version", systemImage: "safari") }.font(.subheadline)
            }
            HStack(spacing: 16) {
                if d.canDecide(p) {
                    Menu {
                        ForEach(ProposalStatus.allCases.filter { $0 != p.status }, id: \.self) { s in Button(s.label) { model.setStatus(p, s) } }
                    } label: { Label("Status", systemImage: "flag") }
                }
                if p.author == model.me { Button { revise = true } label: { Label("New version", systemImage: "doc.badge.plus") } }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .sheet(isPresented: $revise) { ReviseProposalSheet(p: p) }
    }
}

/// The channel's topics as rows (full level): tap filters the channel.
struct TopicRows: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @Binding var topic: String?
    let done: () -> Void
    var body: some View {
        let d = model.derive
        let pinned = d.pinnedTopics(id).filter { $0 != Derive.announcement }
        let counts = d.topicCounts(id)
        let list = pinned.map { t in (t, counts.first { $0.topic == t }?.count ?? 0) } + counts.filter { !pinned.contains($0.topic) }.prefix(8).map { ($0.topic, $0.count) }
        if !list.isEmpty || d.hasAnnouncements(id) {
            PDHeader(text: "Topics")
            if d.hasAnnouncements(id) {
                PDRow(symbol: "megaphone", title: "Announcements") { topic = Derive.announcement; done() }
                PDDivider()
            }
            ForEach(list, id: \.0) { t in
                PDRow(symbol: pinned.contains(t.0) ? "pin" : "number", title: "#" + t.0, value: "\(t.1)") { topic = t.0; done() }
                PDDivider()
            }
        }
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
