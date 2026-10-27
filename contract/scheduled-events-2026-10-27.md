# Scheduled events, sign-up link, waitlist, top 8, automatic rounds, names (2026-10-27)

John asked (2026-10-27): schedule events in the future; a public link for an event that deep links through account
sign-up, where signed-in people sign up and that shows how many have; cut to top 8; pick the number of rounds from the
number of players; player caps; name your event again. Then (same day): decklists for constructed events, which the
organizer can require, entered as text or from the player's own Table 1 deck in that format. Picks (John, 2026-10-27): the link is the existing
`/s/<id>`; a full event has a **waitlist**; top cut is None or Top 8; rounds are Auto by default.

Server: migration `20261027120000_scheduled_events.sql`, events-engine v10 (`playoffs.ts`, copied to the web like the
other rules files). Tests: `supabase/tests/64_scheduled_events_test.sql`, Deno `events-engine/playoffs.test.ts`, shared
cases `testdata/scheduled-events/cases.json` (`make_cases.py`): rounds by players, the organizer's next step, playoff
order, round names, the sign-up line. Clients: iOS `ScheduledEventsTests`, web `scheduledEvents.test.ts`, Android
`ScheduledEventsTest`.

## 1. Names
- Create has **Event name** under the bar, placeholder = the automatic name (`<format> · <Dy D Mon>`). Left empty, the
  event is auto-named as before. Typed, it's that name (1–80 characters) and stays put when format or set change.
- Setup → Details: the name is a field on every event. Emptying it goes back to the automatic name.
- `create_event_v2(p_name)`: non-empty → `auto_name = false`, `name = p_name`. Empty/null → automatic.
- `update_event_details(p_name, p_auto_name)`: new clients send `p_auto_name` = true when the field is empty
  (automatic again) and false with the typed name (1–80 characters). Older builds send no `p_auto_name` and keep
  today's rule (an auto-named event ignores `p_name`; a named one needs one), since they echo back a name that a
  format change may already have replaced.

## 2. Scheduled events
- Create gets **When**: `Now` | `Later`. Later shows a date and time (local, 15-minute steps, from now to a year out)
  and **Where** (venue, optional, ≤ 80). `starts_at` is shown everywhere the event is; nothing starts by itself: the
  organizer still pairs round 1 (Start event works before the start time too).
- The automatic name uses the event's day: `p_local_date` = the scheduled local date (today for Now).
- Scheduled events sit in **Upcoming** on the Events home with their date: `Sat 8 Nov · 18:30 · Venue`.
- Setup → Details gets When / Where / Player cap; they save through `set_event_schedule` until round 1 is paired.

## 3. Player cap and waitlist
- Create and Details: **Player cap** switch (off = no cap) + stepper 4–512, step 1, default 8 when switched on.
  Copy under it: "Sign-ups past the cap join a waitlist."
- The cap counts active players. It limits players who sign themselves up (the share link, the 4-character code,
  QR, nearby). The organizer can always add players by name, invite, add themselves, or **Let in** someone from the
  waitlist past the cap. Lowering the cap below the players already in removes nobody.
- **Waitlist** (`event_waitlist`, RPC-only, first come first served), only for signed-in accounts:
  - the share link's Sign up on a full event puts you on it (`event_sign_up` → `waitlisted`, `position`);
  - a code join on a full event, signed in, puts you on it too and answers
    `{error: "full", waitlisted: true, position, event_id, message: "This event is full. You're number N on the waitlist."}`
    (older builds show the message); signed out (web guests): `{error: "full", message: "This event is full"}`;
  - QR and nearby joins on a full event still refuse with "That event is full" (53400), as before: the organizer is
    at the table and can add them.
- **Moving up** happens until round 1 is paired: when a player leaves (`event_leave`) or is removed, or the cap is
  raised or switched off, the first people in line are seated (one per free place) and get an `event.waitlist_in` push
  ("You're in · <event>"). Nobody moves up once round 1 is paired; the list stays readable and is shown as
  "Didn't get in".
- Organizer, Setup → Players: section `Waitlist · n` under the players, rows `#1 Name`, actions **Let in** (seats
  them now, past the cap) and **Remove**.

## 4. The sign-up link (`https://table-1.site/s/<id>`)
- One link for the event's whole life: before round 1 it's the **event page** with Sign up; once round 1 is paired
  it's the standings page as before (pairings, clock, standings), with "Sign-ups are closed".
