import streamDeck, { action, DidReceiveSettingsEvent, KeyDownEvent, SingletonAction, WillAppearEvent } from "@elgato/streamdeck";

import { openUrl, stopUrl } from "../deck-url";
import type { PadSettings } from "./settings";
import { showName } from "./title";

/** Stops all voices of one pad. */
@action({ UUID: "com.patelt.sounddeck.stop-pad" })
export class StopPad extends SingletonAction<PadSettings> {
	override onWillAppear(ev: WillAppearEvent<PadSettings>): Promise<void> {
		return showName(ev.action, ev.payload.settings.pad);
	}

	override onDidReceiveSettings(ev: DidReceiveSettingsEvent<PadSettings>): Promise<void> {
		return showName(ev.action, ev.payload.settings.pad);
	}

	override async onKeyDown(ev: KeyDownEvent<PadSettings>): Promise<void> {
		// An empty name would give "sounddeck://stop", which stops all pads. Do not send it.
		if (!ev.payload.settings.pad?.trim()) {
			await ev.action.showAlert();
			return;
		}
		const url = stopUrl(ev.payload.settings.pad);
		try {
			await openUrl(url);
		} catch (error) {
			streamDeck.logger.error(`Cannot open ${url}: ${error}`);
			await ev.action.showAlert();
		}
	}
}
