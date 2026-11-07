Table 1 0.1.0 (54) — What to Test

On top of build 53 (everything in 53's notes, plus):

SCAN FROM THE COLLECTION
- Collection tab: the top bar has a camera after + and the magnifier. Tap it and scan a few cards in a row.
- Every scanned row now shows its price on its own line (one copy in its finish and condition; "≈" when converted from Cardmarket, "No price" when there's none), and the bar shows the total ("4 scanned · $12.40"). Check the other scanners too (Add cards, a deck, a binder, Wants, a trade).
- Tap Add: the Add to list opens over the scanner. Close it: you're back scanning with every card kept. Pick Collection, a deck (then its section), a cube, a binder, Want or a trade: everything goes in at once, the scanner closes, and the Collection tab says "Added N scanned cards to …" with Undo (collection, binder, deck, cube). Tap Undo.

PEOPLE
- Tap a player anywhere (standings, Players, the opponent on your match, Account → Head-to-head, Add a friend results): their profile opens on the same tab, with Add friend.

DECK PHOTOS ON YOUR ACCOUNT
- Account → Deck photos: every photo of a deck you played, by event, newest first. A photo's menu: Open event, Everyone's photos from this event, Rotate, note, Remove.

INSIGHTS CARD SEARCH
- Insights → Constructed → the search icon: type "bolt", open Lightning Bolt: its share week by week over a year, every archetype that plays it, and its best lists (tap one).

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-07 at 5343299 from a clean worktree (version 0.1.0, build 54, Release, automatic signing; archive "Table 1 7-11-2026, 10.20"). 410 unit tests passed at 5343299. On top of build 53 (ed282ac): 54695fc (Insights card search; server and web live), 5c609c1 (disabled buttons a flat fill), 8e65ced (scan from the Collection, prices on every scanner), 77852b1 (tapping a person opens their profile; web live), 4cf20f0 (deck photos on your account). **Deck photos on your account needs migration `20261106170000_my_deck_photos.sql` on live (not applied yet, needs John's OK): until then the Account row shows no summary and the screen an error.** Upload from Xcode Organizer, then `bugs.py shipped ios 54 --commit 5343299`. Not yet tried on a phone.
