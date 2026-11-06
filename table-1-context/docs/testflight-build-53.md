Table 1 0.1.0 (53) — What to Test

On top of build 52 (everything in 52's notes, plus):

BUY
- Open one of your decks or cubes and tap Buy (under Add to collection). The total is at the top, then the options, the cards to buy, and Price / Owned / Total.
- Turn Skip cards I own off and on: the list and the total should change. With it on, try Any printing I own counts off: cards you own only in another printing should come back.
- On a deck, turn on Tokens and change Boards (add Considering).
- Tap Buy on TCGplayer. With Exact printings off you should land in one TCGplayer Mass Entry cart; with it on, a menu of each printing's page.
- Wants and Missing: Buy on TCGplayer now opens the same screen first.
- On a card's page: + → Add to → TCGplayer opens that printing's TCGplayer page.
- Every TCGplayer link goes through Table 1's partner link first and lands on the same TCGplayer page.

CARD ICON WIDGET
- On a card's page, open details (the list icon) → Use for the icon widget. Then add the Card icon widget (small) to your Home Screen: the Table 1 mark over that card's art. Long-press → Edit Widget to pick another icon card.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-06 at ed282ac from a clean worktree (version 0.1.0, build 53, Release, automatic signing; archive "Table 1 6-11-2026, 11.52"). On top of build 52 (43120e5): 4c76497 (card icon widget), 081a3bb (scanner name index package; speeds Debug only), 29068bd (affiliate tags: the cart call sends p_from; affiliate link live on the server since 2026-11-06), 2afe6f7 (Buy screen; contract/buy-2026-11-06.md; web live), bd91449 (Debug-only event demos). The affiliate wrapper is server-side (t1_private.settings tcgplayer.link, checked 2026-11-06: deck, cube and missing carts from an iOS client come back as partner.tcgplayer.com links with subId1=ios and subId2 = the screen). 401 iOS unit tests passed on 2afe6f7 (the app code at ed282ac differs only by the build number). Not uploaded yet: waits in Xcode Organizer; after upload, `bugs.py shipped ios 53 --commit ed282ac`. Not yet tried on a phone.
