Table 1 0.1.0 (58) — What to Test

On top of build 57 (everything in 57's notes, plus):

INSIGHTS: DROPDOWNS AND OVERALL
- Insights → Constructed: Format · Events · Window are now dropdowns along one row. Tap each; the list shows the current choice outlined. "Shown formats…" at the end of Format opens the hide switches.
- The matchup grid's first column is Overall: each deck's win rate against everyone. Tap it for the record and likely range.

INSIGHTS: LIMITED, CARDS FIRST
- Insights → Limited opens on Top cards: the ten best for the sort, with each card's art, its mana symbols, rarity, games in hand, and "+4.1" (points above the format's average) under the win rate.
- Sort · Rarity · Color are dropdowns (Color has Colorless now). "Show all N" opens the rest.
- Search a card in the box: it finds it in the set whatever the filters; a card from another set shows under "in other sets" and opens there.
- Rank this set is the big block right under the cards. Color pairs follow; the brief is at the bottom.
- Tap a card: its page opens on the card's picture and mana cost.

JOIN WITH A CODE
- Events tab: an EVENT CODE box under Scan QR / Nearby. Type a 4-character code and Join.
- Copy a message with a code in it ("Draft tonight! Code: K7PQ") or a join link, then tap Paste: it finds the code and joins. iOS asks "Allow Paste" the first time.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-09 at dcb2c38 from a clean worktree (version 0.1.0, build 58, Release, automatic signing). 432 unit tests passed at e21e033 (the same app code). On top of build 57 (11399c8): e21e033 (Insights dropdown filters, Overall in the matchup grid, Limited cards first with art, Scryfall mana symbols, search and Rank this set; event code field with Paste). No server change. Not yet tried on a phone.
