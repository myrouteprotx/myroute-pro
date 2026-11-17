-- MyRoute Pro: OPTIONAL safety copy. Run this BEFORE the setup files if you want an extra backup of your visit data.
-- It only CREATES a new copy of your "docs" table (visits, notes, settings). Nothing is changed or deleted.
-- The copy is locked down (row level security on, no access rules), so only the database owner can read it.
-- To remove the copy later, once everything works: drop table public.docs_backup_before_team;
do $$
begin
  if to_regclass('public.docs') is not null and to_regclass('public.docs_backup_before_team') is null then
    execute 'create table public.docs_backup_before_team as select * from public.docs';
    execute 'alter table public.docs_backup_before_team enable row level security';
    execute 'revoke all on public.docs_backup_before_team from anon, authenticated';
  end if;
end $$;
select count(*) as rows_in_backup from public.docs_backup_before_team;
