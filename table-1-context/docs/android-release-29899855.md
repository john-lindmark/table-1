Table 1 for Android 0.1.0 (versionCode 29899855) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
New: Buy. Every deck and cube has a Buy screen: skip the cards you own, choose one TCGplayer cart or exact printings, add tokens, and see the total before you go. Wants and Missing use it too, and any card's page can open it on TCGplayer. Also new: the Card icon widget puts the Table 1 mark over any card you pick.
</en-US>

## What to test

Everything in 29897320, plus:

- Open a deck or cube → Buy. Check the total, then turn Skip cards I own and Any printing I own counts on and off.
- On a deck: Tokens, and Boards (add Considering).
- Buy on TCGplayer: Exact printings off → one Mass Entry cart; on → a menu of product pages. Links go through Table 1's partner link and land on the same TCGplayer page.
- Wants and Missing: Buy on TCGplayer opens the Buy screen.
- A card's page: + → Add to → TCGplayer.
- Card icon: on a card's page, details → Use for the icon widget, then add the Card icon widget (one cell, resizable).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-06 at ed282ac from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with the usual BUNDLE-METADATA warnings; the release build's widget check passed; versionCode 29899855, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. Android changes since 29897320: 6fc251c (fix #33, a stray Glance list trampoline start crashed the app), 4c76497 (card icon widget), 29068bd (affiliate tags: p_from), 2afe6f7 (Buy screen). The affiliate link itself is server-side and live (checked 2026-11-06). 429 unit tests passed on 2afe6f7. Not yet uploaded; after uploading, `bugs.py shipped android 29899855 --commit ed282ac`.
