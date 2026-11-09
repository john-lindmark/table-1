-- Discord and drafts with several pods (20261109190000_discord_pods, contract/discord-2026-10-29.md § Pods):
-- /event create takes pods and pairing for a draft, the card carries the pick and the seated pods, and a posted card
-- is asked to redraw when the pick or a player's pod changes. Re-pairing a round redraws it through current_round.
\ir _helpers.sql

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000094c1', 'ana@example.com');
\set ANA '''00000000-0000-0000-0000-0000000094c1'''
update public.profiles set display_name = 'Ana' where id = :ANA;
insert into t1_private.discord_links (discord_user_id, user_id) values ('194301', :ANA);

-- Create ------------------------------------------------------------------------------------------------
select public.discord_event_create('194301', '29401', '39401', 'draft', 'Pod night', p_pods => 2, p_pod_pairing => 'cross',
  p_local_date => '2026-11-09') as ev \gset
select ((:'ev'::jsonb)->>'event_id') as ev_id \gset
select pg_temp.eq('a draft made with 2 pods across', (select pods || '|' || pod_pairing from public.events where id = :'ev_id'), '2|cross');
select pg_temp.eq('the card carries the pick, no sizes before the draw',
  ((:'ev'::jsonb)->>'pods') || '|' || ((:'ev'::jsonb)->>'pod_pairing') || '|' || coalesce((:'ev'::jsonb)->>'pod_sizes', 'null'), '2|cross|null');
select pg_temp.eq('the pick is audited like the apps''', (select count(*)::text from public.audit_log where event_id = :'ev_id' and action = 'event.pods_updated'), '1');
select (public.discord_event_create('194301', '29401', '39401', 'draft', 'Pairing only', p_pod_pairing => 'cross')->>'event_id') as ev_p \gset
select pg_temp.eq('pairing alone: automatic pods, that pairing',
  (select coalesce(pods::text, 'auto') || '|' || pod_pairing from public.events where id = :'ev_p'), 'auto|cross');
select (public.discord_event_create('194301', '29401', '39401', 'draft', 'Plain draft')->>'event_id') as ev_plain \gset
select pg_temp.eq('neither: the defaults (automatic, inside pods), nothing extra audited',
  (select coalesce(e.pods::text, 'auto') || '|' || e.pod_pairing || '|' || (select count(*) from public.audit_log a where a.event_id = e.id and a.action = 'event.pods_updated')
     from public.events e where e.id = :'ev_plain'), 'auto|pod|0');
select pg_temp.throws('pods on a constructed event are refused', $$select public.discord_event_create('194301', '29401', '39401', 'modern', p_pods => 2)$$, '22023');
select pg_temp.throws('pairing on sealed is refused', $$select public.discord_event_create('194301', '29401', '39401', 'sealed', p_pod_pairing => 'pod')$$, '22023');
select pg_temp.throws('pods are 1 to 16', $$select public.discord_event_create('194301', '29401', '39401', 'draft', p_pods => 17)$$, '22023');
select pg_temp.throws('pair inside or across', $$select public.discord_event_create('194301', '29401', '39401', 'draft', p_pod_pairing => 'sideways')$$, '22023');
select pg_temp.eq('a refused create makes nothing', (select count(*)::text from public.events where created_by = :ANA), '3');
select pg_temp.eq('other formats carry no pods', coalesce(public.discord_event_create('194301', '29401', '39401', 'modern')->>'pod_pairing', 'null'), 'null');

-- The card once seated ------------------------------------------------------------------------------------
insert into public.participants (event_id, display_name, seat)
select :'ev_id', 'Guest ' || i, i + 1 from generate_series(1, 14) i;   -- 15 with Ana
select public.discord_event_posted(:'ev_id', 'event', '49401');
select pg_temp.as_user(:ANA);   -- the organizer draws the seats and changes the pick
select public.seat_event(:'ev_id');
select pg_temp.eq('seated: each pod''s size in order', public.discord_card_current(:'ev_id')->>'pod_sizes', '[8, 7]');

-- Redraws -------------------------------------------------------------------------------------------------
delete from net.requests;
select public.set_event_pods(:'ev_id', 2, 'pod');
select pg_temp.eq('changing the pairing asks for a redraw', (select count(*)::text from net.requests where url like '%/discord-bot'), '1');
delete from net.requests;
update public.participants set pod_id = (select id from public.pods where event_id = :'ev_id' and name = 'Pod 2')
 where id = (select id from public.participants where event_id = :'ev_id' and seat = 8
               and pod_id = (select id from public.pods where event_id = :'ev_id' and name = 'Pod 1'));
select pg_temp.eq('a player changing pods asks for a redraw', (select count(*)::text from net.requests where url like '%/discord-bot'), '1');
delete from net.requests;
update public.events set pods = 3 where id = :'ev_id';
select pg_temp.eq('changing the number of pods asks for a redraw', (select count(*)::text from net.requests where url like '%/discord-bot'), '1');
delete from net.requests;
update public.events set current_round = 1, status = 'in_progress' where id = :'ev_id';
update public.events set current_round = 0 where id = :'ev_id';
select pg_temp.eq('a round paired, then taken back (withdraw_round): each asks for a redraw',
  (select count(*)::text from net.requests where url like '%/discord-bot'), '2');
select pg_temp.eq('the card says the round as it is now', public.discord_card_current(:'ev_id')->>'current_round', '0');

-- Grants --------------------------------------------------------------------------------------------------
select pg_temp.eq('clients can''t create events as the bot',
  has_function_privilege('authenticated', 'public.discord_event_create(text, text, text, text, text, timestamptz, text, integer, integer, integer, text, text, date, integer, text)', 'execute')::text, 'false');
select pg_temp.eq('the old signature is gone',
  (select count(*)::text from pg_proc where proname = 'discord_event_create'), '1');
