/**
 * Data-access layer for the SK Note Taker Supabase store.
 *
 * The Mac app is local-first and mirrors all meeting data to a Supabase Postgres
 * project (see ../supabase/migrations/0001_init.sql). This layer reads that cloud
 * data via @supabase/supabase-js so the MCP server can serve meetings/transcripts/
 * summaries from anywhere.
 *
 * All reads are defensive: Supabase/network errors are surfaced as an error string
 * rather than crashing the server. Nothing here writes to the store — the MCP
 * server is read-only. stdout is reserved for JSON-RPC; diagnostics go to stderr.
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/** Log a warning to stderr. stdout is reserved for JSON-RPC traffic. */
export function warn(message: string): void {
  process.stderr.write(`[sknote-mcp] WARN ${message}\n`);
}

// ---------------------------------------------------------------------------
// Config + client
// ---------------------------------------------------------------------------

const here = path.dirname(fileURLToPath(import.meta.url));
/** dist/ lives at mcp/dist, so the repo's supabase/config.json is ../../supabase. */
const DEFAULT_CONFIG_PATH = path.resolve(here, "..", "..", "supabase", "config.json");

interface SupabaseConfig {
  url: string;
  anonKey: string;
}

/**
 * Resolve Supabase credentials. Environment variables SUPABASE_URL /
 * SUPABASE_ANON_KEY take precedence; otherwise read supabase/config.json
 * (path overridable via SKNOTE_SUPABASE_CONFIG).
 */
async function resolveConfig(): Promise<SupabaseConfig> {
  const envUrl = process.env.SUPABASE_URL?.trim();
  const envKey = process.env.SUPABASE_ANON_KEY?.trim();
  if (envUrl && envKey) {
    return { url: envUrl, anonKey: envKey };
  }

  const configPath = process.env.SKNOTE_SUPABASE_CONFIG?.trim() || DEFAULT_CONFIG_PATH;
  let raw: string;
  try {
    raw = await fs.readFile(configPath, "utf8");
  } catch (err) {
    throw new Error(
      `could not read Supabase config at ${configPath}: ${(err as Error).message}. ` +
        `Set SUPABASE_URL and SUPABASE_ANON_KEY, or SKNOTE_SUPABASE_CONFIG.`
    );
  }
  let parsed: { url?: string; anonKey?: string };
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`malformed Supabase config ${configPath}: ${(err as Error).message}`);
  }
  const url = envUrl || parsed.url?.trim();
  const anonKey = envKey || parsed.anonKey?.trim();
  if (!url || !anonKey) {
    throw new Error(
      `Supabase config is missing url/anonKey (checked env + ${configPath}).`
    );
  }
  return { url, anonKey };
}

let clientPromise: Promise<SupabaseClient> | undefined;

/** Lazily create a single shared Supabase client. */
export async function getClient(): Promise<SupabaseClient> {
  if (!clientPromise) {
    clientPromise = resolveConfig().then(({ url, anonKey }) =>
      createClient(url, anonKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      })
    );
  }
  return clientPromise;
}

/** For diagnostics: the resolved project URL (never the key). */
export async function describeSource(): Promise<string> {
  try {
    const { url } = await resolveConfig();
    return url;
  } catch (err) {
    return `<unresolved: ${(err as Error).message}>`;
  }
}

// ---------------------------------------------------------------------------
// Row shapes (snake_case, matching the Postgres schema) + camelCase mappings.
// ---------------------------------------------------------------------------

export interface Speaker {
  label?: string;
  name?: string;
  source?: string;
}

export interface MeetingRow {
  id: string;
  title: string | null;
  created_at: string | null;
  ended_at: string | null;
  folder_id: string | null;
  state: string | null;
  speakers: Record<string, Speaker> | null;
  has_recording: boolean | null;
  duration_sec: number | null;
  auto_category: unknown;
  notes: string | null;
  updated_at: string | null;
}

