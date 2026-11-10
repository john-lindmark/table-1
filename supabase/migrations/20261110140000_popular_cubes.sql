-- Popular cubes to rank (John, 2026-11-10: "From my rankings on profile, I should have the ability to rank and see
-- friends rankings of popular cubes"; contract/cube-rankings-2026-10-21.md § Popular cubes). Four well-known cubes that
-- nobody on Table 1 owns, ranked like a Limited set: a ranking's set_key names one (PLSV, LSV, VCUBE, APCUBE), the
-- clients open it as the subject "set:<key>", and it's shared with friends (and whoever the maker's Rankings part
-- reaches) exactly like a set ranking.
--  - t1_private.popular_cubes: key, name, curator, where its list comes from (Cube Cobra, mtgo.com, Scryfall's cube
--    lists), its cards (Oracle ids), the printing each is drawn in (Cube Cobra's pick, else Scryfall's default) and
--    names nothing matched. limited-sync {step:"popular"} (weekly, pg_cron t1-popular-cubes) reads every source and
--    hands the cards to popular_cube_put. A cube's key stays the same as its list changes, so cards that join or leave
--    work like a changed cube (they wait outside the lists until placed).
--  - public.popular_cubes(): the cubes in order, with your rankings and the ones you can see of each.
-- Replaces t1_private.limited_subject_cards, t1_private.set_subject_json and t1_private.limited_subject_ok
-- (20261030140000_limited_rankings.sql), each with a popular cube first.

create table if not exists t1_private.popular_cubes (
  key text primary key check (key ~ '^[A-Z0-9]{2,8}$'),
  name text not null,
  curator text,
  source text not null check (source in ('cubecobra', 'mtgo', 'scryfall')),
  -- Where the list is read from (Cube Cobra id, mtgo.com page, Scryfall cube code) and the page people can open.
  ref text not null,
  url text not null,
  position integer not null,
  cards uuid[] not null default '{}',
  printings jsonb not null default '{}'::jsonb,
  missing text[] not null default '{}',
  synced_at timestamptz,
  changed_at timestamptz
);
alter table t1_private.popular_cubes enable row level security;
revoke all on t1_private.popular_cubes from public, anon, authenticated;

insert into t1_private.popular_cubes (key, name, curator, source, ref, url, position) values
  ('PLSV', 'PowerLSV', 'LSV', 'cubecobra', '786d3a10-43bd-438e-acf4-bb150b881254',
   'https://cubecobra.com/cube/list/786d3a10-43bd-438e-acf4-bb150b881254', 1),
  ('LSV', 'LSVCube', 'LSV', 'cubecobra', 'a525ebe1-c9c0-471c-aca3-772f91bf4145',
   'https://cubecobra.com/cube/list/a525ebe1-c9c0-471c-aca3-772f91bf4145', 2),
  ('VCUBE', 'MTGO Vintage Cube', 'Magic Online', 'mtgo', 'https://www.mtgo.com/vintage-cube-cardlist',
   'https://www.mtgo.com/vintage-cube-cardlist', 3),
  ('APCUBE', 'Arena Powered Cube', 'MTG Arena', 'scryfall', 'apcube', 'https://scryfall.com/cubes/apcube', 4)
on conflict (key) do nothing;

