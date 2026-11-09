Table 1 for Android 0.1.0 (versionCode 29904012) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
The scanner reads Japanese, Chinese and Korean cards again, and split cards like Fire // Ice come in whole. Long press a deck image or ranking image to copy, save or share it. Cube ranking finals check their order more carefully. Tap anywhere in a text box to type in it. Scan QR no longer crashes on phones without Google's code scanner.
</en-US>

## What to test

Everything in 29901198, plus:

- Scan a few Japanese, Chinese or Korean cards: they should be named within a second or two, then English cards right after.
- Scan split cards held upright (Boom // Bust, Fire // Ice, Wear // Tear, a Room): the whole card, not one half.
- A deck → Share → Deck image, and a ranking's Top N image: long press for Copy, Save to Photos, Share.
- A cube ranking's final asks a few check screens ("Final · checking #N").
- Tap a text box's label or padding: it focuses.
- Join → Scan QR on a phone without Google's code scanner: no crash.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-09 at 5d05cac (the build-55 commit only touches iOS) from a clean worktree with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with the usual "signed in JarFile but not in JarInputStream" warnings; versionCode 29904012, versionName 0.1.0, 17 MB; copied to the checkout's `apps/android/app/build/outputs/bundle/release/app-release.aab`). Android changes since 29901198: 6d47462 (long press on made pictures), 19c5152 (ranking final checks), 89a6f02 (fix #34, Scan QR checks Play services first), 89e2da7 (text fields focus on a tap anywhere in their box), 68c371d (CJK cards read again; models asked for at install), 4c44ec1 (split cards, lines in the text's own direction). 465 unit tests passed at 5d05cac. Not yet uploaded; after uploading, `bugs.py shipped android 29904012 --commit 5d05cac`.
