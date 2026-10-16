import { execFile } from "node:child_process";

/**
 * Builds `sounddeck://` URLs. `SoundDeck/DeckURL.swift` in the app reads them.
 * Keep this file free of SDK imports, so that `node --test` can load it.
 */

const scheme = "sounddeck://";

/**
 * Encodes one path segment. Also encodes the characters that `encodeURIComponent` keeps: ! ' ( ) *.
 * A slash in a name becomes %2F, so the app reads it as part of the name.
 */
export function encodeSegment(value: string): string {
	return encodeURIComponent(value).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}

/** Returns the trimmed name, or undefined when the name is empty. The app also trims names. */
function clean(value: string | undefined): string | undefined {
	const trimmed = value?.trim();
	return trimmed ? trimmed : undefined;
}

/** Returns the URL that plays a pad, or undefined when the pad name is empty. */
export function playUrl(pad: string | undefined): string | undefined {
	const name = clean(pad);
	return name === undefined ? undefined : `${scheme}play/${encodeSegment(name)}`;
}

/** Returns the URL that releases a Hold pad, or undefined when the pad name is empty. */
export function releaseUrl(pad: string | undefined): string | undefined {
	const name = clean(pad);
	return name === undefined ? undefined : `${scheme}release/${encodeSegment(name)}`;
}

/** Returns the URL that stops one pad. With no pad name, the URL stops all pads. */
export function stopUrl(pad?: string): string {
	const name = clean(pad);
	return name === undefined ? `${scheme}stop` : `${scheme}stop/${encodeSegment(name)}`;
}

/** Returns the URL that selects a deck, or undefined when the deck name is empty. */
export function deckUrl(deck: string | undefined): string | undefined {
	const name = clean(deck);
	return name === undefined ? undefined : `${scheme}deck/${encodeSegment(name)}`;
}

/** Runs a program with arguments and no shell. Tests replace it. */
export type Runner = (file: string, args: string[], done: (error: Error | null) => void) => void;

const defaultRunner: Runner = (file, args, done) => {
	execFile(file, args, (error) => done(error));
};

// Each URL waits for the previous URL. A fast tap then sends "play" before "release".
let queue: Promise<void> = Promise.resolve();

/**
 * Opens a URL with `/usr/bin/open -g`. The flag `-g` keeps Sound Deck in the background.
 * `execFile` does not use a shell, so a name cannot inject a command.
 */
export function openUrl(url: string, run: Runner = defaultRunner): Promise<void> {
	const next = queue.then(
		() =>
			new Promise<void>((resolve, reject) => {
				run("/usr/bin/open", ["-g", url], (error) => (error ? reject(error) : resolve()));
			})
	);
	// A failed URL must not stop the URLs that follow it.
	queue = next.catch(() => undefined);
	return next;
}
