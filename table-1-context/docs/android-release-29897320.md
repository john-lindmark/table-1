Table 1 for Android 0.1.0 (versionCode 29897320) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
New: sideboard guides. On any deck, plan each matchup: what comes in, what goes out, and notes. Try more than 15 cards by adding them to Considering while you build the guide, then print it for your next event. The printed guide shows only what's in your sideboard and reminds you it's for between games only.
</en-US>

## What to test

Everything in 29897144, plus:

- Open one of your decks (not Commander or Oathbreaker) and tap Sideboard guide.
- Add a matchup (from the meta list or typed), then set In and Out with − and +, and write notes.
- On the In screen, search a card that isn't in the deck: it goes into Considering and comes in.
- Sideboard lists Sideboard and Considering with how many matchups use each card; tap one to move it.
- Tap the print icon: check the preview, then Print (or Save as PDF).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-04 at 43120e5 (Android changes since 29897144: 25c200a, sideboard guides; contract/sideboard-guide-2026-11-04.md; server live since 2026-11-04) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with warnings; the release build's widget check passed; versionCode 29897320, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. 420 unit tests passed on 25c200a. Not yet uploaded; after uploading, `bugs.py shipped android 29897320 --commit 43120e5`.
