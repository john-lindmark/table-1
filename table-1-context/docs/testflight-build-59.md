Table 1 0.1.0 (59) — What to Test

On top of build 58 (everything in 58's notes, plus):

INSIGHTS: LIMITED FILTERS
- Insights → Limited: Rarity and Color take several picks. The list stays open while you pick; Any clears; Done closes. W + U keeps Azorius gold cards too.
- Rank this set is now at the very bottom of the page.

RANKINGS ON YOUR PROFILE
- Your profile lists your shared rankings. Account → Sharing has a Rankings row (Friends by default).
- Open a friend's profile: their rankings you're allowed to see are there.

POPULAR CUBES TO RANK
- Rankings and your profile have a Popular cubes section: PowerLSV, LSVCube, MTGO Vintage Cube and Arena Powered Cube. Rank one, and see which friends have ranked it.

LIMITED CARDS WIDGET
- Add the Limited cards widget (small, medium, large). Edit Widget: pick the set, the sort, rarities and colors. Tap it to open that set in Insights.

SUPPORT
- Account → Support: search the answers and the feature guide, browse topics, and find where to ask for help.

TERMS OF SERVICE
- Account → Terms of service opens the terms on table-1.site.

FOLDABLES AND WIDE WINDOWS
- On an iPhone Duo (or any wide window), the tab bar becomes a rail, the card page and the organizer's live round split in two, and the life tracker stands up on a half-folded phone.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-10 at 99277b5 from a clean worktree (version 0.1.0, build 59, Release, automatic signing with the App Store Connect API key; archive "Table 1 10-11-2026, 09.16"; dSYMs uploaded to Sentry by the post-action). 445 unit tests passed at 99277b5. Uploaded from the command line with the Admin API key 56RQNWR247 (`xcodebuild -exportArchive … -authenticationKey…`): "Upload succeeded", the first build to go up that way. On top of build 58 (dcb2c38): 13a98bd (Limited multi-pick, rankings on profiles, Limited cards widget), 3f363e2 (foldables), 3594311 + b47ea49 (Support), 6c30930 (Terms of service row), 88bcae4 (popular cubes; server live 2026-11-10). Registered with `bugs.py shipped ios 59 --commit 99277b5`. Not yet tried on a phone; the iPhone Duo layouts never seen on a Duo simulator (no iOS 27.1 runtime).
