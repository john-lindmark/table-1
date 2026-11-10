Table 1 for Android 0.1.0 (versionCode 29905629) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
The Limited cards widget now has Set, Rarity and Color buttons: tap one to switch to the next choice. Tap the rest of the widget to open Insights → Limited on what it shows. Two-color cards keep their win rate on wide widgets.
</en-US>

## What to test

Everything in 29905457, plus:

- Limited cards widget: tap Set, Rarity and Color to step through the choices; the cards change at once, and the widget's settings screen shows the new picks.
- Tap the widget's body: Insights → Limited opens on its set, sort, rarity and color.
- On a wide widget, two-color cards show their win rate (they had lost it).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-10 at 4974e05 from a clean worktree with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified). Copied to `apps/android/app/build/outputs/bundle/release/table1-29905629.aab` in the main checkout. The only Android change since 29905457 is ae87159 (unit tests passed there, ScannerPerfTest alone after its usual out-of-memory in the full run); 6cba130 refreshed the bundled Support files. Not yet uploaded; after uploading, `bugs.py shipped android 29905629 --commit 4974e05`.
