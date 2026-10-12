// Renders the bundled sounds with Web Audio in headless Chrome.
// The synthesis is in Tools/MakeSounds.html. It is a copy of the web demo on quietpixel.dev.
//
// Usage: node Tools/MakeSounds.mjs <output-dir>
// Set CHROME to use a different Chrome binary.
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const out = process.argv[2];
if (!out) {
  console.error("Usage: node Tools/MakeSounds.mjs <output-dir>");
  process.exit(1);
}
const chromePath = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const page = pathToFileURL(join(dirname(fileURLToPath(import.meta.url)), "MakeSounds.html")).href;

// A separate profile keeps the Chrome of the user unchanged.
const profile = mkdtempSync(join(tmpdir(), "makesounds-"));
const chrome = spawn(chromePath, [
  "--headless=new", "--disable-gpu", "--no-first-run", "--remote-debugging-port=0",
  `--user-data-dir=${profile}`, page,
]);

try {
  // Chrome writes the address of the DevTools endpoint to stderr.
  const port = await new Promise((resolve, reject) => {
    let text = "";
    chrome.stderr.on("data", (chunk) => {
      text += chunk;
      const match = text.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//);
      if (match) resolve(match[1]);
    });
    chrome.on("exit", () => reject(new Error("Chrome stopped before it was ready.")));
  });
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const target = targets.find((t) => t.type === "page" && t.url === page);
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve) => socket.addEventListener("open", resolve, { once: true }));

  // Wait for the promise that the page makes.
  const reply = new Promise((resolve) => socket.addEventListener("message", (event) => resolve(JSON.parse(event.data)), { once: true }));
  const expression = "(async () => { while (!window.result) await new Promise((r) => setTimeout(r, 50)); return window.result; })()";
  socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, awaitPromise: true, returnByValue: true } }));
  const { result } = await reply;
  if (!result || result.exceptionDetails) throw new Error(`The render failed: ${JSON.stringify(result?.exceptionDetails ?? result)}`);
  socket.close();

  mkdirSync(out, { recursive: true });
  for (const file of result.result.value) {
    writeFileSync(join(out, file.name), Buffer.from(file.data, "base64"));
    console.log(`${file.name}: ${file.info}`);
  }
} finally {
  chrome.kill();
  await new Promise((resolve) => (chrome.exitCode === null ? chrome.on("exit", resolve) : resolve()));
  rmSync(profile, { recursive: true, force: true });
}
