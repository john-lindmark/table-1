Table 1 for Android 0.1.0 (versionCode 29912996) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Every screen's top bar now matches the Collection's and a card's: the title on one line on the dark background, the back arrow at the left edge and buttons at the right edge. The small grey line under titles is gone. Card rows with no numbers keep the name centered beside the card.
</en-US>

## What to test

On top of 29912751 (everything in its notes, plus):

- **Title bars**: every screen's bar is 50 tall on the background, back arrow in the left corner, icon buttons flush right; no subtitle under any title (someone else's friends list reads "Friends · <name>").
- **Card rows**: binders and wants without a price keep the card name centered beside the card.

---
Build notes: built 2026-11-15 at e89e622 from a clean worktree (`.claude/worktrees/ship-66`) with `tools/bundle-release.sh`. Contract: `contract/title-bars-2026-11-15.md`.
