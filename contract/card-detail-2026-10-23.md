# Card detail, rebuilt: client contract (2026-10-23)

Client-only: no new RPC or migration. Design: Figma `Hbkg1vKjdTFpwYt0NtCCYq` section 318:10810 (iOS page):
Collection / Search / Multicard / Multicard Selected / info view frames, and the Printing, Language, Condition,
Add To and Add to Drilldown pickers. Writes go through what already exists: `collection_apply` (with `binder_id`),
`list_edit` (add, swap, move ops), `wants_apply`, `trade_save`. Shared cases: `testdata/card-detail/cases.json`.

## Why

Card detail was a long list (owned rows, printings with + buttons, uses, wants, hero, history). The new screen is
the card itself: the big image, one row of attributes, and one bottom bar. Every tap on a card thumbnail or list
row opens it (the deck and binder Add cards pickers keep their own pick-and-add flow), wherever the card is (collection, deck, cube, binder, search, a friend's profile).

## Scope

The screen is opened **in a scope**; the scope decides which copies it shows and what its edits change.

| Opened from | Scope | Copies shown | Attributes | Bottom bar |
|---|---|---|---|---|
| All cards, Add cards (collection), Binders search, web link `/library/card/<id>` | Collection | every owned copy of the card | Set · Language · Condition · Finish | − count + (owned copies) |
| A deck or cube (list, grid, stacks, version history) | That list | the card's lines in that list | Set · Finish · Section | − count + (copies in the list) |
| A binder or Unsorted | That binder | its copies in that binder | Set · Language · Condition · Finish | − count + (copies in the binder) |
| Wants, Missing, a friend's profile, a shared deck or link, trade matches | Search | nothing (a version to add) | Set · Language · Condition · Finish | **Add to** |

A **version** is what the scope counts: owned copies are printing × finish × condition × language; list lines are
printing × section × finish.

## Layout (Figma frames)

- **Bar**: back arrow, card name, price, then **+** (owned scopes only: opens Add to, see § Add to) and
  the **list** icon, which flips to the info view (the icon becomes **tune**, which flips back). The price is the
  version on screen in its finish (USD market); with several versions and none selected, the one you hold most of.
- **Card**: one version (or none): the card image, as large as fits, in its finish (foil sheen). Tap → full-screen
  zoom. Double-faced printings get **Flip** under the image.
  Two or more versions: a **grid**, two per row, one tile per version with its count when more than one; scrolls
  past four. Tap a tile to select it (accent outline); tap it again to deselect.
- **Attributes**: equal cells in one row. Each shows the value the copies in view share, or **MIX** when they
  differ. Condition and Language are hidden in list scope (John, 2026-11-01; Language showed 2026-10-26 to 11-01): a line's language and condition come from the copies added to it (contract/lists-2026-10-15.md § Conditions) and are never picked there. Finish is hidden when every printing in view has one
  finish. A non-English printing's language is its own and its cell doesn't open.
- **Bottom bar**: owned scopes: − | count | + (count = copies in view, or the selected version's). With a version
  selected the stepper steps that version (Figma 318:10715; it was off before 2026-10-26). Search scope: **Add to**.
- **Undo**: after any change a strip above the attributes says what changed, with Undo (collection batches; list
  edits undo by a reverse edit).

## Attribute pickers

Bottom panels in the Selector style (rows 50 pt, centred uppercase labels, the current value outlined in accent):
- **Set**: every printing of the card, four per row, earliest first; the current one outlined.
- **Language**: every Scryfall language, the eleven common ones first.
- **Condition**: NM, LP, MP, HP, DMG.
- **Finish**: the finishes the printing has (Non-foil / Foil / Etched).
- **Section** (list scope): Main deck / Sideboard / Considering (cubes: Main / Considering; Commander when used).

## What a pick changes

Owned scopes: **a pick changes the copies in view** (all of them, or the selected version's).
- More than one copy would change: ask first. One version: **One copy** / **All N copies**. Several versions
  (MIX), none selected: **Change all N?**.
- Owned copies keep their places: each binder's (and Unsorted's) copies are taken out and put back in the same
  place (one `collection_apply` batch, `delta` ops with `binder_id`). Binder scope moves only that binder's copies.
- **Set**: same finish if the new printing has it, else its first finish; a non-English printing brings its own
  language, otherwise the copy keeps its language. **Finish**, **Condition**, **Language**: just that field.
- List scope: Set and Finish are `list_edit` swap ops (one per line), Section is a move op.
- Nothing in view (count 0) or Search scope: a pick changes the version on screen, nothing is written.

## Stepper

- **+** adds one of the version on screen (in binder scope into that binder; in list scope to that line's section).
- **−** removes one from it (binder scope: from that binder; collection: Unsorted first, as `collection_apply`
  does).
- A version selected: both act on it. Several versions, none selected: both act on the version you hold most of.
- At 0 the screen keeps the last version's attributes, so + puts it back. New versions start as the card's
  original printing, first finish, the condition and language picked for adds (shared with the scanner).

## New edition (long press on +, 2026-10-26)

Figma 360:8704 → 360:8609. Holding the stepper's **+** (owned scopes, at least one version held) makes a **new
edition**: a copy of the selected version (else the one held most of) with count 1, added to the grid as its own tile,
**selected** and **dimmed** (the image under a 60% background-colour veil). Nothing is written yet; a strip says
"Change its set, language, condition or finish to add it." (list scope: set, language, finish or section).
- Picks in the attribute row change only the edition. While it matches a version the scope already holds it stays
  dimmed; the first pick that makes it a version the scope doesn't hold **writes it**: one `collection_apply` op of
  `+count` (into the binder in binder scope, Unsorted otherwise) or one `list_edit` delta op in its section, with Undo,
  and the tile becomes that version, still selected. Undo strip: "Added N MB2 #218 · Foil · LP".
- Before it's written, − and + change its count (− at 1 drops it); leaving the screen drops it.
- One edition at a time; the long press does nothing while one is open or nothing is held. Web: hold 450 ms, or
  right-click. A held press never also counts as a tap.
- Rules: `newEdition(from)` and `isNew(edition, versions)` (cases `new_edition`, `editions`).

## Add to

From the bar's **+**, when more than one copy is in view, a menu asks first: **One copy** / **All N copies** (with
a version selected, N is that version's copies and the menu says "this version only"). One copy adds 1 of the version
on screen; All adds every version in view with its count (rule `addLines`, cases `add_lines`). Search scope's bottom
**Add to** always adds one. The counts carry through every destination: collection and binder ops are `+count`,
deck/cube lines add `count` of each printing (finish fallback per printing), wants are one per printing (and finish)
with the summed count ("Each printing" / "Each printing and finish" when the lines span printings), trade lines carry
their counts.

Bottom panel: **Collection**, **Deck**, **Cube**, **Binder**, **Want**, **Trade**. Drilldowns swap in place with a
back arrow and the step's name:
- Collection: adds 1 of the version on screen.
- Deck: your decks (name, format) → section (Main deck / Sideboard / Considering) → adds 1 of the printing in
  the finish on screen.
- Cube: your cubes → adds 1 to Main.
- Binder: your binders → adds 1 new copy straight into it.
- Want: **Any printing** / **This printing** / **This printing and finish**.
- Trade: your open trades plus **New trade** → adds the version as a **Get** (**Give** too, when you own it).
Condition and language go with collection, binder and trade adds, and with deck and cube adds since 2026-11-01 (the line records them); wants ignore them.

## Info view (list icon)

Smaller image, the rules text (from Scryfall's API for that printing, fetched once when the view opens; offline it
says so), then Price, Card type, Rarity, Artist rows. Under them, the rest of the old screen:
- **In ⟨list⟩** add to collection (list scope): the missing copies, all listed, or one of a listed printing.
- **In decks and cubes** (count used vs owned; tap opens the list).
- **Binders**: where each owned version sits, with Move.
- **Wanted** (want one more / open wants), **Hero** (make it a hero of the scope), **History** (the ledger for the
  printing on screen).

## Telemetry

`card_attribute_changed {attribute, scope, copies, mix, selected}`, `card_stepped {scope, delta}`,
`card_added_to {destination, scope, copies}`, `card_edition_started {scope, versions}`,
`card_edition_added {scope, attribute, copies}`, `card_info_opened {scope}`, `card_version_selected {versions}`,
`card_flipped`, `image_zoomed {screen: card_detail}`.

## Status and demo

iOS built, unit-tested (`CardDetailTests` on the shared cases; `LanguageTests`, `ChangePrintingTests` share the
place-keeping rule) and checked in the Simulator demo: `-T1LibraryDemo multicard` (grid, select, condition change,
Undo, info view, Add to → deck → section), `searchcard` (Add to, printing picker, add to collection), `deckcard`
(list scope). Web and Android built since (see below). Not yet tried signed in.

New edition, stepper on the selected version, and one-or-all Add to (2026-10-26): all three clients. iOS built,
unit-tested and checked in the Simulator (`-T1LibraryDemo onecard`: a card held in one version; long press +, pick
LP, + on the selected version, bar + → All → Binder). Web built, tested and checked in `/library/cards?demo` at
phone width (right-click and a 600 ms hold, pick LP, − drops an edition, bar + → All 3 → Deck → Sideboard). Android
built and unit-tested, not run on a device.
