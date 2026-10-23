# Add a deck or cube to the collection, and zoom on made pictures (2026-10-22)

Client-only on all three platforms; no server change. Writes go through `collection_apply` like every other collection
change (source `import`, so a bulk add never reads as a hand add after a scan), as one batch with Undo.

## 1. Add to collection from a deck or cube

A row on every deck and cube screen (not while editing, not on an empty list, not on a roto deck, whose cards are the
cube's): **Add to collection**, detail "Missing N · or every card" or "You own every card · add more copies". It
opens a full screen:

- **Missing N | Every card M** (segmented, Missing first). Missing adds only what the collection lacks of each
  printing + finish; Every card adds every copy listed.
- **Sideboard** switch on decks with a sideboard (on by default).
- Condition (NM…DMG) and **New copies in** language: the same remembered choices as card detail's Add a printing.
  An English printing goes in as the picked language; any other printing in its own.
- A note: each card goes in as the printing and finish the list names; Considering isn't added.
- **To add · N**: one row per printing + finish with `+n`.
- **Add N cards** (accent). After it: "Added N cards to your collection.", an **Undo** row, and the button becomes
  **Done**.

Rule (`ListToCollection.ops` / `listAddOps`): Main and Commander always count; a deck's sideboard unless switched
off; Considering never. Needs are summed per `card_id|finish` across sections, then Missing subtracts what's owned of
that printing + finish over every condition and language. Ops are sorted by card_id, then finish; only delta > 0.
More than 5,000 printings at once is refused with a message (the batch limit). Shared cases:
`testdata/list-to-collection/cases.json` (iOS `ListToCollectionTests`, web `listToCollection.test.ts`, Android
`ListToCollectionTest`).

## 2. Add to collection from card detail in a deck or cube

Card detail opened from a deck or cube gets an **Add to collection** row under "In <list>" (detail "Missing N · the
printing listed here" or "You own every copy listed here"; trailing Add). It opens a menu:

- **Add the N missing** (when something is missing): the same rule as above, limited to this card's printings.
- **Add all M** (when different from the missing count): every copy of this card the list lists.
- **Add 1 <set #cn> [· finish]** for each of up to four listed lines (Considering lines included here: you picked it).

All use the condition and language under Add a printing, land as one batch, and show the usual Undo bar.

## 3. Zoom on the deck image and the top 100 / top 50 image

The preview on Deck image and Top N image is tappable, with a "Tap the picture to zoom" row under it (web: "Click").
It opens the picture full screen with the same title bar:

- iOS: pinch to zoom, drag to pan, double-tap toggles fitted ↔ 3× around the tap (UIScrollView). No edge swipe-back
  on this screen (a drag from the edge pans); the back arrow closes it.
- Android: pinch, drag, double-tap the same (Compose transform gestures).
- Web: wheel or trackpad pinch zooms around the pointer, drag pans, double-click toggles 3×, + / − / 0 on a keyboard,
  Esc closes only the zoom view.
- Scale runs from fitted (1) to 8×; while the picture is smaller than the screen it stays centered, and once larger
  it can't be dragged past an edge. Web and Android share the math (`lib/zoom.ts`, `Zoom` in `ZoomImage.kt`), tested
  with the same numbers.

## Telemetry

- `list_added_to_collection` {kind, mode: missing / all / one, sideboard, copies, lines, from: list / card}
- `image_zoomed` {screen: deck_image / ranking_image}

## Design QA

iOS Debug: `-T1LibraryDemo deck|cube -T1AddToCollection` opens the add screen; `-T1LibraryDemo deckcard` shows the
card detail row; `-T1LibraryDemo deck -T1DeckImage -T1Zoom` and `-T1LibraryDemo rankimage -T1Zoom` open the zoom
view. Web: `/library/decks?demo` → a deck → Add to collection / Deck image.
