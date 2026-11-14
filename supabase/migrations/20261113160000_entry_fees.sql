-- Entry fees and prizes (contract/entry-fees-2026-11-13.md; plan § Phase 3; Stripe facts in
-- table-1-context/docs/stripe-connect-notes-2026-11-13.md). John's picks, 2026-11-13: pay in the app through Stripe's
-- hosted checkout or at the door; the host is the seller and Table 1 never holds money; the app works out prizes and
-- the host pays them; a league's cut of each entry is a tally of what hosts owe, not a transfer.
--
--   a  tables: a host's Stripe account, an event's fee, payments, prize marks, league dues, seen Stripe events
--   b  the fee: event_fee_set
--   c  the money: pool, prizes, event_money
--   d  organizer marks: door payments, comps, agreed splits, prizes paid
--   e  league dues
--   f  what the payments edge function calls (service role)
--   g  grants
--
-- Amounts are whole cents. Nothing here moves money: Stripe does, on the host's own account.

-- ==================================================================== a_tables
create table if not exists t1_private.stripe_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  account_id text not null unique,
  charges_enabled boolean not null default false,
  payouts_enabled boolean not null default false,
  details_submitted boolean not null default false,
  disabled_reason text,
  livemode boolean not null default false,
  created_at timestamptz not null default now(),
  checked_at timestamptz
);
alter table t1_private.stripe_accounts enable row level security;

-- payout: [{"through": 1, "percent": 40}, {"through": 2, "percent": 25}, {"through": 4, "percent": 17.5}]: each place
-- up to `through` takes `percent` of the pool. host_keep: what the host keeps before prizes (none | flat cents |
-- percent). added_cents: prize money put in from outside the entries (a sponsor, a league's pool).
create table if not exists public.event_fees (
  event_id uuid primary key references public.events (id) on delete cascade,
  amount_cents integer not null check (amount_cents = 0 or amount_cents between 50 and 100000),
  currency text not null default 'usd' check (currency = 'usd'),
  pay_mode text not null default 'door' check (pay_mode in ('door', 'app', 'either')),
  refund_hours integer check (refund_hours is null or refund_hours between 0 and 720),
  host_keep_kind text not null default 'none' check (host_keep_kind in ('none', 'flat', 'percent')),
  host_keep_value integer not null default 0 check (host_keep_value >= 0),
  added_cents integer not null default 0 check (added_cents between 0 and 10000000),
  payout jsonb not null default '[]'::jsonb,
  stripe_user uuid,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  check (host_keep_kind <> 'percent' or host_keep_value <= 100),
  check (amount_cents > 0 or pay_mode = 'door')
);

create table if not exists public.event_payments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  participant_id uuid references public.participants (id) on delete set null,
  user_id uuid,
  payer_name text not null,
  amount_cents integer not null check (amount_cents >= 0),
  currency text not null default 'usd',
  method text not null check (method in ('app', 'door', 'comp')),
  status text not null check (status in ('pending', 'paid', 'refunded', 'failed', 'expired')),
  stripe_account text,
  session_id text unique,
  session_url text,
  session_expires_at timestamptz,
  payment_intent text,
  refund_id text,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  refunded_at timestamptz,
  marked_by uuid
);
create unique index if not exists event_payments_live_idx on public.event_payments (participant_id)
  where status in ('pending', 'paid') and participant_id is not null;
create index if not exists event_payments_event_idx on public.event_payments (event_id);
create index if not exists event_payments_intent_idx on public.event_payments (payment_intent) where payment_intent is not null;

-- A prize as the organizer changed or settled it: amount_cents null = the table's amount.
create table if not exists public.event_prizes (
  event_id uuid not null references public.events (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  amount_cents integer check (amount_cents is null or amount_cents >= 0),
  paid_at timestamptz,
  paid_how text check (paid_how is null or char_length(paid_how) between 1 and 40),
  marked_by uuid,
  primary key (event_id, participant_id)
);

-- What a league says it has received from an event's host toward the event's dues.
create table if not exists public.league_dues (
  event_id uuid primary key references public.events (id) on delete cascade,
  received_cents integer not null default 0 check (received_cents >= 0),
  received_at timestamptz,
  marked_by uuid
);

-- Payments are hidden for now (John, 2026-11-14: "make sure the payments content is hidden for now"): entry fees and
-- Stripe are open only to the accounts listed here until `payments.open` is set to '1' in t1_private.settings.
create table if not exists t1_private.payment_testers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table t1_private.payment_testers enable row level security;

create or replace function t1_private.payments_open_for(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select s.value = '1' from t1_private.settings s where s.name = 'payments.open'), false)
      or exists (select 1 from t1_private.payment_testers t where t.user_id = p_user_id);
$$;

create table if not exists t1_private.stripe_events (
  id text primary key,
  at timestamptz not null default now()
);
alter table t1_private.stripe_events enable row level security;

