# sknote-mcp

An [MCP](https://modelcontextprotocol.io) stdio server that exposes the
**SK Note Taker** meeting store to any MCP client (Claude Desktop, Claude
Code, etc.). It is **read-only**: it reads the Supabase Postgres project the Mac
app mirrors its local-first data to (see `../supabase/migrations/0001_init.sql`)
and never writes to it. Because the data lives in the cloud, meetings,
transcripts, and summaries are reachable from anywhere — not just the machine
that recorded them.

Server name: `sk-note-taker`.

## Data source

The server reads from Supabase. Credentials are resolved in this order:

1. Environment variables `SUPABASE_URL` and `SUPABASE_ANON_KEY` (both required to
   take effect).
2. Otherwise `../supabase/config.json` (`url` + `anonKey`). Override the config
   path with `SKNOTE_SUPABASE_CONFIG`.

The `anonKey` is a publishable key (RLS-gated) and is safe to embed in clients.
Supabase or network errors are surfaced as an `error` field in the tool result
rather than crashing the server. The server logs only to stderr; stdout is
reserved for the JSON-RPC protocol.

## Tools

| Tool | Arguments | Returns |
|------|-----------|---------|
| `list_meetings` | `folderId?`, `limit?`, `since?` | Meeting summaries (`id`, `title`, `createdAt`, `durationSec`, `folderId`, `folderPath`, `state`, `speakerNames[]`, `hasSummary`), newest first. `folderPath` is derived from the `folders` tree; `speakerNames` from the meeting's `speakers` map; `hasSummary` from whether a `summaries` row exists. `since` is an ISO-8601 cutoff. |
| `get_meeting` | `id` | Full meeting metadata, the meeting's `notes`, resolved `folderPath`, and flags for which artifacts exist (`hasTranscript`, `hasSummary`, `hasChat`, `hasRecording`). |
| `get_transcript` | `id`, `resolveNames?` (default `true`) | Diarized segments (from `transcript_segments`, ordered by `idx`) plus readable `[MM:SS] Name: text` lines. With `resolveNames`, speaker keys (`S1`, `S2`…) become names from the meeting's `speakers` map, falling back to `Speaker N`. |
| `get_summary` | `id` | The meeting's `summaries` row mapped to structured `actionItems`, `decisions`, `remember` plus the markdown `body`. |
| `search_meetings` | `query`, `limit?` | Case-insensitive matches across titles, notes, transcript text, and summaries. Each match includes the meeting `id`/`title`, the `field` that matched, and a `snippet` around the first hit. |
| `list_folders` | — | The folder tree with each folder's full `path` and `meetingCount`, plus an `uncategorizedMeetings` count. |

Every tool returns both human-readable text (JSON) and MCP `structuredContent`.

## Build

```bash
npm install
npm run build      # compiles src/ -> dist/ (dist/server.js is the bin entry)
```

## Test

```bash
npm test           # builds, then runs the integration test against live Supabase
```

The integration test seeds the live Supabase project with a small, disposable
dataset (all rows prefixed `__mcptest__<runId>__`), spawns the built server over
stdio, exercises every tool via the MCP client, asserts on the results, and then
deletes exactly the rows it created. It uses the same credential resolution as
the server (`supabase/config.json`, overridable via `SUPABASE_URL` /
`SUPABASE_ANON_KEY`). It never touches non-prefixed rows.

## Register with an MCP client

### Claude Code

```bash
claude mcp add sk-note-taker -- node /Users/mac/Sites/sk-note-taker/mcp/dist/server.js
```

### Generic MCP client (JSON config)

```json
{
  "mcpServers": {
    "sk-note-taker": {
      "command": "node",
      "args": ["/Users/mac/Sites/sk-note-taker/mcp/dist/server.js"],
      "env": {
        "SUPABASE_URL": "https://<project-ref>.supabase.co",
        "SUPABASE_ANON_KEY": "<publishable-anon-key>"
      }
    }
  }
}
```

The `env` block is optional — omit it to fall back to `../supabase/config.json`.
The server logs only to stderr; stdout is reserved for the JSON-RPC protocol.
