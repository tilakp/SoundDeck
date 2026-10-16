import type { Action } from "@elgato/streamdeck";

import type { DeckSettings, PadSettings } from "./settings";

/**
 * Shows a pad or deck name as the key title. A title that the user types in Stream Deck replaces it.
 */
export async function showName<T extends PadSettings | DeckSettings>(action: Action<T>, name: string | undefined): Promise<void> {
	if (action.isKey()) {
		await action.setTitle(name?.trim() ?? "");
	}
}