-- ==================================================================== a_put
-- A cube's list as its source has it now: [{name, card_id?, oracle_id?}] (a Scryfall printing id, else an Oracle id,
-- else the name). Refuses a list under 300 matched cards, so a source page that changed shape never empties a cube.
-- Returns {key, cards, missing, changed}. limited-sync (service role) only.
create or replace function public.popular_cube_put(p_key text, p_cards jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_key text := upper(btrim(coalesce(p_key, '')));
  v_old uuid[];
  v_cards uuid[];
  v_printings jsonb;
  v_missing text[];
begin
  select cards into v_old from t1_private.popular_cubes where key = v_key;
  if not found then raise exception 'Unknown cube %', p_key using errcode = '22023'; end if;
  if jsonb_typeof(p_cards) is distinct from 'array' then raise exception 'Cards must be a list' using errcode = '22023'; end if;
  with i as (
    select btrim(coalesce(x->>'name', '')) name,
           case when x->>'card_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (x->>'card_id')::uuid end cid,
           case when x->>'oracle_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (x->>'oracle_id')::uuid end oid
      from jsonb_array_elements(p_cards) x
  ), m as (
    select i.name, c.id card, coalesce(c.oracle_id, o.oracle_id, case when i.name <> '' then t1_private.meta_card_id(i.name) end) oracle
      from i left join public.cards c on c.id = i.cid
             left join public.card_oracles o on o.oracle_id = i.oid
  )
  select coalesce(array_agg(distinct oracle) filter (where oracle is not null), '{}'),
         coalesce((select jsonb_object_agg(o, card) from (select distinct on (oracle) oracle::text o, card::text card
                                                             from m where oracle is not null and card is not null
                                                            order by oracle, card) p), '{}'::jsonb),
         coalesce(array_agg(distinct name) filter (where oracle is null and name <> ''), '{}')
    into v_cards, v_printings, v_missing
    from m;
  if cardinality(v_cards) < 300 then
    raise exception 'Only % cards matched for %; keeping the list as it was', cardinality(v_cards), v_key using errcode = '22023';
  end if;
  v_cards := (select array_agg(c order by c) from unnest(v_cards) c);
  update t1_private.popular_cubes
     set cards = v_cards, printings = v_printings, missing = v_missing, synced_at = now(),
         changed_at = case when v_old is distinct from v_cards then now() else changed_at end
   where key = v_key;
  return jsonb_build_object('key', v_key, 'cards', cardinality(v_cards), 'missing', to_jsonb(v_missing),
                            'changed', v_old is distinct from v_cards);
end $$;

-- What limited-sync reads: each cube's key, source and ref.
create or replace function public.popular_cube_sources()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', key, 'source', source, 'ref', ref) order by position), '[]'::jsonb)
    from t1_private.popular_cubes;
$$;

-- ==================================================================== b_subjects
-- The subject's cards (sorted Oracle ids as text) and the printing each is drawn in.
create or replace function t1_private.limited_subject_cards(p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  pc t1_private.popular_cubes;
  v_cards uuid[];
begin
  select * into pc from t1_private.popular_cubes where key = upper(p_key);
  if pc.key is not null then
    return jsonb_build_object('cards', coalesce((select jsonb_agg(c::text order by c::text) from unnest(pc.cards) c), '[]'::jsonb),
                              'printings', pc.printings);
  end if;
  v_cards := (select cards from t1_private.limited_cube_versions where key = upper(p_key));
  if v_cards is not null then
    return jsonb_build_object('cards', coalesce((select jsonb_agg(x order by x) from (select distinct c::text x from unnest(v_cards) c) d), '[]'::jsonb),
                              'printings', '{}'::jsonb);
  end if;
  return (select jsonb_build_object('cards', coalesce(jsonb_agg(p.oracle_id::text order by p.oracle_id::text), '[]'::jsonb),
                                    'printings', coalesce(jsonb_object_agg(p.oracle_id::text, p.card_id::text), '{}'::jsonb))
            from t1_private.limited_set_printings(p_key) p);
end $$;

-- How a subject reads in a ranking: {id: "set:<key>", set, kind: set | cube | popular, name, released, mine: false,
-- owner: null, can_see}; a popular cube adds curator and url.
create or replace function t1_private.set_subject_json(p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := (select jsonb_build_object('id', 'set:' || p.key, 'set', p.key, 'kind', 'popular', 'name', p.name, 'released', null,
                                            'curator', p.curator, 'url', p.url, 'mine', false, 'owner', null, 'can_see', true)
                     from t1_private.popular_cubes p where p.key = upper(p_key));
begin
  if v is not null then return v; end if;
  v := (select jsonb_build_object('id', 'set:' || v.key, 'set', v.key, 'kind', 'cube', 'name', v.name, 'released', v.started::text,
                                  'mine', false, 'owner', null, 'can_see', true)
          from t1_private.limited_cube_versions v where v.key = upper(p_key));
  if v is not null then return v; end if;
  return (select jsonb_build_object('id', 'set:' || upper(s.code), 'set', upper(s.code), 'kind', 'set', 'name', s.name, 'released', s.released_at::text,
                                    'mine', false, 'owner', null, 'can_see', true)
            from public.mtg_sets s where s.code = lower(p_key));
end $$;

-- A subject someone may start a ranking of: a popular cube with cards, a cube version, or a draftable paper set.
create or replace function t1_private.limited_subject_ok(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(p_key ~ '^[A-Z0-9]{2,8}(-[0-9]{4})?$', false)
     and (exists (select 1 from t1_private.popular_cubes where key = p_key and cardinality(cards) > 0)
          or exists (select 1 from t1_private.limited_cube_versions where key = p_key)
          or (p_key !~ '-' and t1_private.limited_set_ok(p_key)));
$$;

-- ==================================================================== c_rpc
-- The popular cubes in order: [{key, id: "set:<key>", name, curator, url, cards, updated, mine (your rankings),
-- rankings (the ones you can see, yours too), friends (your friends' you can see)}]. A cube whose list hasn't been
-- read yet isn't listed.
create or replace function public.popular_cubes()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('key', p.key, 'id', 'set:' || p.key, 'name', p.name, 'curator', p.curator,
                                                 'url', p.url, 'cards', cardinality(p.cards), 'updated', p.changed_at::date::text,
                                                 'mine', r.mine, 'rankings', r.seen, 'friends', r.friends)
                              order by p.position), '[]'::jsonb)
      from t1_private.popular_cubes p
      cross join lateral (
        select count(*) filter (where x.user_id = v_uid)::int mine,
               count(*) filter (where x.user_id = v_uid or x.seen)::int seen,
               count(*) filter (where x.user_id <> v_uid and x.seen and t1_private.share_level(x.user_id, v_uid) >= 1)::int friends
          from (select y.*, t1_private.ranking_seen(y, v_uid) seen from public.cube_rankings y where y.set_key = p.key) x) r
     where cardinality(p.cards) > 0);
end $$;

-- ==================================================================== d_grants
revoke execute on function t1_private.limited_subject_cards(text) from public;
revoke execute on function t1_private.set_subject_json(text) from public;
revoke execute on function t1_private.limited_subject_ok(text) from public;
revoke execute on function public.popular_cube_put(text, jsonb) from public, anon, authenticated;
revoke execute on function public.popular_cube_sources() from public, anon, authenticated;
grant execute on function public.popular_cube_put(text, jsonb) to service_role;
grant execute on function public.popular_cube_sources() to service_role;
revoke execute on function public.popular_cubes() from public, anon;
grant execute on function public.popular_cubes() to authenticated;

-- ==================================================================== e_cron
-- Weekly, Mondays 06:41 UTC (Cube Cobra and mtgo.com change a few times a year; Scryfall's list with Arena's runs).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 't1-popular-cubes';
    perform cron.schedule('t1-popular-cubes', '41 6 * * 1', $j$select t1_private.insights_post('limited-sync', '{"step":"popular"}'::jsonb)$j$);
  end if;
end $$;
