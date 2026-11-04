Table 1 for Android 0.1.0 (versionCode 29896900) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
In the life tracker, the chooser now brings you back to the tracker by itself a moment after it picks who goes first. Done still leaves sooner.
</en-US>

## What to test (internal testers)

Everything in 29896168, plus:
- **Chooser**: start a table from Setup (or Options → Chooser), put two or more fingers down. After the pick the tracker comes back on its own about 1.5 seconds later. Check that Done shows at the bottom while you wait (on 29896168 it didn't on John's phone; the cause isn't known, so a screenshot helps if it's still missing).

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-04 at 1dc20ab (Android changes since 29896168: 38269b0, the chooser returns to the tracker and is a full-screen dialog; client-only) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified, with warnings that three Glance error-layout entries are "signed in JarFile but not in JarInputStream"; the release build's widget check passed; versionCode 29896900, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. 411 unit tests passed on 1dc20ab. Uploaded to Play internal testing by John 2026-11-04; registered with `bugs.py shipped android 29896900 --commit 1dc20ab`.
