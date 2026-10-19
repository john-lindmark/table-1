# Bug pipeline (2026-10-18)

From an error in someone's hands to a fix on main to "you need to ship iOS", with no one copying anything by hand.
Internal tooling: nothing here is visible to players.

```
Sentry (iOS, Android, web) ──webhook──▶ bugs edge function ──▶ t1_private.bugs ◀── t1-bugs-tick (every 10 min):
                                         │  rules + Claude: S1–S4      ▲              failed cron jobs, pg_net 5xx/timeouts
                                         ▼                             │
                               push to John for each new S1     tools/bugs/runner.sh (launchd, every 5 min, John's Mac)
                                                                  └─ claude -p "/fix-bugs S1|S4" → worktree, test, fix,
                                                                     merge to main, record platforms
                                         push to John when a platform's unshipped fixes call for a build / deploy
```

## Intake
- **Sentry** (one project per platform: `table1-ios`, `table1-android`, `table1-web`; see `telemetry-2026-10-15.md`). An
  internal integration posts webhooks to `https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/bugs`, signed with its
  client secret (stored server-side by `bugs.py setup-sentry`). Two resources are used:
  - `event_alert`: an alert rule fired, with the full event. Each fire counts one occurrence and replaces the bug's
    sample (exception, in-app frames, last 20 breadcrumbs with query strings stripped, a tag allow-list, app version).
    Never the Sentry user, IP, email or page query strings.
  - `issue` `created`: carries the issue's user count. Other actions are ignored.
- **Server 5xx seen by clients** (the SDKs' failed-request errors to `*.supabase.co`) are filed as one `server` bug per
  endpoint (`http:POST /rest/v1/rpc/report_result`), whichever app saw them.
- **The server's own failures**: `t1-bugs-tick` files failed `cron.job_run_details` (grouped by job + normalised
  message) and `net._http_response` 5xx / timeouts / connection errors (the database kicking edge functions).
