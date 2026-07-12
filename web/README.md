# SK Note Taker — Web Review

A browser-based review app for **SK Note Taker**. It reads (and lightly writes) the same
data as the macOS app — but from **Supabase (cloud Postgres + Storage)** rather than local
files. The Mac app is local-first and mirrors every meeting to Supabase, so you can review
all your meetings from any browser, anywhere — not just a device on the same Wi-Fi as the
Mac.

No build step. Vanilla JS + CSS served statically by a small Express server; the server
talks to Supabase via `@supabase/supabase-js`.

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

Supabase connection details are read from `../supabase/config.json` (the `url` and
`anonKey`). The `anonKey` is a **publishable** key — it is RLS-gated and safe to embed in a
client. You can override the project via environment variables (handy for CI or a second
project):

| Env var | Default | Purpose |
| --- | --- | --- |
| `SKNOTE_WEB_PORT` | `4517` | Port to listen on |
| `SUPABASE_URL` | from `supabase/config.json` | Supabase project URL |
| `SUPABASE_ANON_KEY` | from `supabase/config.json` | Supabase publishable (anon) key |
| `SUPABASE_RECORDINGS_BUCKET` | `recordings` | Storage bucket holding `<meeting-id>.m4a` audio |

If there are no meetings yet, the app starts fine and shows an empty state — record your
first meeting in the Mac app (it syncs to Supabase) and refresh.

## API

All JSON, prefixed with `/api`.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/meetings?folderId=&q=` | List meetings (filter by folder, search title/speakers) |
| GET | `/api/meetings/:id` | Full meeting: metadata, notes, parsed summary, chat |
| GET | `/api/meetings/:id/transcript` | Segments with resolved speaker names |
| GET | `/api/meetings/:id/audio` | Stream the recording from Supabase Storage (HTTP Range supported) |
| PATCH | `/api/meetings/:id/speakers` | Merge `{ "S2": "Kainat" }` name assignments into the `speakers` jsonb |
| PATCH | `/api/meetings/:id/folder` | `{ "folderId": "…" }` move meeting (or `null` to unfile) |
| GET | `/api/folders` | Folder tree with recursive meeting counts |

All data lives in Supabase Postgres; audio is streamed from the private `recordings`
Storage bucket (`<meeting-id>.m4a`) via a short-lived signed URL, with `Range` requests
proxied through for seeking/streaming. Speaker renames are a read-modify-write of the
`speakers` jsonb. If Supabase is unreachable, endpoints return a `502` with a JSON `detail`
rather than crashing the server.

## Tests

```bash
npm test
```

Runs against the **live Supabase project**. The tests seed a small, self-contained dataset
(folders, meetings, transcript, summary, chat, and one audio object) using a unique
`__webtest__<random>__` title/name prefix, spawn the real server on a random port, exercise
every endpoint over HTTP — including the PATCH endpoints (asserting the write actually
landed in Supabase) — and then delete everything they created. They only ever touch rows
they inserted, never your real meetings. Requires network access and a configured Supabase
project.

## Layout

```
web/
├── src/
│   ├── server.js      # Express app + API routes (audio proxied from Storage)
│   ├── store.js       # Supabase data access (maps snake_case → the UI's camelCase shape)
│   └── supabase.js    # Configured @supabase/supabase-js client (config.json / env)
├── public/
│   ├── index.html
│   ├── css/app.css
│   └── js/
│       ├── app.js       # Hash router + UI
│       └── markdown.js  # Tiny XSS-safe Markdown renderer
└── tests/
    └── api.test.mjs     # Live-Supabase integration tests (self-seeding + cleanup)
```
