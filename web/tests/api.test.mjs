// Integration tests for the SK Note Taker web API — against the LIVE Supabase project.
//
// The data now lives in Supabase (cloud Postgres + Storage), so these tests seed a small,
// self-contained dataset directly via the Supabase REST/Storage API using a unique test
// prefix ("__webtest__<random>__…"), spawn the real server, exercise every endpoint over
// HTTP (including the PATCH endpoints, verifying the write actually landed in Supabase),
// and then delete everything they created. They never touch the user's real rows.
//
// Requires network access and a configured Supabase project (supabase/config.json or
// SUPABASE_URL / SUPABASE_ANON_KEY env vars).

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(__dirname, '..', 'src', 'server.js');

// ---- Supabase config (same resolution as src/supabase.js) ----
function loadConfig() {
  let file = {};
  try {
    file = JSON.parse(readFileSync(path.join(__dirname, '..', '..', 'supabase', 'config.json'), 'utf8'));
  } catch { /* env vars may still provide it */ }
  const url = process.env.SUPABASE_URL || file.url;
  const anonKey = process.env.SUPABASE_ANON_KEY || file.anonKey;
  const bucket = process.env.SUPABASE_RECORDINGS_BUCKET || file.recordingsBucket || 'recordings';
  if (!url || !anonKey) throw new Error('Supabase not configured for tests');
  return { url, anonKey, bucket };
}
const CFG = loadConfig();

const REST = `${CFG.url}/rest/v1`;
const STORAGE = `${CFG.url}/storage/v1`;
const authHeaders = {
  apikey: CFG.anonKey,
  Authorization: `Bearer ${CFG.anonKey}`,
};

// Unique per test run so parallel/leftover runs never collide, and cleanup is precise.
const RUN = crypto.randomBytes(4).toString('hex');
const PREFIX = `__webtest__${RUN}__`;

