#!/usr/bin/env node
/**
 * SK Note Taker MCP stdio server.
 *
 * Exposes the on-disk meeting-notes store (see docs/planning/DATA-MODEL.md) to
 * MCP clients as read-only tools. stdout carries JSON-RPC only; all diagnostics
 * go to stderr via warn().
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import {
  fileExists,
  folderPathFor,
  loadAllMeetings,
  loadMeeting,
  readJson,
  readText,
  resolveDataDir,
  warn,
  type FolderJson,
  type FoldersFile,
  type LoadedMeeting,
  type TranscriptJson,
} from "./store.js";
import { parseSummary } from "./summary.js";
import { findFirstHit } from "./search.js";
import {
  renderSegments,
  renderTranscriptText,
  type RenderedSegment,
} from "./transcript.js";
import path from "node:path";

/** Wrap a structured result as MCP tool content (text JSON + structuredContent). */
function jsonResult(data: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
    structuredContent: data as Record<string, unknown>,
  };
}

/** Collect ordered speaker display names for a meeting. */
function speakerNames(meeting: LoadedMeeting): string[] {
  const speakers = meeting.meeting.speakers ?? {};
  return Object.keys(speakers)
    .sort()
    .map((key) => {
      const s = speakers[key];
      return s.name?.trim() || s.label?.trim() || key;
    });
}

/** Load folders.json defensively; empty tree when missing/malformed. */
async function loadFolders(dataDir: string): Promise<FolderJson[]> {
  const file = await readJson<FoldersFile>(path.join(dataDir, "folders.json"));
  return file?.folders ?? [];
}

/** Build the list_meetings summary shape for one meeting. */
async function meetingSummary(
  meeting: LoadedMeeting,
  folders: FolderJson[]
) {
  const m = meeting.meeting;
  const hasSummary = await fileExists(meeting.paths.summaryMd);
  return {
    id: meeting.id,
    title: m.title ?? "(untitled)",
    createdAt: m.createdAt ?? null,
    durationSec: typeof m.durationSec === "number" ? m.durationSec : null,
    folderId: m.folderId ?? null,
    folderPath: folderPathFor(folders, m.folderId),
    state: m.state ?? null,
    speakerNames: speakerNames(meeting),
    hasSummary,
  };
}

