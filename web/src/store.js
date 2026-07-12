// Data access layer for the SK Note Taker web app — backed by Supabase (cloud Postgres).
//
// The Mac app is local-first and mirrors all meeting data to a Supabase project; this
// module reads/writes that same cloud data so meetings can be reviewed from anywhere.
//
// Every function maps the snake_case Postgres columns to the camelCase shape the frontend
// (public/js/app.js) already expects. Supabase/network errors are surfaced by throwing a
// StoreError so the HTTP layer can return a clean 5xx instead of crashing.

import { supabase, RECORDINGS_BUCKET } from './supabase.js';

/** Thrown for any Supabase/network failure so the server can return a 5xx with detail. */
export class StoreError extends Error {
  constructor(message, cause) {
    super(message);
    this.name = 'StoreError';
    this.cause = cause;
  }
}

/** Turn a Supabase { error } into a thrown StoreError (with the PostgREST detail). */
function fail(context, error) {
  const detail = error?.message || String(error);
  throw new StoreError(`${context}: ${detail}`, error);
}

// ---- Speaker helpers ----

/**
 * Resolve the speakers jsonb ({ "S1": { label, name, source } }) into a { key: name } map,
 * preferring name, then label, then the key itself.
 */
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

// ---- Folders ----

/** Raw folder rows mapped to the camelCase shape used internally. */
export async function getFoldersRaw() {
  const { data, error } = await supabase
    .from('folders')
    .select('id, name, kind, parent_id, created_at');
  if (error) fail('list folders', error);
  return (data || []).map((f) => ({
    id: f.id,
    name: f.name,
    kind: f.kind || null,
    parentId: f.parent_id || null,
  }));
}

