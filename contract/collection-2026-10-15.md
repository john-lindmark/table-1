# Collection: client contract (L1, 2026-10-15)

Plan: `table-1-context/docs/plan-collection-2026-10-14.md` §4. Server: migration `20261015120000_collection_core.sql`. Card data for display comes from the catalog pack (`contract/catalog-2026-10-14.md`); these calls carry only ids and quantities.

## Model
One **item** = (card_id, finish, condition, lang) → qty.
- `card_id` is a printing (Scryfall id).
- `finish` is `nonfoil`, `foil` or `etched`, and must be one of that printing's finishes.
- `condition` is `NM`, `LP`, `MP`, `HP` or `DMG` (default `NM`).
- `lang` is a 2–3 letter code (default `en`). It's the language of the physical copy and can differ from the printing's.

## Writing: `collection_apply(p_ops, p_source, p_source_id, p_idempotency_key)`
- **Ops:** `p_ops` is an array of up to 5000 `{card_id, finish?, condition?, lang?, delta | qty}`. `delta` adds or removes copies; `qty` sets the count. For one item, send several deltas or one qty, never both.
- **Source:** `p_source` is `manual`, `scan`, `import`, `trade` or `adjust`.
- **Retries:** always send a fresh `p_idempotency_key` (UUID) per user action, and the same key on retry. A replay returns `{duplicate: true}` and changes nothing; this is permanent, not a 24-hour window.
- **Errors:** if any op is bad, the whole batch is rejected with a readable message, and nothing is written. Bad means: below 0, unknown card, a finish the printing doesn't have, or mixing qty and delta for one item.
- **Result:** `{batch_id, changes, seq, items:[{card_id, finish, condition, lang, qty, seq}], summary}`. Apply `items` to the local store right away so the screen updates. Then run a delta sync. **Don't** move the cursor to the returned `seq`: another device may have written between your cursor and it, and the sync picks those up (your own rows come back too, which is harmless).
- **Rate:** 120 batches per minute per user. Batch the work instead (scan sessions: one call per ~50 cards or on Done).

`collection_undo(p_batch_id, p_idempotency_key?)` reverses one batch. It's how "Undo" works after an add, a scan session or an import. A batch can be undone once.

## Reading: delta sync, `collection_changes(p_after, p_limit=5000)`
The client keeps `cursor` (the highest `seq` it has applied), starting at 0.
```
loop:
  r = collection_changes(cursor, 5000)
  if r.resync: clear local items; cursor = 0; continue
  for [card_id, finish, condition, lang, qty, seq] in r.items:
      qty == 0 ? delete local item : upsert local item
  cursor = r.next
  if !r.more: break
```
- **When:** sync on app open, on returning to the Library, and after any write that came back `duplicate` (another device may have written).
- **First sync** of a large collection is a few pages. After that each sync is one small call.
- `summary` (total cards, printings, distinct cards, USD/EUR value) comes with every response. `library_summary_get()` returns it alone.
- **Never** compute the totals client-side for display: the server values use current prices, which are recomputed nightly.

## Local store
Key items by `card_id|finish|condition|lang`. Join to the catalog pack for name, set and type, then filter, sort and search locally. Group by Oracle card for the list ("Lightning Bolt · 3 printings · 7 copies").

## History
`collection_card_history(p_card_id)` returns the ledger for one printing (add/remove, source, undone).
