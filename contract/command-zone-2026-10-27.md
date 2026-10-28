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
Commander and Oathbreaker decks (not roto decks) show **Command zone** at the top in every layout (list, grid, stacks; not while searching); the `commander` section is left out of the list below it then. The slots are cards **side by side**, at most 220 pt wide: Commander | Partner or background, Oathbreaker | Signature spell (label above each card: Commander, Partner, Oathbreaker, Signature spell). An empty slot is a card-shaped "+ Choose …" box with the hint. A filled card: Open card / Change … / Remove. Change is one `list_edit` swap op (to the new card, non-foil, English); filling an empty slot adds 1; Remove sets qty 0. (2026-10-28: was rows, list layout only, so a deck in grid or stacks had no way to set its commander.)

**In this deck** (2026-10-28): a deck made before the command zone has its commander in the main deck. A slot's picker opened from the deck screen lists the deck's own cards that fit first (`inDeck(role, lines)`: main deck, then sideboard; filtered by the search too), with **Move in**; the catalog follows under All cards. Moving in (`movingIn(line, slot)`): the slot's card, if any, moves to the main deck; a line with one copy moves (`{from, to: commander}`), a line with several gives one copy by deltas (−1 there, +1 commander). Android sends the ops as one edit; iOS and web one per op.

**Move to Commander / Command zone**: in Commander and Oathbreaker decks, edit mode's Move to … and card detail's Section picker offer the `commander` section too.

## Format
Edit mode on a deck or cube (not roto decks) has a **Format** row (current format, Change) opening the format menu (the New deck/cube formats, current one ticked). A pick calls `list_update(p_list_id, p_format)`; the cards stay as they are. Switching a deck to Commander or Oathbreaker shows the command zone to fill. Telemetry `list_format_changed {kind, from, to}`.

## Tests
Shared cases `testdata/command-zone/cases.json` (fits, slots, filling, role names, in_deck, move_in): iOS `CommandZoneTests`, web `commandZone.test.ts`, Android `CommandZoneTest`.

## Telemetry
`command_zone_set` `{format, cards, from: new}` on create; `{format, role, from: add | change | deck}` on the deck screen (`deck`: moved in from the deck's own cards).
