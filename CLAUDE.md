# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Sound Deck is a native macOS SwiftUI soundboard app: a grid of buttons that instantly play user-added or bundled audio files. Bundle identifier `com.cascade.SoundDeck`. `MACOSX_DEPLOYMENT_TARGET` is **14.6** (the README's claim of 13.0 is stale). `Package.swift` mirrors this as `.macOS(.v14)` and must be kept in sync — when they drift, SourceKit type-checks against the wrong SDK floor and reports availability errors that the real Xcode build does not.

There are two parallel build definitions for the same sources:
- `SoundDeck.xcodeproj` — the real way to build/run/test the app (has entitlements, asset catalog, code signing).
- `Package.swift` — a minimal SwiftPM executable target over the same sources, useful only for a fast `swift build` type-check. It carries no entitlements, asset catalog, or bundled sounds, so the sandboxed file-picker and playback paths do not work under `swift run`. Its `sources:` list is explicit — add new files there as well as to the Xcode target (globbing the repo root previously compiled the test targets into the app module).

## Build & Test Commands

Building and running requires Xcode (SwiftUI/AppKit macOS app), not just the Swift toolchain:

```bash
# Build via Xcode project (preferred — matches how the app is actually shipped)
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -configuration Debug build

# Run all tests (unit + UI)
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' test

# Run a single test (Swift Testing framework, used by SoundDeckTests)
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' \
  -only-testing:SoundDeckTests/SoundDeckTests/example test

# Quick type-check/build via SwiftPM (does not produce a runnable sandboxed app)
swift build
```

For interactive development/debugging, open `SoundDeck.xcodeproj` in Xcode and use Cmd+R / Cmd+U — this is the workflow the README assumes and the most reliable way to exercise sandboxed file-picker and audio-playback behavior.

There are two test targets: `SoundDeckTests` (unit tests, Swift Testing `@Test`/`#expect`) and `SoundDeckUITests` (XCUITest). Both are currently placeholder/skeleton tests.

## Architecture

The app is a single-window SwiftUI app with three source files under `SoundDeck/`:

- **`SoundDeckModel.swift`** — `SoundDeckModel: ObservableObject` owns the `[SoundItem]` list and is the persistence layer. `SoundItem` is a `Codable` struct representing either a bundled sound (`isBundled: true`, resolved at playback time via `Bundle.main.resourceURL`) or a user-imported sound (`isBundled: false`, resolved via a security-scoped bookmark stored in `bookmarkData`). The model round-trips the sound list through `UserDefaults` (key `SoundDeckSounds`) as JSON — there is no separate database. On first launch (empty saved list), it seeds itself from bundled `.wav`/`.aiff` files found in the app's resource directory (see `sounds/` at the repo root, which get bundled as resources).
- **`ContentView.swift`** — the entire UI and playback/import logic in one file: the responsive `LazyVGrid` of sound buttons, the "Material"-styled design system (`MaterialCard`, `MaterialButton`, custom `mdDark`/`mdGrey`/`mdTeal`/`mdCream` palette), the `fileImporter` flow for adding new sounds (creates a security-scoped bookmark directly, duplicating logic also present in `SoundDeckModel.addSound`), `AVAudioPlayer`-based playback (`playSound`/`stopSound`/`replayLastSound`), and an `NSViewRepresentable` (`KeyboardSpaceEnterHandler`) that intercepts Space (stop) and Enter (replay last) at the AppKit level since SwiftUI has no native global key handling for this on macOS.
- **`WaveformView.swift`** — draws the live waveform for the currently playing sound, and an `AVAsset` extension (`waveformSamples`) that decodes PCM samples via `AVAssetReader` and downsamples them asynchronously for display. `ContentView` calls this after starting playback and stores the result in `@State var waveformSamples`.

Key cross-cutting behaviors to keep in mind when touching playback or file-import code:
- Every file-backed sound access requires bracketing with `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` (see `playSound` in ContentView.swift) — bundled sounds don't need this since they're resolved via `Bundle.main`.
- Sound identity for UI state (`currentlyPlaying`, `lastPlayed`) is tracked by `sound.name` (filename), not `id`, so duplicate filenames will collide in playback-state highlighting.
- Adding a sound happens in two places (`ContentView`'s `fileImporter` handler and `SoundDeckModel.addSound`) with near-duplicate bookmark-creation logic — check both if changing the import flow.
- Debug logging throughout uses `print("[DEBUG] ...")`; there's no logging framework.
