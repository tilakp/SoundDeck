import AppKit
import SwiftUI

/// Visual language for the deck.
///
/// The original palette was four flat colours applied directly at each call site.
/// Centralising it keeps tints, elevation and motion consistent, and means a restyle
/// touches one file rather than every view.
///
/// Each colour token has a light value and a dark value. The token follows the
/// appearance of the view that draws it. Thus the deck follows the system appearance.
enum Theme {

    // MARK: Appearance

    /// Makes a colour that gives `light` in a light appearance and `dark` in a dark appearance.
    ///
    /// The provider runs again when the appearance changes. Thus no asset catalog entry is necessary.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: adaptive(light: light, dark: dark))
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Ink for the light appearance: a near-black with a small blue shift.
    private static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: alpha)
    }

    private static func white(_ alpha: CGFloat) -> NSColor {
        NSColor(white: 1, alpha: alpha)
    }

    private static func black(_ alpha: CGFloat) -> NSColor {
        NSColor(white: 0, alpha: alpha)
    }

    // MARK: Surfaces

    /// Dark: deep charcoal with a small blue shift. Light: a soft off-white with the same shift.
    static let backdropTop: Color = adaptive(light: rgb(0.957, 0.961, 0.973), dark: rgb(0.055, 0.063, 0.086))
    static let backdropBottom: Color = adaptive(light: rgb(0.925, 0.933, 0.949), dark: rgb(0.027, 0.031, 0.047))

    static var backdrop: LinearGradient {
        LinearGradient(
            colors: [backdropTop, backdropBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Opaque surfaces rather than `.ultraThinMaterial`. On macOS a material samples
    /// whatever is behind the *window*, so over a bright desktop it washes a dark
    /// theme out to grey. Explicit fills keep the palette under our control.
    ///
    /// In the light appearance a raised surface is white, and the hover state is darker.
    static let surfaceColor: NSColor = adaptive(light: rgb(0.980, 0.982, 0.988), dark: rgb(0.094, 0.106, 0.137))
    static let surface = Color(nsColor: surfaceColor)
    static let surfaceRaised: Color = adaptive(light: rgb(1, 1, 1), dark: rgb(0.118, 0.133, 0.169))
    static let surfaceHover: Color = adaptive(light: rgb(0.937, 0.945, 0.961), dark: rgb(0.149, 0.169, 0.212))
    static let stroke: Color = adaptive(light: ink(0.09), dark: white(0.07))
    static let strokeStrong: Color = adaptive(light: ink(0.20), dark: white(0.16))

    /// The fill of a key cap and other small inset controls.
    static let fill: Color = adaptive(light: ink(0.05), dark: white(0.09))
    /// The border of a key cap.
    static let fillStroke: Color = adaptive(light: ink(0.14), dark: white(0.13))
    /// The fill of a small round button on a pad, for example Stop.
    static let fillStrong: Color = adaptive(light: ink(0.08), dark: white(0.14))
    /// Covers the part of a waveform that is outside the trim selection.
    static let dim: Color = adaptive(light: white(0.65), dark: black(0.55))
    /// The drop shadow of a pad at rest.
    static let shadow: Color = adaptive(light: black(0.08), dark: black(0.22))

    // MARK: Text

    static let textPrimary: Color = adaptive(light: ink(0.92), dark: white(0.95))
    static let textSecondary: Color = adaptive(light: ink(0.66), dark: white(0.58))
    /// Gives 4.6:1 or more on all surfaces in the two appearances. This passes WCAG AA for small text.
    static let textTertiary: Color = adaptive(light: ink(0.60), dark: white(0.50))

    // MARK: Accent

    /// The light values are deeper. They give 4.5:1 or more as text on the light surfaces,
    /// and under white text.
    static let accent: Color = adaptive(light: rgb(0.22, 0.36, 0.86), dark: rgb(0.42, 0.55, 1.0))
    static let accentBright: Color = adaptive(light: rgb(0.18, 0.32, 0.80), dark: rgb(0.60, 0.71, 1.0))

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentGradientStart, accentGradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static let accentGradientStart: Color = adaptive(light: rgb(0.30, 0.32, 0.88), dark: rgb(0.45, 0.47, 1.0))
    private static let accentGradientEnd: Color = adaptive(light: rgb(0.50, 0.25, 0.84), dark: rgb(0.66, 0.40, 0.98))

    // MARK: Status

    /// The Stop All control while sound plays, and playback errors. It is the same rose as `SoundTint.rose`.
    static let danger: Color = adaptive(light: rgb(0.80, 0.14, 0.32), dark: rgb(1.00, 0.44, 0.55))

    /// The pad tints. The light values are deeper, for contrast on white.
    fileprivate static let amber: Color = adaptive(light: rgb(0.60, 0.36, 0.0), dark: rgb(1.00, 0.72, 0.30))
    fileprivate static let violet: Color = adaptive(light: rgb(0.50, 0.26, 0.86), dark: rgb(0.72, 0.48, 1.00))
    fileprivate static let teal: Color = adaptive(light: rgb(0.0, 0.47, 0.46), dark: rgb(0.30, 0.83, 0.80))
    fileprivate static let lime: Color = adaptive(light: rgb(0.22, 0.46, 0.06), dark: rgb(0.62, 0.89, 0.42))

    // MARK: Motion

    static let press = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.62)
    static let hover = SwiftUI.Animation.easeOut(duration: 0.16)

    // MARK: Type

    /// The type scale. Use only these four sizes.
    ///
    /// Pad names and key caps use the rounded design. All other text uses the default design.
    enum Font {
        static let captionSize: CGFloat = 11
        static let bodySize: CGFloat = 13
        static let titleSize: CGFloat = 15
        static let numeralSize: CGFloat = 20

        /// Hints, badges, values and secondary labels.
        static func caption(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: captionSize, weight: weight)
        }

        /// Controls, fields and primary labels.
        static func body(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: bodySize, weight: weight)
        }

        /// Sheet titles, the window title and empty states.
        static func title(_ weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: titleSize, weight: weight)
        }

        /// Large monospaced numbers, for example the recording time.
        static func numeral(_ weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            .system(size: numeralSize, weight: weight, design: .monospaced)
        }

        /// The name of a pad.
        static let padName = SwiftUI.Font.system(size: bodySize, weight: .semibold, design: .rounded)

        /// The text in a `KeyCap`.
        static let keyCap = SwiftUI.Font.system(size: captionSize, weight: .semibold, design: .rounded)
    }

    // MARK: Corner radius

    enum Radius {
        /// Key caps and badges.
        static let small: CGFloat = 6
        /// Buttons, chips and fields.
        static let control: CGFloat = 8
        /// Tiles, panels and sheets.
        static let container: CGFloat = 12
    }

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: Geometry

    static let tileRadius: CGFloat = Radius.container
    static let tileMinWidth: CGFloat = 132
    static let tileHeight: CGFloat = 88
    static let tileSpacing: CGFloat = Spacing.s
}

