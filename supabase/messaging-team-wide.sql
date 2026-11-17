-- MyRoute Pro: only owners, administrators and managers may start a team-wide group.
-- Run ONCE in Supabase > SQL Editor, AFTER messaging-and-file-numbers.sql. It only replaces one function; no data is touched.
create or replace function public.mrp_msg_start(p_users uuid[], p_mode text, p_title text, p_body text, p_visit bigint default null)
returns uuid[]
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); o uuid := public.mrp_my_owner(); u uuid; cid uuid; ids uuid[] := '{}'; r text; team int;
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_users is null or array_length(p_users,1) is null then raise exception 'choose at least one person'; end if;
  if exists (select 1 from unnest(p_users) x where x = me or x not in (select pp.uid from public.mrp_msg_people() pp)) then
    raise exception 'you can only message people on your team';
  end if;
  select coalesce((select m.role from public.members m where m.member = me limit 1), 'admin') into r;
  select count(*) into team from public.mrp_msg_people() pp where pp.uid <> me;
  if p_mode = 'group' and array_length(p_users,1) >= 2 then
    if array_length(p_users,1) >= team and team >= 3 and r not in ('admin','manager') then
      raise exception 'only administrators and managers can start a team-wide group';
    end if;
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
