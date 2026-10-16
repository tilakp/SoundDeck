import SwiftUI

/// Waveform with two draggable trim handles and a dimmed region outside them.
struct TrimTrack: View {
    let samples: [Float]?
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let tint: Color

    private static let track = "TrimTrack"

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = position(start, in: width)
            let endX = position(end, in: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface)

                Group {
                    if let samples {
                        WaveformView(samples: samples, progress: 0, tint: Theme.textTertiary)
                    } else {
                        WaveformPlaceholder()
                    }
                }
                .padding(.horizontal, Theme.Spacing.s)

                // Dim everything outside the selection.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, startX))
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)

                Rectangle()
                    .fill(tint.opacity(0.10))
                    .frame(width: max(0, endX - startX))
                    .offset(x: startX)

                handle(at: startX, tint: tint) { newX in
                    start = min(max(0, time(newX, in: width)), max(0, end - 0.05))
                }
                handle(at: endX, tint: tint) { newX in
                    end = max(min(duration, time(newX, in: width)), min(duration, start + 0.05))
                }
            }
            // The handles read their drag position in this space, not in their own frame.
            .coordinateSpace(name: Self.track)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
        }
    }

    private func handle(at x: CGFloat, tint: Color, move: @escaping (CGFloat) -> Void) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: 4)
            .overlay(
                Capsule()
                    .fill(tint)
                    .frame(width: 12)
                    .opacity(0.001) // widen the hit target without showing it
            )
            .shadow(color: tint.opacity(0.7), radius: 4)
            .offset(x: x - 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.track))
                    .onChanged { value in move(value.location.x) }
            )
    }

    private func position(_ time: Double, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func time(_ x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(x / width) * duration
    }
}
