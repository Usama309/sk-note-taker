#!/usr/bin/env node
/**
 * SK Note Taker MCP stdio server.
 *
 * Exposes the SK Note Taker cloud store (Supabase Postgres — see
 * ../supabase/migrations/0001_init.sql) to MCP clients as read-only tools.
 * stdout carries JSON-RPC only; all diagnostics go to stderr via warn().
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import {
  describeSource,
  folderPathFor,
  getClient,
  hasChat,
  hasTranscript,
  loadFolders,
  loadMeeting,
  loadSummary,
  loadTranscript,
  mapMeeting,
  warn,
  type FolderJson,
  type LoadedMeeting,
  type MeetingRow,
  type SummaryRow,
  type TranscriptSegmentRow,
} from "./store.js";
import { mapSummary } from "./summary.js";
import { findFirstHit } from "./search.js";
import {
  renderSegments,
  renderTranscriptText,
  type RenderedSegment,
} from "./transcript.js";

const MEETING_COLUMNS =
  "id,title,created_at,ended_at,folder_id,state,speakers,has_recording,duration_sec,auto_category,notes,updated_at";

/** Wrap a structured result as MCP tool content (text JSON + structuredContent). */
function jsonResult(data: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
    structuredContent: data as Record<string, unknown>,
  };
}

