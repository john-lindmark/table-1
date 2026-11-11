-- Privacy lockdown, step 3 (contract/privacy-lockdown-2026-10-18.md § Step 3; plan step 10).
-- Since step 2 (2026-10-19) every client reads events through event_bundle / event_public / people and hears
-- about changes on the data-free event:<id> broadcast. The tables were still readable by anyone holding the
-- public key: every event (private ones too), every participant's name and account id, every result, and every
-- account's name and handle. This closes them:
--   * events, participants, pods, event_teams, rounds, matches, match_sides: members only (organizer or player,
--     public.in_event). Old builds and the tracker's postgres_changes on rounds keep working for members.
--   * profiles: your own row only (display_name / handle on Account). Everyone else goes through people().
--   * signed-out callers read only the card catalog from tables.
--   * no client role keeps a write privilege on a table without a write policy (RLS already refused those
--     writes; this is belt and braces in case a policy is ever loosened).

-- Event tables ------------------------------------------------------------
-- Drop every read policy on these tables and on profiles, whatever its name (live calls them *_public_read and
-- profiles_read; older databases *_read). Write policies are left alone (the RPC-only migration removed them).
do $$
declare p record;
begin
  for p in
    select pol.polname, pol.polrelid::regclass as rel
      from pg_policy pol
     where pol.polrelid in ('public.events'::regclass, 'public.participants'::regclass, 'public.pods'::regclass,
                            'public.event_teams'::regclass, 'public.rounds'::regclass, 'public.matches'::regclass,
                            'public.match_sides'::regclass, 'public.profiles'::regclass)
       and pol.polcmd = 'r'
  loop
    execute format('drop policy %I on %s', p.polname, p.rel);
  end loop;
end $$;

create policy events_member_read on public.events for select to authenticated using (public.in_event(id));
create policy participants_member_read on public.participants for select to authenticated using (public.in_event(event_id));
create policy pods_member_read on public.pods for select to authenticated using (public.in_event(event_id));
create policy event_teams_member_read on public.event_teams for select to authenticated using (public.in_event(event_id));
create policy rounds_member_read on public.rounds for select to authenticated using (public.in_event(event_id));
create policy matches_member_read on public.matches for select to authenticated using (public.in_event(event_id));
create policy match_sides_member_read on public.match_sides for select to authenticated using (public.in_event(event_id));

-- Profiles ----------------------------------------------------------------
create policy profiles_own_read on public.profiles for select to authenticated using (id = (select auth.uid()));

-- Grants --------------------------------------------------------------------
do $$
declare t record;
begin
  for t in
    select c.oid::regclass as rel, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f')
  loop
    -- Signed out: nothing but the catalog, and never a write.
    execute format('revoke insert, update, delete, truncate, references, trigger on %s from anon', t.rel);
    if t.relname not in ('cards', 'card_oracles', 'card_names', 'card_prices', 'mtg_sets') then
      execute format('revoke select on %s from anon', t.rel);
    end if;
    -- Signed in: never truncate (it skips RLS); writes only where a policy allows one (devices,
    -- notification_prefs, user_settings, profiles).
    execute format('revoke truncate, references, trigger on %s from authenticated', t.rel);
    if not exists (select 1 from pg_policy p
                    where p.polrelid = t.rel and p.polcmd in ('*', 'a', 'w', 'd')
                      and (p.polroles = '{0}' or 'authenticated'::regrole::oid = any (p.polroles))) then
      execute format('revoke insert, update, delete, truncate, references, trigger on %s from authenticated', t.rel);
    end if;
  end loop;
end $$;

-- Profiles keep their column-level update grant (handle, display_name); nobody inserts or deletes one directly
-- (sign-up makes it, delete_account removes it).
revoke insert, delete on public.profiles from authenticated;
