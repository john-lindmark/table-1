-- Hero cards (contract/library-heroes-2026-10-19.md): up to 10 cards, by Oracle id, that stand for a deck, a cube,
-- a binder or the whole collection. Clients highlight them where those are listed and on their own screens.
--  - One row per (account, scope, target); the collection's target is the nil uuid. An empty list deletes the row.
--  - Written only through library_heroes_set (security definer, owner checked, serialized on the library lock);
--    read through library_heroes. The table has RLS on and no policies.
--  - A deleted deck, cube or binder takes its heroes with it; deleting the account removes the rest (FK cascade).

create table if not exists public.library_heroes (
  user_id uuid not null references auth.users(id) on delete cascade,
  scope text not null check (scope in ('collection', 'list', 'binder')),
  target_id uuid not null,
  oracle_ids uuid[] not null check (cardinality(oracle_ids) between 1 and 10),
  updated_at timestamptz not null default now(),
  primary key (user_id, scope, target_id)
);
alter table public.library_heroes enable row level security;
revoke all on public.library_heroes from anon, authenticated;

create or replace function t1_private.hero_json(h public.library_heroes)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('scope', h.scope,
                            'target_id', case when h.scope = 'collection' then null else h.target_id end,
                            'oracle_ids', to_jsonb(h.oracle_ids));
$$;

-- Sets the heroes of one scope (the full list, in order; duplicates dropped). Returns the stored row, or an empty
-- oracle_ids list when it was cleared.
create or replace function public.library_heroes_set(p_scope text, p_target_id uuid default null, p_oracle_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_target uuid := case when p_scope = 'collection' then '00000000-0000-0000-0000-000000000000'::uuid else p_target_id end;
  v_ids uuid[];
  v_bad text;
  v public.library_heroes;
begin
  if v_uid is null then raise exception 'Sign in to pick hero cards' using errcode = '28000'; end if;
  if p_scope is null or p_scope not in ('collection', 'list', 'binder') then
    raise exception 'Heroes belong to the collection, a deck or cube, or a binder' using errcode = '22023';
  end if;
  if v_target is null then raise exception 'Say which % the heroes are for', p_scope using errcode = '22023'; end if;
  perform t1_private.library_lock(v_uid);
  if p_scope = 'list' and not exists (select 1 from public.card_lists where id = v_target and user_id = v_uid and deleted_at is null) then
    raise exception 'That deck or cube isn''t yours' using errcode = '42501';
  end if;
  if p_scope = 'binder' and not exists (select 1 from public.binders where id = v_target and user_id = v_uid and deleted_at is null) then
    raise exception 'That binder isn''t yours' using errcode = '42501';
  end if;

  select coalesce(array_agg(id order by first), '{}') into v_ids
    from (select id, min(n) first from unnest(coalesce(p_oracle_ids, '{}')) with ordinality u(id, n) where id is not null group by id) d;
  if cardinality(v_ids) > 10 then raise exception 'At most 10 hero cards' using errcode = '22023'; end if;
  select string_agg(id::text, ', ') into v_bad from unnest(v_ids) id
   where not exists (select 1 from public.card_oracles o where o.oracle_id = id);
  if v_bad is not null then raise exception 'Unknown card: %', v_bad using errcode = '22023'; end if;

  if cardinality(v_ids) = 0 then
    delete from public.library_heroes where user_id = v_uid and scope = p_scope and target_id = v_target;
    return jsonb_build_object('scope', p_scope, 'target_id', case when p_scope = 'collection' then null else v_target end,
                              'oracle_ids', '[]'::jsonb);
  end if;
  insert into public.library_heroes (user_id, scope, target_id, oracle_ids)
  values (v_uid, p_scope, v_target, v_ids)
  on conflict (user_id, scope, target_id) do update set oracle_ids = excluded.oracle_ids, updated_at = now()
  returning * into v;
  return t1_private.hero_json(v);
end $$;

-- Every hero row of the caller's live collection, decks, cubes and binders.
create or replace function public.library_heroes()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(t1_private.hero_json(h) order by h.scope, h.target_id), '[]'::jsonb)
    from public.library_heroes h
   where h.user_id = auth.uid()
     and (h.scope = 'collection'
          or (h.scope = 'list' and exists (select 1 from public.card_lists l where l.id = h.target_id and l.deleted_at is null))
          or (h.scope = 'binder' and exists (select 1 from public.binders b where b.id = h.target_id and b.deleted_at is null)));
$$;

-- Deleting a deck, cube or binder (a tombstone) drops its heroes.
create or replace function t1_private.library_heroes_gone()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    delete from public.library_heroes where user_id = new.user_id and scope = tg_argv[0] and target_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists card_lists_heroes_gone on public.card_lists;
create trigger card_lists_heroes_gone after update of deleted_at on public.card_lists
  for each row execute function t1_private.library_heroes_gone('list');
drop trigger if exists binders_heroes_gone on public.binders;
create trigger binders_heroes_gone after update of deleted_at on public.binders
  for each row execute function t1_private.library_heroes_gone('binder');

revoke execute on function t1_private.hero_json(public.library_heroes) from public;
revoke execute on function t1_private.library_heroes_gone() from public;
revoke execute on function public.library_heroes_set(text, uuid, uuid[]) from public, anon;
grant execute on function public.library_heroes_set(text, uuid, uuid[]) to authenticated;
revoke execute on function public.library_heroes() from public, anon;
grant execute on function public.library_heroes() to authenticated;