/** Build a folder tree with recursive meeting counts. Returns { tree, totalMeetings, unfiled }. */
export async function getFolderTree() {
  const folders = await getFoldersRaw();

  // Pull just folder_id for every meeting to compute counts without fetching full rows.
  const { data: rows, error } = await supabase.from('meetings').select('folder_id');
  if (error) fail('count meetings', error);

  const directCount = new Map();
  let unfiled = 0;
  const totalMeetings = rows ? rows.length : 0;
  for (const r of rows || []) {
    if (r.folder_id) directCount.set(r.folder_id, (directCount.get(r.folder_id) || 0) + 1);
    else unfiled += 1;
  }

  const byId = new Map();
  for (const f of folders) {
    byId.set(f.id, { id: f.id, name: f.name, kind: f.kind, parentId: f.parentId, children: [], count: 0 });
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

  return { tree: roots, totalMeetings, unfiled };
}

// ---- Meetings ----

/** Map a meetings row to the list-card shape (speakerNames as an array). */
function toListItem(row, hasSummary) {
  const speakerNames = Object.values(resolveSpeakerNames(row.speakers));
  return {
    id: row.id,
    title: row.title || 'Untitled meeting',
    createdAt: row.created_at || null,
    durationSec: typeof row.duration_sec === 'number' ? row.duration_sec : null,
    folderId: row.folder_id || null,
    state: row.state || 'complete',
    speakerNames,
    hasSummary,
    hasRecording: row.has_recording === true,
  };
}

/** List meeting summaries. Optional filter: { folderId, q } (q matches title or speaker names). */
export async function listMeetings({ folderId, q } = {}) {
  let query = supabase
    .from('meetings')
    .select('id, title, created_at, duration_sec, folder_id, state, speakers, has_recording')
    .order('created_at', { ascending: false });

  if (folderId) query = query.eq('folder_id', folderId);

  const { data: rows, error } = await query;
  if (error) fail('list meetings', error);

  // Which of these meetings have a summary? One batched query keyed by meeting_id.
  const ids = (rows || []).map((r) => r.id);
  const withSummary = new Set();
  if (ids.length) {
    const { data: sums, error: sErr } = await supabase
      .from('summaries')
      .select('meeting_id')
      .in('meeting_id', ids);
    if (sErr) fail('list summaries', sErr);
    for (const s of sums || []) withSummary.add(s.meeting_id);
  }

  let out = (rows || []).map((r) => toListItem(r, withSummary.has(r.id)));

  // Text search: title or any resolved speaker name. Done in JS so it matches the display
  // names (derived from the speakers jsonb) exactly, as the on-disk store did.
  if (q && q.trim()) {
    const needle = q.trim().toLowerCase();
    out = out.filter(
      (m) =>
        m.title.toLowerCase().includes(needle) ||
        m.speakerNames.some((n) => n.toLowerCase().includes(needle)),
    );
  }

  return out;
}

/** Fetch a single meetings row, or null if it doesn't exist. */
async function fetchMeetingRow(id) {
  const { data, error } = await supabase
    .from('meetings')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (error) fail('get meeting', error);
  return data || null;
}

/** Full meeting payload: meeting row + notes + parsed summary + chat. */
export async function getMeeting(id) {
  const meeting = await fetchMeetingRow(id);
  if (!meeting) return null;

  const [summaryRow, chatRows] = await Promise.all([
    (async () => {
      const { data, error } = await supabase
        .from('summaries')
        .select('generated_at, body, action_items, decisions, remember')
        .eq('meeting_id', id)
        .maybeSingle();
      if (error) fail('get summary', error);
      return data || null;
    })(),
    (async () => {
      const { data, error } = await supabase
        .from('chat_messages')
        .select('role, text, at')
        .eq('meeting_id', id)
        .order('at', { ascending: true });
      if (error) fail('get chat', error);
      return data || [];
    })(),
  ]);

  let summary = null;
  if (summaryRow) {
    summary = {
      generatedAt: summaryRow.generated_at || null,
      actionItems: Array.isArray(summaryRow.action_items) ? summaryRow.action_items : [],
      decisions: Array.isArray(summaryRow.decisions) ? summaryRow.decisions : [],
      remember: Array.isArray(summaryRow.remember) ? summaryRow.remember : [],
      body: typeof summaryRow.body === 'string' ? summaryRow.body.trim() : '',
    };
  }

  return {
    id: meeting.id,
    title: meeting.title || 'Untitled meeting',
    createdAt: meeting.created_at || null,
    endedAt: meeting.ended_at || null,
    folderId: meeting.folder_id || null,
    state: meeting.state || 'complete',
    durationSec: typeof meeting.duration_sec === 'number' ? meeting.duration_sec : null,
    autoCategory: meeting.auto_category ?? null,
    speakers: meeting.speakers || {},
    speakerNames: resolveSpeakerNames(meeting.speakers),
    hasRecording: meeting.has_recording === true,
    notes: meeting.notes != null && meeting.notes !== '' ? meeting.notes : null,
    summary,
    chat: (chatRows || []).map((c) => ({ role: c.role, text: c.text, at: c.at })),
  };
}

/** Transcript segments with resolved speaker names attached. */
export async function getTranscript(id) {
  const meeting = await fetchMeetingRow(id);
  if (!meeting) return null;

  const { data: rows, error } = await supabase
    .from('transcript_segments')
    .select('idx, speaker, source, start_sec, end_sec, text')
    .eq('meeting_id', id)
    .order('idx', { ascending: true });
  if (error) fail('get transcript', error);

  const names = resolveSpeakerNames(meeting.speakers);

  return {
    speakers: names,
    segments: (rows || []).map((s) => ({
      id: s.idx,
      speaker: s.speaker || null,
      speakerName: (s.speaker && names[s.speaker]) || s.speaker || 'Unknown',
      source: s.source || null,
      start: typeof s.start_sec === 'number' ? s.start_sec : null,
      end: typeof s.end_sec === 'number' ? s.end_sec : null,
      text: typeof s.text === 'string' ? s.text : '',
    })),
  };
}

// ---- Recording (Supabase Storage) ----

/**
 * Whether a recording exists for this meeting, and the storage object path.
 * Returns { exists, objectPath } — objectPath is "<id>.m4a" in the recordings bucket.
 */
export async function recordingInfo(id) {
  const meeting = await fetchMeetingRow(id);
  if (!meeting) return { exists: false, objectPath: null };
  return { exists: meeting.has_recording === true, objectPath: `${id}.m4a` };
}

/**
 * Fetch (a range of) the recording bytes from Supabase Storage.
 * `range` is an optional { start, end } (inclusive) byte range.
 * Returns a Response-like { status, headers, body } from the storage endpoint, so the
 * server can proxy Range/Content-Range/Content-Length straight through to the browser.
 */
export async function fetchRecording(objectPath, rangeHeader) {
  const base = supabase.storage.from(RECORDINGS_BUCKET);
  // Prefer a short-lived signed URL (bucket is private) and proxy the bytes with Range.
  const { data, error } = await base.createSignedUrl(objectPath, 60);
  if (error || !data?.signedUrl) fail('sign recording url', error || new Error('no signed url'));

  const headers = {};
  if (rangeHeader) headers.Range = rangeHeader;
  const res = await fetch(data.signedUrl, { headers });
  return res;
}

// ---- Mutations ----

/** Merge {key: name} assignments into the meeting's speakers jsonb (read-modify-write). */
export async function updateSpeakers(id, assignments) {
  const meeting = await fetchMeetingRow(id);
  if (!meeting) return null;

  const speakers = meeting.speakers && typeof meeting.speakers === 'object' ? { ...meeting.speakers } : {};
  for (const [key, name] of Object.entries(assignments)) {
    if (typeof name !== 'string') continue;
    const existing = speakers[key] && typeof speakers[key] === 'object' ? speakers[key] : { label: key };
    speakers[key] = { ...existing, name: name.trim() };
  }

  const { data, error } = await supabase
    .from('meetings')
    .update({ speakers })
    .eq('id', id)
    .select('id, speakers')
    .maybeSingle();
  if (error) fail('update speakers', error);
  if (!data) return null;

  return { id: data.id, speakers: data.speakers, speakerNames: resolveSpeakerNames(data.speakers) };
}

/** Move a meeting to a folder (or null to unfile). */
export async function updateFolder(id, folderId) {
  const { data, error } = await supabase
    .from('meetings')
    .update({ folder_id: folderId || null })
    .eq('id', id)
    .select('id, folder_id')
    .maybeSingle();
  if (error) fail('update folder', error);
  if (!data) return null;

  return { id: data.id, folderId: data.folder_id || null };
}
