Table 1 for Android 0.1.0 (versionCode 29896168) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
In the life tracker, swiping no longer closes the counter picker: swipe up to scroll its list (long at Commander life, with commander damage from each opponent), and tap Done to close it.
</en-US>

## What to test (internal testers)

Everything in 29895843, plus:
- **Counter picker**: swipe toward yourself on your half or seat to open it, as before. Swiping up or away scrolls the list instead of closing it; only Done closes it. Try it at 40 life with 4 players, on a side seat too.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-11-03 at 3d71656 (Android changes since 29895843: 052d4e4, no swipe closes the counter picker; client-only) from the clean checkout with `apps/android/tools/bundle-release.sh` (upload key; `jarsigner -verify`: jar verified; the release build's widget check passed; versionCode 29896168, versionName 0.1.0, 17 MB) at `apps/android/app/build/outputs/bundle/release/app-release.aab`. 409 unit tests passed on 3d71656. Uploaded to Play internal testing by John 2026-11-04; registered with `bugs.py shipped android 29896168 --commit 3d71656`.
