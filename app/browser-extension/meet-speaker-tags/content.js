// SK Note Taker - Google Meet speaker tags (content script).
//
// Reads who is currently speaking in a Google Meet call and forwards their name to the SK Note
// Taker desktop app (via the background worker -> the app's loopback bridge on 127.0.0.1:8788).
//
// NOTE: Google Meet's DOM uses obfuscated, changing class names, so the selectors below are
// best-effort and are meant to be tuned against a live call. Open DevTools on the Meet tab and
// watch for "[SKNT]" logs to see what it detects, then refine `findActiveSpeaker` / `nameForTile`.
(function () {
  "use strict";
  let last = null;

  const textOf = (el) => (el && el.textContent ? el.textContent.trim() : "");

  // Skip labels that are clearly not a person's name.
  const NON_NAME = /^(you|presenting|pinned|more|mute|unmute|camera|screen|everyone|host|meeting details)$/i;

  function nameForTile(tile) {
    const nodes = tile.querySelectorAll("div, span");
    for (const n of nodes) {
      const t = textOf(n);
      if (t.length >= 2 && t.length <= 40 && !t.includes("\n") && /[a-zA-Z]/.test(t) && !NON_NAME.test(t)) {
        return t;
      }
    }
    return null;
  }

  function findActiveSpeaker() {
    // Participant tiles carry a data-participant-id; a speaking tile shows an animated audio
    // indicator. We approximate "speaking" via an aria-label / class hint (the fragile part).
    const tiles = document.querySelectorAll("[data-participant-id]");
    for (const tile of tiles) {
      const speaking = tile.querySelector('[aria-label*="speaking" i], [class*="speaking" i], [class*="isTalking" i]');
      if (speaking) {
        const name = nameForTile(tile);
        if (name) return name;
      }
    }
    // Speaker/spotlight view: the large tile is the active speaker.
    const main = document.querySelector('[data-layout="spotlight"] [data-participant-id]');
    if (main) {
      const name = nameForTile(main);
      if (name) return name;
    }
    return null;
  }

  function tick() {
    try {
      const name = findActiveSpeaker();
      if (name && name !== last) {
        last = name;
        console.debug("[SKNT] active speaker:", name);
        chrome.runtime.sendMessage({ type: "activeSpeaker", name });
      }
    } catch (_) {
      // ignore transient DOM errors
    }
  }

  console.debug("[SKNT] Meet speaker tags content script loaded");
  setInterval(tick, 400);
})();
