-- A format's Events list is newest first (20261110160000_insights_events_newest_first.sql): the pack listed every
-- Major before any Large event, so a Large event after the last Major sat below older Majors.
\ir _helpers.sql

insert into t1_private.meta_events (source, source_id, format, name, kind, on_date, players, tier) values
  ('melee', 'ORD1', 'modern', 'Regional Championship', 'championship', current_date - 10, 400, 'major'),
  ('melee', 'ORD2', 'modern', 'Older Major', 'championship', current_date - 20, 300, 'major'),
  ('melee', 'ORD3', 'modern', 'Newer Large', 'paper', current_date - 3, 85, 'large'),
  ('mtgo', 'ORD4', 'modern', 'Small Challenge', 'challenge', current_date - 1, 20, 'small'),
  ('mtgo', 'ORD5', 'modern', 'League', 'league', current_date - 1, 0, 'small'),
  ('melee', 'ORD6', 'modern', 'Too Old', 'paper', current_date - 40, 500, 'major');

select pg_temp.eq('events: newest first whatever the tier, leagues and older than 30 days left out',
  (select string_agg(e->>'name', ', ' order by n) from jsonb_array_elements(public.meta_pack_base('modern')->'events') with ordinality x(e, n)),
  'Small Challenge, Newer Large, Regional Championship, Older Major');

-- 45 more small events: the 40 kept still put the biggest tiers first.
insert into t1_private.meta_events (source, source_id, format, name, kind, on_date, players, tier)
  select 'mtgo', 'ORDS' || g, 'modern', 'Small ' || g, 'challenge', current_date - 1 - (g % 5), 20, 'small' from generate_series(1, 45) g;
select pg_temp.eq('events: at most 40, the Majors and Larges always among them, still newest first',
  (select jsonb_array_length(b->'events') || ' ' ||
          (select count(*) from jsonb_array_elements(b->'events') e where e->>'tier' in ('major', 'large')) || ' ' ||
          (select bool_and(coalesce((b->'events'->(n::int))->>'on' <= (e->>'on'), true))
             from jsonb_array_elements(b->'events') with ordinality x(e, n))
     from (select public.meta_pack_base('modern') b) y),
  '40 3 true');

delete from t1_private.meta_events where source_id like 'ORD%';
