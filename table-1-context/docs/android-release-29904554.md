Table 1 for Android 0.1.0 (versionCode 29904554) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Insights filters are dropdowns, and the matchup grid shows each deck's overall win rate. Limited opens on the best cards, with their art and mana symbols, a search across sets, and Rank this set right under them. Join an event by typing its code, or paste a message or link with the code in it.
</en-US>

## What to test

Everything in 29904314, plus:

- Insights → Constructed: Format · Events · Window dropdowns; "Shown formats…" opens the hide switches. The matchup grid's Overall column: tap it for the record.
- Insights → Limited: Top cards with art, mana symbols and "+4.1" vs the average; Sort · Rarity · Color dropdowns; Show all; search (a card in another set opens there); Rank this set under the cards; the brief at the bottom. A card's page opens on its picture.
- Events tab: the EVENT CODE box with Join, and Paste while something's copied (a code, a join link, the QR's link or a message with the code).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-09 at dcb2c38 from a clean worktree with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; versionCode 29904554, versionName 0.1.0). 482 unit tests passed in the same worktree. Android changes since 29904314: e21e033 (Insights dropdowns, Overall, Limited cards first with art, mana symbols as VectorDrawables, search; event code field with Paste; pct1/delta round the exact value like iOS and web). Not yet uploaded; after uploading, `bugs.py shipped android 29904554 --commit dcb2c38`.
