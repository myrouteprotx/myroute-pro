-- Run once in Supabase: SQL Editor > New query > paste > Run
create extension if not exists pg_cron;
create extension if not exists pg_net;

create table if not exists public.push_subs (
  endpoint text primary key,
  owner uuid not null,
  sub jsonb not null,
  created_at timestamptz default now()
);
create table if not exists public.push_config (key text primary key, value text);
alter table public.push_subs enable row level security;
alter table public.push_config enable row level security;

insert into public.push_config (key, value) values ('cron', gen_random_uuid()::text) on conflict (key) do nothing;

-- Checks every 15 minutes; the function only sends between 9:00 and 9:14 AM Central, once a day.
select cron.schedule('route-push', '*/15 * * * *', $$
  select net.http_post(
    url := 'https://rrhmykprzkumixcjsygo.supabase.co/functions/v1/hyper-handler',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron', (select value from public.push_config where key = 'cron')),
    body := '{"action":"run"}'::jsonb
  );
$$);
