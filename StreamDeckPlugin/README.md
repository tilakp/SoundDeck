# Sound Deck plugin for Stream Deck

This plugin lets an Elgato Stream Deck control Sound Deck. The plugin opens `sounddeck://` URLs. Sound Deck reads these URLs in `SoundDeck/DeckURL.swift`.

The plugin operates on macOS only. It uses the official Stream Deck SDK for Node.js (`@elgato/streamdeck`).

## Actions

| Action | Setting | Key down | Key up |
| --- | --- | --- | --- |
| Play Pad | Pad | `sounddeck://play/<pad>` | `sounddeck://release/<pad>` |
| Stop All | None | `sounddeck://stop` | None |
| Stop Pad | Pad | `sounddeck://stop/<pad>` | None |
| Select Deck | Deck | `sounddeck://deck/<deck>` | None |

The Pad setting is the name, the id or the key of a pad. The Deck setting is the name of a deck.

The key up URL is for Hold pads. A Hold pad stops when you release the key. Other pads ignore the release URL.

The key shows the pad name or the deck name as its title. To show a different title, type it in the Title field of Stream Deck.

If the Pad setting or the Deck setting is empty, the key shows a yellow warning triangle. The key also shows the triangle if `open` fails.

## Requirements

- macOS 14 or later.
- Stream Deck 7.1 or later.
- Node.js 24 and npm, for the build. Stream Deck supplies its own Node.js to run the plugin.
- The Stream Deck command-line tool. To install it, type `npm install -g @elgato/cli`.

## Build

Do these steps in this folder.

1. To install the packages, type `npm ci`.
2. To build the plugin, type `npm run build`.

The build writes `com.patelt.sounddeck.sdPlugin/bin/plugin.js`. Git ignores this file.

To run the unit tests, type `npm test`. The tests check the URLs for names with spaces, slashes and quotes.

## Link for development

1. Build the plugin.
2. To link the plugin folder to Stream Deck, type `streamdeck link com.patelt.sounddeck.sdPlugin`.
3. To restart the plugin after a change, type `streamdeck restart com.patelt.sounddeck`.

To build and restart after each change, type `npm run watch`.

The plugin writes its logs to `com.patelt.sounddeck.sdPlugin/logs/`.

## Pack

1. Build the plugin.
2. To make an installer file, type `streamdeck pack com.patelt.sounddeck.sdPlugin`.

The command writes `com.patelt.sounddeck.streamDeckPlugin`. To install the plugin, open this file.

## Use

1. Start Sound Deck one time. macOS then knows the `sounddeck://` scheme.
2. In Stream Deck, find the Sound Deck category.
3. Drag an action to a key.
4. Type the pad name or the deck name in the property inspector.
5. Push the key.

The plugin opens each URL with `/usr/bin/open -g`. Sound Deck stays in the background. If Sound Deck is not open, macOS starts it.

The plugin sends the URLs in sequence. A fast tap therefore sends "play" before "release".

The plugin starts `open` without a shell. Therefore a pad name cannot run a command.

## Icons

The action icons, the key images and the category icon are SVG files. Stream Deck needs a PNG file for the plugin icon. The source of that icon is `assets/marketplace.svg`.

To make the PNG files again, type the commands that follow.

```bash
sips -s format png assets/marketplace.svg --out com.patelt.sounddeck.sdPlugin/imgs/plugin/marketplace.png -z 256 256
sips -s format png assets/marketplace.svg --out com.patelt.sounddeck.sdPlugin/imgs/plugin/marketplace@2x.png -z 512 512
```

## Property inspector

The property inspector loads `sdpi-components` from `sdpi-components.dev`. The Elgato template does the same. Without a network connection, the setting fields do not show.