- **By hand**: `bugs.py file "<title>" --platform ios` (from a session, a tester's report, PostHog).
- Debug and dev environments are ignored. Grouping is by fingerprint: `sentry:<issue id>`, `http:<method> <path>`,
  `cron:<job>:<hash>`, `net:<status>:<hash>`, `manual:<hash>`.

## Severity
| | Meaning | Examples |
|---|---|---|
| **S1** | Blocks running or playing an event, crash on launch/sign-in, data loss, a privacy/security problem, or the server failing for everyone | pairing fails, results won't save, standings crash, one player's private data shown to another |
| **S2** | A crash or hard failure in a main flow without a workaround, a background job failing, a non-blocking crash in Play | collection writes fail, trade confirm crashes, cards-sync failing |
| **S3** | A non-fatal error with a workaround, a secondary feature failing | sample hand errors, an export option failing |
| **S4** | Noise | offline, cancelled requests, browser chatter, cosmetic |

- **Rules first** (`supabase/functions/bugs/triage.ts`): expected network/browser noise is S4 without asking the model
  (never for a crash). Everything else goes to Claude (`claude-opus-5-5`, low effort, structured output, the same
  request shape as `moderate`) in batches of 20, rated by index; error text is treated as data. If the request fails:
  crashes S2, everything else S3.
- **Floors** (database): a bug that comes back after its fix shipped is reopened and rated one level more urgent;
  5 people or a Sentry "spike" alert → at least S2; 25 people or two spikes → S1. Floors also raise an already-open bug.
- John can override (`bugs.py set ID --severity S2`, `--status open|wontfix|needs_john`).

## Statuses
`new` (waiting for a severity) → `open` → `fixing` (claimed by a run) → `fixed` (merged to main) / `needs_john` /
`wontfix` / `duplicate`. A claim older than 3 hours is stale and freed; the third stale try goes to `needs_john`.
A `fixed` bug that keeps reporting before its fix ships is just counted (old builds); after it ships it reopens.

## Runner (John's Mac)
- `tools/bugs/install.sh` installs a launchd job running `runner.sh --poll` every 5 minutes. launchd jobs can't read
  `~/Documents` (macOS privacy; Full Disk Access for bash didn't help on macOS 26), so the poll runs from copies in
  `~/.table1-bugs/` (rerun install.sh after changing runner.sh or bugs.py) and hands each run to Terminal
  (`open -g -a Terminal ~/.table1-bugs/run.command`), which can read the repo. It asks the register
  for `open_s1` / `open_total` (free) and starts a headless Claude Code run only when there is work:
  an open **S1** → `/fix-bugs S1` at once (cap $15); the **08:00 and 18:00** windows → `/fix-bugs S4` once each (cap $40),
  most severe first. One run at a time. Logs in `~/Library/Logs/Table1Bugs/`. Pause: `touch ~/.table1-bugs/paused`.
  Caps: `T1_BUGS_S1_BUDGET`, `T1_BUGS_WINDOW_BUDGET`.
- The skill (`.claude/skills/fix-bugs/SKILL.md`) takes up to 3 bugs (S1 run) or 6 (window run). Each: a worktree off
  main, a failing test first, the fix (every platform with the same bug), `./test.sh` plus `./test.sh ios|android` for
  the platforms touched, a commit `Fix #ID (Sx): …`, `git merge --ff-only` into main, then `bugs.py fixed`.
- It **never** pushes, applies migrations or SQL writes to live, deploys edge functions, or touches secrets. Server
  fixes merge to main and wait for John's OK to deploy. Files another session has uncommitted changes in are left alone.

## Shipping
- A fix's platforms come from the files it changed: `apps/ios` → ios, `apps/android` → android,
  `table-1-events-web` → web, `supabase/migrations` or `supabase/functions` → server (the events engine also → web).
- A platform is **due** when its unshipped fixes include an S1 or S2, number five or more, or the oldest has waited a
  week. Due platforms push John ("iOS + Web build needed + server deploy · Fixes waiting: iOS 2 (S1), …") when the set
  changes, and again daily while it stands.
- After a TestFlight/App Store upload, a Play upload, a web deploy or a server deploy:
  `bugs.py shipped ios 1.0.9 --commit <sha the build was cut from>` (only fixes that commit contains count;
  without `--commit`, all pending on that platform).

## Pushes (notify-worker, watchers only: `t1_private.bug_watchers`, John)
| kind | title | body |
|---|---|---|
| `ops.bug` | New S1 · iOS (or "S1 is back") | the bug title |
| `ops.build` | iOS + Web build needed + server deploy | Fixes waiting: iOS 2 (S1), web 1 (S2) |

## Setup (once)
1. Apply `20261018200000_bug_pipeline.sql`, deploy `bugs` (verify_jwt off) and `notify-worker` (ops copy).
2. `tools/bugs/bugs.py init-secret`, then run the printed SQL (registers the runner secret's hash).
3. Sentry → Settings → Developer Settings → Custom Integrations → **New Internal Integration** "Table 1 Bugs":
   webhook URL above, **Alert Rule Action** on, permissions Issue & Event: Read, webhooks: `issue`. Copy its client
   secret and run `tools/bugs/bugs.py setup-sentry`.
4. In each of the three projects, two alert rules with the action "Send a notification via Table 1 Bugs":
   **"T1 bugs: new or regressed"** (a new issue is created; an issue changes state from resolved to unresolved;
   an issue escalates) and **"T1 bugs: spike"** (seen more than 50 times in 1 hour; the name must contain "spike").
5. `tools/bugs/install.sh`, and sign the `claude` CLI in once in Terminal (`claude`, then `/login`): the desktop app's
   sign-in doesn't carry over. Check with `tools/bugs/runner.sh --dry`. Optional: Terminal → Settings → Profiles →
   Shell → "When the shell exits: Close if the shell exited cleanly", so run windows close themselves.

## Not yet
- PostHog signals (e.g. `sign_in_failed` with `reason: error` rising, scan sessions cancelled empty): needs a PostHog
  personal API key; file by hand meanwhile.
- Edge function logs that never reach a client or pg_net (e.g. a function erroring inside a 200): not swept.
