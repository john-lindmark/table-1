Table 1 0.1.0 (36) — What to Test

New since build 35:

INSIGHTS: THE FORMAT PAGE
- A format opens on Meta over time and the matchup grid, then the summary and the headline numbers.
- Below them, one row per part: Meta now, Cards rising and falling, New set, Bans and unbans (Points changes for Canadian Highlander), and Big events / Events. Each row sums up its part in a line and opens it on its own screen, with only the pickers that part uses.
- Every format's numbers now refresh on schedule. Before, most of the 6-hourly refreshes skipped two or three formats (a server fix, live 29 Oct), so a format could be up to a day behind.
- Please check: open each format and each part, change the window and Big events / All events on a part, and tell us if any row's summary doesn't match what its screen shows.

DECKS AND CUBES
- Basic lands no longer get the red "short" mark in Grid and Stacks when you own fewer than the deck lists (lists already worked this way).

TAB BAR
- Tabs you're not on have lighter labels that match their icons.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-10-29 at 1b1078f from a clean worktree into Organizer as "Table 1 build 36"; version 0.1.0. Includes 63e71eb (format page parts, tab bar labels Neutral_4, basics never short on tiles) on top of build 35 (9839f0e). The server fix (bug #18, meta builds one at a time, migration `20261029120000_meta_build_queue.sql`) needs no app change.
