-- Converted prices (2026-10-28; contract/converted-prices-2026-10-28.md, cases testdata/converted-prices/cases.json).
-- When TCGplayer has no market price for a printing's finish, its Cardmarket EUR price converted at the ECB's daily
-- reference rate stands in (John, 2026-10-28; spike in table-1-context/docs/spike-mtgjson-2026-10-28.md). Mox
-- Sapphire in Alpha, Beta and Unlimited had no USD price at all.
--
-- public.card_prices stays exactly as Scryfall sends it (cards-sync is unchanged). The converted prices live in
-- t1_private.card_price_fallback, rebuilt nightly before library_revalue, and t1_private.card_prices_usd fills the
-- gaps from it. Collection value, trade matches, the redraft pile and card_prices_get read the view; want prices and
-- their alerts (price_days_take, want_prices_of, trade_want_digest) stay on TCGplayer alone, so a change in the
-- exchange rate never reads as a price drop. Etched is never converted (Cardmarket has no etched price).
--
-- Guard: Scryfall's Cardmarket links are sometimes to the wrong product (Summer Magic Badlands at €0.02). A converted
-- price under 10% of the cheapest TCGplayer price of any printing of the same card is left out.
--
-- The functions replaced below are copies of their latest definitions (collection_apply_as, library_revalue and
-- trade_matches_for from 20261024120000_condition_prices.sql, redraft_list from 20261016260000_redraft_deck_photos.sql)
-- with only public.card_prices swapped for t1_private.card_prices_usd. card_prices_get gains a trailing element.

-- ==================================================================== a_rates
-- ECB euro reference rates, one row per ECB working day.
create table if not exists t1_private.fx_rates (
  day date primary key,
  usd_per_eur numeric(10, 6) not null check (usd_per_eur > 0),
  fetched_at timestamptz not null default now()
);
alter table t1_private.fx_rates enable row level security;

-- The one pg_net request in flight, if any.
create table if not exists t1_private.fx_state (
  id boolean primary key default true check (id),
  request_id bigint,
  requested_at timestamptz
);
alter table t1_private.fx_state enable row level security;
insert into t1_private.fx_state default values on conflict do nothing;

-- Hourly: reads the answer to the last request, or asks the ECB again once the newest rate is 20 hours old. The ECB
-- publishes around 16:00 CET on working days; weekends and holidays answer with the last working day's rate.
create or replace function t1_private.fx_tick()
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_state t1_private.fx_state;
  v_status integer;
  v_body text;
  v_rate numeric;
  v_day date;
