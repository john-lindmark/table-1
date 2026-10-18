# Event tables are RPC-only (2026-10-17)

Fixes review finding S1 (`table-1-context/docs/review-2026-10-17.md`). Migration `20261017120000_rpc_only_event_writes.sql`.

## What changes for clients
Clients never write `events`, `event_members`, `event_teams`, `pods`, `participants`, `rounds`, `matches`, `match_sides` or `audit_log` directly. Reads are unchanged. The last two direct writes become RPCs:

| Was | Now |
|---|---|
| `rounds.update(status recorded, recorded_at)`, then `events.update(status completed)` on the last round, then (web) an `audit_log` insert | `record_round(p_event_id, p_round_id, p_final)`: one transaction, audited. `p_round_id` null only with `p_final` (finishing with no open round). |
| `participants.update(status, dropped_in_round)` | `set_participant_status(p_participant_id, p_status, p_dropped_in_round)`: audited. |

Errors to show as messages: `22023` "Resolve the disputed results first" (finishing with an open dispute; fix it with `set_match_result`), `22023` "That event is not running", `42501` not an organizer.

## Server rules
- No write policy and no INSERT/UPDATE/DELETE grant for `anon`/`authenticated` on those tables (`30_security_test.sql` enforces it). `events-engine` uses the service role and is unaffected.
- A participant can only be linked to the caller's own account from a client request, including inside definer RPCs (`participants_link_guard`). Every real path already does that: claim, join, QR, nearby, accepted invite, organizer who plays. Demo events and trusted roles (service role, cron, migrations) are exempt. So lifetime records and head-to-head only count real links.
- `match_sides.user_id` always comes from its participant.

## Rollout
Clients ship first (iOS → web → Android), then the migration. Live apps that still write directly fail with `42501` once it is applied.
