Table 1 0.1.0 (55) — What to Test

On top of build 54 (everything in 54's notes, plus):

SCANNER: SPLIT CARDS
- Scan split cards held upright: Boom // Bust, Fire // Ice, Wear // Tear, any Room. They should come in as the whole card, not one half and not nothing.
- Hold any card upside down: it should still read.

MADE PICTURES
- A deck → Share → Deck image, and a cube ranking's Top N image: long press the picture (and the zoomed view) for Copy, Save to Photos and Share.

RANKINGS
- A ranking's final now asks a few more screens so a color can't take a long run of places off one answer ("Final · checking #N"). Finished rankings ask their checks once.

TEXT FIELDS
- Tap anywhere in a text box (its label or padding, not only the text line): it focuses.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-09 at 5d05cac from a clean worktree (version 0.1.0, build 55, Release, automatic signing). 414 unit tests passed at 5d05cac. On top of build 54 (5343299): 6d47462 (long press on made pictures; web live), 19c5152 (ranking final checks; web live), 3f7a347 (dSYMs to Sentry from the archive post-action), 89e2da7 (text fields focus on a tap anywhere in their box; web live at 5d05cac), 4c44ec1 (split cards in the scanner, lines in the text's own direction). No server change needed. Not yet tried on a phone.
