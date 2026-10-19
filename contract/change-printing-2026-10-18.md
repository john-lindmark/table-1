# Change printing everywhere: client contract (2026-10-18)

Client-only: no new RPC or migration. Builds on `list_edit`'s swap op (`contract/lists-2026-10-15.md`),
`collection_apply` with `binder_id` (`contract/binders-wants-2026-10-17.md`) and trade drafts
(`contract/trades-2026-10-16.md`).

## Why

Card detail lists every printing, but its buttons only add copies to the collection. A deck or cube line's printing
could only be changed from Edit → tap a line, owned copies (in the collection or a binder) and trade gets couldn't be
changed at all. Every card line that names a printing now offers **Change printing**, on one shared screen.

## Where

| Opened from | What changes | How |
|---|---|---|
| Deck or cube → tap a card (list, grid or stacks; also Add, remove or replace) | Card detail opens with an **In ⟨list⟩** section first: each of the card's lines (section, printing, finish, count) with **Change**. Edit → tap a line → Change printing or finish still works. | `list_edit` swap op `{card_id, board, finish, to_card_id, to_finish, qty}` |
| Binder (or Unsorted) → tap a card | Card detail opens with an **In ⟨binder⟩** section first: that binder's copies of the card with **Change**. | `collection_apply`, below |
| Card detail → open an owned item | **Change printing** row (next to condition and Move). | `collection_apply`, below |
| Trade → tap a get | **Change printing** in the line menu (gives are copies you own: remove and add another). | Draft edit; merges into a get that already has that copy |
| Wants → tap a want | **Change printing** (was "Printing"), unchanged: `WantPrintingPanel`, which also offers Any printing. | `wants_apply` |

Card detail's hero shows the context's printing (the list line's or the binder copy's) until another is tapped.

## The screen

Bar "Change printing" + card name, back arrow. The line as it is (printing, finish, and section / condition and
language / trade condition, with its count). Owned copies in more than one place: **From** (each binder, then
Unsorted, with counts; defaults to the binder card detail was opened from, else the place with the most). **Change
n of N** stepper when more than one copy can move (not for trade gets, which move whole). A search field (set,
collector number or year, `CardSearch`) once there are more than 8 printings. Then every printing: art, set and
number, rarity, year, Original, language, price, and a button per finish ("Current" disabled on the line's own).

## Owned copies

One `collection_apply` batch (source `manual`), so card detail's **Undo** reverses it:
```
{card_id: old, finish: old, condition, lang, delta: -n, binder_id: place}
{card_id: new, finish: new, condition, lang', delta: +n, binder_id: place}
```
`place` is the binder chosen in From; Unsorted sends no `binder_id` (removals shrink Unsorted first). Condition stays;
language stays unless the new printing is itself non-English (then its language). Nothing is sent when the new
item key equals the old one, n < 1 or n > the item's qty. Decks and cubes don't follow: they name printings on their
own.

## Telemetry

`printing_changed` (`where`: list / collection / binder / trade, `copies`, `finish_only`). Screens `list_printing`
(unchanged), `item_printing`, `trade_printing`; `library_searched` with screen `change_printing`.

## Status

- **iOS** built 2026-10-18 (`Library/ChangePrinting.swift`; card detail context in `LibraryViews.swift`; trades in
  `Trades.swift`). Tests `Table1Tests/ChangePrintingTests` (ops, language, trade merge, binder copies + undo through
  the demo backend). Demo: `-T1LibraryDemo deckcard|deckprinting|bindercard|binderprinting`.
- **Web, Android:** to do.
