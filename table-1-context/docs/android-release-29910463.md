Table 1 for Android 0.1.0 (versionCode 29910463) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Decklists from deck photos: every deck photo is read into a decklist using the event's set or cube. Dice on basic land piles count as that land's number; sideways cards are left out. Correct the list (counts, change a card, add or remove), then Add to my decks. A notification says when your list is ready. Also: the organizer can turn any deck photo upright.
</en-US>

## What to test

On top of 29910395 (everything in its notes, plus):

- **Decklists from deck photos**: open an event's Deck photos (or Account → Deck photos); each photo has a Decklist row ("Decklist · 40 cards · 2 to check"). Tap it: the photo, the count against the deck size, Main deck / Sideboard / Left out. If it's your deck, you took the photo or you run the event: step counts, tap a line for Change card / Looks right / Move / Remove, Add a card; it saves as you go. Add to my decks makes a private deck; Open deck shows it.
- **A new photo**: add a deck photo and wait about half a minute; the row goes from "Reading the decklist…" to the count, and a notification says the list is ready (tap it: Deck photos, then the list).
- **The organizer turns deck photos**: as organizer, tap a player's photo → Rotate right / Rotate left.

---
Build notes: built 2026-11-13 at a60e230 from a clean worktree (`.claude/worktrees/ship-62`) with `tools/bundle-release.sh`; the Android unit suite passed on the branch before the merge (528 of 529, the one a load-sensitive import budget that passed alone) and the deck photo, push route and support tests after it. Uploaded to Play internal testing from the command line with `tools/play-upload.mjs` (Play accepted the signed bundle).

Promoted to closed testing (alpha) 2026-11-13 with `tools/play-upload.mjs --promote 29910463 --track alpha`.
