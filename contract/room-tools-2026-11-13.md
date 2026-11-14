# Organizer tools for the room (2026-11-13)

Phase 4 of `table-1-context/docs/plan-public-events-leagues-2026-11-13.md`. Server: migration
`20261113150000_room_tools.sql`, notify-worker (`judge.call`). Tests `supabase/tests/73d_room_tools_test.sql`. The
web display itself is `contract/public-events-leagues-2026-11-13.md` § 5.

`event_room(p_event_id, p_token?)` for anyone who can open the event (signed out, and guests with their token):
`{display {show, message}, extensions [{match_id, table_number, extra_seconds}], calls, my_match}`.
`calls` (organizers; null for others): open judge calls `[{call_id, match_id, table_number, called_at, by}]`,
oldest first. `my_match` (a player in the newest round): `{match_id, table_number, extra_seconds, call_open}`.
Every change pings `event:<id>`, so read it wherever the event is re-read (on the ping, on foreground, with the 15 s
refresh).

## 1. The display remote

`event_display_set(p_event_id, p_patch {show, message}) → {show, message}` (organizers): `show` is `auto` | `clock` |
`pairings` | `standings`; `message` up to 140 characters, null or blank clears it.

- The web display follows `display.show` unless its address carries `?show=` (the address wins), and draws the
  message as a line along the bottom of every view.
- The organizer's **Display** panel (web bar; iPhone and Android: Live → More → Display): the address, the QR code,
  Copy link, then **Showing** (Auto | Clock | Pairings | Standings) and **Announcement** (a text field with the count
  `24 / 140`, Show and Clear).
- **A second screen from the phone** (iPhone, iPad, Android): when the device has an external display (AirPlay to
  an Apple TV with mirroring off, a cable, a wireless display on Android), the panel offers **Show on <screen
  name>**, which fills that screen with the display page for the event (the same web page in a web view the app
  owns; the phone keeps the organizer screen). Stop showing ends it. With no external display the panel says
  "Mirror your screen, or open the address on the TV."
- Telemetry `display_set {show, message}`, `display_second_screen {on}`.

## 2. Extra time for a table

`match_time_extend(p_match_id, p_seconds, p_reason?) → {match_id, table_number, extra_seconds}` (organizers; the
round being played; the table's total stays 0–3600; 22023 otherwise).

- Organizer, Live → Round: a match row's menu gains **Extra time** (+3 min, +5 min, +10 min, Take it back); the row
  shows `+5:00` (`extension_text`).
- The display: pairings rows show `+5:00`; the clock view lists tables with extra time under the clock.
- A player whose table has extra time sees `+5:00` beside the round clock on the event screen and in the tracker
  strip (their time runs that much past the round's).
- Telemetry `time_extended {seconds}`.

## 3. Judge calls

- `judge_call(p_match_id, p_token?) → {call_id, match_id, called_at}`: a player at that table (an account, or a
  guest with their token) in the round being played; calling while a call is open returns the same call. The
  organizers get the push `judge.call` ("Judge! Table 7" / "Modern Open · Bea").
- `judge_call_cancel(p_match_id, p_token?) → {cancelled}`: the table takes it back.
- `judge_call_resolve(p_call_id) → {call_id, resolved}`: an organizer marks it handled.

Clients:
- The player's match (event screen and the tracker's Options): **Call a judge** (a confirm); while
  `my_match.call_open`, `JUDGE CALLED` in accent with Cancel.
- Organizer, Live → Round: open calls lead the tab, each `JUDGE · TABLE 7 · BEA · 2 MIN` (`judge_line`) with Done;
  the push opens the event on Live.
- Telemetry `judge_called`, `judge_cancelled`, `judge_resolved`.

## 4. Rules level and the decklist deadline

`event_listing_set` takes `rel` (`casual` | `competitive` | null) and `decklist_due_at` (a time, null clears);
`event_about` returns both. Setup → Details: **Rules** (Not said | Casual | Competitive) and, when decklists are on,
**Decklists due** (a date and time). The About text leads with `COMPETITIVE · DECKLISTS DUE SAT 14 NOV 09:30`
(`rules_line`).

## 5. Print (web)

The organizer's bar gains **Print**: Pairings by table, Pairings A–Z, Standings, Result slips (one per match: the
round, table, both players, boxes for game wins and draws, a line to sign). A print view on light paper in the
sideboard guide's look (SF Mono, uppercase tracked labels, hairline boxes, teal only as the header line), paged for
Letter and A4. Browser only (`/e/<event>/print/<what>`). Telemetry `printed {what}`.
