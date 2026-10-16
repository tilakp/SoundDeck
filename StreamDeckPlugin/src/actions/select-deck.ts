import streamDeck, { action, DidReceiveSettingsEvent, KeyDownEvent, SingletonAction, WillAppearEvent } from "@elgato/streamdeck";

import { deckUrl, openUrl } from "../deck-url";
import type { DeckSettings } from "./settings";
import { showName } from "./title";

/** Makes a deck the current deck in Sound Deck. */
@action({ UUID: "com.patelt.sounddeck.deck" })
export class SelectDeck extends SingletonAction<DeckSettings> {
	override onWillAppear(ev: WillAppearEvent<DeckSettings>): Promise<void> {
		return showName(ev.action, ev.payload.settings.deck);
	}

	override onDidReceiveSettings(ev: DidReceiveSettingsEvent<DeckSettings>): Promise<void> {
		return showName(ev.action, ev.payload.settings.deck);
	}

	override async onKeyDown(ev: KeyDownEvent<DeckSettings>): Promise<void> {
		const url = deckUrl(ev.payload.settings.deck);
		if (url === undefined) {
			await ev.action.showAlert();
			return;
		}
		try {
			await openUrl(url);
		} catch (error) {
			streamDeck.logger.error(`Cannot open ${url}: ${error}`);
			await ev.action.showAlert();
		}
	}
}
