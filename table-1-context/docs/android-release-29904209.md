Table 1 for Android 0.1.0 (versionCode 29904209) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Drafts can now have several pods: pick how many, and whether later rounds pair inside each pod or across them. Randomize the seats, or move and swap players between pods by hand. Standings show each player's pod with a filter. Organizers can also correct earlier results from a new Earlier tab.
</en-US>

## What to test

Everything in 29904012, plus:

- Create → Limited → Draft: Pods (Auto or Choose) and Pairings (Inside pods / Across pods); the line under Pods says how players split.
- Setup → Seating: Randomize; tap a seat to move it to another pod or a new one, or Swap with… then tap the other player.
- Add a player after seating: listed as Not seated, seated in the smallest pod at round 1.
- Round 1: the note under each odd pod says who its last seat plays. Standings show P1/P2 and a pod filter.
- Live → Earlier: correct a past result. (Re-pair round needs a server update that isn't live yet.)

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-09 at 8052216 (the build-56 commit only touches iOS) from a clean worktree with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with the usual "signed in JarFile but not in JarInputStream" warnings; versionCode 29904209, versionName 0.1.0, 17.9 MB; copied to the checkout's `apps/android/app/build/outputs/bundle/release/app-release.aab`). Android changes since 29904012: a3f3eb0 (re-pair a round; server side not live yet), 7ffba59 (drafts with several pods; server live 2026-11-09). 472 unit tests passed at 1a8303b (the same app code). Not yet uploaded; after uploading, `bugs.py shipped android 29904209 --commit 8052216`.
