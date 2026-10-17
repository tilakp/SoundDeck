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

Sound Deck is a soundboard for macOS. It uses SwiftUI. It has decks of pads that play audio files. It has global hotkeys, a menu bar deck, a floating deck and a selectable output device. Other apps and devices control it through a URL scheme, Shortcuts, OSC, MIDI, a web remote, Twitch chat and a Stream Deck plugin.

The value of `PRODUCT_BUNDLE_IDENTIFIER` is `com.patelt.SoundDeck`.

The file `Info.plist` in the repository root gives `com.cascade.SoundDeck`. This file is obsolete. Xcode 16 synced folders create their own `Info.plist`. The build does not use the file in the root.

The value of `MACOSX_DEPLOYMENT_TARGET` is 14.6.

The file `Package.swift` gives the same value as `.macOS(.v14)`. Keep the two values the same. If the values are different, SourceKit uses the incorrect SDK level. SourceKit then reports availability errors. The Xcode build does not report these errors.

## Build and test

To build the application, type the command that follows. This command builds the application that ships.

```bash
xcodebuild -project SoundDeck.xcodeproj -scheme SoundDeck -configuration Debug build
```

To run all tests, type the command that follows. The target `SoundDeckTests` has more than 200 tests. Each area has its own test file. The UI test target contains only empty examples.

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

When the app hosts the unit tests, `SoundDeckApp.isRunningTests` is true. The app then uses a temporary library. It starts no remote controls, no global hotkeys and no floating deck. Do not remove this check. Without it, a test run changes the deck of the user.

The test host opens its own window. Before you capture a window for a UI check, find the window by the process ID of your own app.

When several builds run at the same time, give each one its own `-derivedDataPath`.

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

A deck shows a grid or a cue list. `Deck.layout` holds the choice. A locked deck (`isLocked`) refuses changes. `Deck` has an explicit `CodingKeys` list, because `cueIndex` is runtime state that the file does not keep. Add each new stored field to that list. If you do not, the field is not saved.

### SoundLibraryStore.swift

This file writes JSON to `~/Library/Application Support/SoundDeck/library.json`. The write is atomic.

Version 2 of the file holds the decks and the active deck. The store reads a version 1 file as one deck with the name "Main". In version 3, pad names have no file extension. The library removes the extension one time from each name that the user did not change. The file also holds the Recent list. The directory `Sounds/` holds the copied audio files. Tests give the store a temporary directory.

Do not use `UserDefaults`. `UserDefaults` is a preferences store. A change to the sandbox status replaces the container. An earlier build lost its library for this reason.

The store keeps an unreadable file as `library-corrupt-*.json`. It does not overwrite the file. The store migrates the old `UserDefaults` key one time.

One bad pad does not stop the load. The type `Lossy` skips the bad pad, and the store keeps a copy of the original file. If the store cannot keep a copy, it stops saving. A save would then replace the only copy of the deck of the user.

### SoundLibrary.swift

This file adds, removes, reorders and renames sounds. It also assigns hotkeys and does searches. It adds, selects, renames and removes decks.

The property `sounds` gives the pads of the active deck. The function `sound(withID:)` finds a pad in any deck. A pad from another deck can still play.

When you remove a pad or a deck, the library deletes the copied files.

The function `resolve()` saves a refreshed bookmark when macOS reports a stale bookmark.

A locked deck refuses changes to its pads and to the deck. The guards are in `SoundLibrary`, so every path obeys them. A favorite mark is the only change that a locked deck accepts.

A search and the smart decks Favorites and Recent show pads from all decks. These views are read-only. The keys always use `activeDeckID`. The library records the last 20 played pads. It observes `AudioEngine.lastPlayedID` with Combine.

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

All triggers of a pad call `trigger`. This function applies the play mode: Play over, Restart, Toggle or Hold. The key release and the mouse release call `release`, which stops a Hold pad. The inspector preview calls `play`, so it always plays.

A pad with a choke group stops the other pads in its group. While a pad with `ducksOthers` plays, the other pads go down to `duckLevel` (-12 dB).

A pad that changes its pitch or speed gets an `AVAudioUnitTimePitch` between the player and the voice mixer. Other pads do not get this node.

A pad with an EQ that is not flat gets one `AVAudioUnitEQ` in each branch. The chain is player, time-pitch, EQ, voice mixer. A flat EQ gets no node. The loudness measurement does not include the EQ. A change to the EQ applies at the next trigger.

A failed play goes to `recordFailure`. It fills `lastError` and `padErrors`. The views mark a failed pad in place. A live show gets no modal alert.

The map `Playhead.padProgress` holds the progress of each playing pad. Only small subviews observe it. Do not observe `Playhead` in a tile or in the grid. If you do, the grid draws again 30 times each second.

### AudioRouting.swift, MonitorOutput.swift and MicPassThrough.swift

