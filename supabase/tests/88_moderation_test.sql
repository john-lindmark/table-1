-- Moderation (contract/moderation-2026-10-18.md): what gets checked, the worker's claim/record, shadow vs enforce,
-- reversible actions, notices and appeals, reports, restrictions, permissions, account deletion.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com', '{"full_name": "Cal Reyes"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com', '{"full_name": "Dee Park"}'),
  ('00000000-0000-0000-0000-0000000000e1', 'mod@example.com', '{"full_name": "Mo Derator"}');
insert into t1_private.moderators (user_id, note) values ('00000000-0000-0000-0000-0000000000e1', 'test');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set CAL '''00000000-0000-0000-0000-0000000000c1'''
\set DEE '''00000000-0000-0000-0000-0000000000d1'''
\set MOD '''00000000-0000-0000-0000-0000000000e1'''

-- The worker: claim everything, answer with a verdict per text (default allow).
create or replace function pg_temp.judge(p_block text default null, p_review text default null, p_cat text default 'hate')
returns jsonb language plpgsql as $$
declare v jsonb; res jsonb;
begin
  set local role service_role;
  v := public.moderation_claim(50);
  select coalesce(jsonb_agg(jsonb_build_object('id', c->'id',
           'verdict', case when c->>'text' = p_block or c->>'path' = p_block then 'block'
                           when c->>'text' = p_review then 'review' else 'allow' end,
           'category', case when c->>'text' = p_block or c->>'path' = p_block or c->>'text' = p_review then p_cat else 'none' end,
           'reason', 'test', 'model', 'test')), '[]'::jsonb)
    into res from jsonb_array_elements(v) c;
  perform public.moderation_record(res);
  reset role;
  return v;
end $$;
create or replace function pg_temp.checks(p_kind text) returns text language sql as $$
  select string_agg(coalesce(content, path) || ':' || status, ',' order by id) from public.moderation_checks where subject_kind = p_kind $$;

-- What gets checked -------------------------------------------------------------------------------------
select pg_temp.eq('new accounts queue their names', (select count(*)::text from public.moderation_checks where subject_kind = 'display_name'), '5');
select pg_temp.eq('queueing pings the worker', (select count(*) > 0 from net.requests where url like '%/functions/v1/moderate')::text, 'true');
select pg_temp.eq('worker claims ids, kinds and text only',
  (select string_agg(distinct k, ',' order by k) from jsonb_array_elements(pg_temp.judge()) c, jsonb_object_keys(c) k), 'bucket,id,kind,path,text');
select pg_temp.eq('allowed', pg_temp.checks('display_name'), 'Ana Lind:allow,Ben Ortiz:allow,Cal Reyes:allow,Dee Park:allow,Mo Derator:allow');

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create('d1000000-0000-0000-0000-000000000001', 'deck', 'Secret brew', 'modern', '[]'::jsonb);
select public.binder_save('b1000000-0000-0000-0000-000000000001', 'Private box', false);
reset role;
select pg_temp.eq('private names are never checked', coalesce(pg_temp.checks('list_name'), '') || coalesce(pg_temp.checks('binder_name'), ''), '');
set role authenticated;
select pg_temp.as_user(:ANA);
select public.sharing_set('{"library": "friends"}');
reset role;
select pg_temp.eq('sharing the Library checks what now reaches friends (the new deck stays private)',
  coalesce(pg_temp.checks('list_name'), '-') || ' ' || pg_temp.checks('binder_name'), '- Private box:pending');
set role authenticated;
select pg_temp.as_user(:ANA);
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('kind', 'deck', 'id', 'd1000000-0000-0000-0000-000000000001', 'visibility', 'friends'))));
reset role;
select pg_temp.eq('sharing a deck checks its name', pg_temp.checks('list_name'), 'Secret brew:pending');
select pg_temp.judge();

-- The same words judged before are reused, not re-sent.
set role authenticated;
select pg_temp.as_user(:BEN);
select public.sharing_set('{"library": "public", "profile": "public"}');
select public.binder_save('b2000000-0000-0000-0000-000000000001', 'Private box', true);
reset role;
select pg_temp.eq('cached verdict', (select status || '/' || model from public.moderation_checks
  where subject_kind = 'binder_name' and subject_id = 'b2000000-0000-0000-0000-000000000001'), 'allow/cache');

-- Shadow mode: verdicts and the queue, no action -----------------------------------------------------------
update public.profiles set display_name = 'Nasty Name' where id = :CAL;
select pg_temp.judge('Nasty Name');
select pg_temp.eq('shadow: blocked but untouched', (select display_name from public.profiles where id = :CAL), 'Nasty Name');
select pg_temp.eq('moderators told', (select count(*)::text from pgmq.messages where msg->>'kind' = 'moderation.review'), '1');
set role authenticated;
select pg_temp.as_user(:MOD);
select pg_temp.eq('queue shows the block', (select string_agg(x->>'text' || ':' || (x->>'enforced'), ',')
  from jsonb_array_elements(public.moderation_queue()->'checks') x), 'Nasty Name:false');
