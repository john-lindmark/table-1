Table 1 for Android 0.1.0 (versionCode 29892945) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Decks count a card as owned in any printing, with Match collection to pick yours. Rename decks and cubes from Edit. The deck finder works in the background and notifies you when it's done. Screens open from what was last loaded when the signal drops. Legacy and Vintage in Insights. Faster, more accurate scanning, and old cards are told apart by their border. Your deck's archetype shows how similar your list is.
</en-US>

## What to test (internal testers)

Everything in 29892764 (never uploaded), which this replaces, plus:
- Scanner: the whole frame is read again, and a card name is never taken from below the type line (flavor text).
- Scanner: old black- and white-bordered cards with no readable set code go in as Beta / Revised (French + black: Foreign Black Border).
- Your own deck → Stats: the archetype row shows "N% similar"; brews show no archetype rows.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-01 at 1a4faad (Android changes since 29892764: 3b5f951, 5b56d6e, ee46ad4) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; versionCode 29892945, versionName 0.1.0, 17.5 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. Unit tests passed. Supersedes 29892764. Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, paste the en-US block, then `bugs.py shipped android 29892945 --commit 1a4faad`.
