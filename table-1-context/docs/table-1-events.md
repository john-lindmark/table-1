> **UPDATED 2026-10-13:** Several decisions here have changed. (1) **Library is reopened**: "Cut from v1: collection, wishlist/trades, deck editor" no longer holds. Collection (All cards / Decks / Cubes / Trades), trades that update the collection, and imports from ManaBox/Moxfield/Cube Cobra are now planned; Play remains the priority. (2) The **players-on-web / native-organizer-later** split was superseded on 2026-10-06 by fully native iOS and Android clients plus web (see `events-v1-decisions.md`). (3) **Offline posture** was decided 2026-10-06 (online-first with an offline result queue). (4) Email sign-in is being added. The tournament rules, invariants and access model below still stand. See README.md.

# Table 1 Events — architecture and decisions

First product in the Table 1 suite: a tournament runner for competitive Magic.
This doc is the source of truth for what was decided and why. Last updated
2026-09-08.

## Product shape

Three workspaces (Library / Play / Insights) was the original scope. It was cut
back deliberately. **Play is the product**; Library and Insights are commodity
surfaces with strong free incumbents (Moxfield, Archidekt, ManaBox, Cube Cobra,
MTGGoldfish, 17Lands) and building them first would have meant months before
touching anything differentiated.

The wedge inside Play is **cube and team Limited** — EventLink owns sanctioned
store play, Melee owns competitive constructed, Draftmancer owns online drafting,
and none of them run a cube draft with pods and standings well.

Guiding principle: **single-pod product surface, TO-grade correctness core.**
Organizer features (registration caps, payments, judge tooling, sanctioned
reporting) are additive and can wait. Correctness — pairings, tiebreakers,
results integrity, audit trail — cannot be retrofitted, because by the time a TO
cares, there is already history that was computed wrong.

### Build order

1. Event core — schema, invariants **(done)**
2. One event end to end: create → join → seat → pair → report → standings **(done)**
3. Public standings page **(done)**
4. Cube attach — Cube Cobra import, snapshot into the event
5. Multi-pod — N pods, cross-pod standings
6. Team events, then rotisserie
7. Personal and cube analytics (largely falls out of 1–6)

Cut from v1: collection, wishlist/trades, deck editor (import only — be a layer
on Moxfield and Cube Cobra, not a competitor), constructed metagame, 17Lands,
leagues, achievements, custom formats, draft simulation, two-way Cube Cobra sync.

## Codebase

| Path | What |
| --- | --- |
| `Documents/Table 1/table-1-events-web` | The real app — React 18, Vite 6, Tailwind v4, Supabase. Git repo from first commit. |
| `Documents/Table 1/Table 1 - Events` | The original Figma Make export, kept as the visual reference. Do not build on it. |

Future: React + Vite web app plus native iOS and Android later. Expo was
considered and rejected — if the native apps are going to be Swift and Kotlin
there is no shared codebase for Expo to protect, so the web app is plain React
and the native clients will talk to the same Supabase backend.

The natural split when native arrives: **players and spectators stay on web**
(zero-install, QR join, shareable standings — no native app improves this), and
a **native organizer app** carries push notifications, a lock-screen round timer,
and offline tolerance. Push is the thing that will actually force the native
decision; iOS web push only works for home-screen-installed PWAs and is too
flaky to build "round 2 pairings are up" on.

## Database

Supabase project **Table 1** (`aaozhfcbvqrgkkrihkrd`, us-east-1). Real Postgres
tables with RLS — replacing the Figma Make key-value store (`kv_store_*`), which
could not do migrations, RLS, or any query more interesting than fetching one
JSON blob per event and rewriting it whole.

```
events ─┬─ event_members        organizer roles (owner / organizer)
        ├─ pods                 first-class even at one pod
        ├─ participants ── participant_tokens   (no RLS policy at all)
        ├─ rounds ── matches ── match_sides
        └─ audit_log
```

