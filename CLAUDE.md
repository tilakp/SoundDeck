# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Writing style

Write all documentation, code comments and commit messages in ASD-STE100 (Simplified Technical English).

Obey these rules:

- Do not use em dashes. Use a period, a colon, a semicolon or a comma. If a sentence needs an em dash, write two sentences.
- Keep procedural sentences to 20 words or fewer. Keep descriptive sentences to 25 words or fewer.
- Write one instruction per sentence.
- Use the active voice.
- Use the imperative for steps.
- Use one word for one meaning.
- Keep noun clusters to three words or fewer.
- Keep paragraphs to six sentences or fewer.

## Project

Sound Deck is a soundboard for macOS. It uses SwiftUI. It has a grid of pads that play audio files. It has global hotkeys, a menu bar deck and a selectable output device.

The value of `PRODUCT_BUNDLE_IDENTIFIER` is `com.patelt.SoundDeck`.

The file `Info.plist` in the repository root gives `com.cascade.SoundDeck`. This file is obsolete. Xcode 16 synced folders create their own `Info.plist`. The build does not use the file in the root.

The value of `MACOSX_DEPLOYMENT_TARGET` is 14.6.

The file `Package.swift` gives the same value as `.macOS(.v14)`. Keep the two values the same. If the values are different, SourceKit uses the incorrect SDK level. SourceKit then reports availability errors. The Xcode build does not report these errors.

## Build and test

To build the application, type the command that follows. This command builds the application that ships.

```bash
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -configuration Debug build
```

To run all tests, type the command that follows. The target `SoundDeckTests` tests the store, the library, the decks and the deck files. The UI test target contains only empty examples.

```bash
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' test
```

To run one test, type the command that follows. The target `SoundDeckTests` uses Swift Testing with `@Test` and `#expect`.

```bash
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' \
  -only-testing:SoundDeckTests/SoundDeckTests/example test
```

To do a quick type check, type `swift build`.

GitHub Actions runs the unit tests for each push to `main` and each pull request. The workflow is `.github/workflows/ci.yml`.

