-- Organizer Live Activity (20261022170000_organizer_live_activity): org_start / org_update tokens and the dispatch
-- reaching events whose only token holder is an organizer, with the disputed/settled flags.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set EV '''e0000000-0000-0000-0000-000000000001'''
\set R1 '''f0000000-0000-0000-0000-000000000001'''
\set M1 '''f1000000-0000-0000-0000-000000000001'''
\set M2 '''f1000000-0000-0000-0000-000000000002'''
\set PB '''f2000000-0000-0000-0000-00000000000b'''
\set PC '''f2000000-0000-0000-0000-00000000000c'''
\set PG '''f2000000-0000-0000-0000-00000000000f'''
\set PH '''f2000000-0000-0000-0000-00000000000e'''

-- Alice runs (doesn't play) an event: Bea vs Cal, and two walk-in guests.
insert into public.events (id, short_code, name, created_by, status, current_round) values
  (:EV, 'ORGL01', 'Org night', :A, 'in_progress', 1);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PB, :EV, :B, 'Bea', 1), (:PC, :EV, :C, 'Cal', 2), (:PG, :EV, null, 'Gus', 3), (:PH, :EV, null, 'Hal', 4);
insert into public.rounds (id, event_id, number, status) values (:R1, :EV, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number, status) values
  (:M1, :EV, :R1, 1, 'pending'), (:M2, :EV, :R1, 2, 'pending');
insert into public.match_sides (match_id, participant_id, side, game_wins) values
  (:M1, :PB, 0, 0), (:M1, :PC, 1, 0), (:M2, :PG, 0, 0), (:M2, :PH, 1, 0);

set role authenticated;

-- Tokens --------------------------------------------------------------------------------------------
select pg_temp.as_user(:A);
select public.register_live_activity_token('org_start', repeat('a', 64), 'development', 'phone-a');
select public.register_live_activity_token('org_update', repeat('b', 64), 'development', 'phone-a',
  'e0000000-0000-0000-0000-000000000001', 'act-1');
select public.register_live_activity_token('org_update', repeat('b', 64), 'development', 'phone-a',
  'e0000000-0000-0000-0000-000000000001', 'act-1');
select public.register_live_activity_token('start', repeat('c', 64), 'development', 'phone-a');
select pg_temp.throws('organizer is not a player: no player update token',
  $$select public.register_live_activity_token('update', repeat('d', 64), 'development', 'phone-a',
    'e0000000-0000-0000-0000-000000000001', 'act-2')$$, '42501');
select pg_temp.throws('org_update needs an event',
  $$select public.register_live_activity_token('org_update', repeat('d', 64), 'development', 'phone-a')$$, '42501');
select pg_temp.throws('unknown kind refused',
  $$select public.register_live_activity_token('org_other', repeat('d', 64), 'development', 'phone-a')$$, '22023');

select pg_temp.as_user(:B);
select pg_temp.throws('a player cannot register an organizer update token',
  $$select public.register_live_activity_token('org_update', repeat('e', 64), 'development', 'phone-b',
    'e0000000-0000-0000-0000-000000000001', 'act-3')$$, '42501');
select public.register_live_activity_token('update', repeat('f', 64), 'development', 'phone-b',
  'e0000000-0000-0000-0000-000000000001', 'act-4');

select pg_temp.as_user(:A);
select public.register_live_activity_token('org_start', repeat('9', 64), 'development', 'phone-a');
reset role;

select pg_temp.eq('re-register is idempotent (one org_update row)',
  (select count(*) from public.live_activity_tokens where token = repeat('b', 64))::text, '1');
select pg_temp.eq('org_update keeps its event',
  (select event_id::text from public.live_activity_tokens where token = repeat('b', 64)), 'e0000000-0000-0000-0000-000000000001');
select pg_temp.eq('a new org_start retires the older one on that device',
  (select revoked_at is not null from public.live_activity_tokens where token = repeat('a', 64))::text, 'true');
select pg_temp.eq('the player start token is untouched by org_start',
  (select revoked_at is null from public.live_activity_tokens where token = repeat('c', 64))::text, 'true');

-- Dispatch ------------------------------------------------------------------------------------------
-- Only Alice's organizer tokens are left: Bea's update token goes, so a player can't be what triggers it.
update public.live_activity_tokens set revoked_at = now() where user_id <> :A;
update public.live_activity_tokens set revoked_at = now() where kind in ('start', 'update');
delete from net.requests;

-- Guests' match reported by the organizer: settles one of two.
update public.matches set status = 'reported', version = version + 1 where id = :M2;
select pg_temp.eq('an organizer-only event still dispatches',
  (select count(*) from net.requests where url like '%live-activity')::text, '1');
select pg_temp.eq('match dispatch says settled',
  (select (body->>'settled') || '/' || (body->>'disputed') from net.requests where url like '%live-activity'), 'true/false');

delete from net.requests;
update public.matches set status = 'reported', disputed = true, version = version + 1 where id = :M1;
select pg_temp.eq('a new dispute is flagged and settles nothing',
  (select (body->>'settled') || '/' || (body->>'disputed') from net.requests where url like '%live-activity'), 'false/true');

delete from net.requests;
update public.matches set status = 'confirmed', version = version + 1 where id = :M1;
select pg_temp.eq('deciding the dispute settles it',
  (select (body->>'settled') || '/' || (body->>'disputed') from net.requests where url like '%live-activity'), 'true/false');

-- No tokens at all: nothing goes out.
update public.live_activity_tokens set revoked_at = now();
delete from net.requests;
update public.matches set game_draws = 1, version = version + 1 where id = :M2;
select pg_temp.eq('no tokens, no dispatch',
  (select count(*) from net.requests where url like '%live-activity')::text, '0');
