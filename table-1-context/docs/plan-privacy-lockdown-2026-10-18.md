# Privacy lockdown: events, profiles, records (plan, 2026-10-18)

**Status (2026-10-18):** John chose the recommended answer to all four decisions below. Step 1 is built and green locally,
**not applied to live, engine not deployed**: migration `20261018170000_privacy_lockdown.sql`, events-engine
`standings` guard, tests `90_privacy_lockdown_test.sql` + `perf_20_event_reads.sql`, contract
`contract/privacy-lockdown-2026-10-18.md`. Changed from this plan while building: `event_preview` returns
`{access: 'none'}` and `join_event` returns `{error, message}` instead of raising (an error would roll back the miss
counter); `event_public` also carries the current pairings by name, because `/s` shows them. Steps 2–3 to do.

Follows the friends/sharing review of 2026-10-18. The sharing RPCs (`profile_view`, `profile_cards`, `trade_matches`)
enforce visibility properly. But the older tables they sit beside can still be read by anyone holding the publishable key,
**including signed-out callers**. That makes the Record setting meaningless and lets anyone list every account and event.
Server-side leaks with no product decision (email lookup, repeat requests after a decline, blocks in invites,
`value_usd`) are being fixed in a separate session and are not part of this plan.

## What's open today (live, checked 2026-10-18)

| Table | Policy | Who can read | Exposes |
|---|---|---|---|
| `profiles` | `profiles_read` `using (true)` | anon + authenticated | every account: name, handle, avatar path, `is_demo`, `deleted_at` |
| `events` | `events_public_read` `true` | everyone | every event incl. `visibility = 'private'`: venue, start time, organizer, cube |
| `participants`, `pods`, `event_teams` | `*_public_read` `true` | everyone | who is attending which event (with `user_id`) |
| `rounds`, `matches`, `match_sides` | `*_public_read` `true` | everyone | every pairing and result |
| `player_records`, `head_to_head`, `match_outcomes` | `true` | anon + authenticated | everyone's lifetime record and head-to-head, **whatever their Record setting** |
| `event_results`, `standings_snapshots` | `true` | anon + authenticated | final standings of every event |

Related gaps:
- `events-engine` `standings` action reads with the service role and checks nobody (`index.ts:127`).
- `get_event_teams` can be called signed out and checks nothing.
- `join_event(p_code)` can be called signed out, ignores `visibility` (so private events can be joined by code), and codes are
  4 characters long. Anyone can work through every code.
- Blocks only apply inside the friends RPCs (see the separate session for invites and alerts).

Fine already: `event_locations` and `presence_cells` (RLS on, no policy), `event_members`, `event_invites`, `tracker_*`
(member-only), every Library table (owner-only), the avatars bucket (public, but each path has a random part, so only
someone who already has the URL can fetch it).

It's cheap to fix now: production has 3 events, the web app isn't deployed to table-1.site yet (so no web guests exist
in production), and no client reads the record tables directly.

## Access rules (proposed)

One helper decides access for every event read: `t1_private.event_access(p_event_id, p_token text default null) → text`

| Level | Who | Sees |
|---|---|---|
| `organizer` | `is_event_organizer` | everything |
| `player` | a participant linked to the caller's account (`in_event`) | everything |
| `guest` | holds a valid `participant_tokens` token for this event (web guests, signed out) | everything |
| `invited` | a pending `event_invites` row for the caller | preview |
| `link` | knows the event id or an open event's code, and the event isn't `private` | preview + standings (decision 1) |
| `none` | everyone else, and any non-member of a `private` event | nothing ("That event isn't available", the same answer as for a missing event) |

- **Preview** = name, format label, set/cube name, status, start time, venue name, player count, organizer display name.
  No player list, no `user_id`s, no location coordinates.
- **Records** are never readable from tables. Another account's lifetime record shows only through `profile_view`,
  which already checks the Record setting. Your own comes from `account_overview`. Head-to-head stays server-only
  (used by team balancing in `teams.ts`).
