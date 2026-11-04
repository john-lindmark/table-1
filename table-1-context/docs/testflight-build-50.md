Table 1 0.1.0 (50) — What to Test

On top of build 49 (everything in 49's notes, plus):

LIFE TRACKER COUNTERS
- Swipe toward yourself on your half (or seat) to open the counter picker, as before.
- Swiping up or away no longer closes it: at 30 or 40 life the list is long (commander damage from each opponent, then poison and the rest), so swipe it to scroll. Only Done closes it.
- Check this on a side seat at a 3–5 player table too.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-03 at 3d71656 from a clean worktree (version 0.1.0, build 50, Release, automatic signing; archive "Table 1 3-11-2026, 22.31" in ~/Library/Developer/Xcode/Archives/2026-11-03, named "Table 1"). 384 iOS unit tests passed in that worktree first. The command-line upload (`-exportArchive`, app-store-connect, upload) failed again with "Failed to Use Accounts", so John uploaded it from Xcode Organizer 2026-11-04; registered with `bugs.py shipped ios 50 --commit 3d71656`. On top of build 49 (d8753d2): 052d4e4 (no swipe closes the counter picker; client-only). Not yet tried on a phone.
