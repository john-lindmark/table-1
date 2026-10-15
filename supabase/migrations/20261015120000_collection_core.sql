-- L1 collection core (plan-collection-2026-10-14.md §4).
-- collection_items is the current state (qty per printing × finish × condition × language). Every change goes
-- through collection_apply, which writes the item rows, one append-only ledger row per change, one batch row
-- (the idempotency key; also what an undo reverses) and the per-user library_summary, in one transaction.
-- Clients sync by `seq`: each changed row takes a new value from a global sequence, and a user's writes are
-- serialized on their library_summary row, so per user seq only grows, in commit order.
-- Rows that drop to qty 0 stay as tombstones so deltas carry deletions; t1_private.library_purge_tombstones
-- removes old ones and raises the user's tombstone_floor (a client behind the floor resyncs from 0).
-- The ledger is the audit trail for collection changes (audit_log is event-scoped).

-- ==================================================================== a_tables
create sequence if not exists public.collection_seq;

create table if not exists public.collection_items (
  user_id uuid not null,
  card_id uuid not null references public.cards(id),
  finish text not null check (finish in ('nonfoil', 'foil', 'etched')),
  condition text not null default 'NM' check (condition in ('NM', 'LP', 'MP', 'HP', 'DMG')),
  lang text not null default 'en' check (lang ~ '^[a-z]{2,3}$'),
  qty integer not null check (qty between 0 and 100000),   -- 0 = tombstone
  seq bigint not null,
  added_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, card_id, finish, condition, lang)
);
create index if not exists collection_items_user_seq_idx on public.collection_items (user_id, seq);
create index if not exists collection_items_card_idx on public.collection_items (card_id);
create index if not exists collection_items_tombstone_idx on public.collection_items (updated_at) where qty = 0;

create table if not exists public.collection_batches (
  id uuid primary key,                         -- the client's idempotency key
  user_id uuid not null,
  source text not null check (source in ('manual', 'import', 'scan', 'trade', 'adjust', 'undo')),
  source_id uuid,                              -- import / trade id, or the batch an undo reversed
  ops integer not null,
  changes integer not null default 0,
  seq_max bigint,
  undone_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists collection_batches_user_idx on public.collection_batches (user_id, created_at desc);

create table if not exists public.collection_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  batch_id uuid not null references public.collection_batches(id) on delete cascade,
  card_id uuid not null,
  finish text not null,
  condition text not null,
  lang text not null,
  delta integer not null check (delta <> 0),
  qty_after integer not null,
  at timestamptz not null default now()
);
create index if not exists collection_ledger_user_card_idx on public.collection_ledger (user_id, card_id, id desc);
create index if not exists collection_ledger_batch_idx on public.collection_ledger (batch_id);

-- The Library top level reads this one row. collection_apply keeps it current; values are also recomputed
-- set-based after each night's price sync (t1_private.library_revalue).
create table if not exists public.library_summary (
  user_id uuid primary key,
  total_qty bigint not null default 0,
  unique_printings integer not null default 0,
  unique_cards integer not null default 0,     -- distinct Oracle cards with qty > 0
  value_usd numeric(14,2) not null default 0,
  value_eur numeric(14,2) not null default 0,
  seq bigint not null default 0,               -- highest seq among this user's rows
  tombstone_floor bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.collection_items enable row level security;
alter table public.collection_batches enable row level security;
alter table public.collection_ledger enable row level security;
alter table public.library_summary enable row level security;
-- Read your own rows; writes only through the RPCs below.
do $$
declare t text;
begin
  foreach t in array array['collection_items', 'collection_batches', 'collection_ledger', 'library_summary'] loop
    if not exists (select 1 from pg_policies where tablename = t and policyname = t || '_own_read') then
      execute format('create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))',
                     t || '_own_read', t);
    end if;
  end loop;
end $$;

-- ==================================================================== b_helpers
-- Price of one copy in a finish. Scryfall has no etched EUR price, so etched uses the foil EUR price.
create or replace function t1_private.unit_price(
  p_usd numeric, p_usd_foil numeric, p_usd_etched numeric, p_eur numeric, p_eur_foil numeric,
  p_finish text, p_currency text)
returns numeric language sql immutable set search_path = '' as $$
  select case p_currency
           when 'usd' then case p_finish when 'foil' then p_usd_foil when 'etched' then p_usd_etched else p_usd end
           else case p_finish when 'nonfoil' then p_eur else p_eur_foil end
         end;
$$;

create or replace function t1_private.summary_json(s public.library_summary)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'total_qty', coalesce(s.total_qty, 0), 'unique_printings', coalesce(s.unique_printings, 0),
    'unique_cards', coalesce(s.unique_cards, 0), 'value_usd', coalesce(s.value_usd, 0),
    'value_eur', coalesce(s.value_eur, 0), 'seq', coalesce(s.seq, 0), 'updated_at', s.updated_at);
$$;

