Table 1 for Android 0.1.0 (versionCode 29900203) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Fixed: on Android 15 and later, Save to Photos and Share under the deck image and a ranking's Top 100 image didn't show, and the bottom of other full-screen screens (the scanner's Add button, the chooser's Done) was cut off. New: search any card in Insights and see its share week by week over a year, every archetype that plays it, and its best lists.
</en-US>

## What to test

Everything in 29899855, plus:

- A deck → Deck image: Save to Photos and Share show along the bottom, above the navigation bar.
- A cube → Rankings → a ranking → Top 100 image: the same.
- Tap either picture to zoom: the zoom line at the bottom shows.
- Scanner: the Add button shows whole. Life tracker → Options → Chooser: Done shows at the bottom.
- Skim the other full-screen screens for their bottom row: Share, Export, Add to collection, Add cards in a binder or Wants, a trade's Add, Change printing, Language, Advanced search, Report.
- Status bar icons stay white on those screens; a keyboard (Advanced search, Report) pushes the bottom row up, not over it.
- Insights → Constructed → the search icon: type "bolt", open Lightning Bolt, check the week-by-week chart, Played in and Best lists; open one list.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-06 at ded8be5 (5c609c1 on main is iOS only) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with the usual BUNDLE-METADATA and "signed in JarFile but not in JarInputStream" warnings; the release build's widget check passed; versionCode 29900203, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. Android changes since 29899855: 54695fc (Insights card search and the card page), 00881d0 (full-screen dialogs fill the screen on Android 15+: `T1FullScreenDialog`). 433 unit tests passed on 00881d0. Not yet uploaded; after uploading, `bugs.py shipped android 29900203 --commit ded8be5`.
