Table 1 for Android 0.1.0 (versionCode 29889968) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Rank a set before it comes out: sets in spoiler season, like Star Trek, now lead the Limited set row in Insights, with Rank this set and the cards revealed so far. New cards join your ranking as they're revealed. The Arena cube now goes by its name, Arena Powered Cube · Oct 2025. Reopening the app brings you back to exactly where you were, instead of Events.
</en-US>

## What to test (internal testers)

New since the bundle of 30 October (versionCode 29889809):

INSIGHTS → LIMITED
- A set still to come (or out in the last four weeks) with no 17Lands data yet leads the set row by its code: TRK for Star Trek. Pick it: when it's out, how many of its cards Scryfall has so far, and Rank this set.
- The Arena cube reads "Arena Powered Cube · Oct 2025" in the set row, in Edit and on its card and pair screens, instead of PWR-2510.

REOPENING THE APP
- Opening the app again (after the screen went to sleep, or switching apps) brings you back to exactly where you were: the same tab and screen, and mid-ranking the same four cards in the order you'd dragged them. It used to open on Events every time.
- After 30 minutes or more away it opens on Events, as after a fresh start. A tapped notification or link still opens its own screen.
- Please check: start a cube ranking screen, drag a card, lock the phone for a couple of minutes, unlock.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---
Build notes (not for testers): built 2026-10-30 at 25cf8ac from the main checkout with `apps/android/tools/bundle-release.sh` (signed with the upload key, `jarsigner -verify` clean, versionCode 29889968, versionName 0.1.0); `apps/android/app/build/outputs/bundle/release/app-release.aab`, 14.9 MB. On top of 29889809 (a4558cf) it adds af56001 (Limited picker: spoiler-season sets, Arena cube versions by name) and 25cf8ac (supabase-kt resets the session status to Initializing on every stop and reloads on start; AppRoot drew the start screen for it, dropping the signed-in screens and their navigation, so every return opened on Events; now Initializing with a kept session stays signed in, and only 30+ minutes in the background goes back to Events); ff470af was iOS-only. A bundle built minutes earlier at 96710a4 (29889962) without 25cf8ac was never uploaded. The server part (`limited_rankable_spoilers`) is live since 2026-10-30. Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, and paste the en-US block above into release notes. Then `bugs.py shipped android 29889968 --commit 25cf8ac`.
