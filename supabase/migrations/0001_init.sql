-- SK Note Taker — Supabase schema
-- Mirrors the local JSON data model (docs/planning/DATA-MODEL.md) so the Mac app, the web
-- app, and the MCP server can all read/write the same cloud data and stay in sync.

-- ── Folders (clients → projects) ────────────────────────────────────────────
create table if not exists folders (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,
    kind        text not null default 'generic' check (kind in ('client','project','generic')),
    parent_id   uuid references folders(id) on delete cascade,
    created_at  timestamptz not null default now()
);

-- ── Meetings ────────────────────────────────────────────────────────────────
create table if not exists meetings (
    id           uuid primary key default gen_random_uuid(),
    title        text not null,
    created_at   timestamptz not null default now(),
    ended_at     timestamptz,
    folder_id    uuid references folders(id) on delete set null,
    state        text not null default 'recording' check (state in ('recording','processing','complete')),
    -- speaker key ("S1","S2"…) → { label, name, source }
    speakers     jsonb not null default '{}'::jsonb,
    has_recording boolean not null default false,
    duration_sec double precision not null default 0,
    auto_category jsonb,
    notes        text not null default '',       -- user's rough notes (markdown)
    updated_at   timestamptz not null default now()
);
create index if not exists meetings_folder_idx on meetings(folder_id);
create index if not exists meetings_created_idx on meetings(created_at desc);

-- ── Transcript segments ─────────────────────────────────────────────────────
create table if not exists transcript_segments (
    meeting_id  uuid not null references meetings(id) on delete cascade,
    idx         integer not null,                -- segment order within the meeting
    speaker     text not null,                   -- speaker key "S1","S2"…
    source      text not null check (source in ('mic','system')),
    start_sec   double precision not null,
    end_sec     double precision not null,
    text        text not null,
    primary key (meeting_id, idx)
);

-- ── Summaries (one per meeting) ─────────────────────────────────────────────
create table if not exists summaries (
    meeting_id   uuid primary key references meetings(id) on delete cascade,
    generated_at timestamptz not null default now(),
    body         text not null default '',       -- markdown prose
    action_items jsonb not null default '[]'::jsonb,   -- [{owner, text}]
    decisions    jsonb not null default '[]'::jsonb,   -- [string]
    remember     jsonb not null default '[]'::jsonb    -- [string]
);

-- ── Chat (Q&A) messages ─────────────────────────────────────────────────────
create table if not exists chat_messages (
    id          bigint generated always as identity primary key,
    meeting_id  uuid not null references meetings(id) on delete cascade,
    role        text not null check (role in ('user','assistant')),
    text        text not null,
    at          timestamptz not null default now()
);
create index if not exists chat_meeting_idx on chat_messages(meeting_id, at);

-- ── updated_at trigger for meetings ─────────────────────────────────────────
create or replace function set_updated_at() returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists meetings_updated_at on meetings;
create trigger meetings_updated_at before update on meetings
    for each row execute function set_updated_at();

-- ── Row Level Security ──────────────────────────────────────────────────────
-- Single-user personal deployment. RLS is ON; the policies below allow the anon
-- (publishable) key full access. NOTE: the publishable key is public, so this makes the
-- data readable/writable by anyone who has it. For a shared/hardened deployment, replace
-- these with auth.uid()-scoped policies and add a user_id column. See supabase/README.md.
alter table folders             enable row level security;
alter table meetings            enable row level security;
alter table transcript_segments enable row level security;
alter table summaries           enable row level security;
alter table chat_messages       enable row level security;

do $$
declare t text;
begin
  foreach t in array array['folders','meetings','transcript_segments','summaries','chat_messages']
  loop
    execute format('drop policy if exists "anon_all" on %I;', t);
    execute format('create policy "anon_all" on %I for all to anon, authenticated using (true) with check (true);', t);
  end loop;
end $$;

-- ── Storage bucket for meeting audio (recording.m4a) ────────────────────────
insert into storage.buckets (id, name, public)
values ('recordings', 'recordings', false)
on conflict (id) do nothing;

drop policy if exists "recordings_anon_all" on storage.objects;
create policy "recordings_anon_all" on storage.objects for all to anon, authenticated
    using (bucket_id = 'recordings') with check (bucket_id = 'recordings');
