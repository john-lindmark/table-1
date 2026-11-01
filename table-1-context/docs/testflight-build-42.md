Table 1 0.1.0 (42) — What to Test

On top of build 41:

RENAME DECKS AND CUBES
- Open a deck or cube → Edit → Name → Change. Type a new name and Save. It shows at once and re-sorts the Decks / Cubes lists.

DECKS SHOW WHAT YOU OWN BY CARD
- A deck or cube line no longer reads missing when you own the card in another printing, finish or language.
- Card detail in a deck has Match collection: pick which of your printings the deck should list, then Use these printings (with Undo).
- Following a cube you opened from a share link lets you rank it.

DECK FINDER KEEPS GOING WHEN YOU LOCK THE PHONE
- Find a deck shows its work as it searches (Table 1's own results first, then the web) and sends a push when the list is ready. Lock the phone mid-search and tap the push.

OFFLINE AND WEAK SIGNAL
- Events home, an event, standings and Insights open from what was last loaded, with "Couldn't refresh · last updated …" instead of an error.
- Cards added with no signal stay shown and send when you're back online ("N changes waiting to send" on the Collection home). Deck edits queue the same way.

INSIGHTS
- Legacy and Vintage join the constructed formats.
- Limited: the set row draws whole (no upcoming sets popping in), and Edit can hide upcoming sets too.
- A deck's archetype row opens Insights over the deck; Back returns to the deck.

SCANNER
- Scanning no longer slows down on busy backgrounds or after many cards.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-01 at 5a0b2d3 from a clean worktree (version 0.1.0, build 42, Release, automatic signing). The command-line upload (`-exportArchive`, method `app-store-connect`, destination `upload`, team 94889YTX94) failed twice with "Failed to Use Accounts: App Store Connect access for 94889YTX94 is required", so the archive waits in Xcode Organizer as "Table 1 build 42" (~/Library/Developer/Xcode/Archives/2026-11-01). Upload it from Organizer, or sign in again in Xcode → Settings → Accounts and rerun the export. Then `bugs.py shipped ios 42 --commit 5a0b2d3`. On top of build 41 (96710a4): 63e123d, 44f3948, bdd296b, e0ebb82, 13fcf9d, 79bb758, 732adff, cf5f7b2, 5964acd. Server parts all live (deck finder jobs since d1a392c).
