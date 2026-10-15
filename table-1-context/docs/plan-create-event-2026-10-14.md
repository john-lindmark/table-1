# Plan: create-event and setup changes (2026-10-14)

**Status 2026-10-14: built.** Server, iOS, web and Android all done; client contract in
`contract/create-event-2026-10-14.md`. Not done: Figma screens for the new pieces (build-first rule: Figma follows),
and "Your Table 1 cubes" (waits for Library Cubes). Android not yet run on an emulator.

Scope: the Create event form and the organizer's Setup phase (Players / Seating / Details), on web, iOS and Android.
Order follows the project rule: server first, Figma for the new visuals, then web → iOS → Android in one batch.

## What exists today (checked 2026-10-14)

- `create_event_v2(p_name, p_format_name, p_rounds, p_round_seconds, …, p_player_names)` wraps `create_event`, which
  makes the event, an `owner` row in `event_members`, Pod 1, and one guest participant (no `user_id`) plus a claim token
  per name in `p_player_names`. **The organizer is never a participant.**
- Web create form (`table-1-events-web/src/screens/Home.tsx` ~470–585) already has a player-names textarea, a
  "Round length (minutes)" field (default 50) and an "Event name" field that follows the format until edited.
- After create, Add players is invite-only (`invite_by_email`, `invite_players`). There is no remove RPC; Live has Drop.
- `participants.user_id` is nullable, so guests-by-name are already supported by the schema.
- Sets: all 1,059 rows in `mtg_sets` have `icon_svg_uri`. Web `SetPicker` shows icons in the list; the picked set and
  both native apps show none.
- Cube: free-text `cube_name` + optional `cube_url`. There is no cubes table yet (collection core has items, batches,
  ledger, summary only).
- `events.round_length_seconds` is NOT NULL; `create_event` clamps it to ≥ 60.

## Re-seat latency: why it's slow (fixed 2026-10-14)

`events-engine` `seat_players` (`supabase/functions/events-engine/index.ts:104–158`) does, in sequence:

1. `is_event_organizer` RPC with the caller's token (1 round trip, new client per request).
2. `loadEvent`: 5 parallel queries, including all rounds with nested matches and sides (not needed to seat).
3. Clear all seats (1), then **one `update` per player, awaited in a loop** (N round trips: 8–16 for a typical draft).
4. Status update (1) and audit insert (1).
5. `loadEvent` **again** (5 queries) to build the response.

Then every client throws the response away and refetches the whole event before the button stops spinning
(web `SetupView.tsx:48–49` `refetch()`, iOS `OrganizerPhases.swift:122–129` `act`→`refresh()`, Android
`OrganizerPhases.kt:225–231` `act`→`onChanged()`). Add an edge cold start and it's roughly 20+ sequential network hops.

**Fix**
- New Postgres function `seat_event(p_event_id uuid) returns json` (security definer, organizer check inside via
  `is_event_organizer`). One transaction: shuffle with `order by random()`, split into pods of ≤ 8 (same `podSizes`
  rule), team draft alternates A1 B1 A2 B2 by `team_slot`, one bulk `update … from (values …)`, status → `seated`,
  audit row, and returns the `{event_id, pods:[{pod_id, name, seats:[…]}]}` shape clients already parse.
  Rules stay server-authoritative; they just move from the edge function into Postgres (same as standings).
- Clients call the RPC directly (no edge hop). Keep the `seat_players` engine action as a thin wrapper that calls
  `seat_event`, so `pair_round`'s "seat automatically if nobody is seated" path and old builds keep working.
- Clients render the returned pods immediately and clear the busy state; the full refresh runs in the background.
- Port the `seating.ts` unit tests to a SQL check (pod sizes for 8/10/17, team alternation, no shared seats).
- Measure before/after from edge + Postgres logs. Target: re-seat under 300 ms server time, under 1 s tap-to-render.

**Shipped 2026-10-14:** migration `20261016120000_seat_event.sql` (applied), events-engine v5 (`seat_players` and
`pair_round` auto-seat call `seat_event`), all three clients call the RPC, render its answer at once and reload in the
background; web realtime now filters by event and merges bursts; iOS realtime keeps at most one pending reload; iOS
and Android load the bundle and standings in parallel. Measured: seat_event ~8 ms in Postgres, ~120–150 ms round
trip from a Mac, versus 300–520 ms (1.4 s cold) for the old engine call followed by a blocking full reload.

## Changes

### 1. Add yourself (default on)
- Create form: a row at the top of Players, "You · <display name>", with a switch, **on by default**.
- Server: `create_event_v2` gains `p_include_me boolean default true`; when true it inserts a participant with
  `user_id = auth.uid()`, `display_name` from the profile, seat 1 (before the guests). Audited with the create.
- Setup → Players: the organizer's own row has `Remove`; when they're not playing, a `Join as a player` row appears.
  Server: `add_self_to_event(p_event_id)`, only before round 1.
- Team events too: on by default; the organizer then takes a team slot like any other player.
- The organizer view and the player view coexist for that account: the Events home live card should show "Playing ·
  Organizing" when both are true (check `events_home` returns both roles).

### 2. Remove players
- Setup only (before round 1). Live keeps Drop as today; after round 1 a player can only be dropped, never removed,
  because results and standings reference them.
- Server: `remove_participant(p_participant_id)`: organizer only, 55000 "Players can only be removed before round 1"
  once a round exists. Deletes the participant (cascades token, team slot) and revokes a pending invite for the same
  user. If the event was `seated`, the gap closes: everyone after the removed seat in
  that pod moves up one seat; the others keep their seats and the event stays `seated`. Audit row `participant.removed` with the name in `before`.
