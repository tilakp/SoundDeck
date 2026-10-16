import streamDeck, { action, KeyDownEvent, SingletonAction } from "@elgato/streamdeck";

import { openUrl, stopUrl } from "../deck-url";

/** Stops all pads. */
@action({ UUID: "com.patelt.sounddeck.stop-all" })
export class StopAll extends SingletonAction {
	override async onKeyDown(ev: KeyDownEvent): Promise<void> {
		const url = stopUrl();
		try {
			await openUrl(url);
		} catch (error) {
			streamDeck.logger.error(`Cannot open ${url}: ${error}`);
			await ev.action.showAlert();
		}
	}
}
