Table 1 0.1.0 (52) — What to Test

On top of build 51 (everything in 51's notes, plus):

SIDEBOARD GUIDES
- Open one of your decks (not Commander or Oathbreaker) and tap Sideboard guide under Stats.
- Tap + to add a matchup: pick an archetype from the format's meta, or type a name.
- In a matchup, tap In and Out to set what comes in (sideboard or Considering) and what goes out (main deck) with − and +. Add notes below.
- On the In screen, search for a card that isn't in the deck: it goes into Considering and comes in at once.
- Sideboard (on the guide screen) lists Sideboard and Considering with how many matchups use each card; tap one to move it.
- Tap the print icon: the preview should show only sideboard cards coming in, with a note for any left out. Try Print (or save as PDF from the print sheet).
- Check the guide shows on another device signed in to the same account, and that a deck shared with friends doesn't show your guide.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-04 at 43120e5 from a clean worktree (version 0.1.0, build 52, Release, automatic signing; archive "Table 1 4-11-2026, 17.40" in ~/Library/Developer/Xcode/Archives/2026-11-04). On top of build 51 (1dc20ab): 25c200a (sideboard guides; server and web live since 2026-11-04). 393 iOS unit tests passed on 25c200a (the app code is the same at 43120e5; only the build number changed). The command-line upload wasn't tried to the end (blocked by this session's permission check), so it waits in Xcode Organizer (opened with `open <archive>`) for John to upload; then `bugs.py shipped ios 52 --commit 43120e5`. Not yet tried on a phone.
