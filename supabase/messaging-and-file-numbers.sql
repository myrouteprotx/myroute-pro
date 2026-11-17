-- MyRoute Pro: permanent visit file numbers + private team messaging
-- RUN SECOND (after team-setup.sql). Adds new tables, a sequence and functions only. Deletes and changes NO existing data.
-- Security model: only people on a registered team can use these. Every function works only inside the caller's OWN team,
-- and every table is locked by row level security so database permissions (not just the app screen) protect it.

do $$ begin
  if to_regprocedure('public.mrp_in_team()') is null then raise exception 'Run team-setup.sql first.'; end if;
end $$;

-- Everyone on my team (the owner plus all members) with a display name. Empty unless the caller is on a registered team.
create or replace function public.mrp_msg_people()
returns table(uid uuid, email text, name text, role text)
language sql stable security definer set search_path = public, auth as $$
  with o as (select public.mrp_my_owner() as owner)
  select u.id, u.email::text,
         coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name'),
         case when u.id = (select owner from o) then 'admin'
              else (select m.role from public.members m where m.member = u.id and m.owner = (select owner from o) limit 1) end
  from auth.users u
  where public.mrp_in_team()
    and (u.id = (select owner from o) or u.id in (select m.member from public.members m where m.owner = (select owner from o)));
$$;
revoke all on function public.mrp_msg_people() from public, anon;
grant execute on function public.mrp_msg_people() to authenticated;

-- ---------- 1. permanent, unique visit file numbers ----------
create sequence if not exists public.mrp_file_seq start 1001;
create table if not exists public.mrp_visit_files (
  file_no    bigint primary key default nextval('public.mrp_file_seq'),
  owner      uuid not null,
  visit_id   text not null,
  created_at timestamptz not null default now(),
  unique (owner, visit_id)          -- one number per visit, forever; a number can never be reused
);
alter table public.mrp_visit_files enable row level security;
revoke all on public.mrp_visit_files from anon, authenticated;
grant select on public.mrp_visit_files to authenticated;
drop policy if exists mrp_visit_files_read on public.mrp_visit_files;   -- replaces only this file's own policy of the same name
create policy mrp_visit_files_read on public.mrp_visit_files for select to authenticated
  using (owner = public.mrp_my_owner() and public.mrp_in_team());

-- The app sends the ids of visits that have no number yet (oldest first); each gets the next number once.
create or replace function public.mrp_assign_file_nos(p_ids text[])
returns table(visit_id text, file_no bigint)
language plpgsql security definer set search_path = public, auth as $$
#variable_conflict use_column
declare o uuid := public.mrp_my_owner(); r text; i text;
begin
  if auth.uid() is null or not public.mrp_in_team() then raise exception 'not allowed'; end if;
  select coalesce((select m.role from public.members m where m.member = auth.uid() limit 1), 'admin') into r;
  if r = 'viewer' then raise exception 'viewers cannot assign numbers'; end if;
  if p_ids is null or coalesce(array_length(p_ids,1),0) = 0 then return; end if;
  if array_length(p_ids,1) > 500 then raise exception 'too many at once'; end if;
  foreach i in array p_ids loop
    if i is null or length(i) > 100 then continue; end if;
    insert into public.mrp_visit_files(owner, visit_id) values (o, i) on conflict (owner, visit_id) do nothing;
  end loop;
  return query select f.visit_id, f.file_no from public.mrp_visit_files f where f.owner = o and f.visit_id = any(p_ids);
end $$;
revoke all on function public.mrp_assign_file_nos(text[]) from public, anon;
grant execute on function public.mrp_assign_file_nos(text[]) to authenticated;

-- ---------- 2. private team messaging ----------
create table if not exists public.mrp_conversations (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('direct','group')),
  title      text,
  owner      uuid not null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);
create table if not exists public.mrp_conv_members (
  conv_id      uuid not null references public.mrp_conversations(id) on delete cascade,
  user_id      uuid not null,
  added_by     uuid,
  history_from timestamptz not null default now(),   -- a person only ever sees messages from this moment on
  last_read_at timestamptz not null default now(),
  primary key (conv_id, user_id)
);
create table if not exists public.mrp_messages (
  id         uuid primary key default gen_random_uuid(),
  conv_id    uuid not null references public.mrp_conversations(id) on delete cascade,
  sender     uuid not null default auth.uid(),
  body       text not null check (length(body) between 1 and 4000),
  visit_no   bigint,                                  -- optional reference to a visit file number (a link, not access)
  created_at timestamptz not null default now()
);
create index if not exists mrp_messages_conv_idx on public.mrp_messages(conv_id, created_at);

-- Member of the conversation AND still on the team that owns it (someone removed from the team loses access).
create or replace function public.mrp_is_conv_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.mrp_conv_members cm join public.mrp_conversations c on c.id = cm.conv_id
    where cm.conv_id = cid and cm.user_id = auth.uid() and c.owner = public.mrp_my_owner() and public.mrp_in_team());
$$;
revoke all on function public.mrp_is_conv_member(uuid) from public, anon;
grant execute on function public.mrp_is_conv_member(uuid) to authenticated;

alter table public.mrp_conversations enable row level security;
alter table public.mrp_conv_members  enable row level security;
alter table public.mrp_messages      enable row level security;
revoke all on public.mrp_conversations, public.mrp_conv_members, public.mrp_messages from anon, authenticated;
grant select on public.mrp_conversations, public.mrp_conv_members to authenticated;
grant update (last_read_at) on public.mrp_conv_members to authenticated;
grant select on public.mrp_messages to authenticated;
grant insert (conv_id, body, visit_no) on public.mrp_messages to authenticated;

