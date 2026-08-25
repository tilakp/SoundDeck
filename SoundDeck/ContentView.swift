import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = SoundLibrary()
    @StateObject private var engine = AudioEngine()

    @State private var showingFileImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isDropTargeted = false
    @State private var renaming: SoundItem?
    @State private var renameText = ""

    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "aac", "caf", "flac", "ogg", "wma"
    ]

    var body: some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()

            VStack(spacing: 14) {
                header
                monitor
                deck
                footer
            }
            .padding(18)

            if isDropTargeted { dropOverlay }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(KeyboardHandler(
            onStop: { engine.stopAll() },
            onReplay: { attempt { try engine.replayLast(in: library) } },
            onCharacter: triggerHotKey
        ))
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                report(library.addSounds(urls: urls))
            case .failure(let error):
                present(error)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .alert("Something went wrong", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(item: $renaming) { sound in
            RenameSheet(name: $renameText) {
                library.rename(sound, to: renameText)
                renaming = nil
            } cancel: {
                renaming = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentGradient)
                        .frame(width: 34, height: 34)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 9, y: 3)
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sound Deck")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(library.sounds.count) sound\(library.sounds.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: 8)

            searchField
                .frame(maxWidth: 220)

            outputMenu

            ChromeButton(title: "Add", icon: "plus", prominent: true) {
                showingFileImporter = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search", text: $library.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            if !library.searchText.isEmpty {
                Button {
                    library.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
        )
    }

    /// Output routing. Selecting a virtual device here is what lets conferencing and
    /// streaming apps hear the deck.
    private var outputMenu: some View {
        Menu {
            Button {
                engine.selectOutputDevice(uid: nil)
            } label: {
                HStack {
                    Text("System Default")
                    if engine.selectedDeviceUID == nil { Image(systemName: "checkmark") }
                }
            }
            let virtual = engine.outputDevices.filter(\.isLikelyVirtual)
            if !virtual.isEmpty {
                Divider()
                Section("Virtual") {
                    ForEach(virtual) { device in deviceButton(device) }
                }
            }
            Divider()
            Section("All Outputs") {
                ForEach(engine.outputDevices) { device in deviceButton(device) }
            }
            Divider()
            Button("Refresh Devices") { engine.refreshDevices() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.and.appletv")
                    .font(.system(size: 11, weight: .semibold))
                Text(engine.selectedDeviceName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func deviceButton(_ device: AudioDevice) -> some View {
        Button {
            engine.selectOutputDevice(uid: device.uid)
        } label: {
            HStack {
                Text(device.name)
                if engine.selectedDeviceUID == device.uid { Image(systemName: "checkmark") }
            }
        }
    }

    // MARK: - Monitor

    private var monitor: some View {
        GlassPanel {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(nowPlayingTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(engine.playingIDs.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1)
                    Text(engine.playingIDs.isEmpty ? "Idle" : "\(engine.playingIDs.count) playing")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(width: 150, alignment: .leading)

                Group {
                    if let samples = engine.waveform {
                        WaveformView(samples: samples, progress: engine.progress, tint: focusedTint)
                    } else {
                        WaveformPlaceholder()
                    }
                }
                .frame(height: 44)
                .frame(maxWidth: .infinity)

                masterVolume
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var masterVolume: some View {
        HStack(spacing: 7) {
            Image(systemName: engine.masterVolume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
            Slider(value: $engine.masterVolume, in: 0...1)
                .controlSize(.mini)
                .tint(Theme.accent)
                .frame(width: 92)
        }
    }

    private var nowPlayingTitle: String {
        guard let id = engine.focusedSoundID,
              let sound = library.sounds.first(where: { $0.id == id }) else {
            return "Nothing playing"
        }
        return sound.name
    }

    private var focusedTint: Color {
        guard let id = engine.focusedSoundID,
              let sound = library.sounds.first(where: { $0.id == id }) else { return Theme.accent }
        return sound.tint.color
    }

    // MARK: - Deck

    private var deck: some View {
        GeometryReader { geometry in
            let columns = gridColumns(for: geometry.size.width)
            ScrollView {
                if library.filteredSounds.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.tileSpacing) {
                        ForEach(library.filteredSounds) { sound in
                            SoundTile(
                                sound: sound,
                                isPlaying: engine.playingIDs.contains(sound.id),
                                isLastPlayed: engine.lastPlayedID == sound.id,
                                play: { attempt { try engine.play(sound, in: library) } },
                                stop: { engine.stop(sound) },
                                remove: {
                                    engine.stop(sound, fade: false)
                                    library.remove(sound)
                                },
                                update: { mutate in library.update(sound, mutate) },
                                beginRename: {
                                    renameText = sound.name
                                    renaming = sound
                                }
                            )
                            .onDrag {
                                NSItemProvider(object: sound.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDropDelegate(target: sound, library: library))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let count = max(1, Int((width + Theme.tileSpacing) / (Theme.tileMinWidth + Theme.tileSpacing)))
        return Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing), count: count)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: library.searchText.isEmpty ? "waveform.badge.plus" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(library.searchText.isEmpty ? "Your deck is empty" : "No matches")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text(library.searchText.isEmpty
                 ? "Drop audio files here, or use Add."
                 : "Nothing matches “\(library.searchText)”.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                KeyCap(key: "space")
                Text("stop")
                KeyCap(key: "⏎")
                Text("replay")
                KeyCap(key: "1-9")
                Text("trigger")
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textTertiary)

            Spacer()

            ChromeButton(title: "Stop All", icon: "stop.fill") {
                engine.stopAll()
            }
            .opacity(engine.playingIDs.isEmpty ? 0.45 : 1)
            .animation(Theme.hover, value: engine.playingIDs.isEmpty)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Theme.accent.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 28, weight: .medium))
                    Text("Drop to add sounds")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Theme.accentBright)
            )
            .padding(10)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func triggerHotKey(_ character: String) {
        guard let sound = library.sound(forHotKey: character) else { return }
        attempt { try engine.play(sound, in: library) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                    collected.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            report(library.addSounds(urls: collected))
        }
        return true
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { present(error) }
    }

    private func report(_ errors: [Error]) {
        guard let first = errors.first else { return }
        if errors.count == 1 {
            present(first)
        } else {
            alertMessage = "\(errors.count) files could not be added. First problem: \(first.localizedDescription)"
            showAlert = true
        }
    }

    private func present(_ error: Error) {
        alertMessage = error.localizedDescription
        showAlert = true
    }
}

// MARK: - Reordering

/// Accepts a tile dragged onto another tile and moves it in front of the target.
struct ReorderDropDelegate: DropDelegate {
    let target: SoundItem
    let library: SoundLibrary

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let string = value as? String, let id = UUID(uuidString: string) else { return }
            Task { @MainActor in
                library.move(id: id, before: target.id)
            }
        }
        return true
    }
}

// MARK: - Rename

struct RenameSheet: View {
    @Binding var name: String
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Sound")
                .font(.system(size: 14, weight: .bold, design: .rounded))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

// MARK: - Keyboard

/// Captures key presses for the whole window.
///
/// SwiftUI has no global key handler on macOS, so an AppKit view sits behind the
/// content and forwards what the deck cares about. Anything it does not handle is
/// passed up the responder chain so text fields keep working.
struct KeyboardHandler: NSViewRepresentable {
    let onStop: () -> Void
    let onReplay: () -> Void
    let onCharacter: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcher()
        view.onStop = onStop
        view.onReplay = onReplay
        view.onCharacter = onCharacter
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCatcher else { return }
        view.onStop = onStop
        view.onReplay = onReplay
        view.onCharacter = onCharacter
    }

    final class KeyCatcher: NSView {
        var onStop: (() -> Void)?
        var onReplay: (() -> Void)?
        var onCharacter: ((String) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            // Never swallow keys while the user is typing in a field.
            if let responder = window?.firstResponder, responder is NSTextView {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 49: onStop?()          // space
            case 36, 76: onReplay?()    // return, keypad enter
            default:
                guard !event.modifierFlags.contains(.command),
                      let characters = event.charactersIgnoringModifiers,
                      let first = characters.first,
                      first.isLetter || first.isNumber else {
                    super.keyDown(with: event)
                    return
                }
                onCharacter?(String(first))
            }
        }
    }
}
