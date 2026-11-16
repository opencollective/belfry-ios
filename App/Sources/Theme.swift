import BelfryCore
import SwiftUI
import UIKit

// The Belfry look, as the web chat's: neutral (near-black on white, near-white on black) unless
// the belfry set branding colours (belfry.json `branding`, web src/core/branding.ts); then its
// primary colour is the tint, with white or near-black text on it, whichever reads better.
// AppModel sets `Theme.branding` when the config changes and bumps `brandKey` to redraw.

enum Theme {
    static var branding: Branding? {
        didSet { cache = nil }
    }
    private static var cache: (Color, Color)?

    private static let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1) : UIColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1) }
    private static let paper = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1) : .white }

    /// The tint: the belfry's primary colour, else ink.
    static var accent: Color { colors.0 }
    /// Text and icons on the tint.
    static var onAccent: Color { colors.1 }
    /// Switches: the primary colour, else the system green (ink would hide the knob in dark mode).
    static var toggle: Color {
        if let p = branding?.primary, let (r, g, b) = Branding.rgb(p) { return Color(red: r, green: g, blue: b) }
        return .green
    }

    private static var colors: (Color, Color) {
        if let c = cache { return c }
        var c = (Color(uiColor: ink), Color(uiColor: paper))
        if let p = branding?.primary, let (r, g, b) = Branding.rgb(p) {
            let dark = Branding.darkText(on: p)
            c = (Color(red: r, green: g, blue: b), dark ? Color(red: 0.035, green: 0.035, blue: 0.043) : .white)
        }
        cache = c
        return c
    }
}

extension Color {
    /// The app's tint (see Theme).
    static var brand: Color { Theme.accent }
}

/// Wires a feed's FeedPosition to its scroll view. iOS 18+: a ScrollPosition scrolled by edge.
/// ScrollViewProxy.scrollTo with the id of the lazy feed's last row had to resolve that row
/// through estimated heights while the keyboard and the event's header resized the feed, and could
/// keep the main thread busy for good (the event-chat freeze of 2026-11-16).
struct FeedScroll: ViewModifier {
    let pos: FeedPosition
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.modifier(FeedScroll18(pos: pos))
        } else {
            content.onAppear {
                pos.scrollToEnd = { animated in
                    if animated { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } else { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

@available(iOS 18, *)
private struct FeedScroll18: ViewModifier {
    let pos: FeedPosition
    @State private var position = ScrollPosition(edge: .bottom)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onAppear {
                let binding = $position
                pos.scrollToEnd = { animated in
                    if animated { withAnimation { binding.wrappedValue.scrollTo(edge: .bottom) } } else { binding.wrappedValue.scrollTo(edge: .bottom) }
                }
            }
    }
}

extension View {
    func feedScroll(_ pos: FeedPosition, _ proxy: ScrollViewProxy) -> some View { modifier(FeedScroll(pos: pos, proxy: proxy)) }
}

/// A feed's position as layout callbacks see it: a plain reference, so writing it never redraws.
@MainActor final class FeedPosition {
    var atBottom = true
    private var pending: Task<Void, Never>?
    /// Scrolls the feed to its end (set by `feedScroll`): iOS 18's ScrollPosition by edge, which
    /// never has to find a row; ScrollViewProxy.scrollTo("bottom") before iOS 18.
    var scrollToEnd: (_ animated: Bool) -> Void = { _ in }

    func toEnd(animated: Bool = false) {
        LoopWatch.mark("toEnd begin animated=\(animated)")
        scrollToEnd(animated)
        LoopWatch.mark("toEnd end")
    }

    /// Runs ACTION once the calls stop for 250 ms (one scroll after a height change settles).
    func settle(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { action() }
        }
    }
}

/// The filled button in the belfry's colour (borderedProminent's shape, with text that reads on
/// a neutral or branded tint in light and dark mode).
struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        let small = size == .small || size == .mini
        configuration.label
            .font(small ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .padding(.horizontal, small ? 12 : 18)
            .padding(.vertical, small ? 6 : size == .large ? 14 : 10)
            .foregroundStyle(enabled ? Theme.onAccent : Color.secondary)
            .background(enabled ? Theme.accent : Color.secondary.opacity(0.18), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle() }
}

/// Hides the keyboard (before a sheet opens, so it never stands over it).
@MainActor func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// A sheet that can stop half way: opaque, as before iOS 26 (a half-height sheet of glass lets
    /// the feed show through its rows and reads badly).
    func solidSheet() -> some View {
        presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    /// A bar over the feed (the event's bar, Join, the one-type-of-post bar…): a glass card on
    /// iOS 26, the bar material across before.
    @ViewBuilder func floatingBar() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            self.background(.bar)
        }
        #else
        self.background(.bar)
        #endif
    }

    /// The iOS 26 glass behind a control (a circle, a capsule…), material before iOS 26.
    @ViewBuilder func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape).overlay(shape.stroke(Color.primary.opacity(0.08)))
        }
        #else
        self.background(.regularMaterial, in: shape).overlay(shape.stroke(Color.primary.opacity(0.08)))
        #endif
    }

    /// The bar under the navigation bar (the channel's line, the event bar): a plain safe-area
    /// inset. (iOS 26's safeAreaBar made scrolling to the last message stop short of it, the last
    /// row behind the composer.)
    func topBar<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        safeAreaInset(edge: .top, spacing: 0, content: content)
    }

    /// The composer's place: a plain safe-area inset (scrolling to the last message keeps it above
    /// the composer; with iOS 26's safeAreaBar the last row ended up behind it).
    /// HEIGHT: told the bar's height. The feed must NOT pad its end by it: scrollTo(.bottom) and
    /// defaultScrollAnchor(.bottom) already stop above a safe-area inset (the pad showed as an
    /// empty band above the composer at the end of a channel, 2026-11-15).
    /// 2026-11-15: the composer sits UNDER the feed (a VStack), not over it as a safe-area
    /// inset: defaultScrollAnchor(.bottom) put the last rows behind and below an inset composer,
    /// and padding the feed by the composer's height left an empty band after scrollTo. Under it,
    /// the feed's end is the composer's top, whatever scrolls there.
    /// No geometry reading on the composer: each one made the layout measure the composer's text
    /// view again (part of the event-chat freeze, 2026-11-16).
    func bottomBar<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 0) {
            self.frame(maxHeight: .infinity)
            content()
        }
    }

    /// A feed stays on its last rows when it gets shorter or taller (the keyboard, the event's
    /// header moving): iOS 18's size-change anchor; before, the caller scrolls on a height change.
    /// Whether a feed shows its end (iOS 18's scroll geometry; before: always told yes), kept in
    /// POS without touching view state.
    @ViewBuilder func trackAtBottom(_ pos: FeedPosition) -> some View {
        if #available(iOS 18, *) {
            self.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
            } action: { _, v in LoopWatch.tick("atBottom"); pos.atBottom = v }
        } else {
            self
        }
    }

    /// A feed opens at its end. iOS 18+: for the first frame only (the plain modifier also anchors
    /// size changes, which looped with lazy rows and the keyboard).
    @ViewBuilder func initialScrollAnchorBottom() -> some View {
        if #available(iOS 18, *) { self.defaultScrollAnchor(.bottom, for: .initialOffset) } else { self.defaultScrollAnchor(.bottom) }
    }
}
