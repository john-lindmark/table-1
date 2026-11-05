# Sideboard guides (2026-11-04)

John, 2026-11-04: "Build the ability to define a sideboard guide for decks. it should show which cards come in, which
come out for different matchups. there should be the ability to add cards past the regular 15 so you can consider more
cards as you build out the sideboard guide. you should be able to add notes for each matchup. and you should add the
ability to print the guide and the printed version should match the styling of Table 1. follow the magic competitive
play rules for the printed guide where applicable."

## Model
- A deck (not a cube, not Commander or Oathbreaker) has at most one guide: `{matchups: [{id, name, archetype?, in:
  [[oracle_id, qty]], out: [[oracle_id, qty]], notes}]}`. `id` is a UUID the client makes; `archetype` is the Insights
  archetype id when the matchup was picked from the meta (null when typed); cards are by **card** (oracle id), not
  printing, so changing a printing never breaks the guide; `in` and `out` keep the order cards were added.
- Limits: 40 matchups, 40 cards a side, names 1–40 characters (trimmed), notes up to 1000 (trimmed), quantities 1–99,
  one entry per card a side (the server merges repeats where the card first appeared).
- **Cards past 15:** a matchup's In draws from the sideboard **and Considering** (the existing `maybe` section). The
  In picker's search adds a card to Considering and brings it in at once, so players can try more than 15 cards while
  building the guide; the Sideboard screen moves a card between Sideboard and Considering and says how many matchups
  bring it in.

## Server
Migration `20261104160000_sideboard_guides.sql`, tests `supabase/tests/44_sideboard_guide_test.sql`.
- `card_lists.sideboard_guide jsonb`; `list_json` answers carry `guide` (null when none), so it syncs with
  `lists_changes`. It goes **only to the owner**: shared decks, profiles and share links don't carry it (not yet:
  sharing a guide, which would need moderation of names and notes).
- `list_guide_set(p_list_id, p_guide)` (authenticated, owner, decks only; 22023 on a bad shape or a cube) replaces the
  whole guide; null or no matchups clears it; returns the list. The same guide again doesn't move the seq. Last write
  wins: clients send the whole guide 0.8 s after the last change, through the list queue (sent again offline).

## Rules (testdata/sideboard-guide/make_cases.py, cases.json)
- `check(matchup)`: In and Out counts as asked, the deck size after (main + in − out, each capped at what the deck
  has), and issues in the matchup's order: `gone` (the card left the deck or the sideboard), `in_over` / `out_over`
  (more than the deck has), `considering` (copies that come from Considering, not the sideboard), `below_min` (under
  60, Canadian Highlander 100; no minimum for Other). The row line is `IN 3 · OUT 3` or `NO CHANGES`. Ins needn't match
  outs (Tournament rules allow any exchange that keeps the deck legal).
- Sideboard over 15 in a constructed format (CR 100.4a) is flagged on the guide and the print; Other isn't checked
  (it may be Limited).
- `uses`: how many matchups bring each card in.

## Printing (MTR 2.11, Feb 2026: "Between games, players may refer to a brief set of notes made before the match …
removed from the play area before the beginning of the next game … more than a sheet or two … may be penalized as slow
play"; electronic notes only at Regular REL)
- The printed guide is what a player may use at Competitive REL, so it holds **only what can come in**: Considering
  copies are left out (the print preview says how many), cards no longer in the deck are left out, outs are capped at
  the main deck's copies.
- The rule is printed under the header: `MTR 2.11 · BETWEEN GAMES ONLY · REMOVE FROM THE PLAY AREA BEFORE EACH GAME`.
- `sheets` estimates pages; over two the preview warns (a sheet or two).
- The page is HTML in Table 1's type and grid on light paper: SF Mono (ui-monospace), uppercase tracked labels, 1 px
  hairline boxes with zero radius, the teal accent only as the line under the header (teal text doesn't read on paper,
  and printers drop dark backgrounds). Matchups flow in two columns, each box kept whole; In `+2 Fury` | Out `−1 Name`;
  notes below; the registered sideboard last. Every client builds it with the same rule and must produce
  `testdata/sideboard-guide/guide.html` byte for byte.
- iOS prints it with `UIPrintInteractionController` from a WKWebView, web from a hidden iframe, Android through
  `PrintManager` with a WebView's print adapter. Each shows a preview first (the page itself) with the warnings and
  a Print action. Telemetry `sideboard_guide_printed` {matchups, left_considering, sheets}.

## Screens (all three clients)
- Deck screen: a **Sideboard guide** row under Stats (decks with a guide format), data line `N MATCHUPS · SIDEBOARD 15`.
- **Sideboard guide**: bar with back, title, `add` (new matchup) and `print`. Rows per matchup (name, `IN 3 · OUT 3`,
  marked when it has issues); a Sideboard row (`SIDEBOARD 15 · CONSIDERING 3`) and a notice when the sideboard is over
  15. Tapping a matchup opens it.
- **New matchup**: the deck's format's Insights archetypes by share (when Insights has the format), then a typed name.
- **Matchup**: bar with the name and a menu (Rename, Move up, Move down, Delete). IN and OUT as two cells; each opens
  its picker. Below, the plan (In cards `+2`, Out cards `−2`), the issues as one-line notices, and Notes (tap to edit).
- **In picker**: Sideboard then Considering cards with steppers (0 … copies in the deck); a search that adds a card to
  Considering and brings one in. **Out picker**: main deck cards with steppers.
- **Sideboard**: Sideboard then Considering, each card with `IN N MATCHUPS`; a tap moves one copy to the other section.
- Telemetry: `sideboard_guide_opened`, `sideboard_matchup_added` {from: archetype|typed}, `sideboard_card_considered`,
  `sideboard_guide_printed`.

## Not yet
- Sharing a guide with a deck's audience, exporting it as text, duplicating it with Duplicate deck, separate plans on
  the play and on the draw (notes carry those for now).
