# Card scanning test set

Real photos of Magic cards, with the card and printing each one shows, used to measure and tune the scanner's
matcher (`apps/ios/Table1/Library/CardMatcher.swift`, `apps/android/.../library/CardMatcher.kt`). The unit tests
run the matcher over OCR text read from these photos, so OCR runs once here, on a Mac, not in the tests.

| File | What it is |
| --- | --- |
| `photos/` | 179 photos from eBay listings (sellers' own phone photos): table tops, playmats, hands, sleeves, toploaders, stands, graded slabs, glare and dim light. JPEG, 1280 px. |
| `photos.tsv` | One row per photo: expected card `name`, `set` and `cn` (`*` = any; `set` `*` = name only, used for old foreign cards that aren't in the catalog), printed language, tags, source listing. |
| `ocr.json` | Apple Vision's read of each photo, lines top of the frame first (the order the scanner hands the matcher): `accurate`, `fast` and `small` (accurate at half size, the card further away). |
| `motion.json` | A 2.4 s clip per photo, 12 frames 200 ms apart, of a hand moving the card on all three axes (pan, toward/away, roll and tilt, with motion blur), each frame read like `accurate`. Photo *n* (in `photos.tsv` order) is a *settle* clip when *n* % 3 = 0 (moves in, then holds), *shake* when 1 (tremor and slow drift), *sweep* when 2 (large continuous movement). |
| `catalog.tsv.gz` | The catalog pack the tests match against: every card and printing of pack `v1-5eb83290eb37`, ids shortened. |
| `reports/` | Scan corrections people made in the app, exported by `tools/export_reports.py`; the tests run each one as a clip. |
| `tools/ocr.swift` | Makes `ocr.json` (`swift testdata/scan/tools/ocr.swift`) and `motion.json` (`… ocr.swift motion`; compile it with `swiftc -O` first, it's slow interpreted). |
| `tools/trim_pack.py` | Makes `catalog.tsv.gz` from a downloaded pack. |
| `tools/export_reports.py` | Exports scan corrections (service key) into `reports/`. |

Tags: `frame93` `frame97` `frame03` `frame15` `frame20` (card frame era), `retro`, `borderless`, `showcase`,
`extended`, `fullart`, `foil`, `etched`, `textured`, `galaxy`, `surge`, `promo`, `prerelease`, `white-border`,
`lang` (not English), `dfc` `mdfc` `flip` `split` `adventure` `sideways`, `graded`, `toploader`, `sleeve`, `hand`,
`small` (card small in the frame), `clutter` (other cards or text around it), `signed`, `basic`.

## Adding photos

Put the photo in `photos/` (`NNN-card-name.jpg`, 1280 px), add its row to `photos.tsv`, run both `ocr.swift`
passes, then the tests. Real phone photos from the Table 1 camera are the most useful additions: dim rooms, glare
on sleeves, foreign cards, and anything the scanner got wrong.

## Accuracy (2026-10-15, iOS and Android give the same numbers)

Still photos, Vision `accurate`:

| | Name | Wrong card | Printing |
| --- | --- | --- | --- |
| Before tuning | 124/179 (69%) | 12 | 91/118 (77%) |
| **Now** | **140/179 (78%)** | **0** | **114/134 (85%)**, 2 claimed sure but wrong |
| Now, English cards | 134/141 (95%) | 0 | 108/128 (84%) |
| Now, other languages | 6/38 (16%) | 0 | 6/6 |

`fast` reads: 92/179 names (was 46), 0 wrong (was 27). `small`: 137/179, 0 wrong.

Movement clips, English cards, a card taken within 2.4 s:

| | Before (0.4 s / 1.2 s, any miss resets) | Now |
| --- | --- | --- |
| Settle | 31/47 (66%) | 44/47 (94%), median 1.6 s from the start of the clip |
| Shake | 32/47 (68%) | 39/47 (83%), median 0.4 s |
| Sweep | 0/47 | 0/47 (blurred throughout; nothing should be taken) |
| Wrong card taken | 0 | 0 |

What changed:
- Names: exact name first, top lines first, and never below the type line; a name cut off at the frame edge
  (unique prefix) or misread by about one letter in six (fuzzy, only when nothing else is as close); a name split
  over two lines; up to three short trailing tokens (a misread mana cost) dropped. A double-faced card's front
  face must match exactly (it used to match any card starting with the line: "Summon Doppelganger" → "Summon:
  Bahamut"). Tokens, art cards, emblems and Vanguard can't be scanned.
- Printing: the bottom line is parsed as it's printed ("154/196 M", "RIX • RU", "M 0244", "0014"); power/toughness
  is no longer read as a collector number; the copyright year separates reprints with the same number (Urza's
  Saga / 7th Edition, 4th Edition / Revised); a prerelease date stamp picks the prerelease promo. Foreign cards with
  a legible set code and number match without the name.
- Steadiness: taken 0.4 s after first seen once the printing is read, else 0.8 s (was 1.2 s); a blurred frame no
  longer resets the card unless the gap passes 0.5 s; the printing is the one read most often.

Known gaps:
- Old cards (1993–1997 frames) print no set code or collector number, so the printing is a guess (flagged "Check
  printing"); 10 of 19 such cards get the wrong printing, almost all Revised/Unlimited/4th Edition read as Alpha.
- Foreign cards printed before 2015 (no set code at the bottom) can't match: the catalog pack has English names
  only. Adding printed names in every language to the pack (Scryfall `all_cards`) would fix most of the 32 misses.
- Prerelease promos whose date stamp doesn't read come out as the regular printing (2 here).
- The movement clips are synthetic (a real photo moved by a model of a hand), and Vision on a Mac is not
  VisionKit's live-text pipeline on a phone. Real-device reports (`reports/`) are the check on both.
