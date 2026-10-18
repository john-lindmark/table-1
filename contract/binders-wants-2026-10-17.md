# Binders, "for trade" and wants: client contract (2026-10-17)

Server: migration `20261017140000_binders_wants.sql`. Plan: `table-1-context/docs/plan-binders-wants-2026-10-17.md`.
Builds on `contract/collection-2026-10-15.md` (items, `collection_apply`, delta sync) and `contract/trades-2026-10-16.md`.
Tests: `supabase/tests/70_binders_wants_test.sql`; budgets in `perf_10_library.sql`.

## Model

- **Items don't change.** An item is still (card_id, finish, condition, lang) → qty.
- **Binder:** `{id, name, for_trade, deleted, seq}`. The client makes the `id` (UUID), so creating is idempotent and
  shows at once. Names are unique per account (case-insensitive, among binders not deleted), 1–60 characters; at most
  200 binders.
- **Allocation:** (binder, card_id, finish, condition, lang) → qty: how many of an item's copies that binder holds.
  **Unsorted** = item qty − the item's allocations. The server guarantees allocations never add up to more than the
  item's qty; clients still clamp Unsorted at 0 while a sync is half applied.
- **Want:** `(oracle_id, card_id?, finish?) → qty` (1–999) with an optional `max_usd`. No `card_id` = any printing;
  `card_id` without `finish` = that printing in any finish. One wishlist per account, at most 5000 wants.
