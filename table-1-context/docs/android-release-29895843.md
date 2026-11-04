Table 1 for Android 0.1.0 (versionCode 29895843) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
The life tracker now does Commander: pick 2 to 5 players and 20, 30 or 40 life, and everyone sits around the phone facing their own edge. At 30+ life, track commander damage from each opponent; it comes off life and 21 from one opponent loses. Decks, cubes and binders you follow now show their art on the Collection home. Plus a fix for card data failing to load after the app was in the background.
</en-US>

## What to test (internal testers)

Everything in 29894363, plus:
- **Life tracker Setup**: open the tracker on its own (not from a match): Players 2 3 4 5 and Starting life 20 30 40, then Start, which opens the chooser. Last picks are remembered; Continue resumes a table with history.
- **3–5 players**: seats sit around the phone, each turned to face its edge (3 = left, right and bottom; 4 = two a side; 5 = two a side plus the bottom), named P1–P5. Check that taps land on the seat you touch.
- **Commander damage** at 30+ life: a seat's counter picker lists "Commander P3" from each opponent first; it comes off life, 21 from one opponent loses, Undo and Reset take both back. With 3+ players, Record fills in once one player is left.
- **New match** in Options and History goes back to Setup. Trackers for an event match are unchanged.
- **Followed decks, cubes and binders** show a picture on the Collection home shelves.
- **Coming back to the app** after a while away: card data loads without a "JWT expired" error.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-03 at d8753d2 (Android changes since 29894363: 84268ea fix #30, the catalog check retrying once after an expired-token 401; 6c06fae life tracker Setup, 3–5 players, commander damage; 0e47b2b follow art, needs the follow_art migration, live 2026-11-03) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; versionCode 29895843, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. 408 unit tests passed on d8753d2. Uploaded to Play internal testing by John 2026-11-03, superseding 29894363; registered with `bugs.py shipped android 29895843 --commit d8753d2` (#30 shipped).
