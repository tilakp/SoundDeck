# Sound Deck

<p align="center">
  <img src="./SoundDeck/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Sound Deck Icon" width="128" height="128">
</p>

A beautiful, modern macOS app for quickly playing your favorite sound files.

## Features

- **Add custom audio files** (WAV, MP3, etc.) via the Add Sound button
- **Play sounds** instantly by clicking their button
- **Stop playback** using the always-visible Stop button or by pressing the Space bar
- **Persistent sound list**: Your sounds are saved between app launches
- **Remove sounds** easily via right-click/context menu
- **Modern SwiftUI interface**: Responsive grid, gradient background, and smooth interactions

## Keyboard Shortcuts

- **Space bar**: Stop currently playing sound

## How It Works

- Uses security-scoped bookmarks to persist file access permissions for user-selected audio files
- All file access is sandboxed and privacy-respecting

## Requirements

- macOS 13.0 or later
- Xcode 15 or later (for building)

## Setup & Build

1. Clone or download this repository
2. Open `SoundDeck.xcodeproj` in Xcode
3. Build and run the app on your Mac

## Troubleshooting

- If you encounter permissions errors, ensure you are running the app from Xcode and have granted access to your audio files via the file picker
- If sandbox issues persist, try resetting Xcode privacy permissions with `tccutil reset All com.apple.dt.Xcode`

## Credits

- App and UI by AI
- Powered by SwiftUI and AVFoundation
- App icon: <a href="https://www.freepik.com/icon/audio-waves_11824120">audio-waves icon by Freepik</a>

---

Enjoy your custom soundboard experience! If you have feature requests or issues, feel free to open an issue or contribute.