A voice can play on two outputs. Live is the deck output. Monitor is a second device, for example headphones. `MonitorOutput` has its own engine. A voice gets a monitor branch only when its pad plays on the monitor. The pad field `output` selects Both, Live or Me only.

The two branches start at one host time. The faster output waits for the slower output. The voice retires after the last branch ends. Long loops on two devices can drift, because the device clocks are not locked. A missing monitor turns the monitor off. It does not fall back to the system default, because that can be the call device.

The microphone pass-through uses a separate input engine and `MicRingBuffer`. An `AVAudioSourceNode` reads the queue into the Live bus, before the limiter. The microphone does not go to the monitor. While the microphone is on, the deck engine does not pause.

### VoiceEnvelope.swift

This file holds the fade and duck state of one voice. It is a pure value, so the tests can step it. One engine timer steps all envelopes about 100 times each second, only while a fade or a duck change runs. The voice gain is the user volume times the loudness gain times the envelope gain.

### Loudness.swift

This file measures integrated loudness with ITU-R BS.1770 and the sample peak. A mono file counts as dual mono, because the engine plays it on both channels.

The function `gain` moves a pad to -18 LUFS. The boost is not more than +12 dB, and the peak does not go above -1 dBFS. The library measures pads in the background at start and after each import. A pad without a measurement plays at its user volume.

### DeckArchive.swift

When you add a field to `SoundItem`, add it to `DeckArchive.Entry` as an optional too. If you do not, export loses the setting.

This file exports a deck to one `.sounddeck` file and imports it. The file is JSON. It holds the settings and the Base64 audio of each pad. An import gives each pad a new id. It keeps each copy in the directory of its pad, also when the file name has `..` in it.

### Recorder.swift

This file records from the default input device to an AAC file. It has its own `AVAudioEngine`. A mixer converts the input to mono or stereo. The main mixer is muted, so the microphone does not go to the speakers.

The build setting `INFOPLIST_KEY_NSMicrophoneUsageDescription` holds the text of the permission prompt. Without it, macOS stops the application when it asks for the microphone.

After the stop, the Record sheet shows the recording in a `TrimTrack`. "Add to Deck" saves the trim as `trimStart` and `trimEnd`. The file stays complete. The type `RecordingTrim` holds the pure trim and time functions. Space starts and stops the recording, except when the name field has focus.

### SpeechPad.swift and SpeechPadSheet.swift

The sheet makes a pad that speaks a phrase. It uses the system voices, which work offline. `SpeechRenderer` writes the PCM buffers of `AVSpeechSynthesizer.write` to a CAF file. An empty buffer ends the stream. The library then moves the file in with `addRecording(at:name:)`.

### FreesoundClient.swift and FreesoundSheet.swift

These files search freesound.org with token authentication. The API key is in the keychain. Do not use `UserDefaults` for the key. Token authentication cannot download the original file. Therefore a pad gets the HQ preview, a 128 kbps MP3. Each pad from Freesound keeps a credit in `SoundItem.credit`. CC BY sounds need this credit.

### AudioDevice.swift

This file lists the CoreAudio output devices. It marks the probable virtual devices such as BlackHole and Loopback.

The application sets the output device with `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`. This operation is possible only when the engine is stopped.

### GlobalHotKeys.swift

This file uses the Carbon function `RegisterEventHotKey`.

Do not use `NSEvent.addGlobalMonitorForEvents`. That function needs Accessibility permission. That function also receives all keystrokes of the system. The Carbon function needs no permission. The Carbon function receives only the registered combinations.

The handler receives the press and the release of each key. A Hold pad needs the release.

The C callback has no user data parameter. Therefore the dispatch table is in a singleton. The key of the table is the hotkey ID.

The modifiers are ⌃⌥. VoiceOver uses ⌃⌥ for its own commands. While VoiceOver is on, the modifiers are ⌃⌥⌘.

### HotKeyBinder.swift

This file registers the global hotkeys of the active deck. It registers again only when the keys change, or when VoiceOver starts or stops. The application owns the binder, not the window. Thus the keys also change when the window is closed.

### DeckCommands.swift

This file is the one entry point for all remote controls. A query finds a pad by id, name, key or name prefix, in the active deck first. Each command triggers through the engine, so the play mode, the choke group and ducking apply. Do not add lookup logic to a remote control. Use `DeckCommands.shared`.

### DeckURL.swift, AppDelegate.swift and SoundDeckIntents.swift

`DeckURL` reads `sounddeck://` URLs. `AppDelegate` receives them through a `kAEGetURL` handler. Do not use `onOpenURL`, because it can open a new window. SwiftUI allows only one `NSApplicationDelegateAdaptor`. Add app delegate work to `AppDelegate`.

