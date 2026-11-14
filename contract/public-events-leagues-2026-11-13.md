# Finding events, leagues, format boards, TV display, Upcoming events widget (2026-11-13)

Phase 1 of `table-1-context/docs/plan-public-events-leagues-2026-11-13.md` (John's picks there). Server: migration
`20261113120000_public_events_leagues.sql`, events-engine `placements` action, notify-worker `league.ts`. Tests
`supabase/tests/73_public_events_leagues_test.sql`, `perf_50_leagues.sql`, `events-engine/placements.test.ts`,
`notify-worker/league.test.ts`. Shared client cases `testdata/leagues/cases.json` (reference `make_cases.py`).

Not in this phase: captains and team sign-up, Team Trios, top 4, championship invites, alerts for new public events by
format and area (phase 2); money (phase 3); display remote and native casting (phase 4).

## 1. Finding events: Public, Friends, Private

John, 2026-11-13: "events can be created with private, friends, and public visibilty. users should be able to view a
list of events visible to them in the events tab of the app. users should be able to filter public events by the same
modes as companion, format, location, etc."

**Who can find it** (`events.visibility`) is about finding an event, not opening it:

| Create says | Stored | Who finds it in the Events tab |
|---|---|---|
| **Public** | `public` | everyone on Table 1, and the web signed out |
| **Friends** | `friends` | the organizers' friends (and the organizers) |
| **Private** | `link_only` | nobody: people join by QR, code, link or invitation |

Two older choices stay in Setup → Details for events that use them: `nearby` (found only by people at the venue)
and `private` (invitation only: the link opens for nobody else). Everything that treated "not private" as link access
treats `public` and `friends` the same way (`/s/<id>`, sign-up, follows): a friends event's link opens for whoever has
it, as a Private event's does. Nearby discovery stays `nearby` only.

Events gain `description` (≤ 2,000 characters, plain text; line breaks kept; clients make `https://` links tappable)
and `venue_address` (≤ 200).

**Format key.** What an event is filtered and rated under: `standard` `pioneer` `modern` `legacy` `vintage` `pauper`
`premodern` `canadian_highlander` (the constructed format), `limited` (draft, sealed and their team forms with a set),
`cube` (cube drafts, rotos), `other` (a constructed format we don't name). Labels: Standard … Canadian Highlander,
Limited, Cube, Other. Order as written here.

### RPCs

- `event_listing_set(p_event_id, p_patch jsonb) → {description, venue_address, visibility}`. Organizers only (42501).
  Patch keys, each optional: `description`, `venue_address` (null or blank clears), `find` (`public` | `friends` |
  `private`; `private` unlists a listed event to `link_only` and leaves a `nearby` or invitation-only event as it
  is), `lat` + `lng` (the event's place, for distance). Refuses listing demo events (22023) and by restricted
  accounts (42501), text over its limit (22023). Audited `event.listing_updated`. Create calls it right after
  `create_event_v2` when the pick isn't Private or there is a description or address.
- `event_about(p_event_id, p_token?) → {event_id, description, venue_address, visibility, format_key, league, placed}`
  for anyone who can open the event (42501 otherwise; signed out too). `league` is null or
  `{id, slug, name, season_id, season, multiplier, final}`. `placed`: final places are in.
- `find_events(p_filters jsonb = {}, p_limit = 50) → [event]`, signed out too (public only). Events you can find:
  public ones, and friends ones run by a friend of yours or by you; not demo, status setup / seated / in_progress,
  soonest first; never events whose creator is in a block with you. Filters, each optional (the choices Companion's
  event search gives, less its store event types):
  - `formats`: format keys to keep
  - `lat` + `lng` (never stored): every event with a place gets `km` (whole, ≥ 1); with `km`, keeps those within it
  - `from`, `to`: when it starts (default from: 2 days ago, so running events show)
  - `q`: words in the name, venue, address or league (2+ characters)
  - `team`: true = team events, false = not; `league`: true = in a league, false = not
  - `open`: true = sign-up open with a seat left
  - `scope`: `all` | `public` | `friends`

  Each event: `{event_id, name, format_key, format_label, set_name, cube_name, team_size, status, current_round,
  starts_at, venue_name, venue_address, capacity, top_cut, visibility, players, organizer, has_description, km, league,
  me}`; `organizer` is the creator's name; `me` is `organizer`, `player`, `waitlisted` or null. 22023 for a filter
  that doesn't parse.

### Clients

- **Who can find it** in Create: **Public | Friends | Private** (Private is the default and is today's QR only).
  Setup → Details: Public | Friends | Private, then the older Nearby + QR and Invitation only below a hairline.
  Picking Public or Friends calls `event_listing_set {find}` (with `lat`/`lng` when the organizer shares the venue
  pin); Private calls `{find: "private"}`; the two older choices keep calling `set_event_location` as now, after
  `{find: "private"}` when the event was listed.
- Setup → Details gains **Description** (opens a text panel, counter `1,240 / 2,000`), **Address** and **League** (§ 3).
- The event page (players, followers, the public page): an **About** row when there is a description or address
  (second line: the address) opening the text; a league row (`<league> · <season>`) opening the league.
- **The Events tab lists what you can find.** Under your own events (live, invitations, upcoming, following) the
  Events home has **Find events**: a filter row, the first five results and **All N**. The same list, whole, is the
  Events tab of **Find** (search icon on the Events home bar; iOS `Route.find`, web `/find`, Android `find`), whose
  tabs are **Events | Leagues | Boards**.
  - Filter row (attribute-row dropdowns like Insights): **Format** (several picks; Any clears), **Where** (Everywhere
    | 25 km | 50 km | 100 km | 250 km; a distance asks for location only when picked and falls back to Everywhere
    when refused), **When** (Any time | Today | This weekend | This week | This month, in the device's zone →
    `from`/`to`), **More** (Listed: All | Public | Friends; Team events; League events; Seats left). Find has a
    search box too (`q`, 0.25 s debounce).
  - Rows: a small label above the name (the league's name when in one, else `FRIENDS` for a friends event); the
    name; a data line `SUN 29 MAR · 10:00 · MODERN · MEH GAMES · 19 KM` (date and time in the device's zone; `NOW ·
    ROUND 3` while running; `12/32` when capped); `IN` in accent when `me` is set. A tap opens the event page.
  - Picks are kept per device (`find.formats`, `find.km`, `find.when`, `find.more`). Empty: "No events match" with
    Clear filters, or "No public events yet" + Create an event when nothing is filtered.
  - Shared wording and windows: `testdata/leagues/cases.json` (`eventLine`, `whenWindow`, `filterLabels`).

## 2. Final places

`public.event_placements` keeps where each player finished once an event is `completed`: `place` (the final order
from the engine: playoffs first by how far they went, then Swiss standing; for team events every member has the team's
place), match record, `playoff`, `team_id`. Guests have rows too (no `user_id`).

A trigger asks events-engine (`{action: "placements", event_id}` with `x-t1-secret`) when an event completes, and
again when a result changes afterwards; `t1-placements-sweep` (every 5 minutes) re-asks after 2 minutes without an
answer, five tries. The engine writes through `event_placements_put` (service role), which then sends league results
and rebuilds the event's format board. Places are a copy of the standings: nothing reads them to pair or rank an event.

## 3. Leagues

A league: `name` (2–60), `slug` (from the name, unique; the page is `/league/<slug>`), `description` (≤ 2,000),
`region` (≤ 80), `link` (https, ≤ 300), members (`owner`, `organizer`; up to 20), seasons (up to 40). Three leagues an
account can own. Names and descriptions are queued for moderation review.

A season: `name` (≤ 40, unique in the league), `starts_on`, `ends_on`, `points`, `best_n` (null = every result),
`qualify`, `closed`. State: `upcoming` before `starts_on`, `over` after `ends_on` or once closed, else `active`.

**Points rule** `{"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}, {"through": 4, "points": 8},
{"through": 8, "points": 6}, {"through": 16, "points": 3}], "participation": 1, "match_win": 0}`: a finish earns the
first bracket whose `through` reaches its place, else `participation`; plus `match_win` per match won; times the
event's `multiplier` (1–5 in halves), rounded. Up to 16 brackets, rising. A season event marked `final` earns nothing.

**Qualification** `{"winners": true, "pass_down": true, "top": 10}`: with `winners`, each event (oldest first) qualifies
its best-placed player not already qualified by an earlier event, looking as far as 8th with `pass_down` (only 1st
without); everyone at that place qualifies, so a winning team goes together. Then the `top` N on points among the
rest qualify.

**Standings** are worked out on every read from the kept places of the season's completed events. A player is an
account, or a guest by name (case and spacing ignored; shown as last typed). Order: points (best `best_n` results),
then best finish, then second best, and so on (a finish beats none), then name. Equal on points and finishes share a
rank.

### RPCs

- `league_create(p_name, p_description?, p_region?, p_link?) → league` (signed in; 53400 at three leagues).
- `league_update(p_league_id, p_patch {name, description, region, link, archived}) → league` (members; `archived`
  owner only). `league_member_set(p_league_id, p_user_id, p_role | null)` (owner; a league keeps an owner).
- `league_season_set(p_league_id, p_season_id | null, p_patch {name, starts_on, ends_on, points, best_n, qualify,
  closed}) → season` (members). A new season needs name, dates and points. 22023 for a bad rule, 23505 for a name
  the league already uses. Closing sends the season push.
- `league_event_set(p_event_id, p_season_id | null, p_multiplier = 1, p_final = false) → {league}`: the caller runs
  both the event and the league (42501). Private, demo and cancelled events and closed seasons are refused (22023).
  Adding an upcoming event announces it once.
- `league_view(p_league text, p_season_id?)`, signed out too; `p_league` is the id or the slug. P0002 when unknown,
  archived or someone else's demo. Returns
  `{league {id, slug, name, description, region, link, archived, organizers [names]}, me {role, following, notify},
  seasons [{id, name, starts_on, ends_on, state}], season {id, name, starts_on, ends_on, state, points, best_n,
  qualify, closed} | null, events [{event_id, name, format_label, format_key, starts_at, venue_name, status,
  multiplier, final, players, winner}], standings [row] (first 50), standings_count, my_row | null}`. Default season:
  the active one, else the latest over, else the next. A standings row:
  `{rank, key, user_id, name, points, events, wins, best, qualified}`; `qualified` is `winner`, `points` or null;
  `user_id` is null for guests and for signed-out readers; `key` names the player for `league_player`.
- `league_standings(p_season_id, p_after = 0, p_limit = 100) → [row]`; `league_player(p_season_id, p_key) →
  {player row, events [{event_id, name, format_label, starts_at, place, players, match_wins, points, counted}]}`.
- `leagues_home(p_query?) → {mine [card + role], following [card + notify], found [card]}`; a card is
  `{id, slug, name, region, season, next_event {event_id, name, starts_at, format_label} | null}`. `found` needs a
  query of 2+ characters (name or region).
- `league_follow_set(p_league_id, p_follow, p_notify?) → {following, notify}`. Signing up for or finishing a league
  event follows the league for you once; unfollowing sticks.

### Notifications (kind → who → text)

Audience: followers with notifications on and the league's organizers, never across a block with the event's creator.
The title is `<league> · <season>`. Muted per kind in `notification_prefs.muted_kinds` and per league by `notify`.

| Kind | When | Body | Tap opens |
|---|---|---|---|
| `league.event` | an upcoming event joins a season (once per event; not to whoever added it) | `New event: Modern Open · Modern · MeH Games` (`The final is set: …` for the final) | the event |
| `league.results` | an event's places first come in | `Bea won Modern Open. Standings are updated.` | the league |
| `league.qualified` | you newly qualify (by a win, at once; on points, when the season closes) | `You qualified for the final by winning Modern Open.` / `… on points.` | the league |
| `league.season` | the season is closed | `The season is over. Bea finished first.` | the league |

Push payloads carry `league_id` and `league_slug`.

### Clients

- **Find → Leagues**: Yours, Following, then a search box (name or region). Rows: name; data line
  `2026 · DENVER, COLORADO · NEXT MODERN OPEN`. A `+` in the bar makes a league (name, region, description, link).
- **League page** (iOS `Route.league(id or slug)`, web `/league/<slug>` signed in or out, Android `league/{slug}`).
  Opens on the standings: the league's name, a season cell (a dropdown when there are several), your row in accent
  outline when you're on it, then rows `rank · name · points` with `Q` in accent for the qualified; **All N** opens
  the whole table; a row opens that player's season (events with place, points, `·` for results outside best N; the
  avatar opens their profile when they have an account). Then **Events** (upcoming soonest first, then finished
  newest first, winner on the data line; a tap opens the event). The bar: Follow / Following (a tap toggles; long
  press or the details screen has Notifications on/off), and the list icon for details: description, region, link,
  organizers, the points rule and qualification in words (`pointsWords`, `qualifyWords`).
- **Organizers** get a gear on the league page: Edit league, Seasons (add / edit: name, dates, a preset: **Places**
  (the MMS table) | **Match wins** (1 a win + 1 to play) | Custom brackets; best N; winners qualify, top N qualify;
  Close season with a confirm), Organizers (add from friends and people you've played, remove).
- **An event's League row** (Setup → Details, organizers who run a league): pick league and season, multiplier
  (`1×`, `1.5×`, `2×`, `3×`), This is the final; Remove from league.
- Telemetry: `find_opened {tab}`, `find_filtered {filter}`, `found_event_opened {format_key, visibility, km}`,
  `event_listing_saved {find, description}`, `league_opened {from}`, `league_followed {following}`, `league_created`, `league_season_saved
  {preset}`, `league_event_set {final, multiplier}`, `league_player_opened`.

## 4. Format boards

One board per format key except `other`. A rating per player per board, rebuilt from the match records (never edited
in place): start 1500; each rated match moves both players by Elo with K 40 for a player's first 10 matches on the
board and 24 after; a draw is half. **Rated**: a match between two accounts (no byes, no guests) in a completed event
that is public or in a league, has 6+ players, isn't demo and isn't a roto. Boards rebuild when an event's places come
in (so also after a corrected result) and nightly (`t1-ratings`, 04:20 UTC).

**Listed**: 10+ rated matches on the board, one in the last 365 days, not hidden, not restricted, not deleted.
Rank is by the rounded rating; equal ratings share a rank.

- `format_boards() → {listed, boards [{board, label, players, me}]}`, signed out too (`me` null, `listed` false).
  `me`: `{rating, matches, wins, losses, draws, events, rank | null, to_go}` once you have a rated match; `to_go`
  counts matches left to 10.
- `format_leaderboard(p_board, p_after = 0, p_limit = 100) → {board, label, count, me, rows [{rank, user_id, name,
  avatar_url, rating, matches, wins, losses, draws, events}]}`; `user_id` and `avatar_url` only signed in; people in
  a block with you aren't in your rows. 22023 for an unknown board.
- `leaderboards_listed_set(p_listed) → {listed}`: hide or show yourself on every board. Your matches still count for
  the people you played. Audited.

### Clients

- **Find → Boards**: every board, `MODERN` + data line `124 LISTED · YOU 1612 · #14` (`YOU 1540 · 4 TO GO` before
  you're listed; nothing about you with no rated match). A board (iOS `Route.board(key)`, web `/boards/<key>`, Android
  `board/{key}`): your rating large with rank and record when you have one, then rows `rank · name · rating` with the
  record `8-4-0` as data; a row opens the profile. Signed out on the web: names only.
- **Account → Sharing → Leaderboards**: Listed | Hidden, with "Your results in public events count either way."
- Sign-up for a public or league event says once per device: "Results in public events are public: standings, league
  points and format boards. You can hide yourself from the boards in Sharing."
- Telemetry: `board_opened {board}`, `leaderboards_listed {listed}`.

## 5. TV display (web)

`table-1.site/d/<event>`: full screen, no chrome, for a TV, projector or cast tab. Not claimed by the apps. Reads
`event_public` and the engine's `standings` (so it works signed out for public and link events, and signed in for the
organizer of a private one), reloads on the `event:<id>` broadcast and every 15 s.

Three views: **Clock** (the round clock as large as fits, `ROUND 3 OF 5`, `9/16 IN`, paused state; "Round timer off"
events show the round and results count only), **Pairings** (two lists: by table, and A–Z by player with their table
and opponent; `BYE` rows), **Standings** (rank, name, points, record, OMW%; teams for team events). Lists page every
10 s when they don't fit (rows per page from the screen's height, `displayPages`). Before round 1: the event's name,
start time and sign-up QR. After the finish: final standings.

`?show=auto|clock|pairings|standings` (default `auto`: Clock while a round runs with Pairings for the first 5 minutes
of a round and 20 s of Standings every 2 minutes after results start coming in; Standings between rounds). Keys: `1`
`2` `3` views, `A` auto, `F` full screen, arrows page. The screen is kept awake (Wake Lock) while open.

Organizer **Display** row (Live → More; web: in the bar): the address, a QR code, Copy link, Open here.
Telemetry `display_opened {show}`, `display_link {how}`.

## 6. Upcoming events widget (iPhone, Android)

The next events you can find, from `find_events` (public ones signed out; your friends' too when the widget is
signed in). Settings: **Formats** (any of the format keys; none = all) and **Where** (Near me | Everywhere). Near me uses the app's last rough place (rounded to 0.1°, kept on the
device in the App Group / prefs when location is allowed; never asked from the widget) with 100 km, and reads
Everywhere until there is one. Refreshes every 30 minutes.

- iPhone kind `site.table1.upcoming`: small (the next event: day and time large, name, format · venue), medium (3
  rows), large (6 rows). Android `UpcomingWidgetReceiver` + `UpcomingWidgetConfigActivity`, any size from 2×1.
- A row: `SUN 29 · 10:00` `Modern Open` `MODERN · MEH GAMES`; `IN` in accent when you're signed up. Empty: "No
  events" with the formats picked.
- A tap opens the event (`table1://event/<id>` → the event page); the header opens Find.
