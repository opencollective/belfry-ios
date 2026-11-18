import BelfryCore
import SwiftUI

// A proposal's chat with the proposal at its top (the owner's mock-ups Proposal-A / B, 2026-11-18:
// "The proposal view should show at the top the actual proposal (in the same way that an event
// shows at the top the main details of the event)"). The event screen's header mechanics (SPEC
// 19.29; three levels, a handle that drags and snaps, opening at half) and its layout rules (fixed
// frames in both directions, nothing written from layout callbacks on a hot path, the chat a plain
// embedded stack):
// - half: the status pill, "Proposal by <name> · version N", the title, the start of the text,
//   "Read the full proposal", the vote buttons with their counts (the poll's own options) and
//   "You haven't voted yet · X of Y members have";
// - full: the whole text, the website version's preview, Change the status / New version;
// - up (typing, or pulled up): one bar with the title, the pill, the tally and Vote (a menu of the
//   options) or my vote.
// Under it Chat · Versions · Votes, only the tabs with something in them (web 763910e): Versions
// once a version 2 exists, Votes once someone voted. The channel's own screens are in the ⋯ menu.

enum ProposalTab: String, Hashable { case chat = "Chat", versions = "Versions", votes = "Votes" }

struct ProposalScreen: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var focus: String?
    var pushed = false

    var body: some View {
        let _ = model.version
        if let p = model.derive.proposalFor(id) {
            ProposalScreenBody(id: id, p: p, pushed: pushed)
        } else {
            // the text hasn't arrived yet: the plain chat
            ChannelView(id: id, focus: focus, pushed: pushed)
        }
    }
}

