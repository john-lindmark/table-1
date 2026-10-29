# Testing

One command, local, no CI. Setup once: `brew install postgresql@17 postgis deno` (JDK 17 and Xcode as in SETUP.md).
The pre-commit hook is on via `git config core.hooksPath tools/githooks` (set 2026-10-16; rerun after a fresh clone).

| Command | What runs | Time |
| --- | --- | --- |
| `./test.sh` | **Fast tier.** Web `tsc` + Vitest, engine/web rules parity, Deno engine and cards-sync tests, `list-import` parser round trip, every database test file | ~5 s (+~10 s when a migration changed) |
| `./test.sh staged` | What the pre-commit hook runs: only the fast-tier parts the staged paths touch | 0–5 s |
| `./test.sh full` | Fast + iOS unit tests on the `T1-Tests` simulator + Android `testDebugUnitTest` | a few minutes |
| `./test.sh perf` | Performance budgets: Swiss events of 8–512 players, database RPC timings on a live-sized catalog, web bundle size | ~5 s |
| `./test.sh all` | full + perf | |

Each part prints PASS/FAIL, then a `timings:` block with every measured number against its budget.

## Layers

**Database** (`supabase/tests/`, `run.sh`). A local Postgres 17 + PostGIS cluster in `/var/tmp/t1pg` (started on
demand). `00_local_baseline.sql` stands in for the Supabase platform (auth, realtime, pgmq, pg_cron, pg_net,
storage stubs that record calls) and for the pre-migration live schema; then **every** migration applies in order.
That template is rebuilt only when a migration changes; each `NN_*_test.sql` runs in its own copy.
- `10_events_v1` results, confirm/dispute, auto-confirm, records, joins, QR, deletion
- `20_roto` (roto session's)
- `30_security` schema-wide invariants: RLS on every public table, no policy on `participant_tokens`, every
  security definer function pins `search_path`, `t1_private` unreachable, anon refused on account RPCs,
  trigger functions not callable. A new migration that forgets one of these fails without a new test.
- `40_library` `collection_apply` idempotency, whole-batch rejection, ledger = items, undo once, delta sync,
  per-account isolation, trade confirm as one batch, retry-safe, can't give what you don't own
- `70_binders_wants` binders (create/rename/flag idempotent, unique names, wrong account refused), adds into a
  binder, strict moves, shrink order (Unsorted, then non-trade binders by name, then for-trade), undo restores
  allocations, wants (any printing / printing / finish, max price), trade confirm with binder lines meeting wants
  and undone, `library_changes` paging and resync, and the invariant (allocations never exceed copies) after 300
  random mixed writes
- `80_friends_sharing` friends (ask, idempotent retry, quiet decline, ask-back accepts, cancel, unfriend, block hides
  everything and answers as usual), email lookups that never say whether an account exists (rate limited), the
  visibility matrix (owner / friend / stranger / blocked × profile cap × Same-as chain × per-binder/deck), max prices never
  shown, trade matches in trade_confirm's order (exact → printing → any, over max flagged), people you played with only
  when public, `trade_match_start` idempotent, Add players friends first, account deletion, anon refused
- `88_moderation` what gets checked (never private content), worker claim/record, cached verdicts, shadow vs enforce,
  child safety in any mode, reversible actions (revert never clobbers a later change), notices and one appeal,
  reports and the trusted-reporter threshold, restrictions, permissions, three failed tries go to review, deletion
- `95_bug_pipeline` bug intake and grouping (debug ignored), triage with regression and volume floors, one push per S1,
  the runner's claim/outcomes (stale claims, three tries → John), shipping per platform and build-due pushes, the
  server sweep (failed cron runs, pg_net 5xx/timeouts), service role only
- Event read fixtures: `testdata/event-bundle/make.sh` writes `bundle.json` / `public.json` / `preview.json` from
  `event_bundle` / `event_public` / `event_preview` on a copy of the test template (run after a migration changes
  their shape); iOS `EventBundleTests`, web `eventBundle.test.ts` and Android `EventBundleTest` decode them
- `50_demo` demo data only for `t1_private.demo_testers`, never in `player_records`, `demo_remove` clears it
- `perf_10_library` (perf tier) 35k Oracle cards / 105k printings, a 5,000-printing collection: `search_cards`,
  `card_prices_get`, `collection_changes`, `collection_apply` (500 ops), `catalog_pack_part` per 10k window; with
  4,000 allocations in 20 binders and 500 wants: `library_changes`, `binder_move` (500), `collection_apply` (500
  removals that shrink binders); with 200 friends (500 for-trade printings and 200 wants each, one trading 5,000):
  `trade_matches`, `profile_view`

Write tests with the helpers in `_helpers.sql`: `pg_temp.as_user(uuid)`, `pg_temp.eq(label, got, want)`,
`pg_temp.throws(label, sql, sqlstate)`, `pg_temp.ms(label, sql, budget_ms)`. Run one file: `supabase/tests/run.sh 40_`.
If a migration calls something live has but no migration defines, add it to the baseline (copy it from the
project with `pg_get_functiondef`), as was done for `create_event`, `generate_short_code`, `report_result`.

**Rules engine.** Pairings, standings, seating and teams live in `supabase/functions/events-engine` and are copied to
`table-1-events-web/src/lib`. `tools/test/engine-parity.sh` fails if the copies differ beyond `.ts` import
suffixes, so the Vitest suite (`tournament`, `teams`, `organizer`, …) tests what the server runs.
`tournament.perf.test.ts` plays whole events (8, 9, 64, 65, 256, 512 players) and checks every round is legal:
everyone paired once, one bye when odd, no second bye. Its time budgets apply under `T1_PERF=1`.

**iOS** (`apps/ios/Table1Tests`, scheme test action). Scanner accuracy floors (`CardMatcherTests`), catalog pack
(`CatalogPackTests`), collection CSV import (`CollectionCSVTests`: every format's fixture in `testdata/collection-import`
parsed and matched against the test catalog, export read back, `CollectionImportPerfTests` on 20k lines), and `ScannerPerfTests`: pack → SQLite build, catalog search, matcher per camera frame over
all 1,455 OCR reads in `testdata/scan`. `DeckStatsTests`: deck and cube stats against the shared cases in
`testdata/deck-stats/cases.json` (the web's `deckStats.test.ts` and Android's `DeckStatsTest` read the same file). Runs on its own `T1-Tests` simulator with derived data in
`/var/tmp/t1-test-dd`, so it never touches another session's simulator.

**Android** (`apps/android/app/src/test`). Same scanner accuracy and pack tests, `ListsTest`, `ScannerPerfTest`, and
collection CSV import (`CollectionCSVTest`: the same cases as iOS against `testdata/collection-import` and the test pack,
`CollectionImportPerfTest` on 20k lines). The tests share one in-memory copy of the test pack (`testPack`): two don't fit
the test JVM's heap.

## Budgets (measured 2026-10-16, John's Mac)

| What | Measured | Budget |
| --- | --- | --- |
| Swiss pairing, 512 players, worst round | 1.3 ms | 60 ms |
| Standings, 512 players | 0.4 ms | 25 ms |
| `search_cards` (prefix / two words / typo) | 18 / 23 / 23 ms | 100 / 100 / 120 ms |
| `collection_apply`, 500 ops | 80 ms | 300 ms |
| `collection_changes`, 5,000 items | 5 ms | 30 ms |
| `library_changes`, 4,500 rows / nothing new (2026-10-17, machine under load) | 11 / 0.2 ms | 40 / 5 ms |
| `binder_move` 500 moves; `collection_apply` 500 removals shrinking binders (under load) | 81 / 238 ms | 300 / 300 ms |
| `trade_matches`, 200 friends / one big trader; `profile_view` (2026-10-18) | 97 / 25 / 5 ms | 500 / 150 / 25 ms |
| `catalog_pack_part`, 10k window (oracles / printings) | 27 / 86 ms | 200 / 500 ms (live ≈ 5× local; timeout 8 s) |
| Web JS, gzipped (all / entry) | 314 / 54 KB | 380 / 70 KB |
| iOS pack → SQLite (Debug, Simulator) | 6.0 s | 18 s |
| iOS catalog search, worst query | 40 ms ("the") | 120 ms |
| iOS matcher per frame (Debug) mean / p95 | 6.9 / 33 ms (max 206) | 20 / 90 ms |
| Android matcher per frame (JVM) mean / p95 | 0.44 / 2.1 ms | 2 / 8 ms |
| Android scanner name index | 0.7 s | 2.5 s |
| Collection CSV import, 20k lines, iOS Debug: parse / match by id / by set + number | 210 / 150 / 470 ms | 650 / 1,500 / 1,500 ms |
| Collection CSV import, 20k lines, web: parse / match by id / by set + number | 30 / 32 / 80 ms | 150 / 400 / 400 ms |
| Collection CSV import, 20k lines, Android (JVM): parse / match by id / by set + number | 20 / 30 / 60 ms | 100 / 200 / 200 ms |
| Deck and cube stats, every stat on a 540-card cube: iOS Debug / web / Android (JVM) | 14 / 0.7 / 1.7 ms | 30 / 5 / 10 ms |

Budgets catch regressions (a lost index, a quadratic loop), not noise. Raise one only on purpose and say why in the commit.

## Rules

- **A bug fix comes with the test that would have caught it**, at the layer where the logic lives (SQL for RPCs and
  RLS, Vitest for engine rules, XCTest/JUnit for client logic).
- **A new feature comes with tests** for its server functions (happy path, refusal for the wrong account, idempotent
  retry where the contract promises it) and any client logic that isn't just layout.
- **A new hot path gets a budget** in the perf tier (an RPC that a screen calls on open, anything per frame or per keystroke).
- Run `./test.sh` before committing (the hook does the relevant part); run `./test.sh full` before a TestFlight or
  Play upload, and `./test.sh perf` after changes to search, sync, the catalog pack, pairing or the scanner.
- Other sessions share this working tree. If a failure is in files another session is editing, say so; don't fix
  their work in progress. `git commit --no-verify` only with the reason in the message.

## Discord bot (2026-10-29)
`deno test discord-bot/` runs in the engine tier: Ed25519 verification against a generated key pair (good, altered, replayed), the event card / results / deck / card embeds, button ids, pasted links, `when` parsing across DST, `/help` ↔ `commands.json`, and telemetry hygiene (an id-like property fails the test). `94_discord_test.sql` covers the database side; `perf_40_discord.sql` the budgets (card ≤ 20 ms at 63 players).

## Not covered yet

UI flows (XCUITest / Playwright on the demo modes), edge functions other than the engine and `list-import`'s parser (`cards-sync`,
`notify-worker`, `deck-finder` need fetch mocks), Kotlin/Swift ports of tracker and organizer logic, and RPC
contract drift (`contract/rpc.schema.json` vs the functions' real signatures).
