// SK Note Taker - Google Meet speaker tags (content script).
//
// Reports who is currently speaking in a Google Meet call to the SK Note Taker desktop app (via
// the background worker -> the app's loopback bridge on 127.0.0.1:8788).
//
// HOW THIS READS THE PAGE, AND WHY
// The obvious approach - find the tile with a "speaking" ring - does not work. Meet ships no
// speaking-related class, aria-label, or data attribute: verified against a live call, where
// [aria-label*=speaking], [class*=speaking], [class*=isTalking] and [data-layout=spotlight] all
// matched zero elements, and every class on a participant tile is obfuscated (Djiqwe, LqxiJe...)
// and changes between Meet releases.
//
// Meet's LIVE CAPTIONS are the reliable source: each caption row carries the speaker's real name
// next to their words, and the container is addressable semantically as
// [role="region"][aria-label="Captions"], which is a stable, meaningful hook rather than a
// generated class name. So we read the newest caption row and report its name.
//
// Captions must be on for names to exist at all, so we switch them on once if they are off.
// Captions are local to this browser; other participants see nothing.
(function () {
  "use strict";

  let last = null;
  let triedEnable = false;

  /** The captions container, or null when captions are off. */
  function captionsRegion() {
    return document.querySelector('[role="region"][aria-label="Captions"]')
        || document.querySelector('[role="region"][aria-label*="aption"]');
  }

  /** Turn captions on once, since without them Meet exposes no speaker names anywhere. */
  function enableCaptionsOnce() {
    if (triedEnable) return;
    const btn = [...document.querySelectorAll("button[aria-label]")]
      .find(b => /turn on captions/i.test(b.getAttribute("aria-label") || ""));
    if (btn) {
      triedEnable = true;
      btn.click();
      console.debug("[SKNT] turned on live captions to read speaker names");
    }
  }

  /**
   * Speaker names from the caption rows, oldest last. Classes are obfuscated, so this navigates by
   * SHAPE. A caption row is a direct child of the region holding two blocks:
   *   <div row> <div>[avatar] NAME</div> <div>SPOKEN TEXT</div> </div>
   * Reading the name from the first block (rather than from an avatar <img>) keeps this working for
   * participants who have no profile picture, where Meet draws initials instead of an image.
   * The region also contains a "Jump to bottom" control, which is excluded by its button.
   */
  function speakerNames(region) {
    return [...region.children]
      .filter(row => row.children.length >= 2 && !row.querySelector("button"))
      .map(row => nameInHeader(row.children[0]))
      .filter(Boolean);
  }

  /**
   * The speaker's name inside a caption row's header block. Taking the block's whole textContent is
   * wrong for a participant with no profile picture: Meet draws their initials there too, which
   * would yield "ABNaeem Akram". The name is the LAST leaf that carries text.
   */
  function nameInHeader(header) {
    if (!header) return null;
    const leaves = [...header.querySelectorAll("*")]
      .filter(e => e.children.length === 0 && (e.textContent || "").trim());
    if (leaves.length) return leaves[leaves.length - 1].textContent.trim();
    return (header.textContent || "").trim() || null;
  }

  /** The most recent speaker's name, or null. */
  function findActiveSpeaker() {
    const region = captionsRegion();
    if (!region) { enableCaptionsOnce(); return null; }

    const names = speakerNames(region);
    if (!names.length) return null;

    const name = names[names.length - 1];
    if (!name) return null;

    // "You" is the local user. Their audio arrives on the app's microphone channel and is already
    // attributed there, so reporting it would mislabel the remote (system-audio) side.
    if (/^(you|tu|vous|du)$/i.test(name)) return null;
    if (name.length < 2 || name.length > 60) return null;
    return name;
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
      // transient DOM churn between Meet re-renders
    }
  }

  console.debug("[SKNT] Meet speaker tags loaded (reads live captions)");
  setInterval(tick, 400);
})();