struct ProposalScreenBody: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    let p: Proposal
    let pushed: Bool
    @State private var level: EventLevel = .half
    @State private var drag: CGFloat = 0
    @State private var halfContentH: CGFloat = 0
    @State private var page = EventScreenBody.PageBox(top: 0, width: 0, height: 0)
    /// Pulled up (after its animation): the folded bar instead of the header.
    @State private var folded = false
    @State private var revise = false
    @State private var place: ChannelPlace?
    @State private var notify = false
    @State private var search = false
    @State private var launched = false
    @State private var tab = ProposalTab.chat
    @State private var profile: ProfileKey?

    static let handleH: CGFloat = 22
    static let pickerH: CGFloat = 48
    static let foldedH: CGFloat = 60

    var body: some View {
        let _ = LoopWatch.tick("ProposalScreenBody")
        let total = page.height
        let hs = heights(total)
        let h = height(hs)
        let tabs = tabsShown
        let shown = tabs.contains(tab) ? tab : .chat
        let pick: CGFloat = tabs.count > 1 ? ProposalScreenBody.pickerH : 0
        let paneH = max(0, total - h - ProposalScreenBody.handleH - pick)
        let hidden = level == .full && drag == 0
        Color.clear
            .onGeometryChange(for: EventScreenBody.PageBox.self) { EventScreenBody.PageBox(top: $0.safeAreaInsets.top.rounded(), width: $0.size.width.rounded(), height: $0.size.height.rounded()) } action: { b in
                if b != page { page = b }
            }
            .background(alignment: .top) {
                PDSurface.color.frame(height: page.top + 1).ignoresSafeArea(edges: .top).allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    header(h: h, hs: hs)
                    handle(hs)
                    if tabs.count > 1 {
                        Picker("Show", selection: $tab) {
                            ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .frame(width: page.width, height: pick)
                        .opacity(hidden ? 0 : 1)
                        .accessibilityIdentifier("proposal-tabs")
                    }
                    ZStack {
                        // the chat stays in the tree (its place, its draft); the lists only while shown
                        ChannelView(id: id, embedded: true)
                            .opacity(shown == .chat ? 1 : 0)
                            .allowsHitTesting(shown == .chat)
                            .accessibilityHidden(shown != .chat)
                        if shown == .versions { ProposalVersionsList(p: p) { withAnimation(.snappy(duration: 0.28)) { level = .full } } }
                        if shown == .votes { ProposalVotesList(p: p) { pk in hideKeyboard(); profile = ProfileKey(pubkey: pk, group: id) } }
                    }
                    .frame(width: page.width, height: paneH)
                    .opacity(hidden ? 0 : 1)
                    .allowsHitTesting(!hidden)
                }
                .opacity(page.height > 0 ? 1 : 0)
            }
            .navigationTitle(p.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(item: $profile) { ProfileView(pubkey: $0.pubkey, pushed: true, group: $0.group) }
            .navigationDestination(item: $place) { pl in
                ChannelPlaceView(id: id, place: pl, go: { _ in place = nil }, filter: { _ in place = nil })
            }
            .sheet(isPresented: $revise) { ReviseProposalSheet(p: p) }
            .sheet(isPresented: $notify) { NotifySheet(id: id) }
            .sheet(isPresented: $search) {
                ChannelSearch(channel: id) { gid, mid in
                    search = false
                    if gid != id { openChannel(gid, mid) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                // typing in the chat: the proposal folds into its bar
                if level != .up { withAnimation(.snappy(duration: 0.25)) { level = .up } }
            }
            .onChange(of: level) { _, l in
                if l == .up {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if level == .up { folded = true } }
                } else {
                    folded = false
                }
            }
            .onChange(of: drag) { _, v in if v != 0 { folded = false } }
            .onChange(of: revise || notify || search || place != nil) { _, open in if open { hideKeyboard() } }
            .onAppear(perform: applyLaunch)
    }

    // ---- levels --------------------------------------------------------------------------------

    private func heights(_ total: CGFloat) -> EventScreenBody.Heights {
        let up = ProposalScreenBody.foldedH
        let full = max(up + 120, total - ProposalScreenBody.handleH)
        let measured = halfContentH > 0 ? halfContentH : 340
        let half = min(full, max(up + 120, min(measured, total * 0.68)))
        return EventScreenBody.Heights(up: up, half: half, full: full)
    }

    private func height(_ hs: EventScreenBody.Heights) -> CGFloat {
        let base: CGFloat = level == .up ? hs.up : level == .half ? hs.half : hs.full
        return max(hs.up, min(hs.full, base + drag))
    }

    private func handle(_ hs: EventScreenBody.Heights) -> some View {
        Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(width: page.width, height: ProposalScreenBody.handleH)
            .background(PDSurface.color)
            .overlay(alignment: .bottom) { Divider() }
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { v in drag = v.translation.height }
                .onEnded { v in
                    let base: CGFloat = level == .full ? hs.full : level == .half ? hs.half : hs.up
                    let end = base + v.predictedEndTranslation.height
                    let next: EventLevel = end < (hs.up + hs.half) / 2 ? .up : end < (hs.half + hs.full) / 2 ? .half : .full
                    withAnimation(.snappy(duration: 0.28)) { level = next; drag = 0 }
                })
            .onTapGesture { withAnimation(.snappy(duration: 0.28)) { level = level == .full ? .half : level == .half ? .full : .half } }
            .accessibilityElement()
            .accessibilityIdentifier("proposal-handle")
            .accessibilityLabel(level == .full ? "Show less" : "Show the whole proposal")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation { level = level == .full ? .half : .full } }
            .accessibilityAction(named: "Show the chat") { withAnimation { level = .up } }
    }

    // ---- the header ----------------------------------------------------------------------------

    @ViewBuilder private func header(h: CGFloat, hs: EventScreenBody.Heights) -> some View {
        if folded {
            foldedBar.frame(width: page.width, height: hs.up)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        halfPart
                            .id("proposal-top")
                            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { v in
                                if abs(v - halfContentH) >= 1 { halfContentH = v }
                            }
                        fullPart
                    }
                    .background(PDSurface.color)
                }
                .scrollDisabled(level != .full)
                .scrollBounceBehavior(.basedOnSize)
                .noTopEdgeEffect()
                .onChange(of: level) { _, l in if l != .full { withAnimation(.snappy) { proxy.scrollTo("proposal-top", anchor: .top) } } }
            }
            .background(PDSurface.color)
            .frame(width: page.width, height: h, alignment: .top)
            .clipped()
        }
    }

    private var halfPart: some View {
        let d = model.derive
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusPill(status: p.status)
                Text("Proposal by \(model.name(p.author)) · version \(p.version)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(p.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            let start = p.summary.isEmpty ? p.text : p.summary
            if !start.isEmpty {
                Text(MarkdownText.plainLinks(start)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            if !p.text.isEmpty || !p.summary.isEmpty {
                Button { withAnimation(.snappy(duration: 0.28)) { level = .full } } label: {
                    Text("Read the full proposal").font(.subheadline.weight(.semibold)).underline()
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("proposal-read")
            }
            if p.votingNow { voteButtons(d) }
            turnoutLine(d)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(width: max(0, page.width), alignment: .leading)
    }

    private func voteButtons(_ d: Derive) -> some View {
        let mine = d.myVote(p)
        let tally = p.tally
        return HStack(spacing: 8) {
            ForEach(p.options, id: \.id) { o in
                let on = mine == o.id
                BusyButton { model.vote(p, o.id) } label: {
                    VStack(spacing: 1) {
                        Text(o.label).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text("\(tally[o.id] ?? 0)").font(.caption).foregroundStyle(on ? Theme.onAccent.opacity(0.85) : .secondary)
                    }
                    .foregroundStyle(on ? Theme.onAccent : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(on ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Color.clear : Color(uiColor: .separator), lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(o.label), \(tally[o.id] ?? 0) votes")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("vote-" + o.id)
            }
        }
    }

    /// While votes are open: "You haven't voted yet · 15 of 31 members have" (only real numbers;
    /// no deadline). After: "Vote on version N: 12 yes · 2 no · 1 abstain".
    @ViewBuilder private func turnoutLine(_ d: Derive) -> some View {
        if let poll = p.poll {
            Text(turnoutText(d, poll)).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("proposal-turnout")
        }
    }

    private func turnoutText(_ d: Derive, _ poll: Poll) -> String {
        guard p.votingNow else { return "Vote on version \(poll.version): " + tallyText }
        let t = d.voteTurnout(p)
        let mine = d.myVote(p).flatMap { v in p.options.first { $0.id == v }?.label }
        let me = mine.map { "You voted " + $0.lowercased() } ?? "You haven't voted yet"
        return me + " · \(t.voted) of \(t.of) " + (t.of == 1 ? "member has" : "members have")
    }

    private var tabsShown: [ProposalTab] {
        let d = model.derive
        var out: [ProposalTab] = [.chat]
        if d.proposalVersions(p).count > 1 { out.append(.versions) }
        if p.poll != nil && !(p.poll?.votes.isEmpty ?? true) { out.append(.votes) }
        return out
    }

    private var fullPart: some View {
        let d = model.derive
        return VStack(alignment: .leading, spacing: 14) {
            Divider()
            if !p.summary.isEmpty { Text(p.summary).font(.subheadline.weight(.semibold)) }
            if !p.text.isEmpty { MarkdownText(text: p.text).font(.subheadline) }
            if let w = p.website, let link = websitePreviewLink(w, domain: model.config.domain), let u = URL(string: link) {
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: u) { Label("Preview this version", systemImage: "safari") }
                    Text(p.status == .passed ? "Passed: it is (or is about to be) live at \(model.config.domain)."
                         : "A new version of \(model.config.domain): it goes live once a belfry admin marks this proposal Passed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                if d.canDecide(p) {
                    Menu {
                        ForEach(ProposalStatus.allCases.filter { $0 != p.status }, id: \.self) { s in Button(s.label) { model.setStatus(p, s) } }
                    } label: { Label("Change the status", systemImage: "flag") }
                }
                if p.author == model.me { Button { revise = true } label: { Label("New version", systemImage: "doc.badge.plus") } }
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .frame(width: max(0, page.width), alignment: .leading)
    }

    private var tallyText: String {
        let t = p.tally
        return p.options.map { "\(t[$0.id] ?? 0) \($0.label.lowercased())" }.joined(separator: " · ")
    }

    /// Pulled up: the title, the pill and the tally on one bar, Vote (or my vote) on its right.
    private var foldedBar: some View {
        let d = model.derive
        let mine = d.myVote(p).flatMap { v in p.options.first { $0.id == v }?.label }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    StatusPill(status: p.status, small: true)
                    if p.poll != nil { Text(tallyText).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.28)) { level = .half } }
            if p.votingNow {
                // web: "Vote" (or "Voted yes") opens the proposal at half, where the buttons are
                Button { withAnimation(.snappy(duration: 0.28)) { level = .half } } label: {
                    Text(mine.map { "Voted " + $0.lowercased() } ?? "Vote")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).frame(height: 40)
                        .foregroundStyle(mine == nil ? Theme.onAccent : Color.primary)
                        .background(mine == nil ? Theme.accent : Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("proposal-vote")
            }
        }
        .padding(.horizontal, 16)
        .background(PDSurface.color)
        .accessibilityIdentifier("proposal-folded")
    }

    // ---- toolbar -------------------------------------------------------------------------------

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !pushed { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { search = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search")
            Menu {
                let d = model.derive
                let g = model.group(id)
                Button { place = .members } label: { Label("Members", systemImage: "person.2") }
                if !model.guestReading && !d.amGuest { Button { notify = true } label: { Label("Notifications", systemImage: "bell") } }
                if !model.guestReading { Button { place = .log } label: { Label("Log", systemImage: "clock.arrow.circlepath") } }
                if d.canAdmin(g) && !model.guestReading { Button { place = .settings } label: { Label("Settings", systemImage: "gearshape") } }
            } label: { Image(systemName: "ellipsis") }
            .accessibilityLabel("More")
            .accessibilityIdentifier("proposal-more")
        }
    }

    private func applyLaunch() {
        guard !launched else { return }
        launched = true
        switch model.launch.screen {
        case "proposalup": DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { level = .up } }
        case "proposalfull": DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { level = .full } }
        default: break
        }
    }
}

/// A proposal's state as a pill: green while votes or feedback are open and once passed, red when
/// rejected, grey otherwise.
struct StatusPill: View {
    let status: ProposalStatus
    var small = false
    var body: some View {
        Text(status.label)
            .font((small ? Font.caption2 : .caption).weight(.semibold))
            .padding(.horizontal, small ? 7 : 10)
            .frame(height: small ? 20 : 26)
            .foregroundStyle(fg)
            .background(bg, in: Capsule())
            .lineLimit(1)
    }
    private var bg: Color {
        switch status {
        case .voting, .passed: return Color(uiColor: .systemGreen)
        case .feedback: return Color(uiColor: .systemBlue)
        case .rejected: return Color(uiColor: .systemRed)
        case .draft, .closed: return Color(uiColor: .systemGray4)
        }
    }
    private var fg: Color {
        switch status {
        case .voting, .passed: return .black
        case .feedback, .rejected: return .white
        case .draft, .closed: return .primary
        }
    }
}

/// A proposal's versions, newest first: when, the note, "Read it" (the current one: the header at
/// full; an older one unfolds its text when this phone still holds it).
struct ProposalVersionsList: View {
    @EnvironmentObject var model: AppModel
    let p: Proposal
    let readCurrent: () -> Void
    @State private var open: Int?
    var body: some View {
        List {
            ForEach(model.derive.proposalVersions(p)) { v in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Version \(v.version)").font(.body.weight(.semibold))
                        Spacer()
                        Text((v.at > 0 ? Format.day(v.at) : "") + (v.version == p.version ? " · current" : "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !v.note.isEmpty { Text(v.note).font(.subheadline) }
                    if v.version == p.version {
                        Button("Read it", action: readCurrent).font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                    } else if let text = v.text {
                        if open == v.version { MarkdownText(text: text).font(.subheadline) }
                        else { Button("Read it") { open = v.version }.font(.subheadline.weight(.semibold)).buttonStyle(.borderless) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("proposal-versions")
    }
}

/// Who voted what on the current version (the latest answer of each person counts).
struct ProposalVotesList: View {
    @EnvironmentObject var model: AppModel
    let p: Proposal
    let open: (String) -> Void
    var body: some View {
        let by = model.derive.votesByOption(p)
        List {
            Section { Text("Vote on version \(p.poll?.version ?? p.version). The latest answer of each person counts.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(p.options, id: \.id) { o in
                let keys = (by[o.id] ?? []).sorted { model.name($0).lowercased() < model.name($1).lowercased() }
                Section("\(o.label) · \(keys.count)") {
                    ForEach(keys, id: \.self) { pk in
                        PersonRow(pubkey: pk, title: pk == model.me ? "You" : model.name(pk), detail: nil) { open(pk) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("proposal-votes")
    }
}
