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

## Logic and tests

Pure, with an injectable random source: `TrackerTools.swift` (`Dice`, `Chooser`), `trackerTools.ts`,
`TrackerTools.kt` (return delay `Chooser.returnAfter` / `CHOOSER_RETURN_MS` / `Chooser.RETURN_MS`). Same cases on each: `TrackerToolsTests` (iOS, also Reset game vs Reset match on a local
model), `trackerTools.test.ts`, `TrackerToolsTest`.

Telemetry: `tracker_dice_rolled {sides, count}`, `tracker_chooser_opened`, `tracker_chooser_picked {fingers}`,
`tracker_reset {scope: game|match, mode: local|match}`.