- **People** (`name` + `avatar` for an id): shown when it's yourself, a friend or a pending request (either direction), someone
  you share an event with, or a public profile. Never shown when either side has blocked the other. Inside a shared event, a
  blocked person still appears by their participant name (pairings need it) but without an avatar.

## Server changes

New migration (one file, additive first; see Rollout):

1. `t1_private.event_access(...)` as above, plus SQL tests for every level.
2. `public.event_bundle(p_event_id uuid, p_token text default null) → jsonb`: `{event, participants, rounds (with matches
   and match_sides), teams, is_organizer, access}` in one call, for `organizer`/`player`/`guest`. Anon may call it
   (for guests with a token). It replaces three table reads plus an `is_event_organizer` call on every client.
3. `public.event_preview(p_code text default null, p_event_id uuid default null) → jsonb`: the preview, plus
   `{event_id, access}`. Anon may call it. Rate-limited per caller (and per IP through the `request.headers` GUC
   for anon). Codes only resolve while the event isn't completed, cancelled or archived. Private events resolve only
   for organizer, player or invited.
4. `public.event_public(p_event_id uuid) → jsonb`: what `/s/:eventId` needs (event name and status, standings rows by
   participant display name, team standings), for `link` and above. It computes standings with the same SQL the engine
   reads, or stays a thin call to the engine (see 7).
5. `public.people(p_ids uuid[]) → jsonb`: `[{user_id, display_name, handle, avatar_url}]` under the People rule, max 500
   ids. Ids outside the rule are left out. It never raises an error, so it doesn't reveal which ids exist.
6. Fix `join_event`: refuse `private` events ("Ask the organizer for an invite"), refuse a second join from the same signed-in
   account, rate-limit the code path. `join_event_qr` keeps its secret and works for private events as it does today.
7. `events-engine`: the `standings` action requires `event_access` ≥ `link` (call it through `asCaller`, passing the guest
   token in the body). Pairing actions are unchanged (organizer only).
8. `get_event_teams`: require `event_access` ≥ `guest`.
9. Realtime: statement-level `after insert/update/delete` triggers on `events`, `participants`, `rounds`, `matches`,
   `match_sides`, `event_teams` call `realtime.send('{}'::jsonb, 'changed', 'event:' || event_id, false)`. That's a
   ping with no data on a public topic named by the event's uuid. Clients refetch with `event_bundle`, so all data still
   goes through the access check. This replaces `postgres_changes` on those tables, which needs open RLS to reach guests.
   Do the same for the `rounds` clock on `tracker:<session_id>` if guests use the tracker (web `trackerSync.ts`).
10. **Tighten, after clients ship** (Rollout step 3):
    - `profiles`: drop `profiles_read`; add `profiles_own_read using (id = (select auth.uid()))`.
    - `events`, `participants`, `pods`, `event_teams`, `rounds`, `matches`, `match_sides`: drop `*_public_read`;
      add `*_member_read to authenticated using ((select t1_private.event_access(event_id)) in ('organizer','player'))`.
      Members on old builds (TestFlight build 7) keep working, `postgres_changes` included. Anon gets nothing.
    - `player_records`, `head_to_head`, `match_outcomes`, `event_results`, `standings_snapshots`: drop the read policies
      and `revoke select ... from anon, authenticated`. Server functions run as definer and are unaffected.
11. `contract/rpc.schema.json`: add `event_bundle`, `event_preview`, `event_public`, `people`, then regenerate the
    Swift, Kotlin and TS models. New contract `contract/privacy-lockdown-2026-10-18.md`.

Tests (`supabase/tests/`, `_helpers.sql`): an access matrix (organizer, player, guest token, wrong-event token,
invited, link, stranger, anon, private event) for `event_bundle`, `event_preview`, `event_public`,
`get_event_teams`. `people()` covering friend, played-with, public, stranger, both block directions. After step 10:
anon `select` on each tightened table returns 0 rows or raises an error, and a stranger reads no `match_outcomes`. `join_event` refuses private
events. Perf budget for `event_bundle` (64-player, 6-round event) in `perf_*.sql`.

## Client reads that change

