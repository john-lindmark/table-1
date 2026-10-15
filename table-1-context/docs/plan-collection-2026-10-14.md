# Plan: Collection experience (Library), built to be fast and to scale (2026-10-14)

Builds on `plan-library-scanning-nav.md` (2026-10-13) and the build-order summary from chat. This doc covers the **Library**: catalog, collection, imports, decks/cubes, trades, scanner. Email sign-in and the nav pass are separate tracks; they're listed in the order below only for sequencing.

Status: **approved 2026-10-14** (John accepted the recommended defaults in section 9). **L0 server side live since 2026-10-15** (first sync: 77 s, pack `v1-bfb1f1616afb`). **L1 server live 2026-10-15; web client built** (signed-in UI not yet tried by John). iOS/Android L1 next in a batch.

---

## 1. Build order (merged)

| # | Track | Notes |
|---|---|---|
| 1 | Nav + progressive disclosure (Figma first) | Play / Library / Insights / Account. Library top level is a summary only. |
| 2 | Email sign-in (OTP) + finish Google | Small; unblocks testers. |
| 3 | **L0 Card catalog** | Foundation for all of Library. Server table plus an on-device catalog pack. |
| 4 | **L1 Collection core** | Data model, RPCs, local store + delta sync, All cards, manual add. |
| 5 | **L2 Imports** | CSV / decklist paste: ManaBox, Moxfield, Cube Cobra. |
| 6 | **L3 Decks + Cubes** | Same underlying structure ("card lists"). |
| 7 | **L4 Trades** | Ledger in/out; confirm applies atomically. |
| 8 | **L5 Scanner** | Spike runs **in parallel from L0** (photo set + iOS prototype against the catalog pack). Ship it after Trades. |

Why the scanner spike runs early but ships late: it's the riskiest piece, and it depends only on the catalog pack (L0). So we can measure accuracy while L1 to L4 are being built, and ship it once there's a collection and trades to scan into.

Per feature: Figma, then John's review, then **web**, then **iOS**, then **Android** in a batch. The scanner is native only (web gets search and import).

---

## 2. Performance and scale principles

1. **Write logic once, server-side.** Matching, import resolution and trade application live in Postgres RPCs, so the three clients stay thin.
2. **Batch everything.** One RPC per import chunk, scan batch or trade confirm, never one call per card.
3. **Clients hold a local copy of the user's own data** (SQLite / Room / IndexedDB) and sync **deltas** by revision number. Browsing, filtering and searching your own collection are local and work offline.
4. **Card data comes from our catalog, never from the Scryfall API at runtime.** Images load straight from Scryfall's image CDN (`cards.scryfall.io`) with a disk cache. We never proxy them.
5. **Keyset pagination only** (`where (name, id) > (...)`), never `offset`.
6. **Every user-owned table leads with `user_id`** in its primary key or index. RLS policies use `(select auth.uid())`, the initplan-cached form already used in the tracker migration.
7. **Counts are materialized, and so is the ledger.** `collection_items.qty` is written in the same transaction as an append-only `collection_ledger` row, so counts can always be rebuilt and checked. This is a deliberate difference from standings, which are computed: summing a 50k-row ledger on every read would be too slow, while standings are small.
8. **Summaries are pre-computed** per user (a `library_summary` row updated inside the mutation RPCs), so the Library top level costs one row read.

### Sizing assumptions (to design against)
- Catalog: about 110k printings and about 35k unique names. Grows by about 3k a month.
- Heavy collector: 30–100k physical cards, which aggregate to **5–30k rows** (one per printing × finish × condition × language).
- 10k users × 10k rows is about **100M rows** at the far end. A composite PK leading with `user_id` handles that on a single Postgres instance. We'd look at hash partitioning by `user_id` only past that point; it's not needed now.

---

## 3. L0: Card catalog

### Server tables
```
cards            -- one row per Scryfall printing (default_cards bulk)
  id uuid pk (scryfall id), oracle_id uuid, name text, name_norm text,
  set_code text → mtg_sets, collector_number text, lang text, rarity text,
  finishes text[], layout text, type_line text, mana_cost text, cmc numeric,
  colors text[], color_identity text[], released_at date,
  image_version bigint,          -- enough to build the CDN URL; no full URIs stored
  content_hash bytea,            -- for diff-upsert
  updated_at timestamptz
  unique (set_code, collector_number, lang)      -- import + scanner resolution
  index (oracle_id)
  gin (name_norm gin_trgm_ops)                    -- fuzzy search (pg_trgm)
  btree (name_norm text_pattern_ops)              -- prefix typeahead

card_prices      -- separate table so daily price churn doesn't rewrite card rows
  card_id pk, usd, usd_foil, eur, eur_foil, updated_at
```

