-- MyRoute Pro: team directory (adds name, phone and last login to the Team list)
-- RUN THIRD (after team-setup.sql). Adds ONE new function. Deletes and changes nothing.
-- It builds on mrp_list_members(), which already refuses everyone except the team owner and that team's administrators,
-- and shows only that caller's own team. It reads the sign-in record Supabase already keeps (auth.users).
-- Name and phone appear only if stored on the person's login; otherwise the app shows "Not available".
do $$ begin
  if to_regprocedure('public.mrp_list_members()') is null then raise exception 'Run team-setup.sql first.'; end if;
end $$;

create or replace function public.mrp_team_directory()
returns table(member uuid, email text, role text, name text, phone text, last_login timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.mrp_is_team_admin() then raise exception 'not allowed'; end if;
  return query
    select m.member, m.email, m.role,
           coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name'),
           coalesce(nullif(u.phone,''), u.raw_user_meta_data->>'phone'),
           u.last_sign_in_at
    from public.mrp_list_members() m
    left join auth.users u on u.id = m.member;
end $$;
revoke all on function public.mrp_team_directory() from public, anon;
grant execute on function public.mrp_team_directory() to authenticated;
