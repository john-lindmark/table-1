-- Binders, "for trade" and wants (contract/binders-wants-2026-10-17.md, plan-binders-wants-2026-10-17.md).
-- The collection key is unchanged: an item is (card_id, finish, condition, lang) → qty. A binder holds an
-- allocation of an item's copies (binder_items); copies no binder holds are "Unsorted". Allocations change only
-- inside collection_apply_as, under the same per-account lock as item writes, with a binder_ledger row per change
-- in the same batch, so undo, idempotency and the audit trail work as for items. Invariant: an item's allocations
-- never add up to more than its qty. When copies go, the excess comes out of Unsorted first, then binders not for
-- trade, then for-trade binders (each by name), unless an op names the binder they come from.
-- Wants are one wishlist per account: (oracle, printing?, finish?) → qty with an optional max price.
-- Binders, allocations and wants sync by seq (the items' sequence) through library_changes.

-- ==================================================================== a_tables
alter table public.collection_batches drop constraint if exists collection_batches_source_check;
alter table public.collection_batches add constraint collection_batches_source_check
  check (source in ('manual', 'import', 'scan', 'trade', 'adjust', 'undo', 'binder', 'binder_delete', 'wants'));

-- Tombstone horizon for library_changes (binders, allocations, wants), like tombstone_floor for items.
alter table public.library_summary add column if not exists extras_floor bigint not null default 0;

create table if not exists public.binders (
  id uuid primary key,                          -- made by the client, so creating is idempotent
  user_id uuid not null,
  name text not null check (char_length(name) between 1 and 60),
  for_trade boolean not null default false,
  seq bigint not null,
  deleted_at timestamptz,                       -- tombstone; its copies went back to Unsorted
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists binders_user_name_idx on public.binders (user_id, lower(name)) where deleted_at is null;
create index if not exists binders_user_seq_idx on public.binders (user_id, seq);

create table if not exists public.binder_items (
  user_id uuid not null,
  binder_id uuid not null references public.binders(id) on delete cascade,
  card_id uuid not null,
  finish text not null,
  condition text not null,
  lang text not null,
  qty integer not null check (qty between 0 and 100000),   -- 0 = tombstone
  seq bigint not null,
  updated_at timestamptz not null default now(),
  primary key (binder_id, card_id, finish, condition, lang)
);
create index if not exists binder_items_user_seq_idx on public.binder_items (user_id, seq);
create index if not exists binder_items_item_idx on public.binder_items (user_id, card_id, finish, condition, lang) where qty > 0;
create index if not exists binder_items_tombstone_idx on public.binder_items (updated_at) where qty = 0;

create table if not exists public.binder_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  batch_id uuid not null references public.collection_batches(id) on delete cascade,
  binder_id uuid not null,
  card_id uuid not null,
  finish text not null,
  condition text not null,
  lang text not null,
  delta integer not null check (delta <> 0),
  qty_after integer not null,
  at timestamptz not null default now()
);
create index if not exists binder_ledger_batch_idx on public.binder_ledger (batch_id);
create index if not exists binder_ledger_user_card_idx on public.binder_ledger (user_id, card_id, id desc);

create table if not exists public.wants (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  oracle_id uuid not null,
  card_id uuid,                                 -- null: any printing
  finish text check (finish in ('nonfoil', 'foil', 'etched')),   -- null: any finish
  qty integer not null check (qty between 0 and 999),             -- 0 = tombstone
  max_usd numeric(10,2) check (max_usd >= 0),
  seq bigint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (finish is null or card_id is not null)
);
create unique index if not exists wants_key_idx on public.wants
  (user_id, oracle_id, coalesce(card_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(finish, ''));
create index if not exists wants_user_seq_idx on public.wants (user_id, seq);
create index if not exists wants_tombstone_idx on public.wants (updated_at) where qty = 0;

create table if not exists public.want_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  batch_id uuid not null references public.collection_batches(id) on delete cascade,
  oracle_id uuid not null,
  card_id uuid,
  finish text,
  delta integer not null check (delta <> 0),
  qty_after integer not null,
  at timestamptz not null default now()
);
create index if not exists want_ledger_batch_idx on public.want_ledger (batch_id);

do $$
declare t text;
begin
  foreach t in array array['binders', 'binder_items', 'binder_ledger', 'wants', 'want_ledger'] loop
    execute format('alter table public.%I enable row level security', t);
    if not exists (select 1 from pg_policies where tablename = t and policyname = t || '_own_read') then
      execute format('create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))',
                     t || '_own_read', t);
    end if;
    -- Writes only through the RPCs below (review S4: no client write grant to fall back on).
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ==================================================================== b_helpers
do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 't1_private' and t.typname = 'binder_change') then
    create type t1_private.binder_change as (
      binder_id uuid, card_id uuid, finish text, condition text, lang text, cur integer, new_qty integer);
  end if;
end $$;

