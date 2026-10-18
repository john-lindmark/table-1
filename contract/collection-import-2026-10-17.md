# Collection import and export: CSV (2026-10-17)

Library → **Import and export**. A CSV export from another collection app goes in as one import (`collection_apply`
source `import`, then Undo); the collection comes out as a CSV in Moxfield's or ManaBox's layout, so the data
round-trips. No new server code: parsing and matching run on the device against the catalog pack
(`contract/catalog-2026-10-14.md`), writes are ordinary `collection_apply` batches (`contract/collection-2026-10-15.md`).
Decks and cubes still import through `list-import` (`contract/list-import-2026-10-15.md`).

Built on iOS (`Library/CollectionCSV.swift`, `Library/CollectionImport.swift`, route `.collectionImport`) and web
(`lib/collectionCsv.ts`, `screens/CollectionImport.tsx`, `/library/import`). Android follows in a later batch.
Fixtures: `testdata/collection-import/` (the same 24 cards as each app exports them, plus one line no catalog has;
`make_fixtures.py` rebuilds them; `expected.json` is what each resolves to).

## Reading a file

- **Text:** UTF-8 with or without a BOM. Delimiter is whichever of `,` `\t` `;` appears most in the header line outside
  quotes. RFC 4180 quoting (`""` inside quotes, newlines inside quotes, CRLF or LF). A first line `sep=,` (Dragon
  Shield, Excel) sets the delimiter and is skipped. Blank lines and lines with neither a name nor a Scryfall id are
  skipped silently; a line with quantity 0 is skipped.
- **Headers** are compared normalized: lowercase, only `a-z0-9` kept (`Collector's number` → `collectorsnumber`).
- **Format** is detected from the header, first match wins:

