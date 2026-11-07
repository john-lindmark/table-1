Table 1 for Android 0.1.0 (versionCode 29901198) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
New: scan a pile of cards from the camera on the Collection tab, then add them all to your collection, a deck, cube, binder, wants or a trade, with Undo. Every scanner shows each card's price and the total. Tap a player anywhere to open their profile. Account → Deck photos shows every photo of your decks. The scanner zooms in so cards fill the guide in focus.
</en-US>

## What to test

Everything in 29900203, plus:

- Collection tab → the camera at the top: scan a few cards. Each row has a price line; the bar shows the total.
- Add: Add to opens over the scanner. Close it and keep scanning; then pick Collection, a deck (and section), a cube, a binder, Want or a trade. The Collection tab says "Added N scanned cards to …" with Undo.
- The other scanners (Add cards, a deck, a binder, Wants, a trade) show prices too.
- The scanner starts zoomed in (1.6×): hold a card a little further away so it fills the guide and stays sharp.
- Tap a player in standings, Players, your opponent or Head-to-head: their profile opens, with Add friend.
- Account → Deck photos: every photo of a deck you played, by event, newest first.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-07 at 5343299 (the build-54 commit only touches iOS) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with the usual "signed in JarFile but not in JarInputStream" warnings; versionCode 29901198, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. Android changes since 29900203: 5d2a98e (ML Kit off the main thread, Latin model at install, back to Latin after CJK, scanner timing), 8e65ced (scan from the Collection, prices on every scanner), 64d3c6f (tapping a person opens their profile), 4cf20f0 (deck photos on your account; its migration applied to live 2026-11-07), faf31ce (1.6× scanner zoom, exposure metered on the guide). 452 unit tests passed at 5343299. Not yet uploaded; after uploading, `bugs.py shipped android 29901198 --commit 5343299`.