- Organizer: **Share link** on Setup → Players (next to Show join QR) and in the More menu: the share sheet on phones
  (text "<name> · <when> · Sign up: <link>"), Copy link on the web. The web's Share panel says "Copy sign-up link"
  before round 1, "Copy standings link" after.
- Readable by `link` and above (as `event_public` already is): not private, not cancelled, not demo. Private events show
  only to their members and invitees.
- **Event page** (all clients, from `event_public`): name; facts `Sat 8 Nov · 18:30` · venue · format · `Run by X`;
  rounds line (`4 rounds · Top 8`, `Auto rounds · Top 8`); the **sign-up line** (shared cases):
  `12 players signed up` / `1 player signed up` without a cap, `12/16 players` with one, `16/16 players · 3 on the
  waitlist` when full; then the button:

  | State | Button / text |
  |---|---|
  | signed out | **Sign up** → sign in (any option makes an account; header "Signing up for <name>") → name (new email accounts) → `event_sign_up` → back on the page |
  | open, not in | **Sign up** |
  | full, not in | **Join the waitlist** |
  | in | `You're in` + **Leave** (confirm "Leave <name>?" / "Your place goes to the next person on the waitlist." when there is one) |
  | waitlisted | `You're number N on the waitlist` + **Leave the waitlist** |
  | organizer | `You're running this event` + Open event |
  | round 1 paired | the standings page; players of the event are taken to their event screen |

  The web keeps the signed-out sign-up through the sign-in round trip (`?signup=1` on the return address, like `/j/`);
  the apps hold the link in memory through sign-in, as the QR join does.
- **After round 1** the same link has two tabs (John, 2026-10-27): **Standings** (the top 8 bracket first once
  cut, then the standings in final order) and **Matchups** (every round, newest first, `Round 2 · now` for the one
  being played, then `T1 · Ana 2–1 Bo` rows; playoff rounds by name). `event_public` gains `rounds: [{number, stage,
  status, matches: [same shape as pairings]}]`, names only, no account ids.
- **Apps:** `/s/<id>` opens the in-app event page for anyone signed in (members go straight to the event, as before);
  signed out, the app signs in first with the header, then opens the page. After round 1 non-members still go to the
  web standings.

## 5. Automatic rounds
- `events.auto_rounds` (new events from new clients: true). While no round is paired, the server keeps
  `number_of_rounds` = the recommended Swiss rounds for the active players, so every build shows the right number:

  | Players | ≤ 2 | 3–4 | 5–8 | 9–16 | 17–32 | 33–64 | 65–128 | 129–226 | 227–409 | 410+ |
  |---|---|---|---|---|---|---|---|---|---|---|
  | Swiss rounds | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |

  (Enough rounds to leave one undefeated player; above 128 the MTR Appendix E bands. **Appendix E not yet confirmed
  against the document**, as in CLAUDE.md.) The top cut doesn't change the Swiss count.
- Round 1 fixes it (engine re-checks). Create / Details: Rounds row `Auto` switch; on: `Auto · 4 rounds for 12
  players` (`Auto · set when round 1 is paired` under 2 players); off: the 1–15 stepper as before.
- Auto rounds are for Swiss events only: not round robin (rotos) or team drafts (`auto_rounds` is refused there,
  22023 "Automatic rounds are for Swiss events").

## 6. Top 8
- `events.top_cut` 0 | 8. Create / Details: **Top cut** `None | Top 8` (Swiss events, not team or round robin;
  22023 otherwise). Locks at round 1 like the other details.
- After the last Swiss round, with more than 8 active players, the organizer's next step is **Cut to top 8**; with 8
  or fewer the event finishes after Swiss as usual (Details shows "Top 8 needs 9 or more players" when it would be
  skipped).
