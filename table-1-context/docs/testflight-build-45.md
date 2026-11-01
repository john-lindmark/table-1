Table 1 0.1.0 (45) — What to Test

On top of build 44:

SCANNER
- Old cards by their border: when the scanner can't read a set code or year (Alpha, Beta, Unlimited, Revised and friends), it now looks at the border color. A black border goes in as Beta, a white one as Revised, and a French card with a black border as Foreign Black Border. Scan a few old black- and white-bordered cards and check the printing it picks; fix one if it's wrong.
- Everything from build 44 still holds: the whole frame is read, and a name is never taken from the flavor text.

DECKS
- Under Stats on your own deck, the archetype row says how similar your deck is to that archetype's lists ("88% similar"). Brews get no archetype rows at all.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-01 at 1a4faad from a clean worktree (version 0.1.0, build 45, Release, automatic signing; archive "Table 1 1-11-2026, 16.45" in ~/Library/Developer/Xcode/Archives/2026-11-01, named "Table 1"). The command-line upload failed again with "Failed to Use Accounts" (App Store Connect access for 94889YTX94 required), so it waits in Xcode Organizer (opened there with `open <archive>`) for John to upload; then `bugs.py shipped ios 45 --commit 1a4faad`. Supersedes build 44 (e3f6880, never uploaded). On top of build 44: 5b56d6e (deck archetype similarity, no rows for brews; server live), ee46ad4 (border color from luma reads around Vision's rectangle or along the guide, used only when nothing printed was read; `testBorderRule` / `testBorderPicksPrinting` / `testBorderSamplingCostAndMapping`; scanner suites 22/22). Not yet tried on a phone.
