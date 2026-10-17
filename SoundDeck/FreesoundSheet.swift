import AppKit
import AVFoundation
import SwiftUI

/// Searches freesound.org and adds a result as a pad in the active deck.
///
/// The preview plays through `AVPlayer`, not through the deck engine, so it does not go to the stream output.
struct FreesoundSheet: View {
    @ObservedObject var library: SoundLibrary
    let dismiss: () -> Void

    @ObservedObject private var key = FreesoundKey.shared
    @StateObject private var player = FreesoundPreviewPlayer()
    @Environment(\.openSettings) private var openSettings

    @State private var query = FreesoundQuery(text: "")
    @State private var results: [FreesoundSound] = []
    @State private var total = 0
    @State private var next: URL?
    @State private var isLoading = false
    @State private var adding: Set<Int> = []
    @State private var added: Set<Int> = []
    @State private var message: String?
    @State private var copiedCredits = false

    private var deckCredits: String { FreesoundCredit.deckCredits(library.activeDeck.sounds) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Add from Freesound")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.textPrimary)
                Text("Adds pads to “\(library.activeDeck.name)” in preview quality, 128 kbps MP3.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textTertiary)
            }

            if key.value == nil {
                noKey
            } else {
                searchControls
                resultList
            }

            if let message {
                Text(message)
                    .font(Theme.Font.caption())
                    .foregroundStyle(SoundTint.rose.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(copiedCredits ? "Credits Copied" : "Copy Credits for This Deck", action: copyCredits)
                    .disabled(deckCredits.isEmpty)
                    .help("Copies one line for each pad with a Creative Commons credit")
                Spacer()
                Button("Done") {
                    player.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560, height: key.value == nil ? nil : 560)
        .background(Theme.backdrop)
        .onDisappear { player.stop() }
    }

    // MARK: Parts

    private var noKey: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("To search Freesound, paste a free API key in Settings > Freesound.")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") {
                    dismiss()
                    UserDefaults.standard.set(SettingsView.Tab.freesound.rawValue, forKey: SettingsView.selectedTabKey)
                    openSettings()
                }
                Link("Apply for a key", destination: FreesoundSettings.applyURL)
            }
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                TextField("Search Freesound", text: $query.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading)
            }
            HStack(spacing: Theme.Spacing.m) {
                Picker("License", selection: $query.license) {
                    ForEach(FreesoundQuery.LicenseFilter.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Picker("Length", selection: $query.duration) {
                    ForEach(FreesoundQuery.DurationFilter.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Toggle("Include NonCommercial", isOn: $query.includesNonCommercial)
                    .disabled(query.license != .any)
                    .help("NonCommercial sounds do not allow a monetized stream")
            }
            .font(Theme.Font.caption())
        }
    }

    private var resultList: some View {
        List {
            if !results.isEmpty {
                Text("\(total) sounds")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(results) { sound in
                row(sound)
            }
            if let next {
                Button("Next Page") { load(next) }
                    .disabled(isLoading)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            if isLoading && results.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func row(_ sound: FreesoundSound) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Button {
                player.toggle(sound)
            } label: {
                Image(systemName: player.playingID == sound.id ? "stop.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .disabled(sound.previewURL == nil)
            .help("Preview")

            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name)
                    .font(Theme.Font.body(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(sound.username) · \(Self.format(sound.duration))")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            LicenseBadge(license: sound.licenseKind)

            if added.contains(sound.id) {
                Image(systemName: "checkmark")
                    .foregroundStyle(SoundTint.teal.color)
                    .frame(width: 44)
            } else if adding.contains(sound.id) {
                ProgressView().controlSize(.small).frame(width: 44)
            } else {
                Button("Add") { add(sound) }
                    .disabled(sound.previewURL == nil)
                    .frame(width: 44)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: Actions

    private func search() {
        guard !isLoading else { return }
        results = []
        next = nil
        total = 0
        load(nil)
    }

    /// Loads the first page when `url` is nil, or else the page at `url`.
    private func load(_ url: URL?) {
        guard let apiKey = key.value else { return }
        let query = self.query
        isLoading = true
        message = nil
        Task {
            do {
                let page: FreesoundPage
                if let url {
                    page = try await FreesoundClient.page(at: url, key: apiKey)
                } else {
                    page = try await FreesoundClient.search(query, key: apiKey)
                }
                let shown = page.results.filter { query.allows($0.licenseKind) }
                results.append(contentsOf: shown)
                total = page.count
                next = page.next
                if page.count == 0 { message = "No sounds match. Try other words or filters." }
            } catch {
                message = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func add(_ sound: FreesoundSound) {
        adding.insert(sound.id)
        message = nil
        Task {
            do {
                let file = try await FreesoundClient.downloadPreview(of: sound)
                let item = try library.addRecording(at: file, name: SoundItem.displayName(forFileName: sound.name))
                let credit = FreesoundCredit.text(for: sound)
                library.update(item) { $0.credit = credit }
                added.insert(sound.id)
                copiedCredits = false
            } catch {
                message = error.localizedDescription
            }
            adding.remove(sound.id)
        }
    }

    private func copyCredits() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deckCredits, forType: .string)
        copiedCredits = true
    }

    static func format(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let minutes = tenths / 600
        let rest = Double(tenths % 600) / 10
        return minutes > 0 ? String(format: "%d:%04.1f", minutes, rest) : String(format: "%.1f s", rest)
    }
}

extension FreesoundQuery {
    /// A second check on the result. The server filter must already remove these licenses.
    func allows(_ kind: FreesoundLicense) -> Bool {
        switch kind {
        case .cc0: return true
        case .attribution: return license != .cc0
        case .nonCommercial, .other: return license == .any && includesNonCommercial
        }
    }
}

private struct LicenseBadge: View {
    let license: FreesoundLicense

    private var tint: Color {
        switch license {
        case .cc0: return SoundTint.teal.color
        case .attribution: return SoundTint.amber.color
        case .nonCommercial, .other: return SoundTint.rose.color
        }
    }

    var body: some View {
        Text(license.label)
            .font(Theme.Font.caption(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .help(license.requiresCredit ? "Give credit to the author" : "No credit is necessary")
    }
}

/// Plays one Freesound preview at a time from its URL.
final class FreesoundPreviewPlayer: ObservableObject {
    @Published private(set) var playingID: Int?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ sound: FreesoundSound) {
        if playingID == sound.id {
            stop()
            return
        }
        stop()
        guard let url = sound.previewURL else { return }
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
        let player = AVPlayer(playerItem: item)
        self.player = player
        playingID = sound.id
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playingID = nil
    }
}
