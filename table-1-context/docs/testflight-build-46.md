Table 1 0.1.0 (46) — What to Test

On top of build 45:

INSIGHTS WIDGETS (new)
- Long-press the Home Screen → + → Table 1: Meta, Matchup grid and Archetype matchups.
- Long-press a placed widget → Edit Widget: pick the format, Big or All events, 7/14/30/90 days, and for Archetype matchups the archetype.
- Meta: the top archetypes with their shares; medium and large add the Meta over time graph. Each archetype has its own color, the same in all three widgets.
- Tap a widget: Insights opens on the same format, events and window (the grid, or the archetype's page).

DECKS AND CUBES
- A card added to a deck from your collection or a binder keeps its condition; scanning into a deck keeps the scanner's condition.
- Add to collection (Missing or every card) adds the exact printing, finish, language and condition the deck lists.
- A deck's card page shows Set · Finish · Section only (no Language or Condition).

SCANNER
- With cards scanned, Back asks: Add N, Leave without adding, or Keep scanning.

ALSO
- A new app icon, with Dark and Tinted versions on the Home Screen.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-02 at ee4778b from a clean worktree (version 0.1.0, build 46, Release, automatic signing; archive "Table 1 2-11-2026, 10.48" in ~/Library/Developer/Xcode/Archives/2026-11-02, named "Table 1"). The command-line upload (`-exportArchive`, app-store-connect, upload) failed again with "Failed to Use Accounts", so it waits in Xcode Organizer (opened there with `open <archive>`) for John to upload; then `bugs.py shipped ios 46 --commit ee4778b`. On top of build 45 (1a4faad, distributed by John from Organizer; 44 was never uploaded): f492214 (app icons), 0cb64d0 (scanner Back asks), 1ea215e (Add to collection exact printings), 4181935 + 2b5d92c (list conditions; server live 2026-11-01), dc0b8f5 (Insights widgets; the chart maths moved to Shared). iOS tests 370/370 on dc0b8f5. Not yet tried on a phone.
