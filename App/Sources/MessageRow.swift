import BelfryCore
import SwiftUI

// One message in the feed, and what hangs off it: cards (pod, proposal, event, e-mail), the
// "edited" mark, topic chips, the to-do mark, reactions, the thread chip + "Open thread", outbox
// states; the inline thread, resurfaced threads and join lines.

struct MessageRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let m: Message
    let group: String
    let first: Bool
    let reactions: [Reaction]
    let thread: ThreadInfo?
    let threadOpen: Bool
    let announce: Bool
    var todo: TodoTask?
    var pinned = false
    var openTopic: String?
    var flash = false
    let onThread: () -> Void
    let onOpenThread: () -> Void
    let onReply: () -> Void
    let onHold: () -> Void
    var onTopic: (String) -> Void = { _ in }
    @Environment(\.messageMenu) private var menu
    @State private var tapped = 0

    var body: some View {
        let _ = LoopWatch.tick("MessageRow")
        let d = model.derive
        let pending = model.pending(m.id)
        HStack(alignment: .top, spacing: 10) {
            if first {
                Avatar(pubkey: m.ev.pubkey, size: 36).onTapGesture { model.openProfile = m.ev.pubkey }
            } else { Color.clear.frame(width: 36, height: 1) }
            VStack(alignment: .leading, spacing: 4) {
                if first {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(d.nameOver(m)).font(.subheadline.weight(.semibold)).lineLimit(1).onTapGesture { model.openProfile = m.ev.pubkey }
                        AgentTag(pubkey: m.ev.pubkey)
                        Text(Format.time(m.ev.createdAt)).font(.caption).foregroundStyle(.secondary)
                        if case .memberMail = m.special { Text("via e-mail").font(.caption2).foregroundStyle(.secondary) }
                        if announce { Label("Announcement", systemImage: "megaphone").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand) }
                        if pinned { Image(systemName: "pin").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                    }
                }
                if let created = m.created {
                    Text("Created \(created)").font(.caption).foregroundStyle(.secondary)
                }
                SpecialBody(m: m, group: group)
                MessageButtonsView(m: m, group: group)
                if !m.eventRefs.isEmpty {
                    ForEach(m.eventRefs, id: \.self) { r in EventCardView(ref: r) }
                }
                ForEach(m.media, id: \.url) { media in MediaView(media: media, all: m.media) }
                if let e = m.edited { Text("edited").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Edited \(Format.ago(e))") }
                let extra = d.extraTopics(m, openTopic: openTopic)
                if !extra.isEmpty {
                    FlowRow(spacing: 4) {
                        ForEach(extra, id: \.self) { t in
                            Button { onTopic(t) } label: { Chip(text: "#" + t, tint: .brand) }.buttonStyle(.plain)
                        }
                    }
                }
                if !reactions.isEmpty {
                    ReactionBar(reactions: reactions) { emoji in
                        if model.locked(group) { return } // archived: read only
                        model.toggleReaction(emoji, on: m, in: group); tapped += 1
                    }
                }
                if let thread, thread.count > 0 {
                    // replies always open the thread's own screen (web 9cbb1cb)
                    Button(action: onOpenThread) {
                        HStack(spacing: 6) {
                            HStack(spacing: -6) {
                                ForEach(thread.who.prefix(3), id: \.self) {
                                    Avatar(pubkey: $0, size: 20).overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                                }
                            }
                            Text("\(thread.count) \(thread.count == 1 ? "reply" : "replies")").font(.footnote.weight(.semibold)).foregroundStyle(Color.brand)
                            Text(Format.short(thread.last)).font(.footnote).foregroundStyle(.secondary)
                            let fresh = model.readSync == nil ? 0 : d.unreadInThread(group, m.id, model.readState, now: Int.now)
                            if fresh > 0 { Text("· \(fresh) new").font(.footnote.weight(.semibold)).foregroundStyle(.primary) }
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(thread.count) \(thread.count == 1 ? "reply" : "replies"). Open the thread")
                }
                if let p = pending {
                    if p.status == .failed {
                        HStack(spacing: 10) {
                            Label("Not sent", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                            BusyButton("Retry") { model.retry(p.localId) }.font(.caption.weight(.semibold))
                            BusyButton("Discard", role: .destructive) { model.discard(p.localId) }.font(.caption.weight(.semibold))
                        }.font(.caption)
                    } else {
                        Label(p.stateText, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, first ? 8 : 2)
        .padding(.bottom, 2)
        .opacity(pending == nil ? 1 : 0.65)
        .background(flash ? Color.flash : announce ? Color.brand.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: tapped)
        .accessibilityElement(children: .combine)
        .messageMenu(m, group: group, handlers: menu, guest: model.guestReading || model.locked(group), hold: onHold)
        .accessibilityIdentifier("message-row")
        .accessibilityHint("Touch and hold for actions")
    }
}

/// Next to an agent's name wherever it writes (web 683c974): "<member>'s agent" or "Agent".
struct AgentTag: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    var body: some View {
        let d = model.derive
        if let owner = d.agentOwner(pubkey) {
            Chip(text: owner == model.me ? "Your agent" : "\(model.realNameOrKey(owner))'s agent", icon: "sparkles")
        } else if d.isAgent(pubkey) {
            Chip(text: "Agent", icon: "sparkles")
        }
    }
}

/// What the text part of a message shows: plain text, or an e-mail / inbox / sent-as card.
struct SpecialBody: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let m: Message
    let group: String

    var body: some View {
        switch m.special {
        case .podCard(let pid):
            // open / archived (greyed, opens read only) / deleted (greyed, not a button), SPEC 19.30
            GroupCard(id: pid, text: m.text)
        case .proposalCard(let pid):
            let p = model.derive.proposalFor(pid)
            Button { openChannel(pid, nil) } label: {
                CardFrame {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Image(systemName: "doc.text"); Text(p?.title ?? model.group(pid)?.name ?? "A proposal").font(.subheadline.weight(.semibold)) }
                        if let p, !p.summary.isEmpty { Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if let p {
                            HStack(spacing: 6) {
                                Chip(text: p.status.label, tint: p.votingNow ? .brand : .secondary)
                                Text("version \(p.version)").font(.caption2).foregroundStyle(.secondary)
                                if p.votingNow { Text("\(p.tally["yes"] ?? 0) yes · \(p.tally["no"] ?? 0) no").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }.buttonStyle(.plain)
        case .eventCard(let coord):
            EventCardView(ref: EventRef(coord: coord))
        case .memberMail(let subject, _):
            VStack(alignment: .leading, spacing: 4) {
                if !subject.isEmpty { Text(subject).font(.subheadline.weight(.semibold)) }
                if !m.body.isEmpty { MarkdownText(text: m.body) }
            }
        case .inboxCard, .sentAsChannel:
            InboxCardView(m: m, group: group)
        case .none:
            if !m.text.isEmpty { MarkdownText(text: m.text) }
        }
    }
}

/// An e-mail from outside or what went out, where one shows outside its thread (a search
/// result, an old reply's root): as a message with its tag (SPEC 19.33, round 6).
struct InboxCardView: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String
    var body: some View {
        let d = model.derive
        if let it = d.mailIn(m) ?? d.mailOut(m) { MailEntryRow(it: it, alias: d.mailLocal(group)).padding(.horizontal, -16) }
    }
}

struct CardFrame<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25)))
    }
}

/// An event's card (Belfry event or older session): date chip, title, place, my state.
struct EventCardView: View {
    @EnvironmentObject var model: AppModel
    let ref: EventRef

    var body: some View {
        let d = model.derive
        let e = ref.coord.flatMap { d.calEvent($0) } ?? ref.link.flatMap { d.eventByLink($0) }
        Button { model.openEvent = e?.coord ?? ref.link } label: {
            CardFrame {
                if let e {
                    HStack(alignment: .top, spacing: 10) {
                        DateChip(at: e.start)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(e.allDay ? "All day" : d.lineWhen(e)).font(.caption).foregroundStyle(.secondary)
                            if let l = e.location, !l.isEmpty { Text(l).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            HStack(spacing: 6) {
                                if e.status == .cancelled { Chip(text: "Cancelled", tint: .red) }
                                if let s = d.stateLabel(e) { Chip(text: s, tint: .brand) }
                                if e.meeting {
                                    Text("Meeting · \(d.meetingCount(e)) people").font(.caption2).foregroundStyle(.secondary)
                                } else if e.going > 0 {
                                    Text("\(e.going) going").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Label("An event", systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct DateChip: View {
    let at: Int
    var body: some View {
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Color.brand)
            Text(date.formatted(.dateTime.day())).font(.title3.weight(.semibold))
        }
        .frame(width: 44, height: 44)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .accessibilityHidden(true)
    }
}

struct ReactionBar: View {
    @EnvironmentObject var model: AppModel
    let reactions: [Reaction]
    let toggle: (String) -> Void

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(reactions, id: \.emoji) { r in
                Button { toggle(r.emoji) } label: {
                    Text("\(r.emoji) \(r.who.count)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(r.mine != nil ? Color.brand.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(r.mine != nil ? Color.brand : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(r.emoji), \(r.who.count). \(r.who.map(model.name).joined(separator: ", "))")
                .accessibilityAddTraits(r.mine != nil ? .isSelected : [])
            }
        }
    }
}

struct MediaView: View {
    @EnvironmentObject var model: AppModel
    let media: Media
    /// The message's media: the lightbox swipes through its photos.
    var all: [Media] = []
    var body: some View {
        if media.mime.hasPrefix("image/"), let url = URL(string: media.url), url.scheme == "https" || url.scheme == "http" {
            // the size from imeta `dim` when known: no jump when the picture arrives
            let ratio: CGFloat? = (media.w ?? 0) > 0 && (media.h ?? 0) > 0 ? CGFloat(media.w!) / CGFloat(media.h!) : nil
            CachedImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Label(media.name ?? "Photo", systemImage: "photo").foregroundStyle(.secondary)
                default:
                    if ratio != nil { Color.secondary.opacity(0.12) } else { ProgressView().frame(height: 120) }
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: 280, maxHeight: 280, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                let photos = (all.isEmpty ? [media] : all).filter { $0.mime.hasPrefix("image/") }.map(\.url)
                hideKeyboard()
                model.lightbox = Lightbox(urls: photos, index: photos.firstIndex(of: media.url) ?? 0)
            }
            .accessibilityLabel(media.name ?? "Photo")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the photo")
        } else if media.mime.hasPrefix("audio/") {
            AudioRow(media: media)
        } else if media.mime.hasPrefix("image/") {
            Label(media.name ?? "Photo", systemImage: "photo").foregroundStyle(.secondary)
        } else if let url = URL(string: media.url), url.scheme == "https" {
            Link(destination: url) { Label(media.name ?? "File", systemImage: "paperclip") }.font(.callout)
        }
    }
}

/// The latest three replies under a message, "Show N earlier", a reply box and "Open thread".
struct InlineThread: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let root: Message
    let onOpen: () -> Void
    let onHold: (Message) -> Void
    let onHide: () -> Void
    @State private var all = false

    var body: some View {
        let (shown, hidden) = model.derive.inlineThread(group, root.id, showAll: all)
        VStack(alignment: .leading, spacing: 8) {
            if hidden > 0 {
                Button("Show \(hidden) earlier \(hidden == 1 ? "reply" : "replies")") { withAnimation { all = true } }
                    .font(.caption.weight(.semibold))
            }
            ForEach(shown) { r in ReplyRow(group: group, r: r, onHold: { onHold(r) }) }
            if !model.guestReading && !model.locked(group) {
                Composer(group: group, placeholder: shown.isEmpty ? "Reply (starts a thread)" : "Reply in the thread", compact: true) { text, _, _ in
                    model.reply(text, in: group, to: root)
                }
            }
            HStack(spacing: 16) {
                Button("Hide", action: onHide)
                Button(action: onOpen) { HStack(spacing: 2) { Text("Open thread"); Image(systemName: "chevron.right") } }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) { Rectangle().fill(Color.brand.opacity(0.5)).frame(width: 2).padding(.vertical, 8) }
        .padding(.leading, 56)
        .padding(.trailing)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread")
    }
}

struct ReplyRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.messageMenu) private var menu
    var group = ""
    let r: Message
    /// A message link led here.
    var flash = false
    let onHold: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(pubkey: r.ev.pubkey, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name(r.ev.pubkey)).font(.caption.weight(.semibold))
                    AgentTag(pubkey: r.ev.pubkey)
                    Text(Format.time(r.ev.createdAt)).font(.caption2).foregroundStyle(.secondary)
                    if r.edited != nil { Text("edited").font(.caption2).foregroundStyle(.secondary) }
                    if let p = model.pending(r.id) { Text(p.stateText).font(.caption2).foregroundStyle(p.status == .failed ? .red : .secondary) }
                }
                if !r.text.isEmpty { MarkdownText(text: r.text).font(.subheadline) }
                MessageButtonsView(m: r, group: group.isEmpty ? (r.ev.tag("h") ?? "") : group)
                ForEach(r.media, id: \.url) { MediaView(media: $0, all: r.media) }
                // reactions on a reply (Xavier 2026-11-18), as on a message
                let g = group.isEmpty ? (r.ev.tag("h") ?? "") : group
                let reactions = model.derive.reactions(g)[r.id] ?? []
                if !reactions.isEmpty {
                    ReactionBar(reactions: reactions) { emoji in model.toggleReaction(emoji, on: r, in: g) }.padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, flash ? 4 : 0)
        .background(flash ? Color.flash : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .messageMenu(r, group: group.isEmpty ? (r.ev.tag("h") ?? "") : group, handlers: menu, guest: model.guestReading || model.locked(r.ev.tag("h") ?? group), inset: 8, hold: onHold)
    }
}

/// A reply to an older message, where it lands in the feed (Discord's reply): one grey line with
/// the message it answers (small face, name, first words) hooked to the reply by an elbow, then
/// the reply as an ordinary message. A tap opens the thread.
struct ThreadActivity: View {
    @EnvironmentObject var model: AppModel
    let root: Message
    let last: Message
    let open: Bool
    let toggle: () -> Void
    private var hasLinks: Bool { !Links.inMarkdown(last.text).isEmpty }

    var body: some View {
        let d = model.derive
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ReplyElbow()
                    .stroke(Color(uiColor: .tertiaryLabel), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 24, height: 13)
                    .alignmentGuide(VerticalAlignment.center) { _ in 0 }
                    .padding(.leading, 18)
                Avatar(pubkey: root.ev.pubkey, size: 16)
                Text(model.name(root.ev.pubkey)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(1)
                Text(d.activitySnippet(root)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if root.text.isEmpty, !root.media.isEmpty { Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapIf(hasLinks, perform: toggle)
            HStack(alignment: .top, spacing: 10) {
                Avatar(pubkey: last.ev.pubkey, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.name(last.ev.pubkey)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        AgentTag(pubkey: last.ev.pubkey)
                        Text(Format.time(last.ev.createdAt)).font(.caption).foregroundStyle(.secondary)
                        if last.edited != nil { Text("edited").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if !last.text.isEmpty { MarkdownText(text: last.text).lineLimit(8) }
                    ForEach(last.media, id: \.url) { MediaView(media: $0, all: last.media) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        // a tap on the row opens the thread, except on a reply with links: a tap gesture over
        // the whole row took the taps on its links (Xavier, 2026-11-17: "urls always clickable"),
        // so there only the grey line and the names open it
        .onTapIf(!hasLinks, perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.name(last.ev.pubkey)) replied to \(model.name(root.ev.pubkey)): \(d.activityReply(last))")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the thread")
    }
}

/// The hook from a reply's face up to the line of the message it answers.
struct ReplyElbow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c: CGFloat = 6
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// "<name> joined as a guest, invited by <name>" (SPEC 13, 19.3, 19.16).
struct JoinLine: View {
    @EnvironmentObject var model: AppModel
    let join: GuestJoin
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right").foregroundStyle(Color.brand)
            Text(LocalizedStringKey(text)).font(.footnote)
            Spacer(minLength: 0)
            Text(Format.time(join.at)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    var text: String {
        let who = "**\(model.name(join.pubkey))**"
        if let owner = model.derive.agentOwner(join.pubkey) {
            return owner == model.me ? "\(who) joined as your agent" : "\(who) joined as **\(model.realNameOrKey(owner))**'s agent"
        }
        let what = join.agent ? "an agent" : "a guest"
        guard let by = join.by else { return "\(who) joined as \(what)" }
        return "\(who) joined as \(what), invited by **\(model.name(by))**" + (join.unsaved && !join.agent ? " · not saved" : "")
    }
}

extension View {
    /// A tap gesture only when ON (a tap gesture over text takes the taps on its links).
    @ViewBuilder func onTapIf(_ on: Bool, perform: @escaping () -> Void) -> some View {
        if on { self.onTapGesture(perform: perform) } else { self }
    }
}
