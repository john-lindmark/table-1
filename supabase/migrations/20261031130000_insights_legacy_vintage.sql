-- Insights: Legacy and Vintage (John, 2026-10-31: "add legacy and vintage to the constructed insights format options";
-- contract/insights-2026-10-24.md § Sources and tiers). Both rows have been in meta_formats since the start, switched
-- off, so Magic Online pages and Melee files of theirs were never read. This switches them on (after Modern, the order
-- the apps show), seeds their archetype rules, and goes back for the year they missed:
--  * Magic Online: the month-index backfill starts again from last month (meta-sync reads one month a tick and queues
--    only formats switched on; event pages already read are not queued twice).
--  * Melee: cache files skipped as "not a format read" go back in the queue (they're read again and skipped again
--    when they're still not one).
--  * TopDeck.gg needs nothing: a format with no td_back_<format> cursor is read back a year from scratch.
-- Rules written from 1,427 Legacy and 880 Vintage lists of MTGO Challenges, Sep–Oct 2026 (25 Legacy archetypes name
-- 97% of them, 12 Vintage ones 98%); clustering and Review add the rest. Bans and restrictions of the last year were
-- seeded with the other formats (20261025120000); set releases are drawn for every format already.

update t1_private.meta_formats set enabled = true where format in ('legacy', 'vintage');
update t1_private.meta_formats set ord = case format
    when 'standard' then 1 when 'pioneer' then 2 when 'modern' then 3 when 'legacy' then 4 when 'vintage' then 5
    when 'pauper' then 6 when 'canlander' then 7 when 'premodern' then 8 else ord end
  where format in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'canlander', 'premodern');

