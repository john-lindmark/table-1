-- Canadian Highlander archetypes, by colours: written from the 145 public TopDeck.gg lists of Jan–Oct 2026 grouped by
-- their colours (every group of 5+ decks, plus Jeskai Black, the format's best-known four-colour deck), named as
-- the format's players name them. The cards that set each group
-- apart: Esper Control (Teferi, Time Raveler, Snapcaster Mage, cantrips), Bant (Brightglass Gearhulk, Oko, Crop
-- Rotation, Wargate), Red Deck Wins (Price of Progress, Blood Moon, Eidolon of the Great Revel), Rakdos (Unearth,
-- Dauthi Voidwalker, Blood Moon), Jund (Tarmogoyf, Wrenn and Six, Minsc & Boo), Sultai (Oko, Toxic Deluge), Abzan
-- (Hierarchs, Grist, Birthing Ritual), Boros Aggro (Thalia, Mother of Runes, Luminarch Aspirant), Azorius Control
-- (Supreme Verdict, Mystic Confluence), Dimir Tempo (Psychic Frog, Ledger Shredder), Grixis Tempo (Dragon's Rage
-- Channeler, Cori-Steel Cutter), four-colour (Atraxa, Sevinne's Reclamation). New plans within a colour group are
-- left to clustering and Review.
insert into t1_private.meta_archetypes (format, name, family, colors, status, rule, priority, source) values
  ('canlander', 'Esper Control', 'control', 'WUB', 'approved', '{"colors": "WUB"}'::jsonb, 50, 'seed'),
  ('canlander', 'Bant Midrange', 'midrange', 'WUG', 'approved', '{"colors": "WUG"}'::jsonb, 50, 'seed'),
  ('canlander', 'Red Deck Wins', 'aggro', 'R', 'approved', '{"colors": "R"}'::jsonb, 50, 'seed'),
  ('canlander', 'Rakdos Midrange', 'midrange', 'BR', 'approved', '{"colors": "BR"}'::jsonb, 50, 'seed'),
  ('canlander', 'Jund Midrange', 'midrange', 'BRG', 'approved', '{"colors": "BRG"}'::jsonb, 50, 'seed'),
  ('canlander', 'Sultai Midrange', 'midrange', 'UBG', 'approved', '{"colors": "UBG"}'::jsonb, 50, 'seed'),
  ('canlander', 'Abzan Midrange', 'midrange', 'WBG', 'approved', '{"colors": "WBG"}'::jsonb, 50, 'seed'),
  ('canlander', 'Boros Aggro', 'aggro', 'WR', 'approved', '{"colors": "WR"}'::jsonb, 50, 'seed'),
  ('canlander', 'Azorius Control', 'control', 'WU', 'approved', '{"colors": "WU"}'::jsonb, 50, 'seed'),
  ('canlander', 'Dimir Tempo', 'midrange', 'UB', 'approved', '{"colors": "UB"}'::jsonb, 50, 'seed'),
  ('canlander', 'Grixis Tempo', 'midrange', 'UBR', 'approved', '{"colors": "UBR"}'::jsonb, 50, 'seed'),
  ('canlander', 'Jeskai Black', 'midrange', 'WUBR', 'approved', '{"colors": "WUBR"}'::jsonb, 50, 'seed'),
  ('canlander', 'Four-Color Control', 'control', 'WUBG', 'approved', '{"colors": "WUBG"}'::jsonb, 50, 'seed')
on conflict (format, name) do nothing;

select public.meta_relabel('canlander');
