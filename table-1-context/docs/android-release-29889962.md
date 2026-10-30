Table 1 for Android 0.1.0 (versionCode 29889962) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Rank a set before it comes out: sets in spoiler season, like Star Trek, now lead the Limited set row in Insights, with Rank this set and the cards revealed so far. New cards join your ranking as they're revealed. The Arena cube now goes by its name, Arena Powered Cube · Oct 2025.
</en-US>

## What to test (internal testers)

New since the bundle of 30 October (versionCode 29889809):

INSIGHTS → LIMITED
- A set still to come (or out in the last four weeks) with no 17Lands data yet leads the set row by its code: TRK for Star Trek. Pick it: when it's out, how many of its cards Scryfall has so far, and Rank this set.
- The Arena cube reads "Arena Powered Cube · Oct 2025" in the set row, in Edit and on its card and pair screens, instead of PWR-2510.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---
Build notes (not for testers): built 2026-10-30 at 96710a4 from the main checkout with `apps/android/tools/bundle-release.sh` (signed with the upload key, `jarsigner -verify` clean, versionCode 29889962, versionName 0.1.0); `apps/android/app/build/outputs/bundle/release/app-release.aab`, 14.9 MB. On top of 29889809 (a4558cf) it adds af56001 (Limited picker: spoiler-season sets, Arena cube versions by name); the only other change since, ff470af, was iOS-only. The server part (`limited_rankable_spoilers`) is live since 2026-10-30. Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, and paste the en-US block above into release notes. Then `bugs.py shipped android 29889962 --commit 96710a4`.
