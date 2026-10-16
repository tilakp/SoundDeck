import SwiftUI

/// A compact grid of the pads of the active deck.
///
/// The menu bar deck uses this view. The view does not know its container, so a
/// floating panel can also use it.
struct MiniPadGrid: View {
    @ObservedObject var library: SoundLibrary
    @ObservedObject var engine: AudioEngine
    /// Shows the global hotkey modifiers in each key cap.
    var showsGlobalHint = false

    static let columnCount = 3
    static let padHeight: CGFloat = 58

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: Self.columnCount)
    }

    var body: some View {
        if library.sounds.isEmpty {
            Text("No sounds in this deck")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.l)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.s) {
                ForEach(library.sounds) { sound in
                    MiniPad(
                        sound: sound,
                        keyLabel: keyLabel(for: sound),
                        isPlaying: engine.playingIDs.contains(sound.id),
                        error: engine.padErrors[sound.id],
                        press: { engine.triggerReportingErrors(sound, in: library) },
                        release: { engine.release(sound) }
                    )
                }
            }
        }
    }

    private func keyLabel(for sound: SoundItem) -> String? {
        guard let key = sound.hotKey else { return nil }
        return showsGlobalHint ? "\(GlobalHotKeys.modifierDescription)\(key.uppercased())" : key
    }

    /// The VoiceOver label of a pad: the name, the key, and the state.
    static func accessibilityLabel(name: String, key: String?, isPlaying: Bool, hasError: Bool) -> String {
        var parts = [name]
        if let key { parts.append("key \(key.uppercased())") }
        if isPlaying { parts.append("playing") }
        if hasError { parts.append("failed") }
        return parts.joined(separator: ", ")
    }
}

/// One compact pad.
private struct MiniPad: View {
    let sound: SoundItem
    let keyLabel: String?
    let isPlaying: Bool
    let error: String?
    let press: () -> Void
    /// The mouse button came up. A Hold pad stops.
    let release: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    private var tint: Color { sound.tint.color }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
    }

    var body: some View {
        // A Hold pad plays on mouse down, in the gesture below. A button acts on mouse up.
        Button(action: { if sound.playMode != .hold { press() } }) {
            content
                .padding(.leading, Theme.Spacing.s + 2)
                .padding(.trailing, Theme.Spacing.xs + 2)
                .padding(.vertical, Theme.Spacing.xs + 2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: MiniPadGrid.padHeight)
                .background(background)
                .overlay(alignment: .leading) { tintEdge }
                .clipShape(shape)
                .overlay(border)
                .scaleEffect(pressed ? 0.95 : 1)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    if sound.playMode == .hold { press() }
                }
                .onEnded { _ in
                    pressed = false
                    if sound.playMode == .hold { release() }
                }
        )
        .animation(Theme.press, value: pressed)
        .animation(Theme.hover, value: hovering)
        .animation(Theme.hover, value: isPlaying)
        .help(error ?? sound.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MiniPadGrid.accessibilityLabel(
            name: sound.name, key: sound.hotKey, isPlaying: isPlaying, hasError: error != nil))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(error ?? "")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sound.name)
                // The caption size, so that two lines of a name fit a narrow pad.
                .font(.system(size: Theme.Font.captionSize, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let keyLabel {
                KeyCap(key: keyLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption(.bold))
                    .foregroundStyle(SoundTint.rose.color)
            } else if isPlaying {
                PlayingBars(color: tint)
                    .scaleEffect(0.75, anchor: .bottomTrailing)
            } else if let emoji = sound.emoji, !emoji.isEmpty {
                Text(emoji).font(Theme.Font.caption())
            }
        }
    }

    private var background: some View {
        ZStack {
            shape.fill(hovering ? Theme.surfaceHover : Theme.surfaceRaised)
            if isPlaying {
                shape.fill(tint.opacity(0.18))
            }
        }
    }

    private var tintEdge: some View {
        Rectangle()
            .fill(tint.opacity(isPlaying ? 1 : 0.55))
            .frame(width: 3)
            .shadow(color: isPlaying ? tint.opacity(0.8) : .clear, radius: 4)
    }

    private var border: some View {
        let color: Color
        if error != nil {
            color = SoundTint.rose.color.opacity(0.7)
        } else if isPlaying {
            color = tint.opacity(0.6)
        } else {
            color = Theme.stroke
        }
        return shape.strokeBorder(color, lineWidth: isPlaying || error != nil ? 1.4 : 1)
    }
}
