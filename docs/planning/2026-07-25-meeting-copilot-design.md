# Meeting Copilot — Design Spec

Status: draft for review
Date: 2026-07-25
Owner: Usama / Saqib

## Goal

Turn SK Note Taker from a notetaker into a meeting copilot. Each project holds a living memory of everything that has happened in it. During a meeting, a memory-backed assistant gives short, exact wording to say, fast, so the user can read it out when they are put on the spot. Before a meeting, it briefs the user. Later, it coaches presence from the camera.

This spec covers Phase 0 (quick wins) and Phase 1 (the core copilot). Phase 2 (pre-meeting brief) and Phase 3 (camera presence coaching) get their own specs.

## Decisions locked with the user

- A project's memory is filled by its filed meetings automatically, plus imported transcripts/docs and typed-in details.
- The live assistant works both on-demand and by auto-suggesting when a question is aimed at the user.
- The recording picker gets a real-window highlight and a thumbnail on hover.
- The screen recording should also capture audio.
- Each project keeps a living `project.md` the assistant reads first for speed and accuracy.
- Answers are the exact short wording to say, tuned by communication best practices.
- The assistant has the whole project (all meetings + data) available for context, and can do a quick web lookup when the answer is not in memory.
- When there is a tradeoff, prefer the most complete answer even if it takes 1-2 seconds longer. The `project.md` keeps the common case instant; web lookup adds a beat only when needed.
- A small assistant presence: a processing indicator, and a mood/emoji reaction.
- The communication "training" is an original, compact playbook we author (NOT copyrighted book text), always loaded so every answer follows good communication rules.

## Non-goals (this spec)

- Pre-meeting briefing (Phase 2).
- Camera presence coaching, face enrollment, posture/smile/energy nudges (Phase 3).
- Semantic embedding search. We start with context assembly from the compact `project.md` plus keyword-selected transcript snippets, and add embeddings later behind the same interface only if a project's history grows large.

---

## Phase 0 — Quick wins (build first)

### 0.1 Recording picker: hover preview

In `ScreenSourceSheet`, hovering a source row:

- Draws a colored outline over the real window/display on screen (a borderless, click-through `NSPanel` positioned at the source's frame, converted from ScreenCaptureKit's top-left global coordinates to AppKit's bottom-left). Moves/hides as hover changes; torn down when the sheet closes.
- Shows a thumbnail of that source in the row, captured lazily with `SCScreenshotManager.captureImage(contentFilter:configuration:)` at a small size and cached per source id.

### 0.2 Audio in the screen recording

`ScreenVideoRecorder` currently writes video only. Add an audio track to the `.mov`:

- Enable `SCStreamConfiguration.capturesAudio` (system audio) and `captureMicrophone` + a mic device id (macOS 15+/26) so the recording captures both sides of the call.
- Add an `AVAssetWriterInput` for audio, handle `.audio`/`.microphone` sample buffers on the stream, and mux into the same movie.
- This is independent of the meeting's own `recording.m4a` (kept for transcription). The screen `.mov` becomes a self-contained watchable recording with sound.

---

## Phase 1 — The core copilot

### 1.1 Project memory (data model)

Projects are the existing sidebar folders (`Folder`, `FolderKind`). Each project gets a memory stored locally next to meetings, under `Application Support/SKNoteTaker/folders/<folderId>/`:

- `memory.json` — structured, user-editable:
  - `people: [{ name, role, notes }]`
  - `platforms: [String]`
  - `context: String` (free-form notes about the project/company)
  - `imports: [{ id, title, addedAt }]` (metadata; text lives in `imports/<id>.txt`)
- `project.md` — the living knowledge file (see 1.2), regenerated after each meeting.
- `imports/<id>.txt` — imported transcripts, notes, and docs as plain text.

A meeting belongs to a project via its existing `folderId`. Every meeting filed under the folder contributes to the memory, with no extra step.

New core types (SKNoteCore): `ProjectMemory` (Codable), `ProjectMemoryStore` (load/save per folder, import files), and a `ProjectMemoryBuilder` that produces `project.md`.

### 1.2 The living `project.md`

A compact, structured markdown file the assistant reads first. Regenerated (not blindly appended) after each meeting in the project ends, by feeding the project's meeting summaries plus `memory.json` to a Claude call that returns this structure:

```
# <Project> — Working Memory   (updated <date>)

## People
- <name> — <role> — <notes>

## Platforms & tools
- <platform> — <how we use it>

## Context
<free-form project/company context>

## Open tasks (mine)
- [ ] <task> (from <meeting>, <date>)

## Decisions & outcomes
- <date>: <decision / outcome>

## Reusable answers & facts
- Q: <recurring question>  →  A: <the answer / exact wording>

## Glossary
- <term/acronym> — <meaning>

## Meeting log
- <date> — <title> — <one-line gist>
```

It stays small on purpose so it can be loaded into every assistant call cheaply. Full transcripts are pulled in only when a query needs them (1.4).

### 1.3 The communication playbook

A fixed, original guide (authored by us, versioned in the repo, e.g. `Resources/communication-playbook.md`) always injected into the assistant's system prompt. It encodes widely known, non-copyrighted communication principles: be concise and direct, lead with the answer, positive and confident framing, professional tone, mirror the asker's terms, avoid filler, give exact words to say. This is what makes answers "to the point" and well-worded, and being compact it keeps answers fast.

### 1.4 Context assembly (retrieval)

For any assistant query (on-demand or auto-suggested), assemble:

1. The communication playbook (system).
2. The project's `project.md` (always).
3. `memory.json` details (people/platforms/context).
4. The current live transcript, recent window (last N minutes).
5. The specific question.
6. If the question references past specifics, the transcript excerpts of the most relevant past meetings, selected by keyword/entity match against the question (no embeddings yet).
7. If the answer needs external/current info, a web lookup result (1.6).

### 1.5 The live assistant: two modes

Wire into the existing `LiveAssistantPane` and `ClaudeCLIService`.

- On-demand: the user asks; the assistant answers using 1.4.
- Auto-suggest: a lightweight detector watches the live transcript for a question aimed at the user (an utterance ending in `?` from a speaker other than "me", weighted up if it contains the user's name or second-person phrasing). It debounces (fires only after the question settles, rate-limited) and generates a suggested answer shown as a dismissible card. Never spams: only clear, directed questions.

Output contract (both modes), designed for glanceability:

- Say this: one line of exact wording to read aloud.
- Because: 0-2 short supporting bullets (optional).
- Source: memory or web (so the user knows how solid it is).

Model choice: default to a fast model for instant memory answers; escalate to a stronger model when a web lookup or real reasoning is involved. Because the user prefers completeness over raw speed, an answer that triggers web lookup waits for the web result before showing (1-2s), rather than showing a partial then updating.

### 1.6 Web lookup

When memory does not contain the answer (e.g. "how do I add you as a user in Stripe"), the assistant fetches it via the Claude CLI's web search tool (enabled through the CLI's allowed-tools for these calls) and distills it into the exact short wording to say. Only the query text leaves the device; this is disclosed in Settings.

### 1.7 Assistant presence (personality)

A small assistant avatar in the live pane with a few states: idle, thinking (animated while a call is in flight), and a mood emoji that turns to a smiley when the meeting is going well (an occasional, cheap sentiment read of the recent transcript). Purely a presence/feedback layer; it must never block or distract from the answer.

---

## Storage & privacy

- Everything (memory, `project.md`, imports, recordings) is local, under the existing `Application Support/SKNoteTaker` tree. No new cloud.
- Web lookup sends only the query string to the web, and is disclosed. It can be turned off in Settings (a toggle: "Let the assistant search the web").
- The communication playbook is original content shipped in the app.

## Testing

- Unit (SKNoteCore): `ProjectMemory` load/save + import; `ProjectMemoryBuilder` produces the expected `project.md` sections from fixture meetings; the question-aimed-at-me detector (positive/negative utterances); the transcript-snippet selector (keyword match) picks the right past meeting.
- Live: project memory panel shows/edits/imports; filing a meeting under a project updates `project.md`; on-demand Ask returns a short "say this" answer using memory; auto-suggest fires on a directed question and stays quiet otherwise; a Stripe-style question triggers web lookup and returns exact wording; the presence indicator reflects thinking/idle.
- Every change ships with a test report (what/how/actual result/verdict), per project convention.

## Build order within Phase 1

1. Project memory data model + store + the memory panel UI (view/edit people, platforms, context; import files).
2. `project.md` builder + regeneration hook when a meeting in the project ends.
3. Context assembly + communication playbook + on-demand memory-backed answers.
4. Web lookup.
5. Auto-suggest detector + card.
6. Assistant presence indicator.

## Open questions for review

- `project.md` regeneration: after every meeting is simplest and keeps it coherent. If a project has many meetings this feeds summaries (not full transcripts) to stay cheap. Acceptable?
- Importing a previous *recording* (audio/video file) would run it through the existing offline transcription first. Include in Phase 1, or keep Phase 1 to importing text/transcripts and add audio-file import right after?
```