// --- Supabase REST helpers ---
async function sbInsert(table, rows) {
  const res = await fetch(`${REST}/${table}`, {
    method: 'POST',
    headers: { ...authHeaders, 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: JSON.stringify(rows),
  });
  if (!res.ok) throw new Error(`insert ${table} failed: ${res.status} ${await res.text()}`);
  return res.json();
}
async function sbDelete(table, column, value) {
  const res = await fetch(`${REST}/${table}?${column}=eq.${encodeURIComponent(value)}`, {
    method: 'DELETE',
    headers: authHeaders,
  });
  if (!res.ok && res.status !== 404) {
    process.stderr.write(`[cleanup] delete ${table} ${value} → ${res.status}\n`);
  }
}
async function storageUpload(objectPath, bytes, contentType = 'audio/mp4') {
  const res = await fetch(`${STORAGE}/object/${CFG.bucket}/${objectPath}`, {
    method: 'POST',
    headers: { ...authHeaders, 'Content-Type': contentType },
    body: bytes,
  });
  if (!res.ok) throw new Error(`storage upload failed: ${res.status} ${await res.text()}`);
}
async function storageDelete(objectPath) {
  await fetch(`${STORAGE}/object/${CFG.bucket}/${objectPath}`, { method: 'DELETE', headers: authHeaders }).catch(() => {});
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

async function waitForServer(url, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok || res.status === 404) return;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server did not start in time');
}

// ---- Seeded IDs, filled in before() ----
let child;
let base;
const ids = {
  folderPatriot: null,   // "Patriot Holdings" (root)
  folderRedesign: null,  // child of Patriot
  folderInternal: null,  // root
  mA: null,              // "Weekly sync with Kainat" — full: summary+recording+chat+transcript, in Redesign
  mB: null,              // "Northwind kickoff" — in Internal, no recording
  mC: null,              // bare, no folder, no summary/notes/transcript
};
const AUDIO_BYTES = Buffer.from('SKNOTE-TEST-AUDIO-0123456789', 'utf8'); // 28 bytes

before(async () => {
  // --- Seed folders ---
  const [patriot] = await sbInsert('folders', [{ name: `${PREFIX}Patriot Holdings`, kind: 'client' }]);
  ids.folderPatriot = patriot.id;
  const [redesign] = await sbInsert('folders', [{ name: `${PREFIX}Website Redesign`, kind: 'project', parent_id: patriot.id }]);
  ids.folderRedesign = redesign.id;
  const [internal] = await sbInsert('folders', [{ name: `${PREFIX}Internal`, kind: 'generic' }]);
  ids.folderInternal = internal.id;

  // --- Seed meetings (created_at ordered so newest-first is deterministic: C > B > A) ---
  const [mA] = await sbInsert('meetings', [{
    title: `${PREFIX}Weekly sync with Kainat`,
    created_at: '2026-07-10T09:00:00Z',
    folder_id: redesign.id,
    state: 'complete',
    speakers: {
      S1: { label: 'S1', name: 'Saqib', source: 'mic' },
      S2: { label: 'S2', name: 'Kainat', source: 'system' },
      S3: { label: 'Speaker 3', name: '', source: 'system' },
    },
    has_recording: true,
    duration_sec: 2530,
    notes: `# Weekly sync\n\nDiscussed the ${PREFIX} redesign.`,
  }]);
  ids.mA = mA.id;

  const [mB] = await sbInsert('meetings', [{
    title: `${PREFIX}Northwind kickoff`,
    created_at: '2026-07-11T09:00:00Z',
    folder_id: internal.id,
    state: 'complete',
    speakers: { S1: { label: 'S1', name: 'Saqib', source: 'mic' } },
    has_recording: false,
    duration_sec: 1200,
    notes: '',
  }]);
  ids.mB = mB.id;

  const [mC] = await sbInsert('meetings', [{
    title: `${PREFIX}Bare meeting`,
    created_at: '2026-07-12T09:00:00Z',
    folder_id: null,
    state: 'processing',
    speakers: {},
    has_recording: false,
    duration_sec: 0,
    notes: '',
  }]);
  ids.mC = mC.id;

  // --- Transcript for mA ---
  await sbInsert('transcript_segments', [
    { meeting_id: mA.id, idx: 0, speaker: 'S1', source: 'mic', start_sec: 0, end_sec: 4, text: 'Morning, thanks for joining.' },
    { meeting_id: mA.id, idx: 1, speaker: 'S2', source: 'system', start_sec: 4, end_sec: 9, text: 'Happy to be here.' },
    { meeting_id: mA.id, idx: 2, speaker: 'S1', source: 'mic', start_sec: 9, end_sec: 15, text: 'Let us review the proposal.' },
    { meeting_id: mA.id, idx: 3, speaker: 'S2', source: 'system', start_sec: 15, end_sec: 20, text: 'Looks good overall.' },
    { meeting_id: mA.id, idx: 4, speaker: 'S3', source: 'system', start_sec: 20, end_sec: 25, text: 'One concern on timeline.' },
    { meeting_id: mA.id, idx: 5, speaker: 'S1', source: 'mic', start_sec: 25, end_sec: 30, text: 'Noted, we will adjust.' },
  ]);

  // --- Summary for mA ---
  await sbInsert('summaries', [{
    meeting_id: mA.id,
    generated_at: '2026-07-10T10:00:00Z',
    body: '# Meeting Summary\n\nA productive weekly sync.',
    action_items: [
      { owner: 'Kainat', text: 'Send the revised proposal by Friday' },
      { owner: 'Saqib', text: 'Book the design review' },
    ],
    decisions: ['Ship v1 without SSO', 'Homepage hero and pricing section are approved'],
    remember: ['Client prefers email', 'Budget is fixed'],
  }]);

  // --- Chat for mA ---
  await sbInsert('chat_messages', [
    { meeting_id: mA.id, role: 'user', text: 'What did we decide about SSO?', at: '2026-07-10T11:00:00Z' },
    { meeting_id: mA.id, role: 'assistant', text: 'You decided to ship v1 without SSO.', at: '2026-07-10T11:00:05Z' },
  ]);

  // --- Recording object for mA ---
  await storageUpload(`${mA.id}.m4a`, AUDIO_BYTES);

  // --- Spawn the server ---
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, SKNOTE_WEB_PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stderr.on('data', (d) => process.stderr.write(`[server] ${d}`));
  await waitForServer(`${base}/api/folders`);
});

after(async () => {
  if (child) child.kill('SIGTERM');
  // Clean up everything we created. Child rows (transcript/summary/chat) cascade on meeting
  // delete, but we delete them explicitly too in case a meeting insert half-failed.
  if (ids.mA) { await storageDelete(`${ids.mA}.m4a`); }
  for (const mid of [ids.mA, ids.mB, ids.mC].filter(Boolean)) {
    await sbDelete('chat_messages', 'meeting_id', mid);
    await sbDelete('summaries', 'meeting_id', mid);
    await sbDelete('transcript_segments', 'meeting_id', mid);
    await sbDelete('meetings', 'id', mid);
  }
  for (const fid of [ids.folderRedesign, ids.folderInternal, ids.folderPatriot].filter(Boolean)) {
    await sbDelete('folders', 'id', fid);
  }
});

const get = (p) => fetch(`${base}${p}`);
const getJson = async (p) => {
  const res = await get(p);
  return { status: res.status, body: await res.json().catch(() => null), res };
};
// Only look at our own seeded meetings — the live project may hold the user's real rows.
const mine = (meetings) => (meetings || []).filter((m) => (m.title || '').startsWith(PREFIX));

test('GET /api/folders returns a tree with recursive counts', async () => {
  const { status, body } = await getJson('/api/folders');
  assert.equal(status, 200);
  assert.ok(body.totalMeetings >= 3, 'at least our 3 seeded meetings counted');

  const patriot = body.tree.find((f) => f.id === ids.folderPatriot);
  assert.ok(patriot, 'Patriot Holdings folder present');
  // One meeting lives in the child folder (Redesign) → parent count rolls up to 1.
  assert.equal(patriot.count, 1);
  const redesign = patriot.children.find((c) => c.id === ids.folderRedesign);
  assert.ok(redesign);
  assert.equal(redesign.count, 1);

  const internal = body.tree.find((f) => f.id === ids.folderInternal);
  assert.equal(internal.count, 1);
});

test('GET /api/meetings lists seeded meetings newest-first', async () => {
  const { status, body } = await getJson('/api/meetings');
  assert.equal(status, 200);
  const ours = mine(body.meetings);
  assert.equal(ours.length, 3);

  // Newest first: mC (Jul 12) before mB (Jul 11) before mA (Jul 10).
  assert.deepEqual(ours.map((m) => m.id), [ids.mC, ids.mB, ids.mA]);

  const full = ours.find((m) => m.id === ids.mA);
  assert.equal(full.title, `${PREFIX}Weekly sync with Kainat`);
  assert.equal(full.hasSummary, true);
  assert.equal(full.hasRecording, true);
  assert.equal(full.durationSec, 2530);
  assert.deepEqual(full.speakerNames.sort(), ['Kainat', 'Saqib', 'Speaker 3'].sort());

  // mB has no summary/recording.
  const b = ours.find((m) => m.id === ids.mB);
  assert.equal(b.hasSummary, false);
  assert.equal(b.hasRecording, false);
});

test('GET /api/meetings?folderId= filters by folder', async () => {
  const { body } = await getJson(`/api/meetings?folderId=${ids.folderInternal}`);
  const ours = mine(body.meetings);
  assert.equal(ours.length, 1);
  assert.equal(ours[0].id, ids.mB);
});

test('GET /api/meetings?q= searches title and speakers', async () => {
  const byTitle = await getJson(`/api/meetings?q=${encodeURIComponent(PREFIX + 'Northwind')}`);
  assert.equal(mine(byTitle.body.meetings).length, 1);
  assert.equal(mine(byTitle.body.meetings)[0].id, ids.mB);

  // Search by speaker name: only mA has "Kainat". Scope the query to our run's meetings.
  const bySpeaker = await getJson('/api/meetings?q=kainat');
  const ours = mine(bySpeaker.body.meetings);
  assert.ok(ours.some((m) => m.id === ids.mA));
  assert.ok(ours.every((m) => m.speakerNames.some((n) => n.toLowerCase().includes('kainat'))));

  const none = await getJson(`/api/meetings?q=${encodeURIComponent(PREFIX + 'zzzznope')}`);
  assert.equal(mine(none.body.meetings).length, 0);
});

test('GET /api/meetings/:id returns meeting + notes + parsed summary + chat', async () => {
  const { status, body } = await getJson(`/api/meetings/${ids.mA}`);
  assert.equal(status, 200);
  assert.equal(body.title, `${PREFIX}Weekly sync with Kainat`);

  // Notes markdown passed through raw.
  assert.match(body.notes, /Weekly sync/);

  // Summary fields.
  assert.ok(body.summary);
  assert.equal(body.summary.actionItems.length, 2);
  assert.equal(body.summary.actionItems[0].owner, 'Kainat');
  assert.equal(body.summary.actionItems[0].text, 'Send the revised proposal by Friday');
  assert.deepEqual(body.summary.decisions, ['Ship v1 without SSO', 'Homepage hero and pricing section are approved']);
  assert.equal(body.summary.remember.length, 2);
  assert.match(body.summary.body, /^# Meeting Summary/);

  // Chat messages ordered by time.
  assert.equal(body.chat.length, 2);
  assert.equal(body.chat[0].role, 'user');
  assert.equal(body.chat[1].role, 'assistant');
});

test('GET /api/meetings/:id 404s for unknown id', async () => {
  // A well-formed but nonexistent uuid.
  const { status } = await getJson('/api/meetings/00000000-0000-0000-0000-000000000000');
  assert.equal(status, 404);
});

test('GET /api/meetings/:id handles a meeting with no summary/notes/transcript', async () => {
  const { status, body } = await getJson(`/api/meetings/${ids.mC}`);
  assert.equal(status, 200);
  assert.equal(body.summary, null);
  assert.equal(body.notes, null);
  assert.equal(body.chat.length, 0);
});

test('GET /api/meetings/:id/transcript resolves speaker names', async () => {
  const { status, body } = await getJson(`/api/meetings/${ids.mA}/transcript`);
  assert.equal(status, 200);
  assert.equal(body.segments.length, 6);

  const first = body.segments[0];
  assert.equal(first.speaker, 'S1');
  assert.equal(first.speakerName, 'Saqib');

  // S3 has an empty name → falls back to its label ("Speaker 3").
  const s3 = body.segments.find((s) => s.speaker === 'S3');
  assert.equal(s3.speakerName, 'Speaker 3');
});

test('GET /api/meetings/:id/audio streams with Range support', async () => {
  // Full request.
  const full = await get(`/api/meetings/${ids.mA}/audio`);
  assert.equal(full.status, 200);
  assert.equal(full.headers.get('accept-ranges'), 'bytes');
  const buf = Buffer.from(await full.arrayBuffer());
  assert.equal(buf.length, AUDIO_BYTES.length);

  // Range request → 206 Partial Content.
  const ranged = await fetch(`${base}/api/meetings/${ids.mA}/audio`, { headers: { Range: 'bytes=0-9' } });
  assert.equal(ranged.status, 206);
  assert.equal(ranged.headers.get('content-range'), `bytes 0-9/${AUDIO_BYTES.length}`);
  const slice = Buffer.from(await ranged.arrayBuffer());
  assert.equal(slice.length, 10);
});

test('GET /api/meetings/:id/audio 404s when no recording', async () => {
  const res = await get(`/api/meetings/${ids.mB}/audio`);
  assert.equal(res.status, 404);
});

test('PATCH /api/meetings/:id/speakers merges names and persists', async () => {
  const res = await fetch(`${base}/api/meetings/${ids.mA}/speakers`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ S3: 'Morgan' }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.speakerNames.S3, 'Morgan');

  // Existing names preserved (merge, not replace).
  assert.equal(body.speakers.S1.name, 'Saqib');
  assert.equal(body.speakers.S3.name, 'Morgan');
  // Prior metadata (label/source) on S3 preserved through the merge.
  assert.equal(body.speakers.S3.source, 'system');

  // Verify it actually landed in Supabase.
  const check = await fetch(`${REST}/meetings?id=eq.${ids.mA}&select=speakers`, { headers: authHeaders });
  const [row] = await check.json();
  assert.equal(row.speakers.S3.name, 'Morgan');

  // Transcript now resolves the new name.
  const { body: t } = await getJson(`/api/meetings/${ids.mA}/transcript`);
  assert.equal(t.segments.find((s) => s.speaker === 'S3').speakerName, 'Morgan');

  // Restore S3 to empty so re-runs of other assertions stay stable within this run.
  await fetch(`${base}/api/meetings/${ids.mA}/speakers`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ S3: 'Speaker 3' }),
  });
});

