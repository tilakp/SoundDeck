// Run with `npm test`. Node 22.18 and later load TypeScript files directly.
import assert from "node:assert/strict";
import { test } from "node:test";

import { deckUrl, encodeSegment, openUrl, playUrl, releaseUrl, stopUrl, type Runner } from "../src/deck-url.ts";

test("play and release encode a plain name", () => {
	assert.equal(playUrl("airhorn"), "sounddeck://play/airhorn");
	assert.equal(releaseUrl("airhorn"), "sounddeck://release/airhorn");
});

test("a space becomes %20", () => {
	assert.equal(playUrl("Air Horn"), "sounddeck://play/Air%20Horn");
});

test("a slash stays in the name as %2F", () => {
	assert.equal(playUrl("AC/DC"), "sounddeck://play/AC%2FDC");
	assert.equal(stopUrl("a/b/c"), "sounddeck://stop/a%2Fb%2Fc");
});

test("quotes and other reserved characters are encoded", () => {
	assert.equal(playUrl(`say "hi"`), "sounddeck://play/say%20%22hi%22");
	assert.equal(playUrl("it's (loud)!*"), "sounddeck://play/it%27s%20%28loud%29%21%2A");
	assert.equal(playUrl("a?b#c&d%e"), "sounddeck://play/a%3Fb%23c%26d%25e");
	assert.equal(playUrl("$(rm -rf ~); `x`"), "sounddeck://play/%24%28rm%20-rf%20~%29%3B%20%60x%60");
});

test("non-ASCII text is UTF-8 encoded", () => {
	assert.equal(deckUrl("Café 🎺"), "sounddeck://deck/Caf%C3%A9%20%F0%9F%8E%BA");
});

test("decoding gives the original name back", () => {
	for (const name of ["Air Horn", "AC/DC", `"quoted"`, "it's", "100%", "a+b", "Café 🎺"]) {
		const url = playUrl(name)!;
		assert.equal(decodeURIComponent(url.slice("sounddeck://play/".length)), name);
		assert.equal(encodeSegment(name).includes("/"), false);
	}
});

test("names are trimmed and empty names give no URL", () => {
	assert.equal(playUrl("  Air Horn  "), "sounddeck://play/Air%20Horn");
	assert.equal(playUrl(""), undefined);
	assert.equal(playUrl("   "), undefined);
	assert.equal(releaseUrl(undefined), undefined);
	assert.equal(deckUrl(""), undefined);
});

test("stop without a pad stops all pads", () => {
	assert.equal(stopUrl(), "sounddeck://stop");
	assert.equal(stopUrl("  "), "sounddeck://stop");
	assert.equal(stopUrl("Rimshot"), "sounddeck://stop/Rimshot");
});

test("openUrl runs /usr/bin/open -g with the URL as one argument, in order", async () => {
	const calls: string[][] = [];
	const slowFirst: Runner = (file, args, done) => {
		calls.push([file, ...args]);
		setTimeout(() => done(null), calls.length === 1 ? 20 : 0);
	};
	await Promise.all([openUrl("sounddeck://play/a", slowFirst), openUrl("sounddeck://release/a", slowFirst)]);
	assert.deepEqual(calls, [
		["/usr/bin/open", "-g", "sounddeck://play/a"],
		["/usr/bin/open", "-g", "sounddeck://release/a"],
	]);
});

test("a failed open rejects but does not block the next URL", async () => {
	const fail: Runner = (_file, _args, done) => done(new Error("no handler"));
	await assert.rejects(openUrl("sounddeck://stop", fail), /no handler/);
	let ran = false;
	await openUrl("sounddeck://stop", (_file, _args, done) => {
		ran = true;
		done(null);
	});
	assert.equal(ran, true);
});