### Sync (`cards-sync`, live 2026-10-15)
Measured on the real bulk file (2026-10-14): 80 MB gzipped, 648 MB of JSONL, 118,740 cards, of which **109,573 are paper printings across 37,866 Oracle cards**. Parsing all of it costs about 2.2 s of CPU on an M5, more than an edge function's 2 s per request, and it doesn't fit in 256 MB of memory. So the sync runs in steps, each within the limits:
- **stage** (daily pg_cron, 23:23 UTC): if Scryfall's `updated_at` hasn't changed, stop. Otherwise stream and gunzip the file into ~32 MB line-aligned pieces in the private `catalog-staging` bucket (20 pieces). About 0.8 s of CPU locally; the edge runtime is slower, so this is the step to watch. **Fallback:** `supabase/tools/catalog-stage.ts` does the same staging from any machine (Mac or a scheduled job). Everything after staging stays on Supabase.
- **chunk** ×20: parse a piece (worst piece measured at 150 ms of CPU locally), then upsert in batches of 1000 through `catalog_ingest`. Rows whose content hash hasn't changed are skipped, so a daily run mostly writes prices. `t1_private.catalog_dispatch` runs three chunks at a time through pg_net, and a cron tick every 2 minutes re-queues stuck chunks (3 attempts).
- **pack**: only when card data changed. The version is a hash of the content, so an unchanged catalog is never re-published. Keeps the newest three packs.
- **Card-level data:** printings disagree on name, layout or legalities for 624 cards (reversible "Forest // Forest", 30th Anniversary and other non-legal printings). Each card's data comes from a deterministic source printing (`t1_private.catalog_source_rank`), so chunk order never makes it flip.
- **Dry run** (the full migration plus test calls on the live DB, rolled back): diffing, rank stability, search (prefix, typo, face names, diacritics), the chunk state machine and the cron registration all checked out.
- **Storage use:** about 80 MB in the database, plus about 650 MB of staging that's deleted after each run. Fine on the current plan.
- **First production run (2026-10-15 00:48 UTC):** staging fit inside the edge CPU budget, so the fallback script wasn't needed. The 20 chunks ran three at a time at about 6 s each, and the whole run took 77 s. Result: 109,573 printings, 37,866 cards, 42,026 searchable names, 89,892 printings with a price. The catalog takes 90 MB in the database. The pack is 5,576,360 bytes, and its sha256 checked out after download. An immediate second run skipped (same bulk file). Search takes 1–40 ms on the database (two-letter prefixes are the slowest) and about 270 ms per call from a client, including the network. Follow-up migrations: `20261015010000_card_search_rank` (a full-name match beats a face-name match) and `20261015011000_catalog_invoker` (read RPCs run as the caller).
- **Ops:** watch `t1_private.catalog_runs` for status `failed`. If staging ever goes over the CPU budget, run `supabase/tools/catalog-stage.ts` (needs the service-role key in the environment).

### On-device catalog pack
- The sync job builds a compact **catalog pack**: a gzipped TSV of cards and printings (format in `contract/catalog-2026-10-14.md`), published to the public `catalog` bucket. **Measured: 5.5 MB gzipped.** Clients load it into their own local SQLite. TSV instead of a prebuilt SQLite file, because building SQLite inside an edge function would exceed the CPU budget.
- **Egress:** each new pack costs every active client about 5.5 MB. Packs change when cards change, which is about daily during spoiler season. That's fine at tester scale; before a wide launch, add delta packs (only the P/O lines changed since a given version). Tracked as an L1 follow-up.
- Clients download it once, then again only when the hash changes (new sets: about monthly, plus errata). The app works on the old pack until the new one has downloaded.
- Used for: scanner matching, offline typeahead when adding cards, and resolving decklists on the client for instant preview. The server still re-resolves on commit.

---

## 4. L1: Collection core

