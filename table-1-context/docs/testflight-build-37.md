Table 1 0.1.0 (37) — What to Test

New since build 35 (build 36 went up at the same time; this build has everything in it):

SIGN IN WITH DISCORD
- The sign-in screen has Continue with Discord, after Google. It opens Discord's own page in a sheet, where you approve Table 1, and brings you back signed in.
- If your Discord email matches an account you already have, you land in that account. A new account adds its first and last name before anything else, like email sign-in.
- Closing the sheet or pressing Cancel on Discord's page takes you back to sign-in with no error.
- Signing in with Discord also links you to the Table 1 bot in Discord servers (table-1.site/discord).
- Please check: sign in with Discord (a new account and an existing one if you can), cancel once, and tell us if you end up anywhere unexpected.

INSIGHTS: THE FORMAT PAGE
- A format opens on Meta over time and the matchup grid, then the summary and the headline numbers.
- Below them, one row per part: Meta now, Cards rising and falling, New set, Bans and unbans (Points changes for Canadian Highlander), and Big events / Events. Each row sums up its part in a line and opens it on its own screen, with only the pickers that part uses.
- Every format's numbers now refresh on schedule (a server fix, live 29 Oct); before, a format could be up to a day behind.
- Please check: open each format and each part, change the window and Big events / All events on a part, and tell us if any row's summary doesn't match its screen.

DECKS AND CUBES
- Basic lands no longer get the red "short" mark in Grid and Stacks when you own fewer than the deck lists.

TAB BAR
- Tabs you're not on have lighter labels that match their icons.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-10-29 at 8bdbd1a from a clean worktree and uploaded from the command line by Claude (`xcodebuild -exportArchive -allowProvisioningUpdates`, ExportOptions method `app-store-connect`, destination `upload`, team 94889YTX94, automatic signing, `manageAppVersionAndBuildNumber` false); version 0.1.0. On top of build 36 (1b1078f) it adds fb7a45f (Sign in with Discord); the Discord bot work after it is server and web only. Build 36 was uploaded the same way minutes earlier: the CLI upload worked again (the "Failed to Use Accounts" failures of builds 28–33 are gone once the license agreement was accepted on 2026-10-28). Registered with `bugs.py shipped ios 36 --commit 1b1078f` and `bugs.py shipped ios 37 --commit 8bdbd1a`.