test('PATCH /api/meetings/:id/speakers rejects a non-object body', async () => {
  const res = await fetch(`${base}/api/meetings/${ids.mA}/speakers`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(['not', 'an', 'object']),
  });
  assert.equal(res.status, 400);
});

test('PATCH /api/meetings/:id/folder moves the meeting', async () => {
  const res = await fetch(`${base}/api/meetings/${ids.mC}/folder`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ folderId: ids.folderInternal }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.folderId, ids.folderInternal);

  // Landed in Supabase.
  const check = await fetch(`${REST}/meetings?id=eq.${ids.mC}&select=folder_id`, { headers: authHeaders });
  const [row] = await check.json();
  assert.equal(row.folder_id, ids.folderInternal);

  // Now filterable by that folder.
  const { body: list } = await getJson(`/api/meetings?folderId=${ids.folderInternal}`);
  assert.ok(mine(list.meetings).some((m) => m.id === ids.mC));

  // Unfile it again (folderId null).
  const res2 = await fetch(`${base}/api/meetings/${ids.mC}/folder`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ folderId: null }),
  });
  assert.equal(res2.status, 200);
  assert.equal((await res2.json()).folderId, null);
});

test('PATCH /api/meetings/:id/folder requires folderId key', async () => {
  const res = await fetch(`${base}/api/meetings/${ids.mC}/folder`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  assert.equal(res.status, 400);
});

test('PATCH endpoints 404 for unknown meeting', async () => {
  const nope = '00000000-0000-0000-0000-000000000000';
  const a = await fetch(`${base}/api/meetings/${nope}/speakers`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ S1: 'X' }),
  });
  assert.equal(a.status, 404);
  const b = await fetch(`${base}/api/meetings/${nope}/folder`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ folderId: ids.folderInternal }),
  });
  assert.equal(b.status, 404);
});