select pg_temp.eq('a moderator blocks it by hand (any mode)', public.moderation_resolve(
  (select (x->>'id')::bigint from jsonb_array_elements(public.moderation_queue()->'checks') x), 'block')->>'status', 'block');
reset role;
select pg_temp.eq('reset to a neutral name', (select display_name from public.profiles where id = :CAL),
  'Player ' || upper(right(replace(:CAL, '-', ''), 4)));
select pg_temp.eq('the owner is told', (select count(*)::text from pgmq.messages where msg->>'kind' = 'moderation.notice'
  and msg->'user_ids' ? '00000000-0000-0000-0000-0000000000c1'), '1');
select pg_temp.eq('the reset name is not itself checked', (select count(*)::text from public.moderation_checks
  where subject_kind = 'display_name' and content like 'Player %'), '0');

-- Child safety applies in shadow mode too.
update public.profiles set avatar_url = '00000000-0000-0000-0000-0000000000d1/abc.jpg' where id = :DEE;
select pg_temp.judge('00000000-0000-0000-0000-0000000000d1/abc.jpg', null, 'child_safety');
select pg_temp.eq('child-safety photo taken down at once', coalesce((select avatar_url from public.profiles where id = :DEE), 'none'), 'none');

-- Enforce mode -------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:MOD);
select pg_temp.eq('mode switch', public.moderation_set_mode('enforce')->>'mode', 'enforce');
reset role;

insert into public.events (id, short_code, name, created_by, status) values
  ('e1000000-0000-0000-0000-000000000001', 'MOD1', 'Friday draft', :ANA, 'setup');
