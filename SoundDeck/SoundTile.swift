import SwiftUI

/// One pad in the deck.
struct SoundTile: View {
    let sound: SoundItem
    let isPlaying: Bool
    let isLastPlayed: Bool
    /// The keyboard focus is on this pad.
    let isFocused: Bool
    /// The last playback error of this pad, or nil.
    let errorMessage: String?
    /// The engine playhead. Only the progress fill observes it.
    let playhead: Playhead
    let play: () -> Void
    /// The mouse button came up. A Hold pad stops.
    let release: () -> Void
    let stop: () -> Void
    let remove: () -> Void
    let update: ((inout SoundItem) -> Void) -> Void
    let openInspector: () -> Void
    /// The other decks. The context menu can move the pad to one of them.
    let moveTargets: [(id: UUID, name: String)]
    let moveToDeck: (UUID) -> Void
    /// The deck of the pad is locked. The menu disables the items that change the pad.
    var isLocked = false
    /// The name of the deck of the pad. The grid gives it when it shows pads from all decks.
    var deckLabel: String? = nil

    @State private var hovering = false
    @State private var pressed = false

    private var tint: Color { sound.tint.color }
    private static let errorColor = SoundTint.rose.color

    var body: some View {
        // A Hold pad plays on mouse down, in the gesture below. A button acts on mouse up.
        Button(action: { if sound.playMode != .hold { play() } }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                header
                Spacer(minLength: 0)
                footer
            }
            .padding(.leading, Theme.Spacing.xs)
            .padding(Theme.Spacing.s)
            .frame(height: Theme.tileHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) { colourEdge }
            .overlay(flash)
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .overlay(border)
            .overlay(focusRing)
            .shadow(color: isPlaying ? tint.opacity(0.30) : .black.opacity(0.22),
                    radius: isPlaying ? 10 : 6, y: 3)
            .scaleEffect(pressed ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        // Momentary press feedback; the button's own action still fires the sound.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    if sound.playMode == .hold { play() }
                }
                .onEnded { _ in
                    pressed = false
                    if sound.playMode == .hold { release() }
                }
        )
        .animation(Theme.press, value: pressed)
        .animation(Theme.hover, value: hovering)
        .animation(Theme.hover, value: isPlaying)
        .help(sound.name)
        .accessibilityLabel(sound.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(sound.hotKey.map { "Key \($0.uppercased())" } ?? "")
        .accessibilityAddTraits(.isButton)
        .contextMenu { menu }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isPlaying { parts.append("Playing") }
        if let errorMessage { parts.append("Error: \(errorMessage)") }
        return parts.joined(separator: ", ")
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            if let emoji = sound.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(Theme.Font.body())
                    .accessibilityHidden(true)
            }
            Text(sound.name)
                .font(Theme.Font.padName)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let key = sound.hotKey { PadKeyCap(key: key) }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let deckLabel {
                Text(deckLabel)
                    .font(Theme.Font.caption(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            // A loop changes what a press does. The other modes do not show a glyph.
            if sound.loops {
                Image(systemName: "repeat")
                    .font(Theme.Font.caption(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Loop")
            }
            if isPlaying {
                PlayingBars(color: tint)
                    .accessibilityHidden(true)
            }
            if let errorMessage {
                Text("!")
                    .font(Theme.Font.caption(.heavy))
                    .foregroundStyle(Theme.backdropBottom)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Self.errorColor))
                    .help(errorMessage)
            }
            Spacer(minLength: 0)
            if isPlaying {
                Button(action: stop) {
                    Image(systemName: "stop.fill")
                        .font(Theme.Font.caption(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(Theme.Spacing.xs)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Stop")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minHeight: 20)
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(hovering ? Theme.surfaceHover : Theme.surfaceRaised)
            if isPlaying {
                if sound.loops {
                    // A loop has no end. A steady fill shows that it plays.
                    Rectangle().fill(tint.opacity(0.16))
                } else {
                    PadProgressFill(playhead: playhead, soundID: sound.id, color: tint.opacity(0.22))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The pad colour as a quiet edge on the left.
    private var colourEdge: some View {
        Rectangle()
            .fill(tint.opacity(isPlaying ? 0.9 : 0.55))
            .frame(width: 3)
            .accessibilityHidden(true)
    }

    /// An instant tint flash on press. It fades in 120 ms after release.
    private var flash: some View {
        Rectangle()
            .fill(tint.opacity(pressed ? 0.35 : 0))
            .allowsHitTesting(false)
            .animation(pressed ? nil : .easeOut(duration: 0.12), value: pressed)
            .accessibilityHidden(true)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .strokeBorder(borderColor, lineWidth: errorMessage != nil || isPlaying ? 1.4 : 1)
            .accessibilityHidden(true)
    }

    private var borderColor: Color {
        if errorMessage != nil { return Self.errorColor }
        if isPlaying { return tint.opacity(0.55) }
        return isLastPlayed ? Theme.strokeStrong : Theme.stroke
    }

    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: Theme.tileRadius + 3, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .padding(-3)
                .accessibilityHidden(true)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var menu: some View {
        Button("Play") { play() }
        if isPlaying { Button("Stop") { stop() } }
        Divider()
        Toggle("Favorite", isOn: Binding(
            get: { sound.isFavorite },
            set: { newValue in update { $0.isFavorite = newValue } }
        ))
        Button("Edit…") { openInspector() }
            .disabled(isLocked)

        Menu("Colour") {
            ForEach(SoundTint.allCases) { option in
                Button {
                    update { $0.tint = option }
                } label: {
                    HStack {
                        Text(option.label)
                        if sound.tint == option { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .disabled(isLocked)

        Menu("Icon") {
            Button("None") { update { $0.emoji = nil } }
            ForEach(["🔔", "💥", "🎺", "🥁", "⚡️", "🎉", "😂", "👏", "🚨", "💧", "🐸", "🎸"], id: \.self) { emoji in
                Button(emoji) { update { $0.emoji = emoji } }
            }
        }
        .disabled(isLocked)

        Menu("Hotkey") {
            Button("None") { update { $0.hotKey = nil } }
            ForEach((1...9).map(String.init) + ["0"], id: \.self) { key in
                Button(key) { update { $0.hotKey = key } }
            }
        }
        .disabled(isLocked)

        Toggle("Loop", isOn: Binding(
            get: { sound.loops },
            set: { newValue in update { $0.loops = newValue } }
        ))
        .disabled(isLocked)

        if !moveTargets.isEmpty {
            Menu("Move to Deck") {
                ForEach(moveTargets, id: \.id) { target in
                    Button(target.name) { moveToDeck(target.id) }
                }
            }
            .disabled(isLocked)
        }

        Divider()
        Button("Remove", role: .destructive) { remove() }
            .disabled(isLocked)
    }
}

/// The progress of one pad, as a fill that sweeps from left to right.
/// This is the only part of a tile that observes the playhead. Thus only this view draws again at each tick.
private struct PadProgressFill: View {
    @ObservedObject var playhead: Playhead
    let soundID: UUID
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(color)
                .frame(width: geometry.size.width * (playhead.padProgress[soundID] ?? 0))
        }
    }
}

/// The hotkey of a pad as a large cap. Under stress the user reads the key first.
private struct PadKeyCap: View {
    let key: String

    var body: some View {
        Text(key.uppercased())
            .font(.system(size: Theme.Font.bodySize, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

/// The keyboard focus moves in the pad grid with the arrow keys.
enum PadGridNavigation {
    enum Direction { case left, right, up, down }

    /// Gives the index of the pad next to `index`, or nil when there is no pad in that direction.
    static func neighbour(of index: Int, count: Int, columns: Int, direction: Direction) -> Int? {
        guard count > 0, columns > 0, (0..<count).contains(index) else { return nil }
        let target: Int
        switch direction {
        case .left:  target = index - 1
        case .right: target = index + 1
        case .up:    target = index - columns
        case .down:  target = index + columns
        }
        return (0..<count).contains(target) ? target : nil
    }
}
