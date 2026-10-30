Table 1 0.1.0 (38) — What to Test

New since build 37:

DECK PHOTOS AFTER THE EVENT
- A finished event's Results screen has More → Add a deck photo (also Redraft, Draft picks and Share link). The After the event row now says Add, so you can still add your deck once the event is over.
- Adding a photo shows the whole picture with Rotate left / Rotate right, and it uploads turned the way you left it.
- A photo already uploaded can be turned from its menu (Rotate right / left) by the player it belongs to or whoever uploaded it. Everyone sees it turned.
- Photos in the list show whole instead of cropped.
- Please check: add a photo to a finished event, turn one sideways photo before and after upload, and tell us if anyone sees it the wrong way round.

INSIGHTS
- Your Insights picks (format, Big events / All events, window, set, hidden formats and sets) now follow your account, so they're the same on your phone, the web and Android.
- Constructed numbers now include paper events from Melee (Regional Championships, Spotlights and other big Melee events), and the credit line names every source.
- Please check: change a few picks here, then open Insights on table-1.site and see they match.

COLLECTION
- The Collection home shows your hero art and binders straight away, instead of placeholder art and no binders for the first few seconds.

SIGN-IN
- The email code field says "From the email" instead of showing a six-digit placeholder (codes can be longer).

ALREADY LIVE FOR EVERY BUILD
- Organizers get a push when a player signs up or drops (tap opens the event).
- Event cards posted by the Table 1 Discord bot now update as people sign up from the app or web, and team events' results in Discord show each team with its members.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-10-29 at 65f2fd8 from a clean worktree and uploaded from the command line by Claude (`xcodebuild archive -allowProvisioningUpdates`, then `-exportArchive` with ExportOptions method `app-store-connect`, destination `upload`, team 94889YTX94, automatic signing, `manageAppVersionAndBuildNumber` false); version 0.1.0. On top of build 37 (8bdbd1a) it adds 70c4002 (Melee credit), 08e9e40 (code placeholder), 9bf8e2c (Library stores start side by side), 3e2571d (Insights picks on the account) and d742df4 (deck photos after the event and rotation). The server parts (insights_picks, deck_photo_turns migrations) are live. Registered with `bugs.py shipped ios 38 --commit 65f2fd8`.
