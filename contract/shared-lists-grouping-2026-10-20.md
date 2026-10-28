# Shared decks and cubes, Export screen, Group by (2026-10-20)

Client-only: no server change. iOS built, unit-tested and checked in the demo (`-T1LibraryDemo profiledeck`); web and
Android to do.

## 1. Someone else's deck or cube (profile → Decks / Cubes)

What `profile_cards` returns for a deck or cube (it already enforces who may see it) now offers, above the cards:

- **Export**: the Export screen below, for that list as it is now.
- **Copy to my Library**: a new deck or cube with the same name, format and cards (`list_create`, telemetry
  `list_created` `from: profile`). Its first version's note reads "Copied from <owner>'s <name>". New decks start
  Private (existing trigger); cubes start on "Same as Cubes". `profile_cards` sends no finish, so copies are non-foil;
  lines merge per card and section. The owner isn't told. Not shown on your own profile (your deck screen has
  Duplicate).
- A deck's count leaves out Considering, like the profile row.

The route carries the list's format and the owner's name (`SharedList`), so the screen needs no extra request.

## 2. Export screen (your own lists and shared ones)

Export opens a full screen instead of a menu:

1. A format picker: Text, Arena, Moxfield, MTGO (decks) or Text, Cube Cobra (cubes). Starts on Text.
2. The list in that format, as selectable text, with the format's one-line description above it and the "N cards newer
   than the card data were left out" note under it when it applies.
3. Actions: **To Arena** (copies the Arena text; Arena imports from the clipboard) and **To MTGO** (the MTGO .txt to the
   share sheet) for decks, **To Cube Cobra** (the CSV to the share sheet) for cubes; then **Download .txt** (.csv for
   Cube Cobra) and **Copy text** for the format shown.

Output is unchanged (`ListExport` rules, `testdata/list-export`). Telemetry `list_exported` gains `from` (own / profile)
and `how` (copy / download).

## 3. View on shared cards

Every profile section (All cards, For trade, Wants, binders, decks, cubes) gets the View menu your own screens have:
List / Grid / Stacks, Expand all printings, and Group by. Decks and cubes group by section, then by the Group by
(like your own); stacks are one per group.

## 4. Group by (every card list)

The View menu adds Group by on your decks and cubes (Type / Color / Color identity / Mana value; decks start on Type, cubes on Color),
your binders and All cards (None / Type / Color / Color identity / Mana value; start on None), and everything in §3. Decks and cubes share
one setting per kind between your own and shared ones; All cards, binders and shared sections each keep their own.
Groups, in order:

- **Type**: Creatures, Planeswalkers, Instants, Sorceries, Artifacts, Enchantments, Battles, Lands, Other (front face's
  type line; a land creature is a creature).
- **Color**: White, Blue, Black, Red, Green, Multicolor, Colorless, Lands (the card's colors; packs without colors fall
  back to the mana cost's symbols).
- **Color identity** (added 2026-10-28, § Color identity): each exact combination, headings with their letters.
- **Mana value**: 0 … 6, 7+, Lands; headings read "Mana value 3".

Within a group the screen's own order holds (All cards' Recent / Price / Set sort, binders by count, lists by name).
In stacks, each group is one stack titled "<group> · <count>". Telemetry `card_grouping_changed` (`grouping`, `screen`).
Shared cases: `testdata/card-grouping/cases.json` (iOS `CardGroupingTests`).

## 5. Fixes in the same change (iOS)

- A Friends screen opened from a tapped push could show "Swift.CancellationError error 1": a load cancelled because
  the screen re-appeared was reported as an error. Cancelled requests are never errors now (`Error.isCancellation`,
  tests in `FriendsTests`).
- A keyboard left up by a field on a hidden tab (a tapped push switches tabs) couldn't be dismissed: switching tabs and
  opening or closing a panel put the keyboard away, and every list dismisses it on scroll.

## Color identity (2026-10-28)

Group by color identity sits after Group by color in every View menu above (wire `identity`, telemetry
`card_grouping_changed` as before) and in the Deck image's grouping row ("Identity"). Defaults don't change.

- A card's identity is the catalog pack's `identity` field (contract/catalog-2026-10-14.md; Scryfall's color identity,
  so mana symbols in rules text and color indicators count: Golos is Five-color, Ajani, Nacatl Pariah is Boros).
- Every exact combination is its own group, in this order: White, Blue, Black, Red, Green; Azorius WU, Dimir UB,
  Rakdos BR, Gruul RG, Selesnya WG, Orzhov WB, Izzet UR, Golgari BG, Boros WR, Simic UG; Esper WUB, Grixis UBR, Jund BRG,
  Naya WRG, Bant WUG, Abzan WBG, Jeskai WUR, Sultai UBG, Mardu WBR, Temur URG; Not white UBRG, Not blue WBRG,
  Not black WURG, Not red WUBG, Not green WUBR; Five-color WUBRG; Colorless.
- Headings of two colors or more carry the letters in WUBRG order: "Azorius · WU", "Not red · WUBG",
  "Five-color · WUBRG"; one color and Colorless are the name alone.
- Lands have no group of their own: a land sits in its identity like any card (Breeding Pool in Simic, Command Tower
  and fetch lands in Colorless, a Mountain in Red).
- Packs without the field (built before migration `20261028190000_pack_color_identity.sql` is applied, or a card
  not read since pair codes) fall back to the letters of the card's colors and mana cost, so lands read Colorless
  until the pack has it.

Shared cases: `testdata/card-grouping/cases.json` (`identity`, `colorIdentity`, `order.identity`, `identityLabels`);
iOS `CardGroupingTests` + `CatalogPackTests`, web `cardGrouping.test.ts` + `catalog.test.ts`, Android `CardGroupingTest`
+ `CatalogPackTest`; server `supabase/tests/45_catalog_pack_test.sql`.

