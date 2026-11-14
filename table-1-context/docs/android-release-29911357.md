Table 1 for Android 0.1.0 (versionCode 29911357) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Steadier on opening: no more error flashing for a moment when you come back to the app. Error messages are short and plain. Opening an event you aren't playing in shows its page (sign up, standings, follow) instead of an error. Leagues on the Events home, and New league from + New.
</en-US>

## What to test

On top of 29910583 (everything in its notes, plus):

- **No error flash on opening**: leave the app in the background for a while (an hour or more, so the sign-in token runs out), then open it. The Events home, Collection and Account should load without a red error first.
- **Short errors**: any failure reads as one plain line (for example "That event isn't available." or "Couldn't reach Table 1. Check your connection."), never a web address or a block of headers.
- **An event you're not in**: open an event screen for an event you didn't join (an Upcoming events widget row, a followed event's notification, an old link). It shows the event's page (sign-up, standings and matchups, Follow) instead of an error.
- **Leagues on the Events home** (d806acf): your leagues, followed ones and running ones on the Events home; + New offers New event and New league.

---
Build notes: built 2026-11-14 at 9d4c472 from a clean worktree (`.claude/worktrees/ship-android-9d4c472`) with `tools/bundle-release.sh`; the full Android unit suite (599) passed on 9d4c472 in the main checkout; jar verified; R8's widget check passed. Copied to `apps/android/app/build/outputs/bundle/release/table1-29911357.aab`. Contract for the fixes: `contract/android-errors-2026-11-14.md`.

Promoted to closed testing (alpha) 2026-11-14 with `tools/play-upload.mjs --promote 29911357 --track alpha`; `--check` then listed 29911357 on both internal and alpha.
