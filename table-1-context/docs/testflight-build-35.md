Table 1 0.1.0 (35) — What to Test

New since build 34:

CARD SCANNER: THE RIGHT PRINTING
- Retro-frame reprints (MH2's fetchlands, Ravnica Remastered's retro shocklands) now go in as that printing, not the original. The scanner reads the "Illus." credit as an old or retro frame and knows every printing's artist and frame.
- Borderless and showcase variants: the artist's name tells them apart ("MH2 • EN · Zezhou Chen" is the borderless Tourach), and a set code read in one frame plus the number in a later one count together.
- The number at the end of a copyright line ("© 2024 Wizards of the Coast 407") counts, more set-code spellings read, and a lone number counts on lands and spells.
- The camera also reads the card's bottom strip on its own (straightened and enlarged) and reads text only around the outline.
- A card is taken at 0.2 s when two frames agree on the exact printing (was 0.4 s).
- Please check: scan the retro MH2 fetchlands, a few borderless cards, and a stack of ordinary modern cards; note anything that still says "Check printing" or lands on the wrong set. Changing a row's printing still sends a report that becomes a test case.
- The app rebuilds its card file once on first open. The card file with artists and frames is published; the app downloads it on its next check, and until then the scanner behaves as in build 34.

BUY ON TCGPLAYER
- A want for a specific printing now opens that printing's TCGplayer product page instead of a Mass Entry line (Mass Entry kept failing on exact printings). Wants for "any printing" still go to Mass Entry by name. With more than one link, a menu lists them.
- The server side is live. Product ids arrive with the night's card update (29 Oct), so a wanted printing goes to Mass Entry by name until then; after that it opens the product page.

INSIGHTS
- Matchup grid: the square you tap is outlined and its row and column names light up.

Send anything odd through TestFlight feedback (screenshot + shake).
