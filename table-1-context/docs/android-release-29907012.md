Table 1 for Android 0.1.0 (versionCode 29907012) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Life tracker: taps always count, the counters open from the top strip, it follows you into your next round, and it stops recording once your result is in. Add your deck photo right after your last match. Pods show as their own blocks. Menus and sheets no longer hide behind the navigation bar. Keyboards go away when you tap outside.
</en-US>

## What to test

Everything in 29905629, plus:

- Life tracker: a tap that slides still counts; the counters open only from a pull down from the top strip; in an event it moves to your next match once that round is paired; once your match result is in, Record is off.
- Deck photos: after your last match the event screen leads with Add a deck photo; long press a photo to copy, save or share; a push ten minutes later if you haven't added one (once the server part is live).
- Drafts with several pods: each pod is its own block in Round, Earlier, Players and Matchups.
- Menus, panels and sheets at the bottom of the screen sit above the navigation bar (three-button and gesture navigation).
- Live notification for players: round clock, table and opponent only.
- Keyboards go away on a tap outside, a list drag or Back.

Not yet run on a phone (the overlay fix was checked on the T1-Bars emulator).

---
Build notes: built 2026-11-11 at 0b265d3 from a clean worktree (`.claude/worktrees/ship-61`) with `tools/bundle-release.sh`; full test tier passed at c1c1abf (same app code); jar verified (the usual three Glance error-layout warnings). Copied to `apps/android/app/build/outputs/bundle/release/table1-29907012.aab`. Not uploaded to Play.