### iOS (`apps/ios/Table1`)
| Where | Today | After |
|---|---|---|
| `Data/Repo.swift:116-122` `loadEvent` | `from("events")`, `from("participants")`, `from("rounds").select("*, matches(*, match_sides(*))")`, plus `rpc("is_event_organizer")` | `rpc("event_bundle")` (one call; `is_organizer` comes back in it) |
| `Data/Repo.swift:~131` `eventChanges` | `postgresChange` on matches, match_sides, rounds, participants, events | broadcast channel `event:<id>`, event `changed` |
| `UI/Avatar.swift:67` | `from("profiles").select("id, avatar_url").in("id", ids)` | `rpc("people", p_ids)` |
| `Data/Repo.swift:541`, `:588` | own profile read and update | unchanged (own row) |
| Live Activity / widgets | `live-activity` edge function | check that its `asCaller` reads go through member RLS or an RPC; probably unchanged |

### Web (`table-1-events-web/src`)
| Where | Today | After |
|---|---|---|
| `lib/api.ts:142` `fetchEventIdByCode` | `from("events").ilike("short_code")` | `rpc("event_preview", {p_code})`. `JoinRoute` / `PlayerView` show the preview before joining |
| `lib/api.ts:152` `fetchBundle` | three table reads | `rpc("event_bundle", {p_event_id, p_token})`, token from `lib/session.ts` `getLocalParticipant` |
| `lib/api.ts:177` `subscribeToEvent` | `postgres_changes` on 5 tables | broadcast `event:<id>` |
| `screens/PublicStandings.tsx` (`/s/:eventId`) | `useEvent` → full bundle | `rpc("event_public")` (standings only) |
| `lib/avatarStore.ts:32` | `from("profiles").in("id", ids)` | `rpc("people")` |
| `lib/trackerSync.ts` | `postgres_changes` on `rounds` (clock), tracker tables | tracker tables unchanged; rounds clock → broadcast if guests use the tracker |
| `lib/api.ts:484`, `:721` | own profile | unchanged |

### Android (`apps/android/app/src/main/java/site/table1/events`)
| Where | Today | After |
|---|---|---|
| `data/Repo.kt:200-222` | `from("events")`, `from("participants")`, `from("rounds")` with nested matches, `from("event_teams")` | `rpc("event_bundle")` (teams included) |
| `data/Repo.kt:244` | `postgresChangeFlow` loop over event tables | broadcast `event:<id>` |
| `data/Repo.kt:492` | `postgresChangeFlow` `rounds` update (tracker clock) | unchanged (members only on Android), or broadcast for symmetry |
| `events/ui/components/Avatar.kt:112` | `from("profiles").in("id")` | `rpc("people")` |
| `data/Repo.kt:123`, `:583` | own profile | unchanged |

Edge functions: `events-engine` (standings guard, item 7). `notify-worker`, `cards-sync` and `deck-finder` are unaffected.

## Rollout

1. **Server, additive** (safe with every build): items 1-9 and 11. Nothing existing breaks.
   Records lockdown (the third bullet of item 10) can ship here too, since no client reads those tables.
2. **Clients**, in John's order: iOS (Debug sim check with `-T1EventsDemo`, and a real event), then web, then Android.
3. **Tighten** (item 10, profiles and event tables) once the iOS build that uses `event_bundle` is on TestFlight. Build 7
   keeps working for organizers and players. Its avatars fall back to initials (the read is `try?`).
   Needs John's OK, as with every live migration.

## Decisions for John

1. **What does someone with only the link see** (non-member, event not private)? Recommend: preview + live standings
   (good for friends following along and the store TV). No pairings or player list until they join.
2. **Public standings page `/s/:eventId`**: keep it for non-private events (recommend; the event uuid can't be guessed),
   or make it an organizer switch.
3. **Short codes**: keep 4 characters, with rate limits and codes that work only while the event is open (recommend;
   people type them at the table, and the QR code has a secret), or move to 6.
4. **Blocks inside a shared event**: the organizer can still seat both people and the pairings still show names
   (recommend). Blocking can't take someone out of a tournament.