/** The camelCase meeting object returned to clients (mirrors the old meeting.json shape). */
export interface MeetingJson {
  id: string;
  title?: string;
  createdAt?: string;
  endedAt?: string;
  folderId?: string | null;
  state?: string;
  speakers?: Record<string, Speaker>;
  hasRecording?: boolean;
  durationSec?: number;
  autoCategory?: unknown;
  notes?: string;
  updatedAt?: string;
}

export function mapMeeting(row: MeetingRow): MeetingJson {
  return {
    id: row.id,
    title: row.title ?? undefined,
    createdAt: row.created_at ?? undefined,
    endedAt: row.ended_at ?? undefined,
    folderId: row.folder_id ?? null,
    state: row.state ?? undefined,
    speakers: row.speakers ?? {},
    hasRecording: row.has_recording ?? false,
    durationSec: typeof row.duration_sec === "number" ? row.duration_sec : undefined,
    autoCategory: row.auto_category ?? undefined,
    notes: row.notes ?? "",
    updatedAt: row.updated_at ?? undefined,
  };
}

export interface FolderRow {
  id: string;
  name: string | null;
  kind: string | null;
  parent_id: string | null;
}

export interface FolderJson {
  id?: string;
  name?: string;
  kind?: string;
  parentId?: string | null;
}

export function mapFolder(row: FolderRow): FolderJson {
  return {
    id: row.id,
    name: row.name ?? undefined,
    kind: row.kind ?? undefined,
    parentId: row.parent_id ?? null,
  };
}

export interface TranscriptSegmentRow {
  meeting_id: string;
  idx: number;
  speaker: string | null;
  source: string | null;
  start_sec: number | null;
  end_sec: number | null;
  text: string | null;
}

/** The camelCase transcript segment (mirrors the old transcript.json segment shape). */
export interface TranscriptSegment {
  id?: number;
  speaker?: string;
  source?: string;
  start?: number;
  end?: number;
  text?: string;
}

export function mapSegment(row: TranscriptSegmentRow): TranscriptSegment {
  return {
    id: row.idx,
    speaker: row.speaker ?? undefined,
    source: row.source ?? undefined,
    start: typeof row.start_sec === "number" ? row.start_sec : undefined,
    end: typeof row.end_sec === "number" ? row.end_sec : undefined,
    text: row.text ?? "",
  };
}

export interface SummaryRow {
  meeting_id: string;
  generated_at: string | null;
  body: string | null;
  action_items: unknown;
  decisions: unknown;
  remember: unknown;
}

/** A meeting row paired with its derived id and camelCase view. */
export interface LoadedMeeting {
  id: string;
  row: MeetingRow;
  meeting: MeetingJson;
}

// ---------------------------------------------------------------------------
// Query helpers. Each returns { data, error } so callers can surface the error
// in a tool result instead of throwing.
// ---------------------------------------------------------------------------

export interface Result<T> {
  data?: T;
  error?: string;
}

const MEETING_COLUMNS =
  "id,title,created_at,ended_at,folder_id,state,speakers,has_recording,duration_sec,auto_category,notes,updated_at";

function toResult<T>(data: T | null, error: { message: string } | null): Result<T> {
  if (error) {
    warn(`supabase error: ${error.message}`);
    return { error: error.message };
  }
  return { data: (data ?? undefined) as T };
}

/** Load one meeting by id. `data` is undefined (no error) when not found. */
export async function loadMeeting(id: string): Promise<Result<LoadedMeeting | undefined>> {
  const client = await getClient();
  const { data, error } = await client
    .from("meetings")
    .select(MEETING_COLUMNS)
    .eq("id", id)
    .maybeSingle();
  if (error) {
    warn(`supabase error (loadMeeting ${id}): ${error.message}`);
    return { error: error.message };
  }
  if (!data) {
    return { data: undefined };
  }
  const row = data as MeetingRow;
  return { data: { id: row.id, row, meeting: mapMeeting(row) } };
}

