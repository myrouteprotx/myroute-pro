-- MyRoute Pro: team directory (adds name, phone and last login to the Team list)
-- Run once in Supabase > SQL Editor. It only ADDS a new function; nothing existing is changed or deleted.
-- It builds on the existing mrp_list_members() (which already limits who may see the team) and
-- reads the sign-in record that Supabase already keeps. Name and phone appear only if they were
-- stored on the person's login; otherwise the app shows "Not available".
create or replace function public.mrp_team_directory()
returns table(member uuid, email text, role text, name text, phone text, last_login timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select m.member, m.email, m.role,
         coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name') as name,
         coalesce(nullif(u.phone,''), u.raw_user_meta_data->>'phone') as phone,
         u.last_sign_in_at as last_login
  from public.mrp_list_members() m
  left join auth.users u on u.id = m.member;
$$;
revoke all on function public.mrp_team_directory() from public, anon;
grant execute on function public.mrp_team_directory() to authenticated;
