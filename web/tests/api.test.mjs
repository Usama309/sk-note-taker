// Integration tests for the SK Note Taker web API.
// Copies the fixtures to a throwaway temp dir, spawns the real server against it on a
// random port, and exercises every endpoint over HTTP — including the PATCH endpoints,
// verifying the atomic write actually landed on disk.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(__dirname, 'fixtures');
const SERVER = path.join(__dirname, '..', 'src', 'server.js');

let dataDir;
let child;
let base;

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

async function waitForServer(url, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok || res.status === 404) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server did not start in time');
}

before(async () => {
  // Fresh copy of the fixtures so PATCH tests don't mutate the committed files.
  dataDir = await fs.mkdtemp(path.join(os.tmpdir(), 'sknote-test-'));
  await fs.cp(FIXTURES, dataDir, { recursive: true });

  const port = await freePort();
  base = `http://127.0.0.1:${port}`;

  child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, SKNOTE_DATA_DIR: dataDir, SKNOTE_WEB_PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stderr.on('data', (d) => process.stderr.write(`[server] ${d}`));

  await waitForServer(`${base}/api/folders`);
});

after(async () => {
  if (child) child.kill('SIGTERM');
  if (dataDir) await fs.rm(dataDir, { recursive: true, force: true }).catch(() => {});
});

const get = (p) => fetch(`${base}${p}`);
const getJson = async (p) => {
  const res = await get(p);
  return { status: res.status, body: await res.json().catch(() => null), res };
};

test('GET /api/folders returns a tree with recursive counts', async () => {
  const { status, body } = await getJson('/api/folders');
  assert.equal(status, 200);
  assert.equal(body.totalMeetings, 3);

  const patriot = body.tree.find((f) => f.id === 'f-patriot');
  assert.ok(patriot, 'Patriot Holdings folder present');
  // One meeting lives in the child folder f-redesign → parent count rolls up to 1.
  assert.equal(patriot.count, 1);
  const redesign = patriot.children.find((c) => c.id === 'f-redesign');
  assert.ok(redesign);
  assert.equal(redesign.count, 1);

  const internal = body.tree.find((f) => f.id === 'f-internal');
  assert.equal(internal.count, 1);
});

test('GET /api/meetings lists all meetings newest-first', async () => {
  const { status, body } = await getJson('/api/meetings');
  assert.equal(status, 200);
  assert.equal(body.meetings.length, 3);

  // Newest first: m-ccc33333 (Jul 12) before m-bbb22222 (Jul 11) before m-aaa11111 (Jul 10).
  assert.deepEqual(body.meetings.map((m) => m.id), ['m-ccc33333', 'm-bbb22222', 'm-aaa11111']);

  const full = body.meetings.find((m) => m.id === 'm-aaa11111');
  assert.equal(full.title, 'Weekly sync with Kainat');
  assert.equal(full.hasSummary, true);
  assert.equal(full.hasRecording, true);
  assert.equal(full.durationSec, 2530);
  assert.deepEqual(full.speakerNames.sort(), ['Kainat', 'Saqib', 'Speaker 3'].sort());
});

test('GET /api/meetings?folderId= filters by folder', async () => {
  const { body } = await getJson('/api/meetings?folderId=f-internal');
  assert.equal(body.meetings.length, 1);
  assert.equal(body.meetings[0].id, 'm-bbb22222');
});

test('GET /api/meetings?q= searches title and speakers', async () => {
  const byTitle = await getJson('/api/meetings?q=northwind');
  assert.equal(byTitle.body.meetings.length, 1);
  assert.equal(byTitle.body.meetings[0].id, 'm-bbb22222');

  const bySpeaker = await getJson('/api/meetings?q=kainat');
  assert.equal(bySpeaker.body.meetings.length, 1);
  assert.equal(bySpeaker.body.meetings[0].id, 'm-aaa11111');

  const none = await getJson('/api/meetings?q=zzzznope');
  assert.equal(none.body.meetings.length, 0);
});

