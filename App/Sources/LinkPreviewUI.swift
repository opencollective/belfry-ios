import BelfryCore
import SwiftUI

// Link previews of outside pages (SPEC 19.69; collective-belfry docs/link-previews.md; canvas
// Channels, boards channels/og-*). The belfry is asked, never the page; pictures come from the
// belfry's own address only. One preview per message (its first outside link), in channels and
// open groups: none in private messages nor private groups. A grey box of the same size while
// it loads; nothing found: just the link.

@MainActor
final class LinkPreviewCenter: ObservableObject {
    @Published private(set) var states = [String: LinkPreviewState]()
    private var cache = LinkPreviewCache()
    private var cacheDomain: String?
    private var waiting = [String]()
    private var running = 0
    /// 429 / 503 / offline: nothing is asked again before this.
    private var pauseUntil = Date.distantPast
    weak var model: AppModel?

    private func file(_ domain: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("link-previews-\(domain).json")
    }

    private func load() {
        guard let m = model, cacheDomain != m.config.domain else { return }
        cacheDomain = m.config.domain
        states = [:]
        cache = file(m.config.domain).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(LinkPreviewCache.self, from: $0) } ?? LinkPreviewCache()
    }

    /// What is known now (nil: not asked yet).
    func state(_ link: String) -> LinkPreviewState? {
        load()
        return states[link] ?? cache.state(link)
    }

    /// The message is on screen: ask once, a few at a time.
    func ask(_ link: String) {
        load()
        guard let m = model, states[link] == nil, cache.state(link) == nil, !waiting.contains(link) else { return }
        if m.isDemo {
            states[link] = LinkPreviews.host(link) == "toolshare.example"
                ? .found(LinkPreview(url: link, title: "How a street tool library lends 400 drills a year",
                                     about: "Neighbours in a small street started lending their tools from a garage. Two years later they share drills, ladders and saws with half the town, and nobody keeps a list.",
                                     site: "ToolShare Journal"))
                : LinkPreviewState.none
            return
        }
        guard !m.guestReading || m.session?.guestChannel != nil else { return }
        states[link] = .loading
        waiting.append(link)
        pump()
    }

    private func pump() {
        guard let m = model, running < 2, !waiting.isEmpty else { return }
        let wait = pauseUntil.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.1) { [weak self] in self?.pump() }
            return
        }
        let link = waiting.removeFirst()
        running += 1
        let api = m.api
        let domain = m.config.domain
        Task {
            let a = await api.linkPreview(link)
            running -= 1
            guard cacheDomain == domain else { pump(); return }
            switch a {
            case .found(let p): states[link] = .found(p)
            case .none: states[link] = LinkPreviewState.none
            case .later:
                // asked again the next time its message comes on screen, not before a minute
                states[link] = nil
                pauseUntil = Date().addingTimeInterval(60)
            }
            cache.keep(link, a)
            if a != .later, let f = file(domain), let d = try? JSONEncoder().encode(cache) { try? d.write(to: f, options: .atomic) }
            pump()
        }
    }
}

/// Under a message's text: the preview of its first outside link (or the grey box, or nothing).
struct LinkPreviewSlot: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String

    var body: some View {
        if let link = model.previewLink(m, group: group) {
            LinkPreviewBox(link: link, center: model.linkPreviews)
        }
    }
}

struct LinkPreviewBox: View {
    let link: String
    @ObservedObject var center: LinkPreviewCenter
    @Environment(\.openURL) private var openURL

    var body: some View {
        SwiftUI.Group {
            switch center.state(link) {
            case .found(let p): Button { if let u = URL(string: link) { openURL(u) } } label: { LinkPreviewCard(link: link, p: p) }.buttonStyle(.plain)
            case .loading: LinkPreviewLoading()
            case .some(.none), nil: EmptyView()
            }
        }
        .onAppear { center.ask(link) }
    }
}

/// The page's picture (if any), the site and its address, the title, two lines of description.
struct LinkPreviewCard: View {
    let link: String
    let p: LinkPreview
    /// Above the composer: a small picture, one line each, no description.
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                if let img = p.image, let u = URL(string: img) {
                    CachedImage(url: u) { phase in
                        if let i = phase.image { i.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.title ?? p.about ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(p.siteLine(link: link)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let img = p.image, let u = URL(string: img) {
                    Color.secondary.opacity(0.12)
                        .frame(height: 150)
                        .overlay {
                            CachedImage(url: u) { phase in
                                if let i = phase.image { i.resizable().scaledToFill() } else { Color.clear }
                            }
                        }
                        .clipped()
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.siteLine(link: link)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let t = p.title { Text(t).font(.callout.weight(.semibold)).lineLimit(3).multilineTextAlignment(.leading) }
                    if let d = p.about { Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 300, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.secondary.opacity(0.25)))
            .padding(.top, 6)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("link-preview")
        }
    }
}

/// While the belfry is asked: a grey box, so little moves when the preview arrives.
struct LinkPreviewLoading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(width: 120, height: 12)
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(height: 12)
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(width: 200, height: 12)
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.secondary.opacity(0.25)))
        .padding(.top, 6)
        .accessibilityLabel("Loading the link's preview")
    }
}

/// Above the composer's field: the preview of the link being typed, with ✕ to send it without.
struct ComposerLinkPreview: View {
    let link: String
    @ObservedObject var center: LinkPreviewCenter
    let dismiss: () -> Void

    var body: some View {
        SwiftUI.Group {
            if case .found(let p) = center.state(link) {
                HStack(spacing: 8) {
                    LinkPreviewCard(link: link, p: p, compact: true)
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                            .frame(width: 32, height: 32).background(Color.secondary.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send the link without its preview")
                    .accessibilityIdentifier("composer-preview-off")
                }
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.25)))
            }
        }
        .task(id: link) {
            // asked once the link has stood for a moment, not at every key
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { center.ask(link) }
        }
    }
}

extension AppModel {
    /// Do messages of GROUP show link previews: a channel or an open group (never a private
    /// group: asking tells the belfry which link was sent).
    func previewsIn(_ group: String) -> Bool {
        guard !group.isEmpty, let g = self.group(group) else { return false }
        return !g.isPrivate
    }

    /// The outside link of M that gets a preview here (nil: none).
    func previewLink(_ m: Message, group: String) -> String? {
        guard m.special == .none, previewsIn(group) else { return nil }
        return LinkPreviews.link(of: m, domain: config.domain)
    }
}
