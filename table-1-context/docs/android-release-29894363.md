Table 1 for Android 0.1.0 (versionCode 29894363) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Collection search now looks inside lists: type a card's name to find your decks, cubes and binders that hold it, and friends' you can see. It also finds Insights archetypes, with their recent tournament lists, and the cube and set rankings you can see.
</en-US>

## What to test (internal testers)

Everything in 29894159, plus:
- **A card's name in Search** (the magnifier on the Collection home), three letters or more: decks, cubes and binders holding it show with the count ("Deck · Modern · 4 Lightning Bolt"), yours and others' you can see.
- **Archetypes**: "boros energy" or "pauper" lists Insights archetypes with their lists in the last 90 days; a tap opens the archetype's page.
- **Rankings**: a cube or set name, or who ranked it, lists the rankings you can see; a tap opens the ranking.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-02 at a89e608 (Android changes since 29894159: 1ccf927 Collection Search cards, archetypes and rankings) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; versionCode 29894363, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. The `minifyReleaseWithR8` widget-name check passed. Unit tests passed on 1ccf927. Supersedes 29894159 on Play internal testing once uploaded; then `bugs.py shipped android 29894363 --commit a89e608`.
