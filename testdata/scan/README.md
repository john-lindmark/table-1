# Card scanning test set

Real photos of Magic cards, with the card and printing each one shows, used to measure and tune the scanner's
matcher (`apps/ios/Table1/Library/CardMatcher.swift`, `apps/android/.../library/CardMatcher.kt`). The unit tests
run the matcher over OCR text read from these photos, so OCR runs once here, on a Mac, not in the tests.

| File | What it is |
| --- | --- |
| `photos/` | 291 photos from eBay listings (sellers' own phone photos): table tops, playmats, hands, sleeves, toploaders, stands, graded slabs, glare and dim light; 148 English cards and 143 in other languages (de 24, it 18, ja 27, ko 18, zht 14, es 11, fr 11, ru 12, pt 4, zhs 4). Photos 000–181 were added first, 200–312 for the foreign test. JPEG, 1280 px. |
| `photos.tsv` | One row per photo: expected card `name`, `set` and `cn` (`*` = any; `set` `*` = name only, used for old foreign cards that aren't in the catalog), printed language, tags, source listing. |
| `ocr.json` | Apple Vision's read of each photo, lines top of the frame first (the order the scanner hands the matcher): `accurate`, `fast`, `small` (accurate at half size, the card further away) `multi` (accurate with automatic language detection, so Japanese, Chinese and Korean come through; the scanners switch to reading like this when text names no card, see "Language detection") and `title` (the card's title bar read on its own, in front of `multi`; measured, not read by the scanners, see "Title bar pass"). |
| `motion.json` | A 2.4 s clip per photo, 12 frames 200 ms apart, of a hand moving the card on all three axes (pan, toward/away, roll and tilt, with motion blur), each frame read like `accurate`. Photo *n* (in `photos.tsv` order) is a *settle* clip when *n* % 3 = 0 (moves in, then holds), *shake* when 1 (tremor and slow drift), *sweep* when 2 (large continuous movement). |
| `catalog.tsv.gz` | The catalog pack the tests match against: every card, printing and printed name (N lines, de es fr it pt ru ja zhs zht ko) of pack `v1-4f3fd420d850`, ids shortened. |
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

## Accuracy (2026-10-16, iOS and Android give the same numbers)

Still photos, Vision `accurate` (the first rows are the first 179 photos):

| | Name | Wrong card | Printing |
| --- | --- | --- | --- |
| Before tuning | 124/179 (69%) | 12 | 91/118 (77%) |
| Tuned, English names only | 140/179 (78%) | 0 | 114/134 (85%) |
| **Now** (printed names in other languages) | **161/179 (90%)** | **0** | **123/144 (85%)**, 2 claimed sure but wrong |
| Now, English cards | 134/141 (95%) | 0 | 108/128 (84%) |
| Now, other languages | 27/38 (71%), was 6/38 | 0 | 15/16 |
| Now, Latin and Cyrillic scripts (de es fr it pt ru) | 24/24 | 0 | |
| **All 291 photos** | **235/291 (81%)** | **0** | **183/208 (88%)**, 2 claimed sure but wrong |
| English cards (148) | 141/148 (95%) | 0 | 115/135 (85%) |
| English cards, `multi` (as the scanner reads since 2026-10-16) | 141/148 (95%) | 0 | 113/135 (84%) |
| Other languages (143) | 94/143 (66%) | 0 | 68/73 (93%) |

All 291: `fast` 126/291 names, 1 wrong (a fast read of Greater Good's "1693" as "1695", which is Ruhan of the Fomori;
the steadiness rule needs the same card over several frames, so one misread frame isn't taken). `small` 228/291, 0 wrong.

### Language detection (`testLanguageDetection` / `languageDetection`)

Nobody picks a language. The scanner reads like the phone (`accurate`: Latin and Cyrillic, English first) until
text in view names no card for 0.6 s, then reads Chinese, Japanese and Korean (`multi`), stays there while cards
match and goes back after 1.2 s of misses (`ScanLanguage` in CardMatcher.swift/.kt). iOS switches Vision's
automatic language detection on (VisionKit's DataScanner can't: given a list of languages it uses only the first
one's model; English first turns CJK into noise, Japanese first breaks Korean and Cyrillic). Android switches from
ML Kit's Latin recognizer to its Japanese, Chinese and Korean ones, a frame each in turn (created, and their models
fetched by Play services, only when first needed). The test holds each photo still for 2.4 s through this and
ScanSteadiness (Android: `multi` stands in for every CJK recognizer):

| | Taken | Wrong | Median time to take |
| --- | --- | --- | --- |
| English (148) | 141/148, printing 115/135: the same as `accurate` | 0 | 0.4 s |
| Latin and Cyrillic (80) | 75/80 | 0 | 0.8 s |
| Chinese, Japanese, Korean (63) | 38/63 | 0 | 1.2 s (0.6 s of it finding the script) |

### Cards in other languages (143; `testForeignCards` / `foreignCards`)

| | `accurate` (as the apps read today) | `multi` (OCR that detects the language) |
| --- | --- | --- |
| Latin and Cyrillic: de es fr it pt ru (80) | 75/80 (94%), 0 wrong | 74/80 (93%), 0 wrong |
| Chinese, Japanese, Korean (63) | 19/63 (30%), 0 wrong | **38/63 (60%), 0 wrong** (was 20/63) |
| By language | de 20/24, es 11/11, fr 10/11, it 18/18, pt 4/4, ru 12/12; ja 13/27, ko 3/18, zht 2/14, zhs 1/4 | ja 19/27, ko 9/18, zht 6/14, zhs 4/4 |

Cards in any of these languages match by their printed name (catalog N lines); `accurate` can't read Chinese,
Japanese or Korean, so there they match only by a legible set code and collector number. The test fails on any
wrong card in either read, when Latin/Cyrillic names (`accurate`) drop below 93% and when Chinese, Japanese and
Korean names (`multi`) drop below 60%.

Where the 25 CJK misses in `multi` come from:
- 12 old Korean and traditional Chinese printings that have no printed name on Scryfall in that language (Korean
  Triskelion, Grizzly Bears, Southern Paladin; Chinese Pestilence, Draco), and Auramancer, whose old Chinese
  printing is translated differently (靈氣術士, not 靈氣法師).
  There is no second source: MTGJSON's `foreignData` (from Gatherer, checked 2026-10-16 for 4BB, 5ED, 6ED, 7ED,
  POR, VIS, WTH, TMP, PLS, ODY, TOR, PCY) has an entry for these printings, but every Korean, traditional and
  simplified Chinese name in those sets is the English name (5ED Korean 449/449, TOR traditional 143/143).
  Folding traditional into simplified Chinese in `CardName.norm` (OpenCC `TSCharacters`, 3,221 pairs) was measured
  and left out: it matches Ball Lightning (爆雷煉球 = 爆雷炼球) in `multi` (zht 6/14 → 7/14), but in the
  title-bar read the graded Basking Rootwalla's 沐日蘿特瓦拉, a name the pack doesn't have, came within one character
  of Sunbathing Rootwalla's 浴日萝特瓦拉: a wrong card. Across the pack it would only add 2 names that two cards share.
- 6 Japanese cards whose name is legible in the photo but Vision doesn't read it (a short title in the old
  font: 瞑想, Meditate), so the first line read is the type line.
