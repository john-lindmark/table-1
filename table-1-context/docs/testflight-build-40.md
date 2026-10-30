Table 1 0.1.0 (40) — What to Test

Fixes on top of build 39:

YOUR DECKS IN THE META
- Your own decks now show their archetype under Stats: win rate over 30 days, the change on last week, and what it's good and bad against. Build 39 had the rows but never loaded them.
- A deck that doesn't match an archetype Insights knows says so ("In the meta").
- Please check: open one of your Modern decks.

INSIGHTS OPENS WITH ITS DATA
- Opening Insights and leaving it straight away no longer leaves the format empty when you come back ("No Modern results yet" until you tapped Limited and back).
- Please check: open Insights, switch to another tab within a second or two, come back.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-10-30 at ff470af from a clean worktree and uploaded from the command line by Claude (same recipe as build 39: `xcodebuild archive -allowProvisioningUpdates`, then `-exportArchive`, method `app-store-connect`, destination `upload`, team 94889YTX94, automatic signing, `manageAppVersionAndBuildNumber` false); version 0.1.0. On top of build 39 (a4558cf) it adds ff470af: DeckMetaRows hung `.task` on an empty Group (no list_insight call ever reached the server from build 39), and InsightsStore's load was cancelled with the tab's task after the index, then skipped for ten minutes. No server change. Registered with `bugs.py shipped ios 40 --commit ff470af`. Sentry bug #24 (a ~4 s launch hang on build 39, unsymbolicated) is not addressed beyond moving pack decoding off the main thread.