insert into public.event_members (event_id, user_id, role) values ('e1000000-0000-0000-0000-000000000001', :ANA, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', :ANA, 'Ana Lind', 1),
  ('f1000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001', null, 'Rude Guest', 2);
select pg_temp.eq('guest names are checked, players'' are not', pg_temp.checks('guest_name'), 'Rude Guest:pending');
select pg_temp.judge('Rude Guest');
select pg_temp.eq('guest renamed by seat', (select display_name from public.participants where id = 'f1000000-0000-0000-0000-000000000002'), 'Guest 2');
select pg_temp.eq('audited in the event', (select count(*)::text from public.audit_log where action = 'moderation.renamed'), '1');
update public.events set name = 'Bad Event' where id = 'e1000000-0000-0000-0000-000000000001';
select pg_temp.judge('Bad Event');
select pg_temp.eq('event renamed by code', (select name from public.events where id = 'e1000000-0000-0000-0000-000000000001'), 'Event MOD1');

-- A deck name that reaches people stops being shared; its setting comes back on revert.
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_update('d1000000-0000-0000-0000-000000000001', 'Offensive deck');
reset role;
select pg_temp.judge('Offensive deck', null, 'harassment');
select pg_temp.eq('deck unshared', (select visibility from public.card_lists where id = 'd1000000-0000-0000-0000-000000000001'), 'private');

-- Content changed before the verdict: nothing happens.
update public.profiles set display_name = 'Slow Name' where id = :ANA;
set role service_role;
select public.moderation_claim(50) \gset claimed_
reset role;
update public.profiles set display_name = 'Ana Lind' where id = :ANA;
set role service_role;
select public.moderation_record((select jsonb_agg(jsonb_build_object('id', id, 'verdict', 'block', 'category', 'hate', 'reason', 'x', 'model', 'm'))
  from public.moderation_checks where status = 'running'));
reset role;
select pg_temp.eq('a stale verdict does nothing', (select display_name from public.profiles where id = :ANA), 'Ana Lind');
select pg_temp.judge();

-- Notices and appeals ------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('notices name what changed', (select string_agg(x->>'label' || '|' || (x->>'reason_text'), ';' order by x->>'id')
  from jsonb_array_elements(public.moderation_notices()) x),
  'Guest Rude Guest|It looks like hate speech.;Event Bad Event|It looks like hate speech.;Deck Offensive deck|It looks like it targets or harasses someone.');
select (x->>'id')::bigint deck_action from jsonb_array_elements(public.moderation_notices()) x where x->>'label' like 'Deck%' \gset
select pg_temp.eq('unseen badge', (public.moderation_me()->>'unseen'), '3');
select public.moderation_notices_seen();
select pg_temp.eq('seen', (public.moderation_me()->>'unseen'), '0');
select pg_temp.eq('appeal', public.moderation_appeal(:deck_action, 'It is a card name')->>'appeal', 'open');
select pg_temp.throws('one appeal per action', format('select public.moderation_appeal(%s)', :deck_action), '22023');
select pg_temp.as_user(:BEN);
select pg_temp.throws('not yours', format('select public.moderation_appeal(%s)', :deck_action), '42501');
select pg_temp.throws('not a moderator', 'select public.moderation_queue()', '42501');
select pg_temp.throws('not a moderator: resolve', format('select public.moderation_appeal_resolve(%s, ''revert'')', :deck_action), '42501');
select pg_temp.as_user(:MOD);
select pg_temp.eq('the appeal is queued with its note', (select x->>'note' from jsonb_array_elements(public.moderation_queue()->'appeals') x), 'It is a card name');
select pg_temp.eq('revert', public.moderation_appeal_resolve(:deck_action, 'revert')->>'appeal', 'reverted');
reset role;
select pg_temp.eq('sharing restored', (select visibility from public.card_lists where id = 'd1000000-0000-0000-0000-000000000001'), 'friends');
select pg_temp.eq('a reverted action is no strike', t1_private.strikes(:ANA)::text, '2');

-- A revert never clobbers a later change.
update public.profiles set display_name = 'Worse Name' where id = :BEN;
select pg_temp.judge('Worse Name');
select id ben_action from public.moderation_actions where owner = :BEN and action = 'reset_name' and reverted_at is null \gset
update public.profiles set display_name = 'Benjamin' where id = :BEN;
select t1_private.moderation_revert(:ben_action);
select pg_temp.eq('later rename kept', (select display_name from public.profiles where id = :BEN), 'Benjamin');
select pg_temp.judge();

-- Reports -------------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select public.user_report(:CAL, 'harassment');
reset role;
select pg_temp.eq('a report queues its own check of the name and links to it', (select c.source || '/' || c.status
  from public.user_reports r join public.moderation_checks c on c.id = r.check_id where r.reporter = :ANA), 'report/pending');
select pg_temp.judge();
set role authenticated;
select pg_temp.as_user(:BEN);
select public.user_report(:CAL, 'spam');
select pg_temp.as_user(:DEE);
select public.user_report(:CAL, 'harassment');
select pg_temp.as_user(:MOD);
select pg_temp.eq('3 reporters flag the account', (select string_agg(x->>'display_name' || ':' || (x->>'reporters'), ',')
  from jsonb_array_elements(public.moderation_queue()->'flagged') x), 'Player ' || upper(right(replace(:CAL, '-', ''), 4)) || ':3');

-- Restrictions ----------------------------------------------------------------------------------------------
select pg_temp.eq('restrict', ((public.moderation_restrict(:CAL, 7, 'Harassing players')->>'restricted_until') is not null)::text, 'true');
select pg_temp.as_user(:CAL);
select pg_temp.throws('no friend requests while restricted', format('select public.friend_request(%L)', :ANA), '42501');
select pg_temp.eq('they know', ((public.moderation_me()->>'restricted_until') is not null)::text, 'true');
select pg_temp.as_user(:BEN);
select pg_temp.eq('profile hidden while restricted', public.profile_view(:CAL)->>'visible', 'false');
select pg_temp.as_user(:MOD);
select public.moderation_restrict(:CAL, 0, null);
select pg_temp.as_user(:CAL);
select pg_temp.eq('lifted', public.friend_request(:ANA)->>'status', 'requested');

-- Permissions -----------------------------------------------------------------------------------------------
select pg_temp.throws('accounts cannot claim', 'select public.moderation_claim(1)', '42501');
select pg_temp.throws('accounts cannot record', 'select public.moderation_record(''[]'')', '42501');
select pg_temp.throws('tables are RPC-only', 'select count(*) from public.moderation_checks', '42501');
select pg_temp.as_user(:MOD);
select pg_temp.eq('stats', (public.moderation_stats()->>'mode'), 'enforce');
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon: notices', 'select public.moderation_notices()');
select pg_temp.throws('anon: queue', 'select public.moderation_queue()');
reset role;

-- Gave up after 3 tries: a person looks.
update public.profiles set display_name = 'Flaky' where id = :DEE;
update public.moderation_checks set attempts = 3, status = 'running', claimed_at = now() - interval '10 minutes' where content = 'Flaky';
set role service_role;
select public.moderation_claim(5);
reset role;
select pg_temp.eq('three failed tries go to review', (pg_temp.checks('display_name') like '%Flaky:review%')::text, 'true');

-- Account deletion --------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select public.delete_account();
reset role;
select pg_temp.eq('checks gone', (select count(*)::text from public.moderation_checks where owner = :ANA), '0');
select pg_temp.eq('actions kept without the owner', (select count(*)::text from public.moderation_actions where owner = :ANA), '0');
select pg_temp.eq('...but still counted', ((select count(*) from public.moderation_actions where owner is null) >= 3)::text, 'true');
