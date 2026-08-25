# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Sound Deck is a native macOS SwiftUI soundboard: a grid of pads that play audio instantly, with global hotkeys, a menu bar deck, and selectable audio output so the sounds can be routed into conferencing and streaming apps.

`PRODUCT_BUNDLE_IDENTIFIER` is **`com.patelt.SoundDeck`**. The `Info.plist` at the repo root says `com.cascade.SoundDeck` and is **vestigial** — Xcode 16 synced folders generate their own, so that file is not the one that ships. `MACOSX_DEPLOYMENT_TARGET` is **14.6** (the README's claim of 13.0 is stale). `Package.swift` mirrors this as `.macOS(.v14)` and must be kept in sync; when they drift, SourceKit type-checks against the wrong SDK floor and reports availability errors the real Xcode build does not.

## Build & Test

```bash
# Build (preferred — this is what actually ships)
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -configuration Debug build

# Tests (both targets are still placeholder skeletons)
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' test

# A single test (SoundDeckTests uses Swift Testing: @Test / #expect)
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' \
  -only-testing:SoundDeckTests/SoundDeckTests/example test

# Fast type-check only
swift build
```

`Package.swift` is a **type-check aid only**. It has no entitlements, asset catalog, or bundled sounds, so playback and import do not work under `swift run`. It is scoped to the `SoundDeck/` directory — globbing the repo root previously compiled the test targets into the app module.

To watch debug output, run the built binary directly rather than through Xcode:

```bash
~/Library/Developer/Xcode/DerivedData/SoundDeck-*/Build/Products/Debug/SoundDeck.app/Contents/MacOS/SoundDeck
```

`SoundDeckApp.init` calls `setvbuf(stdout, nil, _IONBF, 0)` because `print` is block-buffered when stdout is a pipe, which silently swallows all output when launched from a script.

## Signing and the sandbox — read before touching entitlements

**The app is deliberately unsandboxed.** This is not an oversight, and re-enabling the sandbox without also fixing signing will break audio import.

The target signs ad-hoc (`CODE_SIGN_IDENTITY = "-"`, no `DEVELOPMENT_TEAM`). App-scoped security bookmarks bind to the app's code-signing identity, and an ad-hoc signature has none to bind to, so `URL.bookmarkData(options: .withSecurityScope)` fails with `NSCocoaErrorDomain 256 "Could not open() the item"` — even though the file is readable and the security scope opens successfully. Under the sandbox a *plain* bookmark cannot restore access across launches, so a sandboxed ad-hoc build loses every imported sound on relaunch.

`BookmarkFlavor` (in `SoundItem.swift`) therefore tries a security-scoped bookmark first and falls back to a plain one, recording which flavour it used per sound. **A bookmark must be resolved with the same option it was created with** — hence `SoundItem.isSecurityScoped`. A build signed with a real Team ID picks the scoped path back up automatically; `SoundDeck.entitlements` documents the keys to restore.

## Architecture

Data flows one way: `SoundLibrary` owns what's in the deck, `AudioEngine` owns what's making noise, and views read both.

- **`SoundItem.swift`** — the model, plus `BookmarkFlavor`. Every field added since v1 is decoded with `decodeIfPresent`; a strict decoder would reject older libraries and silently wipe someone's deck. Keep that discipline when adding fields.
- **`SoundLibraryStore.swift`** — JSON in `~/Library/Application Support/SoundDeck/library.json`, written atomically. Deliberately *not* `UserDefaults`: that is a preferences store, and a sandbox transition swaps it for a different container, which is how an earlier build appeared to lose its library. An unreadable file is preserved as `library-corrupt-*.json` rather than overwritten. Migrates from the legacy `UserDefaults` key once.
- **`SoundLibrary.swift`** — add / remove / reorder / rename / hotkey assignment / search. `resolve()` persists refreshed bookmarks when macOS reports one stale.
- **`AudioEngine.swift`** — an `AVAudioEngine` graph, one *voice* per trigger, so sounds layer:
  `AVAudioPlayerNode → AVAudioMixerNode (per-voice gain, fade) → mainMixerNode (master) → outputNode (routable)`.
  Voices are attached on play and detached on retire. Callers must go through `retire()` so the security scope is released and the badge clears only when a sound's *last* voice ends. The engine pauses when idle to release the output device.
- **`AudioDevice.swift`** — CoreAudio output enumeration, flagging likely virtual devices (BlackHole, Loopback). Output routing is set via `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` and **only works while the engine is stopped**.
- **`GlobalHotKeys.swift`** — Carbon `RegisterEventHotKey`, deliberately not `NSEvent.addGlobalMonitorForEvents`: the monitor needs Accessibility permission and sees every keystroke system-wide. Carbon needs no permission and only fires for registered combos. The C callback has no user-data parameter, so dispatch goes through a singleton keyed by hotkey id.
- **`Theme.swift`** — palette, chrome, motion. Surfaces are **opaque, not `.ultraThinMaterial`**: on macOS a material samples whatever is behind the *window*, so over a bright desktop it washes the dark theme out to grey.
- **`ContentView` / `SoundTile` / `SoundInspector` / `MenuBarDeck`** — the views. `SoundLibrary` and `AudioEngine` are owned by `SoundDeckApp` so the window and menu bar drive one deck, not two copies.

Cross-cutting things that will bite:

- Playback state is keyed by `SoundItem.id`, never by filename — duplicate names used to highlight each other.
- `WaveformView`'s decoder reduces to an envelope *while reading*; do not go back to accumulating every frame, as a few minutes of 48kHz stereo is tens of millions of floats.
- Bucket sizes in waveform code must be floored at 1. `stride(by: 0)` traps, which crashed on clips shorter than the sample target and at zero layout width.
- Debug logging is `print("[DEBUG] …")`; there is no logging framework.

## Icon

Generated, not hand-drawn. The CoreGraphics script renders each size natively rather than downscaling a 1024 master, so the glyph stays crisp at 16pt. Regenerate with:

```bash
swift Tools/MakeIcon.swift <output-dir>
cp <output-dir>/*.png SoundDeck/Assets.xcassets/AppIcon.appiconset/
```

The catalog references a duplicate `icon_32x32 1.png` for the 16pt @2x slot; the script writes it.
