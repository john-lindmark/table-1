# Re-pair a round (2026-11-09)

John: "does the app have the ability to re-pair if the results of a match were incorrectly submitted? if not, build it".

Before this, an organizer could correct any result with `set_match_result` (standings and records follow), but during
a live event only the current round's matches could be opened, and a round already paired from the wrong standings
stayed paired. Now: earlier rounds are open from Live, and the current round can be paired again.

## Rules (server)
- Only the **latest** round, only while it is **active**, only while the event is running (not completed, archived or
  cancelled). Organizers only (`event_members`).
- **Results already in** (not byes, status reported or confirmed) are cleared only when the organizer says so
  (`clear_results: true`); otherwise 409 `{error: "Round 3 has 2 results in. Clear them to re-pair.", code: "has_results"}`.
- **Unresolved disputes in earlier rounds block it** ("Resolve the disputed results first"), like pairing the next round.
- The engine works out the new pairings **first**, as if the round had never been paired (same rules as `pair_round`:
  Swiss, draft across the table, team, round robin, top 8 from the corrected Swiss standings). Only if that succeeds
  does it call `withdraw_round` as the organizer, which in one transaction deletes the round's life trackers, matches
  (sides and outcomes cascade; lifetime records reverse through `matches_records_sync`) and the round, sets
  `events.current_round` back one, and writes `round.withdrawn` to `audit_log` (before = the old tables, sides, scores
  and statuses; after = how many results were cleared; reason when given). Then it pairs the round again exactly like
  `pair_round`: a fresh clock, `round.paired` audited with `repaired: true`, and the `round.paired` push with
  `repaired: true` ("Round 3 re-paired · Table 4 vs Ana"), which replaces the earlier push (same collapse tag).
- Round robin and team draft pair from the roster, so a re-pair gives the same tables; it is allowed anyway.

### Wire
- events-engine `POST {action: "repair_round", event_id, round_id, clear_results?, reason?}` (organizer's JWT) →
  the `pair_round` answer plus `repaired: true`. 403 not an organizer, 409 refusals as above.
- `public.withdraw_round(p_round_id uuid, p_clear_results boolean default false, p_reason text default null)` →
  `{event_id, round_number, stage, cleared_results}`. Security definer, authenticated only. Errors: 42501 signed out /
  not an organizer, P0002 unknown round, 22023 not the latest / already recorded / event not running / earlier
  dispute, PT409 results in without clearing. Clients don't call it directly (the engine does, so nothing is taken
  back unless the new pairings can be made).
- Migration `20261109120000_withdraw_round.sql`; tests `supabase/tests/60b_withdraw_round_test.sql`.

## Clients (iOS, web, Android)
- **Live → Earlier** tab (after Round, only once a round other than the current one exists): every earlier round,
  newest first, each match tappable to open the set-result panel (as Results → Rounds). Note at the end: "Tap a match
  to correct its result. If that changes who should have played whom, re-pair round 3." (no active round: the Results
  note). Web labels the tab Earlier during Live only.
- **Notice** at the top of the Round tab when an organizer correction landed in an earlier round after the current
  round's pairings went out (`match.result_source = organizer` and `match.updated_at > round.pairings_published_at`):
  "A round 2 result changed after round 3 was paired." (several: "Results in rounds 1 and 2 changed after …"),
  with a `Re-pair round 3` button under it. Old rounds without `pairings_published_at` never prompt.
- **Re-pair round N** also in the More menu (web: in the bar) whenever the current round may be re-paired. Playoff
  rounds read "Re-pair the quarterfinals" / "the semifinals" / "the final".
- **Confirm**: title "Re-pair round 3?", message "New pairings from the standings as they are now. Players get their
  new tables and the clock starts again." plus, when results are in, " The 2 results already in for round 3 are
  cleared." Buttons `Not yet` / `Re-pair` (destructive when results are cleared). Confirming sends `clear_results`
  = results > 0 and returns to the Round tab.
- Rules shared through `testdata/repair-round/cases.json` (prompt, confirm, labels): iOS `RepairRound` /
  `RepairRoundTests`, web `lib/repairRound.ts` / `repairRound.test.ts`, Android `RepairRound` / `RepairRoundTest`.
- Telemetry `round_repaired` {round, stage, cleared, from: notice | menu}.
- Demos: web `/dev/events?screen=live&repair`, iOS `-T1EventsDemo live -T1Repair [-T1Tab rounds]`.