### Tables
```
collection_items           -- the current state
  user_id, card_id, finish ('nonfoil'|'foil'|'etched'), condition ('NM'..'DMG'), lang,
  qty int check (qty > 0), added_at, rev bigint
  primary key (user_id, card_id, finish, condition, lang)
  index (user_id, rev)                      -- delta sync
  (rows deleted when qty reaches 0; a tombstone goes to the ledger)

collection_ledger          -- append-only, the source of truth for "what happened"
  id bigserial, user_id, card_id, finish, condition, lang, delta int,
  source ('manual'|'import'|'scan'|'trade'|'adjust'), source_id uuid, at, rev bigint
  index (user_id, rev)

library_summary            -- one row per user, top-level numbers
  user_id pk, total_qty, unique_printings, unique_names, est_value_usd, est_value_eur,
  decks, cubes, open_trades, rev, updated_at
```

- **`rev`**: one per-user counter bumped by every mutation. A client asks for `library_changes_since(rev)` and gets changed rows plus tombstones. That's an index range scan, cheap even for 30k-row collections.
- **One mutation RPC**, `collection_apply(p_ops jsonb, p_idempotency_key uuid)`. It takes an array of `{card_id, finish, condition, lang, delta}`, applies the ops with `insert … on conflict do update` via `unnest`, writes the ledger rows, bumps rev, updates the summary and stores the result in `rpc_idempotency`. Manual add, scan batches, imports and trades all go through it, so there's one code path and one audit trail.
- Locking: the RPC sorts ops by key before writing, so two concurrent batches can't deadlock.
- Value: the nightly price sync recomputes `est_value_*` per user in one set-based statement. The mutation RPCs adjust it incrementally between runs.

### Client
- A local table mirroring `collection_items`, joined to the catalog pack for names and types. Filters (color, set, type, rarity, foil) and sort run **locally**, so they're instant.
- The first sync for a large collection is one paged download (keyset by `rev`, 5k rows per page). After that, only deltas.
- Web: IndexedDB with the same delta protocol. Rows are virtualized, so a 30k-row list renders only what's on screen.

### Screens (progressive disclosure)
- **Library home:** summary only. Total cards, estimated value, then four rows: All cards (count) · Decks (n) · Cubes (n) · Trades (n open). No card lists on this screen.
- **All cards:** search field, filter chips, virtualized list. Grouped by card name with a printings count; tap a name to see its printings, tap a printing to see detail and the qty editor.
- **Card detail:** image, printings you own, which decks/cubes use it, ledger history (one tap deeper).

---

### L1 status (2026-10-15)
- **Server** (`20261015120000_collection_core.sql`, applied): `collection_items`, `collection_batches` (idempotency key + undo unit, kept permanently), `collection_ledger`, `library_summary`. RPCs `collection_apply`, `collection_undo`, `collection_changes`, `library_summary_get`, `collection_card_history`. Each user's writes are serialized on their summary row, so per-user `seq` grows in commit order. Tombstones (qty 0) are purged after 30 days, with a resync floor. Values are recomputed nightly at 01:07 UTC. Account deletion removes the collection. A rolled-back dry run on the live DB covered the arithmetic, idempotent replay, every rejection path, delta sync, undo, tombstones and purge, RLS, and the private-schema denial.
- **Contract:** `contract/collection-2026-10-15.md` and `rpc.schema.json` (43 RPCs).
- **Web:** `src/lib/catalog.ts` (pack loader + local search: 1.7 ms over 37,866 cards; about 150 ms to parse the cached pack) and `src/lib/collection.ts` (per-account IndexedDB mirror, delta sync, apply/undo). Screens in `src/screens/Library.tsx`: `/library` summary, `/library/cards` (virtualized, grouped by card, A–Z / Recent / Most), `/library/card/:oracleId` (owned copies ±1, add any printing and finish, live prices, history, undo), `/library/add`. The Collection tab is live in the top nav. Built on the existing kit ahead of Figma Library screens; restyle when they land.
- **iOS/Android L1** built (separate session, 2026-10-15). **iOS tested on the simulator in Debug demo mode** (`-T1LibraryDemo`, no sign-in, demo fixture of 2,000 cards plus five Modern decks and a Vintage cube): summary, All cards (search, sort, empty state), Add cards search ranking, card detail (image, ±1, add a printing, undo, history), Decks and Cubes (read-only first L3 views: per-list owned/missing, grouped by type for decks and by color for cubes), and the card page's "used vs owned" flag when lists ask for more copies than you own. The signed-in server path on iOS is not yet tried; it needs John's Apple sign-in.
- **Not yet:** condition and language editing in the UI (the server supports both), local fuzzy search (typos; the server `search_cards` has it), delta packs, and native clients.