extension SoundTint {
    /// Resolved colour for the tile badge and glow.
    var color: Color {
        switch self {
        case .none:   return Theme.accent
        case .amber:  return Theme.amber
        case .rose:   return Theme.danger
        case .violet: return Theme.violet
        case .teal:   return Theme.teal
        case .lime:   return Theme.lime
        }
    }
}

// MARK: - Reusable chrome

/// A translucent panel. Uses a real material so it picks up the desktop behind the
/// window rather than looking like a flat grey rectangle.
struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Radius.container
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

/// Small monospaced key cap used for hotkey hints.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key.uppercased())
            .font(Theme.Font.keyCap)
            .foregroundStyle(Theme.textSecondary)
            .frame(minWidth: 16)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.fillStroke, lineWidth: 1)
            )
    }
}

/// Toolbar button with a hover state and optional accent fill.
struct ChromeButton: View {
    let title: String
    let icon: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: icon)
                    .font(Theme.Font.body(.semibold))
                Text(title)
                    .font(Theme.Font.body(.semibold))
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.accentGradient)
                        .shadow(color: Theme.accent.opacity(hovering ? 0.5 : 0.3), radius: hovering ? 12 : 7, y: 3)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(hovering ? Theme.surfaceHover : Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        )
                }
            }
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
    }
}

/// Animated level bars shown on a tile while it is sounding.
struct PlayingBars: View {
    var color: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    // Offset each bar so they do not pulse in lockstep.
                    let wave = sin(t * 7 + Double(index) * 1.3)
                    let height = 4 + (wave + 1) / 2 * 9
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: height)
                }
            }
            .frame(height: 13, alignment: .bottom)
        }
    }
}