begin
  select * into v_state from t1_private.fx_state where id for update;
  if v_state.request_id is not null then
    select h.status_code, h.content into v_status, v_body from net._http_response h where h.id = v_state.request_id;
    if found then
      update t1_private.fx_state set request_id = null, requested_at = null where id;
      v_rate := t1_private.fx_parse_rate(v_body);
      v_day := t1_private.fx_parse_day(v_body);
      if v_status = 200 and v_rate between 0.5 and 2 and v_day is not null then
        insert into t1_private.fx_rates (day, usd_per_eur) values (v_day, v_rate)
        on conflict (day) do update set usd_per_eur = excluded.usd_per_eur, fetched_at = now();
        return 'rate ' || v_day || ' ' || v_rate;
      end if;
      return 'bad answer ' || coalesce(v_status::text, '-');
    end if;
    if v_state.requested_at > now() - interval '1 hour' then return 'waiting'; end if;
    update t1_private.fx_state set request_id = null, requested_at = null where id; -- lost; ask again
  end if;
  if exists (select 1 from t1_private.fx_rates where fetched_at > now() - interval '20 hours') then return 'fresh'; end if;
  update t1_private.fx_state
     set request_id = net.http_get(url := 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml'),
         requested_at = now()
   where id;
  return 'asked';
end $$;

-- <Cube currency='USD' rate='1.1133'/> and <Cube time='2026-10-28'>.
create or replace function t1_private.fx_parse_rate(p_xml text)
returns numeric language sql immutable set search_path = '' as $$
  select (substring(p_xml from $re$currency=['"]USD['"]\s+rate=['"]([0-9]+\.[0-9]+)['"]$re$))::numeric;
$$;
create or replace function t1_private.fx_parse_day(p_xml text)
returns date language sql immutable set search_path = '' as $$
  select (substring(p_xml from $re$time=['"]([0-9]{4}-[0-9]{2}-[0-9]{2})['"]$re$))::date;
$$;

-- The rate on the day of the spike, so prices convert from the moment this is applied; the first tick replaces it.
insert into t1_private.fx_rates (day, usd_per_eur, fetched_at)
select date '2026-10-28', 1.1133, now() - interval '1 day'
 where not exists (select 1 from t1_private.fx_rates);

-- ==================================================================== b_fallback
create table if not exists t1_private.card_price_fallback (
  card_id uuid primary key references public.cards (id) on delete cascade,
  usd numeric,
  usd_foil numeric,
  usd_per_eur numeric(10, 6) not null,
  rate_day date not null
);
alter table t1_private.card_price_fallback enable row level security;

-- A converted price for each finish TCGplayer doesn't price (eur → usd, eur_foil → usd_foil), at the newest rate,
-- to the cent; none under 10% of the cheapest TCGplayer price of the same card. Returns rows written + removed.
create or replace function t1_private.card_price_fallback_refresh()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_rate numeric;
  v_day date;
  v_n integer;
begin
  select r.usd_per_eur, r.day into v_rate, v_day from t1_private.fx_rates r order by r.day desc limit 1;
  if v_rate is null then return 0; end if;
  with cand as (
    select p.card_id, c.oracle_id,
           case when p.usd is null and p.eur > 0 then round(p.eur * v_rate, 2) end usd,
           case when p.usd_foil is null and p.eur_foil > 0 then round(p.eur_foil * v_rate, 2) end usd_foil
      from public.card_prices p
      join public.cards c on c.id = p.card_id
     where (p.usd is null and p.eur > 0) or (p.usd_foil is null and p.eur_foil > 0)
  ), floor as (
    -- least() skips nulls: each printing's cheapest TCGplayer finish.
    select c.oracle_id, min(least(p.usd, p.usd_foil, p.usd_etched)) low
      from public.card_prices p
      join public.cards c on c.id = p.card_id
     where c.oracle_id in (select oracle_id from cand)
       and coalesce(p.usd, p.usd_foil, p.usd_etched) is not null
     group by 1
  ), kept as (
    select k.card_id,
           case when f.low is null or k.usd >= f.low * 0.1 then k.usd end usd,
           case when f.low is null or k.usd_foil >= f.low * 0.1 then k.usd_foil end usd_foil
      from cand k left join floor f on f.oracle_id = k.oracle_id
  ), fresh as (
    select * from kept where usd is not null or usd_foil is not null
  ), gone as (
    delete from t1_private.card_price_fallback b
     where not exists (select 1 from fresh n where n.card_id = b.card_id)
    returning 1
  ), up as (
    insert into t1_private.card_price_fallback as b (card_id, usd, usd_foil, usd_per_eur, rate_day)
    select n.card_id, n.usd, n.usd_foil, v_rate, v_day from fresh n
    on conflict (card_id) do update
       set usd = excluded.usd, usd_foil = excluded.usd_foil, usd_per_eur = excluded.usd_per_eur, rate_day = excluded.rate_day
     where (b.usd, b.usd_foil, b.rate_day) is distinct from (excluded.usd, excluded.usd_foil, excluded.rate_day)
    returning 1
  )
  select (select count(*) from gone) + (select count(*) from up) into v_n;
  return v_n;
end $$;

-- ==================================================================== c_view
-- card_prices with the gaps filled; `converted` is a bitmask of the finishes that are converted (1 nonfoil, 2 foil).
create or replace view t1_private.card_prices_usd as
  select p.card_id,
         coalesce(p.usd, f.usd) usd,
         coalesce(p.usd_foil, f.usd_foil) usd_foil,
         p.usd_etched, p.eur, p.eur_foil,
         (case when p.usd is null and f.usd is not null then 1 else 0 end
          + case when p.usd_foil is null and f.usd_foil is not null then 2 else 0 end) converted
    from public.card_prices p
    left join t1_private.card_price_fallback f on f.card_id = p.card_id;
revoke all on t1_private.card_prices_usd from public, anon, authenticated;

-- Current prices for up to 5000 printings: [[card_id, usd, usd_foil, usd_etched, eur, eur_foil, converted], …].
-- USD is the TCGplayer market price as published by Scryfall, or else the Cardmarket price converted to USD;
-- `converted` says which (bit 1 nonfoil, bit 2 foil). Older apps read the first six elements only.
create or replace function public.card_prices_get(p_card_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if cardinality(p_card_ids) > 5000 then raise exception 'At most 5000 cards per call' using errcode = '22023'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_array(p.card_id, p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil, p.converted)), '[]'::jsonb)
            from t1_private.card_prices_usd p where p.card_id = any (p_card_ids));
end $$;

-- ==================================================================== d_collection_value
create or replace function t1_private.collection_apply_as(
  p_uid uuid, p_ops jsonb, p_source text, p_source_id uuid, p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_key uuid := coalesce(p_batch_id, gen_random_uuid());
  v_batch public.collection_batches;
  v_plan t1_private.collection_change[];
  v_bplan t1_private.binder_change[];
  v_shrink t1_private.binder_change[];
  v_n integer;
  v_bad text;
  v_had integer;
  v_has integer;
  v_seq bigint;
  v_changes integer;
  v_items jsonb;
  v_bitems jsonb;
  v_sum public.library_summary;
begin
  if p_uid is null then raise exception 'Sign in to change your collection' using errcode = '28000'; end if;
  if p_source is null or p_source not in ('manual', 'import', 'scan', 'trade', 'adjust', 'undo', 'binder') then
    raise exception 'Unknown source' using errcode = '22023';
  end if;
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' then raise exception 'ops must be an array' using errcode = '22023'; end if;
  v_n := jsonb_array_length(p_ops);
  if v_n = 0 then raise exception 'Nothing to change' using errcode = '22023'; end if;
  if v_n > 5000 then raise exception 'At most 5000 changes per batch' using errcode = '22023'; end if;

  -- Serialize this user's writes; this also makes a concurrent replay of the same key wait and then see it.
  perform t1_private.library_lock(p_uid);

  select * into v_batch from public.collection_batches where id = v_key;
  if v_batch.id is not null then
    if v_batch.user_id <> p_uid then raise exception 'Batch id already used' using errcode = '23505'; end if;
    select * into v_sum from public.library_summary where user_id = p_uid;
    return jsonb_build_object('batch_id', v_key, 'duplicate', true, 'seq', v_sum.seq, 'items', '[]'::jsonb,
                              'binder_items', '[]'::jsonb, 'summary', t1_private.summary_json(v_sum));
  end if;
  if p_source <> 'undo' and (select count(*) from public.collection_batches
       where user_id = p_uid and created_at > now() - interval '1 minute') >= 120 then
    raise exception 'Too many changes, try again in a moment' using errcode = '53400';
  end if;

  with ops as (
    select o.card_id, coalesce(nullif(o.finish, ''), 'nonfoil') finish,
           upper(coalesce(nullif(o.condition, ''), 'NM')) condition, lower(coalesce(nullif(o.lang, ''), 'en')) lang,
           o.delta, o.qty
      from jsonb_to_recordset(p_ops) o (card_id uuid, finish text, condition text, lang text, delta integer, qty integer)
  ), agg as (
    select card_id, finish, condition, lang, count(qty)::int n_set, count(delta)::int n_delta,
           max(qty) set_qty, coalesce(sum(delta), 0)::int sum_delta
      from ops group by 1, 2, 3, 4
  )
  select array_agg(row(
           a.card_id, a.finish, a.condition, a.lang, c.oracle_id, o.name, c.finishes,
           coalesce(i.qty, 0),
           case when a.n_set > 0 then a.set_qty else coalesce(i.qty, 0) + a.sum_delta end,
           a.n_set, a.n_delta,
           t1_private.condition_price(t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, pr.eur, pr.eur_foil, a.finish, 'usd'), a.condition),
           t1_private.condition_price(t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, pr.eur, pr.eur_foil, a.finish, 'eur'), a.condition)
         )::t1_private.collection_change)
    into v_plan
    from agg a
    left join public.cards c on c.id = a.card_id
    left join public.card_oracles o on o.oracle_id = c.oracle_id
    left join t1_private.card_prices_usd pr on pr.card_id = a.card_id
    left join public.collection_items i
           on i.user_id = p_uid and i.card_id = a.card_id and i.finish = a.finish
          and i.condition = a.condition and i.lang = a.lang;

  -- Validate the whole batch before writing anything.
  if exists (select 1 from unnest(v_plan) p where p.card_id is null) then
    raise exception 'Every change needs a card_id' using errcode = '22023';
  end if;
  select string_agg(p.card_id::text, ', ') into v_bad
    from (select * from unnest(v_plan) p where p.oracle_id is null limit 3) p;
  if v_bad is not null then raise exception 'Unknown card: %', v_bad using errcode = '22023'; end if;
  select string_agg(p.name, ', ') into v_bad
    from (select * from unnest(v_plan) p where p.n_set > 1 or (p.n_set > 0 and p.n_delta > 0) limit 3) p;
  if v_bad is not null then
    raise exception 'Set a quantity or add copies, not both, for %', v_bad using errcode = '22023';
  end if;
  select string_agg(p.name || ' (' || p.finish || ')', ', ') into v_bad
    from (select * from unnest(v_plan) p where not (p.finish = any (p.finishes)) limit 3) p;
  if v_bad is not null then raise exception 'Not printed in that finish: %', v_bad using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_plan) p where p.condition not in ('NM', 'LP', 'MP', 'HP', 'DMG')
                                               or p.lang !~ '^[a-z]{2,3}$') then
    raise exception 'Condition is NM, LP, MP, HP or DMG; language is a 2-3 letter code' using errcode = '22023';
  end if;
  select string_agg(p.name || ' (have ' || p.cur || ')', ', ') into v_bad
    from (select * from unnest(v_plan) p where p.new_qty < 0 limit 3) p;
  if v_bad is not null then raise exception 'Not enough copies: %', v_bad using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_plan) p where p.new_qty > 100000) then
    raise exception 'That is more than 100000 copies' using errcode = '22023';
  end if;

  -- Binder hints, per item and binder: copies added into it (> 0) or taken out of it first (< 0).
  if exists (select 1 from jsonb_array_elements(p_ops) e where e ? 'binder_id' and jsonb_typeof(e->'binder_id') <> 'null') then
    if exists (select 1 from jsonb_array_elements(p_ops) e
                where jsonb_typeof(e->'binder_id') = 'string' and (e ? 'qty' and jsonb_typeof(e->'qty') <> 'null')) then
      raise exception 'A binder goes with copies added or removed, not a set quantity' using errcode = '22023';
    end if;
    if p_source <> 'undo' and exists (
         select 1 from jsonb_to_recordset(p_ops) o (binder_id uuid)
          where o.binder_id is not null
            and not exists (select 1 from public.binders b
                             where b.id = o.binder_id and b.user_id = p_uid and b.deleted_at is null)) then
      raise exception 'That binder is gone' using errcode = 'P0002';
    end if;
    with h as (
      select o.binder_id, o.card_id, coalesce(nullif(o.finish, ''), 'nonfoil') finish,
             upper(coalesce(nullif(o.condition, ''), 'NM')) condition, lower(coalesce(nullif(o.lang, ''), 'en')) lang,
             coalesce(sum(o.delta), 0)::int d
        from jsonb_to_recordset(p_ops) o (binder_id uuid, card_id uuid, finish text, condition text, lang text, delta integer)
       where o.binder_id is not null
       group by 1, 2, 3, 4, 5
    )
    select array_agg(row(h.binder_id, h.card_id, h.finish, h.condition, h.lang, coalesce(bi.qty, 0),
                         greatest(coalesce(bi.qty, 0) + h.d, 0))::t1_private.binder_change)
      into v_bplan
      from h
      join public.binders b on b.id = h.binder_id and b.user_id = p_uid and b.deleted_at is null
      left join public.binder_items bi on bi.binder_id = h.binder_id and bi.card_id = h.card_id and bi.finish = h.finish
                                      and bi.condition = h.condition and bi.lang = h.lang
     where h.d <> 0;
  end if;

  -- Distinct Oracle cards owned before the change, among the ones it touches.
  select count(*) into v_had from (select distinct p.oracle_id from unnest(v_plan) p) a
   where exists (select 1 from public.cards c join public.collection_items i
                   on i.user_id = p_uid and i.card_id = c.id and i.qty > 0
                  where c.oracle_id = a.oracle_id);

  insert into public.collection_batches (id, user_id, source, source_id, ops)
  values (v_key, p_uid, p_source, p_source_id, v_n);

  with up as (
    insert into public.collection_items as i (user_id, card_id, finish, condition, lang, qty, seq)
    select p_uid, p.card_id, p.finish, p.condition, p.lang, p.new_qty, nextval('public.collection_seq')
      from unnest(v_plan) p where p.new_qty <> p.cur
     order by p.card_id, p.finish, p.condition, p.lang
    on conflict (user_id, card_id, finish, condition, lang) do update
       set qty = excluded.qty, seq = excluded.seq, updated_at = now()
    returning i.card_id, i.finish, i.condition, i.lang, i.qty, i.seq
  )
  select count(*)::int, max(seq),
         coalesce(jsonb_agg(jsonb_build_object('card_id', card_id, 'finish', finish, 'condition', condition,
                                               'lang', lang, 'qty', qty, 'seq', seq) order by seq), '[]'::jsonb)
    into v_changes, v_seq, v_items
    from up;

  insert into public.collection_ledger (user_id, batch_id, card_id, finish, condition, lang, delta, qty_after)
  select p_uid, v_key, p.card_id, p.finish, p.condition, p.lang, p.new_qty - p.cur, p.new_qty
    from unnest(v_plan) p where p.new_qty <> p.cur;

  -- Allocations: the binder hints first, then give back whatever an item no longer has copies for.
  v_bitems := t1_private.binder_write(p_uid, v_key, v_bplan);
  with keys as (
    select distinct p.card_id, p.finish, p.condition, p.lang from unnest(v_plan) p
  ), over as (
    select k.card_id, k.finish, k.condition, k.lang, sum(bi.qty) - coalesce(max(i.qty), 0) excess
      from keys k
      join public.binder_items bi on bi.user_id = p_uid and bi.card_id = k.card_id and bi.finish = k.finish
                                 and bi.condition = k.condition and bi.lang = k.lang and bi.qty > 0
      left join public.collection_items i on i.user_id = p_uid and i.card_id = k.card_id and i.finish = k.finish
                                         and i.condition = k.condition and i.lang = k.lang
     group by 1, 2, 3, 4
    having sum(bi.qty) > coalesce(max(i.qty), 0)
  ), ranked as (
    select bi.binder_id, bi.card_id, bi.finish, bi.condition, bi.lang, bi.qty cur, o.excess,
           sum(bi.qty) over (partition by bi.card_id, bi.finish, bi.condition, bi.lang
                             order by b.for_trade, lower(b.name), b.id) cum
      from over o
      join public.binder_items bi on bi.user_id = p_uid and bi.card_id = o.card_id and bi.finish = o.finish
                                 and bi.condition = o.condition and bi.lang = o.lang and bi.qty > 0
      join public.binders b on b.id = bi.binder_id
  )
  select array_agg(row(r.binder_id, r.card_id, r.finish, r.condition, r.lang, r.cur,
                       r.cur - least(r.cur, greatest(0, r.excess - (r.cum - r.cur))))::t1_private.binder_change)
    into v_shrink
    from ranked r
   where least(r.cur, greatest(0, r.excess - (r.cum - r.cur))) > 0;
  v_bitems := v_bitems || t1_private.binder_write(p_uid, v_key, v_shrink);

  select count(*) into v_has from (select distinct p.oracle_id from unnest(v_plan) p) a
   where exists (select 1 from public.cards c join public.collection_items i
                   on i.user_id = p_uid and i.card_id = c.id and i.qty > 0
                  where c.oracle_id = a.oracle_id);

  update public.collection_batches set changes = v_changes, seq_max = v_seq where id = v_key;
  update public.library_summary s
     set total_qty = s.total_qty + d.qty,
         unique_printings = s.unique_printings + d.printings,
         unique_cards = s.unique_cards + v_has - v_had,
         value_usd = s.value_usd + d.usd,
         value_eur = s.value_eur + d.eur,
         seq = greatest(s.seq, coalesce(v_seq, 0)),
         updated_at = now()
    from (select coalesce(sum(p.new_qty - p.cur), 0) qty,
                 coalesce(sum(case when p.cur = 0 and p.new_qty > 0 then 1
                                   when p.cur > 0 and p.new_qty = 0 then -1 else 0 end), 0) printings,
                 coalesce(sum((p.new_qty - p.cur) * coalesce(p.p_usd, 0)), 0) usd,
                 coalesce(sum((p.new_qty - p.cur) * coalesce(p.p_eur, 0)), 0) eur
            from unnest(v_plan) p) d
   where s.user_id = p_uid
  returning s.* into v_sum;

  return jsonb_build_object('batch_id', v_key, 'duplicate', false, 'changes', v_changes, 'seq', v_sum.seq,
                            'items', v_items, 'binder_items', v_bitems, 'summary', t1_private.summary_json(v_sum));