- **Seeds** are the Swiss standings of active players (a dropped player's place goes to the next one). Quarterfinals
  1v8, 4v5, 2v7, 3v6 (tables 1–4), semifinals winner(1v8) v winner(4v5) and winner(2v7) v winner(3v6), then the final.
  The higher seed is side 0 (they choose play or draw). Pairing is the same `pair_round` call; it answers `stage`.
- `rounds.stage`: `swiss` | `quarterfinal` | `semifinal` | `final`. Round numbers keep counting (Swiss 1–5, then 6, 7,
  8). Names: Swiss `Round R of N`; then `Quarterfinals`, `Semifinals`, `Final`.
- **No draws in playoff matches**: any result with equal game wins is refused, 22023 "Playoff matches need a winner"
  (report, organizer set). Clients don't offer 1-1, 0-0 or ID there. Auto-confirm at round end is unchanged.
- **Organizer's next step** (shared cases `next`): `start` (no rounds) → `waiting` (open round has matches without a
  result or disputed) → `pair` (next Swiss round) → `cut` (Cut to top 8) → `semifinals` (Pair semifinals) →
  `final` (Pair the final) → `finish` (Finish event). Copy: "Cut to top 8", "Pair semifinals", "Pair the final"; the
  confirm for the cut: "Cut to top 8?" / "Pairs the quarterfinals from the Swiss standings. Swiss is over: no more
  Swiss rounds." / `Not yet` / `Cut`.
- **Standings** (engine `standings`): `rank` is the final order once the cut is made: the winner, the finalist,
  semifinal losers, quarterfinal losers (each group in seed order; players still alive by seed), then everyone else by
  Swiss. Rows gain `swiss_rank` and `playoff` (`winner` | `final` | `semifinal` | `quarterfinal` | null, the furthest
  stage reached). Top level gains `top_cut` and `bracket`: `[{stage, matches: [{match_id, table_number, status,
  sides: [{seed, participant_id, display_name, game_wins}], winner}]}]` (seeds of the quarterfinals, then each later
  stage once paired). Tiebreakers are Swiss only.
- Clients: Live / Results → Standings shows a **Top 8** section first (Quarterfinals, Semifinals, Final rows:
  `(1) Ana 2–0 (8) Bo`, winner in the accent), then `Swiss standings`. The Winner card reads rank 1 as before.
- Lifetime records and head-to-head count playoff matches like any match.

## 9. Decklists (constructed events)
- `events.decklists`: `off` | `optional` | `required`. Create / Details (constructed formats only; limited events are
  always off, 22023 "Decklists are for constructed events"): **Decklists** `Off | Optional | Required`. Locks with the
  other details at round 1.
- **Players** (event screen before round 1, and the event page once signed up): a **Decklist** row: `Add your decklist`
  (Required: `Decklist required · add it before round 1`) or `Sent · 60 main · 15 sideboard` (+ ` · from <deck>`).
  Opens the decklist screen: **From my decks** lists the player's own decks in the event's format (`deck_format`
  cases: Canadian Highlander ↔ `canlander`, Other constructed shows every deck; Considering is left out), or **Paste
  text** (any of Arena / MTGO / Moxfield / plain text: `4 Lightning Bolt` lines, `Sideboard` header or a blank line
  before the sideboard, `SB:` lines). The screen shows the counts as you type (`decklist` cases) and Send. A deck is
  sent as its plain-text export (main, blank line, sideboard) with its id. Players change or remove theirs until
  round 1 is paired; after that "Decklists lock when round 1 is paired: ask the organizer".
- **Organizer**, Setup → Players: a line `7/8 decklists in` under the section, each player's detail gains
  `Decklist ✓` / `No decklist`; tapping a player with a list opens it (read-only text, counts, source), and the
  organizer can **Enter list** for anyone (guests too) at any time before the event ends. Live / Results → Players:
  the same rows, for deck checks.
- **Required** blocks round 1: Start event is disabled with `Waiting on N decklists` (events-engine also refuses:
  409 "N players haven't sent a decklist"). Switching to Optional in Details lets it start.
- **Who sees a list:** the player and the event's organizers. Nobody else, during or after the event (sharing lists
  after the event is a follow-up).
- Telemetry `decklist_sent {source: deck | text, by: player | organizer}`, `decklist_removed`.

| Call | Who | Does |
|---|---|---|
| `decklist_submit(p_participant_id, p_body, p_list_id = null)` | the participant's account (before round 1) or an organizer (until the event ends) | Saves or replaces the list. `p_list_id` must be the caller's own deck. → `{participant_id, main_count, side_count, list_name, submitted_at, updated_at}`. 22023 "That list has no cards", "This event doesn't take decklists", "That list is too long" (20,000 characters); 42501 not yours / not your deck; 55000 locked / event over. Audited. |
| `decklist_remove(p_participant_id)` | same | → `{participant_id, removed}`. Audited. |
| `decklist_get(p_participant_id)` | same, reading | → `{participant_id, display_name, body, main_count, side_count, list_id, list_name, submitted_at, updated_at}` or null. 42501 for anyone else. |
| `event_bundle` | | gains `decklists: [{participant_id, main_count, side_count, list_name, source: text \| deck, submitted_at}]`: all for organizers, your own for players and guests. `event` rows carry `decklists`. |
| `events_home` rows | | gain `decklists` (mode) and `my_decklist` (bool). |
| `event_preview` / `event_public` | | gain `decklists` (mode). |
| `create_event_v2(…, p_decklists = 'off')`, `update_event_details(…, p_decklists = null)` | | the mode (null keeps; switching to a limited format turns it off). |

