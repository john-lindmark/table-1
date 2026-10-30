-- Spoiler season (John, 2026-10-30: "rank sets not yet on Arena in spoiler season, so like Star Trek should be available
-- via Scryfall"): limited_rankable offered upcoming sets only within 45 days and with 60+ cards, so a set's first weeks of
-- previews never showed. Upcoming sets now count from 75 days out with 20+ cards spoiled; released sets keep 60+. Cards
-- spoiled later join a ranking like cards added to a cube (contract/cube-rankings-2026-10-21.md § Sets).
-- Replaces public.limited_rankable (20261030140000_limited_rankings.sql).

create or replace function public.limited_rankable()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  with subj as (
    select upper(s.code) k, s.name, s.released_at released, 'set'::text kind,
           (select count(*) from t1_private.limited_set_printings(s.code))::int n
      from public.mtg_sets s
     where not s.digital and s.set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'remastered')
       and s.released_at between current_date - 400 and current_date + 75
       and exists (select 1 from public.cards c where c.set_code = s.code and c.lang = 'en')
    union all
    select v.key, v.name, v.started, 'cube', cardinality(v.cards)
      from t1_private.limited_cube_versions v where cardinality(v.cards) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', s.k, 'name', s.name, 'released', s.released::text, 'kind', s.kind,
                                               'cards', s.n, 'pack', p.key is not null,
                                               'mine', (select count(*) from public.cube_rankings r where r.set_key = s.k and r.user_id = v_uid),
                                               'rankings', (select count(*) from public.cube_rankings r where r.set_key = s.k and t1_private.ranking_seen(r, v_uid)))
                            order by s.released desc, s.k), '[]'::jsonb) into v
    from subj s left join t1_private.insight_packs p on p.kind = 'limited' and p.key = s.k
   where s.kind = 'cube' or s.n >= case when s.released > current_date then 20 else 60 end;
  return v;
end $$;

revoke execute on function public.limited_rankable() from public, anon;
grant execute on function public.limited_rankable() to authenticated;