-- One planned change, kept in a plpgsql array (no temp tables: they bloat the catalog under load).
do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 't1_private' and t.typname = 'collection_change') then
    create type t1_private.collection_change as (
      card_id uuid, finish text, condition text, lang text, oracle_id uuid, name text, finishes text[],
      cur integer, new_qty integer, n_set integer, n_delta integer, p_usd numeric, p_eur numeric);
  end if;
end $$;

-- ==================================================================== c_apply
-- The one write path. p_ops: [{card_id, finish?='nonfoil', condition?='NM', lang?='en', delta? | qty?}].
-- Per key: several deltas, or exactly one absolute qty. Up to 5000 ops. The whole batch is rejected if any
-- result would go below 0, a card is unknown, or a finish doesn't exist for that printing.
-- Replaying a batch id returns {duplicate:true} and changes nothing.
create or replace function t1_private.collection_apply_as(
  p_uid uuid, p_ops jsonb, p_source text, p_source_id uuid, p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_key uuid := coalesce(p_batch_id, gen_random_uuid());
  v_batch public.collection_batches;
  v_plan t1_private.collection_change[];
  v_n integer;
  v_bad text;
  v_had integer;
  v_has integer;
  v_seq bigint;
  v_changes integer;
  v_items jsonb;
  v_sum public.library_summary;
begin
  if p_uid is null then raise exception 'Sign in to change your collection' using errcode = '28000'; end if;
  if p_source is null or p_source not in ('manual', 'import', 'scan', 'trade', 'adjust', 'undo') then
    raise exception 'Unknown source' using errcode = '22023';
  end if;
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' then raise exception 'ops must be an array' using errcode = '22023'; end if;
  v_n := jsonb_array_length(p_ops);
  if v_n = 0 then raise exception 'Nothing to change' using errcode = '22023'; end if;
  if v_n > 5000 then raise exception 'At most 5000 changes per batch' using errcode = '22023'; end if;

  -- Serialize this user's writes; this also makes a concurrent replay of the same key wait and then see it.
  insert into public.library_summary (user_id) values (p_uid) on conflict do nothing;
  perform 1 from public.library_summary where user_id = p_uid for update;

  select * into v_batch from public.collection_batches where id = v_key;
  if v_batch.id is not null then
    if v_batch.user_id <> p_uid then raise exception 'Batch id already used' using errcode = '23505'; end if;
    select * into v_sum from public.library_summary where user_id = p_uid;
    return jsonb_build_object('batch_id', v_key, 'duplicate', true, 'seq', v_sum.seq, 'items', '[]'::jsonb,
                              'summary', t1_private.summary_json(v_sum));
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
                            'items', v_items, 'summary', t1_private.summary_json(v_sum));
end $$;

create or replace function public.collection_apply(
  p_ops jsonb, p_source text default 'manual', p_source_id uuid default null, p_idempotency_key uuid default null)
returns jsonb language sql security definer set search_path = '' as $$
  select t1_private.collection_apply_as(auth.uid(),
           p_ops, case when p_source = 'undo' then null else p_source end, p_source_id, p_idempotency_key);
$$;

