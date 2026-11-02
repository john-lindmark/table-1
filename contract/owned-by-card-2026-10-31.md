# Owning a card in any printing, Match collection, and what Follow unlocks (2026-10-31)

John (2026-10-31): "Decks shouldn't show cards as missing if their printing doesn't happen to match the printings of the
cards in your collection." In card detail from a deck: "set printings to match collection" and "pick from the grid of
available printings by tapping to select the number from each of the available printings in the collection." And:
"once you follow a deck or cube or binder the view should update to show the functions you now have available" (a
friend's cube shared by link could only be ranked after following it and opening it again from the Collection).

Shared cases: `testdata/owned-by-card/cases.json` from the Python reference `make_cases.py` (which also checks
`testdata/list-to-collection/cases.json`). Tests: iOS `OwnedByCardTests`, web `ownedByCard.test.ts`, Android
`OwnedByCardTest`.

## 1. Missing goes by card

Supersedes "Missing counts a line as covered only by owned copies of that printing in that finish"
(`contract/lists-2026-10-15.md`) and "per printing × finish" (`contract/binders-wants-2026-10-17.md`). Client-only.

- A deck or cube line is covered by **any copy of the same card** (Oracle id): any printing, finish, condition or
  language. Copies of the printing + finish the line names cover it first; then the card's other copies cover what's
  left, lines in list order. A copy covers one line of a list (lists still don't reserve copies from each other).
  Considering and basic lands never need copies and never use them (as before).
- Rule `shorts(lines, owned, oracleOf, basics)`: copies each line still needs. Everything else follows from it: the
  Decks/Cubes row ("3 missing" / "All owned"), a line's red mark and "missing N", a card with several printings
  ("Missing N"), grid and stack tiles.
- What a row says: "Owned N" counts copies of the card in any printing; a printing's own sub-row (a card with several
  printings, expanded) counts that printing and finish.
- **Wants → Missing** has one line per card: the largest shortfall across lists, shown as the printing of the first
  short line of the list that needs most. Trade gets are tagged "Missing · <list>" for any printing of a missing card.
- **Add to collection → Missing** (deck/cube screen and card detail) does not go by card: since 2026-11-01 it adds the
  exact printing, finish and language listed, counting only copies of those (contract/list-to-collection-2026-10-22.md).
- Before the catalog has loaded a printing is its own card (the old rule).

## 2. Match collection (card detail, deck or cube scope)

- In a deck or cube, when you own copies of the card in printings or finishes the list doesn't name, the info view's
  **In ⟨list⟩** part and the attribute area get a **Match collection** row: "You own N in other printings".
- It opens a bottom panel for one section (Main deck / Sideboard / Commander / Main; a segmented row when the card is
  in more than one): a grid of the versions you own (printing × finish, every condition and language together), two
  per row, each tile with "Own N" and the number picked for the section in accent.
- It opens filled in (**Auto**, rule `autoMatch`): versions the section already lists first, then the ones you hold
  most of, then by card id and finish, up to the section's copies.
- **Tap a tile** (rule `tap`): one more of it while you own more and copies are left to pick; otherwise it goes back
  to none. **Clear** empties the picks; **Auto** fills them again. Copies not picked stay in the printing they're in.
- **Use these printings** writes `list_edit` move ops `{card_id, board, finish, lang?, to_card_id, to_finish, qty}`
  (rule `matchOps`: lines that already are a picked version keep those copies, the rest move in list order to the
  picks in pick order; each copy keeps its language). Undo as for other list edits. Nothing to move: the button reads
  "Already matches".
- Telemetry: `match_collection_opened {kind, versions, copies}`, `match_collection_saved {kind, moved, versions,
  auto}`.

## 3. What Follow unlocks

- **Rankings on a cube opened through a link.** The server let only people who see a cube on its owner's profile rank
  it, and clients hid Rankings on a link. Now following a cube through a live link also counts as seeing it
  (`t1_private.cube_seen`, migration `20261031120000_cube_seen_followers.sql`): its Rankings row appears on the link
  screen as soon as you follow, and leaves if you unfollow (still there when you can see it on the profile).
  A cube opened by link that you don't follow says so on its Follow row: "… and rank it".
- Every shared screen reads the follow state from one store, so Following, Changes and Rankings show the moment
  Follow succeeds, without leaving the screen.

## Status

Built 2026-10-31 on iOS, web and Android; see CLAUDE.md for what's checked and live.
