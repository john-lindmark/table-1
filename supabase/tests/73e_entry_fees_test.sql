-- Entry fees and prizes (20261113160000_entry_fees.sql; contract/entry-fees-2026-11-13.md): the fee and who may set
-- it, the pool with the league's cut and the host's share, payments in the app as the payments function drives them,
-- door payments and comps, refunds, prizes and splits, league dues.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000076' || lower(c) || '1')::uuid, lower(replace(n, ' ', '')) || '@example.com', jsonb_build_object('full_name', n)
  from (values ('A', 'Ana Org'), ('B', 'Bea'), ('C', 'Cal'), ('D', 'Dee'), ('E', 'Eve'), ('F', 'Fay'), ('9', 'Hoi Host'), ('0', 'Sam Stranger')) x(c, n);
\set A '''00000000-0000-0000-0000-0000000076a1'''
\set B '''00000000-0000-0000-0000-0000000076b1'''
\set C '''00000000-0000-0000-0000-0000000076c1'''
\set D '''00000000-0000-0000-0000-0000000076d1'''
\set E '''00000000-0000-0000-0000-0000000076e1'''
\set F '''00000000-0000-0000-0000-0000000076f1'''
\set H '''00000000-0000-0000-0000-000000007691'''
\set S '''00000000-0000-0000-0000-000000007601'''
\set EV '''e0000000-0000-0000-0000-000000007601'''
\set EH '''e0000000-0000-0000-0000-000000007602'''
\set EX '''e0000000-0000-0000-0000-000000007603'''

insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, visibility, starts_at, format_name, format) values
  (:EV, 'FEEMOD', 'Modern Open', :A, 'setup', 0, 5, 'public', now() + interval '3 days', 'modern', 'constructed'),
  (:EH, 'FEEHOI', 'Hoi''s Sealed', :H, 'setup', 0, 3, 'link_only', now() + interval '3 days', 'sealed', 'sealed'),
  (:EX, 'FEEFRE', 'Free with prizes', :A, 'setup', 0, 3, 'link_only', null, 'modern', 'constructed');
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner'), (:EH, :H, 'owner'), (:EX, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat)
select md5('fe' || e.n || p.n)::uuid, e.id, p.uid, p.name, p.n
  from (values (:EV::uuid, 1), (:EH::uuid, 2)) e(id, n),
       (values (1, :B::uuid, 'Bea'), (2, :C::uuid, 'Cal'), (3, :D::uuid, 'Dee'), (4, :E::uuid, 'Eve'), (5, :F::uuid, 'Fay'), (6, null, 'Gus Guest')) p(n, uid, name);
insert into public.leagues (id, slug, name, created_by) values ('10000000-0000-0000-0000-000000007601', 'fee-series', 'Fee Series', :A);
insert into public.league_members (league_id, user_id, role) values ('10000000-0000-0000-0000-000000007601', :A, 'owner');
insert into public.league_seasons (id, league_id, name, starts_on, ends_on, points, entry_cut_cents)
values ('20000000-0000-0000-0000-000000007601', '10000000-0000-0000-0000-000000007601', '2026', current_date - 30, current_date + 300, '{"places": [], "participation": 1, "match_win": 0}', 700);
\set SE '''20000000-0000-0000-0000-000000007601'''
insert into public.league_events (event_id, season_id, league_id) values (:EV, :SE, '10000000-0000-0000-0000-000000007601');
insert into t1_private.stripe_accounts (user_id, account_id, charges_enabled, payouts_enabled, details_submitted) values (:A, 'acct_ANA', true, true, true);

create or replace function pg_temp.pid(p_event int, p_n int) returns uuid language sql immutable as $$ select md5('fe' || p_event || p_n)::uuid $$;
create or replace function pg_temp.pool(p_event uuid) returns text language sql security definer as $$
  select x.entries || ' ' || x.gross_cents || ' ' || x.league_cut_cents || ' ' || x.host_keep_cents || ' ' || x.added_cents || ' ' || x.pool_cents from t1_private.event_pool(p_event) x $$;
create or replace function pg_temp.svc(p_sql text) returns jsonb language plpgsql security definer as $$
declare v jsonb; begin execute p_sql into v; return v; end $$;
grant execute on function pg_temp.pid(int, int), pg_temp.pool(uuid), pg_temp.svc(text) to anon, authenticated;

