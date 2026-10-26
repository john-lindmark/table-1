-- Want prices (contract/want-prices-2026-10-26.md): a daily price history for every printing someone wants, the
-- want list's trend (wants_prices), and one `want.price` push a day per account when a want gets meaningfully
-- cheaper (15%+ and $1+ under its 30-day average) or falls to the want's max price.
-- Prices are Scryfall's TCGplayer market price (card_prices, near mint), refreshed nightly by cards-sync.

-- ==================================================================== a_tables
-- One row per printing and day, for printings of cards someone wants. Kept 120 days.
create table if not exists t1_private.price_days (
  card_id uuid not null,
  day date not null,
  usd numeric(10,2), usd_foil numeric(10,2), usd_etched numeric(10,2),
  primary key (card_id, day)
);
-- No index by day: with one, reads chose it and scanned every printing's history (the daily trim can scan).

-- What each want last pushed: the price, when, and whether it was at or under its max then (a max push fires
-- once per crossing and is armed again when the price goes back over).
create table if not exists t1_private.want_price_alerts (
  user_id uuid not null,
  want_key text not null,                       -- oracle_id:card_id:finish (empty when any)
  price numeric(10,2),
  sent_at timestamptz,
  under_max boolean not null default false,
  primary key (user_id, want_key)
);

-- ==================================================================== b_prices
-- Today's prices of every printing of every wanted card. Same day again = refreshed, not duplicated.
create or replace function t1_private.price_days_take(p_day date default current_date)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  insert into t1_private.price_days as d (card_id, day, usd, usd_foil, usd_etched)
  select p.card_id, p_day, p.usd, p.usd_foil, p.usd_etched
    from public.card_prices p
    join public.cards c on c.id = p.card_id
   where c.oracle_id in (select w.oracle_id from public.wants w where w.qty > 0)
     and coalesce(p.usd, p.usd_foil, p.usd_etched) is not null
  on conflict (card_id, day) do update set usd = excluded.usd, usd_foil = excluded.usd_foil, usd_etched = excluded.usd_etched;
  get diagnostics v_n = row_count;
  delete from t1_private.price_days where day < p_day - 120;
  return v_n;
end $$;

-- Each want's price now and its history (one account, or every account when p_user is null): the cheapest
-- near-mint price among the printings and finishes it takes (any printing = every English printing; a printing
-- = its finishes; a finish = that one). `then` is the oldest day of the last 7, `avg30` the mean of the last 30
-- days (null under 7 days of history). Days before p_today only; `now` is card_prices.
create or replace function t1_private.want_prices_of(p_user uuid, p_today date default current_date)
returns table (user_id uuid, oracle_id uuid, card_id uuid, finish text, max_usd numeric,
               now numeric, now_card_id uuid, now_finish text, then_usd numeric, then_days integer, avg30 numeric, avg_days integer)
language sql stable security definer set search_path = '' as $$
  with w as (
    select w.id, w.user_id, w.oracle_id, w.card_id, w.finish, w.max_usd from public.wants w
     where w.qty > 0 and (p_user is null or w.user_id = p_user)
  ), m as (
    select w.id, w.finish, c.id cid from w
      join public.cards c on c.oracle_id = w.oracle_id
                         and (c.id = w.card_id or (w.card_id is null and c.lang = 'en'))
  ), nowp as (
    select distinct on (m.id) m.id, x.usd, m.cid, x.f
      from m join public.card_prices p on p.card_id = m.cid
      cross join lateral (values ('nonfoil', p.usd), ('foil', p.usd_foil), ('etched', p.usd_etched)) x(f, usd)
     where x.usd is not null and (m.finish is null or m.finish = x.f)
     order by m.id, x.usd, m.cid, x.f
  ), days as (
    -- least() skips nulls: a printing's cheapest finish.
    select m.id, d.day, min(case m.finish when 'nonfoil' then d.usd when 'foil' then d.usd_foil when 'etched' then d.usd_etched
                                         else least(d.usd, d.usd_foil, d.usd_etched) end) usd
      -- Per printing through the primary key: a join by day would read every printing's history.
      from m cross join lateral (select d.day, d.usd, d.usd_foil, d.usd_etched from t1_private.price_days d
                                  where d.card_id = m.cid and d.day >= p_today - 30 and d.day < p_today) d
     group by 1, 2
     having min(case m.finish when 'nonfoil' then d.usd when 'foil' then d.usd_foil when 'etched' then d.usd_etched
                              else least(d.usd, d.usd_foil, d.usd_etched) end) is not null
  ), wk as (
    select distinct on (d.id) d.id, d.usd, d.day from days d where d.day >= p_today - 7 order by d.id, d.day
  ), mo as (
    select d.id, round(avg(d.usd), 2) usd, count(*)::int n from days d group by 1
  )
  select w.user_id, w.oracle_id, w.card_id, w.finish, w.max_usd,
         n.usd, n.cid, n.f, k.usd, (p_today - k.day)::int,
         case when o.n >= 7 then o.usd end, coalesce(o.n, 0)
    from w
    left join nowp n on n.id = w.id
    left join wk k on k.id = w.id
    left join mo o on o.id = w.id;
