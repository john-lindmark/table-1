# Following events you're not in (2026-11-09)

John: "add the ability for users to follow events they are not in." All three clients and the server. Migration
`20261109220000_event_follows.sql`, tests `supabase/tests/64b_event_follows_test.sql`, notify-worker
`event-follow.ts` (+ test), shared cases `testdata/event-links/cases.json` (`followed`).

## Who can follow
Anyone signed in who can read the event by its link: not private, not cancelled, not demo, no block either way with
its creator, and not its organizer or a player (`t1_private.event_followable`). Invitees can. Up to 200 follows.
A finished event can't be newly followed (it can be unfollowed). Who follows is never shown to anyone.
Following re-checks at every read and push: someone who joins the event, is blocked, or loses access drops out
quietly (the row stays; it reads not following while it can't be followed).

## RPCs (authenticated)
| Call | Does |
|---|---|
| `event_follow_get(p_event_id)` | `{following, notify, can_follow}`. Signed out all false. |
| `event_follow_set(p_event_id, p_follow, p_notify = null)` | Follow (notifications on unless `p_notify` false) or unfollow; `p_notify` alone turns notifications on or off. → `{following, notify}`. 28000 signed out; 22023 "You're in this event already" (organizer, player), "That event is over" (new follow of a finished event); 42501 "That event isn't available"; 53400 past 200. Audited in `account_audit` (`event.followed`, `event.unfollowed`, `event.follow_notify`). |
| `events_followed()` | `[{event_id, name, format_label, status, current_round, number_of_rounds, top_cut, starts_at, venue_name, notify, stage}]`: running first, then upcoming by start, then finished in the last 7 days (newest first). Cancelled, archived, private-now and no-longer-followable events drop off. |

## Pushes
- `event.follow_round` when a round is paired (re-pairs too): title the event's name, body "Round 2 of 4 is up. Tap for
  the pairings and standings." ("Quarterfinals is up", "The final is up").
- `event.follow_done` when it finishes: "Final standings are up."
- `event.cancelled` (the usual copy) when it's cancelled.
- Only followers with notifications on, re-checked at send. Never for demo events. Priority 5. A tap opens the event;
  the apps swap in the event page for a non-member (contract/event-links-2026-11-09.md). Android channel Events.

## Clients
- **Event page** (iOS `EventPageView`, Android `EventPageScreen`, web `PublicStandings` and its sign-up page): a
  **Follow** row for anyone signed in who isn't its organizer or player and can follow (or already does): "Follow",
  then "Following · Each round and the final standings" (or "Notifications off") with a check. Tapping Following offers
  Turn notifications off/on and Unfollow (iOS/Android menu; web two buttons under the row). Before round 1 under the
  sign-up line; after, above Standings | Matchups.
- **Events home**: a **Following** section after Waitlist: each event's name and `followedDetail` ("Round 2 of 4 ·
  Modern", "Final standings · Modern", "Sat 8 Nov · 18:30 · The Shop · Draft · FRA"); a tap opens the event page
  (web: `/s/<id>`). An account with only follows isn't "empty".
- Telemetry: `event_followed`, `event_unfollowed`, `event_follow_notify {notify}`. No ids.