function createServer(): McpServer {
  const server = new McpServer({
    name: "sk-note-taker",
    version: "0.1.0",
  });

  // --- list_meetings -------------------------------------------------------
  server.registerTool(
    "list_meetings",
    {
      title: "List meetings",
      description:
        "List meeting-note sessions with metadata. Optionally filter by folderId, cap with limit, or return only meetings created at/after an ISO timestamp (since).",
      inputSchema: {
        folderId: z
          .string()
          .optional()
          .describe("Only include meetings assigned to this folder id."),
        limit: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("Maximum number of meetings to return (newest first)."),
        since: z
          .string()
          .optional()
          .describe("ISO-8601 timestamp; include only meetings created at/after it."),
      },
    },
    async ({ folderId, limit, since }) => {
      const dataDir = resolveDataDir();
      const [meetings, folders] = await Promise.all([
        loadAllMeetings(dataDir),
        loadFolders(dataDir),
      ]);

      let filtered = meetings;
      if (folderId !== undefined) {
        filtered = filtered.filter((m) => m.meeting.folderId === folderId);
      }
      if (since !== undefined) {
        const sinceMs = Date.parse(since);
        if (!Number.isNaN(sinceMs)) {
          filtered = filtered.filter((m) => {
            const created = m.meeting.createdAt
              ? Date.parse(m.meeting.createdAt)
              : NaN;
            return !Number.isNaN(created) && created >= sinceMs;
          });
        } else {
          warn(`list_meetings: ignoring unparseable "since" value: ${since}`);
        }
      }

      // Newest first by createdAt.
      filtered.sort((a, b) => {
        const ta = a.meeting.createdAt ? Date.parse(a.meeting.createdAt) : 0;
        const tb = b.meeting.createdAt ? Date.parse(b.meeting.createdAt) : 0;
        return tb - ta;
      });

      if (limit !== undefined) {
        filtered = filtered.slice(0, limit);
      }

      const result = await Promise.all(
        filtered.map((m) => meetingSummary(m, folders))
      );
      return jsonResult({ meetings: result, count: result.length });
    }
  );

  // --- get_meeting ---------------------------------------------------------
  server.registerTool(
    "get_meeting",
    {
      title: "Get meeting",
      description:
        "Fetch full metadata (meeting.json) and raw notes (notes.md) for one meeting, plus flags for which artifacts (transcript/summary/chat/recording) exist.",
      inputSchema: {
        id: z.string().describe("Meeting id (its directory name / UUID)."),
      },
    },
    async ({ id }) => {
      const dataDir = resolveDataDir();
      const meeting = await loadMeeting(dataDir, id);
      if (!meeting) {
        return jsonResult({ error: `Meeting not found: ${id}`, id });
      }
      const folders = await loadFolders(dataDir);
      const [notes, hasTranscript, hasSummary, hasChat, hasRecording] =
        await Promise.all([
          readText(meeting.paths.notesMd),
          fileExists(meeting.paths.transcriptJson),
          fileExists(meeting.paths.summaryMd),
          fileExists(meeting.paths.chatJson),
          fileExists(meeting.paths.recording),
        ]);

      return jsonResult({
        id: meeting.id,
        meeting: meeting.meeting,
        folderPath: folderPathFor(folders, meeting.meeting.folderId),
        notes: notes ?? null,
        hasNotes: notes !== undefined,
        hasTranscript,
        hasSummary,
        hasChat,
        hasRecording,
      });
    }
  );

  // --- get_transcript ------------------------------------------------------
  server.registerTool(
    "get_transcript",
    {
      title: "Get transcript",
      description:
        "Return a meeting's diarized transcript. With resolveNames (default true) speaker keys (S1, S2…) are replaced by names from the meeting's speakers map, falling back to a 'Speaker N' label. Returns readable lines and structured segments.",
      inputSchema: {
        id: z.string().describe("Meeting id (its directory name / UUID)."),
        resolveNames: z
          .boolean()
          .optional()
          .describe("Resolve speaker keys to names (default true)."),
      },
    },
    async ({ id, resolveNames }) => {
      const dataDir = resolveDataDir();
      const meeting = await loadMeeting(dataDir, id);
      if (!meeting) {
        return jsonResult({ error: `Meeting not found: ${id}`, id });
      }
      const transcript = await readJson<TranscriptJson>(
        meeting.paths.transcriptJson
      );
      if (!transcript) {
        return jsonResult({
          id: meeting.id,
          error: "No transcript available for this meeting.",
          segments: [],
          text: "",
        });
      }

      const resolve = resolveNames ?? true;
      const segments: RenderedSegment[] = renderSegments(
        transcript.segments ?? [],
        meeting.meeting.speakers,
        resolve
      );

      return jsonResult({
        id: meeting.id,
        title: meeting.meeting.title ?? null,
        resolvedNames: resolve,
        segmentCount: segments.length,
        text: renderTranscriptText(segments),
        segments,
      });
    }
  );

  // --- get_summary ---------------------------------------------------------
  server.registerTool(
    "get_summary",
    {
      title: "Get summary",
      description:
        "Return a meeting's AI summary (summary.md): the YAML front-matter parsed into structured actionItems/decisions/remember plus the markdown body.",
      inputSchema: {
        id: z.string().describe("Meeting id (its directory name / UUID)."),
      },
    },
    async ({ id }) => {
      const dataDir = resolveDataDir();
      const meeting = await loadMeeting(dataDir, id);
      if (!meeting) {
        return jsonResult({ error: `Meeting not found: ${id}`, id });
      }
      const raw = await readText(meeting.paths.summaryMd);
      if (raw === undefined) {
        return jsonResult({
          id: meeting.id,
          error: "No summary available for this meeting.",
          hasSummary: false,
        });
      }
      const parsed = parseSummary(raw);
      return jsonResult({
        id: meeting.id,
        title: meeting.meeting.title ?? null,
        hasSummary: true,
        hasFrontMatter: parsed.hasFrontMatter,
        generatedAt: parsed.frontMatter.generatedAt ?? null,
        actionItems: parsed.frontMatter.actionItems,
        decisions: parsed.frontMatter.decisions,
        remember: parsed.frontMatter.remember,
        extra: parsed.frontMatter.extra,
        body: parsed.body,
        raw,
      });
    }
  );

  // --- search_meetings -----------------------------------------------------
  server.registerTool(
    "search_meetings",
    {
      title: "Search meetings",
      description:
        "Case-insensitive search across meeting titles, notes, transcript text, and summaries. Returns matching meetings with a snippet showing the first hit.",
      inputSchema: {
        query: z.string().min(1).describe("Text to search for."),
        limit: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("Maximum number of matches to return."),
      },
    },
    async ({ query, limit }) => {
      const dataDir = resolveDataDir();
      const meetings = await loadAllMeetings(dataDir);

      const matches: Array<{
        id: string;
        title: string;
        field: string;
        snippet: string;
      }> = [];

      for (const meeting of meetings) {
        const title = meeting.meeting.title ?? "";
        const [notes, transcript, summary] = await Promise.all([
          readText(meeting.paths.notesMd),
          readJson<TranscriptJson>(meeting.paths.transcriptJson),
          readText(meeting.paths.summaryMd),
        ]);

        const transcriptText = (transcript?.segments ?? [])
          .map((s) => s.text ?? "")
          .join(" ");

        const hit = findFirstHit(query, [
          { field: "title", text: title },
          { field: "notes", text: notes },
          { field: "transcript", text: transcriptText },
          { field: "summary", text: summary },
        ]);

        if (hit) {
          matches.push({
            id: meeting.id,
            title: title || "(untitled)",
            field: hit.field,
            snippet: hit.snippet,
          });
        }
      }

      const limited =
        limit !== undefined ? matches.slice(0, limit) : matches;
      return jsonResult({
        query,
        count: limited.length,
        matches: limited,
      });
    }
  );

  // --- list_folders --------------------------------------------------------
  server.registerTool(
    "list_folders",
    {
      title: "List folders",
      description:
        "Return the folder tree (from folders.json) with each folder's full path and the number of meetings assigned to it.",
      inputSchema: {},
    },
    async () => {
      const dataDir = resolveDataDir();
      const [folders, meetings] = await Promise.all([
        loadFolders(dataDir),
        loadAllMeetings(dataDir),
      ]);

      const countByFolder = new Map<string, number>();
      for (const m of meetings) {
        const fid = m.meeting.folderId;
        if (fid) {
          countByFolder.set(fid, (countByFolder.get(fid) ?? 0) + 1);
        }
      }

      const tree = folders.map((f) => ({
        id: f.id ?? null,
        name: f.name ?? "(unnamed)",
        kind: f.kind ?? null,
        parentId: f.parentId ?? null,
        path: folderPathFor(folders, f.id),
        meetingCount: f.id ? countByFolder.get(f.id) ?? 0 : 0,
      }));

      const uncategorized = meetings.filter((m) => !m.meeting.folderId).length;

      return jsonResult({
        folders: tree,
        count: tree.length,
        uncategorizedMeetings: uncategorized,
      });
    }
  );

  return server;
}

async function main(): Promise<void> {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  warn(`sk-note-taker MCP server started (data dir: ${resolveDataDir()})`);
}

main().catch((err) => {
  warn(`fatal: ${(err as Error).stack ?? String(err)}`);
  process.exit(1);
});
