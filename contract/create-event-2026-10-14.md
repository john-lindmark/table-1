# Create event and Setup changes (2026-10-14)

Server live: migrations `20261016120000_seat_event.sql`, `20261016130000_create_event_players_clock.sql`,
`20261016140000_show_clock_reads.sql`; edge functions `cube-lookup` (new), `events-engine` v5, `live-activity` v4.
Built on iOS, web and Android. Plan and decisions: `table-1-context/docs/plan-create-event-2026-10-14.md`.

## Events: new columns
`show_clock boolean` (default true), `auto_name boolean`, `name_date date`. Rounds always run 50 minutes
(`round_length_seconds` = 3000). `show_clock = false` hides every clock for that event (organizer Live clock and
Pause/+5, player clock, home card countdown, life tracker clock, Live Activity); auto-confirm at round end is unchanged.
`events_home` rows carry `show_clock`, and their `round.ends_at` / `round.remaining_seconds` are null when hidden.
`tracker_state.clock` is null when hidden. The Live Activity state omits `endsAt` / `pausedRemaining`.

## Names
Auto-named events: `<format_label> · <Dy D Mon>`, e.g. "Draft · Duskmourn: House of Horror · Fri 17 Oct". A trigger
keeps the name in step with format / set / cube changes; the date stays the creation day. Clients show the same
string as a preview on Create and never send a name (older events with typed names still edit theirs in Details).

## RPCs
- `create_event_v2(p_format_name, p_rounds, p_set_code, p_set_name, p_cube_name, p_cube_url, p_team_size,
  p_format_other, p_player_names text[], p_include_me boolean = true, p_show_clock boolean = true,
  p_local_date date)` → `{event_id, short_code}`. `p_name` and `p_round_seconds` are still accepted and ignored.
  `p_include_me` seats the organizer first (team events too). `p_player_names` are players by name only (guests with
  claim links). Send `p_local_date` = the device's date (YYYY-MM-DD).
- `update_event_details(..., p_show_clock boolean = null)`: null keeps the current value. `p_round_seconds` is
  ignored. `p_name` is ignored for auto-named events. Returns `show_clock` too.
- `add_guest(p_event_id, p_name)` → `{participant_id, display_name}`. 1–40 chars; 23505 when the name is already in
  the event.
- `add_self_to_event(p_event_id)` → `{participant_id, display_name}`. 23505 "You're already playing".
- `remove_participant(p_participant_id)` → `{event_id, participant_id}`. Before round 1 only (55000 after; then use
  Drop). In a seated draft the seats after theirs move up one; a pending invite for that account is withdrawn.
  Confirm first: "Remove <name>?" / "They'll leave the event." (+ " Seats after theirs move up one." when seated),
  buttons Keep / Remove.
- `recent_cubes(p_limit int = 5)` → `[{cube_name, cube_url, last_used_at}]`, newest first, this account's events.
- `seat_event(p_event_id)`: see `features-2026-10-13.md` §3.
- Adding a player to a seated draft leaves them unseated; Re-seat or pairing round 1 seats everyone.

Errors for the add/remove calls: 42501 not organizer, 55000 "Players can only be added or removed before round 1".

## cube-lookup (edge function, signed-in)
`POST /functions/v1/cube-lookup {url}` → `{cube_id, name, card_count, url}` where `url` is the canonical
`https://cubecobra.com/cube/overview/<id>`. Accepts any cubecobra.com cube link or a bare id. 400 "That isn't a Cube
Cobra link", 404 "Cube Cobra has no cube at that link", 502 "Cube Cobra didn't answer. Type the name instead."
Clients look up 450 ms after the link stops changing, fill the name (still editable), and store the canonical link.

## UI (built 2026-10-14; Figma follows the build)
- Create: Type → Format → Product (Set with icon / Cube: Recent cubes, Cube Cobra link, Cube name) → team size →
  Rounds stepper + "Round timer · 50 min" switch (Clocks shown / Clocks hidden) → Players: "You · <name>" switch
  (on), guests with Remove, "Add a player by name" + Add → Who can find it. Bar subtitle = the name preview.
- Setup → Players: "You're not playing · Join as a player" when the organizer isn't in it; Remove on each player before
  round 1; "Add a player by name" at the end.
- Setup → Details: name row (auto) or field (older events); Round timer switch replaces the minutes stepper; cube
  fields as on Create; set icon beside the set.
- Seating (organizer and players): each pod drawn as a table, seats clockwise from the top left
  (seat k at −90° + 360°·(k+½)/n, so seat 1 faces seat 5), hairlines between round 1 opponents (accent for yours),
  Pack 1/2/3 control with "↻ Pass left" / "↺ Pass right" in the middle, odd pod's last seat marked Bye.
- Set icons: Scryfall SVGs (`icon_svg_uri`, else `https://svgs.scryfall.io/sets/<code>.svg`), tinted to text colour.
  iOS uses SVGView, Android Coil + coil-svg, web a CSS mask.
- Design QA without signing in: iOS Debug `-T1EventsDemo [create|setup|seating]`; web dev server `/dev/events`.
