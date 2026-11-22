import BelfryCore
import SwiftUI

// One shape (canvas one-shape/anatomy, 2026-11-22): every header is two lines at most, the title
// then one row of one-colour icons with counts (each left out at zero). The lead item is in the
// accent colour (open e-mails, an event's date, "From <sender>"); people come next; no avatars,
// no message count. Nothing clips: when the row is too narrow, items leave in HeaderRow.dropOrder
// (owner, files, to-dos, photos, comments, pinned); the lead and people stay. Every item has a
// spoken label.

struct HeaderItem: Identifiable, Hashable {
    /// lead, people, owner, pinned, todos, files, photos, comments, events, state, done…
    let key: String
    let icon: String?
    let text: String
    let label: String
    var accent = false
    /// A chip (the e-mail state): text on a tinted capsule.
    var chip = false
    var tint: Color? = nil
    var id: String { key }

    static func count(_ key: String, _ icon: String, _ n: Int, _ one: String, _ many: String) -> HeaderItem? {
        n > 0 ? HeaderItem(key: key, icon: icon, text: "\(n)", label: "\(n) \(n == 1 ? one : many)") : nil
    }
}

/// The header's second line. What fits is worked out from estimated widths (HeaderRow.fit):
/// no ViewThatFits in a navigation bar, whose children it measures again and again while the bar
/// and the keyboard move (testKeyboardComposer hung with it, 2026-11-22).
struct IconRow: View {
    let items: [HeaderItem]
    var font: Font = .caption
    /// The width the row may take; nil = a header's (the screen minus the bar's side buttons).
    var budget: CGFloat? = nil

    var body: some View {
        line(fitted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(items.map(\.label).joined(separator: ", "))
    }

    /// Points per character of the row's small type, plus the icon and the chip's padding.
    static func width(_ it: HeaderItem) -> Double {
        Double(it.text.count) * 6.6 + (it.icon == nil ? 0 : 15) + (it.chip ? 12 : 0)
    }

    private var fitted: [HeaderItem] {
        let room = Double(budget ?? (UIScreen.main.bounds.width - 150))
        let keep = Set(HeaderRow.fit(items.map { (key: $0.key, width: IconRow.width($0)) }, budget: room, gap: 8))
        return items.filter { keep.contains($0.key) }
    }

    private func line(_ list: [HeaderItem]) -> some View {
        HStack(spacing: 8) {
            ForEach(list) { it in cell(it) }
        }
        .font(font).monospacedDigit().lineLimit(1).fixedSize()
    }

    @ViewBuilder private func cell(_ it: HeaderItem) -> some View {
        if it.chip {
            Text(it.text).font(font.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background((it.tint ?? .secondary).opacity(0.15), in: Capsule())
                .foregroundStyle(it.tint ?? .secondary)
        } else {
            HStack(spacing: 3) {
                if let icon = it.icon { Image(systemName: icon).imageScale(.small) }
                if !it.text.isEmpty { Text(it.text) }
            }
            .foregroundStyle(it.tint ?? (it.accent ? Color.brand : Color.secondary))
            .fontWeight(it.accent ? .semibold : .regular)
        }
    }
}

/// The two-line header in a navigation bar's principal slot: the title (one line), then the row.
/// Tapping it opens the expanded level (pull-down).
struct OneHeader: View {
    let title: String
    let items: [HeaderItem]
    var glyph: AnyView? = nil
    var chevron: Bool = true
    var open: Bool = false
    var tap: () -> Void = {}

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if let glyph { glyph }
                    Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    if chevron {
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                if !items.isEmpty { IconRow(items: items, font: .caption2) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows more")
    }
}