-- ==================================================================== b_fee
create or replace function t1_private.payout_clean(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare b jsonb; v_last integer := 0; v_through integer; v_pct numeric; v_total numeric := 0; v_out jsonb := '[]'::jsonb;
begin
  if p is null or jsonb_typeof(p) = 'null' then return '[]'::jsonb; end if;
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 16 then raise exception 'Up to 16 prize brackets' using errcode = '22023'; end if;
  for b in select * from jsonb_array_elements(p) loop
    v_through := (b->>'through')::integer; v_pct := trim_scale(round((b->>'percent')::numeric, 2));
    if v_through is null or v_pct is null or v_through <= v_last or v_through > 64 or v_pct <= 0 or v_pct > 100 then
      raise exception 'Prize brackets go up, each with a share of the pool' using errcode = '22023';
    end if;
    v_total := v_total + v_pct * (v_through - v_last);
    v_last := v_through;
    v_out := v_out || jsonb_build_object('through', v_through, 'percent', v_pct);
  end loop;
  if v_total > 100 then raise exception 'The prizes add up to more than the pool' using errcode = '22023'; end if;
  return v_out;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Prize shares are numbers' using errcode = '22023';
end $$;

-- What each paid entry of this event owes its league: the season's cut, for season events that aren't the final,
-- never more than the entry itself.
create or replace function t1_private.event_cut(p_event_id uuid, p_amount_cents integer)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select least(coalesce(s.entry_cut_cents, 0), p_amount_cents)
                     from public.league_events le join public.league_seasons s on s.id = le.season_id
                    where le.event_id = p_event_id and not le.final), 0);
$$;

create or replace function t1_private.fee_json(f public.event_fees)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'amount_cents', f.amount_cents, 'currency', f.currency, 'pay_mode', f.pay_mode, 'refund_hours', f.refund_hours,
    'host_keep', jsonb_build_object('kind', f.host_keep_kind, 'value', f.host_keep_value),
    'added_cents', f.added_cents, 'payout', f.payout,
    'league_cut_cents', t1_private.event_cut(f.event_id, f.amount_cents));
$$;

