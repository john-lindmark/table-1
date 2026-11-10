Table 1 for Android 0.1.0 (versionCode 29905457) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Rank popular cubes like PowerLSV and the MTGO Vintage Cube, and see your friends' rankings on their profiles. Limited filters take several rarities and colors, and a new Limited cards widget shows a set's best cards. Account → Support answers questions with one search. Galaxy Z Fold and Pixel Fold get layouts made for the fold.
</en-US>

## What to test

Everything in 29904554, plus:

- Insights → Limited: Rarity and Color take several picks (Any clears, Done closes); Rank this set at the very bottom.
- Profiles: Rankings section; Account → Sharing → Rankings.
- Rankings and your profile: Popular cubes (PowerLSV, LSVCube, MTGO Vintage Cube, Arena Powered Cube).
- Limited cards widget: add it (2×1 and up), pick set, sort, rarities and colors in its settings.
- Account → Support: search, topics, where to ask. Account → Terms of service.
- Foldables (Galaxy Z Fold, Pixel Fold): half-folded tabletop and book layouts for the life tracker; card page and organizer live round split across the fold; rail on wide windows; folding doesn't restart the app.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-10 at 99277b5 from a clean worktree with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, the usual three Glance error-layout warnings). The full unit suite passed in the same worktree (ScannerPerfTest had failed its name-index budget at load averages of 160–550 from other sessions, then passed in the full run). Android changes since 29904554: 13a98bd, 3f363e2, 3594311 + b47ea49, 6c30930, 88bcae4. Not yet uploaded; after uploading, `bugs.py shipped android 29905457 --commit 99277b5`.