### Invariants worth defending

1. **Standings are always computed from results, never stored.** Inherited from
   the Figma Make build, which got this right.
2. **A match holds *sides*, not `player_a`/`player_b`.** Team events later are a
   change of cardinality, not a change of model.
3. **A pod is first-class even when there is exactly one.** Multi-pod is then a
   feature, not a migration.
4. **Every mutation writes an audit row**, from before it seemed necessary.
5. **Claim tokens are never publicly readable.** They live in
   `participant_tokens`, which has RLS enabled and no policy, so it is reachable
   only from `SECURITY DEFINER` functions.

### Access model

Reads are public across `events`, `pods`, `participants`, `rounds`, `matches`,
`match_sides` — standings and pairings are meant to be shared. `audit_log` and
`participant_tokens` are not readable. Writes are either organizer-gated through
RLS (`is_event_organizer`) or go through an RPC: `create_event` (authenticated
only), `join_event` (anon — returns a token), `report_result` (anon — the token
proves the caller is on that match).

Verified: anon can read event data, sees zero token and zero audit rows, and
cannot write or delete.

**Open:** leaked-password protection is disabled in Supabase Auth. Enable it.

## Tournament rules

Implemented from the Magic Tournament Rules (Feb 27 2026) in
`src/lib/standings.ts` and `src/lib/pairings.ts`, covered by fixtures in
`src/lib/tournament.test.ts`:

- Match points — win 3, draw 1, loss 0, bye 3
- Game points — game win 3, game draw 1, game loss 0
- Match-win % = match points / (3 × matches played), floored at 33%
- Game-win % = game points / (3 × games played), floored at 33%
- Opponents' percentages are means over opponents; byes contribute no opponent
- A bye scores as a 2-0 win for the player's own game-win percentage
- Order: match points → OMW% → GW% → OGW%
- Dropped players leave the pairing pool but keep counting in opponents'
  tiebreakers

Pairings are Swiss: round 1 is a random draw, later rounds sort by standings and
pair down the list, rematches are avoided by exhaustive backtracking rather than
a greedy pass, and the odd player out gets the bye — lowest-ranked player who has
not already had one.

**Open:** Appendix E's recommended-rounds table did not survive PDF extraction.
`recommendedRounds()` uses conventional values (8 players → 3 rounds). Confirm
against the current MTR before anything sanctioned.

## Result reporting

The two-sided blocking confirmation in the original plan was dropped — in
practice one player reports and the other never opens the app, which stalls the
round. Instead: single entry (either player, or the organizer), organizer
override at any time, and every change audited. A dispute window that
auto-confirms is the next step, not a gate on round progression.

## Design language

Carried over from the Figma Make build and now living in
`src/styles/globals.css`:

- SF Mono throughout; uppercase with wide tracking for every label and action
- Zero radius, no shadows, no cards — hard rectangles
- 1px hairline grid: `gap-px` between blocks so the background shows through
- Full-bleed, no page scroll, mobile first
- Dark default `#171725`, surface `#282839`, hover `#33334a`; light `#ffffff` /
  `#f5f5f6`; secondary text `#545461` / `#c4c4ca`
- One accent, electric teal `#00ffd9`, used only to mean "this is the result"
- Enormous tabular numerals; one giant full-width action bar as primary control
- Disabled is a flat `#545461` fill, never dimmed opacity

## Still open

- Offline / connectivity posture — decided 2026-10-06 (see `events-v1-decisions.md`).
- Durability and organizer-device failure — what happens when the organizer's
  phone dies mid-round (partly addressed: any co-organizer can take over).
- Card data, decklists, and legality — not needed until sealed or deck
  submission; snapshot the legality verdict at submission rather than building a
  temporal rules engine. (Now relevant again with the Library work.)
- Cube and Cube Cobra import (one-way).
- Insights, scoped to event-derived personal and cube analytics only.
