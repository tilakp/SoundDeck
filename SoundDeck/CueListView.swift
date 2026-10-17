import AVFoundation
import SwiftUI

/// The active deck as an ordered cue list. Go plays the standby cue and moves the standby down one row.
/// A click on a row sets the standby. A double-click plays the row.
struct CueListView: View {
    @ObservedObject var library: SoundLibrary
    @ObservedObject var engine: AudioEngine
    /// Plays the standby cue. The window owns it, because the Go key also uses it.
    let go: () -> Void

    @FocusState private var listFocused: Bool
    @State private var editingNoteID: UUID?
    @State private var noteText = ""

    private var sounds: [SoundItem] { library.activeDeck.sounds }
    private var standby: Int { CueList.clamp(library.activeDeck.cueIndex, count: sounds.count) }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            goBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.xs) {
                        ForEach(Array(sounds.enumerated()), id: \.element.id) { index, sound in
                            row(sound, index: index).id(index)
                        }
                        endRow.id(sounds.count)
                    }
                    .padding(Theme.Spacing.xs)
                }
                .onChange(of: standby) { _, index in
                    withAnimation(Theme.hover) { proxy.scrollTo(index) }
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: moveStandby)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
                            .strokeBorder(listFocused ? Theme.strokeStrong : Theme.stroke, lineWidth: 1)
                    )
            )
        }
        .alert("Note", isPresented: Binding(
            get: { editingNoteID != nil },
            set: { if !$0 { editingNoteID = nil } }
        )) {
            TextField("Note", text: $noteText)
            Button("Save", action: saveNote)
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Go bar

    private var goBar: some View {
        HStack(spacing: Theme.Spacing.l) {
            Button(action: go) {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "play.fill")
                    Text("Go")
                }
                .font(Theme.Font.title())
                .foregroundStyle(Color.white)
                .frame(minWidth: 96)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
                        .fill(standby < sounds.count ? Theme.accent : Theme.surfaceRaised)
                )
            }
            .buttonStyle(.plain)
            .disabled(standby >= sounds.count)
            .help("Play the standby cue (.)")

            VStack(alignment: .leading, spacing: 2) {
                Text("Standby")
                    .font(Theme.Font.caption(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(standby < sounds.count ? "\(standby + 1)  \(sounds[standby].name)" : "End of list")
                    .font(Theme.Font.title())
                    .foregroundStyle(standby < sounds.count ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Rows

    private func row(_ sound: SoundItem, index: Int) -> some View {
        let isStandby = index == standby
        let isPlaying = engine.playingIDs.contains(sound.id)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.accent)
                .opacity(isStandby ? 1 : 0)
                .frame(width: 12)
            Text("\(index + 1)")
                .font(Theme.Font.body(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name)
                    .font(Theme.Font.body(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let note = sound.note, !note.isEmpty {
                    Text(note)
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            if let key = sound.hotKey { KeyCap(key: key) }
            CueDuration(sound: sound, library: library)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(
            shape.fill(isStandby ? Theme.surfaceHover : (isPlaying ? Theme.surfaceRaised : Color.clear))
        )
        .overlay(alignment: .bottom) {
            if isPlaying {
                CueProgressBar(playhead: engine.playhead, soundID: sound.id, color: sound.tint.color)
                    .frame(height: 2)
                    .padding(.horizontal, Theme.Spacing.m)
            }
        }
        .overlay(shape.strokeBorder(isStandby ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(shape)
        .onTapGesture(count: 2) { play(at: index) }
        .simultaneousGesture(TapGesture().onEnded {
            library.setCueIndex(index)
            listFocused = true
        })
        .contextMenu {
            Button("Play") { play(at: index) }
            Button("Set as Standby") { library.setCueIndex(index) }
            Divider()
            Button("Edit Note…") {
                noteText = sound.note ?? ""
                editingNoteID = sound.id
            }
            if sound.note != nil {
                Button("Remove Note") { library.update(sound) { $0.note = nil } }
            }
        }
    }

    /// The row after the last cue. The standby is here when all cues have played.
    private var endRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.accent)
                .opacity(standby == sounds.count ? 1 : 0)
                .frame(width: 12)
            Text(sounds.isEmpty ? "No cues. Drop audio files here, or use Add." : "End")
                .font(Theme.Font.body(.medium))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .contentShape(Rectangle())
        .onTapGesture { library.setCueIndex(sounds.count) }
    }

    // MARK: - Actions

    /// Plays one row. The standby goes to the row after it, as after a Go.
    private func play(at index: Int) {
        library.setCueIndex(index)
        go()
    }

    private func moveStandby(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: library.setCueIndex(CueList.move(standby, by: -1, count: sounds.count))
        case .down: library.setCueIndex(CueList.move(standby, by: 1, count: sounds.count))
        default: break
        }
    }

    private func saveNote() {
        guard let id = editingNoteID, let sound = library.sound(withID: id) else { return }
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        library.update(sound) { $0.note = trimmed.isEmpty ? nil : trimmed }
        editingNoteID = nil
    }
}

/// The progress of a playing cue. Only this view observes the playhead.
private struct CueProgressBar: View {
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

/// The play time of a cue. It reads only the file header, away from the main thread.
/// A file that does not open shows no time. A loop shows a loop symbol.
private struct CueDuration: View {
    let sound: SoundItem
    let library: SoundLibrary

    @State private var seconds: Double?

    var body: some View {
        Group {
            if sound.loops {
                Image(systemName: "repeat")
            } else if let seconds {
                Text(CueList.format(seconds))
            }
        }
        .font(Theme.Font.caption(.medium).monospacedDigit())
        .foregroundStyle(Theme.textTertiary)
        .task(id: TaskKey(sound: sound)) { seconds = await load() }
    }

    /// Reads the time again when the file or the trim changes.
    private struct TaskKey: Equatable {
        let id: UUID
        let fileName: String
        let trimStart: Double
        let trimEnd: Double?
        let speed: Double

        init(sound: SoundItem) {
            id = sound.id
            fileName = sound.fileName
            trimStart = sound.trimStart
            trimEnd = sound.trimEnd
            speed = sound.speed
        }
    }

    private func load() async -> Double? {
        guard let resolution = library.resolve(sound) else { return nil }
        let url = resolution.url
        let scoped = resolution.needsSecurityScope
        let fileDuration: Double? = await Task.detached(priority: .utility) {
            let didAccess = scoped && url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let rate = file.processingFormat.sampleRate
            return rate > 0 ? Double(file.length) / rate : nil
        }.value
        guard let fileDuration else { return nil }
        return CueList.duration(
            fileDuration: fileDuration,
            trimStart: sound.trimStart,
            trimEnd: sound.trimEnd,
            speed: sound.speed
        )
    }
}
