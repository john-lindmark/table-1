# Plan: binders, "for trade" and wants (2026-10-17)

Roadmap item 3 of `review-2026-10-17.md`. Moxfield, ManaBox and Dragon Shield all have binders; Trades isn't much use
without a trade binder and a wishlist. Client contract: `contract/binders-wants-2026-10-17.md`.

## Shape

**The collection key doesn't change.** An item is still (card_id, finish, condition, lang) → qty, written only by
`collection_apply`, ledgered and synced by seq.

**Binders allocate an item's copies.** `binder_items` holds (binder, card_id, finish, condition, lang) → qty. Copies of
an item that no binder holds are **Unsorted**: `unsorted = item.qty − Σ allocations`. Invariant, checked by the tests
after every write: Σ allocations of an item ≤ its qty.

- A binder is `{id (client UUID), name (unique per account), for_trade}`. Up to 200 per account.
- **Adding** copies can name a binder (`binder_id` on a `delta > 0` op): they go straight into it. Otherwise they're
  Unsorted.
- **Removing** copies can name a binder (`binder_id` on a `delta < 0` op): those come out of it first. Whatever is
  still over-allocated after that shrinks in a fixed order: **Unsorted first, then binders not for trade, then
  for-trade binders**, each group by name (A→Z). So an edit, an undo or a sync from another device never leaves a
  binder claiming copies you don't have, and trade-binder copies are the last to disappear by accident.
- **Moving** copies between binders (or to/from Unsorted) is `binder_move`, strict: it refuses to move more than the
  source holds. It is a `collection_apply` batch whose item quantities don't change, so it's idempotent, ledgered
  (`binder_ledger`), and Undo works as for any batch.
- **Deleting** a binder sends its copies back to Unsorted (one ledgered batch; it can't be undone).
- Every allocation change happens inside `collection_apply_as`, under the same per-account lock as item writes, and
  writes a `binder_ledger` row in the same batch. Undo reverses item and binder changes together.

**Wants** are one wishlist per account: `(oracle_id, card_id?, finish?) → qty`, plus an optional max price (USD).
No card_id = any printing; card_id without finish = that printing in any finish. Written by `wants_apply` (batched,
idempotent, `want_ledger`).

**Missing** is a view, not data: every deck and cube line (not Considering, not roto event decks) you own fewer of
than it asks, per printing × finish, taking the largest need across lists (lists don't reserve copies, so one set of
copies covers every list). Computed on the device from the lists and the collection, like each list's Missing count.

**Sync.** One more delta feed, `library_changes(p_after)`: binders, allocations and wants changed after a cursor, from
the same global sequence as items, tombstones as qty 0 / `deleted`. Clients run it right after `collection_changes`.
Purged tombstones raise `library_summary.extras_floor`; a client behind it resyncs from 0.

## Trades
- A trade line can carry `binder_id`. On a give line it's the binder the copies come from; on a get line, the binder
  they go into. `trade_confirm` passes it to `collection_apply` (binders deleted since the draft are dropped, not an
  error).
- Clients default give lines to copies in for-trade binders: the picker lists for-trade copies first, and the give-side
  scanner prefers a printing (then condition) that a for-trade binder holds.
- Gets that match a want (or a Missing line) are highlighted. `trade_confirm` reduces the wants its gets satisfy, in
  the same batch: exact printing and finish first, then that printing in any finish, then any printing. Undoing the
  trade puts them back.

## Import and export
- ManaBox `Binder Name` with `Binder Type` `binder` → that binder (created if new; a name with "trade" in it is created
  for trade). `Binder Type` `list` rows are ManaBox wishlists, not owned: they become wants, not copies. `deck` rows
  are owned copies with no binder.
- Deckbox and Moxfield `Tradelist Count` → that many of the line's copies go into a for-trade binder called
  "Trade binder" (created if needed). Dragon Shield `Folder Name` → binder, `Trade Quantity` → "Trade binder".
- Add mode sends `binder_id` on the add ops. Replace mode sets item quantities first, then moves copies into binders
  (`binder_move`, chunked).
- Export: ManaBox layout gains its own `Binder Name`/`Binder Type` columns (one row per item × binder; Unsorted rows
  have no binder name). Moxfield fills `Tradelist Count` with the copies in for-trade binders.

## Clients (iOS, then web, then Android)
- Library home: **Binders** (count · how many for trade) and **Wants** (wanted · missing) rows.
- Binders screen: Unsorted + each binder (copies, value); new binder; a binder's screen lists its cards and offers
  rename, for trade on/off, delete.
- Wants screen: Wanted (qty, any printing / a printing, max price) and Missing from decks and cubes (which lists).
  Add a want from search or from card detail.
- Card detail: each owned item says where its copies are ("Trade binder 2 · Unsorted 1"); Move picks how many and
  where.
- Telemetry: `binder_created`, `binder_updated`, `binder_deleted`, `binder_copies_moved`, `want_added`,
  `want_removed`, and trade/import properties (`wants_met`, `binders`).
- Demo (`-T1LibraryDemo binders|wants`): the demo backend applies the same allocation rules locally.

## Tests
`supabase/tests/70_binders_wants_test.sql`: happy paths, wrong-account refusals, idempotent retries, shrink order,
undo, trade confirm with binders and wants, and the invariant after every `collection_apply` / `trade_confirm`.
Perf: `library_changes` first page and `binder_move` 500 moves in `perf_10_library.sql`. Client unit tests for the
Missing view, allocation display and import/export mapping.
