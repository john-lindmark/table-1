# Command zone: commander, oathbreaker and signature spell (2026-10-27)

Client-only; all three clients. No server change: command-zone cards are lines in the deck's existing `commander` section (`list_create` entries / `list_edit` ops), so exports, stats (the commander is never in a sample hand) and Missing already treat them right.

## Formats
- Deck formats gain **Oathbreaker** (`oathbreaker`). Commander and Oathbreaker are the command-zone formats.
- New deck format rows: iOS/Android Modern Pioneer Standard Legacy / Vintage Pauper Canlander Other / Commander Oathbreaker; web (narrower panel) six across three, then four across two.

## Slots
`slots(format, lines)` over the deck's command-zone lines in order:
- **Commander**: one slot per line (at most two): Commander, then Partner or background. With no line, an empty Commander slot; with one, an empty partner slot only when that commander can pair (§ Partners).
- **Oathbreaker**: Oathbreaker = the first planeswalker line; Signature spell = the first instant or sorcery line. Missing ones are empty slots.
- Other formats: none.

Which cards a slot offers (`fits`, on the type line's front face; lenient, legality still has the last word): Commander: Legendary Creature or Legendary Planeswalker. Partner: those or a Background, then only cards that pair (§ Partners). Oathbreaker: Planeswalker. Signature spell: Instant or Sorcery.

The `commander` section is titled **Command zone** for Oathbreaker decks, **Commander** otherwise.

## Partners (2026-10-28)
A commander takes a second card only when it can pair, read from the catalog pack's `pair` code (contract/catalog-2026-10-14.md): `P` partner, `P:<name>` partner with, `G:<group>` partner—group, `F` friends forever, `B` choose a Background, `D` doctor's companion, empty = none; a Time Lord Doctor pairs with a doctor's companion.
- `canPair(typeLine, pair)`: unknown (no code: an older pack or a card not read yet), any code, or a Time Lord Doctor. A Commander deck with one command-zone card shows the empty partner slot only then; two lines always show both.
- `pairs(commander, candidate)` (each `Mate`: type line, pair, name): P with P, F with F, `P:<name>` with the card of that name, `G:<group>` with the same group, B with a Background, D with a Time Lord Doctor and the Doctor with D. Unknown on either side falls back to the partner slot's type rule.
- The partner picker (catalog hits and In this deck) offers only cards that pair; for Partner with it opens searching the named card.
- `partnerHint(commander)` is the empty partner card's hint and the picker's subtitle: "Another commander with partner", the named card, "Another with partner—<group>", "Another commander with friends forever", "A Background", "The Doctor", "A doctor's companion"; unknown keeps "Optional: a second commander".
- `fits`: the Commander slot takes a legendary creature or planeswalker; a Background only fits the partner slot.

Cases `can_pair`, `pairs`, `partner_hint` (and slots with pair codes) in `testdata/command-zone/cases.json`.

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
