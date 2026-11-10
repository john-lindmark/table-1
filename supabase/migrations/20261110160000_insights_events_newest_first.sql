-- Insights: a format's Events list newest first (contract/insights-2026-10-24.md § Constructed pack).
-- The pack listed every Major before any Large event, so Modern's list opened on the 10/24 Regional Championship
-- while three Large events (10/25, 10/31, 11/1) sat below the 10/17 ones and the list read as if nothing big had
-- happened since. Which 40 events are kept is unchanged (biggest tiers first); only their order is.
-- Replaces public.meta_pack_base from 20261025120000_insights.sql (not replaced since).

-- Archetypes, confirmed format changes, recent big events and which tier the client opens on.
-- Events: the 40 kept are still the biggest tiers first, but they are listed newest first.
create or replace function public.meta_pack_base(p_format text, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'format', f.format, 'name', f.name, 'through', p_through::text,
    'sources', coalesce((select jsonb_agg(distinct e.source) from t1_private.meta_events e
                          where e.format = f.format and e.on_date > p_through - 90), '[]'::jsonb),
    'default_tier', case when coalesce((select sum(weight) from t1_private.meta_decks d
                                         where d.format = f.format and d.on_date > p_through - 30 and d.on_date <= p_through
                                           and d.tier in ('major', 'large')), 0)
                              >= (select thin_below from t1_private.meta_settings) then 'big' else 'all' end,
    'archetypes', jsonb_build_array(jsonb_build_object('id', 0, 'name', 'Other', 'family', 'midrange', 'colors', ''))
                  || coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'family', a.family, 'colors', a.colors) order by a.name)
                                 from t1_private.meta_archetypes a where a.format = f.format and a.status = 'approved'), '[]'::jsonb),
    'changes', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'on', c.on_date::text, 'kind', c.kind, 'cards', to_jsonb(c.cards),
                                                             'set_code', c.set_code, 'note', c.note, 'url', c.url) order by c.on_date, c.id)
                           from t1_private.meta_format_changes c
                          where c.format = f.format and c.status = 'confirmed' and c.on_date > p_through - 365 and c.on_date <= p_through), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(ev order by on_date desc, ord, players desc nulls last) from (
        select e.on_date, e.players, t.ord,
               jsonb_build_object('name', e.name, 'on', e.on_date::text, 'players', e.players, 'tier', e.tier, 'source', e.source, 'url', e.url,
                 'top8', (select jsonb_agg(d.archetype_id order by d.rank nulls last, d.id) from (
                            select * from t1_private.meta_decks d where d.event_id = e.id and d.top8 order by d.rank nulls last, d.id limit 8) d),
                 'winner', (select d.archetype_id from t1_private.meta_decks d where d.event_id = e.id and d.rank = 1 limit 1)) ev
          from t1_private.meta_events e join t1_private.meta_tiers t on t.tier = e.tier
         where e.format = f.format and e.kind <> 'league' and e.on_date > p_through - 30 and e.on_date <= p_through
         order by t.ord, e.on_date desc limit 40) x), '[]'::jsonb))
  from t1_private.meta_formats f where f.format = p_format;
$$;
