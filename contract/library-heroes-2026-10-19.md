# Hero cards (2026-10-19)

The few cards that stand for a deck, a cube, a binder or the whole collection. Picked by the user; shown wherever those
places are listed and highlighted inside them.

## Rules
- A hero is a card (Oracle id), not a printing: changing a line's printing or finish keeps it a hero. The art shown is the
  printing the place holds (the line or copy with the most copies), else the card's cover.
- Up to 10 per place, kept in the order picked. Unsorted (copies in no binder) has no heroes.
- Where they show:
  - Listed: Collection home → All cards row, Decks / Cubes, Binders. Up to three hero cards fan out at the left of the row.
  - Inside: All cards, a deck/cube (every layout), a binder. A hero's row is a shade lighter with a 2 pt white left edge;
    in the grid and in stacks the card gets a 2 pt white outline. (Not the accent: teal means "the result".)
- Setting: card detail has "Make it a hero" for where it was opened from (a deck or cube, a binder, else the collection);
  tap again to stop. A deck/cube's Edit mode offers it on each line's menu too.
- Deleting a deck, cube or binder drops its heroes; deleting the account drops all of them.
- Private like the rest of the Library; friends' views don't show heroes yet.

## Server (migration `20261020110000_library_heroes.sql`)
- `public.library_heroes (user_id, scope, target_id, oracle_ids uuid[1..10])`, PK (user_id, scope, target_id); the collection's
  target is the nil uuid. RLS on, no policies, no grants: read and written only through the RPCs.
- `library_heroes_set(p_scope, p_target_id, p_oracle_ids) → {scope, target_id, oracle_ids}`: replaces the scope's list
  (order kept, duplicates dropped, empty deletes). Owner checked (42501), unknown card / bad scope / over 10 (22023), signed
  out (28000). Serialized on the library lock.
- `library_heroes() → [{scope, target_id, oracle_ids}]`: every row of the caller whose list or binder is still live.
- Triggers on `card_lists.deleted_at` / `binders.deleted_at` delete the heroes of a tombstoned list or binder.
- Tests: `supabase/tests/96_library_heroes_test.sql`.

## Clients
- Fetch `library_heroes` when the Library starts and on each return to the app (a handful of rows, no cursor); keep a
  per-account cache; toggling shows at once and the RPC's answer replaces it (on failure, refetch).
- Telemetry: `hero_added` / `hero_removed` (`scope`, `count`).
- Status: iOS built and checked in the demo (`-T1LibraryDemo` seeds a hero per deck and cube and two for the collection).
  Web built and checked in `/library?demo` (the demo seeds heroes the same way); Android built and unit-tested, not yet run
  on a device. Migration written and tested locally, not applied to live.