/** Load all folders. */
export async function loadFolders(): Promise<Result<FolderJson[]>> {
  const client = await getClient();
  const { data, error } = await client
    .from("folders")
    .select("id,name,kind,parent_id");
  const res = toResult(data as FolderRow[] | null, error);
  if (res.error) return { error: res.error };
  return { data: (res.data ?? []).map(mapFolder) };
}

/** Load transcript segments for a meeting, ordered by idx. */
export async function loadTranscript(
  id: string
): Promise<Result<TranscriptSegment[]>> {
  const client = await getClient();
  const { data, error } = await client
    .from("transcript_segments")
    .select("meeting_id,idx,speaker,source,start_sec,end_sec,text")
    .eq("meeting_id", id)
    .order("idx", { ascending: true });
  const res = toResult(data as TranscriptSegmentRow[] | null, error);
  if (res.error) return { error: res.error };
  return { data: (res.data ?? []).map(mapSegment) };
}

/** Load a meeting's summary row. `data` undefined (no error) when absent. */
export async function loadSummary(id: string): Promise<Result<SummaryRow | undefined>> {
  const client = await getClient();
  const { data, error } = await client
    .from("summaries")
    .select("meeting_id,generated_at,body,action_items,decisions,remember")
    .eq("meeting_id", id)
    .maybeSingle();
  if (error) {
    warn(`supabase error (loadSummary ${id}): ${error.message}`);
    return { error: error.message };
  }
  return { data: (data as SummaryRow | null) ?? undefined };
}

/** True/false whether a meeting has any transcript segments. */
export async function hasTranscript(id: string): Promise<Result<boolean>> {
  const client = await getClient();
  const { count, error } = await client
    .from("transcript_segments")
    .select("*", { count: "exact", head: true })
    .eq("meeting_id", id);
  if (error) {
    warn(`supabase error (hasTranscript ${id}): ${error.message}`);
    return { error: error.message };
  }
  return { data: (count ?? 0) > 0 };
}

/** True/false whether a meeting has any chat messages. */
export async function hasChat(id: string): Promise<Result<boolean>> {
  const client = await getClient();
  const { count, error } = await client
    .from("chat_messages")
    .select("*", { count: "exact", head: true })
    .eq("meeting_id", id);
  if (error) {
    warn(`supabase error (hasChat ${id}): ${error.message}`);
    return { error: error.message };
  }
  return { data: (count ?? 0) > 0 };
}

// ---------------------------------------------------------------------------
// Pure helpers reused across tools.
// ---------------------------------------------------------------------------

/** Resolve a speaker key (S1, S2…) to a display name using the speakers map. */
export function resolveSpeakerName(
  speakers: Record<string, Speaker> | undefined,
  key: string | undefined
): string {
  if (!key) {
    return "Unknown";
  }
  const entry = speakers?.[key];
  if (entry?.name && entry.name.trim().length > 0) {
    return entry.name;
  }
  if (entry?.label && entry.label.trim().length > 0) {
    return entry.label;
  }
  // Fallback: derive "Speaker N" from a key like "S2".
  const match = /^S(\d+)$/.exec(key);
  if (match) {
    return `Speaker ${match[1]}`;
  }
  return key;
}

/** Resolve the folder path (e.g. "Client / Project") for a folder id. */
export function folderPathFor(
  folders: FolderJson[],
  folderId: string | null | undefined
): string | null {
  if (!folderId) {
    return null;
  }
  const byId = new Map<string, FolderJson>();
  for (const f of folders) {
    if (f.id) {
      byId.set(f.id, f);
    }
  }
  const parts: string[] = [];
  const seen = new Set<string>();
  let current: FolderJson | undefined = byId.get(folderId);
  while (current && current.id && !seen.has(current.id)) {
    seen.add(current.id);
    parts.unshift(current.name ?? current.id);
    current = current.parentId ? byId.get(current.parentId) : undefined;
  }
  return parts.length > 0 ? parts.join(" / ") : null;
}
