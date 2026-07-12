# SK Note Taker — Original Instructions (verbatim intent)

Captured: 2026-07-12. Source: Saqib Kamran (voice prompt, transcribed).

## The Request

1. **Research Granola in detail** — look at every feature they have. Granola is installed on this
   system; go through its file structure and data as part of the research.
2. **Build exactly the same app for Mac**, with these differences:
   - **AI features via Claude Code CLI** (the user's Claude Code subscription), NOT a paid API.
   - **Totally different branding**: the app is called **"SK Note Taker"**.
   - Design a **very beautiful layout** and a **beautiful logo**.
3. **Publish on GitHub.**
4. **Core behavior**: takes notes exactly like Granola — captures input from **mic and speaker**
   simultaneously and transcribes in **real time**.
5. **Upgrade over Granola: multi-speaker identification (diarization).**
   - Live transcript labels utterances as Speaker 1, Speaker 2, Speaker 3…
   - Record meetings entirely with the multiple speakers.
6. **Speaker naming**: in the settings for a particular note/meeting, the user can assign a name
   to each speaker (e.g. "Speaker 2 = Kainat"). After that, the transcript reads "Kainat said…"
   and the user can ask questions like "What did Kainat say?" and the app answers from the
   transcription.
7. **Auto-categorization**: meetings are organized into subfolders by **project and client**.
8. **MCP access**: an MCP server through which meetings, transcriptions, and summaries can be
   accessed.
9. **Intelligent summaries**: action items, action list, things to remember, decisions, etc.
10. **Platform**: native **Mac app**, plus a **web app view** to review all meetings when away
    from the computer.

## Process the user asked for

1. Put this entire instruction into a file (this file).
2. Do the planning + research; keep preparing planning files.
3. Produce the implementation plan.
4. Execute the implementation.
5. Test each and every feature — the app must be fully working.
6. Everything is done autonomously (user is away). Report when done.