-- Set, change or remove (p_fee null) an event's entry fee. Keys: amount_cents (0 = free with prizes), pay_mode
-- (door | app | either), refund_hours (a player's own full refund until this many hours before the start; null = ask
-- the organizer), host_keep {kind, value}, added_cents, payout. Paying in the app needs the caller's Stripe account
-- ready to take payments. The amount locks once anyone has paid.
create or replace function public.event_fee_set(p_event_id uuid, p_fee jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  f public.event_fees;
  n public.event_fees;
  v_paid boolean;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null or not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can set the entry fee' using errcode = '42501';
  end if;
  if e.is_demo then raise exception 'Demo events have no fees' using errcode = '22023'; end if;
  if not t1_private.payments_open_for(v_uid) then
    raise exception 'Entry fees aren''t available yet' using errcode = '42501';
  end if;
  select * into f from public.event_fees where event_id = p_event_id;
  v_paid := exists (select 1 from public.event_payments p where p.event_id = p_event_id and p.status in ('pending', 'paid') and p.method <> 'comp');
  if p_fee is null or jsonb_typeof(p_fee) = 'null' then
    if v_paid then raise exception 'Entries are paid: refund them before removing the fee' using errcode = '22023'; end if;
    delete from public.event_fees where event_id = p_event_id;
    if f.event_id is not null then
      insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
      values (p_event_id, v_uid, 'fee.removed', 'event', p_event_id, t1_private.fee_json(f));
    end if;
    return jsonb_build_object('fee', null);
  end if;
  if jsonb_typeof(p_fee) <> 'object' then raise exception 'Say what the fee is' using errcode = '22023'; end if;
  n := f;
  if n.event_id is null then
    n.event_id := p_event_id; n.currency := 'usd'; n.pay_mode := 'door'; n.host_keep_kind := 'none'; n.host_keep_value := 0;
    n.added_cents := 0; n.payout := '[]'::jsonb;
  end if;
  begin
    if p_fee ? 'amount_cents' then n.amount_cents := (p_fee->>'amount_cents')::integer; end if;
    if p_fee ? 'pay_mode' then n.pay_mode := p_fee->>'pay_mode'; end if;
    if p_fee ? 'refund_hours' then n.refund_hours := (p_fee->>'refund_hours')::integer; end if;
    if p_fee ? 'added_cents' then n.added_cents := coalesce((p_fee->>'added_cents')::integer, 0); end if;
    if p_fee ? 'host_keep' then
      n.host_keep_kind := coalesce(p_fee->'host_keep'->>'kind', 'none');
      n.host_keep_value := coalesce((p_fee->'host_keep'->>'value')::integer, 0);
    end if;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Amounts are whole cents' using errcode = '22023';
  end;
  if p_fee ? 'payout' then n.payout := t1_private.payout_clean(p_fee->'payout'); end if;
  if n.amount_cents is null or not (n.amount_cents = 0 or n.amount_cents between 50 and 100000) then
    raise exception 'An entry fee is $0.50 to $1,000, or 0 for a free event with prizes' using errcode = '22023';
  end if;
  if n.pay_mode is null or n.pay_mode not in ('door', 'app', 'either') then
    raise exception 'Pay at the door, in the app, or either' using errcode = '22023';
  end if;
  if n.amount_cents = 0 then n.pay_mode := 'door'; end if;
  if n.refund_hours is not null and n.refund_hours not between 0 and 720 then
    raise exception 'Refunds close 0 to 720 hours before the start' using errcode = '22023';
  end if;
  if n.host_keep_kind not in ('none', 'flat', 'percent') or n.host_keep_value < 0
     or (n.host_keep_kind = 'percent' and n.host_keep_value > 100) then
    raise exception 'The host keeps nothing, an amount, or a percent up to 100' using errcode = '22023';
  end if;
  if n.host_keep_kind = 'none' then n.host_keep_value := 0; end if;
  if n.added_cents not between 0 and 10000000 then raise exception 'Added prize money is 0 to $100,000' using errcode = '22023'; end if;
  if v_paid and f.event_id is not null and n.amount_cents <> f.amount_cents then
    raise exception 'Entries are paid: the amount is locked' using errcode = '22023';
  end if;
  if n.pay_mode in ('app', 'either') then
    if not exists (select 1 from t1_private.stripe_accounts a where a.user_id = coalesce(f.stripe_user, v_uid) and a.charges_enabled)
       and not exists (select 1 from t1_private.stripe_accounts a where a.user_id = v_uid and a.charges_enabled) then
      raise exception 'Connect Stripe before taking payments in the app' using errcode = '55000';
    end if;
    n.stripe_user := case when exists (select 1 from t1_private.stripe_accounts a where a.user_id = v_uid and a.charges_enabled)
                          then v_uid else f.stripe_user end;
  else
    n.stripe_user := null;
  end if;
  insert into public.event_fees (event_id, amount_cents, currency, pay_mode, refund_hours, host_keep_kind, host_keep_value,
                                 added_cents, payout, stripe_user, updated_by)
  values (p_event_id, n.amount_cents, 'usd', n.pay_mode, n.refund_hours, n.host_keep_kind, n.host_keep_value,
          n.added_cents, n.payout, n.stripe_user, v_uid)
  on conflict (event_id) do update
    set amount_cents = excluded.amount_cents, pay_mode = excluded.pay_mode, refund_hours = excluded.refund_hours,
        host_keep_kind = excluded.host_keep_kind, host_keep_value = excluded.host_keep_value,
        added_cents = excluded.added_cents, payout = excluded.payout, stripe_user = excluded.stripe_user,
        updated_by = v_uid, updated_at = now()
  returning * into n;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (p_event_id, v_uid, 'fee.set', 'event', p_event_id,
          case when f.event_id is not null then t1_private.fee_json(f) end, t1_private.fee_json(n));
  return jsonb_build_object('fee', t1_private.fee_json(n));
end $$;

-- ==================================================================== c_money
-- The pool: paid entries (door and app; comps pay nothing) less the league's cut and what the host keeps, plus
-- money added from outside.
create or replace function t1_private.event_pool(p_event_id uuid)
returns table (entries integer, gross_cents integer, league_cut_cents integer, host_keep_cents integer,
               added_cents integer, pool_cents integer)
language sql stable security definer set search_path = '' as $$
  with f as (select * from public.event_fees where event_id = p_event_id),
  p as (select count(*) filter (where pay.method <> 'comp')::integer as n,
               coalesce(sum(pay.amount_cents), 0)::integer as gross
          from public.event_payments pay where pay.event_id = p_event_id and pay.status = 'paid'),
  c as (select p.n, p.gross, p.n * t1_private.event_cut(p_event_id, f.amount_cents) as cut, f.host_keep_kind as kind,
               f.host_keep_value as val, f.added_cents as added
          from f cross join p),
  k as (select c.*, case c.kind when 'flat' then least(c.val, c.gross - c.cut)
                               when 'percent' then floor((c.gross - c.cut) * c.val / 100.0)::integer else 0 end as keep
          from c)
  select k.n, k.gross, k.cut, k.keep, k.added, greatest(0, k.gross - k.cut - k.keep) + k.added from k;
$$;

-- Prizes by final place: each entrant (a player, or a team sharing its place) takes its bracket's share of the pool,
-- split evenly among a team's members; an organizer's own amount replaces the table's.
create or replace function t1_private.event_prize_rows(p_event_id uuid)
returns table (participant_id uuid, user_id uuid, name text, place integer, amount_cents integer, custom boolean,
               paid_at timestamptz, paid_how text)
language sql stable security definer set search_path = '' as $$
  with f as (select payout from public.event_fees where event_id = p_event_id),
  pool as (select pool_cents from t1_private.event_pool(p_event_id)),
  pl as (select x.*, count(*) over (partition by x.place) as share from public.event_placements x where x.event_id = p_event_id),
  calc as (
    select pl.participant_id, pl.user_id, pl.name, pl.place,
           floor(pool.pool_cents * coalesce((select (b->>'percent')::numeric from jsonb_array_elements(f.payout) b
                                              where (b->>'through')::integer >= pl.place
                                              order by (b->>'through')::integer limit 1), 0) / 100.0 / pl.share)::integer as amount
      from pl cross join f cross join pool)
  select c.participant_id, c.user_id, c.name, c.place, coalesce(z.amount_cents, c.amount), z.amount_cents is not null,
         z.paid_at, z.paid_how
    from calc c left join public.event_prizes z on z.event_id = p_event_id and z.participant_id = c.participant_id;
$$;

-- A player's payment state for an event: unpaid | pending | paid | refunded, with how.
create or replace function t1_private.payment_state(p_event_id uuid, p_participant_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((
    select jsonb_build_object('status', case when p.status in ('pending', 'paid', 'refunded') then p.status else 'unpaid' end,
                              'method', p.method, 'amount_cents', p.amount_cents)
      from public.event_payments p
     where p.event_id = p_event_id and p.participant_id = p_participant_id
     order by (p.status = 'paid') desc, (p.status = 'pending') desc, p.created_at desc limit 1),
    jsonb_build_object('status', 'unpaid', 'method', null, 'amount_cents', 0));
$$;

-- An event's money for whoever can open it: the fee, the pool as it stands, your own payment, prizes once the places
-- are in, and for organizers every player's payment and whether Stripe is ready.
create or replace function public.event_money(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_access text := t1_private.event_access(p_event_id, p_token);
  e public.events;
  f public.event_fees;
  v_pid uuid;
  v_me jsonb;
  v_ready boolean;
begin
  if v_access = 'none' then raise exception 'That event isn''t available' using errcode = '42501'; end if;
  select * into e from public.events where id = p_event_id;
  select * into f from public.event_fees where event_id = p_event_id;
  if f.event_id is null then return jsonb_build_object('fee', null); end if;
  v_ready := f.pay_mode in ('app', 'either') and exists (
    select 1 from t1_private.stripe_accounts a where a.user_id = f.stripe_user and a.charges_enabled);
  if v_uid is not null then
    select p.id into v_pid from public.participants p where p.event_id = p_event_id and p.user_id = v_uid order by p.created_at limit 1;
  end if;
  if v_pid is not null then
    v_me := t1_private.payment_state(p_event_id, v_pid);
    v_me := v_me || jsonb_build_object(
      'participant_id', v_pid,
      'can_pay', f.amount_cents > 0 and v_ready and v_me->>'status' in ('unpaid', 'pending', 'refunded')
                 and e.status not in ('completed', 'archived', 'cancelled'),
      'can_refund', v_me->>'status' = 'paid' and v_me->>'method' = 'app' and f.refund_hours is not null
                    and t1_private.sign_up_open(e)
                    and (e.starts_at is null or now() < e.starts_at - make_interval(hours => f.refund_hours)));
  end if;
  return jsonb_build_object(
    'fee', t1_private.fee_json(f),
    'app_ready', v_ready,
    'pool', (select to_jsonb(x) from t1_private.event_pool(p_event_id) x),
    'me', v_me,
    'prizes', coalesce((
      select jsonb_agg(jsonb_build_object('participant_id', r.participant_id, 'user_id', case when v_uid is not null then r.user_id end,
                                          'name', r.name, 'place', r.place, 'amount_cents', r.amount_cents,
                                          'custom', r.custom, 'paid', r.paid_at is not null, 'paid_how', r.paid_how)
                       order by r.place, lower(r.name))
        from t1_private.event_prize_rows(p_event_id) r where r.amount_cents > 0 or r.custom), '[]'::jsonb),
    'organizer', case when v_access = 'organizer' then jsonb_build_object(
      'stripe', (select jsonb_build_object('connected', a.user_id is not null, 'ready', coalesce(a.charges_enabled, false))
                   from (select 1) one left join t1_private.stripe_accounts a on a.user_id = v_uid),
      'players', coalesce((
        select jsonb_agg(t1_private.payment_state(p_event_id, p.id)
                         || jsonb_build_object('participant_id', p.id, 'user_id', p.user_id, 'name', p.display_name)
                         order by p.seat nulls last, lower(p.display_name))
          from public.participants p where p.event_id = p_event_id), '[]'::jsonb),
      'unpaid', (select count(*) from public.participants p
                  where p.event_id = p_event_id and p.status = 'active'
                    and t1_private.payment_state(p_event_id, p.id)->>'status' <> 'paid')::integer) end);
end $$;

-- ==================================================================== d_marks
-- The organizer marks a player paid at the door, comped (plays free), or unpaid again. Payments made in the app
-- are changed only by a refund.
create or replace function public.event_payment_mark(p_event_id uuid, p_participant_id uuid, p_state text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); f public.event_fees; p public.participants;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then raise exception 'Only organizers can mark payments' using errcode = '42501'; end if;
  if p_state is null or p_state not in ('door', 'comp', 'unpaid') then raise exception 'Mark door, comp or unpaid' using errcode = '22023'; end if;
  select * into f from public.event_fees where event_id = p_event_id;
  if f.event_id is null or f.amount_cents = 0 then raise exception 'This event has no entry fee' using errcode = '22023'; end if;
  select * into p from public.participants where id = p_participant_id and event_id = p_event_id;
  if p.id is null then raise exception 'That player isn''t in this event' using errcode = 'P0002'; end if;
  if exists (select 1 from public.event_payments x where x.participant_id = p.id and x.method = 'app' and x.status = 'paid') then
    raise exception 'They paid in the app: refund it instead' using errcode = '22023';
  end if;
  delete from public.event_payments where participant_id = p.id and status in ('pending', 'paid') and method in ('door', 'comp');
  update public.event_payments set status = 'expired' where participant_id = p.id and status = 'pending';
  if p_state <> 'unpaid' then
    insert into public.event_payments (event_id, participant_id, user_id, payer_name, amount_cents, method, status, paid_at, marked_by)
    values (p_event_id, p.id, p.user_id, p.display_name, case when p_state = 'door' then f.amount_cents else 0 end,
            p_state, 'paid', now(), v_uid);
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, v_uid, 'payment.marked', 'participant', p.id, jsonb_build_object('state', p_state));
  return t1_private.payment_state(p_event_id, p.id) || jsonb_build_object('participant_id', p.id);
end $$;

-- An agreed split or any other change to the prizes: [{participant_id, amount_cents}] replaces those players'
-- amounts; null goes back to the table. The total can't pass the pool.
create or replace function public.event_prizes_set(p_event_id uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_pool integer; v_total integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then raise exception 'Only organizers can change prizes' using errcode = '42501'; end if;
  if not exists (select 1 from public.event_placements where event_id = p_event_id) then
    raise exception 'Prizes are set once the final places are in' using errcode = '22023';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) = 'null' then
    update public.event_prizes set amount_cents = null where event_id = p_event_id;
  else
    if jsonb_typeof(p_rows) <> 'array' then raise exception 'Prizes are a list' using errcode = '22023'; end if;
    insert into public.event_prizes (event_id, participant_id, amount_cents, marked_by)
    select p_event_id, pl.participant_id, (r->>'amount_cents')::integer, v_uid
      from jsonb_array_elements(p_rows) r
      join public.event_placements pl on pl.event_id = p_event_id and pl.participant_id = (r->>'participant_id')::uuid
     where (r->>'amount_cents')::integer >= 0
    on conflict (event_id, participant_id) do update set amount_cents = excluded.amount_cents, marked_by = v_uid;
  end if;
  select pool_cents into v_pool from t1_private.event_pool(p_event_id);
  select coalesce(sum(amount_cents), 0) into v_total from t1_private.event_prize_rows(p_event_id);
  if v_total > coalesce(v_pool, 0) then
    raise exception 'The prizes add up to more than the pool' using errcode = '22023';
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, v_uid, 'prizes.set', 'event', p_event_id, p_rows);
  return jsonb_build_object('total_cents', v_total, 'pool_cents', v_pool);
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Amounts are whole cents' using errcode = '22023';
end $$;

-- A prize handed over (cash, store credit, …) or not yet.
create or replace function public.event_prize_mark(p_event_id uuid, p_participant_id uuid, p_paid boolean, p_how text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then raise exception 'Only organizers can mark prizes' using errcode = '42501'; end if;
  if not exists (select 1 from public.event_placements where event_id = p_event_id and participant_id = p_participant_id) then
    raise exception 'That player has no place in this event' using errcode = 'P0002';
  end if;
  insert into public.event_prizes (event_id, participant_id, paid_at, paid_how, marked_by)
  values (p_event_id, p_participant_id, case when p_paid then now() end,
          case when p_paid then nullif(left(btrim(coalesce(p_how, '')), 40), '') end, v_uid)
  on conflict (event_id, participant_id) do update
    set paid_at = excluded.paid_at, paid_how = excluded.paid_how, marked_by = v_uid;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, v_uid, 'prize.marked', 'participant', p_participant_id, jsonb_build_object('paid', coalesce(p_paid, false), 'how', p_how));
  return jsonb_build_object('participant_id', p_participant_id, 'paid', coalesce(p_paid, false));
end $$;

-- ==================================================================== e_league_dues
-- A season's prize pool from its cut of each paid entry. Everyone sees the pool; the league's organizers also see
-- what each event owes and what they've marked received.
create or replace function public.league_money(p_season_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); s public.league_seasons; l public.leagues; v_member boolean;
begin
  select * into s from public.league_seasons where id = p_season_id;
  select * into l from public.leagues where id = s.league_id;
  v_member := t1_private.league_role(l.id, v_uid) is not null;
  if l.id is null or ((l.archived_at is not null or (l.is_demo and l.created_by is distinct from v_uid)) and not v_member) then
    raise exception 'That league isn''t available' using errcode = 'P0002';
  end if;
  return (
    with ev as (
      select e.id, e.name, coalesce(e.starts_at, e.created_at) as at,
             (select x.entries from t1_private.event_pool(e.id) x) as entries,
             (select x.league_cut_cents from t1_private.event_pool(e.id) x) as owed,
             coalesce((select d.received_cents from public.league_dues d where d.event_id = e.id), 0) as received
        from public.league_events le join public.events e on e.id = le.event_id
       where le.season_id = p_season_id and not le.final and not e.is_demo and e.status <> 'cancelled')
    select jsonb_build_object(
      'entry_cut_cents', coalesce(s.entry_cut_cents, 0),
      'pool_cents', coalesce((select sum(coalesce(ev.owed, 0)) from ev), 0)::integer,
      'received_cents', case when v_member then coalesce((select sum(ev.received) from ev), 0)::integer end,
      'events', case when v_member then coalesce((
        select jsonb_agg(jsonb_build_object('event_id', ev.id, 'name', ev.name, 'entries', coalesce(ev.entries, 0),
                                            'owed_cents', coalesce(ev.owed, 0), 'received_cents', ev.received) order by ev.at, ev.id)
          from ev where coalesce(ev.owed, 0) > 0 or ev.received > 0), '[]'::jsonb) end));
end $$;

-- The league marks what it has received from an event's host.
create or replace function public.league_due_mark(p_event_id uuid, p_received_cents integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); le public.league_events;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into le from public.league_events where event_id = p_event_id;
  if le.event_id is null or t1_private.league_role(le.league_id, v_uid) is null then
    raise exception 'Only the league''s organizers can mark its dues' using errcode = '42501';
  end if;
  if p_received_cents is null or p_received_cents not between 0 and 100000000 then
    raise exception 'Say how much was received' using errcode = '22023';
  end if;
  insert into public.league_dues (event_id, received_cents, received_at, marked_by)
  values (p_event_id, p_received_cents, now(), v_uid)
  on conflict (event_id) do update set received_cents = excluded.received_cents, received_at = now(), marked_by = v_uid;
  insert into public.account_audit (actor, action, target_id, after)
  values (v_uid, 'league.due_marked', p_event_id, jsonb_build_object('received_cents', p_received_cents));
  return jsonb_build_object('event_id', p_event_id, 'received_cents', p_received_cents);
end $$;

-- Your own Stripe connection, as last heard from Stripe (the payments function refreshes it).
create or replace function public.payments_account()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object('connected', true, 'ready', a.charges_enabled, 'payouts', a.payouts_enabled,
                                              'details_submitted', a.details_submitted, 'disabled_reason', a.disabled_reason)
                     from t1_private.stripe_accounts a where a.user_id = auth.uid()),
                  jsonb_build_object('connected', false, 'ready', false, 'payouts', false, 'details_submitted', false,
                                     'disabled_reason', null))
         -- enabled: whether this account is shown payments at all (clients hide every payments screen without it).
         || jsonb_build_object('enabled', t1_private.payments_open_for(auth.uid()));
