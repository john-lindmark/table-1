Table 1 0.1.0 (49) — What to Test

On top of build 48 (everything in 48's notes, plus):

LIFE TRACKER FOR COMMANDER, PAUPER COMMANDER AND OATHBREAKER
- Open the life tracker on its own (not from a match): it starts on Setup. Pick Players (2, 3, 4 or 5) and Starting life (20, 30 or 40), then Start. Your last picks are remembered; Continue picks up a table that already has history.
- Start clears the table and opens the chooser (fingers on the screen, one is picked).
- Three to five players sit around the phone, each facing their own edge: 3 = left, right and bottom; 4 = two a side; 5 = two a side plus the bottom. Players are named P1–P5 (two players stay You / Opponent).
- At 30 or 40 life, a player's counter picker lists commander damage from each opponent first ("Commander P3"). Commander damage also comes off life, and 21 from one opponent loses. Undo and Reset take both back.
- With 3+ players, Record is filled in once one player is left; the score reads like "P1 1 · P2 0 · P3 2".
- Options and History have New match (back to Setup).
- Trackers for a match in an event work as before (two players, no commander damage).

COLLECTION HOME
- Decks, cubes and binders you follow now show a picture on their shelf tiles, like your own: the owner's hero card if they picked one, else the first card in it.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-03 at d8753d2 from a clean worktree (version 0.1.0, build 49, Release, automatic signing; archive "Table 1 3-11-2026, 17.08" in ~/Library/Developer/Xcode/Archives/2026-11-03, named "Table 1"). 383 iOS unit tests passed in that worktree first. The command-line upload (`-exportArchive`, app-store-connect, upload) failed again with "Failed to Use Accounts", so it waits in Xcode Organizer (opened there with `open <archive>`) for John to upload; then `bugs.py shipped ios 49 --commit d8753d2`. On top of build 48 (a89e608): 6c06fae (life tracker Setup, 3–5 players, commander damage; client-only) and 0e47b2b (follow art; needs the follow_art migration, live 2026-11-03; older builds ignore the field). Not yet tried on a phone.