- Clients: `Remove` on each row in Setup → Players and in the create form's player list; confirm alert
  "Remove <name>?" / "They'll leave the event." (`Keep` / `Remove`). Removing someone seated says
  "Seats after theirs move up one." in the alert message.

### 3. Seating as a table
- Replace the numbered list with a drawing of the table: a rectangle (or oval for 5–7) with seats placed around it in
  order, names on the seats, team colour/letter per seat for team drafts, and pass arrows for the current pack
  (Pack 1 ← · Pack 2 → · Pack 3 ←, toggled by a segmented control). The round-1 across-the-table pairs are drawn as
  hairlines between opposite seats, accent on the signed-in player's seat and opponent.
- One table per pod; multiple pods stack vertically with the pod name as the section label.
- Accessibility: the same data stays available as a list for VoiceOver/TalkBack (the drawing is decorative-plus-labels).
- Figma first: a Seating frame for 8 seats, 6 seats, odd count (bye seat), team draft 3v3/4v4. John reviews, then
  build. (Figma MCP needs re-authorising before I can draw it.)

### 4. Add a player by name only
- Create form: replace the textarea with a list editor: text field "Add a player by name" + `Add`, each name a row
  with `Remove`. Sends `p_player_names` as today.
- Setup → Add players: alongside invite-by-email, an "Add by name" field. Server: `add_guest(p_event_id, p_name)`
  (organizer only, before round 1, 1–40 chars, unique name within the event, creates participant + claim token,
  audited). Guests show detail "Guest" and can still claim their seat later via the claim link/QR.

### 5. Round timer toggle
- Replace the minutes field/stepper with a switch "Round timer · 50 min", on by default. Rounds are always 50 minutes
  (`round_length_seconds` = 3000); the switch only decides whether clocks are shown for that event.
- Server: new column `events.show_clock boolean not null default true`; `create_event_v2` and `update_event_details`
  gain `p_show_clock` and always store 3000 s. Returned by `events_home`, the event bundle and the engine standings.
- Clients: when `show_clock` is false, hide the Live tab's big clock and Pause/+5, the player's round clock, the life
  tracker clock, and the Live Activity/widget timer (show `Round R of N`). Rounds still have their 50-minute timer
  server-side, so auto-confirm at round end is unchanged.
- Contract update: `features-2026-10-13.md` §1 (Round length) and `organizer-phases-2026-10-14.md` Details row.

### 6. Cube: recent cubes, Cube Cobra link, Table 1 cubes
- The Cube choice becomes three sources, top to bottom:
  1. **Recent cubes**: names (and link if any) from this account's last events with a cube, newest first, max 5.
     Server: `recent_cubes(p_limit int)` → `{cube_name, cube_url, last_used_at}` distinct by name/url from `events`
     where the caller is owner.
  2. **Cube Cobra link**: paste a link; the name fills in from Cube Cobra. Server-side lookup (edge function action or
     a new small `cube-lookup` function) so there's no browser CORS issue and the link is validated once; falls back
     to the last path segment if Cube Cobra doesn't answer. The name stays editable.
  3. **Your Table 1 cubes**: pick from the Library's Cubes. **Blocked**: there is no cubes table yet (Library step 3
     in Current direction). Ship 1 and 2 now, add a `cube_id` reference on events when Library Cubes lands, and hide
     this section until then.

### 7. Set icons
- Web: icon on the picked set (label row), in Setup → Details, and next to `format_label` where it's shown for set
  events.
- iOS: Scryfall icons are SVG only and SwiftUI can't render remote SVG. Add a small SVG package (e.g. SVGView via SPM)
  or convert at sync time in `sets-sync` to a PDF/PNG in a public bucket. Recommend the sync-time conversion if it
  fits the edge CPU budget; otherwise the package. Tint to the text colour.
- Android: Coil with `coil-svg` decoder, tinted.
- All clients cache icons (1,059 small files; load only visible rows).

### 8. Automatic event name
- Remove the Event name field from Create and from Setup → Details.
- Server generates the name in `create_event_v2` (and regenerates it in `update_event_details` when the config
  changes), so all three clients agree: `<format_label> · <weekday day month>`, e.g. "Modern · Tue 14 Oct",
  "Draft · Duskmourn · Fri 17 Oct", "Team draft · Vintage Cube · Sat 18 Oct". Date in the event's local date
  (creation time in the client's timezone; pass `p_tz` or the date from the client).
- `p_name` stays on the RPC signature (ignored/nullable) so older builds don't break.

## Order of work

1. **Server** (one migration + engine deploy): `seat_event`, `create_event_v2` (`p_include_me`, generated name,
   nullable round seconds), `add_self_to_event`, `remove_participant`, `add_guest`, `recent_cubes`, nullable
   `show_clock`, `update_event_details` changes, cube lookup. Update
   `contract/rpc.schema.json` and regenerate models. New contract note `contract/create-event-2026-10-14.md`.
2. **Re-seat latency** on clients (render response, background refresh). Quick, independent; can ship first.
3. **Figma**: Seating table frames, create form (You row, player list editor, timer switch, cube sources). John
   reviews.
4. **Web**: all items, then deploy.
5. **iOS + Android** together: all items, one build each.

## Decisions (John, 2026-10-14)
- Auto-name "Modern · Tue 14 Oct" style: yes.
- Round timer switch only hides the clocks for that event; rounds stay 50 minutes.
- Removing a seated player closes the gap.
- Add yourself is on by default for team events too.
