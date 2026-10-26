-- Canadian Highlander: the colour groups too small for a named plan in 20261025181000 (fewer than 5 lists in Jan–Oct
-- 2026) get their colours' names, so a deck reads "Izzet" or "Naya" rather than "Other" (Other was 31% of the 90-day
-- share). Priority 60, after the named plans; four-colour decks other than Jeskai Black and Four-Color Control stay
-- Other, and clustering can still propose a plan within any of these.
insert into t1_private.meta_archetypes (format, name, family, colors, status, rule, priority, source) values
  ('canlander', 'Mono-White', 'aggro', 'W', 'approved', '{"colors": "W"}'::jsonb, 60, 'seed'),
  ('canlander', 'Mono-Blue', 'control', 'U', 'approved', '{"colors": "U"}'::jsonb, 60, 'seed'),
  ('canlander', 'Mono-Black', 'midrange', 'B', 'approved', '{"colors": "B"}'::jsonb, 60, 'seed'),
  ('canlander', 'Mono-Green', 'ramp', 'G', 'approved', '{"colors": "G"}'::jsonb, 60, 'seed'),
  ('canlander', 'Orzhov', 'midrange', 'WB', 'approved', '{"colors": "WB"}'::jsonb, 60, 'seed'),
  ('canlander', 'Selesnya', 'midrange', 'WG', 'approved', '{"colors": "WG"}'::jsonb, 60, 'seed'),
  ('canlander', 'Izzet', 'midrange', 'UR', 'approved', '{"colors": "UR"}'::jsonb, 60, 'seed'),
  ('canlander', 'Simic', 'midrange', 'UG', 'approved', '{"colors": "UG"}'::jsonb, 60, 'seed'),
  ('canlander', 'Golgari', 'midrange', 'BG', 'approved', '{"colors": "BG"}'::jsonb, 60, 'seed'),
  ('canlander', 'Gruul', 'midrange', 'RG', 'approved', '{"colors": "RG"}'::jsonb, 60, 'seed'),
  ('canlander', 'Jeskai', 'midrange', 'WUR', 'approved', '{"colors": "WUR"}'::jsonb, 60, 'seed'),
  ('canlander', 'Mardu', 'midrange', 'WBR', 'approved', '{"colors": "WBR"}'::jsonb, 60, 'seed'),
  ('canlander', 'Naya', 'midrange', 'WRG', 'approved', '{"colors": "WRG"}'::jsonb, 60, 'seed'),
  ('canlander', 'Temur', 'midrange', 'URG', 'approved', '{"colors": "URG"}'::jsonb, 60, 'seed'),
  ('canlander', 'Five-Color', 'midrange', 'WUBRG', 'approved', '{"colors": "WUBRG"}'::jsonb, 60, 'seed')
on conflict (format, name) do nothing;

select public.meta_relabel('canlander');