The file `Config/SoundDeck-Info.plist` registers the scheme. Xcode merges it into the generated plist. Keep this file outside `SoundDeck/`. If it is inside, the synced folder copies it as a resource.

The intents in `SoundDeckIntents.swift` give Shortcuts the actions Play Pad, Stop Pad, Stop All Pads and Select Deck.

### OSCServer.swift and OSCMessage.swift

The server receives OSC messages on UDP with `NWListener`. It is off by default. The default port is 9000. `OSCMessage.swift` holds a pure parser and the command mapping. A malformed packet gives no messages. A float 1 on `/sounddeck/play/<pad>` triggers, and a float 0 releases.

### WebRemoteServer.swift and WebRemotePage.swift

The server sends the web remote page with `NWListener`. It is off by default. The default port is 8787. Each API call must send the pairing code in the header `X-Pairing-Code`. After 10 incorrect codes in one minute, the API returns 429. The parser and the router are pure functions. The traffic is plain HTTP on the local network.

### TwitchChat.swift

This file reads the chat of one Twitch channel. The connection is anonymous: the nick is `justinfan<number>`. The command `!sound <pad>` plays a pad. The pure type `ChatTriggerGate` applies the allowed pads and the cooldowns. A rejected message does not start a cooldown. The app never releases a pad from chat. Therefore a Hold pad plays to its end. Channel point rewards need a Twitch developer app and OAuth. The app does not do them.

### MIDIControl.swift and MIDIMessage.swift

This file connects to all MIDI sources with CoreMIDI and the MIDI 1.0 protocol. A setup change connects all sources again. The receive block parses UMP words on the CoreMIDI thread and sends the messages to the main actor. `MIDIMessage.swift` holds the pure parser and matcher. A CC is down at 64 or more. The matcher acts only when a CC crosses 64. If two pads have the same mapping, both play.

### FloatingDeck.swift

This file holds a floating panel with the pads. The panel uses `.nonactivatingPanel`. Therefore a click on a pad does not activate the app, and the meeting app keeps the focus. The hosting view accepts the first mouse click. Keep `hidesOnDeactivate` false. If it is true, the panel hides while another app is active.

### CueList.swift and CueListView.swift

The cue list plays the pads of a deck in order. `Deck.cueIndex` holds the standby cue. The value `sounds.count` means End. The Go key is the period key, only in List layout. Keep the Go logic in `CueList`, because the tests use it.

### StreamDeckPlugin/

This folder is a Node.js project for the Elgato Stream Deck. It is not in the Xcode project. It uses the `sounddeck://` URLs. If you change the URL forms in `DeckURL.swift`, change `StreamDeckPlugin/src/deck-url.ts` also. To test the plugin, type `npm test` in that folder.

### Theme.swift

This file holds the palette, the chrome, the motion values and the design tokens. `Theme.Font` gives four type sizes: caption 11, body 13, title 15 and numeral 20. Pad names and key caps use the rounded design. `Theme.Radius` gives small 6, control 8 and container 12. `Theme.Spacing` gives 4, 8, 12, 16 and 24. Do not add literal sizes in views. Use a token.

Each colour token has a light value and a dark value, so the app follows the system appearance. The function `Theme.adaptive` makes a dynamic `NSColor`. Do not use a literal colour in a view. Add a token. Text on an `accent` or `danger` fill uses `Theme.onFill`, which is near-black in dark mode. The test `ThemeTests` checks text contrast in the two appearances.

The surfaces are opaque. Do not use `.ultraThinMaterial`. On macOS a material samples the content behind the window. Above a bright desktop, a material makes the dark theme grey.

### Views

The main views are `ContentView`, `SoundTile`, `SoundInspector`, `MenuBarDeck`, `MiniPadGrid` and `SettingsView`.

The main window shows no alert for a playback error. The monitor strip shows the error for 4 seconds. The type `TransientNotice` controls this period. Only import and export show an alert. Stop All is at the right of the monitor strip.

The Add button is a menu: Add Files, Record, Speech Pad and Freesound. The context menu of a deck has Rename, Export, Lock and Delete. Command-F focuses the search field.

Space always stops all sounds, also when a pad has focus. Return plays the focused pad, or plays the last pad again when no pad has focus.

The inspector puts the settings in a two-column grid. Fades, pitch and speed are in the closed "Shape" section. `KeyRecorderField` records the hotkey. The pure rules are in `KeyRecording`. The permitted characters must agree with `GlobalHotKeys.keyCode(for:)`.

`MiniPadGrid` shows a compact grid of the pads of the active deck. The menu bar deck and the floating deck use it. A Hold pad plays on mouse down and stops on mouse up. "Settings…" in the menu bar uses `openSettings` after `NSApp.activate`, because `SettingsLink` can open Settings behind the front app.

The Settings window has one tab for each integration. Each tab is in its own file.

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
