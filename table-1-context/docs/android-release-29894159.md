Table 1 for Android 0.1.0 (versionCode 29894159) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
New Insights widgets: the meta with its graph, the matchup grid, and one archetype's matchups, each set up for your format, events and window. Tap a grid square for its record, or an archetype for its line. Widgets now stay the widget you placed. Collection search finds decks, cubes and binders. Decks and cubes remember each card's condition, and Add to collection adds their exact printings. The scanner asks before Back drops your cards. A new app icon.
</en-US>

## What to test (internal testers)

Everything in 29894028 (never uploaded), which this replaces, plus:
- **Tap a grid square** on the Matchup grid widget: it's outlined, its names light up and the top line reads "Deck vs Deck · W-L-D" (tall grids add the win rate and its likely range). Tap again to clear.
- **Tap an archetype** in a Meta widget's legend (4×2 and up, where the graph is): its line is drawn on top and the rest fade. Tap again to let go. Each widget keeps its own pick.
- **Collection search** (the magnifier on the Collection home) finds your decks, cubes and binders too, and others' you can see.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-02 at a2c12e8 (Android changes since 29894028: acfff1c Collection search, 364ba39 widget taps) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; versionCode 29894159, versionName 0.1.0, 17.6 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. The `minifyReleaseWithR8` widget-name check passed. Unit tests passed (393 on 364ba39). Supersedes 29894028. Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, paste the en-US block, then `bugs.py shipped android 29894159 --commit a2c12e8`.
