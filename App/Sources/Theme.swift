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

struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
    func bottomBar<V: View>(height: Binding<CGFloat>? = nil, @ViewBuilder _ content: () -> V) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            content().background(GeometryReader { g in Color.clear.preference(key: BarHeightKey.self, value: g.size.height) })
        }
        .onPreferenceChange(BarHeightKey.self) { h in height?.wrappedValue = h }
    }
}
