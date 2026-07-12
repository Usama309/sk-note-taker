# sknote-mcp

An [MCP](https://modelcontextprotocol.io) stdio server that exposes the
**SK Note Taker** meeting-notes store to any MCP client (Claude Desktop, Claude
Code, etc.). It is **read-only**: it reads the same on-disk JSON/Markdown store
the Mac app and web view use (see `../docs/planning/DATA-MODEL.md`) and never
writes to it.

Server name: `sk-note-taker`.

## Data location

By default the server reads:

```
~/Library/Application Support/SKNoteTaker/
```

Override with the `SKNOTE_DATA_DIR` environment variable (used by the tests to
point at fixtures). A missing data directory yields empty results rather than an
error; malformed JSON files are skipped with a warning on stderr.

## Tools

| Tool | Arguments | Returns |
|------|-----------|---------|
| `list_meetings` | `folderId?`, `limit?`, `since?` | Meeting summaries (`id`, `title`, `createdAt`, `durationSec`, `folderId`, `folderPath`, `state`, `speakerNames[]`, `hasSummary`), newest first. `since` is an ISO-8601 cutoff. |
| `get_meeting` | `id` | Full `meeting.json`, `notes.md` content, resolved `folderPath`, and flags for which artifacts exist (`hasTranscript`, `hasSummary`, `hasChat`, `hasRecording`). |
| `get_transcript` | `id`, `resolveNames?` (default `true`) | Diarized segments plus readable `[MM:SS] Name: text` lines. With `resolveNames`, speaker keys (`S1`, `S2`…) become names from the meeting's speakers map, falling back to `Speaker N`. |
| `get_summary` | `id` | `summary.md` parsed into structured `actionItems`, `decisions`, `remember` (from YAML front-matter) plus the markdown `body` and `raw` text. |
| `search_meetings` | `query`, `limit?` | Case-insensitive matches across titles, notes, transcript text, and summaries. Each match includes the meeting `id`/`title`, the `field` that matched, and a `snippet` around the first hit. |
| `list_folders` | — | The folder tree from `folders.json` with each folder's full `path` and `meetingCount`, plus an `uncategorizedMeetings` count. |

Every tool returns both human-readable text (JSON) and MCP `structuredContent`.

## Build

```bash
npm install
npm run build      # compiles src/ -> dist/ (dist/server.js is the bin entry)
```

## Test

```bash
npm test           # builds, then runs the integration test against tests/fixtures
```

The integration test spawns the built server over stdio with `SKNOTE_DATA_DIR`
pointed at `tests/fixtures/` and exercises every tool.

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
        "SKNOTE_DATA_DIR": "~/Library/Application Support/SKNoteTaker"
      }
    }
  }
}
```

`SKNOTE_DATA_DIR` is optional — omit it to use the default location. The server
logs only to stderr; stdout is reserved for the JSON-RPC protocol.
