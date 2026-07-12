// Supabase client for the SK Note Taker web app.
// The Mac app is local-first and mirrors all meeting data to this Supabase Postgres
// project; the web app reads/writes the same cloud data so meetings can be reviewed from
// anywhere (not just the LAN).
//
// Config resolution order:
//   1. env SUPABASE_URL / SUPABASE_ANON_KEY (override — useful for CI or a different project)
//   2. ../../supabase/config.json (the checked-in publishable config)
//
// The anon key is a *publishable* key: it is RLS-gated and safe to embed in a client.

import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.join(__dirname, '..', '..', 'supabase', 'config.json');

function loadConfig() {
  let file = {};
  try {
    file = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
  } catch (err) {
    // A missing/broken config file is fine as long as env vars are set.
    if (err.code !== 'ENOENT') {
      console.error(`[supabase] could not read ${CONFIG_PATH}: ${err.message}`);
    }
  }

  const url = process.env.SUPABASE_URL || file.url;
  const anonKey = process.env.SUPABASE_ANON_KEY || file.anonKey;
  const recordingsBucket = process.env.SUPABASE_RECORDINGS_BUCKET || file.recordingsBucket || 'recordings';

  if (!url || !anonKey) {
    throw new Error(
      'Supabase is not configured: set SUPABASE_URL and SUPABASE_ANON_KEY, or provide supabase/config.json',
    );
  }
  return { url, anonKey, recordingsBucket };
}

export const config = loadConfig();

export const supabase = createClient(config.url, config.anonKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

export const RECORDINGS_BUCKET = config.recordingsBucket;
