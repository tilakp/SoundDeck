import SwiftUI

/// Visual language for the deck.
///
/// The original palette was four flat colours applied directly at each call site.
/// Centralising it keeps tints, elevation and motion consistent, and means a restyle
/// touches one file rather than every view.
enum Theme {

    // MARK: Surfaces

    /// Deep, slightly blue-shifted charcoal — warmer than pure black under the
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
    static let textTertiary = Color.white.opacity(0.36)

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

    // MARK: Geometry

    static let tileRadius: CGFloat = 13
    static let tileMinWidth: CGFloat = 132
    static let tileHeight: CGFloat = 76
    static let tileSpacing: CGFloat = 9
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
    var cornerRadius: CGFloat = 14
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
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .frame(minWidth: 16)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
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
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentGradient)
                        .shadow(color: Theme.accent.opacity(hovering ? 0.5 : 0.3), radius: hovering ? 12 : 7, y: 3)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovering ? Theme.surfaceHover : Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