- 4 graded slabs (the label is abbreviated English, "LILIANA, DREAD.GNRL."; the card is behind it) and 2 basic lands
  read only by their type line ("基本土地 — 沼").

### Title bar pass (`title`, 2026-10-16; measured, not in the scanners)

A second OCR pass on the title bar alone: `VNDetectRectanglesRequest` finds the card (aspect 0.6–0.85, the largest),
`CIPerspectiveCorrection` deskews it to 630×880, the top 14% left of the mana cost (x 4–80%) is cropped, upscaled 2x
and read with language detection; those lines go in front of `multi`'s. A card-shaped rectangle is found in 210 of
291 photos (often the frame inside the black border, or the sleeve or slab).

| | `multi` | `title` |
| --- | --- | --- |
| All 291 | 254/291, 0 wrong | 257/291, **1 wrong** |
| English (148) | 141/148 | 141/148 |
| Latin and Cyrillic (80) | 74/80 | 76/80 (fr Snow-Covered Island, pt Swords to Plowshares: a cleaner title read) |
| Chinese, Japanese, Korean (63) | 39/63 | 40/63: + 2 graded slabs (Grim Lavamancer zht, Temporal Mastery ko: the title now comes before the label), − Northern Paladin ja (the crop misreads 北の聖謝上 and pushes the right line down) |

(`multi` CJK is 39/63 here, not 38, with traditional/simplified Han folding.)

- None of the 6 Japanese misses (207 Meditate, 211, 212, 215, 216, 218) come back. 207 and 211 are old-frame titles
  about 20 px tall in a 1280 px eBay JPEG: a tight hand crop at 1–4x, grey/contrast/inverted, padded, with automatic
  detection or `ja-JP`/`zh-Hans` forced, reads nothing; the pixels are gone. 212, 215, 216 and 218 are Strixhaven
  Mystical Archive (STA) Japanese cards, whose name is printed **vertically** in a box on the left (否認), so no
  horizontal title bar has it. Those four print "114" / "STA★JP" (number and set code on two lines); the matcher
  doesn't pair a number line with a set-code line, which would name all four without the title.
- The wrong card: 226 Basking Rootwalla (zht, graded). The crop reads 沐日蘿特瓦拉 exactly, but Basking Rootwalla has
  no Chinese name in the pack, and folded to simplified it is one character from Sunbathing Rootwalla's 浴日萝特瓦拉,
  so the fuzzy rule (one edit in six characters) takes it. `multi` on a sharper photo would read the same line, so
  this is a matcher rule to fix (a one-character Han difference in a 6-character name is a different word), not
  something the title pass causes.
