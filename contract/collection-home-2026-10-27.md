# Collection home (2026-10-27)

Figma `Hbkg1vKjdTFpwYt0NtCCYq` node 325:10820. Client-only; all three clients.

## Layout
- **Bar**: COLLECTION (12 pt, tracking 2, uppercase) on the page background, then **+** and **Search** icon buttons (50 × 50, Material weight 300 paths copied from Figma).
- **Collection shelf**: full width, 179 pt high. Up to two art crops side by side (Scryfall `art_crop`) under a 60 % background scrim; total cards bottom left, value (USD) bottom right, 9 pt muted. Tap: All cards.
- **Shelves**: Decks, Binders, Cubes. Each: 32 pt above, a 50 pt header (icon, title 12 pt tracking 2, arrow) that opens Decks / Binders / Cubes, then a sideways row of 258 × 135 tiles 1 pt apart. A tile is art crop + 60 % scrim + title (11 pt) and a detail line (9 pt muted) 16 pt from the bottom left.
  - Decks: yours (detail: format, or the event for a roto deck), then decks you follow (detail: owner).
  - Binders: yours (no detail), then binders you follow (owner).
  - Cubes: yours (no detail), then cubes you follow (owner).
  - A followed item with unseen updates shows "N new" in the accent at the right. Followed tiles show the art the follow list names (`art`, contract/follows-2026-10-25.md § Follow art; since 2026-11-03, before that they had none).
  - No decks / binders / cubes of your own: one tile, New deck / New binder / New cube.
- **Actions** along the bottom, above the tab bar: Trade (Trades) · Wants · Import (Import and export). 50 pt, 11 pt labels.

## Art
`ShelfArt` (iOS `LibraryViews.swift`, web `shelfArt` in `Library.tsx`, Android `ShelfArt` in `LibraryScreens.kt`): the place's hero cards (in the printing it holds), topped up with the first non-basic cards it holds, one per card. Collection: 2, ordered by NM market value. Decks/cubes: 1, main deck and commander by copies. Binders: 1, by copies.

## + and Search
- **+** menu: Add cards, New deck, New binder, New cube (the same panels as on Decks / Binders / Cubes).
- **Search**: the Add cards search (name or Scryfall syntax) titled Search, no scanner; each card shows how many copies you own; a tap opens its card page. Since 2026-11-02 it also finds decks, cubes and binders, yours and others' you can see (contract/library-search-2026-10-18.md § Collection search). Routes: iOS `.search`, web `/library/search`, Android `collection/search`.

## Moved
- **Trade matches** now sit inside Trades as a Matches section (person rows as on Trade matches; with none, one "No matches yet" row opens Trade matches, which explains how they start). The Trade matches screen stays (push taps and the desktop sidebar open it).
- **Following** is no longer a home row: followed items are on their shelves. The Following screen stays reachable from push taps and (web desktop) the sidebar.

## Telemetry
`collection_home_tap` `{target: add | search | trade | wants | import}`.
