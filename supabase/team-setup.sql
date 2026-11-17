-- MyRoute Pro: team setup (the "members" table and the functions Team Management uses)
-- Run FIRST, once, in Supabase > SQL Editor. Then run messaging-and-file-numbers.sql, team-directory.sql and messaging-team-wide.sql.
-- Safe to re-run. It only ADDS a table, functions and extra access rules. Your own data and your own access are not changed.
-- Until someone is added to your team, nothing behaves differently for you.

create table if not exists public.members (
  member     uuid primary key references auth.users(id) on delete cascade,   -- one team per person
  owner      uuid not null references auth.users(id) on delete cascade,      -- whose data they work on
  role       text not null default 'viewer' check (role in ('admin','manager','user','viewer')),
  created_at timestamptz not null default now()
);
alter table public.members enable row level security;
revoke all on public.members from anon, authenticated;
grant select on public.members to authenticated;
drop policy if exists mrp_members_self on public.members;
create policy mrp_members_self on public.members for select to authenticated using (member = auth.uid());

-- Whose data the signed-in person works on (themself if they are not on someone's team)
create or replace function public.mrp_my_owner() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select coalesce((select m.owner from public.members m where m.member = auth.uid() limit 1), auth.uid());
$$;
-- True for the owner and for administrators (the people who may manage the team)
create or replace function public.mrp_is_team_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select auth.uid() is not null and (
    not exists (select 1 from public.members m where m.member = auth.uid())
    or exists (select 1 from public.members m where m.member = auth.uid() and m.role = 'admin'));
$$;
revoke all on function public.mrp_my_owner() from public, anon;
revoke all on function public.mrp_is_team_admin() from public, anon;
grant execute on function public.mrp_my_owner() to authenticated;
grant execute on function public.mrp_is_team_admin() to authenticated;

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
  if exists (select 1 from public.members where member = t and owner <> o) then return 'other_team'; end if;
  insert into public.members(member, owner, role) values (t, o, p_role)
    on conflict (member) do update set role = excluded.role;
  return 'ok';
end $$;

create or replace function public.mrp_set_member_role(p_member uuid, p_role text)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.mrp_is_team_admin() then raise exception 'not allowed'; end if;
  if p_role not in ('admin','manager','user','viewer') then raise exception 'bad role'; end if;
  update public.members set role = p_role where member = p_member and owner = public.mrp_my_owner();
end $$;

create or replace function public.mrp_remove_member(p_member uuid)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.mrp_is_team_admin() then raise exception 'not allowed'; end if;
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

-- ---------- let team members work on the owner's data, by role ----------
-- These are EXTRA rules added beside your existing ones, so the owner keeps exactly the access they have now.
-- Everyone on the team can read; administrators, managers and users can add and change; only administrators can delete.
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
