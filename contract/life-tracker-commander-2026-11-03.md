# Life tracker: table setup, 3–5 players, commander damage (2026-11-03)

Client-only. No server change. John: "expand the functionality for the life tracker to support EDH, pauper
commander, and oathbreaker. If the life tracker is being opened without an event active, the user should be
shown selectors for number of players (2,3,4,5) and then configure starting life total (20, 30, 40). after
configuration should start with the chooser. swipe for counters should include commander damage for each
opponent when starting with 30 or 40 life. incrementing commander damage should decrement lifetotal."

Shared cases: `testdata/tracker-table/cases.json`. Tests: iOS `TrackerTableTests`, web `trackerTable.test.ts`,
Android `TrackerTableTest`.

## Setup

A local tracker (opened with no match: the Events home, the life tracker shortcut, `table1://tracker`, web
`/life`) opens on **Setup** first: Players `2 3 4 5`, Starting life `20 30 40`, then **Start**. The pickers start
on the last setup used on this device (default 2 players, 20 life). Start clears the local session (games,
history and counter columns), names the players, and opens the **Chooser** over the table.

When the saved local session has history or recorded games, Setup also offers **Continue**, which opens it as it
was (no chooser). Synced matches (an event's match) never show Setup: they stay two players at the event's life.

Options gains **New match** on local sessions (opens Setup); History's "New match" opens Setup too and its
"Starting life" row is gone (Setup holds it).

## Names and seats

Two players keep **You** / **Opponent**. Three to five are **P1 … P5**. Seats go clockwise from the bottom, each
player facing their own edge of the phone (`seat`: `bottom` reads normally, `top` is turned 180°, `left` 90°
clockwise, `right` 90° counter-clockwise). Rows run top to bottom on screen; `strip` is the info strip.

| Players | Rows |
|---|---|
| 2 | `[1 top]` · strip · `[0 bottom]` |
| 3 | `[1 left, 2 right]` · strip · `[0 bottom]` |
| 4 | `[1 left, 2 right]` · strip · `[0 left, 3 right]` |
| 5 | `[2 left, 3 right]` · `[1 left, 4 right]` · strip · `[0 bottom]` |

Every seat works like a two-player half in its own orientation: the life column first (on the player's left),
then up to three counter columns; +1 on the player's top half of a column, −1 on the bottom half; swipe toward
yourself to open the counter picker from your far edge, away to close it.

## Commander damage

On when the session is local and starting life is **30 or more** (Commander 40, Pauper Commander 30; Oathbreaker
plays at 20 without it). Counter key `cmd:<side>`: damage this side has taken from that opponent's commander,
0–999. The picker lists one row per opponent first (in side order, skipping yourself), then Poison, Energy,
Experience, Rad, Speed. Labels: "Commander" / "Cmd" with two players, "Commander P3" / "Cmd P3" with more.
Picker rows and columns follow the usual rules (turned on, or non-zero unless turned off; three columns at most).

Commander damage is part of life: a side's life is starting life + its life taps − all commander damage it has
taken. So +1 commander damage takes 1 life, −1 gives it back, Undo and Reset take both back at once. Nothing
extra is stored: the op is the commander damage. History shows "P1 · Commander P3 +3 → 3"; a life group's result
counts the commander damage taken before it.

## Losing and recording

A side has lost when life ≤ 0, poison ≥ 10 or commander damage from one opponent ≥ 21 (that column turns red).
Two players: as before (the other side won). Three or more: once one player is left, Record turns accent and
is filled in with them; otherwise Record asks who won (every player, then Draw). Recording starts the next game
at full life. With three or more there's no best-of-three: no "Match over" prompt, and the score reads
"P1 1 · P2 0 · P3 2".

## Telemetry

`tracker_setup_started {players, life}`, `tracker_setup_continued`, `tracker_commander_damage {players}` (first
commander tap per game).
