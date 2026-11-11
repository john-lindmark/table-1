-- Privacy lockdown, step 3 (migration 20261111170000): event tables are members-only, profiles are your own row,
-- signed-out callers read only the catalog, and client roles hold no write privilege without a write policy.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000bb01', 'ola@example.com', '{"full_name": "Ola Org"}'),
  ('00000000-0000-0000-0000-00000000bb02', 'pia@example.com', '{"full_name": "Pia Play"}'),
  ('00000000-0000-0000-0000-00000000bb03', 'sam@example.com', '{"full_name": "Sam Stranger"}');
\set OLA '''00000000-0000-0000-0000-00000000bb01'''
\set PIA '''00000000-0000-0000-0000-00000000bb02'''
\set SAM '''00000000-0000-0000-0000-00000000bb03'''
\set EV  '''e0000000-0000-0000-0000-0000000000b1'''

insert into public.events (id, short_code, name, created_by, status, visibility, team_size)
  values (:EV, 'LCK1', 'Locked Night', :OLA, 'in_progress', 'link_only', 2);
insert into public.event_members (event_id, user_id, role) values (:EV, :OLA, 'owner');
insert into public.pods (id, event_id) values ('f0000000-0000-0000-0000-0000000000b1', :EV);
insert into public.event_teams (id, event_id, display_order, name) values ('d0000000-0000-0000-0000-0000000000b1', :EV, 0, 'Team A');
insert into public.participants (id, event_id, pod_id, user_id, display_name, seat) values
  ('a0000000-0000-0000-0000-0000000000b1', :EV, 'f0000000-0000-0000-0000-0000000000b1', :PIA, 'Pia Play', 1),
  ('a0000000-0000-0000-0000-0000000000b2', :EV, 'f0000000-0000-0000-0000-0000000000b1', null, 'Walk In', 2);
insert into public.rounds (id, event_id, number, status) values ('b0000000-0000-0000-0000-0000000000b1', :EV, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number)
  values ('c0000000-0000-0000-0000-0000000000b1', :EV, 'b0000000-0000-0000-0000-0000000000b1', 1);
insert into public.match_sides (match_id, participant_id, side, game_wins) values
  ('c0000000-0000-0000-0000-0000000000b1', 'a0000000-0000-0000-0000-0000000000b1', 0, 0),
  ('c0000000-0000-0000-0000-0000000000b1', 'a0000000-0000-0000-0000-0000000000b2', 1, 0);

create function pg_temp.seen() returns text language sql as $$
  select concat_ws(',',
    (select count(*) from public.events where id = 'e0000000-0000-0000-0000-0000000000b1'),
    (select count(*) from public.participants where event_id = 'e0000000-0000-0000-0000-0000000000b1'),
    (select count(*) from public.pods where event_id = 'e0000000-0000-0000-0000-0000000000b1'),
    (select count(*) from public.event_teams where event_id = 'e0000000-0000-0000-0000-0000000000b1'),
    (select count(*) from public.rounds where event_id = 'e0000000-0000-0000-0000-0000000000b1'),
    (select count(*) from public.matches where event_id = 'e0000000-0000-0000-0000-0000000000b1'),
    (select count(*) from public.match_sides where event_id = 'e0000000-0000-0000-0000-0000000000b1'));
$$;
grant execute on function pg_temp.seen() to anon, authenticated;

-- Event tables: members only --------------------------------------------------
set role authenticated;
select pg_temp.as_user(:OLA);
select pg_temp.eq('the organizer reads the event, players, pod, team, round, match and sides', pg_temp.seen(), '1,2,1,1,1,1,2');
select pg_temp.as_user(:PIA);
select pg_temp.eq('a player reads the same', pg_temp.seen(), '1,2,1,1,1,1,2');
select pg_temp.as_user(:SAM);
select pg_temp.eq('a stranger reads nothing from the tables', pg_temp.seen(), '0,0,0,0,0,0,0');
select pg_temp.eq('… and still sees a link event through event_public', ((public.event_public(:EV, null))::text like '%Locked Night%')::text, 'true');
select pg_temp.as_user(:PIA);
select pg_temp.eq('a player''s event_bundle is unchanged',
  (select jsonb_array_length(to_jsonb(public.event_bundle(:EV, null))->'participants'))::text, '2');