create or replace function t1_private.binder_json(b public.binders)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('id', b.id, 'name', b.name, 'for_trade', b.for_trade, 'deleted', b.deleted_at is not null,
                            'seq', b.seq, 'created_at', b.created_at);
$$;

-- Writes allocation changes (rows where new_qty <> cur) and their ledger rows. Returns the changed rows as
-- [binder_id, card_id, finish, condition, lang, qty, seq]. Callers hold the account lock.
create or replace function t1_private.binder_write(p_uid uuid, p_batch uuid, p_changes t1_private.binder_change[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if p_changes is null or cardinality(p_changes) = 0 then return '[]'::jsonb; end if;
  with up as (
    insert into public.binder_items as bi (user_id, binder_id, card_id, finish, condition, lang, qty, seq)
    select p_uid, c.binder_id, c.card_id, c.finish, c.condition, c.lang, c.new_qty, nextval('public.collection_seq')
      from unnest(p_changes) c where c.new_qty <> c.cur
     order by c.binder_id, c.card_id, c.finish, c.condition, c.lang
    on conflict (binder_id, card_id, finish, condition, lang) do update
       set qty = excluded.qty, seq = excluded.seq, updated_at = now()
    returning bi.binder_id, bi.card_id, bi.finish, bi.condition, bi.lang, bi.qty, bi.seq
  )
  select coalesce(jsonb_agg(jsonb_build_array(binder_id, card_id, finish, condition, lang, qty, seq) order by seq), '[]'::jsonb)
    into v from up;
  insert into public.binder_ledger (user_id, batch_id, binder_id, card_id, finish, condition, lang, delta, qty_after)
  select p_uid, p_batch, c.binder_id, c.card_id, c.finish, c.condition, c.lang, c.new_qty - c.cur, c.new_qty
    from unnest(p_changes) c where c.new_qty <> c.cur;
  return v;
end $$;

-- Takes the account lock: every write to a user's collection, binders and wants is serialized on this row,
-- so per account seq only grows in commit order (what the delta syncs rely on).
create or replace function t1_private.library_lock(p_uid uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.library_summary (user_id) values (p_uid) on conflict do nothing;
  perform 1 from public.library_summary where user_id = p_uid for update;
end $$;

-- ==================================================================== c_apply
-- The one write path for items and allocations. p_ops: [{card_id, finish?='nonfoil', condition?='NM', lang?='en',
-- delta? | qty?, binder_id?}]. binder_id goes with a delta: added copies go into that binder; removed copies come
-- out of it first. After the items change, any item whose allocations exceed its qty gives the excess back from
-- binders not for trade, then for-trade binders (by name); Unsorted copies are always the first to go because they
-- are what's left over. Source 'undo' ignores binders that are gone; other sources reject them.
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
           t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, pr.eur, pr.eur_foil, a.finish, 'usd'),
           t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, pr.eur, pr.eur_foil, a.finish, 'eur')
         )::t1_private.collection_change)
    into v_plan
    from agg a
    left join public.cards c on c.id = a.card_id
    left join public.card_oracles o on o.oracle_id = c.oracle_id
    left join public.card_prices pr on pr.card_id = a.card_id
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

-- 'undo' and 'binder' are internal sources (collection_undo, binder_move).
create or replace function public.collection_apply(
  p_ops jsonb, p_source text default 'manual', p_source_id uuid default null, p_idempotency_key uuid default null)
returns jsonb language sql security definer set search_path = '' as $$
  select t1_private.collection_apply_as(auth.uid(),
           p_ops, case when p_source in ('undo', 'binder') then null else p_source end, p_source_id, p_idempotency_key);
$$;

