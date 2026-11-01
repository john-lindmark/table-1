Table 1 0.1.0 (44) — What to Test

On top of build 43:

SCANNER
- The camera reads the whole frame again, as it did before 28 October. Build 43 read only around the outline and read the card's bottom strip on its own; a card held a little larger than the outline lost its title, and an Ice Age Counterspell went in as "Gustha Ebbasdotter" (the name in its flavor text) three times. That can't happen now: a name is never taken from below the type line, on iPhone and Android.
- Scan a pile of mixed cards, old and new, on a busy desk, and hold some larger than the outline. Watch for speed over 30+ cards and for any wrong card.
- Old sets still can't be told apart from the text: Alpha, Beta, Unlimited and Revised all go in as Revised until you fix one, and the next ones follow your fix. The printing rules from 28 October (retro frames, artists, set codes) stay.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-01 at e3f6880 from a clean worktree (version 0.1.0, build 44, Release, automatic signing; archive "Table 1 1-11-2026, 13.57" in ~/Library/Developer/Xcode/Archives/2026-11-01). The command-line upload failed again with "Failed to Use Accounts" (App Store Connect access for 94889YTX94 required), so it waits in Xcode Organizer (opened there with `open <archive>`) for John to upload; then `bugs.py shipped ios 44 --commit e3f6880`. On top of build 43 (ca5153d): 3b5f951 (the iOS camera reads the whole frame again: no `regionOfInterest`, no deskewed bottom-strip read, no Core Image per frame; the matcher never takes a name from below the type line on both platforms; John's build 43 report 17843b42 as a test case; tests `testNoNameFromBelowTheTypeLine` / `noNameFromBelowTheTypeLine`, scanner suites 23/23 on iOS and the Android matcher suite 14/14, reports 196/202 named with 0 wrong, printing 90/195). No server change. Not yet tried on a phone.