| Format | Detected by | Real layout (from the app's own export) |
|---|---|---|
| Delver Lens | `QuantityX` or `Delver Local ID` | tab-separated: `QuantityX` (`2x`), `Name`, `Edition` (set name), `Foil` (`Foil`/blank), `Price`, `Scryfall ID`, `MultiverseID`, `Delver Local ID`, `TCGPlayer productID`. Delver's site presets (Moxfield, Deckbox, TCGplayer…) produce that site's layout and are read as it. |
| Dragon Shield | `Folder Name` + `Card Name` | optional `"sep=,"` line, then `Folder Name, Quantity, Trade Quantity, Card Name, Set Code, Set Name, Card Number, Condition, Printing, Language, Price Bought, Date Bought, LOW, MID, MARKET` |
| TCGplayer | `Simple Name`, or `TCGplayer Id` + `Product Name` | `Quantity, Name, Simple Name, Set, Card Number, Set Code, Printing, Condition, Language, Rarity, Product ID, SKU` |
| ManaBox | `ManaBox ID`, `Binder Type` or `Purchase price currency` | `[Binder Name, Binder Type,] Name, Set code, Set name, Collector number, Foil, Rarity, Quantity, ManaBox ID, Scryfall ID, Purchase price, Misprint, Altered, Condition, Language, Purchase price currency` |
| Archidekt | `Edition Code` + `Edition Name`, or `Date Added` + `Finish` | `Quantity, Name, Finish, Condition, Date Added, Language, Purchase Price, Tags, Edition Name, Edition Code, Multiverse Id, Scryfall ID, Collector Number` (columns are configurable there; any subset reads) |
| Deckbox | `Tradelist Count` + `Card Number` | `Count, Tradelist Count, Name, Edition, Edition Code, Card Number, Condition, Language, Foil, Signed, Artist Proof, Altered Art, Misprint, Promo, Textless, Printing Id, Printing Note, Tags, My Price, Cost, Rarity, Price, TcgPlayer ID, Scryfall ID` |
| Moxfield | `Tradelist Count` + `Edition` | `Count, Tradelist Count, Name, Edition, Condition, Language, Foil, Tags, Last Modified, Collector Number, Alter, Proxy, Purchase Price`, every field quoted |
| Other | a name or Scryfall id column | read by the column names below |

A file with no name and no Scryfall id column is refused: "This file has no card name column."

- **Columns** (normalized names; the first present wins):

| Field | Columns | Notes |
|---|---|---|
| name | `simplename` (TCGplayer: its `Name` carries `[Version 2]` and `(Foil Etched)`), `name`, `cardname`, `card`, `productname` | |
| quantity | `quantity`, `count`, `qty`, `quantityx`, `totalquantity`, `amount` | digits only (`2x` → 2); empty → 1; not a number → the line is unmatched ("Quantity isn't a number") |
| set code | `setcode`, `editioncode`, `code`; Moxfield's `edition` | lowercased. Dragon Shield `GK1_*`/`GK2_*` → `gk1`/`gk2` |
| set name | `setname`, `editionname`, `expansion`; `edition` (Deckbox, Delver Lens); `set` (TCGplayer) | Other formats: a lone `set`/`edition` is tried as a code, then as a name |
| collector number | `collectornumber`, `cardnumber`, `collectorsnumber`, `number`, `cn` | trimmed; `12/281` → `12` |
| finish | `foil`, `finish`, `printing` | contains `etched` → etched; blank, `normal`, `nonfoil`, `non-foil`, `false`, `no`, `0` → non-foil; contains `foil` or `true`/`yes`/`1` → foil. TCGplayer: `(Foil Etched)` in `Name` → etched |
| condition | `condition` | see below; blank or unknown → NM. TCGplayer seller exports append ` Foil` (→ foil) |
| language | `language`, `lang` | names or codes → Scryfall codes: English en, German de, French fr, Italian it, Spanish es, Portuguese pt, Japanese ja/jp, Korean ko/kr, Russian ru, Chinese Simplified / Simplified Chinese / Chinese / zh-CN zhs, Chinese Traditional / Traditional Chinese / zh-TW zht, Hebrew he, Latin la, Ancient Greek grc, Arabic ar, Sanskrit sa, Phyrexian ph, Quenya qya; unknown → en |
| Scryfall id | `scryfallid` | |

- **Conditions.** ManaBox and Dragon Shield grade on Cardmarket's scale; everyone else on TCGplayer's.

| Ours | TCGplayer scale (Moxfield, Archidekt, Deckbox, TCGplayer, Delver Lens, other) | Cardmarket scale (ManaBox, Dragon Shield) |
|---|---|---|
| NM | Mint, Near Mint, M, NM | mint, near_mint / NearMint |
| LP | Lightly Played, Good (Lightly Played), Slightly Played, Excellent, Good, LP, SP, EX | excellent, good |
| MP | Moderately Played, Played, MP | light_played / LightPlayed |
| HP | Heavily Played, HP | played |
| DMG | Damaged, Poor, D, DMG | poor |

## Matching (per line)

1. **Scryfall id**, when the file has one and the catalog has that printing.
2. **Set**: the set code if the catalog has that set, else the set name looked up in `mtg_sets` (normalized like card
   names; read with the anon key, paged 1000 rows a call, cached on the device). Then:
   - **set + collector number** (as written, then lowercased, then without leading zeros). When the line also names a
     card and the printing is a different card, this step is skipped (a wrong number doesn't win over the name).
   - **set + name**: that card's printings in the set.
   Among several printings, the printed language that matches the copy's language wins, then English, then the
   card's original printing, then the lowest collector number.
3. **Name** → the card's **original printing** (catalog `original`). Names match exactly (normalized), a front face
   matches its card (`Brazen Borrower` → `Brazen Borrower // Petty Theft`), and failing that, the name without a
   trailing `[...]`/`(...)` or ` Token`/` Emblem`. Two cards with the same name: the non-token one with more printings.

The finish is the file's when the printing has it; otherwise etched falls back to foil, then the printing's first
finish (non-foil first). Condition and language come from the file (the copy's language, which can differ from the
printing's). Lines that land on the same card, finish, condition and language are summed.

Lines that match nothing are listed with their line number, name, set and quantity. **Fix** opens a card search with
the name filled in; the picked card resolves like step 2 (its printing in the line's set when it has one) or step 3.
**Skip** drops the line. Nothing unmatched is ever written.

## Preview

Format, file name and line count; matched cards (copies) and printings; unmatched lines; total value in USD
(`card_prices_get` market prices × copies, "of N priced"). Then **Add to collection** (default) or **Replace collection**.

## Writing

- **Add:** one op per item, `delta` = the file's copies.
- **Replace:** the collection becomes the file: one `qty` op per item in the file, and `qty: 0` for every item held
  now that the file doesn't have (after a sync first). The confirm dialog (native alert) says how many cards that
  removes. Never mixes `qty` and `delta` for one item.
- Ops go in chunks of **5000** (the RPC's limit), one `collection_apply(…, 'import', null, key)` per chunk. Each
  chunk's key (a UUID) is made when Import is tapped and kept until the import finishes, so retrying after a failure
  resends the failed chunks with the same keys and a chunk that did land replays as `{duplicate: true}`. A failure
  partway says how many parts went in and offers Try again. 20k lines ≈ 4 batches, far under 120/minute.
- **Undo** undoes every chunk's batch (the batch id is the key), newest first.

## Export

From the same screen: **For Moxfield** / **For ManaBox**, shared as a file (`table1-collection-<layout>-<date>.csv`).
One row per item (card × finish × condition × language), sorted by name, set and number. Items whose printing isn't
in the local catalog yet are left out and counted ("2 cards newer than the card data were left out").

- **Moxfield** (every field quoted, CRLF): `Count, Tradelist Count (0), Name, Edition (set code), Condition (Near Mint …
  Damaged), Language (English …), Foil (blank/foil/etched), Tags, Last Modified, Collector Number, Alter (False),
  Proxy (False), Purchase Price`.
- **ManaBox:** `Name, Set code (upper case), Set name, Collector number, Foil (normal/foil/etched), Rarity, Quantity,
  ManaBox ID (blank), Scryfall ID, Purchase price, Misprint (false), Altered (false), Condition (Cardmarket scale:
  near_mint, excellent, light_played, played, poor), Language (code), Purchase price currency (USD)`.

Both read back through the importer to the same items (tested on each platform). Lossy on the way out to other
apps only where their scale is coarser (ManaBox's `good` reads as LP and goes out as `excellent`).

## Telemetry (`contract/telemetry-2026-10-15.md`)

Screen `collection_import`. Events: `collection_import_previewed` (`format`, `lines`, `matched`, `unmatched`),
`collection_imported` (`format`, `mode`: add / replace, `cards`, `items`, `parts`, `fixed`, `skipped`),
`collection_exported` (`layout`: moxfield / manabox, `cards`). Each chunk also sends `collection_changed` with
`source: import`. No file names or card names.

## Design QA without signing in

iOS Debug: `-T1LibraryDemo import` opens the screen; add `-T1ImportFile <path>` to read a file as if picked and
`-T1ImportAuto import|undo` to skip unmatched lines and import (then undo) without taps. Web dev: `/library/import?demo`
(drop a file on the page). Demo prices cover only the demo collection's cards, so an imported file's value shows "—".

## Performance

Parsing a 20,000-line ManaBox file and matching it against the full catalog have budgets: iOS
`CollectionImportPerfTests` (Debug, Simulator), web `collectionCsv.perf.test.ts` (`./test.sh perf`). See TESTING.md.