test('GET /api/meetings/:id returns meeting + notes + parsed summary + chat', async () => {
  const { status, body } = await getJson('/api/meetings/m-aaa11111');
  assert.equal(status, 200);
  assert.equal(body.title, 'Weekly sync with Kainat');

  // Notes markdown passed through raw.
  assert.match(body.notes, /Weekly sync/);

  // Summary front-matter parsed into structured fields.
  assert.ok(body.summary);
  assert.equal(body.summary.actionItems.length, 2);
  assert.equal(body.summary.actionItems[0].owner, 'Kainat');
  assert.equal(body.summary.actionItems[0].text, 'Send the revised proposal by Friday');
  assert.deepEqual(body.summary.decisions, ['Ship v1 without SSO', 'Homepage hero and pricing section are approved']);
  assert.equal(body.summary.remember.length, 2);
  assert.match(body.summary.body, /^# Meeting Summary/);
  assert.ok(!body.summary.body.includes('---'), 'front-matter stripped from body');

  // Chat messages.
  assert.equal(body.chat.length, 2);
  assert.equal(body.chat[0].role, 'user');
});

test('GET /api/meetings/:id 404s for unknown id', async () => {
  const { status } = await getJson('/api/meetings/does-not-exist');
  assert.equal(status, 404);
});

test('GET /api/meetings/:id handles a meeting with no summary/notes/transcript', async () => {
  const { status, body } = await getJson('/api/meetings/m-ccc33333');
  assert.equal(status, 200);
  assert.equal(body.summary, null);
  assert.equal(body.notes, null);
  assert.equal(body.chat.length, 0);
});

test('GET /api/meetings/:id/transcript resolves speaker names', async () => {
  const { status, body } = await getJson('/api/meetings/m-aaa11111/transcript');
  assert.equal(status, 200);
  assert.equal(body.segments.length, 6);

  const first = body.segments[0];
  assert.equal(first.speaker, 'S1');
  assert.equal(first.speakerName, 'Saqib');

  // S3 has an empty name → falls back to its label.
  const s3 = body.segments.find((s) => s.speaker === 'S3');
  assert.equal(s3.speakerName, 'Speaker 3');
});

test('GET /api/meetings/:id/audio streams with Range support', async () => {
  // Full request.
  const full = await get('/api/meetings/m-aaa11111/audio');
  assert.equal(full.status, 200);
  assert.equal(full.headers.get('accept-ranges'), 'bytes');
  const buf = Buffer.from(await full.arrayBuffer());
  assert.ok(buf.length > 0);

  // Range request → 206 Partial Content.
  const ranged = await fetch(`${base}/api/meetings/m-aaa11111/audio`, { headers: { Range: 'bytes=0-9' } });
  assert.equal(ranged.status, 206);
  assert.equal(ranged.headers.get('content-range'), `bytes 0-9/${buf.length}`);
  const slice = Buffer.from(await ranged.arrayBuffer());
  assert.equal(slice.length, 10);
});

test('GET /api/meetings/:id/audio 404s when no recording', async () => {
  const res = await get('/api/meetings/m-bbb22222/audio');
  assert.equal(res.status, 404);
});

test('PATCH /api/meetings/:id/speakers merges names and writes atomically', async () => {
  const res = await fetch(`${base}/api/meetings/m-aaa11111/speakers`, {
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

  // Verify it actually landed on disk.
  const onDisk = JSON.parse(await fs.readFile(path.join(dataDir, 'meetings', 'm-aaa11111', 'meeting.json'), 'utf8'));
  assert.equal(onDisk.speakers.S3.name, 'Morgan');

  // Transcript now resolves the new name.
  const { body: t } = await getJson('/api/meetings/m-aaa11111/transcript');
  assert.equal(t.segments.find((s) => s.speaker === 'S3').speakerName, 'Morgan');

  // No leftover temp files from the atomic write.
  const dir = await fs.readdir(path.join(dataDir, 'meetings', 'm-aaa11111'));
  assert.ok(!dir.some((f) => f.includes('.tmp')), 'no temp files left behind');
});

test('PATCH /api/meetings/:id/speakers rejects a non-object body', async () => {
  const res = await fetch(`${base}/api/meetings/m-aaa11111/speakers`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(['not', 'an', 'object']),
  });
  assert.equal(res.status, 400);
});

test('PATCH /api/meetings/:id/folder moves the meeting', async () => {
  const res = await fetch(`${base}/api/meetings/m-ccc33333/folder`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ folderId: 'f-internal' }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.folderId, 'f-internal');

  // Landed on disk.
  const onDisk = JSON.parse(await fs.readFile(path.join(dataDir, 'meetings', 'm-ccc33333', 'meeting.json'), 'utf8'));
  assert.equal(onDisk.folderId, 'f-internal');

  // Now filterable by that folder.
  const { body: list } = await getJson('/api/meetings?folderId=f-internal');
  assert.ok(list.meetings.some((m) => m.id === 'm-ccc33333'));

  // Unfile it again (folderId null).
  const res2 = await fetch(`${base}/api/meetings/m-ccc33333/folder`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ folderId: null }),
  });
  assert.equal(res2.status, 200);
  assert.equal((await res2.json()).folderId, null);
});

test('PATCH /api/meetings/:id/folder requires folderId key', async () => {
  const res = await fetch(`${base}/api/meetings/m-ccc33333/folder`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  assert.equal(res.status, 400);
});

test('PATCH endpoints 404 for unknown meeting', async () => {
  const a = await fetch(`${base}/api/meetings/nope/speakers`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ S1: 'X' }),
  });
  assert.equal(a.status, 404);
  const b = await fetch(`${base}/api/meetings/nope/folder`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ folderId: 'f-internal' }),
  });
  assert.equal(b.status, 404);
});

test('missing data dir yields empty results, not a crash', async () => {
  // Point a second server at a non-existent dir.
  const port = await freePort();
  const emptyChild = spawn(process.execPath, [SERVER], {
    env: { ...process.env, SKNOTE_DATA_DIR: path.join(os.tmpdir(), 'sknote-nonexistent-xyz'), SKNOTE_WEB_PORT: String(port) },
    stdio: 'ignore',
  });
  try {
    const url = `http://127.0.0.1:${port}`;
    await waitForServer(`${url}/api/folders`);
    const meetings = await (await fetch(`${url}/api/meetings`)).json();
    assert.deepEqual(meetings.meetings, []);
    const folders = await (await fetch(`${url}/api/folders`)).json();
    assert.deepEqual(folders.tree, []);
    assert.equal(folders.totalMeetings, 0);
  } finally {
    emptyChild.kill('SIGTERM');
  }
});
