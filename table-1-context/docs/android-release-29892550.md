Table 1 for Android 0.1.0 (versionCode 29892550) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Rename decks and cubes from Edit. Decks count a card as owned in any printing, with Match collection to pick yours. The deck finder works in the background and sends a notification when it's done. Screens open from what was last loaded when the signal drops, and cards added offline send when you're back. Legacy and Vintage in Insights. Faster scanning on busy backgrounds.
</en-US>

## What to test (internal testers)

New since bundle 29890522 (31 October):
- Deck or cube → Edit → Name → Change: rename it.
- A deck line you own in another printing no longer reads missing; card detail in a deck → Match collection.
- Find a deck: leave the app mid-search; a notification opens the result.
- Turn on airplane mode: Events, an event and Insights still open with "Couldn't refresh"; add a card, it shows and sends later.
- Insights: Legacy and Vintage; Limited set row hides upcoming sets in Edit.
- Scan cards on a cluttered desk: it shouldn't get slower the more you scan.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-01 at 5a0b2d3 from a clean worktree with `apps/android/tools/bundle-release.sh` (upload key, `jarsigner -verify`: jar verified; versionCode 29892550, versionName 0.1.0, 15.0 MB), copied to `apps/android/app/build/outputs/bundle/release/app-release.aab`. On top of 29890522 (c2771fa). Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, paste the en-US block, then `bugs.py shipped android 29892550 --commit 5a0b2d3`.
