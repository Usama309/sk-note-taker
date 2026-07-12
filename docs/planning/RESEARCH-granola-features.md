# Granola (granola.ai) — Exhaustive Feature Inventory (as of July 2026)

Granola is a desktop-first "AI notepad" for meetings: it transcribes locally-captured audio without a bot, lets you jot rough notes during the call, then merges your notes with the transcript into polished "enhanced notes."

---

## 1. Core Note-Taking Flow

**The notepad model (human-in-the-loop).** During a meeting you type rough, ad-hoc bullets into a minimal editor while Granola transcribes in the background. Your bullets act as *anchors/priority signals*, not the final notes.

**"Enhance notes" merge.** When the meeting ends you click **Enhance notes**; Granola analyzes the full transcript using your bullets as anchors — each bullet becomes a heading or priority signal, the AI finds all transcript content relevant to that topic, synthesizes it into prose, and inserts it beneath your bullet.

**Black vs. gray text provenance.** Your own writing renders in black; AI-generated additions render in gray. If you edit gray text, it turns black — persistent visual provenance.

**Re-enhancement loop.** Edit enhanced output directly, or edit raw bullets and re-enhance. Also "edit notes just by asking" — natural-language edit commands.

**Templates.** 29+ built-in templates (sales call, 1:1, investor pitch, standup, etc.). Custom templates = markdown outline of section headers plus bracketed AI hints. Templates can auto-apply via trigger rules (calendar title keywords, attendee domains) and can be switched after the fact (regenerates notes).

**Editor.** Two-pane: raw notes tab + Enhanced tab; transcript alongside. Dark mode, file uploads into notes/chat, offline access to existing notes.

## 2. Audio Capture & Transcription

- **Botless dual-stream capture**: microphone ("Me") + system audio output ("Them") — no bot joins the call. Audio streamed to third-party ASR in real time, **never recorded/stored** (no playback later).
- **Platform-agnostic**: works with Zoom, Meet, Teams, any VoIP app; in-person via mic. Side effect: no app-audio isolation (background music leaks in).
- **Real-time transcript UI**: green ("Me") and gray ("Them") bubbles. Custom vocabulary ("Internal Jargon") list. 10 languages. No pre-recorded file import.
- **Speaker diarization: ABSENT on desktop.** Only Me/Them; all remote participants collapse into "Them." Only the iPhone app does multi-speaker recognition (in-person only).

## 3. Calendar Integration & Meeting Detection

- Google + Microsoft calendar sync (no Apple Calendar). Metadata feeds note context.
- Notification ~1 min before meetings with 2+ attendees; one click opens call link + starts transcription.
- Ad-hoc detection: watches for mic-in-use and offers to start notes; can be disabled.
- **Briefs**: overnight meeting prep — who you're meeting, last discussion, open threads.

## 4. AI Features

- Summaries/action items via template-driven enhancement; post-meeting follow-up email and project plan drafts.
- **Granola Chat** (single meeting) — works live during the call.
- **Chat across meetings**: folder / all / selected set. Default scope = summaries of 40 most recent; full transcripts capped at 25. Citations link back to source meetings.
- **Recipes** (Sep 2025): reusable prompt templates in Chat ("Coach Me", "Write a Brief"); user-savable.

## 5. Organization

- **Workspaces** → **Folders/Team Folders** (auto-add rules, per-folder Slack posting, visibility controls) → **Spaces** (Mar 2026; shared notes + shared chat over org context).
- Full-text search + semantic retrieval via Chat with citations.

## 6. Sharing & Collaboration

- Private by default. Per-note share links (Anyone / company / private); Enterprise admin policies.
- Integrations (Business): Slack, Notion (rows in DB), HubSpot/Attio/Affinity auto-match via attendees; Salesforce via Zapier only.

## 7. Platforms & Sync

- macOS, Windows (Jun 2025), iOS (Apr 2025), Android (Jul 2026).
- **Web app notes.granola.ai: view/edit only, cannot capture.**
- Cloud sync near-instant; offline access to synced notes.

## 8. MCP Server & API

- **Official Granola MCP** (Feb 2026): hosted `https://mcp.granola.ai/mcp`. Tools: list/query meetings, browse folders, retrieve transcripts, `query_granola_meetings` (server-side chat, cited answer). Paid-plan gated.
- **Public REST API**: `GET /notes`, `GET /notes/{id}?include=transcript`; Bearer `grn_` keys; Business+.

## 9. Pricing

| Tier | Price | Gates |
|---|---|---|
| Basic | $0 | limited history (~30 days lock) |
| Business | $14/u/mo | unlimited history, advanced models, integrations, MCP, API |
| Enterprise | $35/u/mo | SSO, admin controls, auto-deletion, analytics |

## 10. Limitations = Our Opportunities

1. **No desktop speaker diarization** (confirmed by official docs) — our headline upgrade.
2. **No audio recording/playback** — we record full meeting audio.
3. Free-tier history lock — ours is local and unlimited.
4. ASR accuracy ~90-92%, jargon issues.
5. No audio-source isolation.
6. No file import; web can't capture.
7. API read-only, no webhooks/OAuth.
8. Privacy debate: participants not notified.
