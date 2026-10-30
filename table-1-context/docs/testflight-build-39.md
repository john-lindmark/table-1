Table 1 0.1.0 (39) — What to Test

New since build 38:

CUBES: SYNC WITH CUBE COBRA
- Every cube of yours has Sync with Cube Cobra (under Export). It reads the cube on Cube Cobra again and shows what's in, what's out and which cards moved to another printing, then Accept changes saves them as one new version.
- A cube you imported from Cube Cobra remembers its link; an older cube asks for the link once.
- Please check: change a few cards in a cube on Cube Cobra, sync, and see that the in / out / printing lists match.

INSIGHTS: EVERY ARCHETYPE, YOURS FIRST
- Meta over time draws every named archetype on 1% or more of the meta, not just the top 8.
- The matchup grid lists every archetype with enough matches, follows the Big events / All events and window pickers, and keeps its labels in view as you scroll.
- The grid puts the archetypes of your own decks first, then archetypes you own most of the cards for.
- Your own decks show their archetype under Stats: win rate over 30 days, the change on last week, and what it's good and bad against.
- Please check: open Modern's grid, change the window, and open one of your Modern decks.

RANK LIMITED SETS
- Every Limited set in Insights has Rank this set (Arena cubes: Rank this cube), and New sets to rank lists sets that are out or about to be out.
- Rankings has Sets you can rank. A set ranking works like a cube ranking, and your friends can see it.
- Arena's cubes come in versions, one per time Arena runs them.

NEW IN INSIGHTS
- A push when Insights gets something new: a new format, a set's first draft data, a new Arena cube run, or a new set to rank. A tap opens it.
- Turn it off with the New in Insights switch at the bottom of Limited.

ALREADY LIVE FOR EVERY BUILD
- The Table 1 Discord bot posts Insights pictures: /meta matchups, deck and winrates.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-10-30 at a4558cf from a clean worktree and uploaded from the command line by Claude (`xcodebuild archive -allowProvisioningUpdates`, then `-exportArchive` with ExportOptions method `app-store-connect`, destination `upload`, team 94889YTX94, automatic signing, `manageAppVersionAndBuildNumber` false); version 0.1.0. On top of build 38 (65f2fd8) it adds 21f07f3 (Sync with Cube Cobra), 121276d (Insights every archetype, yours first, deck screens), 8fd7e8c + 810277b (Limited set rankings, Arena cube versions, New in Insights). The server parts (cube_sync, insights_all_archetypes, insights_mine, list_insight, limited_cube_versions, limited_rankings, catalog_new_sets, insights_news) are live. Registered with `bugs.py shipped ios 39 --commit a4558cf`.
