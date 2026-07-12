/**
 * Data-access layer for the SK Note Taker on-disk store.
 *
 * All reads are defensive: a missing data directory yields empty results, and a
 * malformed JSON file is skipped with a stderr warning rather than crashing the
 * server. Nothing here writes to the store — the MCP server is read-only.
 */
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

/** Log a warning to stderr. stdout is reserved for JSON-RPC traffic. */
export function warn(message: string): void {
  process.stderr.write(`[sknote-mcp] WARN ${message}\n`);
}

/**
 * Resolve the data directory. `SKNOTE_DATA_DIR` overrides the default of
 * ~/Library/Application Support/SKNoteTaker (important for tests).
 */
export function resolveDataDir(): string {
  const override = process.env.SKNOTE_DATA_DIR;
  if (override && override.trim().length > 0) {
    return path.resolve(override);
  }
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "SKNoteTaker"
  );
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

/** Read + parse a JSON file. Returns undefined on missing/malformed input. */
export async function readJson<T>(filePath: string): Promise<T | undefined> {
  let raw: string;
  try {
    raw = await fs.readFile(filePath, "utf8");
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") {
      warn(`could not read ${filePath}: ${(err as Error).message}`);
    }
    return undefined;
  }
  try {
    return JSON.parse(raw) as T;
  } catch (err) {
    warn(`skipping malformed JSON ${filePath}: ${(err as Error).message}`);
    return undefined;
  }
}

/** Read a text file (notes.md, summary.md). Returns undefined when absent. */
export async function readText(filePath: string): Promise<string | undefined> {
  try {
    return await fs.readFile(filePath, "utf8");
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") {
      warn(`could not read ${filePath}: ${(err as Error).message}`);
    }
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// On-disk shapes (see docs/planning/DATA-MODEL.md). All fields optional at read
// time — files may be partial or hand-edited, so we validate as we consume.
// ---------------------------------------------------------------------------

export interface Speaker {
  label?: string;
  name?: string;
  source?: string;
}

export interface MeetingJson {
  id?: string;
  title?: string;
  createdAt?: string;
  endedAt?: string;
  folderId?: string | null;
  state?: string;
  speakers?: Record<string, Speaker>;
  hasRecording?: boolean;
  durationSec?: number;
  autoCategory?: { project?: string; client?: string; confidence?: number };
}

export interface TranscriptSegment {
  id?: number;
  speaker?: string;
  source?: string;
  start?: number;
  end?: number;
  text?: string;
  final?: boolean;
}

export interface TranscriptJson {
  version?: number;
  segments?: TranscriptSegment[];
}

export interface FolderJson {
  id?: string;
  name?: string;
  kind?: string;
  parentId?: string | null;
}

export interface FoldersFile {
  folders?: FolderJson[];
}

/** Absolute paths to the well-known files for one meeting. */
export interface MeetingPaths {
  dir: string;
  meetingJson: string;
  transcriptJson: string;
  notesMd: string;
  summaryMd: string;
  chatJson: string;
  recording: string;
}

export function meetingsDir(dataDir: string): string {
  return path.join(dataDir, "meetings");
}

export function meetingPaths(dataDir: string, id: string): MeetingPaths {
  const dir = path.join(meetingsDir(dataDir), id);
  return {
    dir,
    meetingJson: path.join(dir, "meeting.json"),
    transcriptJson: path.join(dir, "transcript.json"),
    notesMd: path.join(dir, "notes.md"),
    summaryMd: path.join(dir, "summary.md"),
    chatJson: path.join(dir, "chat.json"),
    recording: path.join(dir, "recording.m4a"),
  };
}

/** List meeting directory ids. Empty array if the store or meetings dir is absent. */
export async function listMeetingIds(dataDir: string): Promise<string[]> {
  const dir = meetingsDir(dataDir);
  if (!(await pathExists(dir))) {
    return [];
  }
  let entries: import("node:fs").Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch (err) {
    warn(`could not list meetings dir ${dir}: ${(err as Error).message}`);
    return [];
  }
  return entries
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .sort();
}

/** A meeting's parsed metadata paired with the id derived from its directory. */
export interface LoadedMeeting {
  id: string;
  paths: MeetingPaths;
  meeting: MeetingJson;
}

/**
 * Load one meeting's meeting.json. Returns undefined when the file is
 * missing/malformed (already warned by readJson). The directory name is the
 * authoritative id; meeting.json.id is used only as a fallback.
 */
export async function loadMeeting(
  dataDir: string,
  id: string
): Promise<LoadedMeeting | undefined> {
  const paths = meetingPaths(dataDir, id);
  const meeting = await readJson<MeetingJson>(paths.meetingJson);
  if (!meeting) {
    return undefined;
  }
  return { id: meeting.id ?? id, paths, meeting };
}

/** Load every meeting that has a readable meeting.json. */
export async function loadAllMeetings(
  dataDir: string
): Promise<LoadedMeeting[]> {
  const ids = await listMeetingIds(dataDir);
  const loaded = await Promise.all(ids.map((id) => loadMeeting(dataDir, id)));
  return loaded.filter((m): m is LoadedMeeting => m !== undefined);
}

export async function fileExists(filePath: string): Promise<boolean> {
  return pathExists(filePath);
}

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
