Table 1 0.1.0 (47) — What to Test

On top of build 46 (everything in 46's notes, plus):

INSIGHTS WIDGETS
- Matchup grid: tap a square. It's outlined, its row and column names light up, and the top line reads "Deck vs Deck · W-L-D"; the large widget adds the win rate and its likely range (or "too few to say"). Tap it again to clear it, or tap another square.
- Meta (medium and large): tap an archetype in the legend. Its line is drawn on top and the others fade. Tap it again to let go.
- Tapping anywhere else on a widget still opens Insights.
- Tinted and clear Home Screens: the widgets stay readable (winning squares filled faintly, losing ones outlined, text always full).
- Two grid widgets with the same format, events and window share what's tapped.

COLLECTION
- Search (the magnifier on the Collection home) finds your decks, cubes and binders too, and others' you can see.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-02 at a2c12e8 from a clean worktree (version 0.1.0, build 47, Release, automatic signing; archive "Table 1 2-11-2026, 12.59" in ~/Library/Developer/Xcode/Archives/2026-11-02, named "Table 1"). The command-line upload (`-exportArchive`, app-store-connect, upload) failed again with "Failed to Use Accounts", so it waits in Xcode Organizer (opened there with `open <archive>`) for John to upload. John uploaded it from Organizer on 2026-11-02; registered with `bugs.py shipped ios 47 --commit a2c12e8`. On top of build 46 (ee4778b, in Organizer, not uploaded; 46's notes still apply to anyone coming from 45): acfff1c (Collection Search finds decks, cubes and binders), 364ba39 (Insights widget taps and the tinted look). iOS tests 372/372 on 364ba39. Not yet tried on a phone. Supersedes 46: upload 47 instead, then `bugs.py shipped ios 47 --commit a2c12e8`.
