-- Trades and price lookups for the Library.
-- A trade is one account's record of a swap: what it gives (copies it owns) and what it gets (any printing).
-- Drafts are saved as they're built; confirming applies both sides to the collection in one batch
-- (source 'trade', source_id = trade id), so Undo and history work as for any other change.
-- Market prices are Scryfall's, which carry TCGplayer market prices (USD) and Cardmarket (EUR).

create table if not exists public.trades (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  partner text,                                   -- who it's with, free text
  note text,
  status text not null default 'draft' check (status in ('draft', 'confirmed')),
  -- [{card_id, finish, condition, lang, qty}]
  gives jsonb not null default '[]'::jsonb,
  gets jsonb not null default '[]'::jsonb,
  batch_id uuid,                                  -- the collection batch written on confirm
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz
);
create index if not exists trades_user_idx on public.trades (user_id, updated_at desc);
alter table public.trades enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'trades' and policyname = 'trades_own_read') then
    create policy trades_own_read on public.trades for select to authenticated using (user_id = (select auth.uid()));
  end if;
end $$;

-- Normalizes one side: valid shape, positive quantities, at most 500 lines.
create or replace function t1_private.trade_side(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare v jsonb;
begin
  if p is null then return '[]'::jsonb; end if;
  if jsonb_typeof(p) <> 'array' then raise exception 'A trade side must be an array' using errcode = '22023'; end if;
  if jsonb_array_length(p) > 500 then raise exception 'At most 500 lines per side' using errcode = '22023'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'card_id', l.card_id, 'finish', coalesce(nullif(l.finish, ''), 'nonfoil'),
           'condition', upper(coalesce(nullif(l.condition, ''), 'NM')), 'lang', lower(coalesce(nullif(l.lang, ''), 'en')),
           'qty', l.qty)), '[]'::jsonb)
    into v
    from jsonb_to_recordset(p) l (card_id uuid, finish text, condition text, lang text, qty integer);
  if exists (select 1 from jsonb_array_elements(v) e
              where e->>'card_id' is null or coalesce((e->>'qty')::int, 0) < 1 or (e->>'qty')::int > 10000) then
    raise exception 'Every trade line needs a card and a quantity of 1 or more' using errcode = '22023';
  end if;
  return v;
end $$;

-- Creates (p_trade_id null) or replaces a draft. Returns the trade.
create or replace function public.trade_save(
  p_trade_id uuid, p_partner text default null, p_note text default null,
  p_gives jsonb default '[]'::jsonb, p_gets jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v public.trades;
begin
  if v_uid is null then raise exception 'Sign in to trade' using errcode = '28000'; end if;
  if p_trade_id is null then
    if (select count(*) from public.trades where user_id = v_uid and status = 'draft') >= 50 then
      raise exception 'Too many open trades; confirm or delete some first' using errcode = '53400';
    end if;
    insert into public.trades (user_id, partner, note, gives, gets)
    values (v_uid, nullif(left(trim(p_partner), 80), ''), nullif(left(trim(p_note), 500), ''),
            t1_private.trade_side(p_gives), t1_private.trade_side(p_gets))
    returning * into v;
  else
    update public.trades
       set partner = nullif(left(trim(p_partner), 80), ''), note = nullif(left(trim(p_note), 500), ''),
           gives = t1_private.trade_side(p_gives), gets = t1_private.trade_side(p_gets), updated_at = now()
     where id = p_trade_id and user_id = v_uid and status = 'draft'
    returning * into v;
    if v.id is null then raise exception 'That trade is gone or already confirmed' using errcode = 'P0002'; end if;
  end if;
  return to_jsonb(v) - 'user_id';
end $$;

-- Applies a draft to the collection: gives come out, gets go in, one batch. Rejected (nothing written) if
-- you no longer own what you're giving. Idempotent on p_idempotency_key like collection_apply.
create or replace function public.trade_confirm(p_trade_id uuid, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v public.trades;
  v_ops jsonb;
  v_res jsonb;
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
  select jsonb_agg(o) into v_ops from (
    select jsonb_build_object('card_id', e->>'card_id', 'finish', e->>'finish', 'condition', e->>'condition',
                              'lang', e->>'lang', 'delta', -(e->>'qty')::int) o
      from jsonb_array_elements(v.gives) e
    union all
    select jsonb_build_object('card_id', e->>'card_id', 'finish', e->>'finish', 'condition', e->>'condition',
                              'lang', e->>'lang', 'delta', (e->>'qty')::int)
      from jsonb_array_elements(v.gets) e) s;
  if v_ops is null then raise exception 'Add cards to the trade first' using errcode = '22023'; end if;

  v_res := t1_private.collection_apply_as(v_uid, v_ops, 'trade', v.id, coalesce(p_idempotency_key, gen_random_uuid()));
  update public.trades
     set status = 'confirmed', confirmed_at = now(), updated_at = now(), batch_id = (v_res->>'batch_id')::uuid
   where id = v.id
  returning * into v;
  return v_res || jsonb_build_object('trade', to_jsonb(v) - 'user_id');
end $$;

create or replace function public.trade_delete(p_trade_id uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.trades where id = p_trade_id and user_id = auth.uid();
$$;

-- Newest first. Confirmed trades stay as history.
create or replace function public.trades_list(p_limit integer default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.status <> 'draft', t.updated_at desc), '[]'::jsonb)
    from (select * from public.trades where user_id = auth.uid()
           order by updated_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) t;
$$;

-- Current prices for up to 5000 printings: [[card_id, usd, usd_foil, usd_etched, eur, eur_foil], …].
-- USD is the TCGplayer market price as published by Scryfall; null when TCGplayer has no market price.
create or replace function public.card_prices_get(p_card_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if cardinality(p_card_ids) > 5000 then raise exception 'At most 5000 cards per call' using errcode = '22023'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_array(p.card_id, p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil)), '[]'::jsonb)
            from public.card_prices p where p.card_id = any (p_card_ids));
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'trade_save(uuid, text, text, jsonb, jsonb)', 'trade_confirm(uuid, uuid)', 'trade_delete(uuid)',
    'trades_list(integer)', 'card_prices_get(uuid[])'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke execute on function t1_private.trade_side(jsonb) from public;

-- Account deletion also removes trades (personal records).
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
  delete from public.collection_ledger where user_id = v_uid;
  delete from public.collection_batches where user_id = v_uid;
  delete from public.collection_items where user_id = v_uid;
  delete from public.card_lists where user_id = v_uid;   -- versions and entries cascade
  delete from public.library_summary where user_id = v_uid;
end $$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