## 5. L2: Imports

- Inputs: CSV (ManaBox, Moxfield, Cube Cobra exports) and decklist paste (`4 Lightning Bolt (2X2) 117`, MTGO/Arena formats). Link import comes later.
- **Format detection** is done by header row. There's one column-mapping table per source, kept in a single shared spec under `contract/`.
- **Resolution, in priority order:** Scryfall ID (ManaBox and Moxfield exports include it), then `(set, collector_number, lang)` through the unique index, then exact `name_norm`, then trigram fuzzy match. Whatever is left is returned as **unmatched lines** for the user to fix.
- **Two steps: preview, then commit.**
  1. `import_preview` parses and resolves in chunks of 2k lines and returns a diff: adds, unmatched lines, and conflicts with existing qty. Nothing is written yet.
  2. `import_commit(import_id)` applies the diff through `collection_apply` (source = `import`, source_id = import_id), so it's idempotent and can be undone as a whole.
- Large files (50k+ lines) go up to Storage first, and the server processes them in chunks while the client shows progress. The app never sends a 10 MB request body.
- Target modes: **add to collection**, **replace collection** (shows the diff first), **into a new deck/cube** (optionally also adding the cards to the collection).

---

## 6. L3: Decks and Cubes

One shared structure, so decks and cubes are written once:
```
card_lists          id, user_id, kind ('deck'|'cube'), name, format, rev, updated_at
card_list_entries   list_id, card_id (printing) or oracle_id (any printing), board ('main'|'side'|'maybe'|'commander'), qty
                    primary key (list_id, board, card_id/oracle_id)
```
- **Decks don't reserve copies (recommended).** "In decks" is **derived**: the sum of list qty per oracle/printing against what you own. Nothing has to be kept in sync, so it can't drift. The UI shows "3 owned · 4 in decks" and flags shortfalls.
- Lists sync through the same `rev` delta protocol.
- Deck view: summary first (count, curve, colors, owned %), then the list one tap deeper. Cube view: count and color balance, then the list.
- Ties into Play later: register a deck for an event, and Insights can show win/loss by deck.

---

### L3 status (2026-10-15, iOS ahead of server)
Built on iOS against a local store (the Debug demo fills it). Nothing about decks or cubes reaches the database yet; that needs the L3 tables below.
- **Sections:** decks have Main deck, Sideboard and Considering; cubes have Main and Considering (board values `main`, `side`, `maybe`, plus `commander`). Considering is ideas, not commitments: it never counts as missing and never counts against the copies you own (the card page lists it separately).
- **Create and edit:** a New deck / New cube row (name and format), Add cards (search, then +Add straight into the chosen section), and Edit mode on a list (−/+ per line; tap a card to move it to another section or remove it). The card page has "Add to a deck or cube".
- **Version history (git-like):** a list is a series of versions; its contents are the newest. Every change appends a version, and edits within 10 minutes of each other are grouped into one. Restoring an old version appends a copy of it ("Restored v3"), so history is never rewritten. Each version shows its date, note and +/− counts, and opens to a per-section diff against the version before it.
- **Server design for L3** (not built): `card_lists` (id, user_id, kind, name, format, current_version), `card_list_versions` (list_id, version, created_at, note, entries jsonb snapshot; append-only, primary key (list_id, version)), `card_list_entries` (the current version materialized for queries: list_id, card_id, board, qty). Writes go through one RPC per edit batch that appends or extends the open version in a transaction, the same pattern as `collection_apply`. Clients sync lists by `updated_at` and version number.

### Card corners (2026-10-15)
Measured from Scryfall's transparent PNG scans: every printing 4.32% of card width (≈2.7 mm), **Alpha 6.99%** (≈4.4 mm, a rounder cutting die), Collectors' and International Edition square. Applied on iOS, web and Android; spec in `contract/catalog-2026-10-14.md`.

## 7. L4: Trades