-- The DROP POLICY lines only remove policies with these exact names (this file's own, from an earlier run); then they are re-created.
drop policy if exists mrp_conv_read on public.mrp_conversations;
create policy mrp_conv_read on public.mrp_conversations for select to authenticated using (public.mrp_is_conv_member(id));
drop policy if exists mrp_cm_read on public.mrp_conv_members;
create policy mrp_cm_read on public.mrp_conv_members for select to authenticated using (public.mrp_is_conv_member(conv_id));
drop policy if exists mrp_cm_mark_read on public.mrp_conv_members;
create policy mrp_cm_mark_read on public.mrp_conv_members for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
-- messages: only members, and only messages from the moment they joined (history_from)
drop policy if exists mrp_msg_read on public.mrp_messages;
create policy mrp_msg_read on public.mrp_messages for select to authenticated using (
  public.mrp_is_conv_member(conv_id)
  and exists (select 1 from public.mrp_conv_members cm where cm.conv_id = mrp_messages.conv_id and cm.user_id = auth.uid() and mrp_messages.created_at >= cm.history_from));
drop policy if exists mrp_msg_send on public.mrp_messages;
create policy mrp_msg_send on public.mrp_messages for insert to authenticated with check (
  sender = auth.uid() and public.mrp_is_conv_member(conv_id));

-- Start private messages. p_mode = 'separate' (one private chat per person) or 'group' (one shared conversation).
-- (messaging-team-wide.sql replaces this with the same function plus the team-wide group rule.)
create or replace function public.mrp_msg_start(p_users uuid[], p_mode text, p_title text, p_body text, p_visit bigint default null)
returns uuid[]
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); o uuid := public.mrp_my_owner(); u uuid; cid uuid; ids uuid[] := '{}';
begin
  if me is null or not public.mrp_in_team() then raise exception 'not allowed'; end if;
  if p_users is null or array_length(p_users,1) is null then raise exception 'choose at least one person'; end if;
  if array_length(p_users,1) > 100 then raise exception 'too many people'; end if;
  if p_body is not null and length(p_body) > 4000 then raise exception 'message too long'; end if;
  if exists (select 1 from unnest(p_users) x where x = me or x not in (select pp.uid from public.mrp_msg_people() pp)) then
    raise exception 'you can only message people on your team';
  end if;
  if p_mode = 'group' and array_length(p_users,1) >= 2 then
    insert into public.mrp_conversations(kind, title, owner, created_by) values ('group', nullif(trim(p_title),''), o, me) returning id into cid;
    insert into public.mrp_conv_members(conv_id, user_id, added_by) select cid, x, me from unnest(p_users || me) x;
    if p_body is not null and length(trim(p_body)) > 0 then insert into public.mrp_messages(conv_id, sender, body, visit_no) values (cid, me, p_body, p_visit); end if;
    return array[cid];
  end if;
  foreach u in array p_users loop
    select c.id into cid from public.mrp_conversations c
      where c.kind = 'direct' and c.owner = o
        and (select count(*) from public.mrp_conv_members m where m.conv_id = c.id) = 2
        and exists (select 1 from public.mrp_conv_members m where m.conv_id = c.id and m.user_id = me)
        and exists (select 1 from public.mrp_conv_members m where m.conv_id = c.id and m.user_id = u) limit 1;
    if cid is null then
      insert into public.mrp_conversations(kind, owner, created_by) values ('direct', o, me) returning id into cid;
      insert into public.mrp_conv_members(conv_id, user_id, added_by) values (cid, me, me), (cid, u, me);
    end if;
    if p_body is not null and length(trim(p_body)) > 0 then insert into public.mrp_messages(conv_id, sender, body, visit_no) values (cid, me, p_body, p_visit); end if;
    ids := ids || cid; cid := null;
  end loop;
  return ids;
end $$;

-- Add someone to an existing GROUP. By default they see only messages sent from now on.
-- p_share_history = true must be chosen on purpose to let them read the earlier messages too.
create or replace function public.mrp_msg_add_member(p_conv uuid, p_user uuid, p_share_history boolean default false)
returns text
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid();
begin
  if not public.mrp_in_team() then return 'not_allowed'; end if;
  if not exists (select 1 from public.mrp_conversations c where c.id = p_conv and c.kind = 'group') then return 'not_group'; end if;
  if not public.mrp_is_conv_member(p_conv) then return 'not_member'; end if;
  if p_user not in (select pp.uid from public.mrp_msg_people() pp) then return 'not_on_team'; end if;
  insert into public.mrp_conv_members(conv_id, user_id, added_by, history_from)
    values (p_conv, p_user, me, case when p_share_history then '-infinity'::timestamptz else now() end)
    on conflict (conv_id, user_id) do nothing;
  return 'ok';
end $$;
revoke all on function public.mrp_msg_start(uuid[],text,text,text,bigint) from public, anon;
revoke all on function public.mrp_msg_add_member(uuid,uuid,boolean) from public, anon;
grant execute on function public.mrp_msg_start(uuid[],text,text,text,bigint) to authenticated;
grant execute on function public.mrp_msg_add_member(uuid,uuid,boolean) to authenticated;
