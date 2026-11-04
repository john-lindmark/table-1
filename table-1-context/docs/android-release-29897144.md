Table 1 for Android 0.1.0 (versionCode 29897144) — release notes

The first bundle meant for closed testing (testers from outside the internal list, joining by a Google Group).

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Welcome to the Table 1 test. Run Magic events from your phone with Swiss pairings, a round clock and standings; play your matches with the life tracker (2 to 5 players, commander damage); keep your collection, decks and cubes; and see how your decks do in the meta in Insights. Tell us what breaks and what you miss.
</en-US>

## What to test

Everything in 29896900. Nothing new for testers: this bundle adds only the Test Lab check below.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-04 at b3fa634 (Android changes since 29896900: 82e395e, an account signed in on a Firebase Test Lab phone marks itself a robot and Test Lab sends no PostHog, Sentry as environment `test_lab`; contract/test-robots-2026-11-04.md; demo testers, the review account among them, are never marked, server-side since robots_spare_testers) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with warnings; the release build's widget check passed; versionCode 29897144, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. 412 unit tests passed on b3fa634. Not yet uploaded; after uploading, `bugs.py shipped android 29897144 --commit b3fa634`.
