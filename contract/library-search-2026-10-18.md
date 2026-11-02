# Library: search in screens, want printings, cube remove/replace, adding to a binder (2026-10-18)

Client-only. No migration and no new RPC: everything uses `wants_apply`, `list_edit`, `binder_move` and
`collection_apply` as they are (`contract/binders-wants-2026-10-17.md`, `contract/lists-2026-10-15.md`,
`contract/collection-2026-10-15.md`). Same behavior on iOS, web and Android.

## Search inside a screen

- **Where:** a cube or deck (list screen), a binder (and Unsorted), the Binders screen (across every binder), and
  Wants (both Wanted and Missing).
- **Rule (`CardSearch.matches` / `cardMatches`):** every word of the query, normalized like card names
  (`CardName.norm`: lowercase, no accents or apostrophes, æ → ae, other runs → one space), appears in the card's name
  or its full type line. Empty query = everything. So "jace mind" finds Jace, the Mind Sculptor, "legendary creature"
  finds legends, "urzas saga" finds Urza's Saga.
- **Lists:** while a search is active the summary block (stats, Add, Version history, Export) is hidden, sections with
  no match are hidden, and stats/Missing/legality still count the whole list.
- **Binders screen:** the search lists every owned card that matches with where its copies are ("Trade binder 2 ·
  Box 1 1 · Unsorted 1"), most copies first; tap opens the card.

## Want a specific printing

- **Printing picker** (iOS `WantPrintingPanel`, web `WantPrinting`, Android `WantPrintingOverlay`): Any printing at the
  top, then every printing (original first) with rarity, year, language and market price. Tapping a printing wants it
  in any finish; a printing with more than one finish also shows a button per finish. More than 8 printings: a filter
  by set code, collector number or year (`matchesPrinting`: every word, split on spaces and `#`, starts the set code,
  number or year).
- **From:** Add a want (each search hit: tap the card for the picker, **Want** for any printing), card detail → Add to
  wants → **Pick a printing…**, and Wants → a want → **Printing** (replaces the old Only / Any printing items).
- **Changing an existing want** (`repointWant` / `BinderRules.repoint`): one `wants_apply` with two ops: the old want
  `qty: 0`, then the new key `delta: <old qty>` with the old `max_usd`. A want already at the new key is added to, not
  overwritten. Picking where it already points does nothing. Any printing always drops the finish.

## Cube (and deck) remove / replace

- The list's add screen is **Add, remove or replace** with two modes. **Add** is unchanged.
- **Remove or replace** searches only the list's own lines (`matchingLines`: same rule as above; nothing until
  something is typed), every section, by name. Each line: **Remove** (`list_edit` `delta: -1` on that line) and
  **Replace**.
- **Replace** keeps the line and switches the search to the catalog ("Replacing Chain Lightning · Main"); **Put in**
  sends one `list_edit` op `{card_id, board, finish, to_card_id, to_finish, qty: 1}` (the existing printing-swap op;
  the server doesn't require the same card), so one copy leaves and the new card's original printing arrives in the
  same section in one edit. `to_finish` is the new printing's first finish (non-foil when it has one).

## Add cards to a binder

- A binder (and Unsorted) has an **Add cards** row. It opens a catalog search; each card says how many are here and
  where the rest are, with:
  - **Move in** (only when you own copies elsewhere): one `binder_move` of 1 copy into this binder from
    `moveInSource`: Unsorted first, then binders not for trade, then for-trade binders, each by name; within one
    place, the item with the most copies there. Never from this binder.
  - **+ New**: one `collection_apply` add (source manual) of the card's original printing, its first finish, the
    condition last picked on card detail (default NM), with `binder_id` this binder (none for Unsorted).
  - The last action shows with **Undo** (`collection_undo` on its batch).

## Collection search (2026-11-02)

John: "allow users to search from collection to not just cards but also decks, cubes, and binders that are visible
to them". The Collection home's Search (contract/collection-home-2026-10-27.md) finds decks, cubes and binders above
the cards.

- **Field**: labelled Search, placeholder "A card, deck, cube or binder". Cards search as before (name or Scryfall
  syntax); lists show once the normalized query has 2+ characters.
- **Yours** are matched on the device, offline too: every normalized word of the query is in the name or the format
  code (`matchesList`; an empty query matches nothing), ordered names starting with the first word first, then by
  normalized name (`order`). Cases `lists` / `listOrder` in `testdata/library-search/cases.json`.
- **Everyone else's** come from `library_search(p_query, p_limit 20, max 50)` (signed in only, 300 ms after typing
  stops): items you can see on their owner's profile (friends', and anyone's set to Anyone on a public profile, the
  same rule as `profile_view`) or through the live link you followed with. Every lowercase word must be in the name,
  the owner's name or (decks and cubes) the format. Never your own, a deleted or demo account's, or across a block.
  Order: followed first, then friends', people you've played with, everyone else; names starting with the first word
  first, then by name. Each item: `kind`, `id`, `name`, `format`, `for_trade` (binders), `cards`, `owner`
  {display_name, avatar_url}, `user_id` (seen on the profile: opens their profile section) or `token` (seen through
  a followed link: opens the link), `following`. A failed call (offline) shows yours only.
- **Sections**: Decks · N, Cubes · N, Binders · N, yours first, then others'; three rows each and "Show all N" (all
  rows when there are four or fewer), then a Cards heading over the card rows. Rows: name; "Deck · Modern",
  "Cube", "Binder · For trade", plus the owner's name on someone else's; the right value is main-deck cards (decks,
  cubes) or copies (binders). Taps open your deck/cube/binder screen, their profile section, or the link.
- Not searched yet: the cards inside other people's lists ("decks with Ragavan").

Server: migration `20261102120000_library_search.sql`, tests `supabase/tests/84_library_search_test.sql`, budget in
`perf_10_library.sql` (20k lists: ~15 ms locally). Clients: iOS `Library/ListSearch.swift`, web `lib/listSearch.ts` +
`screens/ListSearch.tsx`, Android `library/ListSearch.kt`. Design QA: iOS `-T1LibraryDemo search -T1SearchQuery tr`,
web `/library/search?demo` (the demo's followed items stand in for other people's).

## Telemetry (`contract/telemetry-2026-10-15.md`)

`library_searched` (`screen`), `list_card_removed` / `list_card_replaced` (`kind`), `want_added` gains `finish`,
`want_changed` gains `printing`, `any_printing`, `finish` when repointed. Binder adds count as `binder_copies_moved`
and `collection_changed` as before. Screens `want_printing`, `binder_add`. Collection search:
`search_list_opened` (`kind` deck / cube / binder, `whose` mine / following / shared).

## Code and tests

- iOS: `Library/Catalog.swift` (`CardSearch`), `Library/Binders.swift` (`BinderRules.repoint`, `moveInSource`,
  `places`), `Library/BindersViews.swift`, `Library/CardLists.swift` (`ListLine.matching`, `ListsStore.replaceCard`).
- Web: `lib/librarySearch.ts`, `screens/Binders.tsx`, `screens/Lists.tsx`.
- Android: `library/LibrarySearch.kt`, `library/BindersScreens.kt`, `library/ListScreens.kt`.
- Tests: shared cases `testdata/library-search/cases.json`; iOS `LibrarySearchTests`, web `librarySearch.test.ts`,
  Android `LibrarySearchTest` (search cases, repoint, Move in order, Replace swap, remove search).
- Design QA: iOS `-T1LibraryDemo cube|wants|binder|binders`; web `/library/cubes?demo`, `/library/wants?demo`,
  `/library/binders?demo`. Android has no Library demo.