$$;

-- ==================================================================== c_rpcs
create or replace function t1_private.want_alerts_on(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from public.notification_prefs np where np.user_id = p_user and 'want.price' = any (np.muted_kinds));
$$;

-- Your wants' prices and trend. {alerts, items: [{oracle_id, card_id, finish, now, now_card_id, now_finish, then,
-- then_days, avg30}]}; numbers null when there's no price.
create or replace function public.wants_prices()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return jsonb_build_object('alerts', t1_private.want_alerts_on(v_uid), 'items', coalesce((
    select jsonb_agg(jsonb_build_object('oracle_id', p.oracle_id, 'card_id', p.card_id, 'finish', p.finish,
                                        'now', p.now, 'now_card_id', p.now_card_id, 'now_finish', p.now_finish,
                                        'then', p.then_usd, 'then_days', p.then_days, 'avg30', p.avg30)
                     order by p.oracle_id, p.card_id nulls first, p.finish nulls first)
      from t1_private.want_prices_of(v_uid) p), '[]'::jsonb));
end $$;

-- Price alerts on or off for your account (the `want.price` push kind). Returns {alerts}.
create or replace function public.want_alerts_set(p_on boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_was boolean;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_on is null then raise exception 'p_on is required' using errcode = '22023'; end if;
  v_was := t1_private.want_alerts_on(v_uid);
  if v_was <> p_on then
    insert into public.notification_prefs as np (user_id, muted_kinds)
    values (v_uid, case when p_on then '{}'::text[] else array['want.price'] end)
    on conflict (user_id) do update
      set muted_kinds = case when p_on then array_remove(np.muted_kinds, 'want.price')
                             else array_append(array_remove(np.muted_kinds, 'want.price'), 'want.price') end,
          updated_at = now();
    perform t1_private.account_audit(v_uid, 'want_alerts.set', null,
                                     jsonb_build_object('alerts', v_was), jsonb_build_object('alerts', p_on));
  end if;
  return jsonb_build_object('alerts', p_on);
end $$;

-- ==================================================================== d_digest
-- Once a day: wants that got meaningfully cheaper, or fell to their max, become one `want.price` push per account.
--   drop:      now ≤ avg30 × (1 − p_drop) and avg30 − now ≥ p_min; at most once per want every p_cooldown, and
--              (within 30 days of the last push) only at 5% under the price last pushed.
--   under_max: now ≤ max_usd, once per crossing (armed again when the price goes back over the max).
-- Not demo or deleted accounts, not accounts that turned price alerts off.
create or replace function t1_private.want_price_digest(
  p_today date default current_date, p_drop numeric default 0.15, p_min numeric default 1.00,
  p_cooldown interval default interval '7 days')
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_rows jsonb;
  r record;
  v_n integer := 0;
begin
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_rows from (
    select q.*, case when q.under_now and not coalesce(a.under_max, false) then 'under_max'
                     when q.avg30 is not null and q.now <= q.avg30 * (1 - p_drop) and q.avg30 - q.now >= p_min
                      and (a.sent_at is null or a.sent_at <= now() - p_cooldown)
                      and (a.price is null or a.sent_at < now() - interval '30 days' or q.now <= a.price * 0.95) then 'drop'
                end hit,
           coalesce(a.under_max, false) was_under
      from (
        select p.user_id, p.oracle_id::text || ':' || coalesce(p.card_id::text, '') || ':' || coalesce(p.finish, '') want_key,
               o.name, p.now, p.avg30, p.max_usd,
               (p.max_usd is not null and p.now is not null and p.now <= p.max_usd) under_now,
               case when p.avg30 > 0 then round((p.avg30 - p.now) / p.avg30 * 100)::int end pct
          from t1_private.want_prices_of(null, p_today) p
          join public.card_oracles o on o.oracle_id = p.oracle_id
          join public.profiles pr on pr.id = p.user_id and pr.deleted_at is null and not pr.is_demo
          left join public.notification_prefs np on np.user_id = p.user_id
         where p.now is not null and not coalesce('want.price' = any (np.muted_kinds), false)
      ) q
      left join t1_private.want_price_alerts a on a.user_id = q.user_id and a.want_key = q.want_key
  ) x;

  -- What was pushed, and each want's side of its max.
  insert into t1_private.want_price_alerts as a (user_id, want_key, price, sent_at, under_max)
  select h.user_id, h.want_key, case when h.hit is not null then h.now end, case when h.hit is not null then now() end, h.under_now
    from jsonb_to_recordset(v_rows) h(user_id uuid, want_key text, now numeric, under_now boolean, was_under boolean, hit text)
   where h.hit is not null or h.under_now <> h.was_under
  on conflict (user_id, want_key) do update
    set under_max = excluded.under_max,
        price = coalesce(excluded.price, a.price),
        sent_at = coalesce(excluded.sent_at, a.sent_at);

  -- One push per account: the biggest moves first (under the max, then the deepest drop).
  for r in
    select h.user_id, count(*)::int n,
           (array_agg(h.name order by h.hit = 'under_max' desc, h.pct desc nulls last, h.name))[1:3] names,
           (array_agg(jsonb_build_object('name', h.name, 'price', h.now, 'pct', h.pct, 'reason', h.hit, 'max', h.max_usd)
                      order by h.hit = 'under_max' desc, h.pct desc nulls last, h.name))[1] first
      from jsonb_to_recordset(v_rows) h(user_id uuid, name text, now numeric, max_usd numeric, pct integer, hit text)
     where h.hit is not null
     group by h.user_id
  loop
    perform public.enqueue_notification('want.price', null, array[r.user_id],
      jsonb_build_object('n', r.n, 'names', to_jsonb(r.names)) || r.first);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Deleting your account clears what was kept about your wants.
create or replace function t1_private.want_prices_forget()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from t1_private.want_price_alerts where user_id = new.id;
  return null;
end $$;
drop trigger if exists profiles_want_prices_forget on public.profiles;
create trigger profiles_want_prices_forget after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function t1_private.want_prices_forget();

-- ==================================================================== e_cron
-- The catalog sync starts 23:23 UTC and is done well before 03:15; pushes go out at 16:05 UTC (evening in
-- Europe, midday in the US).
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-price-days') then
      perform cron.schedule('t1-price-days', '15 3 * * *', 'select t1_private.price_days_take()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-want-prices') then
      perform cron.schedule('t1-want-prices', '5 16 * * *', 'select t1_private.want_price_digest()');
    end if;
  end if;
end $$;

-- ==================================================================== f_grants
do $$
declare f text;
begin
  foreach f in array array['price_days_take(date)', 'want_prices_of(uuid, date)', 'want_alerts_on(uuid)',
                           'want_price_digest(date, numeric, numeric, interval)', 'want_prices_forget()'] loop
    execute format('revoke execute on function t1_private.%s from public', f);
  end loop;
  foreach f in array array['wants_prices()', 'want_alerts_set(boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