-- ==================================================================== d_wants
-- Applies want changes: [{oracle_id? | card_id, finish?, qty | delta, max_usd?}]. A want with no card_id is any
-- printing; finish needs a card_id. qty sets the count (0 removes), delta adds or takes (never below 0);
-- max_usd present sets the price ceiling (null clears it). Writes want_ledger rows under p_batch.
-- Returns the changed wants as [oracle_id, card_id, finish, qty, max_usd, seq]. Callers hold the account lock.
create or replace function t1_private.wants_apply_as(p_uid uuid, p_batch uuid, p_ops jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_plan jsonb;
  v_bad text;
  v_out jsonb;
begin
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) = 0 then
    raise exception 'Nothing to change' using errcode = '22023';
  end if;
  if jsonb_array_length(p_ops) > 5000 then raise exception 'At most 5000 changes per batch' using errcode = '22023'; end if;
  with ops as (
    select o.oracle_id, o.card_id, nullif(o.finish, '') finish, o.delta, o.qty,
           (e ? 'max_usd') has_max, case when jsonb_typeof(e->'max_usd') = 'number' then (e->>'max_usd')::numeric end max_usd
      from jsonb_array_elements(p_ops) e
      cross join lateral jsonb_to_record(e) o (oracle_id uuid, card_id uuid, finish text, delta integer, qty integer)
  ), r as (
    select coalesce(c.oracle_id, ops.oracle_id) oracle_id, ops.card_id, ops.finish, ops.delta, ops.qty, ops.has_max,
           ops.max_usd, c.finishes, (ops.card_id is not null and c.id is null) unknown_card,
           (ops.card_id is null and not exists (select 1 from public.card_oracles co where co.oracle_id = ops.oracle_id)) unknown_oracle
      from ops left join public.cards c on c.id = ops.card_id
  ), agg as (
    select oracle_id, card_id, finish, count(qty)::int n_set, count(delta)::int n_delta, max(qty) set_qty,
           coalesce(sum(delta), 0)::int sum_delta, bool_or(has_max) has_max, max(max_usd) max_usd,
           bool_or(unknown_card or unknown_oracle or oracle_id is null) unknown,
           bool_or(finish is not null and (card_id is null or not (finish = any (finishes)))) bad_finish
      from r group by 1, 2, 3
  )
  select jsonb_agg(jsonb_build_object(
           'oracle_id', a.oracle_id, 'card_id', a.card_id, 'finish', a.finish, 'n_set', a.n_set, 'n_delta', a.n_delta,
           'unknown', a.unknown, 'bad_finish', a.bad_finish, 'cur', coalesce(w.qty, 0), 'exists', w.id is not null,
           'new', least(999, greatest(0, case when a.n_set > 0 then a.set_qty else coalesce(w.qty, 0) + a.sum_delta end)),
           'set_qty', a.set_qty, 'cur_max', w.max_usd, 'new_max', case when a.has_max then a.max_usd else w.max_usd end))
    into v_plan
    from agg a
    left join public.wants w on w.user_id = p_uid and w.oracle_id = a.oracle_id
                            and w.card_id is not distinct from a.card_id and w.finish is not distinct from a.finish;

  if exists (select 1 from jsonb_array_elements(v_plan) p where (p->>'unknown')::boolean) then
    raise exception 'Unknown card in wants' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(v_plan) p where (p->>'bad_finish')::boolean) then
    raise exception 'A finish needs a printing that comes in it' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(v_plan) p
              where (p->>'n_set')::int > 1 or ((p->>'n_set')::int > 0 and (p->>'n_delta')::int > 0)) then
    raise exception 'Set a quantity or add copies, not both, for one want' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(v_plan) p
              where (p->>'set_qty')::int not between 0 and 999 or (p->>'new_max')::numeric not between 0 and 99999999) then
    raise exception 'A want is 0 to 999 copies, with a max price of 0 or more' using errcode = '22023';
  end if;

  with p as (
    select (e->>'oracle_id')::uuid oracle_id, (e->>'card_id')::uuid card_id, e->>'finish' finish, (e->>'cur')::int cur,
           (e->>'new')::int new_qty, (e->>'new_max')::numeric new_max, (e->>'cur_max')::numeric cur_max,
           (e->>'exists')::boolean had
      from jsonb_array_elements(v_plan) e
  ), ch as (
    select * from p where (new_qty, new_max) is distinct from (cur, cur_max) and (had or new_qty > 0)
  ), up as (
    insert into public.wants as w (user_id, oracle_id, card_id, finish, qty, max_usd, seq)
    select p_uid, ch.oracle_id, ch.card_id, ch.finish, ch.new_qty, ch.new_max, nextval('public.collection_seq') from ch
    on conflict (user_id, oracle_id, coalesce(card_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(finish, ''))
    do update set qty = excluded.qty, max_usd = excluded.max_usd, seq = excluded.seq, updated_at = now()
    returning w.oracle_id, w.card_id, w.finish, w.qty, w.max_usd, w.seq
  ), led as (
    insert into public.want_ledger (user_id, batch_id, oracle_id, card_id, finish, delta, qty_after)
    select p_uid, p_batch, ch.oracle_id, ch.card_id, ch.finish, ch.new_qty - ch.cur, ch.new_qty from ch where ch.new_qty <> ch.cur
  )
  select coalesce(jsonb_agg(jsonb_build_array(oracle_id, card_id, finish, qty, max_usd, seq) order by seq), '[]'::jsonb)
    into v_out from up;

  if (select count(*) from public.wants where user_id = p_uid and qty > 0) > 5000 then
    raise exception 'At most 5000 wants' using errcode = '53400';
  end if;
  return v_out;
end $$;

-- One wishlist edit (a batch with source 'wants'). Same key = {duplicate: true}.
create or replace function public.wants_apply(p_ops jsonb, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_key uuid := coalesce(p_idempotency_key, gen_random_uuid());
  v_batch public.collection_batches;
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'Sign in to change your wants' using errcode = '28000'; end if;
  perform t1_private.library_lock(v_uid);
  select * into v_batch from public.collection_batches where id = v_key;
  if v_batch.id is not null then
    if v_batch.user_id <> v_uid then raise exception 'Batch id already used' using errcode = '23505'; end if;
    return jsonb_build_object('batch_id', v_key, 'duplicate', true, 'wants', '[]'::jsonb);
  end if;
  if (select count(*) from public.collection_batches
       where user_id = v_uid and created_at > now() - interval '1 minute') >= 120 then
    raise exception 'Too many changes, try again in a moment' using errcode = '53400';
  end if;
  insert into public.collection_batches (id, user_id, source, ops)
  values (v_key, v_uid, 'wants', coalesce(jsonb_array_length(case when jsonb_typeof(p_ops) = 'array' then p_ops end), 0));
  v_rows := t1_private.wants_apply_as(v_uid, v_key, p_ops);
  update public.collection_batches set changes = jsonb_array_length(v_rows) where id = v_key;
  return jsonb_build_object('batch_id', v_key, 'duplicate', false, 'wants', v_rows);
end $$;

-- ==================================================================== e_binders
-- Creates (new id) or renames / flags a binder. Calling again with the same id and values changes nothing.
create or replace function public.binder_save(p_id uuid, p_name text default null, p_for_trade boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v public.binders;
  v_name text := nullif(left(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), 60), '');
begin
  if v_uid is null then raise exception 'Sign in to sort your collection' using errcode = '28000'; end if;
  if p_id is null then raise exception 'A binder needs an id' using errcode = '22023'; end if;
  perform t1_private.library_lock(v_uid);
  select * into v from public.binders where id = p_id;
  if v.id is not null and v.user_id <> v_uid then raise exception 'That binder isn''t yours' using errcode = '42501'; end if;
  if v.deleted_at is not null then raise exception 'That binder was deleted' using errcode = 'P0002'; end if;
  if v.id is null then
    if v_name is null then raise exception 'Name the binder' using errcode = '22023'; end if;
    if (select count(*) from public.binders where user_id = v_uid and deleted_at is null) >= 200 then
      raise exception 'At most 200 binders' using errcode = '53400';
    end if;
    if exists (select 1 from public.binders where user_id = v_uid and deleted_at is null and lower(name) = lower(v_name)) then
      raise exception 'You already have a binder called %', v_name using errcode = '23505';
    end if;
    insert into public.binders (id, user_id, name, for_trade, seq)
    values (p_id, v_uid, v_name, coalesce(p_for_trade, false), nextval('public.collection_seq'))
    returning * into v;
  else
    v_name := coalesce(v_name, v.name);
    if lower(v_name) <> lower(v.name) and exists (select 1 from public.binders where user_id = v_uid
         and deleted_at is null and lower(name) = lower(v_name) and id <> v.id) then
      raise exception 'You already have a binder called %', v_name using errcode = '23505';
    end if;
    if (v_name, coalesce(p_for_trade, v.for_trade)) is distinct from (v.name, v.for_trade) then
      update public.binders set name = v_name, for_trade = coalesce(p_for_trade, for_trade),
                                seq = nextval('public.collection_seq'), updated_at = now()
       where id = v.id returning * into v;
    end if;
  end if;
  return t1_private.binder_json(v);
end $$;

-- Deletes a binder; its copies go back to Unsorted (one batch, source 'binder_delete', ledgered, not undoable).
-- Deleting one that's already deleted returns it with duplicate: true.
create or replace function public.binder_delete(p_id uuid, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_key uuid := coalesce(p_idempotency_key, gen_random_uuid());
  v public.binders;
  v_changes t1_private.binder_change[];
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'Sign in to sort your collection' using errcode = '28000'; end if;
  perform t1_private.library_lock(v_uid);
  select * into v from public.binders where id = p_id;
  if v.id is null then raise exception 'That binder is gone' using errcode = 'P0002'; end if;
  if v.user_id <> v_uid then raise exception 'That binder isn''t yours' using errcode = '42501'; end if;
  if v.deleted_at is not null then
    return jsonb_build_object('duplicate', true, 'binder', t1_private.binder_json(v), 'binder_items', '[]'::jsonb);
  end if;
  if exists (select 1 from public.collection_batches where id = v_key) then
    raise exception 'Batch id already used' using errcode = '23505';
  end if;
  select array_agg(row(bi.binder_id, bi.card_id, bi.finish, bi.condition, bi.lang, bi.qty, 0)::t1_private.binder_change)
    into v_changes
    from public.binder_items bi where bi.binder_id = p_id and bi.qty > 0;
  insert into public.collection_batches (id, user_id, source, source_id, ops, changes)
  values (v_key, v_uid, 'binder_delete', p_id, coalesce(cardinality(v_changes), 0), coalesce(cardinality(v_changes), 0));
  v_rows := t1_private.binder_write(v_uid, v_key, v_changes);
  update public.binders set deleted_at = now(), seq = nextval('public.collection_seq'), updated_at = now()
   where id = p_id returning * into v;
  return jsonb_build_object('batch_id', v_key, 'duplicate', false, 'binder', t1_private.binder_json(v), 'binder_items', v_rows);
end $$;

-- Moves copies between binders and Unsorted: [{card_id, finish?, condition?, lang?, from (binder id | null =
-- Unsorted), to (binder id | null), qty}], up to 2500. Strict: the whole call is refused if a source holds fewer
-- copies than asked. It's a collection batch (source 'binder') whose item quantities don't change, so the same key
-- replays as a duplicate and collection_undo moves them back.
create or replace function public.binder_move(p_moves jsonb, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_key uuid := coalesce(p_idempotency_key, gen_random_uuid());
  v_m jsonb;
  v_ops jsonb;
  v_bad text;
begin
  if v_uid is null then raise exception 'Sign in to sort your collection' using errcode = '28000'; end if;
  perform t1_private.library_lock(v_uid);
  if exists (select 1 from public.collection_batches where id = v_key) then
    return t1_private.collection_apply_as(v_uid, '[{}]'::jsonb, 'binder', null, v_key);
  end if;
  if p_moves is null or jsonb_typeof(p_moves) <> 'array' or jsonb_array_length(p_moves) = 0 then
    raise exception 'Nothing to move' using errcode = '22023';
  end if;
  if jsonb_array_length(p_moves) > 2500 then raise exception 'At most 2500 moves per call' using errcode = '22023'; end if;

  select jsonb_agg(jsonb_build_object('card_id', m.card_id, 'finish', coalesce(nullif(m.finish, ''), 'nonfoil'),
           'condition', upper(coalesce(nullif(m.condition, ''), 'NM')), 'lang', lower(coalesce(nullif(m.lang, ''), 'en')),
           'src', m."from", 'dst', m."to", 'qty', m.qty))
    into v_m
    from jsonb_to_recordset(p_moves) m (card_id uuid, finish text, condition text, lang text, "from" uuid, "to" uuid, qty integer);

  if exists (select 1 from jsonb_to_recordset(v_m) m (card_id uuid, src uuid, dst uuid, qty integer)
              where m.card_id is null or coalesce(m.qty, 0) < 1 or m.src is not distinct from m.dst) then
    raise exception 'Each move needs a card, a quantity of 1 or more, and two different places' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_to_recordset(v_m) m (src uuid, dst uuid), lateral (values (m.src), (m.dst)) b (id)
              where b.id is not null and not exists (select 1 from public.binders x
                    where x.id = b.id and x.user_id = v_uid and x.deleted_at is null)) then
    raise exception 'That binder is gone' using errcode = 'P0002';
  end if;
  -- What each source holds now: a binder's allocation, or Unsorted (copies minus every allocation).
  select string_agg(coalesce(o.name, s.card_id::text), ', ') into v_bad from (
    select m.card_id, m.finish, m.condition, m.lang, m.src, sum(m.qty) want,
           case when m.src is null
                then coalesce((select i.qty from public.collection_items i where i.user_id = v_uid and i.card_id = m.card_id
                                  and i.finish = m.finish and i.condition = m.condition and i.lang = m.lang), 0)
                   - coalesce((select sum(bi.qty) from public.binder_items bi where bi.user_id = v_uid and bi.card_id = m.card_id
                                  and bi.finish = m.finish and bi.condition = m.condition and bi.lang = m.lang), 0)
                else coalesce((select bi.qty from public.binder_items bi where bi.binder_id = m.src and bi.card_id = m.card_id
                                  and bi.finish = m.finish and bi.condition = m.condition and bi.lang = m.lang), 0) end have
      from jsonb_to_recordset(v_m) m (card_id uuid, finish text, condition text, lang text, src uuid, qty integer)
     group by 1, 2, 3, 4, 5) s
    left join public.cards c on c.id = s.card_id
    left join public.card_oracles o on o.oracle_id = c.oracle_id
   where s.want > s.have;
  if v_bad is not null then raise exception 'Not that many copies there: %', v_bad using errcode = '22023'; end if;

  select jsonb_agg(o) into v_ops from (
    select jsonb_strip_nulls((e - 'src' - 'dst' - 'qty') || jsonb_build_object('delta', -(e->>'qty')::int, 'binder_id', e->'src')) o
      from jsonb_array_elements(v_m) e
    union all
    select jsonb_strip_nulls((e - 'src' - 'dst' - 'qty') || jsonb_build_object('delta', (e->>'qty')::int, 'binder_id', e->'dst'))
      from jsonb_array_elements(v_m) e) x;
  return t1_private.collection_apply_as(v_uid, v_ops, 'binder', null, v_key);
end $$;

-- ==================================================================== f_undo
-- Reverses one earlier batch: its item changes, the binder allocations it made or shrank, and the wants a trade
-- satisfied. Per item, the undo puts each binder's copies back where they were, and the rest goes to or comes out
-- of Unsorted. Binder deletions and wishlist edits aren't undone this way.
create or replace function public.collection_undo(p_batch_id uuid, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_batch public.collection_batches;
  v_ops jsonb;
  v_wops jsonb;
  v_res jsonb;
begin
  if v_uid is null then raise exception 'Sign in to change your collection' using errcode = '28000'; end if;
  if p_idempotency_key is not null
     and exists (select 1 from public.collection_batches where id = p_idempotency_key and user_id = v_uid) then
    return t1_private.collection_apply_as(v_uid, '[{}]'::jsonb, 'undo', p_batch_id, p_idempotency_key);
  end if;
  perform t1_private.library_lock(v_uid);
  select * into v_batch from public.collection_batches where id = p_batch_id and user_id = v_uid for update;
  if v_batch.id is null then raise exception 'Nothing to undo' using errcode = 'P0002'; end if;
  if v_batch.source = 'undo' then raise exception 'An undo can''t be undone' using errcode = '22023'; end if;
  if v_batch.source = 'binder_delete' then raise exception 'Deleting a binder can''t be undone' using errcode = '22023'; end if;
  if v_batch.source = 'wants' then raise exception 'Change the want instead' using errcode = '22023'; end if;
  if v_batch.undone_by is not null then raise exception 'Already undone' using errcode = '22023'; end if;

  with item as (
    select card_id, finish, condition, lang, sum(delta)::int d from public.collection_ledger
     where batch_id = p_batch_id group by 1, 2, 3, 4
  ), bind as (
    select binder_id, card_id, finish, condition, lang, sum(delta)::int bd from public.binder_ledger
     where batch_id = p_batch_id group by 1, 2, 3, 4, 5 having sum(delta) <> 0
  ), keys as (
    select card_id, finish, condition, lang from item union select card_id, finish, condition, lang from bind
  ), rest as (
    select k.card_id, k.finish, k.condition, k.lang,
           -coalesce(i.d, 0) + coalesce((select sum(b.bd) from bind b where b.card_id = k.card_id and b.finish = k.finish
                                          and b.condition = k.condition and b.lang = k.lang), 0)::int r
      from keys k left join item i on i.card_id = k.card_id and i.finish = k.finish
                                  and i.condition = k.condition and i.lang = k.lang
  )
  select jsonb_agg(o) into v_ops from (
    select jsonb_build_object('card_id', card_id, 'finish', finish, 'condition', condition, 'lang', lang,
                              'delta', -bd, 'binder_id', binder_id) o from bind
    union all
    select jsonb_build_object('card_id', card_id, 'finish', finish, 'condition', condition, 'lang', lang, 'delta', r)
      from rest where r <> 0) x;
  if v_ops is null then raise exception 'Nothing to undo' using errcode = 'P0002'; end if;

  v_res := t1_private.collection_apply_as(v_uid, v_ops, 'undo', p_batch_id, p_idempotency_key);
  update public.collection_batches set undone_by = (v_res->>'batch_id')::uuid where id = p_batch_id;

  select jsonb_agg(jsonb_build_object('oracle_id', oracle_id, 'card_id', card_id, 'finish', finish, 'delta', -d))
    into v_wops
    from (select oracle_id, card_id, finish, sum(delta)::int d from public.want_ledger where batch_id = p_batch_id
           group by 1, 2, 3 having sum(delta) <> 0) w;
  return v_res || jsonb_build_object('wants',
    case when v_wops is null then '[]'::jsonb
         else t1_private.wants_apply_as(v_uid, (v_res->>'batch_id')::uuid, v_wops) end);
end $$;

-- ==================================================================== g_trades
-- Trade lines may carry binder_id: where a give's copies come from, where a get's copies go.
create or replace function t1_private.trade_side(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare v jsonb;
begin
  if p is null then return '[]'::jsonb; end if;
  if jsonb_typeof(p) <> 'array' then raise exception 'A trade side must be an array' using errcode = '22023'; end if;
  if jsonb_array_length(p) > 500 then raise exception 'At most 500 lines per side' using errcode = '22023'; end if;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'card_id', l.card_id, 'finish', coalesce(nullif(l.finish, ''), 'nonfoil'),
           'condition', upper(coalesce(nullif(l.condition, ''), 'NM')), 'lang', lower(coalesce(nullif(l.lang, ''), 'en')),
           'qty', l.qty, 'binder_id', l.binder_id))), '[]'::jsonb)
    into v
    from jsonb_to_recordset(p) l (card_id uuid, finish text, condition text, lang text, qty integer, binder_id uuid);
  if exists (select 1 from jsonb_array_elements(v) e
              where e->>'card_id' is null or coalesce((e->>'qty')::int, 0) < 1 or (e->>'qty')::int > 10000) then
    raise exception 'Every trade line needs a card and a quantity of 1 or more' using errcode = '22023';
  end if;
  return v;
end $$;

-- Applies a draft to the collection (one batch), then takes what it gets off your wants: an exact printing and
-- finish first, then that printing in any finish, then any printing. Undo puts both back.
create or replace function public.trade_confirm(p_trade_id uuid, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v public.trades;
  v_ops jsonb;
  v_res jsonb;
  v_batch uuid;
  v_line record;
  v_want record;
  v_left integer;
  v_wops jsonb;
  v_wants jsonb := '[]'::jsonb;
begin
  if v_uid is null then raise exception 'Sign in to trade' using errcode = '28000'; end if;
  select * into v from public.trades where id = p_trade_id and user_id = v_uid for update;
  if v.id is null then raise exception 'That trade is gone' using errcode = 'P0002'; end if;
  if v.status = 'confirmed' then
    if p_idempotency_key is not null and v.batch_id = p_idempotency_key then
      return jsonb_build_object('trade', to_jsonb(v) - 'user_id', 'duplicate', true);
    end if;
    raise exception 'That trade is already confirmed' using errcode = '22023';
  end if;
  -- A binder deleted since the draft was saved just drops out (the copies come from / go to the usual place).
  select jsonb_agg(o) into v_ops from (
    select jsonb_strip_nulls(jsonb_build_object('card_id', e->>'card_id', 'finish', e->>'finish',
             'condition', e->>'condition', 'lang', e->>'lang', 'delta', dir * (e->>'qty')::int,
             'binder_id', (select b.id from public.binders b where b.id = (e->>'binder_id')::uuid
                              and b.user_id = v_uid and b.deleted_at is null))) o
      from (select e, -1 dir from jsonb_array_elements(v.gives) e
            union all select e, 1 from jsonb_array_elements(v.gets) e) s) s;
  if v_ops is null then raise exception 'Add cards to the trade first' using errcode = '22023'; end if;

  v_res := t1_private.collection_apply_as(v_uid, v_ops, 'trade', v.id, coalesce(p_idempotency_key, gen_random_uuid()));
  v_batch := (v_res->>'batch_id')::uuid;
  update public.trades
     set status = 'confirmed', confirmed_at = now(), updated_at = now(), batch_id = v_batch
   where id = v.id
  returning * into v;

  if not coalesce((v_res->>'duplicate')::boolean, false) then
    for v_line in
      select c.oracle_id, l.card_id, l.finish, sum(l.qty)::int qty
        from jsonb_to_recordset(v.gets) l (card_id uuid, finish text, qty integer)
        join public.cards c on c.id = l.card_id
       group by 1, 2, 3 order by 2, 3
    loop
      v_left := v_line.qty;
      v_wops := '[]'::jsonb;
      for v_want in
        select w.card_id, w.finish, w.qty from public.wants w
         where w.user_id = v_uid and w.oracle_id = v_line.oracle_id and w.qty > 0
           and (w.card_id is null or (w.card_id = v_line.card_id and (w.finish is null or w.finish = v_line.finish)))
         order by case when w.card_id is null then 2 when w.finish is null then 1 else 0 end
      loop
        exit when v_left <= 0;
        v_wops := v_wops || jsonb_build_array(jsonb_build_object('oracle_id', v_line.oracle_id, 'card_id', v_want.card_id,
                    'finish', v_want.finish, 'delta', -least(v_left, v_want.qty)));
        v_left := v_left - least(v_left, v_want.qty);
      end loop;
      if jsonb_array_length(v_wops) > 0 then
        v_wants := v_wants || t1_private.wants_apply_as(v_uid, v_batch, v_wops);
      end if;
    end loop;
  end if;
  return v_res || jsonb_build_object('trade', to_jsonb(v) - 'user_id', 'wants', v_wants);
end $$;

-- ==================================================================== h_sync
-- Delta sync for binders, allocations and wants, oldest first: binders [{id, name, for_trade, deleted, seq}]
-- changed after p_after; binder_items [[binder_id, card_id, finish, condition, lang, qty, seq]] and
-- wants [[oracle_id, card_id, finish, qty, max_usd, seq]] paged together by seq (qty 0 = gone).
-- resync = true: drop the local copy and start from 0.
create or replace function public.library_changes(p_after bigint default 0, p_limit integer default 5000)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_after bigint := coalesce(p_after, 0);
  v_lim integer := least(greatest(coalesce(p_limit, 5000), 1), 10000);
  v_floor bigint;
  v_binders jsonb;
  v_bseq bigint;
  v_items jsonb;
  v_wants jsonb;
  v_n integer;
  v_last bigint;
begin
  if v_uid is null then raise exception 'Sign in to see your collection' using errcode = '28000'; end if;
  select extras_floor into v_floor from public.library_summary where user_id = v_uid;
  if v_after > 0 and v_after < coalesce(v_floor, 0) then
    return jsonb_build_object('resync', true, 'binders', '[]'::jsonb, 'binder_items', '[]'::jsonb, 'wants', '[]'::jsonb,
                              'next', 0, 'more', false);
  end if;
  select coalesce(jsonb_agg(t1_private.binder_json(b) order by b.seq), '[]'::jsonb), max(b.seq)
    into v_binders, v_bseq
    from public.binders b where b.user_id = v_uid and b.seq > v_after;
  select coalesce(jsonb_agg(r.j order by r.seq) filter (where r.k = 'b'), '[]'::jsonb),
         coalesce(jsonb_agg(r.j order by r.seq) filter (where r.k = 'w'), '[]'::jsonb),
         count(*), max(r.seq)
    into v_items, v_wants, v_n, v_last
    from ((select 'b' k, bi.seq, jsonb_build_array(bi.binder_id, bi.card_id, bi.finish, bi.condition, bi.lang, bi.qty, bi.seq) j
             from public.binder_items bi where bi.user_id = v_uid and bi.seq > v_after order by bi.seq limit v_lim)
          union all
          (select 'w', w.seq, jsonb_build_array(w.oracle_id, w.card_id, w.finish, w.qty, w.max_usd, w.seq)
             from public.wants w where w.user_id = v_uid and w.seq > v_after order by w.seq limit v_lim)
          order by 2 limit v_lim) r;
  return jsonb_build_object('resync', false, 'binders', v_binders, 'binder_items', v_items, 'wants', v_wants,
    'next', case when v_n = v_lim then v_last else greatest(v_after, coalesce(v_last, 0), coalesce(v_bseq, 0)) end,
    'more', v_n = v_lim);
end $$;

-- ==================================================================== i_jobs
-- Tombstones older than 30 days go (items as before; allocations, wants and deleted binders too), and each
-- affected user's floors move up to the newest purged seq.
create or replace function t1_private.library_purge_tombstones()
returns void language plpgsql security definer set search_path = '' as $$
begin
  with gone as (
    delete from public.collection_items
     where qty = 0 and updated_at < now() - interval '30 days'
    returning user_id, seq
  )
  update public.library_summary s set tombstone_floor = greatest(s.tombstone_floor, g.max_seq)
    from (select user_id, max(seq) max_seq from gone group by user_id) g
   where s.user_id = g.user_id;

  with g1 as (
    delete from public.binder_items where qty = 0 and updated_at < now() - interval '30 days' returning user_id, seq
  ), g2 as (
    delete from public.wants where qty = 0 and updated_at < now() - interval '30 days' returning user_id, seq
  ), gone as (
    select * from g1 union all select * from g2
  )
  update public.library_summary s set extras_floor = greatest(s.extras_floor, g.max_seq)
    from (select user_id, max(seq) max_seq from gone group by user_id) g
   where s.user_id = g.user_id;

  with gone as (
    delete from public.binders b where b.deleted_at < now() - interval '30 days'
       and not exists (select 1 from public.binder_items bi where bi.binder_id = b.id and bi.qty > 0)
    returning user_id, seq
  )
  update public.library_summary s set extras_floor = greatest(s.extras_floor, g.max_seq)
    from (select user_id, max(seq) max_seq from gone group by user_id) g
   where s.user_id = g.user_id;
end $$;

-- ==================================================================== j_grants
revoke execute on function t1_private.collection_apply_as(uuid, jsonb, text, uuid, uuid) from public;
revoke execute on function t1_private.binder_write(uuid, uuid, t1_private.binder_change[]) from public;
revoke execute on function t1_private.binder_json(public.binders) from public;
revoke execute on function t1_private.library_lock(uuid) from public;
revoke execute on function t1_private.wants_apply_as(uuid, uuid, jsonb) from public;
revoke execute on function t1_private.library_purge_tombstones() from public;
revoke execute on function t1_private.trade_side(jsonb) from public;
do $$
declare f text;
begin
  foreach f in array array[
    'collection_apply(jsonb, text, uuid, uuid)', 'collection_undo(uuid, uuid)', 'trade_confirm(uuid, uuid)',
    'wants_apply(jsonb, uuid)', 'binder_save(uuid, text, boolean)', 'binder_delete(uuid, uuid)',
    'binder_move(jsonb, uuid)', 'library_changes(bigint, integer)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ==================================================================== k_delete_account
-- Account deletion also removes binders and wants (personal records).
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  perform public.demo_remove();
  update public.profiles
     set handle = null, display_name = 'Deleted player', avatar_url = null,
         deleted_at = now(), updated_at = now()
   where id = v_uid;
  update public.participants set display_name = 'Deleted player' where user_id = v_uid;
  delete from public.devices where user_id = v_uid;
  delete from public.notification_prefs where user_id = v_uid;
  delete from public.presence_cells where user_id = v_uid;
  delete from public.event_invites where user_id = v_uid and status = 'pending';
  delete from public.trades where user_id = v_uid;
  delete from public.want_ledger where user_id = v_uid;
  delete from public.wants where user_id = v_uid;
  delete from public.binder_ledger where user_id = v_uid;
  delete from public.binder_items where user_id = v_uid;
  delete from public.binders where user_id = v_uid;
  delete from public.collection_ledger where user_id = v_uid;
  delete from public.collection_batches where user_id = v_uid;
  delete from public.collection_items where user_id = v_uid;
  delete from public.card_lists where user_id = v_uid;   -- versions and entries cascade
  delete from public.library_summary where user_id = v_uid;
  update public.scan_reports set user_id = null where user_id = v_uid;
end $$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
