import SwiftUI

/// One pad in the deck.
struct SoundTile: View {
    let sound: SoundItem
    let isPlaying: Bool
    let isLastPlayed: Bool
    let play: () -> Void
    let stop: () -> Void
    let remove: () -> Void
    let update: ((inout SoundItem) -> Void) -> Void
    let openInspector: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    private var tint: Color { sound.tint.color }

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer(minLength: 0)
                footer
            }
            .padding(10)
            .frame(height: Theme.tileHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(border)
            .overlay(alignment: .top) { playingEdge }
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .shadow(color: isPlaying ? tint.opacity(0.34) : .black.opacity(0.22),
                    radius: isPlaying ? 12 : 6, y: 3)
            .scaleEffect(pressed ? 0.96 : (hovering ? 1.018 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Momentary press feedback; the button's own action still fires the sound.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false }
        )
        .animation(Theme.press, value: pressed)
        .animation(Theme.hover, value: hovering)
        .animation(Theme.hover, value: isPlaying)
        .help(sound.name)
        .contextMenu { menu }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 7) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(isPlaying ? 0.30 : 0.16))
                .frame(width: 24, height: 24)
            if let emoji = sound.emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 12))
            } else if isPlaying {
                PlayingBars(color: tint)
            } else {
                Text(sound.initials)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let key = sound.hotKey { KeyCap(key: key) }
            if sound.loops {
                Image(systemName: "repeat")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            if sound.trimEnd != nil || sound.trimStart > 0 {
                Image(systemName: "scissors")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if isPlaying {
                Button(action: stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else if hovering {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .transition(.opacity)
            }
        }
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surfaceRaised)
            if isPlaying {
                // Tint bloom from the top-left while sounding.
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(0.28), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 110
                        )
                    )
            }
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .strokeBorder(
                isPlaying ? tint.opacity(0.55) : (isLastPlayed ? Theme.strokeStrong : Theme.stroke),
                lineWidth: isPlaying ? 1.4 : 1
            )
    }

    @ViewBuilder
    private var playingEdge: some View {
        if isPlaying {
            Capsule()
                .fill(tint)
                .frame(width: 20, height: 2.5)
                .padding(.top, 4)
                .shadow(color: tint.opacity(0.8), radius: 5)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var menu: some View {
        Button("Play") { play() }
        if isPlaying { Button("Stop") { stop() } }
        Divider()
        Button("Edit…") { openInspector() }

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

        Menu("Icon") {
            Button("None") { update { $0.emoji = nil } }
            ForEach(["🔔", "💥", "🎺", "🥁", "⚡️", "🎉", "😂", "👏", "🚨", "💧", "🐸", "🎸"], id: \.self) { emoji in
                Button(emoji) { update { $0.emoji = emoji } }
            }
        }

        Menu("Hotkey") {
            Button("None") { update { $0.hotKey = nil } }
            ForEach((1...9).map(String.init) + ["0"], id: \.self) { key in
                Button(key) { update { $0.hotKey = key } }
            }
        }

        Toggle("Loop", isOn: Binding(
            get: { sound.loops },
            set: { newValue in update { $0.loops = newValue } }
        ))

        Divider()
        Button("Remove", role: .destructive) { remove() }
    }
}
