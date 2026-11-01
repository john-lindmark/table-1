Table 1 0.1.0 (43) — What to Test

On top of build 42:

SCANNER
- Scanning stays as quick on the thirtieth card as on the first. Build 42 got slower with every card in the scanned list (closing and reopening the scanner reset it); the screen was being redrawn on every camera frame, scanned rows included. Now a camera frame redraws nothing.
- Scan a pile of 30+ cards in one go, on a busy desk too, and watch for any slowdown as the list grows.

SIGN-IN
- Signed out, the sign-in screen shows a carousel of what Table 1 does (run events, life tracker, your record, Insights, imports, rankings) under a small Table 1 mark. Joining from a QR code or a sign-up link still shows the event instead.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-01 at ca5153d from a clean worktree (version 0.1.0, build 43, Release, automatic signing, `xcodebuild archive -allowProvisioningUpdates`; archive "Table 1 1-11-2026, 13.15" in ~/Library/Developer/Xcode/Archives/2026-11-01). **The command-line upload (`-exportArchive`, method `app-store-connect`, destination `upload`, team 94889YTX94) failed with "Failed to Use Accounts: App Store Connect access for 94889YTX94 is required"**, as build 42's did, so it waits in Xcode Organizer: upload it from Organizer, or sign in again in Xcode → Settings → Accounts and rerun the export. Then `bugs.py shipped ios 43 --commit ca5153d`. On top of build 42 (5a0b2d3): a26559c (feature spots: the sign-in carousel, iOS `UI/Spots.swift`), ac6b32f (the scanner screen no longer re-evaluates on every camera frame: `CardScanView.Feed`, test `testFrameRedrawsNothing`; 0.5 ms with no rows and 14.8 ms with 60 per re-evaluation in the Debug Simulator, five times a second on build 42). No server change. John confirmed on build 42 that the slowdown reset on reopening the scanner, which is what this fixes; not yet tried on a device.
