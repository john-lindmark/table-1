Table 1 for Android 0.1.0 (versionCode 29912751) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Every list of cards now looks the same: the card on the left, its name, a line of numbers and a count on the right. Insights rows show mana costs, Constructed's rising and falling cards and an archetype's cards show each card, and Limited's color pairs show their mana symbols. Decks and binders drop the extra labels. A confirmed trade's prices show the first time you open it, and a card's Insights page opens quickly again.
</en-US>

## What to test

On top of 29912614 (everything in its notes, plus):

- **Card rows**: decks, cubes, binders, wants, Limited and Constructed Insights all draw cards with the same row (whole card thumbnail, name, data lines, value on the right); Insights rows add the mana cost.
- **Decks and cubes**: no Owned / Missing or finish on rows; a short count is red, a foil shines. Binder lists: card, name, count.
- **Limited**: color pairs show mana symbols; the New sets to rank list at the bottom is gone.
- **Prices**: open a confirmed trade from Trades: prices show at once.
- **Insights card page**: a rarely played card's page opens without an error.

---
Build notes: built 2026-11-15 at cc7d5b9 from a clean worktree (`.claude/worktrees/ship-65`) with `tools/bundle-release.sh`; 607 Android unit tests passed (the two CSV-import perf budgets failed under load next to the iOS suite and passed alone); jar verified. Contract: `contract/card-rows-2026-11-15.md`.