-- ==================================================================== setting the fee
set role authenticated;
select pg_temp.as_user(:S);
select pg_temp.throws('a stranger can''t set a fee', format('select public.event_fee_set(%L, %L)', :EV, '{"amount_cents": 2500}'), '42501');
select pg_temp.as_user(:H);
select pg_temp.throws('paying in the app needs Stripe connected', format('select public.event_fee_set(%L, %L)', :EH, '{"amount_cents": 1500, "pay_mode": "either"}'), '55000');
select pg_temp.eq('at the door needs nothing', public.event_fee_set(:EH, '{"amount_cents": 1500, "pay_mode": "door", "payout": [{"through": 1, "percent": 100}]}')->'fee'->>'pay_mode', 'door');
select pg_temp.eq('Hoi''s own connection reads not connected', public.payments_account()->>'connected', 'false');
select pg_temp.as_user(:A);
select pg_temp.eq('Ana''s reads ready', (select (v->>'connected') || (v->>'ready') from public.payments_account() v), 'truetrue');
select pg_temp.throws('under 50 cents is refused', format('select public.event_fee_set(%L, %L)', :EV, '{"amount_cents": 20}'), '22023');
select pg_temp.throws('prizes can''t pass the pool', format('select public.event_fee_set(%L, %L)', :EV, '{"amount_cents": 2500, "payout": [{"through": 1, "percent": 60}, {"through": 3, "percent": 25}]}'), '22023');
select pg_temp.throws('the host keeps at most all of it', format('select public.event_fee_set(%L, %L)', :EV, '{"amount_cents": 2500, "host_keep": {"kind": "percent", "value": 120}}'), '22023');
select pg_temp.eq('$25, either way, refunds until a day before, the host keeps 10%, top two paid; the league''s $7 comes from the season',
  (public.event_fee_set(:EV, '{"amount_cents": 2500, "pay_mode": "either", "refund_hours": 24, "host_keep": {"kind": "percent", "value": 10},
                               "payout": [{"through": 1, "percent": 60}, {"through": 2, "percent": 40}]}')->'fee')::text,
  '{"payout": [{"percent": 60, "through": 1}, {"percent": 40, "through": 2}], "currency": "usd", "pay_mode": "either", "host_keep": {"kind": "percent", "value": 10}, "added_cents": 0, "amount_cents": 2500, "refund_hours": 24, "league_cut_cents": 700}');

set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('anyone who can open the event sees the fee and an empty pool',
  (select (v->'fee'->>'amount_cents') || ' ' || (v->>'app_ready') || ' ' || (v->'pool'->>'pool_cents') || ' ' || coalesce(v->>'me', 'no me') || ' ' || coalesce(v->>'organizer', 'no organizer') from public.event_money(:EV) v),
  '2500 true 0 no me no organizer');
select pg_temp.throws('anon can''t set fees', format('select public.event_fee_set(%L, null)', :EV), '42501');
select pg_temp.throws('anon reads no payments', 'select count(*) from public.event_payments', '42501');
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('a signed-up player is unpaid and can pay in the app', (select (v->'me'->>'status') || ' ' || (v->'me'->>'can_pay') || ' ' || (v->'me'->>'can_refund') from public.event_money(:EV) v), 'unpaid true false');
select pg_temp.throws('clients can''t reach the payment functions', format('select public.payment_begin(%L, %L)', :EV, :B), '42501');
select pg_temp.throws('or settle one', $$select public.payment_settle('cs_x', 'pi_x', 'paid')$$, '42501');

-- ==================================================================== paying in the app (as the payments function)
reset role;
select pg_temp.eq('begin: what to charge, on the host''s account',
  (select (v->>'amount_cents') || ' ' || (v->>'account_id') || ' ' || (v->>'event_name') || ' ' || (v->>'fee_cents') from public.payment_begin(:EV, :B) v), '2500 acct_ANA Modern Open 0');
select (public.payment_begin(:EV, :B)->>'payment_id') as "PB" \gset
select public.payment_session_put(:'PB', 'cs_bea_1', 'https://checkout.stripe.test/bea1', now() + interval '30 minutes');
select pg_temp.eq('an open checkout is handed back, not doubled', (select (v->>'payment_id' = :'PB')::text || ' ' || (v->>'reuse_url') from public.payment_begin(:EV, :B) v), 'true https://checkout.stripe.test/bea1');
select pg_temp.throws('someone not signed up can''t pay', format('select public.payment_begin(%L, %L)', :EV, :S), '22023');
select pg_temp.throws('a door-only event takes no app payments', format('select public.payment_begin(%L, %L)', :EH, :B), '22023');
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('while checkout is open the player reads pending', public.event_money(:EV)->'me'->>'status', 'pending');
reset role;
select pg_temp.eq('Stripe says paid', public.payment_settle('cs_bea_1', 'pi_bea_1', 'paid')->>'status', 'paid');
select pg_temp.eq('hearing it twice changes nothing', public.payment_settle('cs_bea_1', 'pi_bea_1', 'paid')->>'status', 'paid');
select pg_temp.eq('an unknown session is ignored', public.payment_settle('cs_nope', 'pi_nope', 'paid')->>'known', 'false');
select pg_temp.eq('pool: one entry, less the league''s $7 and the host''s 10% of the rest', pg_temp.pool(:EV), '1 2500 700 180 0 1620');
select pg_temp.throws('a paid player can''t pay again', format('select public.payment_begin(%L, %L)', :EV, :B), '22023');

-- A checkout that lapses, and one paid after a newer one was opened.
select (public.payment_begin(:EV, :C)->>'payment_id') as "PC" \gset
select public.payment_session_put(:'PC', 'cs_cal_1', 'https://checkout.stripe.test/cal1', now() + interval '30 minutes');
select pg_temp.eq('an expired checkout leaves the player unpaid', public.payment_settle('cs_cal_1', null, 'expired')->>'status', 'expired');
select (public.payment_begin(:EV, :F)->>'payment_id') as "PF1" \gset
select public.payment_session_put(:'PF1', 'cs_fay_1', 'https://checkout.stripe.test/fay1', now() + interval '1 minute');
select (public.payment_begin(:EV, :F)->>'payment_id') as "PF2" \gset
select pg_temp.eq('a checkout about to lapse is replaced', (:'PF1' <> :'PF2')::text, 'true');
select public.payment_session_put(:'PF2', 'cs_fay_2', 'https://checkout.stripe.test/fay2', now() + interval '30 minutes');
select pg_temp.eq('the old one paid late while a new one is open: flagged to refund, with where',
  (select (v->>'duplicate') || ' ' || (v->>'payment_intent') || ' ' || (v->>'account_id') from public.payment_settle('cs_fay_1', 'pi_fay_1', 'paid') v), 'true pi_fay_1 acct_ANA');
select pg_temp.eq('the new one pays', public.payment_settle('cs_fay_2', 'pi_fay_2', 'paid')->>'status', 'paid');

-- ==================================================================== door, comp, unpaid
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.throws('players can''t mark payments', format('select public.event_payment_mark(%L, %L, %L)', :EV, pg_temp.pid(1, 2), 'door'), '42501');
select pg_temp.as_user(:A);
select pg_temp.eq('Cal pays at the door', (select (v->>'status') || ' ' || (v->>'method') || ' ' || (v->>'amount_cents') from public.event_payment_mark(:EV, pg_temp.pid(1, 2), 'door') v), 'paid door 2500');
select pg_temp.eq('Dee plays free', (select (v->>'status') || ' ' || (v->>'method') || ' ' || (v->>'amount_cents') from public.event_payment_mark(:EV, pg_temp.pid(1, 3), 'comp') v), 'paid comp 0');
select pg_temp.eq('the guest pays at the door too', public.event_payment_mark(:EV, pg_temp.pid(1, 6), 'door')->>'status', 'paid');
select pg_temp.eq('and is unmarked again', public.event_payment_mark(:EV, pg_temp.pid(1, 6), 'unpaid')->>'status', 'unpaid');
select pg_temp.throws('an app payment is changed only by a refund', format('select public.event_payment_mark(%L, %L, %L)', :EV, pg_temp.pid(1, 1), 'unpaid'), '22023');
select pg_temp.eq('pool: three paid entries (comps pay nothing and owe the league nothing)', pg_temp.pool(:EV), '3 7500 2100 540 0 4860');
select pg_temp.eq('the organizer sees everyone''s payment and who is unpaid',
  (select (select string_agg((p->>'name') || ' ' || (p->>'status') || coalesce(' ' || (p->>'method'), ''), ', ') from jsonb_array_elements(v->'organizer'->'players') p) || ' | ' || (v->'organizer'->>'unpaid') || ' | ' || (v->'organizer'->'stripe'->>'ready')
     from public.event_money(:EV) v),
  'Bea paid app, Cal paid door, Dee paid comp, Eve unpaid, Fay paid app, Gus Guest unpaid | 2 | true');
select pg_temp.throws('the amount is locked once entries are paid', format('select public.event_fee_set(%L, %L)', :EV, '{"amount_cents": 3000}'), '22023');
select pg_temp.throws('and the fee can''t be removed', format('select public.event_fee_set(%L, null)', :EV), '22023');
select pg_temp.eq('prize money can be added', public.event_fee_set(:EV, '{"added_cents": 1000}')->'fee'->>'added_cents', '1000');
select pg_temp.eq('it goes straight to the pool', pg_temp.pool(:EV), '3 7500 2100 540 1000 5860');

-- ==================================================================== refunds
select pg_temp.as_user(:B);
select pg_temp.eq('inside the window a player can take their own refund', public.event_money(:EV)->'me'->>'can_refund', 'true');
reset role;
select pg_temp.eq('the player asks: their own app payment', (select (v->>'payment_intent') || ' ' || (v->>'by_organizer') from public.payment_refund_begin(:EV, null, :B) v), 'pi_bea_1 false');
select pg_temp.throws('a door payment has nothing to refund in the app', format('select public.payment_refund_begin(%L, null, %L)', :EV, :C), 'P0002');
select pg_temp.throws('nobody refunds someone else', format('select public.payment_refund_begin(%L, %L, %L)', :EV, pg_temp.pid(1, 1), :C), '42501');
update public.events set starts_at = now() + interval '2 hours' where id = :EV;
select pg_temp.throws('after the window it''s the organizer''s call', format('select public.payment_refund_begin(%L, null, %L)', :EV, :B), '55000');
select pg_temp.eq('the organizer can always refund', public.payment_refund_begin(:EV, pg_temp.pid(1, 1), :A)->>'by_organizer', 'true');
select pg_temp.eq('refunded', public.payment_refunded('pi_bea_1', 're_bea_1', :A)->>'known', 'true');
select pg_temp.eq('hearing the refund twice is harmless', public.payment_refunded('pi_bea_1', 're_bea_1', :A)->>'known', 'false');
select pg_temp.eq('the pool gives it back', pg_temp.pool(:EV), '2 5000 1400 360 1000 4240');
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('the player reads refunded and may pay again', (select (v->'me'->>'status') || ' ' || (v->'me'->>'can_pay') from public.event_money(:EV) v), 'refunded true');

-- ==================================================================== prizes
select pg_temp.as_user(:A);
select pg_temp.throws('no prizes before the places are in', format('select public.event_prizes_set(%L, null)', :EV), '22023');
reset role;
update public.events set status = 'completed' where id = :EV;
insert into public.event_placements (event_id, participant_id, user_id, name, place)
select :EV, pg_temp.pid(1, n), u, name, place from (values (2, :C::uuid, 'Cal', 1), (5, :F::uuid, 'Fay', 2), (3, :D::uuid, 'Dee', 3), (1, :B::uuid, 'Bea', 4)) x(n, u, name, place);
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('prizes by place: 60% and 40% of the pool, names only signed out',
  (select string_agg((p->>'place') || ' ' || (p->>'name') || ' ' || (p->>'amount_cents') || ' ' || (p->>'paid') || coalesce(' ' || (p->>'user_id'), ''), ', ') from jsonb_array_elements(public.event_money(:EV)->'prizes') p),
  '1 Cal 2544 false, 2 Fay 1696 false');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('the finalists agree an even split',
  public.event_prizes_set(:EV, jsonb_build_array(jsonb_build_object('participant_id', pg_temp.pid(1, 2), 'amount_cents', 2120),
                                                 jsonb_build_object('participant_id', pg_temp.pid(1, 5), 'amount_cents', 2120)))::text,
  '{"pool_cents": 4240, "total_cents": 4240}');
select pg_temp.throws('a split can''t pass the pool', format('select public.event_prizes_set(%L, %L)', :EV,
  jsonb_build_array(jsonb_build_object('participant_id', pg_temp.pid(1, 2), 'amount_cents', 4000), jsonb_build_object('participant_id', pg_temp.pid(1, 5), 'amount_cents', 2120))::text), '22023');
select pg_temp.eq('the refused split changed nothing', (public.event_money(:EV)->'prizes'->0->>'amount_cents'), '2120');
select pg_temp.eq('paid in cash', public.event_prize_mark(:EV, pg_temp.pid(1, 2), true, 'Cash')->>'paid', 'true');
select pg_temp.eq('everyone sees it''s settled', (select (p->>'paid') || ' ' || (p->>'paid_how') || ' ' || (p->>'custom') from jsonb_array_elements(public.event_money(:EV)->'prizes') p where p->>'name' = 'Cal'), 'true Cash true');
select pg_temp.eq('back to the table', (public.event_prizes_set(:EV, null)->>'total_cents'), '4240');
select pg_temp.as_user(:C);
select pg_temp.throws('players don''t mark prizes', format('select public.event_prize_mark(%L, %L, true)', :EV, pg_temp.pid(1, 2)), '42501');

-- A team's prize is split among its members; a free event's prizes come from added money.
select pg_temp.as_user(:H);
select pg_temp.eq('two door entries at Hoi''s', (public.event_payment_mark(:EH, pg_temp.pid(2, 1), 'door')->>'status') || (public.event_payment_mark(:EH, pg_temp.pid(2, 2), 'door')->>'status'), 'paidpaid');
reset role;
insert into public.event_placements (event_id, participant_id, user_id, name, place) values
  (:EH, pg_temp.pid(2, 1), :B, 'Bea', 1), (:EH, pg_temp.pid(2, 2), :C, 'Cal', 1), (:EH, pg_temp.pid(2, 3), :D, 'Dee', 2);
select pg_temp.eq('two players sharing first share its prize; no league, no host share', (select string_agg(r.name || ' ' || r.amount_cents, ', ' order by r.name) from t1_private.event_prize_rows(:EH) r where r.amount_cents > 0), 'Bea 1500, Cal 1500');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('a free event with a $100 prize pool',
  (select (v->'fee'->>'amount_cents') || ' ' || (v->'fee'->>'pay_mode') from public.event_fee_set(:EX, '{"amount_cents": 0, "pay_mode": "app", "added_cents": 10000, "payout": [{"through": 1, "percent": 100}]}') v), '0 door');
select pg_temp.eq('its pool is the added money', pg_temp.pool(:EX), '0 0 0 0 10000 10000');
select pg_temp.eq('a fee with nobody paid can be removed', public.event_fee_set(:EX, null)::text, '{"fee": null}');
select pg_temp.eq('and then there''s nothing to show', public.event_money(:EX)::text, '{"fee": null}');

-- ==================================================================== league dues
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('everyone sees the season''s pool: $7 from each paid entry', (select (v->>'entry_cut_cents') || ' ' || (v->>'pool_cents') || ' ' || coalesce(v->>'events', 'no detail') from public.league_money(:SE) v), '700 1400 no detail');
set role authenticated;
select pg_temp.as_user(:S);
select pg_temp.throws('a stranger can''t mark dues', format('select public.league_due_mark(%L, 1400)', :EV), '42501');
select pg_temp.as_user(:A);
select pg_temp.eq('the league sees what each event owes', (public.league_money(:SE)->'events')::text, '[{"name": "Modern Open", "entries": 2, "event_id": "e0000000-0000-0000-0000-000000007601", "owed_cents": 1400, "received_cents": 0}]');
select pg_temp.eq('and marks it received', public.league_due_mark(:EV, 1400)->>'received_cents', '1400');
select pg_temp.eq('the tally follows', public.league_money(:SE)->>'received_cents', '1400');

-- ==================================================================== the host's Stripe account
reset role;
select pg_temp.eq('a new host account is stored', public.stripe_account_put(:H, 'acct_HOI')->>'charges_enabled', 'false');
select pg_temp.eq('Stripe says it can take payments (found by account id)', public.stripe_account_put(null, 'acct_HOI', '{"charges_enabled": true, "details_submitted": true}')->>'charges_enabled', 'true');
select pg_temp.throws('only real account ids', $$select public.stripe_account_put(null, 'not an id')$$, '22023');
set role authenticated;
select pg_temp.as_user(:H);
select pg_temp.eq('now Hoi can take payments in the app', public.event_fee_set(:EH, '{"pay_mode": "either"}')->'fee'->>'pay_mode', 'either');
reset role;
select public.stripe_account_gone('acct_HOI');
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('a host who disconnects: the app option goes quiet', (select (v->>'app_ready') || ' ' || coalesce(v->'me'->>'can_pay', '-') from public.event_money(:EH) v), 'false false');
reset role;
select pg_temp.eq('a Stripe event counts once', public.stripe_event_seen('evt_1')::text || public.stripe_event_seen('evt_1')::text, 'truefalse');
select pg_temp.eq('everything is audited', (select string_agg(action, ',' order by action) from (select distinct action from public.audit_log where event_id = :EV and (action like 'fee.%' or action like 'pay%' or action like 'prize%')) x),
  'fee.set,payment.marked,payment.paid,payment.refunded,prize.marked,prizes.set');
