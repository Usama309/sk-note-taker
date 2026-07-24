# SK Note Taker - Google Meet Speaker Tags

A tiny Chrome/Chromium extension that reads who is speaking in a Google Meet call and sends their
name to the SK Note Taker desktop app, so your transcript shows real participant names instead of
"Speaker 1 / 2 / 3".

## Install (load unpacked)
1. Open your Chromium browser (Chrome, Edge, Brave, Arc) and go to `chrome://extensions`.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and select this `meet-speaker-tags` folder.
4. Make sure it's installed in the browser profile you use for Google Meet.

## Use
- Start (or join) a Google Meet call in that browser.
- Start a meeting in SK Note Taker (the app runs the local bridge on 127.0.0.1:8788 during a meeting).
- Real names appear on the transcript for speakers Meet identifies.

## How it works
- `content.js` runs on `meet.google.com`, reads the active speaker from the page, and posts the
  name to `background.js`.
- `background.js` forwards it to the app's loopback bridge (`http://127.0.0.1:8788/speaker`).
- The app maps the name onto the transcript timeline (same path as the Zoom Accessibility reader).

## Tuning
Google Meet's page markup changes over time, so `findActiveSpeaker` in `content.js` is best-effort.
Open DevTools on the Meet tab and watch for `[SKNT]` logs to see what it detects, then refine the
selectors.