/** Wrap a Supabase/tool error as a graceful MCP result (never throws). */
function errorResult(message: string, extra?: Record<string, unknown>) {
  return jsonResult({ error: message, ...extra });
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
      try {
        const client = await getClient();

        let query = client
          .from("meetings")
          .select(MEETING_COLUMNS)
          .order("created_at", { ascending: false });
        if (folderId !== undefined) {
          query = query.eq("folder_id", folderId);
        }
        if (since !== undefined) {
          const sinceMs = Date.parse(since);
          if (!Number.isNaN(sinceMs)) {
            query = query.gte("created_at", new Date(sinceMs).toISOString());
          } else {
            warn(`list_meetings: ignoring unparseable "since" value: ${since}`);
          }
        }
        if (limit !== undefined) {
          query = query.limit(limit);
        }

        const { data: rows, error } = await query;
        if (error) {
          return errorResult(error.message);
        }

        const meetingRows = (rows ?? []) as MeetingRow[];
        const folderIds = meetingRows
          .map((r) => r.folder_id)
          .filter((f): f is string => !!f);

        // Which of these meetings have a summary? One bulk query.
        const ids = meetingRows.map((r) => r.id);
        const summaryIds = new Set<string>();
        if (ids.length > 0) {
          const { data: sumRows, error: sumErr } = await client
            .from("summaries")
            .select("meeting_id")
            .in("meeting_id", ids);
          if (sumErr) {
            return errorResult(sumErr.message);
          }
          for (const s of sumRows ?? []) {
            summaryIds.add((s as { meeting_id: string }).meeting_id);
          }
        }

        // Resolve folder paths (fetch folders only if any meeting is filed).
        let folders: FolderJson[] = [];
        if (folderIds.length > 0) {
          const foldersRes = await loadFolders();
          if (foldersRes.error) {
            return errorResult(foldersRes.error);
          }
          folders = foldersRes.data ?? [];
        }

        const meetings = meetingRows.map((row) => {
          const m = mapMeeting(row);
          const loaded: LoadedMeeting = { id: row.id, row, meeting: m };
          return {
            id: row.id,
            title: m.title ?? "(untitled)",
            createdAt: m.createdAt ?? null,
            durationSec: typeof m.durationSec === "number" ? m.durationSec : null,
            folderId: m.folderId ?? null,
            folderPath: folderPathFor(folders, m.folderId),
            state: m.state ?? null,
            speakerNames: speakerNames(loaded),
            hasSummary: summaryIds.has(row.id),
          };
        });

        return jsonResult({ meetings, count: meetings.length });
      } catch (err) {
        return errorResult(`list_meetings failed: ${(err as Error).message}`);
      }
    }
  );

  // --- get_meeting ---------------------------------------------------------
  server.registerTool(
    "get_meeting",
    {
      title: "Get meeting",
      description:
        "Fetch full metadata and raw notes for one meeting, plus flags for which artifacts (transcript/summary/chat/recording) exist.",
      inputSchema: {
        id: z.string().describe("Meeting id (UUID)."),
      },
    },
    async ({ id }) => {
      try {
        const meetingRes = await loadMeeting(id);
        if (meetingRes.error) {
          return errorResult(meetingRes.error, { id });
        }
        const meeting = meetingRes.data;
        if (!meeting) {
          return errorResult(`Meeting not found: ${id}`, { id });
        }

        const [foldersRes, txRes, chatRes, summaryRes] = await Promise.all([
          loadFolders(),
          hasTranscript(id),
          hasChat(id),
          loadSummary(id),
        ]);
        for (const r of [foldersRes, txRes, chatRes, summaryRes]) {
          if (r.error) {
            return errorResult(r.error, { id });
          }
        }

        const notes = meeting.meeting.notes ?? "";
        return jsonResult({
          id: meeting.id,
          meeting: meeting.meeting,
          folderPath: folderPathFor(foldersRes.data ?? [], meeting.meeting.folderId),
          notes: notes.length > 0 ? notes : null,
          hasNotes: notes.length > 0,
          hasTranscript: txRes.data ?? false,
          hasSummary: summaryRes.data !== undefined,
          hasChat: chatRes.data ?? false,
          hasRecording: meeting.meeting.hasRecording ?? false,
        });
      } catch (err) {
        return errorResult(`get_meeting failed: ${(err as Error).message}`, { id });
      }
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
        id: z.string().describe("Meeting id (UUID)."),
        resolveNames: z
          .boolean()
          .optional()
          .describe("Resolve speaker keys to names (default true)."),
      },
    },
    async ({ id, resolveNames }) => {
      try {
        const meetingRes = await loadMeeting(id);
        if (meetingRes.error) {
          return errorResult(meetingRes.error, { id });
        }
        const meeting = meetingRes.data;
        if (!meeting) {
          return errorResult(`Meeting not found: ${id}`, { id });
        }

        const txRes = await loadTranscript(id);
        if (txRes.error) {
          return errorResult(txRes.error, { id });
        }
        const segmentsRaw = txRes.data ?? [];
        if (segmentsRaw.length === 0) {
          return jsonResult({
            id: meeting.id,
            error: "No transcript available for this meeting.",
            segments: [],
            text: "",
          });
        }

        const resolve = resolveNames ?? true;
        const segments: RenderedSegment[] = renderSegments(
          segmentsRaw,
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
      } catch (err) {
        return errorResult(`get_transcript failed: ${(err as Error).message}`, { id });
      }
    }
  );

  // --- get_summary ---------------------------------------------------------
  server.registerTool(
    "get_summary",
    {
      title: "Get summary",
      description:
        "Return a meeting's AI summary: structured actionItems/decisions/remember plus the markdown body.",
      inputSchema: {
        id: z.string().describe("Meeting id (UUID)."),
      },
    },
    async ({ id }) => {
      try {
        const meetingRes = await loadMeeting(id);
        if (meetingRes.error) {
          return errorResult(meetingRes.error, { id });
        }
        const meeting = meetingRes.data;
        if (!meeting) {
          return errorResult(`Meeting not found: ${id}`, { id });
        }

        const summaryRes = await loadSummary(id);
        if (summaryRes.error) {
          return errorResult(summaryRes.error, { id });
        }
        const row = summaryRes.data;
        if (!row) {
          return jsonResult({
            id: meeting.id,
            error: "No summary available for this meeting.",
            hasSummary: false,
          });
        }

        const mapped = mapSummary(row);
        return jsonResult({
          id: meeting.id,
          title: meeting.meeting.title ?? null,
          hasSummary: true,
          generatedAt: mapped.generatedAt ?? null,
          actionItems: mapped.actionItems,
          decisions: mapped.decisions,
          remember: mapped.remember,
          body: mapped.body,
        });
      } catch (err) {
        return errorResult(`get_summary failed: ${(err as Error).message}`, { id });
      }
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
      try {
        const client = await getClient();

        // Pull all meetings (title + notes), then join transcript + summary text
        // in JS so the field-priority order (title → notes → transcript → summary)
        // matches the original file-based server.
        const { data: rows, error } = await client
          .from("meetings")
          .select(MEETING_COLUMNS)
          .order("created_at", { ascending: false });
        if (error) {
          return errorResult(error.message);
        }
        const meetingRows = (rows ?? []) as MeetingRow[];
        const ids = meetingRows.map((r) => r.id);

        // Bulk-load transcript segments + summaries for these meetings.
        const transcriptByMeeting = new Map<string, string>();
        const summaryText = new Map<string, string>();
        if (ids.length > 0) {
          const [{ data: segRows, error: segErr }, { data: sumRows, error: sumErr }] =
            await Promise.all([
              client
                .from("transcript_segments")
                .select("meeting_id,idx,text")
                .in("meeting_id", ids)
                .order("idx", { ascending: true }),
              client
                .from("summaries")
                .select("meeting_id,body,action_items,decisions,remember")
                .in("meeting_id", ids),
            ]);
          if (segErr) {
            return errorResult(segErr.message);
          }
          if (sumErr) {
            return errorResult(sumErr.message);
          }
          for (const s of (segRows ?? []) as Pick<TranscriptSegmentRow, "meeting_id" | "text">[]) {
            const prev = transcriptByMeeting.get(s.meeting_id) ?? "";
            transcriptByMeeting.set(
              s.meeting_id,
              prev ? `${prev} ${s.text ?? ""}` : s.text ?? ""
            );
          }
          for (const s of (sumRows ?? []) as SummaryRow[]) {
            // Fold body + jsonb fields into one searchable blob.
            const mapped = mapSummary(s);
            const parts = [
              mapped.body,
              ...mapped.actionItems.map((a) =>
                [a.owner, a.text].filter(Boolean).join(" ")
              ),
              ...mapped.decisions,
              ...mapped.remember,
            ].filter(Boolean);
            summaryText.set(s.meeting_id, parts.join("\n"));
          }
        }

        const matches: Array<{
          id: string;
          title: string;
          field: string;
          snippet: string;
        }> = [];

        for (const row of meetingRows) {
          const title = row.title ?? "";
          const notes = row.notes ?? "";
          const transcript = transcriptByMeeting.get(row.id) ?? "";
          const summary = summaryText.get(row.id) ?? "";

          const hit = findFirstHit(query, [
            { field: "title", text: title },
            { field: "notes", text: notes },
            { field: "transcript", text: transcript },
            { field: "summary", text: summary },
          ]);

          if (hit) {
            matches.push({
              id: row.id,
              title: title || "(untitled)",
              field: hit.field,
              snippet: hit.snippet,
            });
          }
        }

        const limited = limit !== undefined ? matches.slice(0, limit) : matches;
        return jsonResult({
          query,
          count: limited.length,
          matches: limited,
        });
      } catch (err) {
        return errorResult(`search_meetings failed: ${(err as Error).message}`);
      }
    }
  );

  // --- list_folders --------------------------------------------------------
  server.registerTool(
    "list_folders",
    {
      title: "List folders",
      description:
        "Return the folder tree with each folder's full path and the number of meetings assigned to it.",
      inputSchema: {},
    },
    async () => {
      try {
        const client = await getClient();
        const foldersRes = await loadFolders();
        if (foldersRes.error) {
          return errorResult(foldersRes.error);
        }
        const folders = foldersRes.data ?? [];

        // Fetch every meeting's folder_id to count assignments.
        const { data: rows, error } = await client
          .from("meetings")
          .select("id,folder_id");
        if (error) {
          return errorResult(error.message);
        }
        const meetingRows = (rows ?? []) as Array<{ id: string; folder_id: string | null }>;

        const countByFolder = new Map<string, number>();
        for (const m of meetingRows) {
          if (m.folder_id) {
            countByFolder.set(m.folder_id, (countByFolder.get(m.folder_id) ?? 0) + 1);
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

        const uncategorized = meetingRows.filter((m) => !m.folder_id).length;

        return jsonResult({
          folders: tree,
          count: tree.length,
          uncategorizedMeetings: uncategorized,
        });
      } catch (err) {
        return errorResult(`list_folders failed: ${(err as Error).message}`);
      }
    }
  );

  return server;
}

async function main(): Promise<void> {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  warn(`sk-note-taker MCP server started (source: ${await describeSource()})`);
}

main().catch((err) => {
  warn(`fatal: ${(err as Error).stack ?? String(err)}`);
  process.exit(1);
});