```
trades        id, user_id, counterparty_user_id null, counterparty_name null, status ('draft'|'confirmed'|'void'),
              note, created_at, confirmed_at
trade_lines   trade_id, direction ('out'|'in'), card_id, finish, condition, lang, qty
```
- **Draft:** add lines manually, by scan (out = matched against owned cards only) or by search (in = full catalog). It's saved locally and on the server, so a half-built trade at a table survives losing connection.
- **Confirm:** `trade_confirm(trade_id, resolutions, idempotency_key)` runs in **one transaction**.
  1. Check that every "out" line is owned at that qty. If one isn't, reject and name the lines.
  2. Check deck usage (derived, see section 6). If an outgoing card is used in a deck or cube, the client must pass a resolution per line: `remove_from_lists` or `keep_in_lists` (the deck then shows it as missing). With no resolution, the RPC rejects. This is the "warn and require a choice" rule, enforced on the server.
  3. Apply all lines via `collection_apply` (source = `trade`), apply the list resolutions, then mark the trade confirmed.
- **Void** a confirmed trade by writing the reverse ops. The ledger keeps both, so nothing is ever deleted.
- Two-party trades between Table 1 users (each side confirms) come later. The `counterparty_user_id` column already allows it.

---

## 8. L5: Scanner

The pipeline is unchanged from `plan-library-scanning-nav.md`. Performance targets and how we get there:

| Target | Value |
|---|---|
| Time to match (good light) | < 500 ms from card entering the frame |
| Batch throughput | ≥ 1 card/sec sustained |
| Title accuracy on test set | ≥ 98% top-1 |
| Printing accuracy | ≥ 90% auto, the rest resolved with one tap |
| Network calls per scan | 0 (commit is batched) |

- **Frame budget:** rectangle detection runs on throttled frames (about 10–15 fps). OCR runs **only on a stable, deskewed crop** of the title band and bottom-left info line, never on the whole frame.
- **Matching runs in memory:** the catalog pack's names load into a SymSpell-style index (precomputed deletions), so a fuzzy lookup over about 35k names takes microseconds. In Trades the index is built from **owned cards only**, which is smaller, faster and more accurate.
- **Consistency gate:** the same match on N consecutive stable crops (start at 3 and tune on the test set).
- **Printing:** the OCR'd collector number and set code (printed bottom-left on modern cards) go through the `(set, collector_number)` lookup. Fallback order: the set the user scanned last in this session, then the newest printing, then a one-tap printing picker. Art perceptual hashing is a **later** option (it needs a bigger pack), only if the test set shows we need it.
- **Batch mode:** matches go into a local buffer with an undo for the last card. One `collection_apply` call on Done, or every 50 cards, so a crash loses little.
- **Battery:** the camera session stops when the app goes to the background or after 60 s with nothing detected.
- **Spike deliverables (parallel to L0/L1):** a photo test set of 300+ shots (backgrounds, lighting, sleeves, foils, old frames, non-English), an iOS prototype on the catalog pack, and a CSV report of accuracy and time-to-match. Android ML Kit parity is checked against the same set.

---

## 9. Decisions (accepted 2026-10-14)

John accepted the recommended defaults: (1) derived deck usage, no reservations; (2) finish always, condition/language optional with NM/EN defaults; (3) prices: no recommendation was given, so the catalog stores both USD and EUR and the display currency becomes a user setting (default to be picked with the Library home design); (4) single-sided trades first; (5) catalog sync host decided by the L0 spike; (6) past events under Insights.

Original options:

1. **Deck copies: derived (recommended) or reserved?** Derived means decks never lock copies and shortfalls are shown. Reserved means copies are allocated to decks, which costs more to keep consistent.
2. **Which attributes to track per copy?** Recommended: finish always; condition and language optional, defaulting to NM / EN. Each one multiplies rows and import complexity.
3. **Prices:** show an estimated value? USD (TCGplayer), EUR (Cardmarket), or a per-user setting?
4. **Two-party trades in v1, or single-sided ledger first?** Recommended: single-sided first.
5. **Catalog sync host:** edge function if streaming fits, otherwise a GitHub Action. Settled by the L0 spike, not by John, but it adds a dependency on GitHub secrets.
6. **"Past events out of the ledger":** still assumed to mean history under Insights.

## 10. Figma screens needed before L1 builds
Library home (summary) · All cards (list, filters) · Card detail (printings, in-lists, history) · Add card (search + scan entry) · Import (source pick → preview diff → done) · Deck/Cube summary + list · Trade draft · Trade confirm with deck-conflict choice · Scanner (single + batch, match chip, printing picker).
