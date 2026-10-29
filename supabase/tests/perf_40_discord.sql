-- Table 1 for Discord (20261029130000_discord): the card and a sign-up on a full night. Budgets ~5x local, like
-- perf_20_event_reads.sql. Run with `T1_PERF=1 supabase/tests/run.sh perf_`.
\ir _helpers.sql
set client_min_messages = notice;

insert into auth.users (id, email)
select md5('u' || g)::uuid, 'p' || g || '@example.com' from generate_series(1, 64) g;
\set ORG '''00000000-0000-0000-0000-0000000000f2'''
insert into auth.users (id, email) values (:ORG, 'org@example.com');
\set EV '''e0000000-0000-0000-0000-0000000000f2'''
insert into public.events (id, short_code, name, created_by, status, visibility, current_round, number_of_rounds, capacity)
values (:EV, 'BIG1', 'Big Night', :ORG, 'setup', 'link_only', 0, 6, 100);
insert into public.event_members (event_id, user_id, role) values (:EV, :ORG, 'owner');
insert into public.pods (id, event_id) values ('f0000000-0000-0000-0000-0000000000f2', :EV);
insert into public.participants (id, event_id, pod_id, user_id, display_name, seat)
select md5('pt' || g)::uuid, :EV, 'f0000000-0000-0000-0000-0000000000f2', md5('u' || g)::uuid, 'Player ' || g, g
  from generate_series(1, 63) g;
insert into t1_private.discord_events (event_id, guild_id, channel_id) values (:EV, '20001', '30001');
insert into t1_private.discord_links (discord_user_id, user_id) values ('100064', md5('u64')::uuid), ('100001', :ORG);
-- 40 other posted events in the server, for autocomplete.
insert into public.events (id, short_code, name, created_by, status, visibility, number_of_rounds)
select md5('e' || g)::uuid, 'C' || lpad(g::text, 3, '0'), 'Night ' || g, :ORG, 'setup', 'link_only', 3 from generate_series(1, 40) g;
insert into t1_private.discord_events (event_id, guild_id, channel_id) select md5('e' || g)::uuid, '20001', '30001' from generate_series(1, 40) g;

select pg_temp.ms('discord card, 63 players', $$select public.discord_event_card('20001', 'e0000000-0000-0000-0000-0000000000f2')$$, 20);
select pg_temp.ms('autocomplete, 41 posted events', $$select public.discord_events_list('20001', 'open', 'night')$$, 20);
select pg_temp.ms('discord_me', $$select public.discord_me('100064')$$, 5);
select pg_temp.ms('sign up through the bot (one call: act, seat, card)',
  $$select public.discord_event_sign_up('100064', '20001', 'e0000000-0000-0000-0000-0000000000f2'); select public.discord_event_drop('100064', '20001', 'e0000000-0000-0000-0000-0000000000f2')$$, 40);
