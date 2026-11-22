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

/// The header's second line. Variants with fewer items are tried until one fits.
struct IconRow: View {
    let items: [HeaderItem]
    var font: Font = .caption

    var body: some View {
        let v = variants
        ViewThatFits(in: .horizontal) {
            line(v[0]); line(v[min(1, v.count - 1)]); line(v[min(2, v.count - 1)])
            line(v[min(3, v.count - 1)]); line(v[min(4, v.count - 1)]); line(v[min(5, v.count - 1)]); line(v[v.count - 1])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.map(\.label).joined(separator: ", "))
    }

    /// The full row, then one fewer item each step in the drop order.
    private var variants: [[HeaderItem]] {
        var out = [items]
        var cur = items
        for k in HeaderRow.dropOrder where cur.contains(where: { $0.key == k }) {
            cur.removeAll { $0.key == k }
            out.append(cur)
        }
        return out
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
