> **UPDATED 2026-10-13:** The **Auth** decision below (Apple + Google only, email disabled) is being reversed: email sign-in is being added alongside both. The "Pending: disable email provider" item is cancelled. See README.md and plan-library-scanning-nav.md. Everything else here still stands.

# Table 1 Events V1 — decisions (updated 2026-10-06)

Supplements `table-1-events.md`. Full plan: https://claude.ai/code/artifact/6a6b62cc-9f34-4fbf-a40b-ffd2fc6edd79

- **Clients:** fully native on each platform — SwiftUI (iOS), Kotlin + Jetpack Compose (Android), existing React + Vite app (web). John wants deeper device integrations (Live Activities, App Clips, widgets, BLE proximity). Players get native apps; web stays the zero-install join and spectator surface.
- **Rules are server-authoritative:** pairings in a `pair_round` edge function, standings from a Postgres function, both ported from `standings.ts` / `pairings.ts`. Clients render and submit only. Shared JSON Schema contract generates Swift/Kotlin/TS models.
- **Auth:** Sign in with Apple + Google only; email/password disabled. Walk-in token join stays; `claim_participant` links history on sign-in.
- **Joining:** nearby (150 m default radius), QR code from the owner (`https://table-1.site/j/<code>?s=<secret>`, rotatable, any visibility), owner invite, and nearby alerts.
- **Nearby alerts:** when an event opens to nearby players, opted-in users seen in the surrounding geohash-6 block within 3 hours get a push with Join / Decline (`event_invites`). Max 1,000 per event, once per event. Presence stores only a ~1 km cell, never coordinates.
- **Results:** single entry counts immediately; opponent's same score confirms, different score disputes (first result stands); **auto-confirm at round end** (round recorded or next round created); organizer `set_match_result` any time, audited with reason.
- **Records:** `player_records` + `head_to_head` maintained by triggers via `match_outcomes`; rebuildable from results. **Head-to-head is public.**
- **Offline posture:** online-first with an offline result queue; any co-organizer can take over. Accepted.
- **Location privacy:** event point lives in `event_locations` (RLS, no policy) so public `select *` on `events` stays safe.
- **Live:** applied straight to `aaozhfcbvqrgkkrihkrd` on 2026-10-06 as migrations `events_v1_extensions` through `events_v1_l_cleanup_jobs`; rolled-back smoke test passed live. Cron jobs live: `t1-records-drift`, `t1-presence-expire`, `t1-purge-idempotency`. `delete_account()` RPC and the duplicate-index drops were run by John in the SQL Editor (verified 2026-10-06; the Supabase connector's approval prompts never surfaced in the cloud session). Source + 65-check test suite in `claude/backend/`.
- **Pending:** notify-worker edge function + its 10 s sweep; disable email provider in Auth settings to clear the leaked-password warning.
- **Open:** recommended rounds per player count (MTR Appendix E).