end $$;

-- ==================================================================== e_revalue
create or replace function t1_private.library_revalue()
returns void language sql security definer set search_path = '' as $$
  update public.library_summary s
     set value_usd = v.usd, value_eur = v.eur
    from (select i.user_id,
                 coalesce(sum(i.qty * t1_private.condition_price(t1_private.unit_price(p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil, i.finish, 'usd'), i.condition)), 0) usd,
                 coalesce(sum(i.qty * t1_private.condition_price(t1_private.unit_price(p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil, i.finish, 'eur'), i.condition)), 0) eur
            from public.collection_items i
            left join t1_private.card_prices_usd p on p.card_id = i.card_id
           where i.qty > 0
           group by i.user_id) v
   where s.user_id = v.user_id
     and (s.value_usd, s.value_eur) is distinct from (v.usd::numeric(14,2), v.eur::numeric(14,2));
$$;

-- ==================================================================== f_trade_matches
create or replace function t1_private.trade_matches_for(p_me uuid, p_one uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_people jsonb;
begin
  with people as (
    select * from t1_private.match_people(p_me, p_one)
  ), my_wants as (
    select w.oracle_id, w.card_id, w.finish, w.qty, w.max_usd from public.wants w where w.user_id = p_me and w.qty > 0
  ), their_tb as (
    select p.uid, tb.id from people p cross join lateral t1_private.trade_binders_for(p.uid, p.level) tb(id)
  ), their_copies as (
    select t.uid who, c.oracle_id, bi.card_id, bi.finish, bi.condition, bi.lang, sum(bi.qty)::int qty
      from their_tb t
      join public.binder_items bi on bi.binder_id = t.id and bi.qty > 0
      join public.cards c on c.id = bi.card_id
     where c.oracle_id in (select oracle_id from my_wants)
     group by 1, 2, 3, 4, 5, 6
  ), wants_seen as (
    select p.uid from people p, t1_private.share_of(p.uid) s
     where t1_private.vis_ok(p.level, s.profile, coalesce(s.wants, s.library))
  ), my_copies as (
    select c.oracle_id, bi.card_id, bi.finish, bi.condition, bi.lang,
           (array_agg(bi.binder_id order by bi.qty desc, bi.binder_id))[1] binder_id, sum(bi.qty)::int qty
      from public.binders b
      join public.binder_items bi on bi.binder_id = b.id and bi.qty > 0
      join public.cards c on c.id = bi.card_id
     where b.user_id = p_me and b.for_trade and b.deleted_at is null
     group by 1, 2, 3, 4, 5
  ), their_wants as (
    select w.user_id who, w.oracle_id, w.card_id, w.finish, w.qty
      from wants_seen ws join public.wants w on w.user_id = ws.uid and w.qty > 0
     where w.oracle_id in (select oracle_id from my_copies)
  ), have as (
    select m.* from t1_private.want_match(
      (select array_agg(row(o.who, w.oracle_id, w.card_id, w.finish, w.qty, w.max_usd)::t1_private.mwant)
         from my_wants w join (select distinct who, oracle_id from their_copies) o on o.oracle_id = w.oracle_id),
      (select array_agg(row(tc.who, tc.oracle_id, tc.card_id, tc.finish, tc.condition, tc.lang, null,
                            tc.qty, t1_private.condition_price(t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, null, null, tc.finish, 'usd'), tc.condition))::t1_private.mcopy)
         from their_copies tc left join t1_private.card_prices_usd pr on pr.card_id = tc.card_id)) m
  ), want as (
    select m.* from t1_private.want_match(
      (select array_agg(row(tw.who, tw.oracle_id, tw.card_id, tw.finish, tw.qty, null)::t1_private.mwant) from their_wants tw),
      (select array_agg(row(o.who, mc.oracle_id, mc.card_id, mc.finish, mc.condition, mc.lang, mc.binder_id,
                            mc.qty, t1_private.condition_price(t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, null, null, mc.finish, 'usd'), mc.condition))::t1_private.mcopy)
         from my_copies mc join (select distinct who, oracle_id from their_wants) o on o.oracle_id = mc.oracle_id
         left join t1_private.card_prices_usd pr on pr.card_id = mc.card_id)) m
  ), have_lines as (
    -- One line per copy (a copy split over two wants names the most specific one).
    select h.who, h.card_id, h.finish, h.condition, h.lang, sum(h.qty)::int qty, max(h.usd) usd,
           (array_agg(jsonb_build_object('oracle_id', h.w_oracle, 'card_id', h.w_card, 'finish', h.w_finish) order by h.tier))[1] want,
           coalesce(bool_or(h.max_usd is not null and h.usd > h.max_usd), false) over_max
      from have h group by 1, 2, 3, 4, 5
  ), want_lines as (
    select h.who, h.card_id, h.finish, h.condition, h.lang, h.binder_id, sum(h.qty)::int qty, max(h.usd) usd,
           (array_agg(jsonb_build_object('oracle_id', h.w_oracle, 'card_id', h.w_card, 'finish', h.w_finish) order by h.tier))[1] want
      from want h group by 1, 2, 3, 4, 5, 6
  ), per as (
    select p.uid, p.friend,
           coalesce((select sum(l.qty) from have_lines l where l.who = p.uid), 0) have_copies,
           coalesce((select sum(l.qty) from want_lines l where l.who = p.uid), 0) want_copies,
           coalesce((select sum(l.qty * l.usd) from have_lines l where l.who = p.uid and not l.over_max), 0) have_usd,
           coalesce((select sum(l.qty * l.usd) from want_lines l where l.who = p.uid), 0) want_usd
      from people p
  ), top as (
    select * from per where have_copies + want_copies > 0
     order by have_copies + want_copies desc, friend desc, uid limit 50
  )
  select coalesce(jsonb_agg(t1_private.person_json(t.uid) || jsonb_build_object(
           'friend', t.friend, 'have_copies', t.have_copies, 'want_copies', t.want_copies,
           'have_usd', round(t.have_usd, 2), 'want_usd', round(t.want_usd, 2),
           'they_have', coalesce((select jsonb_agg(jsonb_build_object('card_id', l.card_id, 'finish', l.finish,
                                    'condition', l.condition, 'lang', l.lang, 'qty', l.qty, 'want', l.want, 'usd', l.usd,
                                    'over_max', l.over_max) order by l.over_max, l.usd desc nulls last, l.card_id, l.finish)
                                  from (select * from have_lines l where l.who = t.uid
                                         order by l.over_max, l.usd desc nulls last, l.card_id, l.finish limit 200) l), '[]'::jsonb),
           'they_want', coalesce((select jsonb_agg(jsonb_build_object('card_id', l.card_id, 'finish', l.finish,
                                    'condition', l.condition, 'lang', l.lang, 'binder_id', l.binder_id, 'qty', l.qty,
                                    'want', l.want, 'usd', l.usd) order by l.usd desc nulls last, l.card_id, l.finish)
                                  from (select * from want_lines l where l.who = t.uid
                                         order by l.usd desc nulls last, l.card_id, l.finish limit 200) l), '[]'::jsonb))
         order by t.have_copies + t.want_copies desc, t.friend desc, t.uid), '[]'::jsonb)
    into v_people from top t;
  return jsonb_build_object('people', v_people, 'generated_at', now());