- **Missing** isn't stored. It's every deck and cube line (not Considering; not roto event decks) that you own fewer
  copies of than it asks for, per printing × finish, with the largest need across lists (lists don't reserve copies).
  Each Missing line names the lists that need it.

## How copies move

- **Adding copies into a binder:** a `collection_apply` op with `delta > 0` and `binder_id`. Without `binder_id` they're
  Unsorted.
- **Removing copies:** an op with `delta < 0` may name `binder_id`: those copies come out of that binder first.
  Whatever the item's allocations then exceed its qty by comes out of: **Unsorted first, then binders not for trade,
  then for-trade binders**, each group by name A→Z. A `qty` op works the same way (it's a removal when lower).
- `binder_id` with a `qty` op is refused. A `binder_id` that isn't one of your live binders is refused ("That binder
  is gone").
- `collection_apply` results gain `binder_items`: the allocation rows it changed, as in `library_changes`. Apply them
  to the local store with `items`.
- **Undo** (`collection_undo`) reverses a batch's item and allocation changes together: copies go back into the binder
  they left, and copies a batch put in a binder come out of it. Undoing a trade also restores the wants it met.

## RPCs (authenticated)

| Call | Does |
|---|---|
| `binder_save(p_id, p_name?, p_for_trade?)` | Creates the binder (new id; name required) or renames / flags it. Same id and values = no change. Returns the binder. A deleted binder: "That binder was deleted". Another account's id: 42501. |
| `binder_delete(p_id, p_idempotency_key)` | Deletes it; its copies go back to Unsorted. One batch (source `binder_delete`), ledgered, **not undoable** (ask first). Already deleted: `{duplicate: true}`. Returns `{batch_id, binder, binder_items}`. |
| `binder_move(p_moves, p_idempotency_key)` | `p_moves`: up to 2500 `{card_id, finish?, condition?, lang?, from, to, qty}`, `from`/`to` a binder id or null (Unsorted). Refused whole if a source holds fewer copies than asked ("Not that many copies there: …"). A batch (source `binder`) with no item change: the same key replays as a duplicate, Undo moves them back. Returns the `collection_apply` result. |
| `wants_apply(p_ops, p_idempotency_key)` | Up to 5000 `{oracle_id | card_id, finish?, qty | delta, max_usd?}`. `qty` sets (0 removes), `delta` adds/takes (never below 0), `max_usd` present sets the ceiling (null clears it). One batch (source `wants`); same key = `{duplicate: true}`. Returns `{batch_id, duplicate, wants}`. Not undone through `collection_undo`: edit the want instead. |
| `library_changes(p_after, p_limit=5000)` | Delta sync, below. |

Every write counts toward the 120 batches a minute of `collection_apply`. Errors are readable messages; nothing is
written when a call is refused.

## Sync: `library_changes`

Its own cursor, separate from the collection's (`library.cursor`), starting at 0. Run it right after
`collection_changes` on every sync.
```
loop:
  r = library_changes(cursor, 5000)
  if r.resync: clear local binders, allocations and wants; cursor = 0; continue
  for b in r.binders: b.deleted ? remove binder (its allocations arrive as qty 0) : upsert binder
  for [binder_id, card_id, finish, condition, lang, qty, seq] in r.binder_items: qty == 0 ? delete : upsert
  for [oracle_id, card_id, finish, qty, max_usd, seq] in r.wants: qty == 0 ? delete : upsert
  cursor = r.next
  if !r.more: break
```
Binders come in full whenever they changed after the cursor (a page may repeat them; upserting is harmless).
Allocations and wants page together by seq. Key allocations `binder_id|card_id|finish|condition|lang` and wants
`oracle_id|card_id|finish` (empty for null).

## Trades

- A trade line may carry `binder_id` (`trade_save` keeps it). On a **give** it's the binder the copies come from; on a
  **get**, the binder they go into. `trade_confirm` passes it to `collection_apply`; a binder deleted since the draft
  drops out instead of failing the confirm.
- **Gives default to trade copies.** Adding a give by search lists copies in for-trade binders first (with the binder
  named) and picks the for-trade binder when the copy is there. The give-side scanner prefers, among the printings you
  own of a scanned card, one a for-trade binder holds (then the condition with the most for-trade copies), and sets the
  line's `binder_id` to that binder.
- **Wants in trades.** A get that matches a want (any printing, that printing, or that printing and finish) or a Missing
  line is highlighted ("Want", "Missing · Burn"); a want's `max_usd` shows "over your max" when the market price is
  higher. `trade_confirm` takes the gets off the wants they meet, in the same batch: the exact printing and finish
  first, then that printing in any finish, then any printing. Its result carries the changed `wants`. Undo puts them
  back.

## Import and export (`contract/collection-import-2026-10-17.md`)

- **ManaBox** `Binder Name` + `Binder Type`: `binder` rows go into that binder (made if you have none by that name,
  matched case-insensitively; a new binder whose name contains "trade" is for trade). `list` rows are ManaBox
  wishlists, not owned copies: they become wants (that printing and finish) and are counted apart in the preview.
  `deck` rows and rows with no binder name are Unsorted copies.
- **Deckbox** and **Moxfield** `Tradelist Count`: that many of the line's copies (at most its count) go into a for-trade
  binder named "Trade binder" (made if needed). **Dragon Shield** `Folder Name` → binder; `Trade Quantity` copies go
  into "Trade binder" instead.
- The preview says how many copies go into binders and how many binders are new.
- **Add:** binders are created first (`binder_save`), then each add op carries its `binder_id` (an item split across
  binders is several ops). **Replace:** item quantities are set as before, then `binder_move` (from Unsorted, chunks of
  2500, a key per chunk kept for retries) puts the file's binder copies in place. Wants from ManaBox lists go in one
  `wants_apply` (adds `delta`). Undo undoes the collection chunks; binders and wants it made stay.
- **Export, ManaBox layout:** `Binder Name, Binder Type` come first (ManaBox's own layout): one row per item ×
  binder, `binder` type, plus a row for the Unsorted copies with no binder name; wants export as `list` rows of a
  binder named "Wants". **Moxfield layout:** `Tradelist Count` = the item's copies in for-trade binders (Moxfield has
  no binder column). Both read back through the importer to the same items, binders and for-trade copies.

## Clients

- **Library home:** a **Binders** row (binders · copies in for-trade binders) and a **Wants** row (wanted · missing).
- **Binders screen:** Unsorted, then each binder (copies, value, "For trade"); New binder. A binder's screen lists its
  cards (tap → card detail) with Rename, For trade on/off and Delete (native alert: its copies go to Unsorted).
- **Wants screen:** two sections. Wanted (qty, which printing, max price; tap to change qty, printing, max price or
  remove) and Missing from decks and cubes (copies short, which lists; Add to wants). Add a want: search, then any
  printing by default.
- **Card detail:** each owned item says where its copies are ("Trade binder 2 · Unsorted 1"); **Move** (in the opened
  item) picks a source when there are several, how many, then the destination (a binder, Unsorted or a new binder).
  **Add to wants** sits next to "Add to a deck or cube".
- **Telemetry** (`contract/telemetry-2026-10-15.md`), no names or ids: `binder_created` (`for_trade`), `binder_updated`
  (`renamed`, `for_trade`), `binder_deleted` (`copies`), `binder_copies_moved` (`copies`, `to`: binder / unsorted,
  `from`: binder / unsorted), `want_added` (`any_printing`, `has_max`, `from`: search / card / missing),
  `want_changed`, `want_removed`. `trade_confirmed` gains `wants_met` (copies) and `from_trade_binder` (give copies
  that came from for-trade binders). `collection_imported` gains `binders`, `binder_copies`, `wants`. Screens:
  `binders`, `binder`, `wants`.
- **Demo:** iOS Debug `-T1LibraryDemo binders|wants` opens those screens; the demo backend applies the same allocation
  rules (shrink order, moves, deletes, wants met by trades) locally, seeded with two binders.

## Account deletion

Deletes binders, allocations, wants and their ledgers with the collection.
