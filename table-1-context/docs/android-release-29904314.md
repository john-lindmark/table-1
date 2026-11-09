Table 1 for Android 0.1.0 (versionCode 29904314) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
See a player's friends on their profile, and choose who sees yours (Sharing → Friends). Event links now open in the app for events you're not in, with standings and matchups. Follow an event you're not playing to keep it on your Events tab, with a notification each round.
</en-US>

## What to test

Everything in 29904209, plus:

- Account → Sharing → Friends: "Friends" (who sees your friends list, starts Private) and "You in friends' lists" (starts Friends). Opening either asks first.
- A friend's profile with their list shared: a Friends row ("3 mutual"), their friends with mutual first; tap one for their profile, long-press for Block or Report.
- An event's link (table-1.site/s/…) for an event you're not in: after round 1 it opens in the app with Standings and Matchups (no browser).
- Follow on that page: the event shows on Events under Following, with a notification each round and at the finish (once the server part is on).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-09 at 11399c8 (the build-57 commit only touches iOS) from a clean worktree with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with the usual "signed in JarFile but not in JarInputStream" warnings; versionCode 29904314, versionName 0.1.0, 17.9 MB; copied to the checkout's `apps/android/app/build/outputs/bundle/release/app-release.aab`). 478 unit tests passed in the same worktree. Android changes since 29904209: dea44b9 (friends on profiles; server live 2026-11-09), 121bf8e (event links open in the app; follow events you're not in; the follow server part not yet live, so Follow and Following stay hidden until it is). Not yet uploaded; after uploading, `bugs.py shipped android 29904314 --commit 11399c8`.
