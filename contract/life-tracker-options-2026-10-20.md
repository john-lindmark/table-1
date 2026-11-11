# Life tracker: Reset, Options, chooser, dice (2026-10-20)

Client-only. No server change. Figma: tracker `73:5420` (strip), Options panel `231:9191`.

## Strip

The bottom row of the info strip is **Record | Options | Reset** (was Close | Record | History).
Options stays centred. Watching (organizer, read-only) shows Options only.

## Reset

Reset always asks first (native alert, the one platform-native piece).

- Life goes back to starting life and every counter to 0 for the current game. Synced matches do it the
  usual way: one inverse op per change group, so both phones agree and history nets to 0.
- Local session with recorded games: the alert offers **Reset game** (as above, games stay) and
  **Reset match** (games cleared too, 0–0; names, starting life and counter columns stay).
- Synced match: recorded games are the event's record and stay; the alert says so.

## Options (231:9191)

A panel rising from the bottom over a scrim: **Chooser**, **Roll dice**, **History**, **Leave tracker**.
Each row closes the panel, then opens its tool. History is the existing history panel (Undo last, Reset game,
Starting life, New match, Report now). Leave tracker closes the tracker (what Close did).

## Chooser

Covers the screen. Everyone puts a finger down. Once two or more fingers have stayed down with no finger
landing or lifting for **2 s**, one is picked at random (uniform). Moving a finger doesn't restart the wait.
While waiting each finger shows a ring that closes over the 2 s; the pick fills in accent (the result), the
others turn grey. Fingers that land after the pick are ignored. **1.5 s after the pick the tracker comes
back on its own** (2026-11-04, John: on Android there was no way back after a pick but the back gesture);
Done closes it sooner. Swipe-back is off on this screen (it would fight the fingers). On Android the chooser
is a full-screen dialog drawn edge to edge (`FullScreenDialog`, like the app's other full-screen screens),
with Done padded for the system bars; it was a popup. Why John saw no Done in the popup isn't known: his
phone uses gesture navigation, so it wasn't a navigation bar covering it.

## Roll dice

A panel: die (D4 D6 D8 D10 D12 D20), how many (1–10), Roll. The total shows large in accent; the caption
says what was rolled and each die ("2D6 · 4 + 5"). Tapping the total rolls again. The die and count are
remembered on this device.

## Taps and the pull band (2026-11-11)

John: "there are many times when a user taps it intending to increment or decrement and the number doesn't
change … make it the case that the swipe down for drawer can only be started from the top of the counter box".
What the server's tracker log showed (1,757 synced taps, Oct 13 – Nov 11): 25 taps taken back within 80 ms
of landing, the ones that had already been sent when the finger drifted past 10 pt (a drift before the first
send, 0.3 s, left no trace, so the true count is higher); telemetry had no per-tap events. Two rules lost taps:
a finger that travelled more than 10 pt cancelled the tap (iOS took back the change it made on touch-down;
Android and web never sent it), and a 24 pt drift toward the player anywhere on the half opened the picker.

Now (`TrackerTouch` iOS / `TrackerTouch` Android / `trackerTable.ts` web, cases
`testdata/tracker-touch/cases.json` from `make_cases.py`; tests `TrackerTouchTests`, `TrackerTouchTest`,
`trackerTouch.test.ts`):

- A touch on a +1 / −1 zone always counts, however far it drifts. iOS still fires on touch-down; Android and
  web on release.
- Only a touch that **starts in the pull band**, the 44 pt / dp / px strip along the player's far edge (their
  "top", by the strip; the top of every +1 zone), and travels 24 toward the player (and 1.5× more toward them
  than across) opens the counter picker. That one touch's tap doesn't count (iOS takes it back).
- A finger that rolls more than 24 before the hold delay is a sloppy tap, not a hold: no repeat.
- A second finger on the same zone is its own tap (Android and web; iOS SwiftUI zones track one touch).
- iOS counts the tap in the drag's `onChanged` / `onEnded` rather than watching a gesture-state change, so a
  very short tap can't fall between two redraws.

Telemetry: `tracker_touches {taps, moved, pulls, holds, band_taps, players, mode}` when the tracker closes or
goes to the background (`moved` = taps that travelled past the old 10 pt and used to be lost).

## Logic and tests

Pure, with an injectable random source: `TrackerTools.swift` (`Dice`, `Chooser`), `trackerTools.ts`,
`TrackerTools.kt` (return delay `Chooser.returnAfter` / `CHOOSER_RETURN_MS` / `Chooser.RETURN_MS`). Same cases on each: `TrackerToolsTests` (iOS, also Reset game vs Reset match on a local
model), `trackerTools.test.ts`, `TrackerToolsTest`.

Telemetry: `tracker_dice_rolled {sides, count}`, `tracker_chooser_opened`, `tracker_chooser_picked {fingers}`,
`tracker_reset {scope: game|match, mode: local|match}`.
