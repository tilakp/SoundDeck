import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#endif
import AVKit

// Material color palette from https://colorhunt.co/palette/222831393e46948979dfd0b8
extension Color {
    static let mdDark = Color(red: 34/255, green: 40/255, blue: 49/255)      // #222831
    static let mdGrey = Color(red: 57/255, green: 62/255, blue: 70/255)      // #393E46
    static let mdTeal = Color(red: 148/255, green: 137/255, blue: 121/255)   // #948979
    static let mdCream = Color(red: 223/255, green: 208/255, blue: 184/255)  // #DFD0B8
}

struct MaterialCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        content
            .padding(8)
            .background(Color.mdCream)
            .cornerRadius(12)
            .shadow(color: Color.mdGrey.opacity(0.14), radius: 6, x: 0, y: 3)
    }
}

struct MaterialButton: View {
    let label: String
    let icon: String?
    let action: () -> Void
    let background: Color
    let foreground: Color
    var body: some View {
        Button(action: action) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(label)
                    .fontWeight(.semibold)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(background)
            .foregroundColor(foreground)
            .cornerRadius(10)
            .shadow(color: background.opacity(0.13), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ContentView: View {
    @StateObject private var model = SoundDeckModel()
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showingFileImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var currentlyPlaying: String? = nil
    @State private var lastPlayed: String? = nil
    @State private var waveformSamples: [Float]? = nil
    
    var body: some View {
        GeometryReader { geometry in
            let minCardWidth: CGFloat = 170
            let spacing: CGFloat = 14
            let availableWidth = geometry.size.width - 48 // account for padding
            let columnsCount = max(Int((availableWidth + spacing) / (minCardWidth + spacing)), 1)
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnsCount)
            ZStack {
                Color.mdDark.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("Sound Deck", systemImage: "music.note.list")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(Color.mdCream)
                        Spacer()
                        MaterialButton(label: "Add Sound", icon: "plus.circle.fill", action: { showingFileImporter = true }, background: Color.mdTeal, foreground: Color.mdCream)
                    }
                    .padding([.top, .horizontal])
                    if let waveformSamples = waveformSamples {
                        WaveformView(samples: waveformSamples, color: .mdTeal)
                            .frame(height: 56)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    } else {
                        Rectangle()
                            .fill(Color.mdGrey.opacity(0.18))
                            .frame(height: 56)
                            .cornerRadius(8)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                    Spacer().frame(height: 7)
                    Text("Add audio files and play them with a click. Click any sound below to play. Use the stop button or press Space to stop playback. Press Enter to replay the last sound.")
                        .font(.headline)
                        .foregroundColor(Color.mdTeal)
                        .padding(.horizontal)
                    Spacer().frame(height: 15)
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: spacing) {
                            ForEach(model.sounds) { sound in
                                MaterialCard {
                                    SoundButtonView(
                                        sound: sound,
                                        isPlaying: currentlyPlaying == sound.name,
                                        isLastPlayed: lastPlayed == sound.name,
                                        playAction: { playSound(sound) },
                                        removeAction: {
                                            if let idx = model.sounds.firstIndex(of: sound) {
                                                model.sounds.remove(at: idx)
                                                model.saveSounds()
                                            }
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        MaterialButton(label: "Stop", icon: "stop.circle.fill", action: stopSound, background: Color.mdGrey, foreground: Color.mdCream)
                        Spacer()
                    }
                    .padding(.bottom, 20)
                }
                .padding(24)
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        print("[DEBUG] url: \(url), isFileURL: \(url.isFileURL), path: \(url.path)")
                        do {
                            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                            let newSound = SoundItem(name: url.lastPathComponent, bookmarkData: bookmark)
                            model.sounds.append(newSound)
                            model.saveSounds()
                            print("[DEBUG] Created bookmark for: \(url.path)")
                        } catch {
                            print("[DEBUG] Failed to create bookmark for \(url.path): \(error)")
                            alertMessage = "Failed to add sound: \(error.localizedDescription)"
                            showAlert = true
                        }
                    }
                case .failure(let error):
                    print("Failed to import file: \(error)")
                    alertMessage = "Failed to import file: \(error.localizedDescription)"
                    showAlert = true
                }
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
            .frame(minWidth: 600, minHeight: 500)
            .background(KeyboardSpaceEnterHandler(onSpace: stopSound, onEnter: replayLastSound))
        }
    }
    
    private func playSound(_ sound: SoundItem) {
        guard let url = sound.fileURL else {
            print("Could not resolve file URL for sound: \(sound.name)")
            return
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        print("[DEBUG] startAccessingSecurityScopedResource: \(didStartAccessing) for \(url.path)")
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let fileManager = FileManager.default
            guard fileManager.isReadableFile(atPath: url.path) else {
                print("File is not readable at path: \(url.path)")
                return
            }
            print("[DEBUG] Attempting to play: \(url.path)")
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            currentlyPlaying = sound.name
            lastPlayed = sound.name
            print("[DEBUG] Playback started for: \(url.lastPathComponent)")
            // Analyze waveform (async)
            let asset = AVAsset(url: url)
            asset.waveformSamples(sampleCount: 500) { samples in
                DispatchQueue.main.async {
                    self.waveformSamples = samples
                }
            }
        } catch {
            print("Could not play sound: \(error)")
        }
    }
    
    private func stopSound() {
        audioPlayer?.stop()
        currentlyPlaying = nil
        waveformSamples = nil
    }
    
    private func replayLastSound() {
        if let lastName = lastPlayed, let sound = model.sounds.first(where: { $0.name == lastName }) {
            playSound(sound)
        }
    }
}

struct SoundButtonView: View {
    let sound: SoundItem
    let isPlaying: Bool
    let isLastPlayed: Bool
    let playAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: playAction) {
                HStack {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : (isLastPlayed ? "arrow.counterclockwise.circle.fill" : "play.circle.fill"))
                        .foregroundColor(isPlaying ? Color.mdTeal : (isLastPlayed ? Color.mdGrey : Color.mdDark))
                        .font(.title3)
                    Text(sound.name)
                        .font(.subheadline)
                        .foregroundColor(Color.mdDark)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                Button("Remove", role: .destructive, action: removeAction)
            }
        }
        .padding(.vertical, 1)
    }
}

// Keyboard handler for space and enter keys
struct KeyboardSpaceEnterHandler: NSViewRepresentable {
    let onSpace: () -> Void
    let onEnter: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = KeyboardCatcherView()
        view.onSpace = onSpace
        view.onEnter = onEnter
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    class KeyboardCatcherView: NSView {
        var onSpace: (() -> Void)?
        var onEnter: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 { // space bar
                onSpace?()
            } else if event.keyCode == 36 { // enter/return
                onEnter?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
