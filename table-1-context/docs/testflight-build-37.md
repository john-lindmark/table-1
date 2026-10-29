Table 1 0.1.0 (37) — What to Test

New since build 36:

SIGN IN WITH DISCORD
- The sign-in screen has Continue with Discord, after Google. It opens Discord's own sign-in in a sheet and comes back to the app.
- If your Discord email matches an account you already have, you land in that account. A new account asks for your name first, like email sign-in.
- Closing the sheet or pressing Cancel on Discord's screen takes you back to sign-in with no error.
- Please check: sign in with Discord (new account and existing account if you can), cancel once, and tell us if you end up anywhere unexpected.

Build 36 (format page parts in Insights, lighter tab bar labels, basics never marked short) went up at the same time; everything in it is in this build too.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-10-29 at 8bdbd1a from a clean worktree and uploaded from the command line by Claude (`xcodebuild -exportArchive -allowProvisioningUpdates`, ExportOptions method `app-store-connect`, destination `upload`, team 94889YTX94, automatic signing, `manageAppVersionAndBuildNumber` false); version 0.1.0. On top of build 36 (1b1078f) it adds fb7a45f (Sign in with Discord); the Discord bot work after it is server and web only. Build 36 was uploaded the same way minutes earlier: the CLI upload worked again (the "Failed to Use Accounts" failures of builds 28–33 are gone once the license agreement was accepted on 2026-10-28). Registered with `bugs.py shipped ios 36 --commit 1b1078f` and `bugs.py shipped ios 37 --commit 8bdbd1a`.
