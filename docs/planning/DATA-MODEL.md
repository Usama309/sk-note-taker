# SK Note Taker — Data Model

All components (Mac app, MCP server, web view) read/write the same on-disk store. JSON files —
human-readable, easy for three runtimes to share, trivially syncable later.

## Location

```
~/Library/Application Support/SKNoteTaker/
├── folders.json                     # folder tree (projects/clients)
├── settings.json                    # app settings
└── meetings/
    └── <meeting-id>/                # UUID
        ├── meeting.json             # metadata + speaker names + folder
        ├── transcript.json          # diarized segments
        ├── notes.md                 # user's raw notes (Granola-style)
        ├── summary.md               # AI enhanced summary (generated)
        ├── chat.json                # Q&A history with this meeting
        └── recording.m4a            # optional full audio recording
```

## meeting.json

```json
{
  "id": "UUID",
  "title": "Weekly sync with Kainat",
  "createdAt": "2026-07-12T18:00:00Z",
  "endedAt": "2026-07-12T18:42:10Z",
  "folderId": "UUID or null",
  "state": "recording | processing | complete",
  "speakers": {
    "S1": { "label": "Speaker 1", "name": "Saqib", "source": "mic" },
    "S2": { "label": "Speaker 2", "name": "Kainat", "source": "system" }
  },
  "hasRecording": true,
  "durationSec": 2530,
  "autoCategory": { "project": "…", "client": "…", "confidence": 0.9 }
}
```

- `speakers` maps stable speaker keys → optional human names. Renaming a speaker only edits
  this map; transcript segments always reference the key (`S1`, `S2`, …).
- `source` records which audio channel the speaker came from (`mic` = local user,
  `system` = remote participants) — mic-channel speakers default to the machine owner.

## transcript.json

```json
{
  "version": 1,
  "segments": [
    {
      "id": 0,
      "speaker": "S2",
      "source": "system",
      "start": 12.48,
      "end": 15.91,
      "text": "Let's review the launch checklist.",
      "final": true
    }
  ]
}
```

- `start`/`end` are seconds from meeting start.
- Live view renders volatile (non-final) segments in a lighter style; only `final: true`
  segments are persisted.

## folders.json

```json
{
  "folders": [
    { "id": "UUID", "name": "Patriot Holdings", "kind": "client", "parentId": null },
    { "id": "UUID", "name": "Website Redesign", "kind": "project", "parentId": "<client-id>" }
  ]
}
```

Two-level convention (client → project) but arbitrary nesting allowed. AI auto-categorization
proposes `folderId` by matching/creating folders from transcript content.

## chat.json

```json
{ "messages": [ { "role": "user", "text": "What did Kainat say about the deadline?",
                  "at": "…" },
                { "role": "assistant", "text": "…", "at": "…" } ] }
```

## summary.md front-matter

`summary.md` begins with YAML front-matter for structured consumption by MCP/web:

```markdown
---
generatedAt: 2026-07-12T18:45:00Z
actionItems:
  - owner: Kainat
    text: Send the revised proposal by Friday
decisions:
  - Ship v1 without SSO
remember:
  - Client prefers weekly Friday check-ins
---
# Meeting Summary
…prose summary…
```

## Concurrency

The Mac app is the only writer during a meeting. MCP/web are read-mostly (web may edit
speaker names/folder assignment → write meeting.json atomically via temp-file + rename).
