# Team events: finish once a team has clinched, members ranked by record (2026-10-23)

From the 23 Oct team draft (3v3). Rules live in `supabase/functions/events-engine/teams.ts` (copied to
`table-1-events-web/src/lib/teams.ts`; `tools/test/engine-parity.sh` keeps them equal). Tests in
`table-1-events-web/src/lib/teams.test.ts` and `organizer.test.ts`; wire fixture
`testdata/event-standings/team-clinched.json` (iOS `EventBundleTests`, Android `EventBundleTest`).

## 1. Finish once a team has clinched
- Two teams head to head (team draft, or team sealed with exactly two teams). A team has **clinched** when its
  members' match wins (byes included) exceed the other team's plus every match still to play: open matches in paired
  rounds, plus one per seat of the larger team for each round not yet paired. It must also top the team standings,
  so finishing names it the winner. With no draws this is a majority: 5 of 9 in a 3v3 over three rounds, 7 of 12 in a
  4v4. Null once nothing is left to play, with three or more teams, and when the event isn't seated/in progress.
- events-engine `standings` returns `clinched` {team_id, name, match_wins, opponent_match_wins, remaining} (null
  otherwise). The web computes the same thing from its copy of the rules.
- Organizer Live: a notice "Team Alpha has clinched it: 5–1 in match wins with 3 matches left to play. You can finish
  now; open matches won't count." The big action becomes **Finish event** even while results are outstanding; when
  the round is in and rounds remain, **Play on · pair round N** sits above it. An open dispute still blocks (the
  server refuses to finish over one). The finish dialog repeats the clinch and says open matches won't count.
- No server change: `record_round(p_final)` already finishes with matches open (it records the round given, or the
  last one between rounds). Unplayed matches stay pending and count for nobody.
- Telemetry: `event_finished_clinched` {remaining} after an early finish (all three clients).

## 2. Team members ranked by record
- In the team table each team's members are listed best first: match points, then game-win % (2-0 2-1 2-1 above
  2-1 2-1 2-1), then OMW%, then OGW%, then seat letter. This is the order John asked for inside a team; the event's
  overall player standings keep the MTR order (points, OMW, GW, OGW).
- events-engine `teams[].members` come in that order and carry `match_losses` / `match_draws`; clients show each
  member's record ("2-0") and no longer re-sort by seat.
