import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var library: SoundLibrary
    @ObservedObject var engine: AudioEngine

    @State private var showingFileImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isDropTargeted = false
    @State private var inspecting: SoundItem?
    @State private var recording = false
    @State private var renamingDeckID: UUID?
    @State private var deckName = ""
    @State private var deletingDeck: Deck?
    @State private var notice = TransientNotice()
    @State private var showingShortcuts = false
    @FocusState private var searchFocused: Bool

    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "aac", "caf", "flac", "ogg", "wma"
    ]

    var body: some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.l) {
                header
                monitor
                deckBar
                deck
            }
            .padding(Theme.Spacing.l)

            if isDropTargeted { dropOverlay }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(KeyboardHandler(
            onStop: { engine.stopAll() },
            onReplay: replayOrFireFocusedPad,
            onCharacter: triggerHotKey,
            onRelease: releaseHotKey
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
        // Errors from the menu bar deck and the global hotkeys also show in the monitor strip.
        .onChange(of: engine.lastError) { _, message in
            if let message { flash(message) }
        }
        .alert("Something went wrong", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(item: $inspecting) { sound in
            SoundInspector(sound: sound, library: library, engine: engine) {
                inspecting = nil
            }
        }
        .sheet(isPresented: $recording) {
            RecorderSheet(library: library) { recording = false }
        }
        .alert("Rename Deck", isPresented: Binding(
            get: { renamingDeckID != nil },
            set: { if !$0 { renamingDeckID = nil } }
        )) {
            TextField("Name", text: $deckName)
            Button("Rename") {
                if let id = renamingDeckID { library.renameDeck(id, to: deckName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deletingDeck?.name ?? "")”?",
            isPresented: Binding(get: { deletingDeck != nil }, set: { if !$0 { deletingDeck = nil } }),
            presenting: deletingDeck
        ) { deck in
            Button("Delete Deck", role: .destructive) {
                for sound in deck.sounds { engine.stop(sound, fade: false) }
                library.removeDeck(deck.id)
            }
        } message: { deck in
            Text("This removes the deck and its \(deck.sounds.count) pads. You cannot undo this.")
        }
    }

    // MARK: - Header

    private var header: some View {
        // The search field is overlaid rather than placed between the two groups, so
        // it centres on the window instead of on the leftover space. That space would
        // drift as the branding and device names change width.
        ZStack {
            headerSides
            searchField
                .frame(width: 250)
        }
    }

    private var headerSides: some View {
        HStack(spacing: Theme.Spacing.m) {
            // The window has no title bar. This quiet wordmark keeps the name visible.
            Text("Sound Deck")
                .font(Theme.Font.body(.semibold))
                .foregroundStyle(Theme.textSecondary)

            shortcutsButton

            // Reserves the centre for the overlaid search field.
            Spacer(minLength: 270)

            outputMenu

            addMenu
        }
    }

    /// The keyboard shortcuts of the main window, in a small popover.
    private var shortcutsButton: some View {
        Button {
            showingShortcuts.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Keyboard shortcuts")
        .popover(isPresented: $showingShortcuts, arrowEdge: .bottom) {
            ShortcutList()
        }
    }

    /// Adds sounds. The divider leaves space for more sources later.
    private var addMenu: some View {
        Menu {
            Button("Add Files…") { showingFileImporter = true }
            Button("Record…") { recording = true }
            Divider()
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "plus")
                Text("Add")
            }
            .font(Theme.Font.body(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.accent)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.caption(.semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search", text: $library.searchText)
                .textFieldStyle(.plain)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                // Give the keys back to the deck. If not, the digits go into the field.
                .onSubmit(endEditing)
                .onExitCommand(perform: endEditing)
            if !library.searchText.isEmpty {
                Button {
                    library.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
        )
        .background(
            // Command-F puts the focus in the search field.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
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
            if engine.routing.micEnabled {
                Divider()
                Toggle("Mute Microphone", isOn: Binding(
                    get: { engine.routing.micMuted },
                    set: { engine.setMicMuted($0) }))
            }
            Divider()
            Button("Refresh Devices") { engine.refreshDevices() }
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "speaker.wave.2")
                    .font(Theme.Font.caption(.semibold))
                Text(engine.selectedDeviceName)
                    .font(Theme.Font.body(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
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
            HStack(spacing: Theme.Spacing.l) {
                Text(nowPlayingTitle)
                    .font(Theme.Font.body(.semibold))
                    .foregroundStyle(engine.playingIDs.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                monitorCentre
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)

                masterVolume

                // Stop All stays in this place in all states, so the hand finds it.
                StopAllButton(active: !engine.playingIDs.isEmpty) {
                    engine.stopAll()
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
        }
    }

    private var masterVolume: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: engine.masterVolume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
            Slider(value: $engine.masterVolume, in: 0...1)
                .controlSize(.mini)
                .tint(Theme.accent)
                .frame(width: 92)
        }
    }

    /// A playback error for some seconds, else the waveform, else one quiet hairline.
    @ViewBuilder private var monitorCentre: some View {
        if let message = notice.text {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .lineLimit(2)
            }
            .font(Theme.Font.body(.medium))
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        } else if let samples = engine.waveform {
            MonitorWaveform(samples: samples, playhead: engine.playhead, tint: focusedTint)
        } else {
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
        }
    }

    /// One label for the monitor. "Idle" when nothing plays.
    private var nowPlayingTitle: String {
        guard !engine.playingIDs.isEmpty else { return "Idle" }
        let others = engine.playingIDs.count - 1
        guard let id = engine.focusedSoundID,
              let sound = library.sound(withID: id) else {
            return "\(engine.playingIDs.count) playing"
        }
        return others > 0 ? "\(sound.name) +\(others)" : sound.name
    }

    private var focusedTint: Color {
        guard let id = engine.focusedSoundID,
              let sound = library.sound(withID: id) else { return Theme.accent }
        return sound.tint.color
    }

    // MARK: - Deck bar

    /// The decks. Keys play pads of the active deck only.
    private var deckBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(library.decks) { deck in deckChip(deck) }
                Menu {
                    Button("New Deck") {
                        let deck = library.addDeck(named: "Deck")
                        startRenaming(deck)
                    }
                    Button("Import Deck…", action: importDeck)
                } label: {
                    Image(systemName: "plus")
                        .font(Theme.Font.caption(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.surface))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New or imported deck")
            }
        }
    }

    private func deckChip(_ deck: Deck) -> some View {
        let isActive = deck.id == library.activeDeckID
        return Button {
            library.selectDeck(deck.id)
        } label: {
            Text(deck.name)
                .font(Theme.Font.body(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(isActive ? Theme.surfaceRaised : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .strokeBorder(isActive ? Theme.strokeStrong : Theme.stroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { startRenaming(deck) }
            Button("Export…") { export(deck) }
            Divider()
            Button("Delete…", role: .destructive) { deletingDeck = deck }
                .disabled(library.decks.count < 2)
        }
    }

    private func startRenaming(_ deck: Deck) {
        deckName = deck.name
        renamingDeckID = deck.id
    }

    private func export(_ deck: Deck) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DeckArchive.contentType]
        panel.nameFieldStringValue = "\(deck.name).\(DeckArchive.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attemptWithAlert { try library.exportArchive(of: deck.id).write(to: url, options: .atomic) }
    }

    private func importDeck() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [DeckArchive.contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attemptWithAlert { try library.importArchive(Data(contentsOf: url)) }
    }

    // MARK: - Deck

    /// The pad with the keyboard focus. Tab and the arrow keys move it.
    @FocusState private var focusedPadID: UUID?

    /// Return fires the pad with the keyboard focus. With no focused pad, Return plays the last pad again.
    private func replayOrFireFocusedPad() {
        if let id = focusedPadID, let sound = library.filteredSounds.first(where: { $0.id == id }) {
            play(sound)
        } else {
            replayLast()
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, in sounds: [SoundItem], columns: Int) {
        let step: PadGridNavigation.Direction
        switch direction {
        case .left: step = .left
        case .right: step = .right
        case .up: step = .up
        case .down: step = .down
        @unknown default: return
        }
        guard let id = focusedPadID,
              let index = sounds.firstIndex(where: { $0.id == id }),
              let target = PadGridNavigation.neighbour(
                  of: index, count: sounds.count, columns: columns, direction: step
              ) else { return }
        focusedPadID = sounds[target].id
    }

    private var deck: some View {
        GeometryReader { geometry in
            let columns = gridColumns(for: geometry.size.width)
            let sounds = library.filteredSounds
            ScrollView {
                if sounds.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.tileSpacing) {
                        ForEach(sounds) { sound in
                            SoundTile(
                                sound: sound,
                                isPlaying: engine.playingIDs.contains(sound.id),
                                isLastPlayed: engine.lastPlayedID == sound.id,
                                isFocused: focusedPadID == sound.id,
                                errorMessage: engine.padErrors[sound.id],
                                playhead: engine.playhead,
                                play: {
                                    endEditing()
                                    play(sound)
                                },
                                release: { engine.release(sound) },
                                stop: { engine.stop(sound) },
                                remove: {
                                    engine.stop(sound, fade: false)
                                    library.remove(sound)
                                },
                                update: { mutate in library.update(sound, mutate) },
                                openInspector: { inspecting = sound },
                                moveTargets: library.decks
                                    .filter { $0.id != library.activeDeckID }
                                    .map { (id: $0.id, name: $0.name) },
                                moveToDeck: { library.moveSound(sound, toDeck: $0) }
                            )
                            .focused($focusedPadID, equals: sound.id)
                            .onDrag {
                                NSItemProvider(object: sound.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDropDelegate(target: sound, library: library))
                        }
                    }
                    .onMoveCommand { moveFocus($0, in: sounds, columns: columns.count) }
                    // Room for the focus ring, which is outside the tile.
                    .padding(.vertical, 4)
                    .padding(.horizontal, 3)
                }
            }
        }
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let count = max(1, Int((width + Theme.tileSpacing) / (Theme.tileMinWidth + Theme.tileSpacing)))
        return Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing), count: count)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: library.searchText.isEmpty ? "waveform.badge.plus" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(library.searchText.isEmpty ? "Your deck is empty" : "No matches")
                .font(Theme.Font.title())
                .foregroundStyle(Theme.textSecondary)
            Text(library.searchText.isEmpty
                 ? "Drop audio files here, or use Add."
                 : "Nothing matches “\(library.searchText)”.")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
            .fill(Theme.accent.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            )
            .overlay(
                VStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 28, weight: .medium))
                    Text("Drop to add sounds")
                        .font(Theme.Font.title())
                }
                .foregroundStyle(Theme.accentBright)
            )
            .padding(Theme.Spacing.m)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func triggerHotKey(_ character: String) {
        guard let sound = library.sound(forHotKey: character) else { return }
        play(sound)
    }

    /// Triggers a pad. An error marks the pad and shows in the monitor strip. It never shows an alert.
    private func play(_ sound: SoundItem) {
        do {
            try engine.trigger(sound, in: library)
        } catch {
            engine.recordFailure(error, for: sound)
            // `lastError` can keep the same text, so `onChange` does not always fire.
            flash(error.localizedDescription)
        }
    }

    private func replayLast() {
        guard let id = engine.lastPlayedID, let sound = library.sound(withID: id) else { return }
        do {
            try engine.replayLast(in: library)
        } catch {
            engine.recordFailure(error, for: sound)
            flash(error.localizedDescription)
        }
    }

    /// Shows a message in the monitor strip for `TransientNotice.duration` seconds.
    private func flash(_ message: String) {
        let token = withAnimation(Theme.hover) { notice.show(message) }
        DispatchQueue.main.asyncAfter(deadline: .now() + TransientNotice.duration) {
            withAnimation(Theme.hover) { notice.expire(token) }
        }
    }

    private func releaseHotKey(_ character: String) {
        guard let sound = library.sound(forHotKey: character) else { return }
        engine.release(sound)
    }

    /// Ends text editing in the window. The keyboard monitor then gets the hotkeys again.
    private func endEditing() {
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
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

    /// Runs live work, for example a pad press. An error shows in the monitor strip, not in an alert.
    /// Use `play(_:)` for a pad. It also marks the pad that failed.
    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { flash(error.localizedDescription) }
    }

    /// Runs work that the user waits for, for example an export. An error shows in an alert.
    private func attemptWithAlert(_ work: () throws -> Void) {
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

// MARK: - Keyboard

/// Captures key presses for the whole window.
///
/// SwiftUI has no global key handler on macOS. An AppKit view installs a local event
/// monitor for its window. The monitor does not depend on the first responder, so a
/// click on a SwiftUI control does not stop the hotkeys. A text field keeps its keys.
struct KeyboardHandler: NSViewRepresentable {
    let onStop: () -> Void
    let onReplay: () -> Void
    let onCharacter: (String) -> Void
    let onRelease: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcher()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCatcher else { return }
        view.onStop = onStop
        view.onReplay = onReplay
        view.onCharacter = onCharacter
        view.onRelease = onRelease
    }

    final class KeyCatcher: NSView {
        var onStop: (() -> Void)?
        var onReplay: (() -> Void)?
        var onCharacter: ((String) -> Void)?
        var onRelease: ((String) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, event.window === self.window, self.handle(event) else { return event }
                return nil
            }
        }

        /// Returns true when the deck used the key.
        private func handle(_ event: NSEvent) -> Bool {
            // Never swallow keys while the user is typing in a field.
            if window?.firstResponder is NSTextView { return false }
            if event.type == .keyUp {
                guard let character = Self.padCharacter(of: event) else { return false }
                onRelease?(character)
                return true
            }
            // A held key repeats. The pad plays one time for each press.
            if event.isARepeat { return Self.padCharacter(of: event) != nil || [36, 49, 76].contains(event.keyCode) }
            switch event.keyCode {
            case 49: onStop?()          // space
            case 36, 76: onReplay?()    // return, keypad enter
            default:
                guard let character = Self.padCharacter(of: event) else { return false }
                onCharacter?(character)
            }
            return true
        }

        /// The letter or digit of a pad key. Nil for other keys and for Command shortcuts.
        private static func padCharacter(of event: NSEvent) -> String? {
            guard !event.modifierFlags.contains(.command),
                  let first = event.charactersIgnoringModifiers?.first,
                  first.isLetter || first.isNumber else { return nil }
            return String(first)
        }
    }
}

/// The monitor waveform. Only this view observes the playhead.
private struct MonitorWaveform: View {
    let samples: [Float]
    @ObservedObject var playhead: Playhead
    let tint: Color

    var body: some View {
        WaveformView(samples: samples, progress: playhead.progress, tint: tint)
    }
}

/// Stops every voice. It stays in one place. It is rose while sound plays and quiet when idle.
private struct StopAllButton: View {
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "stop.fill")
                Text("Stop All")
            }
            .font(Theme.Font.body(.semibold))
            .foregroundStyle(active ? Color.white : Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(background)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Stop all sounds (Space)")
        .animation(Theme.hover, value: active)
        .animation(Theme.hover, value: hovering)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let idleFill = hovering ? Theme.surfaceHover : Theme.surfaceRaised
        return shape
            .fill(active ? Theme.danger : idleFill)
            .overlay(shape.strokeBorder(active ? Color.clear : Theme.stroke, lineWidth: 1))
    }
}

/// The keyboard shortcuts of the main window.
private struct ShortcutList: View {
    private let rows: [(key: String, action: String)] = [
        ("Space", "Stop all sounds"),
        ("Return", "Play the last pad again"),
        ("A–Z, 0–9", "Play the pad with that key"),
        ("⌘F", "Search"),
        ("Esc", "Leave the search field")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Keyboard Shortcuts")
                .font(Theme.Font.body(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.s) {
                ForEach(rows, id: \.key) { row in
                    GridRow {
                        KeyCap(key: row.key)
                        Text(row.action)
                            .font(Theme.Font.body())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(Theme.Spacing.l)
        // The text colours are for a dark surface. This sets the popover only, not the window.
        .preferredColorScheme(.dark)
    }
}
