Table 1 for Android 0.1.0 (versionCode 29894028) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
New Insights widgets: the meta with its graph, the matchup grid, and one archetype's matchups, each set up for your format, events and window. Widgets now stay the widget you placed. Decks and cubes remember each card's condition, and Add to collection adds their exact printings. The scanner asks before Back drops your cards. A new app icon.
</en-US>

## What to test (internal testers)

Everything in 29892945 (never uploaded), which this replaces, plus:
- **Insights widgets.** Long-press the home screen → Widgets → Table 1: Meta, Matchup grid and Archetype matchups. Placing one (or Reconfigure / the widget's settings on Android 12+) opens its settings: format, Big | All events, 7/14/30/90 days, and for Archetype matchups the archetype. Resize them: one row, 2×2, 4×2, tall. Meta shows the graph from 4×2 up. Each archetype keeps its color across the three. A tap opens Insights on the same picks.
- **Widgets keep their type.** Next event and Current match widgets no longer turn into Collection value after the collection syncs. Ones that had turned should come back as what they were after this update.
- Decks and cubes: a card added from your collection or a binder keeps its condition; scanning into a deck keeps the scanner's condition; Add to collection (Missing or every card) adds the exact printing, finish, language and condition the deck lists. A deck's card page shows no Language or Condition.
- Scanner: with cards scanned, Back asks Add N / Leave without adding / Keep scanning.
- The new app icon (and themed icon on Android 13+), and the new notification icon.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-02 at ee4778b (Android changes since 29892945: f492214 icons, 0cb64d0 scanner Back, 1ea215e exact printings, 4181935 + 2b5d92c list conditions, dc0b8f5 Insights widgets and the R8 widget fix) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; versionCode 29894028, versionName 0.1.0, 17.5 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. The new `minifyReleaseWithR8` check passed: the mapping keeps all six GlanceAppWidget classes under their own names. Unit tests passed (390). Supersedes 29892945. Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, paste the en-US block, then `bugs.py shipped android 29894028 --commit ee4778b`.
