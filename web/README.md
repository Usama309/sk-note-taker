# SK Note Taker — Web Review

A browser-based review app for **SK Note Taker**. It reads (and lightly writes) the same
on-disk store as the macOS app, so you can review all your meetings from any browser —
including your phone on the same Wi-Fi — when you're away from the Mac.

No build step. Vanilla JS + CSS served statically by a small Express server.

## Screenshot

<!-- screenshot placeholder: add web/docs/screenshot.png -->
_Dark, Linear/Granola-quality UI: sidebar with folder tree, meeting cards, and a detail
view with Summary / Transcript / Notes tabs plus an audio player._

## Requirements

- Node 22+

## Run

```bash
cd web
npm install
npm start
```

The server listens on `0.0.0.0:4517` by default.

- On this Mac: <http://localhost:4517>
- On the LAN (phone/tablet): `http://<mac-ip>:4517`
  Find your Mac's IP with `ipconfig getifaddr en0` (Wi-Fi) — both devices must be on the
  same network.

### Configuration

| Env var | Default | Purpose |
| --- | --- | --- |
| `SKNOTE_WEB_PORT` | `4517` | Port to listen on |
| `SKNOTE_DATA_DIR` | `~/Library/Application Support/SKNoteTaker` | Data directory to read/write |

If the data directory doesn't exist yet, the app starts fine and shows an empty state —
record your first meeting in the Mac app and refresh.

## API

All JSON, prefixed with `/api`.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/meetings?folderId=&q=` | List meetings (filter by folder, search title/speakers) |
| GET | `/api/meetings/:id` | Full meeting: metadata, notes, parsed summary, chat |
| GET | `/api/meetings/:id/transcript` | Segments with resolved speaker names |
| GET | `/api/meetings/:id/audio` | Stream `recording.m4a` (HTTP Range supported) |
| PATCH | `/api/meetings/:id/speakers` | Merge `{ "S2": "Kainat" }` name assignments (atomic write) |
| PATCH | `/api/meetings/:id/folder` | `{ "folderId": "…" }` move meeting (or `null` to unfile) |
| GET | `/api/folders` | Folder tree with recursive meeting counts |

Writes to `meeting.json` are atomic (temp file + rename) so a concurrent read from the Mac
app or MCP server never sees a half-written file. Missing directories yield empty results;
malformed JSON files are skipped and logged to `console.error` rather than crashing.

## Tests

```bash
npm test
```

Spawns the real server against a throwaway copy of `tests/fixtures/` on a random port and
exercises every endpoint over HTTP, including the PATCH endpoints (asserting the atomic
write actually landed on disk).

## Layout

```
web/
├── src/
│   ├── server.js      # Express app + API routes
│   └── store.js       # On-disk store access (read + atomic write, front-matter parser)
├── public/
│   ├── index.html
│   ├── css/app.css
│   └── js/
│       ├── app.js       # Hash router + UI
│       └── markdown.js  # Tiny XSS-safe Markdown renderer
└── tests/
    ├── api.test.mjs
    └── fixtures/        # Fake data dir (3 meetings, folders)
```
