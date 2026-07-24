// SK Note Taker - Meet speaker tags (background service worker).
// Forwards active-speaker names from the content script to the desktop app's loopback bridge.
// host_permissions for http://127.0.0.1:8788/* exempts this fetch from CORS.
chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.type === "activeSpeaker" && msg.name) {
    fetch("http://127.0.0.1:8788/speaker", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: msg.name }),
    }).catch(() => {
      // App not running / no active meeting: nothing to do.
    });
  }
});
