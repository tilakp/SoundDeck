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
    /// The engine playhead. Only the waveform of a playing pad observes it.
    let playhead: Playhead
    /// The waveform and the length. Nil while the library reads the file.
    let preview: PadPreview?
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
            .overlay(flash)
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .overlay(border)
            .overlay(focusRing)
            .shadow(color: isPlaying ? tint.opacity(0.30) : Theme.shadow,
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
            PadIcon(sound: sound, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name)
                    .font(Theme.Font.padName)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let deckLabel {
                    Text(deckLabel)
                        .font(Theme.Font.caption(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let key = sound.hotKey { PadKeyCap(key: key) }
        }
    }

    /// The waveform, then the state at the right: the length, or Stop while the pad plays.
    private var footer: some View {
        HStack(spacing: Theme.Spacing.s) {
            Group {
                if isPlaying && !sound.loops {
                    PlayingPadWaveform(playhead: playhead, soundID: sound.id,
                                       envelope: preview?.envelope, tint: tint)
                } else {
                    PadWaveform(envelope: preview?.envelope, progress: isPlaying ? 1 : 0, tint: tint)
                }
            }
            .frame(height: 18)
            .accessibilityHidden(true)

            // A loop changes what a press does. The other modes do not show a glyph.
            if sound.loops {
                Image(systemName: "repeat")
                    .font(Theme.Font.caption(.bold))
                    .foregroundStyle(isPlaying ? tint : Theme.textSecondary)
                    .help("Loop")
            }
            if let errorMessage {
                Image(systemName: "exclamationmark")
                    .font(Theme.Font.caption(.heavy))
                    .foregroundStyle(Theme.onFill)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Self.errorColor))
                    .help(errorMessage)
            }
            if isPlaying {
                Button(action: stop) {
                    Image(systemName: "stop.fill")
                        .font(Theme.Font.caption(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.fillStrong))
                }
                .buttonStyle(.plain)
                .help("Stop")
                .transition(.scale.combined(with: .opacity))
            } else if let preview {
                Text(PadPreview.format(duration: preview.duration))
                    .font(Theme.Font.caption(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
        }
        .frame(minHeight: 20)
    }

    /// The pad colour washes the whole tile. It is stronger on hover and while the pad plays.
    private var background: some View {
        ZStack {
            Rectangle().fill(Theme.surfaceRaised)
            Rectangle().fill(tint.opacity(isPlaying ? Theme.tileWashActive : hovering ? Theme.tileWashHover : Theme.tileWash))
        }
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
        if isPlaying { return tint.opacity(0.85) }
        return tint.opacity(isLastPlayed ? 0.55 : 0.28)
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

    /// A key for the pad. The library removes the key from the pad that had it.
    private func hotKeyButton(_ key: String) -> some View {
        Button {
            update { $0.hotKey = key }
        } label: {
            if sound.hotKey?.lowercased() == key {
                Label(key.uppercased(), systemImage: "checkmark")
            } else {
                Text(key.uppercased())
            }
        }
    }

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
            Button("None") { update { $0.symbol = nil; $0.emoji = nil } }
            Divider()
            ForEach(PadSymbols.choices, id: \.symbol) { choice in
                Button {
                    update { $0.symbol = choice.symbol; $0.emoji = nil }
                } label: {
                    Label(choice.label, systemImage: choice.symbol)
                }
            }
        }
        .disabled(isLocked)

        Menu("Hotkey") {
            Button("None") { update { $0.hotKey = nil } }
            Divider()
            ForEach((1...9).map(String.init) + ["0"], id: \.self) { key in hotKeyButton(key) }
            // The letters are in a submenu, so the menu stays short.
            Menu("Letters") {
                ForEach("abcdefghijklmnopqrstuvwxyz".map(String.init), id: \.self) { key in hotKeyButton(key) }
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

/// The waveform of a playing pad. It fills with the pad colour as the pad plays.
/// This is the only part of a tile that observes the playhead. Thus only this view draws again at each tick.
private struct PlayingPadWaveform: View {
    @ObservedObject var playhead: Playhead
    let soundID: UUID
    let envelope: [Float]?
    let tint: Color

    var body: some View {
        PadWaveform(envelope: envelope, progress: playhead.padProgress[soundID] ?? 0, tint: tint)
    }
}

/// A short bar waveform. The bars before `progress` have the pad colour.
/// Before the preview loads, a quiet line holds the place, so the tile does not jump.
struct PadWaveform: View {
    let envelope: [Float]?
    var progress: Double = 0
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            if let envelope, !envelope.isEmpty {
                let gap: CGFloat = 1.5
                let width = max(1, (geometry.size.width - gap * CGFloat(envelope.count - 1)) / CGFloat(envelope.count))
                let played = Int((Double(envelope.count) * progress.clamped(to: 0...1)).rounded(.up))
                HStack(alignment: .center, spacing: gap) {
                    ForEach(envelope.indices, id: \.self) { index in
                        Capsule()
                            .fill(index < played ? tint : tint.opacity(0.38))
                            .frame(width: width, height: max(2, CGFloat(envelope[index]) * geometry.size.height))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Capsule()
                    .fill(tint.opacity(0.25))
                    .frame(height: 2)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// The icon of a pad: an SF Symbol, or an emoji from an earlier version.
struct PadIcon: View {
    let sound: SoundItem
    let tint: Color

    var body: some View {
        if let symbol = sound.symbol {
            // A wide symbol, for example the bicycle, fits in the same box as a narrow one.
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .frame(width: Theme.Font.bodySize + 2, height: Theme.Font.bodySize + 2)
                .padding(.top, 1)
                .accessibilityHidden(true)
        } else if let emoji = sound.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(Theme.Font.body())
                .accessibilityHidden(true)
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
                    .fill(Theme.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.fillStroke, lineWidth: 1)
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
