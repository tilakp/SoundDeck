import Foundation

/// The page of the web remote. It has no external scripts, styles or fonts.
///
/// The page asks for the pairing code one time and keeps it in `localStorage`.
/// A QR code from the Settings window gives the code in the URL fragment.
/// The browser does not send a fragment to the server.
enum WebRemotePage {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; "
        + "style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'"

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>Sound Deck</title>
<style>
:root{--bg:#0e1016;--surface:#181b23;--text:rgba(255,255,255,.95);--muted:rgba(255,255,255,.58);--stroke:rgba(255,255,255,.1);--accent:#6b8cff;--stop:#e5485d}
@media (prefers-color-scheme:light){:root{--bg:#f2f3f7;--surface:#fff;--text:#14161c;--muted:#5d6270;--stroke:rgba(0,0,0,.12);--accent:#3b5bdb;--stop:#d6334a}}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font:16px/1.3 -apple-system,system-ui,sans-serif;-webkit-tap-highlight-color:transparent}
body{padding:max(16px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) calc(104px + env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left))}
header{display:flex;gap:12px;align-items:center;margin-bottom:16px}
h1{font-size:20px;margin:0;flex:1}
select{font:inherit;color:var(--text);background:var(--surface);border:1px solid var(--stroke);border-radius:10px;padding:10px 12px;max-width:60%}
#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px}
.pad{position:relative;min-height:100px;border:1px solid var(--stroke);border-radius:14px;background:var(--surface);color:var(--text);font:inherit;font-weight:600;text-align:left;padding:12px;display:flex;flex-direction:column;justify-content:flex-end;touch-action:none;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none;transition:transform .08s}
.pad .key{position:absolute;top:10px;left:12px;font-size:12px;color:var(--muted);border:1px solid var(--stroke);border-radius:6px;padding:1px 6px;text-transform:uppercase}
.pad .name{overflow-wrap:anywhere}
.pad.on{border-color:var(--accent);box-shadow:inset 0 0 0 2px var(--accent)}
.pad.down{transform:scale(.96)}
#stop{position:fixed;left:16px;right:16px;bottom:max(16px,env(safe-area-inset-bottom));height:68px;border:0;border-radius:16px;background:var(--stop);color:#fff;font:inherit;font-size:20px;font-weight:700}
#msg{color:var(--muted);text-align:center;margin:0 0 16px}
#msg:empty{display:none}
form{display:flex;flex-direction:column;gap:12px;max-width:320px;margin:12vh auto 0;text-align:center}
form p{color:var(--muted);margin:0}
form input{font:inherit;font-size:28px;letter-spacing:.3em;text-align:center;padding:12px;border-radius:12px;border:1px solid var(--stroke);background:var(--surface);color:var(--text)}
form button{font:inherit;font-weight:600;padding:14px;border:0;border-radius:12px;background:var(--accent);color:#fff}
[hidden]{display:none!important}
</style>
</head>
<body>
<form id="pair" hidden>
<h1>Sound Deck</h1>
<p>Type the pairing code. It is in Sound Deck on the Mac: Settings, Web Remote.</p>
<input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" aria-label="Pairing code">
<button>Connect</button>
<p id="pairmsg"></p>
</form>
<main id="deck" hidden>
<header><h1>Sound Deck</h1><select id="decks" aria-label="Deck"></select></header>
<div id="msg"></div>
<div id="grid"></div>
<button id="stop">Stop All</button>
</main>
<script>
"use strict";
const $ = id => document.getElementById(id);
const STORE = "soundDeckPairingCode";
let code = null, timer = null, deckKey = "", padKey = "", queue = Promise.resolve();

function load() { try { return localStorage.getItem(STORE); } catch (e) { return null; } }
function keep(value) {
  try { value ? localStorage.setItem(STORE, value) : localStorage.removeItem(STORE); } catch (e) {}
}

async function api(method, path, body) {
  const response = await fetch(path, {
    method, cache: "no-store",
    headers: { "X-Pairing-Code": code || "", "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined
  });
  if (response.status === 401) { unpair("The code is not correct. Type the code that the Mac shows."); throw new Error("401"); }
  if (response.status === 429) { unpair("Too many incorrect codes. Wait one minute."); throw new Error("429"); }
  return response;
}

// Send the commands in sequence, so that a release never arrives before its play.
function send(path, body) {
  queue = queue.then(() => api("POST", path, body)).then(() => setTimeout(refresh, 120)).catch(() => {});
}

function unpair(text) {
  code = null; keep(null); stopPolling();
  $("deck").hidden = true; $("pair").hidden = false;
  $("pairmsg").textContent = text || ""; $("code").value = "";
}

function startPolling() { stopPolling(); refresh(); timer = setInterval(refresh, 1000); }
function stopPolling() { clearInterval(timer); timer = null; }

function connect() {
  $("pair").hidden = true; $("deck").hidden = false;
  deckKey = ""; padKey = "";
  startPolling();
}

async function refresh() {
  if (!code) return;
  try {
    const response = await api("GET", "/api/pads");
    if (!response.ok) throw new Error(String(response.status));
    render(await response.json());
  } catch (e) {
    if (code) $("msg").textContent = "No connection to the Mac.";
  }
}

function render(state) {
  const select = $("decks");
  const dk = JSON.stringify([state.decks, state.activeDeck]);
  if (dk !== deckKey) {
    deckKey = dk; select.textContent = "";
    for (const deck of state.decks) {
      const option = document.createElement("option");
      option.value = deck.id; option.textContent = deck.name;
      option.selected = deck.id === state.activeDeck;
      select.append(option);
    }
  }
  // Build the buttons again only when the pads change. A new button loses the pointer.
  const grid = $("grid");
  const pk = JSON.stringify(state.pads.map(p => [p.id, p.name, p.key]));
  if (pk !== padKey) {
    padKey = pk; grid.textContent = "";
    for (const pad of state.pads) grid.append(makePad(pad));
  }
  const playing = new Set(state.pads.filter(p => p.isPlaying).map(p => p.id));
  for (const button of grid.children) button.classList.toggle("on", playing.has(button.dataset.id));
  $("msg").textContent = state.pads.length ? "" : "This deck has no pads.";
}

function makePad(pad) {
  const button = document.createElement("button");
  button.className = "pad"; button.dataset.id = pad.id;
  if (pad.key) {
    const key = document.createElement("span");
    key.className = "key"; key.textContent = pad.key; button.append(key);
  }
  const name = document.createElement("span");
  name.className = "name"; name.textContent = pad.name; button.append(name);
  let down = false;
  button.addEventListener("pointerdown", event => {
    event.preventDefault();
    if (down) return;
    down = true; button.classList.add("down");
    try { button.setPointerCapture(event.pointerId); } catch (e) {}
    send("/api/play", { pad: pad.id });
  });
  const up = () => {
    if (!down) return;
    down = false; button.classList.remove("down");
    send("/api/release", { pad: pad.id });
  };
  button.addEventListener("pointerup", up);
  button.addEventListener("pointercancel", up);
  button.addEventListener("lostpointercapture", up);
  button.addEventListener("contextmenu", event => event.preventDefault());
  return button;
}

$("decks").addEventListener("change", event => send("/api/deck", { deck: event.target.value }));
$("stop").addEventListener("click", () => send("/api/stop", {}));
$("pair").addEventListener("submit", event => {
  event.preventDefault();
  const value = $("code").value.trim();
  if (!/^\d{6}$/.test(value)) { $("pairmsg").textContent = "The code has six digits."; return; }
  code = value; keep(value); connect();
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) stopPolling(); else if (code) startPolling();
});

const fragment = /^#code=(\d{6})$/.exec(location.hash);
if (fragment) { keep(fragment[1]); history.replaceState(null, "", location.pathname); }
code = load();
if (code) connect(); else unpair("");
</script>
</body>
</html>
"""#
}