## 7. RPCs (wire names in `rpc.schema.json`)
| Call | Who | Does |
|---|---|---|
| `create_event_v2(…, p_name, p_starts_at timestamptz = null, p_venue_name = null, p_capacity int = null, p_top_cut int = 0, p_auto_rounds boolean = false)` | signed in | As before, plus §1–6. `p_rounds` is used when `p_auto_rounds` is false. Older builds get `auto_rounds = false`, `top_cut = 0`, no cap, unscheduled. |
| `update_event_details(…, p_top_cut int = null, p_auto_rounds boolean = null, p_auto_name boolean = null)` | organizer, before round 1 | null keeps. Name rule §1. Returns `top_cut`, `auto_rounds`, `auto_name` too. |
| `set_event_schedule(p_event_id, p_starts_at, p_venue_name, p_capacity, p_local_date)` | organizer, before round 1 | Full state every call (null = unscheduled / no venue / no cap). Moves people up from the waitlist when places open. → `{event_id, starts_at, venue_name, capacity, name, players, waitlist}`. 22023 "Caps are 2 to 10000 players", "Pick a time within a year". |
| `event_sign_up(p_event_id)` | signed in | → `{event_id, status: joined \| waitlisted \| already_joined \| already_waitlisted, participant_id?, position?}`. Name from the profile (new email accounts add it first). 28000 signed out; 42501 "That event isn't available" (private without an invite, demo, unknown); 55000 "Sign-ups are closed" (round 1 paired); 22023 cancelled / finished. Rate-limited with the join limits. Audited (`participant.joined` via `link`, `waitlist.joined`). |
| `event_leave(p_event_id)` | signed in | Before round 1: leaves your seat or your waitlist place, moves the next person up. → `{event_id, status: left \| left_waitlist \| not_in}`. 55000 after round 1 (ask the organizer to drop you). Audited. |
| `waitlist_admit(p_event_id, p_user_id)` / `waitlist_remove(p_event_id, p_user_id)` | organizer, before round 1 | Let in past the cap / take off the list. Audited. |
| `event_bundle` | as before | gains `waitlist: [{user_id, display_name, position, created_at}]` (organizers; `[]` for others). `event` rows carry `top_cut`, `auto_rounds`; rounds carry `stage`. |
| `event_public` | as before | gains `rounds` (every round's matchups, newest first, §4) and `round.stage`. |
| `event_preview` / `event_public` | as before | gain `top_cut, auto_rounds, number_of_rounds, waitlist` (count), `sign_up` (`open` \| `full` \| `closed`), `me` (`organizer` \| `player` \| `waitlisted` \| null), `position` (yours on the waitlist). |
| `events_home` | signed in | rows gain `capacity, top_cut, waitlist`; round objects gain `stage`; new top-level `waitlist: [{event_id, name, format_label, starts_at, venue_name, position, players, capacity}]` (events you're waiting for, open ones only). |
| `join_event` | as before | full event → §3. |
| events-engine `pair_round` | organizer | §5–6; answers `stage`. |
| events-engine `standings` | as before | §6. |

## 8. Telemetry
`event_created` gains `{scheduled, capped, top_cut, auto_rounds, named}`; `event_signed_up {status: joined |
waitlisted, signed_in_now}`; `event_left {waitlist: bool}`; `waitlist_admitted`; `event_link_shared`;
`event_page_viewed {state}` (signed_out | open | full | in | waitlisted | organizer). Never ids or names.

## Not covered
- No reminder push before a scheduled start (follow-up). No check-in at the venue.
- Older builds: they never send the new fields; organizers on them see auto names, no schedule, and after the last
  Swiss round they offer Finish instead of the cut (pairing still works if another device cuts). Players on them see a
  playoff round as `Round 6 of 5`.
- The Live Activity and widgets don't name playoff rounds yet.