end $$;

-- ==================================================================== g_redraft
-- Most valuable first; cards with no market price last, then by name.
create or replace function public.redraft_list(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.in_event(p_event_id) then
    raise exception 'Only players in this event can see the redraft' using errcode = '42501';
  end if;
  return (
    with rows as (
      select r.id, r.card_id, r.finish, r.added_at, o.name, c.set_code, c.collector_number, c.image_ts, c.image_faces,
             case r.finish when 'foil' then pr.usd_foil when 'etched' then pr.usd_etched else pr.usd end as usd,
             coalesce(p.display_name, 'Organizer') as added_by_name, coalesce(r.added_by = auth.uid(), false) as mine
        from public.event_redraft_cards r
        join public.cards c on c.id = r.card_id
        join public.card_oracles o on o.oracle_id = c.oracle_id
        left join t1_private.card_prices_usd pr on pr.card_id = r.card_id
        left join public.participants p on p.event_id = r.event_id and p.user_id = r.added_by
       where r.event_id = p_event_id)
    select jsonb_build_object(
      'event_id', p_event_id,
      'count', count(*),
      'total_usd', coalesce(sum(usd), 0),
      'cards', coalesce(jsonb_agg(jsonb_build_object(
          'id', id, 'card_id', card_id, 'finish', finish, 'name', name, 'set', set_code, 'cn', collector_number,
          'image_ts', image_ts, 'image_faces', image_faces, 'usd', usd, 'added_by', added_by_name,
          'mine', mine, 'added_at', added_at)
        order by usd desc nulls last, name, added_at), '[]'::jsonb))
      from rows);
end $$;


-- ==================================================================== h_cron
-- The catalog sync starts 23:23 UTC; the fallback is rebuilt at 00:50, before the 01:07 library_revalue.
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-fx-rate') then
      perform cron.schedule('t1-fx-rate', '40 * * * *', 'select t1_private.fx_tick()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-price-fallback') then
      perform cron.schedule('t1-price-fallback', '50 0 * * *', 'select t1_private.card_price_fallback_refresh()');
    end if;
  end if;
end $$;

-- ==================================================================== i_grants
revoke execute on function t1_private.fx_tick() from public;
revoke execute on function t1_private.fx_parse_rate(text) from public;
revoke execute on function t1_private.fx_parse_day(text) from public;
revoke execute on function t1_private.card_price_fallback_refresh() from public;
revoke execute on function public.card_prices_get(uuid[]) from public, anon;
grant execute on function public.card_prices_get(uuid[]) to authenticated;

-- Convert now and revalue every collection, rather than tonight.
select t1_private.card_price_fallback_refresh();
select t1_private.library_revalue();
