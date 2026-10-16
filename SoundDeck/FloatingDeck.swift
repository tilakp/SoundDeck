import AppKit
import SwiftUI

/// Remembers if the floating deck was open at the last quit.
struct FloatingDeckPreference {
    static let openKey = "floatingDeckOpen"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The value is false when the user never opened the panel.
    var isOpen: Bool {
        get { defaults.bool(forKey: Self.openKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.openKey) }
    }
}

/// A small panel with the pads. The panel stays above other apps, such as Zoom, Meet or OBS.
///
/// The panel does not activate the app. A click on a pad plays the pad, and the meeting
/// app stays the active app.
@MainActor
final class FloatingDeck: NSObject, NSWindowDelegate {
    /// The instance that the application uses.
    static var shared: FloatingDeck?

    static let autosaveName = "FloatingDeck"
    static let defaultSize = NSSize(width: 300, height: 360)
    static let minimumSize = NSSize(width: 220, height: 160)

    private let library: SoundLibrary
    private let engine: AudioEngine
    private let preference: FloatingDeckPreference
    private var panel: NSPanel?

    init(library: SoundLibrary, engine: AudioEngine, preference: FloatingDeckPreference = FloatingDeckPreference()) {
        self.library = library
        self.engine = engine
        self.preference = preference
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Do not make the panel key. The front app keeps the keyboard focus.
        panel.orderFrontRegardless()
        preference.isOpen = true
    }

    func hide() {
        panel?.orderOut(nil)
        preference.isOpen = false
    }

    /// Opens the panel again if it was open at the last quit.
    func restore() {
        if preference.isOpen { show() }
    }

    // The close button of the panel calls this. A quit does not close the windows,
    // so the preference stays true for the next launch.
    func windowWillClose(_ notification: Notification) {
        preference.isOpen = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.title = "Sound Deck"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        // A panel hides when its app is not active. This panel must stay over the meeting app.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(Theme.surface)
        panel.contentMinSize = Self.minimumSize
        panel.delegate = self
        panel.contentView = FirstMouseHostingView(rootView: FloatingDeckView(library: library, engine: engine))
        panel.center()
        // Restores the saved frame, if there is one, and saves each change.
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }
}

/// A hosting view that acts on the first click.
///
/// The app is usually not active when the user clicks the panel. Without this override,
/// AppKit can use the first click only to bring the window forward.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The content of the floating deck: the deck name, a Stop All button and the pads.
struct FloatingDeckView: View {
    @ObservedObject var library: SoundLibrary
    @ObservedObject var engine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header
            if let error = engine.lastError {
                Text(error)
                    .font(Theme.Font.caption())
                    .foregroundStyle(SoundTint.rose.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                MiniPadGrid(library: library, engine: engine, showsGlobalHint: GlobalHotKeys.shared.isEnabled)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(library.activeDeck.name)
                .font(Theme.Font.caption(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            stopButton
        }
    }

    private var stopButton: some View {
        let idle = engine.playingIDs.isEmpty
        return Button {
            engine.stopAll()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "stop.fill")
                Text("Stop All")
            }
            .font(Theme.Font.caption(.semibold))
            .foregroundStyle(idle ? Theme.textTertiary : Theme.backdropBottom)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(idle ? Theme.surfaceRaised : SoundTint.rose.color)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(idle)
        .accessibilityLabel("Stop all sounds")
    }
}
