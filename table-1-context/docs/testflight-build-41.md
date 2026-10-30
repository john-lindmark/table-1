Table 1 0.1.0 (41) — What to Test

On top of build 40:

RANK A SET IN SPOILER SEASON
- Insights → Limited: a set that's still to come (or came out in the last four weeks) with no 17Lands data yet now leads the set row by its code. Star Trek shows as TRK.
- Pick it: it says when the set is out and how many of its cards Scryfall has so far, with Rank this set under it. Cards revealed later join your ranking for you to place.
- Please check: Insights → Limited → TRK → Rank this set, then sort a screen or two.

THE ARENA CUBE BY NAME
- The Powered Cube reads "Arena Powered Cube · Oct 2025" in the set row, in Edit and on its card and pair screens, instead of PWR-2510.

FIX
- A set's "Out" date no longer reads a day early in time zones west of UTC.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-10-30 at 96710a4 from a clean worktree and uploaded from the command line by Claude (same recipe as build 40: `xcodebuild archive -allowProvisioningUpdates`, then `-exportArchive`, method `app-store-connect`, destination `upload`, team 94889YTX94, automatic signing, `manageAppVersionAndBuildNumber` false); version 0.1.0. On top of build 40 (ff470af) it adds af56001 (Limited picker: spoiler-season sets with Rank this set, Arena cube versions by name, the UTC release-day fix). The server part (`limited_rankable_spoilers`: upcoming sets from 75 days out with 20+ cards) is live since 2026-10-30. Registered with `bugs.py shipped ios 41 --commit 96710a4`.
