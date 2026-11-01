Table 1 for Android 0.1.0 (versionCode 29892764) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Decks count a card as owned in any printing, with Match collection to pick yours. Rename decks and cubes from Edit. The deck finder works in the background and notifies you when it's done. Screens open from what was last loaded when the signal drops. Legacy and Vintage in Insights. Faster scanning. Lists keep their place after card detail, card images no longer stay blank, and the scanner's button sits above the navigation bar.
</en-US>

## What to test (internal testers)

Everything in 29892550 (never uploaded), which this replaces:
- A deck line you own in another printing no longer reads missing (Darklight Fleshraker: 4 Weatherlight Buried Alive, covered by the SLD and MH3 copies); card detail in a deck → Match collection.
- Deck or cube → Edit → Name → Change: rename it.
- Find a deck: leave the app mid-search; a notification opens the result.
- Airplane mode: Events, an event and Insights still open with "Couldn't refresh"; add a card, it shows and sends later.
- Insights: Legacy and Vintage; Limited set row hides upcoming sets in Edit.
- Scan cards on a cluttered desk: it shouldn't get slower the more you scan.

New since 29892550:
- Open a card from a long deck, All cards or a binder, go back: the list is where you left it.
- Change a card's condition while images load: no card stays blank.
- Scanner, Add cards, Share, Export: the bottom button sits above the navigation bar.
- Sign-in screen: the feature carousel.
- Sentry and PostHog report from this build (first Android build with either).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-01 at ad9653e (no Android change since d69ea44) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; versionCode 29892764, versionName 0.1.0, 17.5 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. Supersedes 29892550. Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, paste the en-US block, then `bugs.py shipped android 29892764 --commit ad9653e`.