-- Reverses one earlier batch (an import, a scan session, a mistaken add). Rejected if later changes already
-- removed the copies it added. A batch can be undone once; undo batches themselves can't be undone.
create or replace function public.collection_undo(p_batch_id uuid, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_batch public.collection_batches;
  v_ops jsonb;
  v_res jsonb;
begin
  if v_uid is null then raise exception 'Sign in to change your collection' using errcode = '28000'; end if;
  if p_idempotency_key is not null
     and exists (select 1 from public.collection_batches where id = p_idempotency_key and user_id = v_uid) then
    return t1_private.collection_apply_as(v_uid, '[{}]'::jsonb, 'undo', p_batch_id, p_idempotency_key);
  end if;
  select * into v_batch from public.collection_batches where id = p_batch_id and user_id = v_uid for update;
  if v_batch.id is null then raise exception 'Nothing to undo' using errcode = 'P0002'; end if;
  if v_batch.source = 'undo' then raise exception 'An undo can''t be undone' using errcode = '22023'; end if;
  if v_batch.undone_by is not null then raise exception 'Already undone' using errcode = '22023'; end if;

  select jsonb_agg(jsonb_build_object('card_id', card_id, 'finish', finish, 'condition', condition,
                                      'lang', lang, 'delta', -d))
    into v_ops
    from (select card_id, finish, condition, lang, sum(delta) d from public.collection_ledger
           where batch_id = p_batch_id group by 1, 2, 3, 4 having sum(delta) <> 0) l;
  if v_ops is null then raise exception 'Nothing to undo' using errcode = 'P0002'; end if;

  v_res := t1_private.collection_apply_as(v_uid, v_ops, 'undo', p_batch_id, p_idempotency_key);
  update public.collection_batches set undone_by = (v_res->>'batch_id')::uuid where id = p_batch_id;
  return v_res;
end $$;

-- ==================================================================== d_reads
-- Delta sync: rows changed after `p_after` (a seq the client already holds), oldest first, at most p_limit.
-- Tombstones come through with qty 0. resync=true means the client is behind the purge horizon: drop the
-- local copy and start again from 0.
create or replace function public.collection_changes(p_after bigint default 0, p_limit integer default 5000)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_lim integer := least(greatest(coalesce(p_limit, 5000), 1), 10000);
  v_sum public.library_summary;
  v_items jsonb;
  v_n integer;
  v_last bigint;
begin
  if v_uid is null then raise exception 'Sign in to see your collection' using errcode = '28000'; end if;
  select * into v_sum from public.library_summary where user_id = v_uid;
  if coalesce(p_after, 0) > 0 and coalesce(p_after, 0) < coalesce(v_sum.tombstone_floor, 0) then
    return jsonb_build_object('resync', true, 'items', '[]'::jsonb, 'next', 0, 'more', false,
                              'summary', t1_private.summary_json(v_sum));
  end if;
  select coalesce(jsonb_agg(jsonb_build_array(card_id, finish, condition, lang, qty, seq) order by seq), '[]'::jsonb),
         count(*), max(seq)
    into v_items, v_n, v_last
    from (select card_id, finish, condition, lang, qty, seq from public.collection_items
           where user_id = v_uid and seq > coalesce(p_after, 0)
           order by seq limit v_lim) r;
  return jsonb_build_object('resync', false, 'items', v_items, 'next', coalesce(v_last, coalesce(p_after, 0)),
                            'more', v_n = v_lim, 'summary', t1_private.summary_json(v_sum));
end $$;

create or replace function public.library_summary_get()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select t1_private.summary_json(s) from public.library_summary s where s.user_id = auth.uid()),
                  t1_private.summary_json(null::public.library_summary));
$$;

-- One printing's change history for the card detail screen, newest first.
create or replace function public.collection_card_history(p_card_id uuid, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', l.at, 'finish', l.finish, 'condition', l.condition, 'lang', l.lang, 'delta', l.delta,
           'qty_after', l.qty_after, 'source', b.source, 'batch_id', b.id, 'undone', b.undone_by is not null)
           order by l.id desc), '[]'::jsonb)
    from (select * from public.collection_ledger
           where user_id = auth.uid() and card_id = p_card_id
           order by id desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) l
    join public.collection_batches b on b.id = l.batch_id;
$$;

-- ==================================================================== e_jobs
-- Nightly after the price sync: recompute every collection's value from current prices, set-based.
create or replace function t1_private.library_revalue()
returns void language sql security definer set search_path = '' as $$
  update public.library_summary s
     set value_usd = v.usd, value_eur = v.eur
    from (select i.user_id,
                 coalesce(sum(i.qty * t1_private.unit_price(p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil, i.finish, 'usd')), 0) usd,
                 coalesce(sum(i.qty * t1_private.unit_price(p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil, i.finish, 'eur')), 0) eur
            from public.collection_items i
            left join public.card_prices p on p.card_id = i.card_id
           where i.qty > 0
           group by i.user_id) v
   where s.user_id = v.user_id
     and (s.value_usd, s.value_eur) is distinct from (v.usd::numeric(14,2), v.eur::numeric(14,2));
$$;

-- Tombstones older than 30 days go; each affected user's floor moves up to the newest purged seq.
create or replace function t1_private.library_purge_tombstones()
returns void language sql security definer set search_path = '' as $$
  with gone as (
    delete from public.collection_items
     where qty = 0 and updated_at < now() - interval '30 days'
    returning user_id, seq
  )
  update public.library_summary s set tombstone_floor = greatest(s.tombstone_floor, g.max_seq)
    from (select user_id, max(seq) max_seq from gone group by user_id) g
   where s.user_id = g.user_id;
$$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-library-revalue') then
      perform cron.schedule('t1-library-revalue', '7 1 * * *', 'select t1_private.library_revalue()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-library-tombstones') then
      perform cron.schedule('t1-library-tombstones', '37 4 * * 0', 'select t1_private.library_purge_tombstones()');
    end if;
  end if;
end $$;

-- ==================================================================== f_grants
revoke execute on function t1_private.collection_apply_as(uuid, jsonb, text, uuid, uuid) from public;
do $$
declare f text;
begin
  foreach f in array array[
    'collection_apply(jsonb, text, uuid, uuid)', 'collection_undo(uuid, uuid)', 'collection_changes(bigint, integer)',
    'library_summary_get()', 'collection_card_history(uuid, integer)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ==================================================================== g_delete_account
-- Account deletion also removes the collection (it is personal data, not shared tournament history).
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
  delete from public.collection_ledger where user_id = v_uid;
  delete from public.collection_batches where user_id = v_uid;
  delete from public.collection_items where user_id = v_uid;
  delete from public.library_summary where user_id = v_uid;
end $$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
