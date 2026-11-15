Table 1 0.1.0 (64) — What to Test

On top of build 63 (everything in 63's notes, plus):

NEW NAVIGATION
- The tabs are Play · Cards · Insights · Account, each with a row of sub-tabs above the tab bar.
- Play: Events · Life tracker. Life tracker opens full screen; closing it lands back on Events.
- Cards: Collection · Trade · Wants. Trade and Wants keep the tab bar. Import is in the Collection's + menu.
- Insights: Constructed · Limited · Rankings. The Constructed | Limited switch at the top is gone.
- Rankings: yours, your friends', popular cubes to rank, cubes and sets you can rank.
- Account: Profile (your own profile, Friends at the top), Records (record, deck photos, every head-to-head), Settings (every setting, Sign out, Delete account, About).
- Each tab comes back to the sub-tab you left it on, after closing the app too.
- A trade or wants notification, or a rankings link, opens the right sub-tab.

LEAGUES
- The Events home lists your leagues, followed ones and running ones; + New offers New event and New league.

COLLECTION
- Shelf tiles and the collection strip show their art with no dark scrim; names and values sit on tags.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes: archived 2026-11-15 at 3011efc from a clean worktree (`.claude/worktrees/ship-64`) with the API key; uploaded from the command line. iOS unit tests (521) passed on the nav work before the commit; the commit's pre-commit tier (web, rules parity, database, feature guide) passed. Contract: `contract/main-nav-2026-11-14.md`.
