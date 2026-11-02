Table 1 0.1.0 (48) — What to Test

On top of build 47 (everything in 47's notes, plus):

COLLECTION SEARCH
- Type a card's name in Search (the magnifier on the Collection home), three letters or more: your decks, cubes and binders that hold it show with the count ("Deck · Modern · 4 Lightning Bolt"), and so do friends' and anyone's you can see. A card named exactly finds only that card.
- Archetypes: a deck name like "boros energy" or a format like "pauper" lists Insights archetypes with their lists in the last 90 days. Tap one: its Insights page opens; Back returns to Search.
- Rankings: a cube or set name, or who ranked it, lists the rankings you can see, yours first. Tap one: the ranking opens.
- Sections run Decks, Cubes, Binders, Archetypes, Rankings, then Cards.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-02 at a89e608 from a clean worktree (version 0.1.0, build 48, Release, automatic signing; archive "Table 1 2-11-2026, 16.23" in ~/Library/Developer/Xcode/Archives/2026-11-02, named "Table 1"). xcodegen in the worktree changed only the spots folder reference's id (the path differs); the archive carries spots/. The command-line upload (`-exportArchive`, app-store-connect, upload) failed again with "Failed to Use Accounts", so it waits in Xcode Organizer (opened there with `open <archive>`) for John to upload; then `bugs.py shipped ios 48 --commit a89e608`. On top of build 47 (a2c12e8): 1ccf927 (Collection Search finds cards inside lists, archetypes and rankings; needs the library_search_more migration, live 2026-11-02). iOS LibrarySearchTests pass and the demo was checked in the Simulator on 1ccf927. Not yet tried on a phone.