select pg_temp.as_user(:SAM);
reset role;

set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('signed out: events closed', $$select 1 from public.events$$, '42501');
select pg_temp.throws('signed out: participants closed', $$select 1 from public.participants$$, '42501');
select pg_temp.throws('signed out: matches closed', $$select 1 from public.matches$$, '42501');
select pg_temp.throws('signed out: match sides closed', $$select 1 from public.match_sides$$, '42501');
select pg_temp.throws('signed out: rounds closed', $$select 1 from public.rounds$$, '42501');
select pg_temp.throws('signed out: profiles closed', $$select 1 from public.profiles$$, '42501');
select pg_temp.eq('signed out still reads the card catalog', (select count(*) >= 0 from public.cards)::text, 'true');
select pg_temp.eq('signed out still previews a link event', ((public.event_preview('LCK1', null))::text like '%Locked Night%')::text, 'true');
reset role;

-- Profiles: your own row ------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:SAM);
select pg_temp.eq('you read your own profile only', (select string_agg(display_name, ',') from public.profiles), 'Sam Stranger');
update public.profiles set display_name = 'Sam S' where id = :SAM;
update public.profiles set display_name = 'Hacked' where id = :PIA;
select pg_temp.throws('nobody makes a profile directly',
  $$insert into public.profiles (id, display_name) values (gen_random_uuid(), 'x')$$, '42501');
select pg_temp.throws('is_demo is not yours to change', format($$update public.profiles set is_demo = true where id = %L$$, :SAM), '42501');
reset role;
select pg_temp.eq('your own rename landed, another account''s did not',
  (select string_agg(display_name, ',' order by display_name) from public.profiles where id in (:SAM, :PIA)), 'Pia Play,Sam S');

-- Own settings still save ---------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:SAM);
insert into public.user_settings (user_id, tracker_mode) values (:SAM, 'tracker')
  on conflict (user_id) do update set tracker_mode = excluded.tracker_mode;
insert into public.notification_prefs (user_id, nearby_alerts) values (:SAM, false)
  on conflict (user_id) do update set nearby_alerts = excluded.nearby_alerts;
select pg_temp.throws('another account''s settings are refused',
  format($$insert into public.user_settings (user_id, tracker_mode) values (%L, 'tracker')$$, :PIA), '42501');
reset role;
select pg_temp.eq('own settings saved', (select tracker_mode from public.user_settings where user_id = :SAM), 'tracker');

-- Grants -----------------------------------------------------------------------------
select pg_temp.eq('anon writes nowhere',
  (select coalesce(string_agg(c.relname, ',' order by c.relname), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and (has_table_privilege('anon', c.oid, 'INSERT') or has_table_privilege('anon', c.oid, 'UPDATE')
        or has_table_privilege('anon', c.oid, 'DELETE') or has_table_privilege('anon', c.oid, 'TRUNCATE'))), '');
select pg_temp.eq('anon reads only the catalog',
  (select string_agg(c.relname, ',' order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and has_table_privilege('anon', c.oid, 'SELECT')),
  'card_names,card_oracles,card_prices,cards,mtg_sets');
select pg_temp.eq('signed in, writes only where a policy allows them',
  (select string_agg(c.relname, ',' order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and (has_table_privilege('authenticated', c.oid, 'INSERT') or has_table_privilege('authenticated', c.oid, 'DELETE')
        or has_table_privilege('authenticated', c.oid, 'TRUNCATE')
        or exists (select 1 from information_schema.column_privileges cp
                    where cp.table_schema = 'public' and cp.table_name = c.relname
                      and cp.grantee = 'authenticated' and cp.privilege_type = 'UPDATE'))),
  'devices,notification_prefs,profiles,user_settings');