$$;

-- ==================================================================== f_service
-- Called by the payments edge function with the service role, never by clients.

create or replace function public.stripe_account_get(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select (select to_jsonb(a) from t1_private.stripe_accounts a where a.user_id = p_user_id);
$$;

-- Stores or refreshes a host's account. p_flags: {charges_enabled, payouts_enabled, details_submitted,
-- disabled_reason, livemode}. With p_user_id null the row is found by the account id (a webhook).
create or replace function public.stripe_account_put(p_user_id uuid, p_account_id text, p_flags jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a t1_private.stripe_accounts;
begin
  if p_account_id is null or p_account_id !~ '^acct_[A-Za-z0-9]+$' then raise exception 'Not an account id' using errcode = '22023'; end if;
  if p_user_id is not null then
    insert into t1_private.stripe_accounts (user_id, account_id) values (p_user_id, p_account_id)
    on conflict (user_id) do update set account_id = excluded.account_id;
  end if;
  update t1_private.stripe_accounts
     set charges_enabled = coalesce((p_flags->>'charges_enabled')::boolean, charges_enabled),
         payouts_enabled = coalesce((p_flags->>'payouts_enabled')::boolean, payouts_enabled),
         details_submitted = coalesce((p_flags->>'details_submitted')::boolean, details_submitted),
         disabled_reason = case when p_flags ? 'disabled_reason' then p_flags->>'disabled_reason' else disabled_reason end,
         livemode = coalesce((p_flags->>'livemode')::boolean, livemode),
         checked_at = now()
   where account_id = p_account_id
  returning * into a;
  return to_jsonb(a);
end $$;

-- A host disconnected Table 1 from their Stripe account.
create or replace function public.stripe_account_gone(p_account_id text)
returns void language sql security definer set search_path = '' as $$
  delete from t1_private.stripe_accounts where account_id = p_account_id;
$$;

-- A player is about to pay in the app: checks everything and hands back what to charge, on whose account. An open
-- checkout that hasn't expired is handed back to reuse.
create or replace function public.payment_begin(p_event_id uuid, p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events; f public.event_fees; p public.participants; a t1_private.stripe_accounts; pay public.event_payments;
begin
  select * into e from public.events where id = p_event_id;
  select * into f from public.event_fees where event_id = p_event_id;
  if e.id is null or f.event_id is null or f.amount_cents = 0 or f.pay_mode not in ('app', 'either') then
    raise exception 'This event doesn''t take payments in the app' using errcode = '22023';
  end if;
  if e.is_demo or e.status in ('completed', 'archived', 'cancelled') then
    raise exception 'That event isn''t taking payments' using errcode = '22023';
  end if;
  select * into p from public.participants where event_id = p_event_id and user_id = p_user_id order by created_at limit 1;
  if p.id is null then raise exception 'Sign up first, then pay' using errcode = '22023'; end if;
  select * into a from t1_private.stripe_accounts where user_id = f.stripe_user;
  if a.user_id is null or not a.charges_enabled then
    raise exception 'The host can''t take payments in the app right now' using errcode = '55000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p.id::text, 7));
  select * into pay from public.event_payments where participant_id = p.id and status in ('pending', 'paid');
  if pay.status = 'paid' then raise exception 'You''ve paid already' using errcode = '22023'; end if;
  if pay.id is not null and pay.method <> 'app' then
    delete from public.event_payments where id = pay.id;
    pay := null;
  end if;
  if pay.id is not null and (pay.session_expires_at is null or pay.session_expires_at < now() + interval '2 minutes'
                             or pay.amount_cents <> f.amount_cents or pay.stripe_account <> a.account_id) then
    update public.event_payments set status = 'expired' where id = pay.id;
    pay := null;
  end if;
  if pay.id is null then
    insert into public.event_payments (event_id, participant_id, user_id, payer_name, amount_cents, method, status, stripe_account)
    values (p_event_id, p.id, p_user_id, p.display_name, f.amount_cents, 'app', 'pending', a.account_id)
    returning * into pay;
  end if;
  return jsonb_build_object(
    'payment_id', pay.id, 'participant_id', p.id, 'amount_cents', pay.amount_cents, 'currency', f.currency,
    'account_id', a.account_id, 'event_name', e.name, 'reuse_url', pay.session_url,
    'fee_cents', coalesce((select (s.value)::integer from t1_private.settings s where s.name = 'payments.fee_cents'), 0));
end $$;

create or replace function public.payment_session_put(p_payment_id uuid, p_session_id text, p_url text, p_expires_at timestamptz)
returns void language sql security definer set search_path = '' as $$
  update public.event_payments set session_id = p_session_id, session_url = p_url, session_expires_at = p_expires_at
   where id = p_payment_id and status = 'pending';
$$;

-- Stripe says how a checkout ended: paid | failed | expired. Safe to hear twice, in any order.
create or replace function public.payment_settle(p_session_id text, p_payment_intent text, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pay public.event_payments;
begin
  if p_status not in ('paid', 'failed', 'expired') then raise exception 'Unknown status' using errcode = '22023'; end if;
  select * into pay from public.event_payments where session_id = p_session_id for update;
  if pay.id is null then return jsonb_build_object('known', false); end if;
  if p_status = 'paid' and pay.status in ('pending', 'expired', 'failed') then
    -- A payment that lands after its row lapsed still counts, unless another payment took its place.
    if pay.status <> 'pending' and exists (select 1 from public.event_payments x
                                            where x.participant_id = pay.participant_id and x.status in ('pending', 'paid') and x.id <> pay.id) then
      update public.event_payments set payment_intent = p_payment_intent where id = pay.id;
      return jsonb_build_object('known', true, 'status', pay.status, 'duplicate', true, 'payment_intent', p_payment_intent,
                                'account_id', pay.stripe_account);
    end if;
    update public.event_payments set status = 'paid', paid_at = now(), payment_intent = p_payment_intent, session_url = null
     where id = pay.id;
    insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
    values (pay.event_id, pay.user_id, pay.payer_name, 'payment.paid', 'participant', pay.participant_id,
            jsonb_build_object('amount_cents', pay.amount_cents, 'method', 'app'));
  elsif p_status in ('failed', 'expired') and pay.status = 'pending' then
    update public.event_payments set status = p_status, session_url = null where id = pay.id;
  end if;
  return jsonb_build_object('known', true, 'status', (select status from public.event_payments where id = pay.id));
end $$;

-- A refund is asked for: by an organizer of the event (any time), or by the player themself inside the refund
-- window. Hands back what to refund on whose account.
create or replace function public.payment_refund_begin(p_event_id uuid, p_participant_id uuid, p_by uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.events; f public.event_fees; pay public.event_payments; v_org boolean;
begin
  select * into e from public.events where id = p_event_id;
  select * into f from public.event_fees where event_id = p_event_id;
  v_org := exists (select 1 from public.event_members m where m.event_id = p_event_id and m.user_id = p_by);
  select * into pay from public.event_payments
   where event_id = p_event_id and status = 'paid' and method = 'app'
     and (participant_id = p_participant_id or (p_participant_id is null and user_id = p_by))
   order by paid_at desc limit 1;
  if pay.id is null then raise exception 'There''s no app payment to refund' using errcode = 'P0002'; end if;
  if not v_org then
    if pay.user_id is distinct from p_by then raise exception 'Only the organizer can refund someone else' using errcode = '42501'; end if;
    if f.refund_hours is null or not t1_private.sign_up_open(e)
       or (e.starts_at is not null and now() >= e.starts_at - make_interval(hours => f.refund_hours)) then
      raise exception 'Refunds have closed: ask the organizer' using errcode = '55000';
    end if;
  end if;
  return jsonb_build_object('payment_id', pay.id, 'payment_intent', pay.payment_intent, 'account_id', pay.stripe_account,
                            'amount_cents', pay.amount_cents, 'by_organizer', v_org);
end $$;

-- The refund went through at Stripe (our own call's answer, or the webhook: whichever comes first).
create or replace function public.payment_refunded(p_payment_intent text, p_refund_id text, p_by uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pay public.event_payments;
begin
  select * into pay from public.event_payments where payment_intent = p_payment_intent and status = 'paid' for update;
  if pay.id is null then return jsonb_build_object('known', false); end if;
  update public.event_payments set status = 'refunded', refunded_at = now(), refund_id = p_refund_id, marked_by = p_by where id = pay.id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (pay.event_id, p_by, 'payment.refunded', 'participant', pay.participant_id, jsonb_build_object('amount_cents', pay.amount_cents));
  return jsonb_build_object('known', true, 'event_id', pay.event_id, 'participant_id', pay.participant_id);
end $$;

-- Whether an account may use payments yet (the payments function asks before talking to Stripe for them).
create or replace function public.payments_open(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select t1_private.payments_open_for(p_user_id);
$$;

-- True the first time a Stripe event id is seen.
create or replace function public.stripe_event_seen(p_id text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  insert into t1_private.stripe_events (id) values (p_id) on conflict do nothing;
  get diagnostics v_n = row_count;
  delete from t1_private.stripe_events where at < now() - interval '30 days';
  return v_n > 0;
end $$;

-- ==================================================================== g_grants
alter table public.event_fees enable row level security;
alter table public.event_payments enable row level security;
alter table public.event_prizes enable row level security;
alter table public.league_dues enable row level security;
revoke all on public.event_fees, public.event_payments, public.event_prizes, public.league_dues from anon, authenticated;
insert into t1_private.settings (name, value) values ('payments.fee_cents', '0') on conflict (name) do nothing;

-- Payments, prize marks and the fee ping `event:<id>` like the other event tables, so screens follow at once.
do $$
declare t text;
begin
  foreach t in array array['event_fees', 'event_payments', 'event_prizes'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_ping_ins', t);
    execute format('drop trigger if exists %I on public.%I', t || '_ping_upd', t);
    execute format('drop trigger if exists %I on public.%I', t || '_ping_del', t);
    execute format('create trigger %I after insert on public.%I referencing new table as new_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_ins', t, 'event_id');
    execute format('create trigger %I after update on public.%I referencing old table as old_rows new table as new_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_upd', t, 'event_id');
    execute format('create trigger %I after delete on public.%I referencing old table as old_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_del', t, 'event_id');
  end loop;
end $$;

do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 't1_private' and p.proname in ('payments_open_for', 'payout_clean', 'fee_json', 'event_cut', 'event_pool',
                                                             'event_prize_rows', 'payment_state') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.event_fee_set(uuid, jsonb)', 'public.event_payment_mark(uuid, uuid, text)', 'public.event_prizes_set(uuid, jsonb)',
    'public.event_prize_mark(uuid, uuid, boolean, text)', 'public.league_due_mark(uuid, integer)', 'public.payments_account()'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.event_money(uuid, text)', 'public.league_money(uuid)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.stripe_account_get(uuid)', 'public.stripe_account_put(uuid, text, jsonb)', 'public.stripe_account_gone(text)',
    'public.payment_begin(uuid, uuid)', 'public.payment_session_put(uuid, text, text, timestamptz)',
    'public.payment_settle(text, text, text)', 'public.payment_refund_begin(uuid, uuid, uuid)',
    'public.payment_refunded(text, text, uuid)', 'public.stripe_event_seen(text)', 'public.payments_open(uuid)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
