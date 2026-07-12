// SK Note Taker — web review server.
// Express + ESM, no build step. Serves a static vanilla-JS UI and a JSON API over the
// shared on-disk store. Listens on 0.0.0.0 so a phone on the LAN can review meetings.

import express from 'express';
import path from 'node:path';
import { promises as fs, createReadStream } from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  listMeetings,
  getMeeting,
  getTranscript,
  getFolderTree,
  recordingPath,
  updateSpeakers,
  updateFolder,
} from './store.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, '..', 'public');

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
      console.error('[api] /meetings failed:', err);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // GET /api/meetings/:id
  api.get('/meetings/:id', async (req, res) => {
    try {
      const meeting = await getMeeting(req.params.id);
      if (!meeting) return res.status(404).json({ error: 'not_found' });
      res.json(meeting);
    } catch (err) {
      console.error('[api] /meetings/:id failed:', err);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // GET /api/meetings/:id/transcript
  api.get('/meetings/:id/transcript', async (req, res) => {
    try {
      const transcript = await getTranscript(req.params.id);
      if (!transcript) return res.status(404).json({ error: 'not_found' });
      res.json(transcript);
    } catch (err) {
      console.error('[api] /transcript failed:', err);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // GET /api/meetings/:id/audio — stream recording.m4a with Range support.
  api.get('/meetings/:id/audio', async (req, res) => {
    try {
      const file = await recordingPath(req.params.id);
      if (!file) return res.status(404).json({ error: 'no_recording' });

      const stat = await fs.stat(file);
      const total = stat.size;
      const range = req.headers.range;

      res.setHeader('Accept-Ranges', 'bytes');
      res.setHeader('Content-Type', 'audio/mp4');

      if (range) {
        const m = /^bytes=(\d*)-(\d*)$/.exec(range);
        if (!m) return res.status(416).setHeader('Content-Range', `bytes */${total}`).end();
        let start = m[1] === '' ? 0 : parseInt(m[1], 10);
        let end = m[2] === '' ? total - 1 : parseInt(m[2], 10);
        if (Number.isNaN(start) || Number.isNaN(end) || start > end || end >= total) {
          return res.status(416).setHeader('Content-Range', `bytes */${total}`).end();
        }
        res.status(206);
        res.setHeader('Content-Range', `bytes ${start}-${end}/${total}`);
        res.setHeader('Content-Length', end - start + 1);
        createReadStream(file, { start, end }).pipe(res);
      } else {
        res.setHeader('Content-Length', total);
        createReadStream(file).pipe(res);
      }
    } catch (err) {
      console.error('[api] /audio failed:', err);
      res.status(500).json({ error: 'internal_error' });
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
      console.error('[api] PATCH /speakers failed:', err);
      res.status(500).json({ error: 'internal_error' });
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
      console.error('[api] PATCH /folder failed:', err);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // GET /api/folders
  api.get('/folders', async (_req, res) => {
    try {
      res.json(await getFolderTree());
    } catch (err) {
      console.error('[api] /folders failed:', err);
      res.status(500).json({ error: 'internal_error' });
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
  });
}
