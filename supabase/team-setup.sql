-- MyRoute Pro: team setup (the "members" table and the functions Team Management uses)
-- RUN FIRST. Safe to re-run. Adds tables, functions and extra access rules only. Deletes and changes NO existing data.
-- Security model:
--   * "Owners" are the accounts listed in mrp_team_owners. You register YOUR login email near the top of this file (edit it in the SQL Editor first).
--   * Only a registered owner, or an administrator on that owner's team, can manage a team. Nobody else can, even though they are signed in.
--   * Every team function works only on the caller's OWN team. Nobody can touch another team's people or data.

-- ---------- registered owners ----------
create table if not exists public.mrp_team_owners (
  owner      uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.mrp_team_owners enable row level security;
revoke all on public.mrp_team_owners from anon, authenticated;    -- no policies: only the database owner and our functions can use it

-- ---------- register YOUR exact login as the team owner (runs first so a mistake stops everything before any change) ----------
-- BEFORE RUNNING: in the SQL Editor, replace PUT_YOUR_LOGIN_EMAIL_HERE below with your MyRoute Pro login email (keep the quote marks).
-- (Your email is typed in the editor only, never saved in GitHub.) If it does not match exactly ONE account, this stops with an error.
do $$
declare v_email text := 'PUT_YOUR_LOGIN_EMAIL_HERE'; n int; v_id uuid;
begin
  if v_email is null or v_email like 'PUT\_YOUR%' then
    raise exception 'Stopped: replace PUT_YOUR_LOGIN_EMAIL_HERE with your MyRoute Pro login email, then run again. Nothing was changed.';
  end if;
  select count(*) into n from auth.users where lower(email) = lower(trim(v_email));
  if n <> 1 then
    raise exception 'Stopped: % account(s) match "%". Expected exactly 1. Nothing was changed.', n, v_email;
  end if;
  select id into v_id from auth.users where lower(email) = lower(trim(v_email));
  insert into public.mrp_team_owners(owner) values (v_id) on conflict (owner) do nothing;
end $$;

-- ---------- team membership ----------
create table if not exists public.members (
  member     uuid primary key references auth.users(id) on delete cascade,   -- one team per person
  owner      uuid not null references auth.users(id) on delete cascade,      -- whose data they work on
  role       text not null default 'viewer' check (role in ('admin','manager','user','viewer')),
  created_at timestamptz not null default now()
);
alter table public.members enable row level security;
revoke all on public.members from anon, authenticated;
grant select on public.members to authenticated;
drop policy if exists mrp_members_self on public.members;   -- replaces only this file's own policy of the same name
create policy mrp_members_self on public.members for select to authenticated using (member = auth.uid());

-- ---------- helper functions (all pin their search path; none accept a user id from the caller) ----------
-- Whose data the signed-in person works on: their team owner, or themself.
create or replace function public.mrp_my_owner() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select coalesce((select m.owner from public.members m where m.member = auth.uid() limit 1), auth.uid());
$$;
-- True only for a registered owner, or an administrator on a registered owner's team. NOT true for everyone else.
create or replace function public.mrp_is_team_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select auth.uid() is not null and (
    exists (select 1 from public.mrp_team_owners o where o.owner = auth.uid())
    or exists (select 1 from public.members m join public.mrp_team_owners o on o.owner = m.owner
               where m.member = auth.uid() and m.role = 'admin'));
$$;
-- True when the caller belongs to a registered team (as owner or member). Messaging and file numbers require this.
create or replace function public.mrp_in_team() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select auth.uid() is not null and exists (select 1 from public.mrp_team_owners o where o.owner = public.mrp_my_owner());
$$;
revoke all on function public.mrp_my_owner() from public, anon;
revoke all on function public.mrp_is_team_admin() from public, anon;
revoke all on function public.mrp_in_team() from public, anon;
grant execute on function public.mrp_my_owner() to authenticated;
grant execute on function public.mrp_is_team_admin() to authenticated;
grant execute on function public.mrp_in_team() to authenticated;

-- ---------- team functions used by Settings > Team Management ----------
create or replace function public.mrp_list_members()
returns table(member uuid, email text, role text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.mrp_is_team_admin() then raise exception 'not allowed'; end if;
  return query select m.member, u.email::text, m.role from public.members m join auth.users u on u.id = m.member
    where m.owner = public.mrp_my_owner() order by u.email;
end $$;

create or replace function public.mrp_add_member(p_email text, p_role text)
returns text
language plpgsql security definer set search_path = public, auth as $$
declare t uuid; o uuid := public.mrp_my_owner();
begin
  if not public.mrp_is_team_admin() then raise exception 'not allowed'; end if;
  if p_role not in ('admin','manager','user','viewer') then return 'bad_role'; end if;
  select id into t from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if t is null then return 'no_account'; end if;
  if t = auth.uid() or t = o then return 'self'; end if;
  if exists (select 1 from public.mrp_team_owners where owner = t) then return 'owner_account'; end if;   -- never pull another owner into a team
  if exists (select 1 from public.members where member = t and owner <> o) then return 'other_team'; end if;
  insert into public.members(member, owner, role) values (t, o, p_role)
    on conflict (member) do update set role = excluded.role where public.members.owner = o;
  return 'ok';
end $$;

create or replace function public.mrp_set_member_role(p_member uuid, p_role text)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.mrp_is_team_admin() then raise exception 'not allowed'; end if;
  if p_role not in ('admin','manager','user','viewer') then raise exception 'bad role'; end if;
  if p_member = auth.uid() then raise exception 'you cannot change your own role'; end if;
  update public.members set role = p_role where member = p_member and owner = public.mrp_my_owner();
end $$;

create or replace function public.mrp_remove_member(p_member uuid)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.mrp_is_team_admin() then raise exception 'not allowed'; end if;
  if p_member = auth.uid() then raise exception 'you cannot remove yourself'; end if;
  delete from public.members where member = p_member and owner = public.mrp_my_owner();
end $$;

revoke all on function public.mrp_list_members() from public, anon;
revoke all on function public.mrp_add_member(text,text) from public, anon;
revoke all on function public.mrp_set_member_role(uuid,text) from public, anon;
revoke all on function public.mrp_remove_member(uuid) from public, anon;
grant execute on function public.mrp_list_members() to authenticated;
grant execute on function public.mrp_add_member(text,text) to authenticated;
grant execute on function public.mrp_set_member_role(uuid,text) to authenticated;
grant execute on function public.mrp_remove_member(uuid) to authenticated;

-- ---------- let team members work on their owner's data, by role ----------
-- EXTRA rules added beside your existing ones: the owner keeps exactly the access they have now.
-- Everyone on the team can read; administrators, managers and users can add and change; only administrators can delete.
-- The DROP POLICY lines below only remove policies with THESE names (created by this file on an earlier run). They never touch your own policies or any data.
do $$ begin
  if to_regclass('public.docs') is not null then
    execute 'drop policy if exists mrp_team_docs_read on public.docs';
    execute 'create policy mrp_team_docs_read on public.docs for select to authenticated using (owner in (select m.owner from public.members m where m.member = auth.uid()))';
    execute 'drop policy if exists mrp_team_docs_insert on public.docs';
    execute 'create policy mrp_team_docs_insert on public.docs for insert to authenticated with check (owner in (select m.owner from public.members m where m.member = auth.uid() and m.role in (''admin'',''manager'',''user'')))';
    execute 'drop policy if exists mrp_team_docs_update on public.docs';
    execute 'create policy mrp_team_docs_update on public.docs for update to authenticated using (owner in (select m.owner from public.members m where m.member = auth.uid() and m.role in (''admin'',''manager'',''user''))) with check (owner in (select m.owner from public.members m where m.member = auth.uid() and m.role in (''admin'',''manager'',''user'')))';
    execute 'drop policy if exists mrp_team_docs_delete on public.docs';
    execute 'create policy mrp_team_docs_delete on public.docs for delete to authenticated using (owner in (select m.owner from public.members m where m.member = auth.uid() and m.role = ''admin''))';
  end if;
  if to_regclass('public.blobs') is not null then
    execute 'drop policy if exists mrp_team_blobs_read on public.blobs';
    execute 'create policy mrp_team_blobs_read on public.blobs for select to authenticated using (owner in (select m.owner from public.members m where m.member = auth.uid()))';
    execute 'drop policy if exists mrp_team_blobs_insert on public.blobs';
    execute 'create policy mrp_team_blobs_insert on public.blobs for insert to authenticated with check (owner in (select m.owner from public.members m where m.member = auth.uid() and m.role in (''admin'',''manager'',''user'')))';
    execute 'drop policy if exists mrp_team_blobs_update on public.blobs';
    execute 'create policy mrp_team_blobs_update on public.blobs for update to authenticated using (owner in (select m.owner from public.members m where m.member = auth.uid() and m.role in (''admin'',''manager'',''user''))) with check (owner in (select m.owner from public.members m where m.member = auth.uid() and m.role in (''admin'',''manager'',''user'')))';
  end if;
end $$;

-- Final check: shows the registered owner account(s). It must be YOUR login email.
select u.email as registered_owner_email from public.mrp_team_owners o join auth.users u on u.id = o.owner;