- Not wired into the scanners: +3 names, 1 wrong, none of the cases it was for, and a rectangle detection plus a
  second OCR per frame. Worth another look with real phone frames (a live 1080p frame of a card filling the view
  has a sharper title than these photos) once the fuzzy rule is fixed.

Movement clips, English cards, a card taken within 2.4 s:

| | Before (0.4 s / 1.2 s, any miss resets) | Tuned (first 179 photos) | Now (all 148 English cards) |
| --- | --- | --- | --- |
| Settle | 31/47 (66%) | 44/47 (94%), median 1.6 s from the start of the clip | 46/49 (94%), median 1.6 s |
| Shake | 32/47 (68%) | 39/47 (83%), median 0.4 s | 42/51 (82%), median 0.4 s |
| Sweep | 0/47 | 0/47 (blurred throughout; nothing should be taken) | 0/48 |
| Wrong card taken | 0 | 0 | 0 |

What changed:
- Printed names (2026-10-15): the pack's N lines (de, es, fr, it, pt, ru names from Scryfall `all_cards`) join the
  name index; an English name always wins a clash, a printed name two cards share is left out, and a cut-off or
  misread name only counts as ambiguous when the candidates are different cards ("Urza's Sa" fits both "Urza's
  Saga" and its German "Urzas Sage"). Type lines in those languages stop the name search like English ones.
- Names: exact name first, top lines first, and never below the type line; a name cut off at the frame edge
  (unique prefix) or misread by about one letter in eight (fuzzy, only when nothing else is as close); a name split
  over two lines; up to three short trailing tokens (a misread mana cost) dropped. A double-faced card's front
  face must match exactly (it used to match any card starting with the line: "Summon Doppelganger" → "Summon:
  Bahamut"). Tokens, art cards, emblems and Vanguard can't be scanned.
- Printing: the bottom line is parsed as it's printed ("154/196 M", "RIX • RU", "M 0244", "0014"); power/toughness
  is no longer read as a collector number; the copyright year separates reprints with the same number (Urza's
  Saga / 7th Edition, 4th Edition / Revised); a prerelease date stamp picks the prerelease promo. Foreign cards with
  a legible set code and number match without the name.
- Chinese, Japanese and Korean (2026-10-16): the pack carries ja, zhs, zht and ko printed names; `CardName.norm`
  keeps Han, kana and Hangul with nothing between them ("死者の災厄、ケイヤ" → "死者の災厄ケイヤ"; "・", "、" and Korean
  word spaces don't count); such a name can be two characters long but then only counts from the first line (飛行,
  Flying, on the second line is the Japanese name of Flight); type lines in those languages stop the name search
  (also "リーチャー", since OCR misreads the ク); a hiragana-only line is furigana and doesn't count as a line, and
  furigana Scryfall writes into a name in brackets ("耕（こう）作（さく）") is dropped; CJK names count only above the
  type line (short ones turn up in rules text); cut-off
  names need 4 characters and misread ones 4 characters with one edit in six, counted in characters. Android's
  name index uses UTF-8 byte trigrams like iOS (character trigrams lost 爆雷煉球 → 爆雷炼球, one character off).
- Foreign test set (2026-10-15): a one-word name counts only from the first two lines of card text and never from a
  line in capitals ("FOIL" on a grading label is a card; "Fliegen" is the German keyword and the German name of Fly;
  "Umwandlung" is German cycling and Conversion); fuzzy names allow one edit in eight letters, not six ("reserva de
  mana" was one edit in six from the Portuguese Game Preserve); old foreign type lines ("Greif beschwören",
  "Invoquer : hydre") stop the name search; matching by set code and number alone needs the number written as a
  collector number ("154/196", "0244", "R 1695", "297"), not "212", a misread 2/2; date stamps in de, fr, it, es,
  pt and ru pick the prerelease promo ("27-28 giugno 2020").
- Steadiness: taken 0.4 s after first seen once the printing is read, else 0.8 s (was 1.2 s); a blurred frame no
  longer resets the card unless the gap passes 0.5 s; the printing is the one read most often.

Known gaps:
- Old cards (1993–1997 frames) print no set code or collector number, so the printing is a guess (flagged "Check
  printing"); 10 of 19 such cards get the wrong printing, almost all Revised/Unlimited/4th Edition read as Alpha.
- Japanese, Korean and Chinese: see the 25 misses above. Language detection has not been tried on a phone yet.
- A printed name matches the card, not the foreign printing: most foreign printings aren't in the catalog
  (Scryfall `default_cards`), so the printing is the English one with the same set and number when it's read.
- Prerelease promos whose date stamp doesn't read come out as the regular printing (2 here).
- The movement clips are synthetic (a real photo moved by a model of a hand), and Vision on a Mac is not
  VisionKit's live-text pipeline on a phone. Real-device reports (`reports/`) are the check on both.
