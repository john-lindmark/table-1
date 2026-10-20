# Library polish (2026-10-19)

A batch of Library changes from John's notes. Hero cards have their own contract (`library-heroes-2026-10-19.md`).

## Navigation
- Every screen with a back arrow also goes back with a swipe from the left edge: pushed screens use the system gesture
  (iOS: re-enabled while the system bar is hidden); full-screen panels follow the finger and close past a third of the
  width or on a flick. The camera (scanner, photo picker) doesn't swipe away.
- The Collection tab's home is titled "Collection" (was "Library").

## Sorting and order
- All cards → Price: a card with no price sorts first, as if it were the most valuable (those are the ones to look up).
- Card detail lists printings earliest first (release date, then pack order), most recent last: In collection and Add a
  printing alike.

## Decks and cubes
- The number row at the top of a deck or cube (Main / Side / Considering / Missing) is gone; section headers keep their counts
  and each line still says what's missing.
- **Add, remove or replace** works like Cube Cobra's edit panel: an Add box and a Remove or replace box on one screen. Pick a
  card in either (tap a result, or Return for the top one). With only Remove picked the button removes one copy; with both
  picked it reads Replace and swaps that copy for the added card in the same section, as one edit. Add adds into the chosen
  section; the + on a result adds at once. Remove/Replace searches only the list's own cards.

## Printings, collapsed
- In All cards, a deck/cube and a binder, a card with several printings (or finishes) is one row: name, total, "N printings",
  and a chevron that opens one row per printing and finish (indented, set and number, finish, price or owned). Collapsed by
  default and on every visit. View → Expand all printings / Collapse all printings opens or closes every card (binders: an
  Expand / Collapse bar button). Grid and stacks show one card per Oracle card, or with Expand all, one per printing.
- Deck/cube Edit mode always shows every line (edits are per line).

## Foil
- Foil copies get a light rainbow sheen over the card image (a diagonal spectrum blended into the art plus one soft highlight
  band); etched gets a dimmer one. Shown wherever the finish is known: deck/cube lines, owned copies, binders, trades, the
  scanner's list, expanded printings.

## Scan everywhere you add cards
- Scan sits next to the search on every Add cards screen: the collection (as before), a deck or cube (scanned cards go into the
  chosen section as one edit, in the printing and finish read), a binder (new copies straight into the binder, one batch, one
  Undo) and Add a want (each scanned card is wanted once, any printing). Trades already had it.

## Advanced search
- Every Add cards search box takes Scryfall's syntax; **Adv** opens a form (name, card text, type line, colors with
  exactly / including / at most, mana value, rarity, set code, legal in) that writes the syntax into the box.
- A plain name is the usual ranked name search. A query whose keys the card data on the phone carries runs offline:
  name (bare words, "quoted", !exact), t/type, c/color (letters, color and guild/shard names, c / m, counts, = : <= >= < > !=),
  mv/cmc (numbers, even, odd), m/mana, r/rarity, s/set/e, cn/number, year, date, lang, is:foil/nonfoil/etched,
  f/format/legal, banned, restricted, produces, with -, or, and parentheses. Set, rarity, year, … match printings, and the hit
  shows (and adds) the matching printing.
- Anything else (o: card text, power, identity, artist, …) is sent to Scryfall's search API (`/cards/search`, one card per Oracle
  card, by name, with a User-Agent) after typing settles, and hits are matched back to the local data by printing id.
  Offline, it says card text needs a connection. A status line shows the count and "from Scryfall".
- Cases shared by every platform: `testdata/card-query/cases.json` (queries, whether they run locally, matches; the form's output).

## Binder views
- A binder (and Unsorted) has View like All cards and decks: List, Grid or Stacks (remembered), plus Expand all
  printings. Who sees this and Add cards stay at the top in every view. Grid and stacks show one card per Oracle card,
  or one per printing and finish with Expand all; heroes get their outline.

## Scanner reads the guide box
- The scanner looks only at the card in the guide box drawn over the camera, so cards lying around it are never read:
  - Of the card-shaped rectangles found, it reads the one whose centre is inside the guide (grown by a quarter, for a
    card held a little off), nearest the guide's centre. Before, the largest anywhere in the frame won.
  - With no card found in the guide, only text whose centre is inside the guide (grown 10%) is read. Before, all the
    text in the frame was.
- The guide box is the same rect on screen and in the image: 72% of the camera view's width (or what its height
  allows), card-shaped, centred; mapped into the image the way the preview fills the view (aspect fill, cropped).
- iOS: `ScanRegion` in `CardScanner.swift`, tests `Table1Tests/ScanRegionTests.swift`. Not yet tried on a real camera.
  Android to do (same rule over ML Kit's text blocks and its card rectangle).

## Status
iOS built, unit-tested (`CardQueryTests`, `ScanRegionTests`) and checked in the demo.
Web (2026-10-19): built, unit-tested (`src/lib/cardQuery.test.ts`, same cases) and checked in `/library?demo`. No scanner on the web,
so no Scan; back is the browser's. Browsers can't set a User-Agent, so Scryfall requests carry the browser's own.
Android (2026-10-19): built and unit-tested (`CardQueryTest`, same cases); not yet run on a device. Back: system back and
predictive back (`enableOnBackInvokedCallback`); full-screen panels are dialogs, so back closes them. Scan on every Add cards
screen; `scan_session_ended` is now sent on Android for every context (it wasn't for add/trade before).
