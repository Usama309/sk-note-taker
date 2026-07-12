// Data access layer for the SK Note Taker on-disk store.
// All three runtimes (Mac app, MCP server, web) share the same JSON files under the
// data directory. This module reads them defensively: a missing directory yields empty
// results, and a malformed file is skipped (logged to console.error) rather than crashing.

import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

/** Resolve the data directory. SKNOTE_DATA_DIR overrides the default (important for tests). */
export function dataDir() {
  if (process.env.SKNOTE_DATA_DIR) return process.env.SKNOTE_DATA_DIR;
  return path.join(os.homedir(), 'Library', 'Application Support', 'SKNoteTaker');
}

const meetingsDir = () => path.join(dataDir(), 'meetings');

async function readJson(file) {
  try {
    const raw = await fs.readFile(file, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    console.error(`[store] skipping malformed/unreadable JSON ${file}: ${err.message}`);
    return null;
  }
}

async function readText(file) {
  try {
    return await fs.readFile(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    console.error(`[store] cannot read ${file}: ${err.message}`);
    return null;
  }
}

/** Atomic write: write to a temp file in the same directory, then rename over the target. */
async function writeJsonAtomic(file, obj) {
  const dir = path.dirname(file);
  const tmp = path.join(dir, `.${path.basename(file)}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const json = JSON.stringify(obj, null, 2);
  await fs.writeFile(tmp, json, 'utf8');
  try {
    await fs.rename(tmp, file);
  } catch (err) {
    await fs.rm(tmp, { force: true });
    throw err;
  }
}

// ---- Folders ----

export async function getFoldersRaw() {
  const data = await readJson(path.join(dataDir(), 'folders.json'));
  if (!data || !Array.isArray(data.folders)) return [];
  return data.folders;
}

/** Build a folder tree with recursive meeting counts. Returns { tree, totalMeetings }. */
export async function getFolderTree() {
  const folders = await getFoldersRaw();
  const meetings = await listMeetings({});

  const directCount = new Map();
  let unfiled = 0;
  for (const m of meetings) {
    if (m.folderId) directCount.set(m.folderId, (directCount.get(m.folderId) || 0) + 1);
    else unfiled += 1;
  }

  const byId = new Map();
  for (const f of folders) {
    byId.set(f.id, { id: f.id, name: f.name, kind: f.kind || null, parentId: f.parentId || null, children: [], count: 0 });
  }

  const roots = [];
  for (const node of byId.values()) {
    if (node.parentId && byId.has(node.parentId)) byId.get(node.parentId).children.push(node);
    else roots.push(node);
  }

  // Recursive count = own direct meetings + all descendants.
  function tally(node) {
    let total = directCount.get(node.id) || 0;
    for (const child of node.children) total += tally(child);
    node.count = total;
    return total;
  }
  for (const r of roots) tally(r);

  return { tree: roots, totalMeetings: meetings.length, unfiled };
}

// ---- Meetings ----

function resolveSpeakerNames(speakers) {
  const names = {};
  if (speakers && typeof speakers === 'object') {
    for (const [key, val] of Object.entries(speakers)) {
      if (val && typeof val === 'object') names[key] = val.name || val.label || key;
      else names[key] = key;
    }
  }
  return names;
}

async function readMeetingJson(id) {
  const meeting = await readJson(path.join(meetingsDir(), id, 'meeting.json'));
  if (!meeting || typeof meeting !== 'object') return null;
  return meeting;
}

/** List meeting summaries. Optional filter: { folderId, q }. */
export async function listMeetings({ folderId, q } = {}) {
  let entries;
  try {
    entries = await fs.readdir(meetingsDir(), { withFileTypes: true });
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    console.error(`[store] cannot read meetings dir: ${err.message}`);
    return [];
  }

  const out = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const id = entry.name;
    const meeting = await readMeetingJson(id);
    if (!meeting) continue;

    const speakerNames = Object.values(resolveSpeakerNames(meeting.speakers));
    const hasSummary = await fileExists(path.join(meetingsDir(), id, 'summary.md'));

    out.push({
      id: meeting.id || id,
      title: meeting.title || 'Untitled meeting',
      createdAt: meeting.createdAt || null,
      durationSec: typeof meeting.durationSec === 'number' ? meeting.durationSec : null,
      folderId: meeting.folderId || null,
      state: meeting.state || 'complete',
      speakerNames,
      hasSummary,
      hasRecording: meeting.hasRecording === true || (await fileExists(path.join(meetingsDir(), id, 'recording.m4a'))),
    });
  }

  let filtered = out;
  if (folderId) filtered = filtered.filter((m) => m.folderId === folderId);
  if (q && q.trim()) {
    const needle = q.trim().toLowerCase();
    filtered = filtered.filter(
      (m) => m.title.toLowerCase().includes(needle) || m.speakerNames.some((n) => n.toLowerCase().includes(needle)),
    );
  }

  // Newest first.
  filtered.sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
  return filtered;
}

async function fileExists(file) {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

/** Very small YAML front-matter parser (safe subset: scalars, and lists of scalars or one-level maps). */
export function parseFrontMatter(md) {
  if (typeof md !== 'string') return { data: {}, body: '' };
  const match = md.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { data: {}, body: md };

  const [, yaml, body] = match;
  const data = {};
  const lines = yaml.split(/\r?\n/);
  let currentKey = null;

  const stripQuotes = (s) => {
    s = s.trim();
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) return s.slice(1, -1);
    return s;
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) continue;

    const indent = line.match(/^\s*/)[0].length;

    if (indent === 0) {
      const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
      if (!kv) continue;
      const [, key, rest] = kv;
      if (rest.trim() === '') {
        // Block key — could be a list or a nested map. Peek ahead.
        data[key] = [];
        currentKey = key;
      } else {
        data[key] = stripQuotes(rest);
        currentKey = null;
      }
    } else if (currentKey) {
      const listItem = line.match(/^\s*-\s*(.*)$/);
      if (listItem) {
        const rest = listItem[1];
        const inlineKv = rest.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
        if (inlineKv) {
          // Start of a map list item, e.g. "- owner: Kainat".
          const obj = { [inlineKv[1]]: stripQuotes(inlineKv[2]) };
          data[currentKey].push(obj);
        } else {
          data[currentKey].push(stripQuotes(rest));
        }
      } else {
        // Continuation of the previous map list item, e.g. "    text: ...".
        const contKv = line.match(/^\s*([A-Za-z0-9_-]+):\s*(.*)$/);
        const arr = data[currentKey];
        if (contKv && arr.length && typeof arr[arr.length - 1] === 'object') {
          arr[arr.length - 1][contKv[1]] = stripQuotes(contKv[2]);
        }
      }
    }
  }

  return { data, body: body || '' };
}

/** Full meeting payload: meeting.json + notes.md + parsed summary + chat.json. */
export async function getMeeting(id) {
  const meeting = await readMeetingJson(id);
  if (!meeting) return null;

  const base = path.join(meetingsDir(), id);
  const notes = await readText(path.join(base, 'notes.md'));
  const summaryRaw = await readText(path.join(base, 'summary.md'));
  const chat = await readJson(path.join(base, 'chat.json'));
  const hasRecording = await fileExists(path.join(base, 'recording.m4a'));

  let summary = null;
  if (summaryRaw != null) {
    const { data, body } = parseFrontMatter(summaryRaw);
    summary = {
      generatedAt: data.generatedAt || null,
      actionItems: Array.isArray(data.actionItems) ? data.actionItems : [],
      decisions: Array.isArray(data.decisions) ? data.decisions : [],
      remember: Array.isArray(data.remember) ? data.remember : [],
      body: body.trim(),
    };
  }

  return {
    ...meeting,
    id: meeting.id || id,
    hasRecording,
    speakerNames: resolveSpeakerNames(meeting.speakers),
    notes: notes ?? null,
    summary,
    chat: chat && Array.isArray(chat.messages) ? chat.messages : [],
  };
}

/** Transcript segments with resolved speaker names attached. */
export async function getTranscript(id) {
  const meeting = await readMeetingJson(id);
  if (!meeting) return null;

  const transcript = await readJson(path.join(meetingsDir(), id, 'transcript.json'));
  const names = resolveSpeakerNames(meeting.speakers);
  const segments = transcript && Array.isArray(transcript.segments) ? transcript.segments : [];

  return {
    speakers: names,
    segments: segments
      .filter((s) => s && typeof s === 'object')
      .map((s) => ({
        id: s.id,
        speaker: s.speaker || null,
        speakerName: (s.speaker && names[s.speaker]) || s.speaker || 'Unknown',
        source: s.source || null,
        start: typeof s.start === 'number' ? s.start : null,
        end: typeof s.end === 'number' ? s.end : null,
        text: typeof s.text === 'string' ? s.text : '',
      })),
  };
}

/** Path to recording.m4a if it exists, else null. */
export async function recordingPath(id) {
  const meeting = await readMeetingJson(id);
  if (!meeting) return null;
  const file = path.join(meetingsDir(), id, 'recording.m4a');
  return (await fileExists(file)) ? file : null;
}

/** Merge {key: name} assignments into meeting.json speakers map. Atomic write. */
export async function updateSpeakers(id, assignments) {
  const file = path.join(meetingsDir(), id, 'meeting.json');
  const meeting = await readMeetingJson(id);
  if (!meeting) return null;

  if (!meeting.speakers || typeof meeting.speakers !== 'object') meeting.speakers = {};
  for (const [key, name] of Object.entries(assignments)) {
    if (typeof name !== 'string') continue;
    const existing = meeting.speakers[key] || { label: key };
    meeting.speakers[key] = { ...existing, name: name.trim() };
  }

  await writeJsonAtomic(file, meeting);
  return { id: meeting.id || id, speakers: meeting.speakers, speakerNames: resolveSpeakerNames(meeting.speakers) };
}

/** Move a meeting to a folder (or null to unfile). Atomic write. */
export async function updateFolder(id, folderId) {
  const file = path.join(meetingsDir(), id, 'meeting.json');
  const meeting = await readMeetingJson(id);
  if (!meeting) return null;

  meeting.folderId = folderId || null;
  await writeJsonAtomic(file, meeting);
  return { id: meeting.id || id, folderId: meeting.folderId };
}
