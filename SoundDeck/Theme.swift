import SwiftUI

/// Visual language for the deck.
///
/// The original palette was four flat colours applied directly at each call site.
/// Centralising it keeps tints, elevation and motion consistent, and means a restyle
/// touches one file rather than every view.
enum Theme {

    // MARK: Surfaces

    /// Deep charcoal with a small blue shift. It is warmer than pure black under the
    /// translucent materials layered on top of it.
    static let backdropTop = Color(red: 0.055, green: 0.063, blue: 0.086)
    static let backdropBottom = Color(red: 0.027, green: 0.031, blue: 0.047)

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
    static let surface = Color(red: 0.094, green: 0.106, blue: 0.137)
    static let surfaceRaised = Color(red: 0.118, green: 0.133, blue: 0.169)
    static let surfaceHover = Color(red: 0.149, green: 0.169, blue: 0.212)
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.16)

    // MARK: Text

    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.58)
    /// White at 0.50 gives 4.7:1 to 5.3:1 on all surfaces. This passes WCAG AA for small text.
    static let textTertiary = Color.white.opacity(0.50)

    // MARK: Accent

    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let accentBright = Color(red: 0.60, green: 0.71, blue: 1.0)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.45, green: 0.47, blue: 1.0), Color(red: 0.66, green: 0.40, blue: 0.98)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

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
        case .amber:  return Color(red: 1.00, green: 0.72, blue: 0.30)
        case .rose:   return Color(red: 1.00, green: 0.44, blue: 0.55)
        case .violet: return Color(red: 0.72, green: 0.48, blue: 1.00)
        case .teal:   return Color(red: 0.30, green: 0.83, blue: 0.80)
        case .lime:   return Color(red: 0.62, green: 0.89, blue: 0.42)
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
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
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
