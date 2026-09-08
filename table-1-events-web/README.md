# Table 1 Events — web

Single-pod Swiss tournament runner. React + Vite + Supabase, mobile first,
carrying the Table 1 design language from the original Figma Make build
(`../Table 1 - Events`, kept as the visual reference).

## Run it

```bash
npm install
cp .env.example .env     # fill in the anon key, or use the .env already here
npm run dev              # http://localhost:5173
npm test                 # pairings + tiebreaker fixtures
```

## Routes

| Path | Who | What |
| --- | --- | --- |
| `/` | organizer | Sign in, event list, create event, join by code |
| `/e/:eventId` | organizer | Run the event — pairings, results, timer, standings, drops |
| `/join/:code` | player | Join as a guest with just a name |
| `/p/:eventId` | player | Their match, their result buttons, live standings |
| `/s/:eventId` | anyone | Read-only standings and pairings — the shareable link |

Players never make an account. `join_event` hands back a token that lives in
their own `localStorage` and proves they are on a given match.

## Tournament rules

`src/lib/standings.ts` and `src/lib/pairings.ts` implement the Magic Tournament
Rules (Feb 27 2026):

- Match points — win 3, draw 1, loss 0, bye 3
- Game points — game win 3, game draw 1, game loss 0
- Match-win % = match points / (3 × matches played), floored at 33%
- Game-win % = game points / (3 × games played), floored at 33%
- Opponents' percentages are means over opponents; byes contribute no opponent
- A bye scores as a 2-0 win for the player's own game-win percentage
- Standings order: match points → OMW% → GW% → OGW%
- Dropped players leave the pairing pool but keep counting in their opponents'
  tiebreakers

Pairings are Swiss: round 1 is a random draw, later rounds sort by standings and
pair down the list, and rematches are avoided by exhaustive backtracking rather
than a greedy pass. The odd player out gets the bye — lowest-ranked player who
has not already had one. `npm test` covers all of the above with fixtures.

**Open item:** Appendix E's recommended-rounds table did not survive PDF
extraction, so `recommendedRounds()` uses the conventional values (8 players → 3
rounds). Confirm against the current MTR before running anything sanctioned.

## Database

Supabase project `Table 1` (`aaozhfcbvqrgkkrihkrd`). Real Postgres tables, RLS
on all of them — not the Figma Make key-value store.

```
events ─┬─ event_members        organizer roles
        ├─ pods                 first-class even at one pod
        ├─ participants ── participant_tokens   (never publicly readable)
        ├─ rounds ── matches ── match_sides     (sides, not playerA/playerB)
        └─ audit_log
```

Two decisions worth preserving as this grows: standings are always computed from
results and never stored, and a match holds *sides* rather than two named
players, so team events later are a change of cardinality rather than a rewrite.

Reads are public — standings and pairings are meant to be shared. Every write is
either organizer-gated through RLS or goes through a `SECURITY DEFINER` RPC
(`create_event`, `join_event`, `report_result`).

## Not built yet

Cube import, sealed, multi-pod, teams, rotisserie, decklists, analytics,
intentional draws, and result-dispute handling. See the roadmap discussion.