If `xcodebuild` reports that the developer directory is a command line tools instance, put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` before the command.

The file `Package.swift` is a type check aid only. It has no entitlements, no asset catalog and no bundled sounds. Playback and import do not operate with `swift run`. The target includes only the `SoundDeck/` directory. A previous version included the repository root. That version compiled the test targets into the application module.

To see debug output, run the binary directly. Do not use Xcode.

```bash
~/Library/Developer/Xcode/DerivedData/SoundDeck-*/Build/Products/Debug/SoundDeck.app/Contents/MacOS/SoundDeck
```

The function `SoundDeckApp.init` calls `setvbuf(stdout, nil, _IONBF, 0)`. The function `print` uses block buffering when stdout is a pipe. Without this call, a script launch loses all output.

## Signing and the sandbox

Read this section before you change the entitlements.

The application does not use the App Sandbox. This is deliberate. If you enable the sandbox and do not also change the signature, audio import stops.

The target uses an ad-hoc signature. The value of `CODE_SIGN_IDENTITY` is `-`. There is no `DEVELOPMENT_TEAM`.

The system attaches an app-scoped security bookmark to the code signature. An ad-hoc signature has no identity. Therefore `URL.bookmarkData(options: .withSecurityScope)` fails. The error is `NSCocoaErrorDomain 256 "Could not open() the item"`. The file is readable. The security scope opens correctly. The operation still fails.

A plain bookmark cannot restore access in the sandbox. A sandboxed build with an ad-hoc signature loses all imported sounds at the next start.

The application copies each new import into the library directory. Thus new pads have no bookmark. At start, the library copies the files of pads from earlier builds. A pad keeps its bookmark only when its file is missing.

The type `BookmarkFlavor` is in `SoundItem.swift`. It refreshes the stale bookmarks of these old pads. You must resolve a bookmark with the same option that created it. The property `SoundItem.isSecurityScoped` holds this option.

A build with a Team ID uses security-scoped bookmarks again. The file `SoundDeck.entitlements` lists the keys to add.

## Architecture

The data flows in one direction. The type `SoundLibrary` holds the contents of the deck. The type `AudioEngine` holds the audio state. The views read both types.

### SoundItem.swift

This file holds the model and the type `BookmarkFlavor`.

A pad has one of three sources. A bundled pad reads `Resources/<fileName>`. A copied pad reads `Sounds/<id>/<fileName>` in the library directory. An old pad reads its bookmark. The display name is `name`. A rename does not change `fileName`.

The decoder reads each new field with `decodeIfPresent`. A strict decoder rejects an older library file. A rejected file deletes the deck of the user. Keep this method when you add a field.

### Deck.swift

A deck is a named list of pads. The keys 1 to 0 and the global hotkeys play the pads of the active deck only. Each deck has its own keys.

### SoundLibraryStore.swift

This file writes JSON to `~/Library/Application Support/SoundDeck/library.json`. The write is atomic.

Version 2 of the file holds the decks and the active deck. The store reads a version 1 file as one deck with the name "Main". The directory `Sounds/` holds the copied audio files. Tests give the store a temporary directory.

Do not use `UserDefaults`. `UserDefaults` is a preferences store. A change to the sandbox status replaces the container. An earlier build lost its library for this reason.

The store keeps an unreadable file as `library-corrupt-*.json`. It does not overwrite the file. The store migrates the old `UserDefaults` key one time.

One bad pad does not stop the load. The type `Lossy` skips the bad pad, and the store keeps a copy of the original file. If the store cannot keep a copy, it stops saving. A save would then replace the only copy of the deck of the user.

### SoundLibrary.swift

This file adds, removes, reorders and renames sounds. It also assigns hotkeys and does searches. It adds, selects, renames and removes decks.

The property `sounds` gives the pads of the active deck. The function `sound(withID:)` finds a pad in any deck. A pad from another deck can still play.

When you remove a pad or a deck, the library deletes the copied files.

The function `resolve()` saves a refreshed bookmark when macOS reports a stale bookmark.

### AudioEngine.swift

This file holds an `AVAudioEngine` graph. Each trigger creates one voice. Therefore sounds play at the same time.

The graph is:

`AVAudioPlayerNode` to `AVAudioMixerNode` (voice gain, loudness gain and fade) to `mainMixerNode` (master gain) to the peak limiter to `outputNode` (routable).

The voice mixer volume can be more than 1. A value of 4 gives +12 dB. The limiter is Apple's AUPeakLimiter. It stops clipping when several loud voices play together.

The engine attaches a voice at playback. The engine detaches the voice at retirement. Always use the function `retire()`. This function releases the security scope. It also clears the pad state after the last voice of a sound stops.

The engine pauses when it is idle. This releases the output device.

The engine stops when the output device changes or the Mac sleeps. The engine then retires all voices and routes again. It also routes again when a device is added or removed, or when the system default changes. If the selected device is missing, the engine uses the system default. It keeps the selection, so it goes back when the device returns.

After a change of device, the engine connects the main mixer again at the sample rate of the device. Without this, a device with another rate can fail or play no sound.

The function `trimWindow` holds the trim math. It is a pure function, so the tests can call it.

### Loudness.swift

This file measures integrated loudness with ITU-R BS.1770 and the sample peak. A mono file counts as dual mono, because the engine plays it on both channels.

The function `gain` moves a pad to -18 LUFS. The boost is not more than +12 dB, and the peak does not go above -1 dBFS. The library measures pads in the background at start and after each import. A pad without a measurement plays at its user volume.

### DeckArchive.swift

This file exports a deck to one `.sounddeck` file and imports it. The file is JSON. It holds the settings and the Base64 audio of each pad. An import gives each pad a new id. It keeps each copy in the directory of its pad, also when the file name has `..` in it.

### Recorder.swift

This file records from the default input device to an AAC file. It has its own `AVAudioEngine`. A mixer converts the input to mono or stereo. The main mixer is muted, so the microphone does not go to the speakers.

The build setting `INFOPLIST_KEY_NSMicrophoneUsageDescription` holds the text of the permission prompt. Without it, macOS stops the application when it asks for the microphone.

### AudioDevice.swift

This file lists the CoreAudio output devices. It marks the probable virtual devices such as BlackHole and Loopback.

The application sets the output device with `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`. This operation is possible only when the engine is stopped.

### GlobalHotKeys.swift

This file uses the Carbon function `RegisterEventHotKey`.

Do not use `NSEvent.addGlobalMonitorForEvents`. That function needs Accessibility permission. That function also receives all keystrokes of the system. The Carbon function needs no permission. The Carbon function receives only the registered combinations.

The C callback has no user data parameter. Therefore the dispatch table is in a singleton. The key of the table is the hotkey ID.

The modifiers are ⌃⌥. VoiceOver uses ⌃⌥ for its own commands. While VoiceOver is on, the modifiers are ⌃⌥⌘.

### HotKeyBinder.swift

This file registers the global hotkeys of the active deck. It registers again only when the keys change, or when VoiceOver starts or stops. The application owns the binder, not the window. Thus the keys also change when the window is closed.

### Theme.swift

This file holds the palette, the chrome and the motion values.

The surfaces are opaque. Do not use `.ultraThinMaterial`. On macOS a material samples the content behind the window. Above a bright desktop, a material makes the dark theme grey.

### Views

The views are `ContentView`, `SoundTile`, `SoundInspector`, `RecorderSheet` and `MenuBarDeck`.

The deck bar in `ContentView` shows the decks, the menu for new and imported decks, and the Record button. The context menu of a deck has Rename, Export and Delete.

The type `SoundDeckApp` owns `SoundLibrary` and `AudioEngine`. Therefore the window and the menu bar use the same deck.

## Cautions

- The playback state uses `SoundItem.id`. Do not use the file name. Two files with the same name showed the same state.
- The decoder in `WaveformView` makes an envelope during the read. Do not collect all frames. Some minutes of 48 kHz stereo audio give tens of millions of float values.
- Set a minimum of 1 for each bucket size in the waveform code. The function `stride(by: 0)` causes a trap. This trap occurred with short clips and with zero layout width.
- Debug output uses `print("[DEBUG] …")`. There is no logging framework.

## Icon

A script creates the icon. The script renders each size directly. It does not scale down a 1024 pixel image. Therefore the glyph stays sharp at 16 points.

To create the icon files, type the commands that follow.

```bash
swift Tools/MakeIcon.swift <output-dir>
cp <output-dir>/*.png SoundDeck/Assets.xcassets/AppIcon.appiconset/
```

The asset catalog uses a second copy of the 32 pixel file with the name `icon_32x32 1.png`. This copy fills the 16 point 2x slot. The script writes this copy.

## Bundled sounds

A script creates the nine files in `sounds/`. The page `Tools/MakeSounds.html` holds a copy of the Web Audio synthesis of the demo on quietpixel.dev. The script opens this page in headless Chrome and writes 16-bit mono WAV files.

To create the sound files, type the commands that follow.

```bash
node Tools/MakeSounds.mjs <output-dir>
cp <output-dir>/*.wav sounds/
```

The list `bundledOrder` in `SoundLibrary.swift` sets the order of the pads. If you change a file name, change the list also.

At start, `SoundLibrary` removes the pads of bundled files that are missing. It then adds the bundled sounds that are not in the deck. This keeps a library from an earlier version correct.
