import streamDeck, { action, DidReceiveSettingsEvent, KeyDownEvent, KeyUpEvent, SingletonAction, WillAppearEvent } from "@elgato/streamdeck";

import { openUrl, playUrl, releaseUrl } from "../deck-url";
import type { PadSettings } from "./settings";
import { showName } from "./title";

/**
 * Plays a pad on key down. Sends "release" on key up, so that Hold pads stop when the key comes up.
 */
@action({ UUID: "com.patelt.sounddeck.play" })
export class PlayPad extends SingletonAction<PadSettings> {
	override onWillAppear(ev: WillAppearEvent<PadSettings>): Promise<void> {
		return showName(ev.action, ev.payload.settings.pad);
	}

	override onDidReceiveSettings(ev: DidReceiveSettingsEvent<PadSettings>): Promise<void> {
		return showName(ev.action, ev.payload.settings.pad);
	}

	override async onKeyDown(ev: KeyDownEvent<PadSettings>): Promise<void> {
		const url = playUrl(ev.payload.settings.pad);
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

	override async onKeyUp(ev: KeyUpEvent<PadSettings>): Promise<void> {
		const url = releaseUrl(ev.payload.settings.pad);
		if (url === undefined) return;
		try {
			await openUrl(url);
		} catch (error) {
			streamDeck.logger.error(`Cannot open ${url}: ${error}`);
		}
	}
}
