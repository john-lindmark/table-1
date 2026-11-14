# Teams with captains, Team Trios, top 4, a season's final, new-event alerts (2026-11-13)

Phase 2 of `table-1-context/docs/plan-public-events-leagues-2026-11-13.md`. Server: migration
`20261113140000_teams_finals_alerts.sql`, events-engine (top 4, team playoffs, `team_trios`), notify-worker
(`event.public_new`). Tests `supabase/tests/73c_teams_finals_alerts_test.sql`, engine tests in
`supabase/functions/events-engine/`. Shared client cases: `testdata/leagues/cases.json` (wording) and
`testdata/scheduled-events/cases.json` (the organizer's next step, regenerated with top 4).

## 1. Team Trios and the top 4 cut

- **Team Trios** (`format_name` `team_trios`): a constructed team event, always three players a team, each seat
  (A, B, C) playing its own format: `events.seat_formats` = three of `standard` `pioneer` `modern` `legacy` `vintage`
  `pauper` `premodern` `canadian_highlander` `duel_commander` `other` (default Modern / Standard / Pioneer). Paired
  team against team, seat against seat, like team sealed. `format_label` "Team Trios", format key `other`.
  `create_event_v2` and `update_event_details` take `team_trios` (team size is always 3 whatever is sent);
  `set_event_trios(p_event_id, p_seat_formats text[3]) → {seat_formats}` before round 1 (organizers; 22023 for a bad
  list, 55000 once round 1 is paired). `event_about` returns `seat_formats`.
- **Top cut** `events.top_cut` is 0, 4 or 8. Top 8: Swiss events of players. Top 4: those, and team sealed and Team
  Trios (never a team draft, a roto or round robin). The engine pairs semifinals 1 v 4 and 2 v 3, then the final;
  team playoffs are team against team (seat against seat; a 2–2 split in teams of four goes to the higher seed). A
  cut needs 5+ players (teams) for top 4 and 9+ for top 8, else the event finishes after Swiss. The standings action
  gains `team_bracket` and a `playoff` field on team rows.

Clients:
- Create and Setup → Details: **Team Trios** in the format picker (with the constructed formats), then a **Seats** row
  of three cells `A · MODERN` `B · STANDARD` `C · PIONEER`, each a format dropdown; sent with `set_event_trios` after
  create and on change. Top cut choices come from `cut_choices` (by format).
- Team lists, pairings and the player's own match show the seat and its format (`seat_label`: `A · MODERN`).
- The organizer's next step and the bracket follow the engine (`next` cases; team events draw `team_bracket`).

## 2. Teams sign themselves up

`events.team_signup` (default off: the organizer builds the teams, as before). `event_teams` gains `captain_id` and
`join_code` (8 characters). Capacity counts every signed-up team whole, so a team's seats are held for its members.

- `team_signup_set(p_event_id, p_on) → {team_signup}`: organizers, team events, before round 1.
- `team_mine(p_event_id, p_token?) → {team_signup, team_size, seat_formats, team, captain, can_create, teams}` for
  anyone who can open the event (signed out too). `team` (yours, or null): `{id, name, captain_id, join_code,
  members [{participant_id, user_id, name, slot}], complete}`. `teams`: every team as `{id, name, members (count),
  complete}`; organizers get each team in full with its code.
- `team_create(p_event_id, p_name) → team_mine`: signs you up, makes the team, you are captain in seat A. 22023 when
  the organizer builds the teams or you're on a team; 23505 for a name in use; 55000 when sign-up is closed or the
  event is full.
- `team_join(p_event_id, p_code) → team_mine`: signs you up into the team's next free seat. P0002 for a wrong code,
  22023 when the team is full or you're on a team.
- `team_update(p_team_id, p_patch) → team_mine`: the captain or an organizer, before round 1. Keys: `name`; `order`
  (every member's participant id once, seat A first); `captain` (a member's user id); `remove` (a member's
  participant id: they leave the event; the captain can't remove themself).
- Leaving is `event_leave` as for any event: the captaincy passes to the first member left, and an empty team closes.

Clients:
- Setup → Teams (team events): a **Teams sign up** switch; with it on, each team shows its code and `2/3`.
- The event page for a team event with sign-up on, when you're on no team: **Sign up a team** (asks its name) and
  **Join a team** (a code field with Paste; `/s/<event>?team=<CODE>` arrives with the code filled in). Full:
  "The event is full".
- On a team: a **Your team** block: the name, members by seat with seat labels, `2/3`, and a code row with Copy and
  Share (the link above). The captain's row menu on a member: Move up / Move down, Make captain, Remove; and
  Rename team. Everyone: Leave team (a confirm; the captain's says who takes over).
- Everyone sees **Teams**: each name with `2/3` or `COMPLETE` (`team_line`).
- Telemetry `team_created`, `team_joined {how: code|link}`, `team_updated {what}`, `team_signup_set {on}`.

## 3. A season's final

- `league_final_status(p_event_id) → {season_id, qualified [row], next [row]}` for someone who runs both the event
  and its league, when the event is the season's final (42501 otherwise). A row: `{key, user_id, name, rank, points,
  how, state}`; `how` is `winner` | `points` | null; `state` is `in` (signed up), `invited`, `declined`, `guest` (no
  account: add them by hand) or `none`. `next`: the next eight on points.
- `league_final_invite(p_event_id, p_keys text[]?) → {ok, invited}`: with no keys, everyone qualified who has an
  account and isn't in or invited; with keys, those players (passing an invitation down). Invitations are ordinary
  event invitations (`event.invite` push; an invitation-only final takes sign-ups from the invited only).

Clients: on a final you organize, Setup → Players gains a **Qualified** row (`3 of 23 in`) opening the list:
Qualified (name, `WINNER` / `POINTS`, state on the right: `IN` in accent, `INVITED`, `DECLINED`, `GUEST`, or an
Invite button) with **Invite the qualified** as the big action, then Next in line with Invite per row.
Telemetry `final_invited {count, passed_down}`.

## 4. Alerts for new public events

One alert setting per account: on/off, formats (format keys; none = all), an optional rough home area you choose
(kept rounded to 0.1°, about 10 km; never read without your pick) and a distance. Ten minutes after an event becomes
public, accounts whose alert fits get `event.public_new` ("New Modern event near you" / "Modern Open · MeH Games"),
once per event, never for an event you run or are in, never across a block, at most five a week.

- `event_alerts_get() → {on, formats, km, lat, lng}` (lat/lng null with no area).
- `event_alerts_set(p_patch) → the same`. Keys: `on`; `formats`; `km` (null = anywhere; 5–500 needs an area); `lat` +
  `lng` (your area); `place: null` forgets the area. 22023 for an unknown format or a distance without an area.

Clients: Find → Events ends with an **Alerts** row (`alert_line`: `OFF`, or `MODERN, LIMITED · 50 KM`) opening
Alerts: an On switch, Formats (several), Area (Use where I am now, asked only on that tap; Forget area), Distance
(Anywhere | 25 | 50 | 100 | 250 km; a distance without an area asks for the area first), and the line "Up to five a
week." The push opens the event. Telemetry `event_alerts_saved {on, formats, km}`.
