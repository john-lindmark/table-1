# Command zone: commander, oathbreaker and signature spell (2026-10-27)

Client-only; all three clients. No server change: command-zone cards are lines in the deck's existing `commander` section (`list_create` entries / `list_edit` ops), so exports, stats (the commander is never in a sample hand) and Missing already treat them right.

## Formats
- Deck formats gain **Oathbreaker** (`oathbreaker`). Commander and Oathbreaker are the command-zone formats.
- New deck format rows: iOS/Android Modern Pioneer Standard Legacy / Vintage Pauper Canlander Other / Commander Oathbreaker; web (narrower panel) six across three, then four across two.

## Slots
`slots(format, lines)` over the deck's command-zone lines in order:
- **Commander**: one slot per line (at most two): Commander, then Partner or background. While there are fewer than two, an empty slot follows (Choose a commander / Add a partner or background).
- **Oathbreaker**: Oathbreaker = the first planeswalker line; Signature spell = the first instant or sorcery line. Missing ones are empty slots.
- Other formats: none.

Which cards a slot offers (`fits`, on the type line's front face; lenient, legality still has the last word): Commander / Partner: Legendary Creature, Legendary Planeswalker, or Background. Oathbreaker: Planeswalker. Signature spell: Instant or Sorcery.

The `commander` section is titled **Command zone** for Oathbreaker decks, **Commander** otherwise.

## New deck
Picking Commander or Oathbreaker shows **Command zone** with a row per slot. An empty row opens the picker; a filled row offers Change / Remove. The picker is the catalog search (name or Scryfall syntax) filtered by `fits`; a tap takes the card's original paper printing. Create sends the slots' cards as `commander` entries (qty 1, non-foil, English). `filling(lines, slotCard, new)`: the slot's card is replaced in place, else the new card is added; picking a card already in another slot moves it.

## Deck screen
Commander and Oathbreaker decks (not roto decks) show **Command zone** above the rows (rows layout, not while searching); the `commander` section is left out of the list below it then. A filled row: Open card / Change … / Remove. Change is one `list_edit` swap op (to the new card, non-foil, English); filling an empty slot adds 1; Remove sets qty 0.

## Tests
Shared cases `testdata/command-zone/cases.json` (fits, slots, filling, role names): iOS `CommandZoneTests`, web `commandZone.test.ts`, Android `CommandZoneTest`.

## Telemetry
`command_zone_set` `{format, cards, from: new}` on create; `{format, role, from: add | change}` on the deck screen.
