# Card scanning test set

Real photos of Magic cards, with the card and printing each one shows, used to measure and tune the scanner's
matcher (`apps/ios/Table1/Library/CardMatcher.swift`, `apps/android/.../library/CardMatcher.kt`). The unit tests
run the matcher over OCR text read from these photos, so OCR runs once here, on a Mac, not in the tests.

| File | What it is |
| --- | --- |
| `photos/` | 291 photos from eBay listings (sellers' own phone photos): table tops, playmats, hands, sleeves, toploaders, stands, graded slabs, glare and dim light; 148 English cards and 143 in other languages (de 24, it 18, ja 27, ko 18, zht 14, es 11, fr 11, ru 12, pt 4, zhs 4). Photos 000–181 were added first, 200–312 for the foreign test. JPEG, 1280 px. |
| `photos.tsv` | One row per photo: expected card `name`, `set` and `cn` (`*` = any; `set` `*` = name only, used for old foreign cards that aren't in the catalog), printed language, tags, source listing. |
| `ocr.json` | Apple Vision's read of each photo, lines top of the frame first (the order the scanner hands the matcher): `accurate`, `fast`, `small` (accurate at half size, the card further away) `multi` (accurate with automatic language detection, so Japanese, Chinese and Korean come through; the scanners switch to reading like this when text names no card, see "Language detection"), `title` (the card's title bar read on its own, in front of `multi`; measured, not read by the scanners, see "Title bar pass") and `bottom` (`accurate`, then the card's bottom strip read on its own, as the iOS scanner reads since 2026-10-28; `… ocr.swift bottom` adds it to an existing file). |
| `motion.json` | A 2.4 s clip per photo, 12 frames 200 ms apart, of a hand moving the card on all three axes (pan, toward/away, roll and tilt, with motion blur), each frame read like `accurate`. Photo *n* (in `photos.tsv` order) is a *settle* clip when *n* % 3 = 0 (moves in, then holds), *shake* when 1 (tremor and slow drift), *sweep* when 2 (large continuous movement). |
| `catalog.tsv.gz` | The catalog pack the tests match against: every card, printing and printed name (N lines, de es fr it pt ru ja zhs zht ko) of pack `v1-4f3fd420d850`, ids shortened. |
| `reports/` | Scan corrections people made in the app, exported by `tools/export_reports.py`; the tests run each one as a clip. 201 labelled on 2026-10-28 (232 reports from Oct 24–28, 199 of them wrong printings; the 32 with no answer sit in `reports/unlabelled/`, which the tests skip). |
| `border.json` | The luma samples the border rule reads (see "Border colour"), per photo with a border (259: `borderless` cards left out): `quad` as the iOS scanner samples around Vision's rectangle, `g100` as Android samples along the guide box (here the rectangle's bounds standing for the guide), and both again on a dim, low-contrast copy (`dim.quad`, `dim.g100`); `expected` is `white` for `white-border` photos, else `black`. Compact JSON; made by `tools/border.swift`. |
| `tools/border.swift` | Makes `border.json` (`swift testdata/scan/tools/border.swift [check]`; `check` also tallies the reference rule per read and checks the iOS orientation mapping against Vision). |
| `tools/ocr.swift` | Makes `ocr.json` (`swift testdata/scan/tools/ocr.swift`) and `motion.json` (`… ocr.swift motion`; compile it with `swiftc -O` first, it's slow interpreted). |
| `tools/trim_pack.py` | Makes `catalog.tsv.gz` from a downloaded pack (keeps the illustrator and frame fields since 2026-10-28). |
| `tools/art_fields.py` | Adds the illustrator and frame to an older `catalog.tsv.gz` from Scryfall's `default_cards` bulk file (by set, number and language; the test pack's ids are counters). |
| `tools/export_reports.py` | Exports scan corrections (service key) into `reports/`. |
| `tools/art_refs.py`, `art_fetch.swift`, `art_match.swift` | The art matching spike (see "Art matching spike"). |

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

### Language of the copy (2026-10-20; `testForeignCards` / `foreignCards`)

A scanned copy goes in as the language its text says (contract/card-language-2026-10-19.md): the code by the set
code ("WAR • JP"), else the languages of the printed name read; English is picked for adds in the test. Of the cards
in other languages named right, `accurate` puts 88/94 (94%) in their own language, `multi` 105/112 (94%); floor 93%.
No English card goes in as another language (`testStillPhotos`). The misses: Pendelhaven, Eureka (it), Triskelion,
Manifold Key (de) print the English name; Barbarian Lunatic (es, read as it) and Yavimaya Coast (pt, read as es) are
names those languages print alike once accents go; Ball Lightning (zht) read as Simplified.

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

### Card gate (`inCard`, `testCardGate`, 2026-10-16; in the iOS scanner)

A phone pointed at a MacBook keyboard read "command" / "option" and took Opt ("Option" is a printed name of it); a
Cube Cobra page on a screen gave Mana Vault from a list of names (scan reports, 2026-10-15). The scanner now runs
`VNDetectRectanglesRequest` in the same Vision pass as the text (aspect 0.6–0.85, a fifth of the frame or more,
upright only: a landscape rectangle is usually the art box) and:
- with a card found, reads only the text whose centre is inside it (the rectangle grown 10%, since the frame
  inside the black border is often what's found);
- with none found, reads the whole frame but takes a card only when the lines have a type line, or a set code and
  number that agree with the name.

| | Name, all 291 | English (148) | Wrong |
| --- | --- | --- | --- |
| No gate (`accurate`) | 235 | 141 | 0 |
| **Gate (`inCard`, else frame with type line or printing)** | **233** | **140** | **0** |
| Gate, `multi` | 253 | 140 | 0 |
| Only the text inside the card, nothing without one | 169 (deskewed) | 90 | 0 |
| Whole frame, printing required | 143 | 92 | 0 |

A card is found in 220 of 291 photos. Reading the deskewed card on its own (CIPerspectiveCorrection) named far
fewer cards than filtering the frame's own read, so the scanner filters. Still let through: a list of names with a
type word in it ("Sorcery (8)" on Cube Cobra) when no card is in view.

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
- Old frames (2026-10-26): with no printing to read they wait for the slow take, and their names misread in a third
  of frames or more ("Fundra", "Cuunterspell", "Uhamme" in phone reports), so a gap over 0.5 s kept starting them
  over (Crusade, named 6 times in 2.4 s, never taken). The gap is now 1 s and the slow take needs 3 frames that name
  the card. Movement clips: shake 42/51 → 46/51, settle median 1.6 → 1.2 s, sweeps 0/48 taken, no wrong cards;
  1993–2003 frames 19/26 → 20/26 (the rest are names the camera doesn't read at all: "D vamp", nothing for
  Cyclopean Tomb). Printing: an "Illus." line and no year means 1993–94; ties go to Revised, Unlimited, Beta, then
  Alpha (was Alpha); a foreign name on an old frame picks that language's printing (Foreign Black Border); the
  printing picked by hand on a scanned row is the next guess (same set, nearest number). Phone reports in
  `reports/` (the 7 old-card ones): 5/7 printings right, was 0/7; the 2 left are Unlimited Scrublands read as
  Revised, which no text tells apart (the border colour would: black Alpha/Beta, white Unlimited/Revised).

Known gaps:
- Old cards (1993–1997 frames) print no set code or collector number, so the printing is a guess (flagged "Check
  printing"). Since 2026-10-26 the guess is Revised, not Alpha; Beta and Unlimited need one fix by hand, then
  follow. Since 2026-11-01 the border colour is read from the frame and picks Beta or Revised (see "Border colour");
  Alpha from Beta and Unlimited from Revised still need a fix by hand. Old-frame names misread far more than modern ones on a phone. Since
  2026-10-28 an "Illus." line prefers 1993/1997 frames, so a retro-frame reprint of a card with no old printing
  (MH2 438) is found from the credit alone; a card with both (Lightning Bolt) still goes in as Revised.
- Japanese, Korean and Chinese: see the 25 misses above. Language detection has not been tried on a phone yet.
- A printed name matches the card, not the foreign printing: most foreign printings aren't in the catalog
  (Scryfall `default_cards`), so the printing is the English one with the same set and number when it's read.
- Prerelease promos whose date stamp doesn't read come out as the regular printing (2 here).
- The movement clips are synthetic (a real photo moved by a model of a hand), and Vision on a Mac is not
  VisionKit's live-text pipeline on a phone. Real-device reports (`reports/`) are the check on both.

### Printings from the frame, the artist and the last frames (2026-10-28; `testPrintingEvidence`, `testBottomLineParsing`)

232 phone reports from Oct 24–28 (John's own collection, iOS builds 23–33), 199 of them wrong printings: MH2's
retro-frame fetchlands went in as Zendikar's, Ravnica Remastered's retro shocklands as the originals, borderless and
showcase cards as the regular printing, The List as the set it reprints. What the frames had read: a retro frame
shows its "Illus. <artist>" line and sometimes the end of its copyright line ("™ & © 2021 Wizards of the Coast 438")
and almost never the tiny set code; a borderless card's set code came in one frame ("MH2 • EN A- ZEZHOU CHEN") and
its number four frames later ("312"); set codes read with the bullet as a letter ("MH2 WEN", "ECL MEN") or a dash;
copyright years garbled ("& C 2013W"). Scryfall's artist and frame per printing were the missing data: MH2 438 and
ZEN 220 Misty Rainforest share Shelly Wan's art, but one is a 1997 frame and the other 2003.

The catalog pack's P lines now carry both (contract/catalog-2026-10-14.md; `art_fields.py` added them to the test
pack), and the matcher (rules in contract/trades-2026-10-16.md § Scanning) scores a printing by set code (4),
number (2), year (1), an "Illus." line for 1993/1997 frames (2), an artist after a brush for 2003+ frames (1) and
the artist's name read (2, fuzzy by a letter or two per word); a lone three-digit number counts for a card with no
power/toughness; the number at the end of a copyright line counts; what the last five frames of the same card read
is merged. Still photos (iOS): names 236/291, printing 186/208 (89%, was 183/208), English printing 119/134 (89%, was
115/135), 0 wrong cards, 2 sure-but-wrong as before. With the bottom strip read (`bottom`): names 240/291, printing
188/212. Movement clips: shake median 0.6 → 0.2 s (two frames that read the same printing exactly take the card),
settle 1.2 s as before, sweep 0/48 taken, 0 wrong.

Bounded evidence (2026-10-31; `testEvidenceStaysBounded` / `evidenceStaysBounded`): the merged evidence had kept every
frame's words for as long as a card stayed in view, and the artist's fuzzy word match ran over all of it several
times per printing on every frame, so each frame was slower than the last (80 frames of one card on a cluttered
desk: 0.1 s → 7.9 s per frame on the JVM) and frames queued up behind the main thread for the rest of the session.
Now the last ten frames are kept, each artist is looked up once per frame and each frame searched once per artist
(`ScanLines`, words compared as bytes), the per-line
regexes are skipped on lines that can't match them (no digit, no two capitals in a row, no "Illus."-like start), and
the scanners drop a frame read while the last one is still being matched. Accuracy numbers unchanged.

Still slower after many cards on build 42 (2026-11-01, iOS; `testFrameRedrawsNothing`): the matcher was bounded, but
the scanner screen's steadiness and frame memory were `@State` structs written on every camera frame, so every frame
re-evaluated the whole screen, scanned rows included, and that costs more for every row: measured in the Simulator
(Debug) at 0.5 ms with no rows and 14.8 ms with 60, about five times a second, on the main thread the matcher shares.
Now they live in a class held in `@State` (`CardScanView.Feed`), and a frame redraws nothing; the test pins the type
and prints the cost. Android's steadiness and frame memory were never Compose state, so it had no such redraw. The
remaining per-frame work is Vision's two text reads, the rectangle search and the strip crop; on a phone that is a
sustained load, so if scanning still slows with time rather than with rows, thermal throttling is the next suspect
(it would recover after a minute idle, not on reopening the scanner). Vision's automatic language detection, which
the scanner stays in once it has switched while cards keep matching, costs only a few percent more per read on the
Mac (median 146 vs 140 ms over 30 photos) and isn't it.

Build 43 was still slow on John's phone and named cards wrong (2026-11-01), so the camera side of 2026-10-28 is
reverted: the iOS scanner reads the whole frame again (no region of interest around the guide, no deskewed
bottom-strip read, no Core Image per frame); the matcher's printing rules from that day stay. His reports showed
why: an Ice Age Counterspell, held larger than the guide, lost its title to the reading region's edge in most frames
(they start at "Interrupt"), and the matcher's fallback, an exact multi-word name anywhere in the first twelve lines,
took the flavor text's "-Gustha Ebbasdotter," for the card (a Mystery Booster Commander card), three takes in a row
(report 17843b42, now a case here). The matcher on both platforms now never takes a name from below the type line
(`testNoNameFromBelowTheTypeLine` / `noNameFromBelowTheTypeLine`); the photo and report numbers are unchanged
(JVM: reports name 196/202, 0 wrong, printing 90/195). Old sets stay a guess: Alpha, Beta, Unlimited and Revised
print nothing that tells them apart, so the scanner guesses Revised and follows a hand fix for the next card; the
border colour (black for Alpha, Beta and Foreign Black Border, white for Unlimited and Revised) is the next tell
worth reading from the frame, and would halve that guess.

Reported corrections (201 clips): name 196/201, **printing 90/195 (46%), was 5/195** (every report was a wrong
printing). Of the 105 left: 21 The List (the bottom text is the reprinted set's; only a tiny symbol differs), 11
prerelease and promo-pack stamps the camera doesn't read, 8 Unlimited/Beta read as Revised (nothing printed tells
them apart; the border colour would), 3 where the frames read a number that contradicts the correction, and about
60 whose frames read no bottom line at all (11 retro fetchlands with only the name and rules text, Harmonic Prodigy,
Mindbreak Trap, shocklands of 2012–13): those are what the iOS scanner's bottom strip read is for, which the clips
(whole-frame reads) can't show; real phone reports after the next build are the check. The test floor on reports
is 44%.

### Border colour (2026-11-01; `testBorderRule`, `testBorderPicksPrinting`, Android `borderRule`, `borderPicksPrinting`)

Alpha, Beta and Foreign Black Border cards have black borders; Unlimited and Revised white ones; nothing printed on
a 1993–94 card tells them apart, so every one went in as Revised (John's Android report, 2026-11-01). Now the
scanners read the border colour from the camera frame and the matcher uses it as a tie-break under the hand-picked
set: black picks Beta (the commoner black border), white Revised; a foreign name still picks its language's printing
first (French → Foreign Black Border); anything printed that was read (a set code, number or year) still wins; the
read is remembered over the card's frames like the rest of the bottom evidence, and forgotten with the take. Alpha
from Beta and Unlimited from Revised still need a fix by hand, which carries to the next card as before.

How it reads (`ScanBorder`, the same rule in CardMatcher.swift, CardMatcher.kt and `tools/border.swift`): a few luma
reads per camera frame, never an image pass. On iOS the card's edge is Vision's card-shaped rectangle (the one the
scanner already finds; the ungrown corners), and without one the guide box; on Android, where ML Kit finds no
rectangle, always the guide box. Around a rectangle: six points a side, luma 1.5% and 3% of the card's width just
inside (12 a side), the same just outside, and at 6.5% and 9% outside (the table), plus 24 points in the text box
(whose darkest sample is the frame's ink and 75th percentile its paper): 120 reads. Along the guide: at six points a
side a profile from 12% outside to 12% inside in 1% steps, the strongest step is the card's edge, and the bands
around it are the same inside / outside / far samples: 624 reads. A side is black when its median luma is ≤ 70,
or ≤ 25% of the way from ink to paper and ≤ 115; white when ≥ 165, or ≥ 90% of the way and ≥ 140 (the absolute
bounds are a well-exposed phone frame; the relative ones keep a dim or low-contrast frame readable; the text box
decides only when it has 50+ of contrast). At least three sides one colour and none the other just inside the edge
is the border; when three or more inside sides are neither, the rectangle was the frame inside the border, and the
same rule runs just outside, counting only sides whose outside band steps (0.3 of ink-to-paper, or 45 luma) to the
far band: a border ends at the table, a table just goes on (without that check a white desk beside a lit black
border read as white). iOS reads the 420v luma plane scaled to full range; an upright pixel (x, y) is the landscape
buffer's (y, height − 1 − x) for orientation .right, checked against Vision by `tools/border.swift check`. Android
reads the Y plane by CameraX's rotation (`ScanBorder.rawPixel`).

Measured over the photo set (`border.json`, 259 photos with a border, 212 with a rectangle), the 61 old-frame
(`frame93`) photos are what the rule is for; "all" includes modern cards, where a wrong read is harmless (the border
only picks between 1993–95 printings) and comes from sleeves and toploaders (their clear margin reads white):

| Read | Old frame right / wrong / unknown (of 58 with a rectangle) | All right / wrong / unknown |
| --- | --- | --- |
| `quad` (iOS, Vision's rectangle) | 47 / 1 / 10 | 139 / 9 / 64 |
| `g100` (Android, the guide; rectangle bounds standing in) | 31 / 0 / 27 | 99 / 15 / 98 |
| guide 6% small / 6% large (`g094`, `g106`, tallied only) | 33 / 0 / 25, 34 / 1 / 23 | 89 / 19 / 104, 108 / 13 / 91 |
| `dim.quad` (contrast 0.55, brightness −0.12, blur 0.8) | 37 / 0 / 21 | 85 / 6 / 121 |
| `dim.g100` | 26 / 0 / 32 | 53 / 9 / 150 |

The one old-frame wrong is 263 Snow-Covered Island (a full-art basic: no text box, so the paper reference is the
art). Rules tried on the way: fixed thresholds alone (149 right but 14 wrong on `quad`, and the dim copies all
unknown: a black border lifts to ~95 luma), the text-box reference alone (basics and dark text boxes break it),
and no far-band check (the outside fallback read white desks as white borders: 085 Imprison). "Unknown" is mostly
a hand or shadow on one side, a sleeve edge, or the guide landing on art rather than the edge; the scanner then
guesses Revised as before. Not yet tried on a phone: real frames (auto-exposed, 1080p) should sit nearer the
plain photos than the dim copies.

Cost per frame, samples and rule together (`testBorderSamplingCostAndMapping`, `borderSamplingCostAndMapping`):
0.03 ms around a rectangle (120 reads) and 0.13 ms along the guide (624 reads) in the Debug Simulator, 0.15 ms
along the guide on the JVM; the camera hands the matcher a frame every 200 ms. No image is rendered or copied: the
reads go straight to the camera buffer's luma plane while Vision / ML Kit already hold it.

### Low-contrast reads of old cards (2026-11-01; `dim`, `dimFixed` in `ocr.json`)

John asked whether processing the image so the name reads better would help old cards, and for lower-contrast
images in the suite. `… ocr.swift dim` reads every `frame93` and `frame97` photo twice more: `dim` is the same dim,
low-contrast copy `border.swift` samples (contrast 0.55, brightness −0.12, blur 0.8), `dimFixed` that copy with its
contrast stretched back (CIColorControls contrast 1.8) before OCR, which is what a per-frame fix on the phone would
do. The matcher's name accuracy on each is in `testStillPhotos` / `stillPhotos` (modes `dim`, `dimFixed`).

| Read of the 97 old-frame photos | Named | Wrong card | Printing |
| --- | --- | --- | --- |
| `accurate` (plain photo) | 64/97 (66%) | 0 | 32/46 |
| `multi` (as the scanners read) | 69/97 (71%) | 0 | 36/49 |
| `dim` | 64/97 (66%) | 0 | 35/47 |
| `dimFixed` (contrast stretched back before OCR) | 56/97 (58%) | **2** (Volcanic Island it → Island, Northern Paladin ja → Into the North) | 29/41 |

Vision reads the dim copy as well as the plain photo: lower contrast costs no names. Stretching the contrast back
before OCR reads fewer (the stretch clips the frame's texture into the letters and sharpens noise) and names two
wrong cards, so the scanners don't do it; a per-frame contrast fix on the phone would cost a Core Image render and
help nothing. The old-frame names the set still loses (33 of 97) are the same ones in every read: titles too small
or soft in the photo for any contrast ("D vamp", Cyclopean Tomb), and the 20 px Japanese titles the title-bar pass
also couldn't read. The thing that would help old names is pixels, not processing: a 1080p phone frame of a card
filling the guide has a title about 60 px tall, three times these photos', which is why real phone reports
(`reports/`) are the measure that counts. The test floor: `dim` names no wrong card and within 8 of `accurate`.


## Art matching spike (2026-10-16; measured, not in the scanners)

Could a card be named by how it looks rather than by its text? Mac-side, on the 291 photos: the card found and
deskewed as in the title bar pass (no rectangle: the whole photo), then embedded and looked up among Scryfall images.
Nothing per frame touches the network: the reference images were downloaded once (Scryfall's `unique_artwork` and
`default_cards` bulk files, then `art_crop` and `border_crop` images from cards.scryfall.io at ≤ 15/s) into
`~/Library/Caches/table1-art-spike`, outside the repo.

- `tools/art_refs.py` lists the references: one per illustration (49,742 scannable arts, both faces of double-faced
  cards; no tokens, art series, emblems), the 806 arts the photos show first, then the rest shuffled, so the first N
  are "the test set plus distractors". Whole cards: the 258 printings the photos show, then one printing per art.
- `tools/art_fetch.swift arts|cards` downloads them (384 px), `tools/art_match.swift [picks.tsv]` embeds and
  measures. `picks.tsv` is the app's CardMatcher run on `multi` (CardMatcher, CatalogPack, SQLite and the model
  part of Catalog.swift compiled on the Mac with a three-line driver): 253/291 right, 0 wrong.

Methods: Apple Vision's `VNGenerateImageFeaturePrintRequest` (768 floats, built into iOS, nothing to ship), cosine
nearest neighbour; dHash and DCT pHash (64 bits, Hamming). Crops: `art modern` (the 2003+ art box), `art boxes`
(modern and 1993/97 boxes, each also turned 180°, best of four), `+rect` (also the detected rectangle itself as the art:
the detector often finds the art box, which is card-shaped too), `whole card` (the deskewed card, and turned).

Right card at top-1 (top-5), all 291 photos, as distractors are added:

| References | art modern | **art boxes** | art boxes+rect | +rect int8 | pHash | dHash | whole card |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 806 (test arts only) | 84% | 84% (93%) | 81% | 85% | 71% | 50% | 58% |
| 5,000 | 79% | 79% (86%) | 77% | 79% | 70% | 42% | 52% |
| 20,000 | 75% | 77% (82%) | 73% | 75% | 67% | 35% | 48% |
| 49,742 (all) | 74% | **77% (82%)**, 225/291 | 73% | 73% | 64% | 32% | 46% |

Text, for comparison: 253/291 (87%), 0 wrong. Accuracy levels off after ~20k references.

- Art is language-blind: at 49,742 references, cards in other languages 120/143, English 105/148. Old frames are
  nearly perfect (1993 58/61, 1997 32/36, white border 25/25); it fails on foil (75/119), borderless (20/32,
  the fixed art box is wrong there), modern frames (2020 frame 68/104) and when no rectangle is found (31/47).
  Many misses are a wrong crop: the rectangle is the art box or the text box, not the card.
- Whole card is worse everywhere except English: 21/143 other languages (the text differs from Scryfall's English
  image), 26/61 1993 frames. Frames and text boxes look alike across thousands of cards and drown the art. It reads
  the printing on 108/247. Art and whole card together: either is right on 251, the clearer margin wins 228; worse
  than art alone, so whole card adds nothing.
- Mean-centering the index (against hub arts that are everyone's nearest neighbour) made it worse (69%); int8 costs
  nothing.
- A wrong answer is always possible: forced to answer, art boxes is wrong on 66 photos. Answering only when the best
  card leads the next by more than 0.070 (just above every wrong answer here, so fitted on this set): 145 answers, 0
  wrong.

As a fallback, where text names nothing (38 photos): art top-1 is right on 32: ko 9/9, zht 8/8, ja 5/8, en 5/7,
de 3/4, fr, pt. With the 0.070 margin, 23 of them, 0 wrong: names 253 → 276/291 (95%).

As a confirmation of the text matcher's pick (253 right picks; 581 wrong claims: a random card, and Opt, per photo):

| Rule (49,742 arts) | Right picks kept | Wrong claims let through |
| --- | --- | --- |
| Claimed card is art's top-1 | 193/253 | 0/581 |
| Claimed card in art's top 5 | 206/253 | 0/581 |
| Claimed card in art's top 20 | 212/253 | 1/581 |
| Claimed card scores ≥ 0.478 (keeps 95%) | 241/253 | 328/581 |

A score threshold alone separates nothing (scores of unrelated arts are high); rank does. Synthetic negatives: a
keyboard with "option" keys finds no card-shaped rectangle; with the whole frame as the card, Opt ranks 4,904th. A
list of card names on a dark screen ("4 Opt", "4 Lightning Bolt"…) finds a rectangle; Opt ranks 4,690th, Lightning
Bolt 629th. Both are rejected by the top-5 rule.

Time on Apple silicon (Mac, median per frame): find and deskew 6.7 ms (the gate already does this), crops 11 ms (8
crops; 4 for art boxes), feature print 5.0 ms per crop, search of 49,742 arts 1.9 ms per crop (float32, brute force):
about 40 ms for art boxes, so not every frame. Index: 49,742 × 768 = 152 MB float32, **38 MB int8**; every printing
(109,573) would be 84 MB int8; a pHash per art is 397 kB but too weak.

**Recommendation: don't ship it as the primary matcher; worth building as a fallback, and as an alternative way
through the gate, not as a required confirmation.**
- Primary: no. 77% and wrong answers where text gets 87% with none; text also reads the printing.
- Fallback for frames text can't name: yes, the one clear gain, mostly Chinese, Japanese and Korean cards with no
  printed name in the pack (22 of 25 CJK misses named at top-1), run only after text has found nothing for a while,
  and answering only with a clear margin.
- Confirmation: top-5 let no wrong claim through and rejects the keyboard and the list of names, but as a hard
  requirement it would drop 47 of 253 right picks. Use it as one more way to pass the gate (a frame with no type line
  and no rectangle-bounded text, whose text pick is in art's top 5), not as a new requirement.
- Before building: (1) Android has no Vision feature print, so it needs its own model and its own index (e.g. a
  small MobileNet-class embedding in TFLite), which is the larger half of the work; the iOS index must be built with
  the same feature print revision the phone runs. (2) The margin was fitted on these photos; check it on held-out and
  real phone frames (`reports/`). (3) 38 MB is a separate optional download next to the catalog pack. (4) Fix the
  art box for borderless/showcase frames and try the second-largest rectangle when the largest is the art box: most
  remaining misses are crops, not embeddings.
