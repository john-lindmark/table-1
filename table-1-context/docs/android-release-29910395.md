Table 1 for Android 0.1.0 (versionCode 29910395) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Cube rankings check the final more closely, so one color no longer clumps together in the top 50 or 100. Since the last internal build: sideboard guides, Buy for decks and cubes, scan a pile from Collection with prices, Insights card search, drafts with several pods, follow events, friends on profiles, deck photos on your account, Support, the Limited cards and card icon widgets, and life tracker fixes.
</en-US>

## What to test

Internal testing was on 29896900 (2026-11-04); closed testing has 29907012. This build is everything in 29907012, plus:

- **Cube rankings, final checks**: finish a ranking's final (or open one already finished); it asks a few more check screens ("Final · checking #N") and the top 50 / 100 should no longer run several cards of one color in a row.
- **Rules without an update**: nothing to see yet; later ranking rule fixes can reach this build without a new upload.

For internal testers coming from 29896900, the notes of 29897320 through 29907012 list the rest (sideboard guides, Buy, scanning from Collection, Insights card search, pods, re-pair a round, friends on profiles, following events, deck photos, Support, foldables, widgets, life tracker fixes, bottom menus above the navigation bar).

---
Build notes: built 2026-11-13 at 9046188 from a clean worktree (`.claude/worktrees/ship-android-9046188`) with `tools/bundle-release.sh`; 522 Android unit tests passed there; jar verified. Copied to `apps/android/app/build/outputs/bundle/release/table1-29910395.aab`. Uploaded to internal testing from the command line with `tools/play-upload.mjs` (the first API upload).
