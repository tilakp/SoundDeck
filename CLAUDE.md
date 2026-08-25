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

To run all tests, type the command that follows. The two test targets contain only empty examples.

```bash
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' test
```

To run one test, type the command that follows. The target `SoundDeckTests` uses Swift Testing with `@Test` and `#expect`.

```bash
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -destination 'platform=macOS' \
  -only-testing:SoundDeckTests/SoundDeckTests/example test
```

To do a quick type check, type `swift build`.

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

The type `BookmarkFlavor` is in `SoundItem.swift`. It tries a security-scoped bookmark first. It uses a plain bookmark only if the first operation fails. It records the type of each bookmark.

You must resolve a bookmark with the same option that created it. The property `SoundItem.isSecurityScoped` holds this option.

A build with a Team ID uses security-scoped bookmarks again. The file `SoundDeck.entitlements` lists the keys to add.

## Architecture

The data flows in one direction. The type `SoundLibrary` holds the contents of the deck. The type `AudioEngine` holds the audio state. The views read both types.

### SoundItem.swift

This file holds the model and the type `BookmarkFlavor`.

The decoder reads each new field with `decodeIfPresent`. A strict decoder rejects an older library file. A rejected file deletes the deck of the user. Keep this method when you add a field.

### SoundLibraryStore.swift

This file writes JSON to `~/Library/Application Support/SoundDeck/library.json`. The write is atomic.

Do not use `UserDefaults`. `UserDefaults` is a preferences store. A change to the sandbox status replaces the container. An earlier build lost its library for this reason.

The store keeps an unreadable file as `library-corrupt-*.json`. It does not overwrite the file. The store migrates the old `UserDefaults` key one time.

### SoundLibrary.swift

This file adds, removes, reorders and renames sounds. It also assigns hotkeys and does searches.

The function `resolve()` saves a refreshed bookmark when macOS reports a stale bookmark.

### AudioEngine.swift

This file holds an `AVAudioEngine` graph. Each trigger creates one voice. Therefore sounds play at the same time.

The graph is:

`AVAudioPlayerNode` to `AVAudioMixerNode` (voice gain and fade) to `mainMixerNode` (master gain) to `outputNode` (routable).

The engine attaches a voice at playback. The engine detaches the voice at retirement. Always use the function `retire()`. This function releases the security scope. It also clears the pad state after the last voice of a sound stops.

The engine pauses when it is idle. This releases the output device.

### AudioDevice.swift

This file lists the CoreAudio output devices. It marks the probable virtual devices such as BlackHole and Loopback.

The application sets the output device with `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`. This operation is possible only when the engine is stopped.

### GlobalHotKeys.swift

This file uses the Carbon function `RegisterEventHotKey`.

Do not use `NSEvent.addGlobalMonitorForEvents`. That function needs Accessibility permission. That function also receives all keystrokes of the system. The Carbon function needs no permission. The Carbon function receives only the registered combinations.

The C callback has no user data parameter. Therefore the dispatch table is in a singleton. The key of the table is the hotkey ID.

### Theme.swift

This file holds the palette, the chrome and the motion values.

The surfaces are opaque. Do not use `.ultraThinMaterial`. On macOS a material samples the content behind the window. Above a bright desktop, a material makes the dark theme grey.

### Views

The views are `ContentView`, `SoundTile`, `SoundInspector` and `MenuBarDeck`.

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
