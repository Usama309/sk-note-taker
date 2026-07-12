// SK Note Taker — web review server.
// Express + ESM, no build step. Serves a static vanilla-JS UI and a JSON API backed by
// Supabase (cloud Postgres + Storage), so meetings can be reviewed from anywhere — not just
// a device on the same LAN as the Mac. Still listens on 0.0.0.0 for LAN/phone access.

import express from 'express';
import path from 'node:path';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';

import {
  listMeetings,
  getMeeting,
  getTranscript,
  getFolderTree,
  recordingInfo,
  fetchRecording,
  updateSpeakers,
  updateFolder,
  StoreError,
} from './store.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, '..', 'public');

/** Send a 5xx with a clear JSON error. Supabase/network failures carry a message; others are generic. */
function serverError(res, err, where) {
  console.error(`[api] ${where} failed:`, err);
  const isStore = err instanceof StoreError;
  res.status(isStore ? 502 : 500).json({
    error: isStore ? 'supabase_error' : 'internal_error',
    detail: err?.message || String(err),
  });
}

export function createApp() {
  const app = express();
  app.use(express.json({ limit: '256kb' }));

  const api = express.Router();

  // GET /api/meetings?folderId=&q=
  api.get('/meetings', async (req, res) => {
    try {
      const meetings = await listMeetings({ folderId: req.query.folderId, q: req.query.q });
      res.json({ meetings });
    } catch (err) {
      serverError(res, err, '/meetings');
    }
  });

  // GET /api/meetings/:id
  api.get('/meetings/:id', async (req, res) => {
    try {
      const meeting = await getMeeting(req.params.id);
      if (!meeting) return res.status(404).json({ error: 'not_found' });
      res.json(meeting);
    } catch (err) {
      serverError(res, err, '/meetings/:id');
    }
  });

  // GET /api/meetings/:id/transcript
  api.get('/meetings/:id/transcript', async (req, res) => {
    try {
      const transcript = await getTranscript(req.params.id);
      if (!transcript) return res.status(404).json({ error: 'not_found' });
      res.json(transcript);
    } catch (err) {
      serverError(res, err, '/transcript');
    }
  });

  // GET /api/meetings/:id/audio — proxy recording from Supabase Storage with Range support.
  api.get('/meetings/:id/audio', async (req, res) => {
    try {
      const { exists, objectPath } = await recordingInfo(req.params.id);
      if (!exists) return res.status(404).json({ error: 'no_recording' });

      const upstream = await fetchRecording(objectPath, req.headers.range);

      // Storage 404 (row says has_recording but object is missing) → treat as no recording.
      if (upstream.status === 404) return res.status(404).json({ error: 'no_recording' });
      if (upstream.status === 416) {
        const cr = upstream.headers.get('content-range');
        if (cr) res.setHeader('Content-Range', cr);
        return res.status(416).end();
      }
      if (upstream.status >= 400) {
        return serverError(res, new StoreError(`storage ${upstream.status}`), '/audio');
      }

      res.setHeader('Accept-Ranges', 'bytes');
      res.setHeader('Content-Type', upstream.headers.get('content-type') || 'audio/mp4');
      const len = upstream.headers.get('content-length');
      if (len) res.setHeader('Content-Length', len);
      const cr = upstream.headers.get('content-range');
      if (cr) res.setHeader('Content-Range', cr);
      // 206 when the upstream honored the Range request, else 200.
      res.status(upstream.status === 206 ? 206 : 200);

      if (upstream.body) {
        Readable.fromWeb(upstream.body).pipe(res);
      } else {
        const buf = Buffer.from(await upstream.arrayBuffer());
        res.end(buf);
      }
    } catch (err) {
      serverError(res, err, '/audio');
    }
  });

  // PATCH /api/meetings/:id/speakers  { "S2": "Kainat", ... }
  api.patch('/meetings/:id/speakers', async (req, res) => {
    try {
      const body = req.body;
      if (!body || typeof body !== 'object' || Array.isArray(body)) {
        return res.status(400).json({ error: 'invalid_body' });
      }
      const result = await updateSpeakers(req.params.id, body);
      if (!result) return res.status(404).json({ error: 'not_found' });
      res.json(result);
    } catch (err) {
      serverError(res, err, 'PATCH /speakers');
    }
  });

  // PATCH /api/meetings/:id/folder  { folderId }
  api.patch('/meetings/:id/folder', async (req, res) => {
    try {
      const body = req.body || {};
      if (!('folderId' in body)) return res.status(400).json({ error: 'missing_folderId' });
      const result = await updateFolder(req.params.id, body.folderId || null);
      if (!result) return res.status(404).json({ error: 'not_found' });
      res.json(result);
    } catch (err) {
      serverError(res, err, 'PATCH /folder');
    }
  });

  // GET /api/folders
  api.get('/folders', async (_req, res) => {
    try {
      res.json(await getFolderTree());
    } catch (err) {
      serverError(res, err, '/folders');
    }
  });

  app.use('/api', api);

  // Static UI.
  app.use(express.static(PUBLIC_DIR, { extensions: ['html'] }));

  // SPA fallback for hash routing — any non-API GET returns index.html.
  app.get('*', (req, res, next) => {
    if (req.path.startsWith('/api/')) return next();
    res.sendFile(path.join(PUBLIC_DIR, 'index.html'));
  });

  return app;
}

// Start the server unless imported (tests import createApp directly).
const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const port = parseInt(process.env.SKNOTE_WEB_PORT || '4517', 10);
  const app = createApp();
  app.listen(port, '0.0.0.0', () => {
    console.log(`SK Note Taker web review running on http://0.0.0.0:${port}`);
    console.log(`On this Mac:   http://localhost:${port}`);
    console.log(`On the LAN:    http://<mac-ip>:${port}`);
    console.log('Data source:   Supabase (cloud) — reviewable from anywhere');
  });
}
