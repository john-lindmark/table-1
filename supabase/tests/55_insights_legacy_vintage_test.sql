-- Insights: Legacy and Vintage switched on (20261031130000_insights_legacy_vintage.sql): their order among the
-- formats, their seeded rules naming real lists, and the year of Magic Online indexes read again.
\ir _helpers.sql

create function pg_temp.card(p_name text) returns uuid language sql as $$
  insert into public.card_oracles (oracle_id, name, name_norm, face_names, layout, type_line, colors, legalities, source_card_id, source_rank, content_hash)
  values (md5(p_name)::uuid, p_name, public.card_name_norm(p_name), '{}', 'normal', 'Card', '{}', '{}', md5('s' || p_name)::uuid, 'a', 'h')
  on conflict (oracle_id) do nothing
  returning oracle_id;
$$;
-- Every name the seeded rules use, as the catalog has them.
select pg_temp.card(n) from (
  select distinct jsonb_array_elements_text(coalesce(rule->'main', '[]') || coalesce(rule->'deck', '[]') || coalesce(rule->'not', '[]')
                                            || coalesce((select jsonb_agg(x) from jsonb_array_elements(rule->'any') g, jsonb_array_elements(g) x), '[]')) n
    from t1_private.meta_archetypes where format in ('legacy', 'vintage')) s;
select pg_temp.card(n) from unnest(array['Brainstorm', 'Ponder', 'Island', 'Underground Sea', 'Black Lotus', 'Mox Sapphire', 'Force of Will']) n;
insert into public.card_names (name_norm, oracle_id, is_face)
select o.name_norm, o.oracle_id, false from public.card_oracles o on conflict do nothing;
select t1_private.meta_rule_compile(id) from t1_private.meta_archetypes where format in ('legacy', 'vintage');

select pg_temp.eq('Legacy and Vintage are on, after Modern',
  (select string_agg(format, ' ' order by ord) from t1_private.meta_formats where enabled),
  'standard pioneer modern legacy vintage pauper canlander');
select pg_temp.eq('their rules are seeded, approved, and every name compiles',
  (select count(*) filter (where format = 'legacy') || '/' || count(*) filter (where format = 'vintage') || '/'
          || count(*) filter (where status <> 'approved' or blocked or cardinality(missing) > 0)
     from t1_private.meta_archetypes where format in ('legacy', 'vintage') and source = 'seed'),
  '25/11/0');

create function pg_temp.lbl(p_format text, p_main text[], p_side text[] default '{}') returns text language sql as $$
  select coalesce((select name from t1_private.meta_archetypes where id = t1_private.meta_label(p_format,
           (select array_agg(md5(x)::uuid) from unnest(p_main) x), coalesce((select array_agg(md5(x)::uuid) from unnest(p_side) x), '{}'))), 'Other');
$$;
select pg_temp.eq('Legacy lists by their plan',
  concat_ws(' | ',
    pg_temp.lbl('legacy', array['Doomsday', 'Thassa''s Oracle', 'Dark Ritual', 'Brainstorm', 'Underground Sea']),
    pg_temp.lbl('legacy', array['Show and Tell', 'Omniscience', 'Atraxa, Grand Unifier', 'Island']),
    pg_temp.lbl('legacy', array['Show and Tell', 'Sneak Attack', 'Emrakul, the Aeons Torn']),
    pg_temp.lbl('legacy', array['Nethergoyf', 'Fatal Push', 'Undercity Sewers', 'Orcish Bowmasters']),
    pg_temp.lbl('legacy', array['Tamiyo, Inquisitive Student', 'Swords to Plowshares', 'Tundra', 'Brainstorm']),
    pg_temp.lbl('legacy', array['Brainstorm', 'Ponder', 'Island'])),
  'Doomsday | Omni-Tell | Sneak and Show | Dimir Tempo | Azorius Tempo | Other');
select pg_temp.eq('Vintage lists by their plan',
  concat_ws(' | ',
    pg_temp.lbl('vintage', array['Mishra''s Workshop', 'Karn, the Great Creator', 'Black Lotus']),
    pg_temp.lbl('vintage', array['Paradoxical Outcome', 'Mox Sapphire', 'Black Lotus']),
    pg_temp.lbl('vintage', array['Psychic Frog', 'Force of Will', 'Underground Sea']),
    pg_temp.lbl('vintage', array['Time Vault', 'Manifold Key', 'Mox Sapphire']),
    pg_temp.lbl('vintage', array['Force of Will', 'Mox Sapphire'])),
  'Workshops | Paradoxical Outcome | Dimir Tempo | Vault Key | Other');

select pg_temp.eq('the Magic Online backfill starts again from last month',
  ((select state->>'backfill_next' from t1_private.meta_settings) >= to_char(now() - interval '2 months', 'YYYY/MM'))::text, 'true');
select pg_temp.eq('and reads a year back', (select state ? 'backfill_until' from t1_private.meta_settings)::text, 'true');