insert into t1_private.meta_archetypes (format, name, family, colors, status, rule, priority, source) values
  ('legacy', 'Beseech Storm', 'combo', 'BRG', 'approved', '{"main": ["Tendrils of Agony"]}'::jsonb, 10, 'seed'),
  ('legacy', 'Doomsday', 'combo', 'UB', 'approved', '{"main": ["Doomsday"]}'::jsonb, 10, 'seed'),
  ('legacy', 'Lands', 'control', 'G', 'approved', '{"main": ["Dark Depths", "Thespian''s Stage"]}'::jsonb, 10, 'seed'),
  ('legacy', 'Oops All Spells', 'combo', 'BG', 'approved', '{"main": ["Balustrade Spy"]}'::jsonb, 10, 'seed'),
  ('legacy', 'Painter', 'combo', 'R', 'approved', '{"main": ["Painter''s Servant", "Grindstone"]}'::jsonb, 10, 'seed'),
  ('legacy', 'Hogaak', 'midrange', 'BG', 'approved', '{"main": ["Hogaak, Arisen Necropolis"]}'::jsonb, 12, 'seed'),
  ('legacy', 'Dredge', 'combo', 'UB', 'approved', '{"main": ["Narcomoeba", "Dread Return"]}'::jsonb, 15, 'seed'),
  ('legacy', 'Sneak and Show', 'combo', 'UR', 'approved', '{"main": ["Show and Tell", "Sneak Attack"]}'::jsonb, 15, 'seed'),
  ('legacy', 'Affinity', 'aggro', 'U', 'approved', '{"main": ["Mox Opal", "Urza''s Saga"], "any": [["Emry, Lurker of the Loch", "Kappa Cannoneer", "Pinnacle Emissary"]]}'::jsonb, 20, 'seed'),
  ('legacy', 'Cradle Elves', 'combo', 'G', 'approved', '{"main": ["Gaea''s Cradle", "Green Sun''s Zenith"]}'::jsonb, 20, 'seed'),
  ('legacy', 'Death and Taxes', 'aggro', 'W', 'approved', '{"main": ["Aether Vial"], "any": [["Thalia, Guardian of Thraben", "Stoneforge Mystic", "Recruiter of the Guard"]]}'::jsonb, 20, 'seed'),
  ('legacy', 'Eldrazi', 'aggro', '', 'approved', '{"main": ["Thought-Knot Seer", "Eldrazi Temple"]}'::jsonb, 20, 'seed'),
  ('legacy', 'Karn Tron', 'ramp', '', 'approved', '{"main": ["Karn, the Great Creator", "Urza''s Tower"]}'::jsonb, 20, 'seed'),
  ('legacy', 'Omni-Tell', 'combo', 'UG', 'approved', '{"main": ["Show and Tell", "Omniscience"]}'::jsonb, 20, 'seed'),
  ('legacy', 'Reanimator', 'combo', 'B', 'approved', '{"main": ["Reanimate"]}'::jsonb, 20, 'seed'),
  ('legacy', 'Temur Cascade', 'ramp', 'RG', 'approved', '{"main": ["Violent Outburst"], "any": [["Apex Devastator", "Maelstrom Wanderer", "Etali, Primal Conqueror", "Emrakul, the Aeons Torn"]]}'::jsonb, 20, 'seed'),
  ('legacy', 'Show and Tell', 'combo', 'U', 'approved', '{"main": ["Show and Tell"]}'::jsonb, 25, 'seed'),
  ('legacy', 'Bant Beanstalk', 'midrange', 'WUG', 'approved', '{"main": ["Up the Beanstalk"]}'::jsonb, 30, 'seed'),
  ('legacy', 'Boros Energy', 'aggro', 'RW', 'approved', '{"main": ["Ocelot Pride", "Guide of Souls"]}'::jsonb, 30, 'seed'),
  ('legacy', 'Izzet Delver', 'aggro', 'UR', 'approved', '{"main": ["Dragon''s Rage Channeler", "Lightning Bolt"], "any": [["Murktide Regent", "Cori-Steel Cutter", "Delver of Secrets"]]}'::jsonb, 30, 'seed'),
  ('legacy', 'Red Stompy', 'aggro', 'R', 'approved', '{"main": ["Magus of the Moon"], "any": [["Blood Moon", "Chalice of the Void", "Fable of the Mirror-Breaker"]]}'::jsonb, 30, 'seed'),
  ('legacy', 'Jeskai Control', 'control', 'WUR', 'approved', '{"main": ["Swords to Plowshares", "Volcanic Island", "Tundra"], "any": [["Forth Eorlingas!", "Back to Basics", "Teferi, Time Raveler"]]}'::jsonb, 35, 'seed'),
  ('legacy', 'Azorius Control', 'control', 'WU', 'approved', '{"main": ["Wrath of the Skies", "Tundra"]}'::jsonb, 40, 'seed'),
  ('legacy', 'Dimir Tempo', 'midrange', 'UB', 'approved', '{"main": ["Fatal Push", "Undercity Sewers"], "any": [["Nethergoyf", "Kaito, Bane of Nightmares", "Moonshadow", "Orcish Bowmasters"]], "not": ["Doomsday", "Dark Ritual"]}'::jsonb, 40, 'seed'),
  ('legacy', 'Azorius Tempo', 'midrange', 'WU', 'approved', '{"main": ["Tamiyo, Inquisitive Student", "Swords to Plowshares", "Tundra"]}'::jsonb, 45, 'seed'),
  ('vintage', 'Doomsday', 'combo', 'UB', 'approved', '{"main": ["Doomsday"]}'::jsonb, 10, 'seed'),
  ('vintage', 'Dredge', 'combo', 'B', 'approved', '{"main": ["Bazaar of Baghdad"]}'::jsonb, 10, 'seed'),
  ('vintage', 'Oath of Druids', 'combo', 'UG', 'approved', '{"main": ["Oath of Druids"]}'::jsonb, 10, 'seed'),
  ('vintage', 'Breach Storm', 'combo', 'UR', 'approved', '{"main": ["Underworld Breach", "Brain Freeze"]}'::jsonb, 15, 'seed'),
  ('vintage', 'Paradoxical Outcome', 'combo', 'U', 'approved', '{"main": ["Paradoxical Outcome"]}'::jsonb, 15, 'seed'),
  ('vintage', 'Workshops', 'aggro', '', 'approved', '{"main": ["Mishra''s Workshop"]}'::jsonb, 25, 'seed'),
  ('vintage', 'Vault Key', 'combo', 'U', 'approved', '{"main": ["Time Vault", "Manifold Key"]}'::jsonb, 28, 'seed'),
  ('vintage', 'Blue Tinker', 'combo', 'U', 'approved', '{"main": ["Tinker"]}'::jsonb, 30, 'seed'),
  ('vintage', 'White Initiative', 'aggro', 'W', 'approved', '{"main": ["Clarion Conqueror"], "any": [["White Plume Adventurer", "Seasoned Dungeoneer", "Archon of Emeria"]]}'::jsonb, 30, 'seed'),
  ('vintage', 'Dimir Tempo', 'midrange', 'UB', 'approved', '{"main": ["Psychic Frog"]}'::jsonb, 40, 'seed'),
  ('vintage', 'Jeskai Control', 'control', 'WUR', 'approved', '{"main": ["Swords to Plowshares", "Tundra"], "any": [["Lórien Revealed", "Snapcaster Mage", "Forth Eorlingas!", "Stock Up"]]}'::jsonb, 45, 'seed')
on conflict (format, name) do nothing;

-- The year of Magic Online indexes again, from last month back to the backfill's existing end.
update t1_private.meta_settings
   set state = state || jsonb_build_object('backfill_next', to_char(date_trunc('month', now()) - interval '1 month', 'YYYY/MM'),
                                           'backfill_until', coalesce(state->>'backfill_until', to_char(now() - interval '12 months', 'YYYY/MM')))
 where id;

-- Melee files skipped before these formats were read.
update t1_private.meta_queue set status = 'pending', attempts = 0, error = null
 where source = 'melee' and status = 'skipped';
