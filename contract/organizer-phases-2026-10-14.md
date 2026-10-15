# Client spec — organizer event screen in three phases (2026-10-14)

Approved by John 2026-10-12. Figma: flow "Event — organizer · setup / live / results" (iOS 69:6396, Android 70:5604,
web "Organizer (/e/:id) · setup / live / results" 71:6202). Backend is live (migration
`supabase/migrations/20261013140000_organizer_phases.sql`). Every platform implements the same behavior.
UI rule: Table 1's own components everywhere; only alert dialogs are native (web: T1 dialog).

The organizer's event screen picks one of three views from the event's state. The phase is derived, never stored:

| Phase | When |
| --- | --- |
| **Setup** | status `setup` or `seated` and no rounds exist |
| **Live** | status `in_progress` (or any round exists and the event isn't completed/cancelled) |
| **Results** | status `completed` (or `archived`) or `cancelled` |

The view switches by itself when the state changes (realtime refresh already reloads the bundle). When the phase
changes, reset the selected tab to that phase's first tab.

---------------------------------------------------------------------------------------------------
## 1. Setup
**Bar:** title = event name; subtitle = `CODE · Setup · N players · <format_label>`.
Phones: Back + **More** (T1 menu: Add players, Show join QR, Cancel event). Web: links Events + Cancel event.

**Tabs:** `Players` | `Seating` (draft / team draft only) | `Teams` (team events only) | `Details`.

- **Players:** buttons row `Add players` (accent) · `Show join QR` (opens the existing QR view as a panel/route).
  A `Join code` row with the short code. Section `Players · N`, one row per participant (detail: Joined / Invited ·
  not joined yet / Guest — use what the bundle has; invites list if the app already loads it).
- **Seating:** what the app already shows for drafts (Seat players / Re-seat, pod seat list, pass directions,
  "Round 1 pairs across the table: 1 v 5 …").
- **Teams:** the existing Teams editor, unchanged.
- **Details** (editable; changes save on commit — field blur / stepper tap / picker choice, debounce 600 ms):
  Event name · Format (same picker as Create: Constructed list + Other with "Format name"; Limited list) ·
  Product (limited: Set picker from `draftable_sets` or Cube name + optional CubeCobra link) · Team size 3|4 (team
  formats) · Rounds stepper 1–15 · Round length stepper (10–240 min, step 5) · phones only: Who can find it
  (Nearby | Link only | Private → existing `set_event_location`/visibility call if the app has one; otherwise leave
  this row out). Footer notice: "Details lock when round 1 is paired. Changes save as you make them."
  Save = `rpc update_event_details(p_event_id, p_name, p_format_name, p_rounds, p_round_seconds, p_set_code,
  p_set_name, p_cube_name, p_cube_url, p_team_size, p_format_other)` — send the **full current state** every time.
  Returns `{event_id, name, format_name, format_label, number_of_rounds, round_length_seconds, set_code, set_name,
  cube_name, cube_url, team_size, format_other}`. Errors (show inline as an error notice): 55000 "Details lock once
  round 1 is paired", 22023 validation messages. Switching to a non-team format releases everyone from teams.

**Big action:** `Start event · pair round 1` (disabled with "Add at least 2 players" when fewer than 2 active, or the
team problem text for team events, as today) → **confirm alert**: title "Start <name>?", message
"Pairs round 1 and starts the <N>-minute clock. Format, rounds and teams lock." (drafts: "Pairs round 1 across
the table and starts …"), buttons `Not yet` (cancel) / `Start` → existing pair round 1 call.

**Cancel event:** existing alert with optional reason (title "Cancel this event?", `Keep event` / `Cancel event`).

---------------------------------------------------------------------------------------------------
## 2. Live
**Bar:** subtitle = `Round R of N · mm:ss left` (or `paused`, or `time`) `· <format_label>`. Phones: Back + More
(T1 menu: Cancel event). Web: Events + Cancel event.

**Tabs:** `Round` | `Standings` | `Players` (+ `Teams` read-only for team events, optional).

- **Round:** big clock (Big Number style) showing time left (counts down live; `0:00` when over); caption
  `Round R of N · X of Y results in · Z disputed` (paused: `Paused · Round R of N`). Under it a buttons row:
  `Pause clock` / `Resume clock` and `+5 min` →
  `rpc set_round_clock(p_round_id, p_action 'pause'|'resume'|'add', p_seconds 300)` → `{round_id, timer_status,
  remaining_seconds, duration_seconds, ends_at}`. (Use this instead of any direct `rounds` update; it keeps
  `timer_ends_at`, `timer_last_started_at`, `timer_remaining_at_change` consistent and drives Live Activity pushes.)
  Clock rule everywhere: running → ends = `timer_last_started_at + timer_remaining_at_change` (or `timer_ends_at`);
  paused → remaining = `timer_remaining_at_change`.
  Matches grouped in this order, each with a section header and count: `Disputed · n`, `Waiting · n` (no result
  yet), `Results in · n` (confirmed/reported; byes listed last as "Bye"). Row: title `T<table> · A v B`, detail
  (Disputed: "Reported 2–1 and 1–2 · tap to set" when both reports are known, else "Reported differently · tap to
  set"; Waiting: "No result yet"; Results in: Confirmed / Set by organizer / Reported by <name>), value = score or
  `Set`. Tapping any non-bye match opens the existing set-result panel (with Watch life tracker).
- **Standings:** the existing standings list (teams first for team events) with a notice
  "Live: updates as results come in. N matches still open." when N > 0.
- **Players:** section `Playing · n` (rows with value/action `Drop`) and `Dropped · n` (detail "Dropped after round R
  · still counts in tiebreakers", action `Reinstate`). Drop/Reinstate = update `participants` set
  `status` = 'dropped' | 'active', `dropped_in_round` = current round number | null (organizer RLS allows it; the web
  already has `setParticipantStatus`). Confirm Drop with an alert: "Drop <name>?" / "They won't be paired again.
  Their results so far still count." / `Keep` / `Drop`.

**Big action:** unchanged logic — `Waiting on N result(s)` (disabled) → `Pair round R+1` → on the last round
`Finish event` → **confirm alert** "Finish <name>?" / "Final standings go to every player and the event moves to
Past. You can still correct a result afterwards." / `Not yet` / `Finish`.

---------------------------------------------------------------------------------------------------
## 3. Results
**Bar:** subtitle `Final · <date> · N players · <format_label>`; cancelled: `Cancelled · <date> · after round R of N`.
No More menu / Cancel link. Back only.

**Tabs:** `Standings` | `Rounds` | `Players`.

- **Standings:** a **Winner card** at the top (surface block: small accent label `WINNER`, the name in Title style,
  caption `W-L-D · P points · games GW-GL`). Team events: label `WINNING TEAM`, team name, caption
  `W-L · P points · M match wins`, and a line with the members' names. Then section `Final standings` and the
  standings list (teams first for team events). Cancelled events: no winner card; an error notice
  "Cancelled: <reason>" (or "Cancelled by the organizer."), section `Standings after round R`, and the list, then the
  notice "Confirmed results count toward records. Unplayed rounds never do."
- **Rounds:** every round newest first: section `Round R`, rows `T<table> · A v B` with the score value (detail
  "Set by organizer" when result_source is organizer; byes as "A · Bye"). Footer notice "Tap a match to correct its
  result. Standings and records update." Tapping opens the same set-result panel (`set_match_result` works after
  the event ends).
- **Players:** everyone with their final record (detail `Dropped after round R` when dropped).

---------------------------------------------------------------------------------------------------
## 4. Copy (exact)
"Setup", "Start event · pair round 1", "Start <name>?", "Not yet", "Start", "Show join QR", "Join code",
"Details lock when round 1 is paired. Changes save as you make them.", "Pause clock", "Resume clock", "+5 min",
"Disputed", "Waiting", "Results in", "No result yet", "Set", "Drop", "Reinstate", "Keep", "Finish <name>?",
"Finish", "WINNER", "WINNING TEAM", "Final standings", "Final", "Tap a match to correct its result. Standings and
records update."
