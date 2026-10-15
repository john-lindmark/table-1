> **UPDATED 2026-10-13:** §4 (Collection tab greyed out, "Soon") is superseded: the Collection tab is going live as All cards / Decks / Cubes / Trades. See README.md and plan-library-scanning-nav.md. The rest still stands.

# Plan — Life tracker, event types & formats, team events, Collection tab (2026-10-12)

## Status (2026-10-12): built
- Backend live: migration `20261013120000_formats_teams_tracker.sql` (copy in `claude/backend/`), events-engine v4 (`seat_players`, team pairing/standings, `teams` + `seating` in standings), `sets-sync` edge function + daily cron (1059 Scryfall sets).
- iOS, Android, web written to `contract/features-2026-10-13.md`. Web: tsc, 50 tests, build pass. Swift/Kotlin syntax-checked only (not compiled).
- UI rule (John): T1 components everywhere, including tab bars, segmented controls, switches, steppers, menus and sheets; only alert dialogs are native. Remaining native bit: iOS pull-to-refresh.
- Figma: tracker, create, seating, teams, team standings, player and Account states on all three platforms (see `figma-screens.md`).
- Synced to the Mac (`~/Documents/Table 1`), SETUP.md §9, iOS build number 3. Web still needs deploying; iOS needs `xcodegen`.
- Functionality doc (Claude Doc): https://claude.ai/code/artifact/614eea94-2588-4cfc-91f7-64c9f73000cb

## Decisions (John, 2026-10-12)
- Life tracker runs on each player's own phone, synced live within a match. Both halves have controls; the opponent's half is flipped, so one phone can also be shared on the table.
- Limited round 1 pairs across the draft table (8-pod: 1v5, 2v6, 3v7, 4v8).
- Team events: teams of 3 or 4, chosen at create.
- Sets come from Scryfall's draftable set list (cached server-side); cube = name + optional CubeCobra link.

## 1. Life tracker
**Where:** Events top bar "Life" (works with no event), the live card / player event screen ("Open life tracker"), and auto-open when in tracker mode.

**Layout:** full screen, screen kept awake. My half at the bottom, opponent's half on top rotated 180°. Each half: name, big life total, tap left −1 / right +1 (hold to repeat), counters row. Center strip: game number, games won, History, Record game, ⋯ (reset, starting life, close).

**Counters:** life (20 default), Poison (loss at 10), Energy, Experience, Rad, Speed (max 4); shown on demand from "+ Counter".

**History:** per game, newest first. Taps on the same player + counter less than 2 s apart merge into one entry; any other player/counter closes the group. Undo last pushes inverse ops.

**Recording games:** Record game → pick winner → confirm ("Record game 2: you won? Match is 2–0") → committed. Life ≤ 0 or poison ≥ 10 offers the same flow. When the match is decided, prompt "Report 2–1" → existing report_match.

**Sync:** `tracker_sessions`, `tracker_ops` (idempotent by client_op_id), `tracker_games`; totals = starting life + sum of deltas; Realtime postgres_changes per session; RLS: the two players, organizer read-only. Outside an event: local-only.

**Modes:** per-user `user_settings.tracker_mode` ('elsewhere' default | 'tracker'), on Account and as a switch on the event screen.

## 2. Event create
Type (Constructed | Limited) → Format (Constructed: Standard, Pioneer, Modern, Legacy, Vintage, Pauper, Premodern, Canadian Highlander, Other; Limited: Draft, Team draft, Sealed, Team sealed) → Product (set from `draftable_sets()` or cube name + optional CubeCobra link) → team size (team formats) → rounds (default 3) → round length → name. Created with `create_event_v2`.

**Draft seating:** pods of up to 8, balanced; round 1 across the table (seat i vs i + n/2; odd pod → last seat bye). Sealed round 1 random. Swiss from round 2.

## 3. Team events
- Team size 3 or 4. Organizer assigns by hand or Randomize; rename; "+ Team". Pairing blocked until everyone is on a team.
- Team draft: two teams, alternating seats; A_i plays B_((i + round) mod size).
- Team sealed: Swiss between teams, slot vs slot; odd team count → team bye.
- Team result: majority of member matches; even split is a draw; 3/1/0, bye 3.
- Standings: team table (points, then members' match wins, then GWP), individual table below with team tag.

## 4. Collection tab
Events | Collection | Account; Collection greyed with "Soon" and not selectable.

## Defaults chosen (change any)
- Tracker mode defaults to Track elsewhere.
- 2–2 team result is a team draw.
- Team draft is two teams per pod in v1.
- Sealed round 1 is random (no pod).
- Life tracker also on web.
- Not in scope: life totals on the Live Activity, multiplayer/Commander, joining a friend's tracker outside an event.
