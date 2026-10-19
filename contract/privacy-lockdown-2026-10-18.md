# Privacy lockdown: who can read an event, people, records (client contract, 2026-10-18)

Server: migration `20261018170000_privacy_lockdown.sql` (step 1 of `table-1-context/docs/plan-privacy-lockdown-2026-10-18.md`;
additive, every build keeps working). Tests: `supabase/tests/90_privacy_lockdown_test.sql`; budgets in
`perf_20_event_reads.sql`. Wire shapes in `rpc.schema.json` (`event_bundle`, `event_preview`, `event_public`, `people`,
`join_event`, `get_event_teams`, events-engine `standings`, realtime `event`).

## Decisions (John, 2026-10-18)

- **Someone with only the link** (not a member, event not private) sees a preview and the standings page: no player
  list or account ids until they join.
- **`/s/:eventId` stays** for non-private events: standings, the clock, current pairings by name. The event uuid can't be guessed.
- **Codes stay 4 characters.** They work only while the event is open (not completed, cancelled or archived), and
  lookups are rate-limited.
- **Blocks don't affect seating.** Blocking can't take someone out of a tournament. Inside a shared event, a blocked
  person still shows by their participant name, but `people` won't return their profile.

## Who can read an event

| Access | Who | Gets |
|---|---|---|
| `organizer` | an `event_members` row | `event_bundle`, `get_event_teams`, preview, public |
| `player` | a participant linked to your account | the same |
| `guest` | the claim token of a participant in this event (`p_token`; web guests, signed out) | the same |
| `invited` | a pending invite | preview, public |
| `link` | anyone else, if the event isn't private, cancelled or demo | preview, public |
| `none` | everyone else | nothing |

A refusal reads "That event isn't available" (42501), the same as for an event that doesn't exist.

## RPCs

| Call | Who | Does |
|---|---|---|
| `event_bundle(p_event_id, p_token?)` | anon + signed in | `{event, participants, rounds, teams, is_organizer, access}`. Rows are exactly what `select *` returns today: participants by seat; rounds by number, each with `matches` (by table) and each match with `match_sides` (by side); `teams` = `get_event_teams`. Replaces the three table reads and the `is_event_organizer` call. |
| `event_preview(p_code?, p_event_id?)` | anon + signed in | `{event_id, access, short_code, name, format_label, set_name, cube_name, status, starts_at, venue_name, capacity, players, organizer_name}`. By code: open events only. When not available: `{event_id: null, access: "none"}` (a result, not an error). |
| `event_public(p_event_id, p_token?)` | anon + signed in | Preview fields + `current_round, number_of_rounds, show_clock, format_name, team_size, round` (the active round's clock, or null) + `pairings: [{match_id, table_number, is_bye, status, game_draws, intentional_draw, sides: [{side, participant_id, display_name, game_wins}]}]`. No account ids. For `link` and above. |
| `people(p_ids)` | signed in | `[{user_id, display_name, handle, avatar_url}]` (max 500 ids) for: yourself; anyone with a friendship row with you (friends, requests either way); anyone you share an event with (player or organizer); an invite links the invited account and that event's organizers; public profiles. Never across a block, either way. Never deleted accounts; demo accounts only through a shared event. Ids outside the rule are left out quietly. Replaces `from("profiles").in("id", …)`. |
| `get_event_teams(p_event_id, p_token?)` | anon + signed in | As before, now only for organizer / player / guest (old one-argument calls still work for members). |
| `join_event(p_code, p_display_name)` | anon + signed in | As before, plus: private events need an invite (or the QR code: `join_event_qr` is unchanged); a signed-in account already in the event gets its seat back (`already_joined: true`, same `participant_id` and `token`). **Changed:** a code that doesn't lead to a joinable event returns `{error: not_found \| cancelled \| finished \| private, message}` instead of raising (an error would roll back the miss counter). The web's `joinEvent` throws `message`. |
| events-engine `standings` | as before | Body gains optional `token`. It first calls `event_public` as the caller, so it refuses whoever that refuses (404 "That event isn't available"). |

**Rate limits** (53400 "Too many tries, wait a few minutes"): code lookups (`event_preview` by code): 60 per 10 minutes
per account, 300 per address. `join_event`: 20 / 200. Misses (a code that's unknown, finished, cancelled or private to
you): 20 per account or 60 per address in 10 minutes, after which code lookups and joins stop for that caller. Lookups
by id are not limited (uuids can't be guessed). Address = first `x-forwarded-for` hop.

## Realtime

Topic `event:<event_id>`, event `changed`, payload `{}`: a ping with no data, sent once per event per statement
that writes `events`, `participants`, `rounds`, `matches`, `match_sides` or `event_teams`. Public (not a private
channel), so web guests receive it too. On receipt, debounce and refetch `event_bundle` (members, guests) or `event_public`
(the `/s` page). This replaces the Postgres Changes subscriptions, which will stop reaching non-members in step 3.
The existing `match:<id>` topic is unchanged.

## Records

`player_records`, `head_to_head`, `match_outcomes`, `event_results` and `standings_snapshots` are server-only now:
no read policy, no select grant for anon or authenticated. Another account's lifetime record shows only through
`profile_view`, which applies their Record setting. Yours comes from `account_overview` / `profile_view(self)`. Team
balancing (`teams.ts` in events-engine) reads them with the service role. No client read these tables directly.

## Client changes (step 2; not done yet)

| Platform | Change |
|---|---|
| iOS | `Repo.loadEvent` → `event_bundle`. `Repo.eventChanges` → broadcast `event:<id>`. `UI/Avatar.swift` → `people`. |
| Web | `fetchEventIdByCode` → `event_preview` (show the preview before joining). `fetchBundle` → `event_bundle` with the guest token from `lib/session.ts`. `subscribeToEvent` → broadcast. `PublicStandings` → `event_public` + engine `standings`. `avatarStore` → `people`. `joinEvent` already reads `{error, message}`. |
| Android | `Repo.kt` event loads (events, participants, rounds, event_teams) → `event_bundle`. The `postgresChangeFlow` loop → broadcast. `Avatar.kt` → `people`. |

Step 3 (needs John's OK, after the iOS build with `event_bundle` is on TestFlight): `profiles` readable only as your own
row; event tables readable by members only; signed-out callers get nothing from tables.
