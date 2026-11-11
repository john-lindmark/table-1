# Life tracker: Reset, Options, chooser, dice (2026-10-20)

Client-only except § After the result is in. Figma: tracker `73:5420` (strip), Options panel `231:9191`.

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

## After the result is in (2026-11-11)

John: "restrict the ability to record additional wins in the tracker if the match results have already been
submitted". A synced match's games are settled once the match has a result: reported by either player (the
tracker's Report or the event screen), confirmed, disputed, or entered by the organizer.

- Server: `tracker_record_game` refuses a new game with PT409 (HTTP 409) "The result for this match is already
  in" once `matches.status` leaves `pending` (helper `public.tracker_result_in`, closed to clients). A resend of a game already recorded with the same answer still returns the state. Clearing the result
  (Re-pair round with results cleared) puts the match back to `pending` and the tracker records again.
  `tracker_state` (and `tracker_open`, which returns it) gains `result_in` (boolean; older servers leave it out,
  read as false). Migration `20261111150000_tracker_result_lock.sql`, test `62b_tracker_result_lock_test.sql`.
- Clients: Record reads **Result in** in the disabled color and does nothing (strip and fold controls). It turns
  off when the state says so (open, every refetch: back to the app, a realtime rejoin), right after this phone
  reports, and when a Record is refused (the error shows, then the state is read again). Life, counters, Undo,
  Reset game and History keep working; Report now stays (reporting the same score confirms the opponent's).
  No `event:<id>` subscription in the tracker: the client libraries hand back the event screen's own channel for
  that topic, and closing the tracker would unsubscribe it.
- Local tables are never locked.
- Rule `canRecord` (iOS `TrackerModel.canRecord`, web `canRecord` in `tracker.ts`, Android `TrackerDoc.canRecord`);
  tests `TrackerResultTests` / `tracker.test.ts` / `TrackerResultTest`.
- Telemetry `tracker_record_refused {reason: result_in}`.

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

## Next round

(2026-11-11; John: "the player sees the old match in their tracker, even after new round has started".) A synced
tracker opens on one match and only listens to that match's taps, games and round clock, so once the next round
was paired a tracker left open, or reopened from a screen that hadn't caught up (the iOS home's saved round), kept
showing the old match. Now it follows its player:

- `tracker_next(p_match_id, p_event_id default null)` (migration `20261111130000_tracker_next.sql`, test
  `60d_tracker_next_test.sql`) answers the signed-in player of a match with `{round, match_id, bye}` for the event's
  newest later round, or null when there is none. It answers null to anyone who isn't one of the match's players
  (an organizer watching, or keeping score for guests, stays put). A match that is gone (its round was re-paired)
  is looked up by `p_event_id`: the caller's match in the event's newest round.
- The tracker asks once it has opened, every 15 s while it is on screen and the app is in front, and on returning
  to the app. It does not subscribe to `event:<id>`: every SDK hands back the same channel for the same topic, so
  the tracker closing would unsubscribe the event screen open under it.
- What it does with the answer (`TrackerNext.decide` / `decideNext`, cases `testdata/tracker-next/cases.json`):
  a different match → send anything queued, then open that match's tracker in place of this one (iOS a new tracker
  launch, web `/life/<id>` replacing the page, Android `tracker/<id>` replacing the route, so Back still returns
  where the tracker came from); a bye → "Round 3 paired | you have a bye" on the strip, the match stays; the round is
  paired but its matches aren't written yet (events-engine inserts the round first) → ask again in 2 s, up to 4
  tries; nothing newer or the same match → stay.
- Telemetry `tracker_next_round {how: open|poll|foreground, round}`.
