Table 1 0.1.0 (51) — What to Test

On top of build 50 (everything in 50's notes, plus):

LIFE TRACKER CHOOSER
- Start a table from Setup (or Options → Chooser) and put two or more fingers down.
- Once one is picked, the life tracker comes back on its own about 1.5 seconds later. Done still leaves sooner.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-04 at 1dc20ab from a clean worktree (version 0.1.0, build 51, Release, automatic signing; archive "Table 1 4-11-2026, 10.42" in ~/Library/Developer/Xcode/Archives/2026-11-04, named "Table 1"). 385 iOS unit tests passed in that worktree first. The command-line upload (`-exportArchive`, app-store-connect, upload) failed again with "Failed to Use Accounts", so it waits in Xcode Organizer (opened with `open <archive>`) for John to upload; then `bugs.py shipped ios 51 --commit 1dc20ab`. On top of build 50 (3d71656): 38269b0 (the chooser returns to the tracker; client-only). Not yet tried on a phone.
