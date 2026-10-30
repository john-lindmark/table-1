Table 1 for Android 0.1.0 (versionCode 29889809) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Sync a cube with Cube Cobra and accept what changed. Insights shows every archetype, puts your decks first, and your decks show how their archetype is doing. Rank any Limited set or Arena cube, and get a heads-up when Insights has something new. Widgets look like the iPhone's and resize. Going offline no longer signs you out, and Library sync is much lighter on your battery and data.
</en-US>

## What to test (internal testers)

New since the bundle of 29 October (versionCode 29888918):

CUBES
- Every cube of yours has Sync with Cube Cobra (under Export): what's in, what's out and which cards moved printing, then Accept changes.

INSIGHTS
- Meta over time draws every named archetype on 1% or more; the matchup grid lists them all, follows the pickers and keeps its labels in view.
- The grid puts your decks' archetypes first; your own decks show their archetype under Stats (win rate, change on last week, good and bad against).
- Limited: Rank this set / Rank this cube, New sets to rank, and Sets you can rank in Rankings. Arena cubes come in versions.
- New in Insights notifications (new format, a set's first data, a new cube run, a set to rank), with a switch at the bottom of Limited.

WIDGETS
- Next event, Collection value and Current match look like the iPhone's and resize from one row to full width.

FIXES
- Offline or a server hiccup no longer shows the sign-in screen; the app keeps your session and retries.
- Library sync stops when the server says there's nothing more (it used to make 50 calls every sync).
- Sign in with Apple is gone from Android (Google, Discord and email remain).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---
Build notes (not for testers): built 2026-10-30 at a4558cf from the clean main checkout with `apps/android/tools/bundle-release.sh` (signed with the upload key, versionCode 29889809, versionName 0.1.0); `apps/android/app/build/outputs/bundle/release/app-release.aab`, 14.9 MB. On top of 29888918 (65f2fd8) it adds 2c97589 (widgets), 21f07f3 (cube sync), 425b6a9 (app links key, web side), ba623cc (lists sync), 5bfb5a1 (session refresh), 11c42ee (no Apple), 121276d (Insights every archetype), aa94e4f (Limited rankings, New in Insights). Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, and paste the en-US block above into release notes. Then `bugs.py shipped android 29889809 --commit a4558cf`.
