# SK Note Taker — Supabase backend

The Mac app is **local-first**: it records to `~/Library/Application Support/SKNoteTaker/`
and mirrors everything to this Supabase project so the web app (and MCP) can read your
meetings from anywhere. Nothing breaks offline; sync catches up when you're back online.

- **Project**: `ntuamvphoorqbuikbhdb` (region ap-northeast-1)
- **URL**: `https://ntuamvphoorqbuikbhdb.supabase.co`
- **Publishable (anon) key**: in `config.json` — safe to embed in clients.

## Schema

`migrations/0001_init.sql` — tables: `folders`, `meetings`, `transcript_segments`,
`summaries`, `chat_messages`, plus a `recordings` Storage bucket for the m4a audio.

Apply / re-apply (session-mode pooler, IPv4):

```bash
PGPASSWORD='<db-password>' psql \
  "host=aws-0-ap-northeast-1.pooler.supabase.com port=5432 \
   user=postgres.ntuamvphoorqbuikbhdb dbname=postgres sslmode=require" \
  -v ON_ERROR_STOP=1 -f supabase/migrations/0001_init.sql
```

(The direct `db.<ref>.supabase.co` host is IPv6-only; use the pooler on IPv4 networks.)

## Security note

RLS is **on**, but the current policies grant the anon key full read/write — i.e. anyone
holding the (public) publishable key can access the data. That's acceptable for a single-user
personal deployment. To harden (e.g. before deploying the web app publicly), switch the
policies to `auth.uid()`-scoped rules, add a `user_id` column, and sign in via Supabase Auth.
