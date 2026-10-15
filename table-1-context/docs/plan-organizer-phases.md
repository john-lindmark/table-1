# Plan — organizer event screen in three phases (2026-10-12)

John asked for three distinct organizer views: **Setup** (before round 1), **Live** (rounds running), **Results** (completed or cancelled). He approved the proposal below; rollout was Figma first, then iOS, Android and web.

## Status (2026-10-12): built
- Figma: flow "Event — organizer · setup / live / results" — iOS 69:6396, Android 70:5604, Web "Organizer (/e/:id) · setup / live / results" 71:6202 (supersedes the old organizer flow, which is still there).
- Backend live: migration `20261013140000_organizer_phases.sql` (copy in `claude/backend/`): `update_event_details` (full state, refused once a round exists, non-team format releases teams) and `set_round_clock` (pause / resume / add, keeps timer fields consistent). Drop/Reinstate stays a direct `participants` update (organizer RLS).
- Client spec: `contract/organizer-phases-2026-10-14.md`. iOS `UI/OrganizerPhases.swift`, Android `ui/screens/OrganizerPhases.kt`, web `src/screens/organizer/*` + `src/lib/organizer.ts` (79 web tests pass, build passes). Swift/Kotlin syntax-checked only.
- Decision: unresolved disputes count as outstanding, so they block pairing the next round (all three apps).
- Known gaps: disputed rows say "Reported differently · tap to set" (the second report is only in audit_log); Setup → Players shows joined/guest only (invites aren't loaded on the event screen); phones' "Who can find it" re-pins the event at the organizer's current location because `set_event_location` needs coordinates.
- Synced to the Mac; SETUP.md §10; iOS build number 4.

## Phase is derived, not stored
- Setup: status `setup` or `seated` and no rounds.
- Live: status `in_progress` (any round exists, event not completed/cancelled).
- Results: status `completed` or `cancelled`.

## Setup
- Bar: name · code · Setup · N players · format label. Phones: Back, More (Add players, Show join QR, Cancel event); web links: Events, Cancel event.
- Tabs: Players | Seating (drafts) | Teams (team events) | Details.
- Details (editable until round 1): name, format, set/cube, team size, rounds, round length, visibility (phones). Saves as you go.
- Big action: "Start event · pair round 1" → confirm alert → pair_round.

## Live
- Tabs: Round | Standings | Players (+ read-only Teams on Android).
- Round: big clock + caption; Pause/Resume and +5 min; matches grouped Disputed → Waiting → Results in; tap → set result (with Watch life tracker).
- Players: Playing (Drop, confirmed) and Dropped (Reinstate).
- Big action: Waiting on N results → Pair round N+1 → Finish event (confirm).

## Results
- Tabs: Standings | Rounds | Players. Winner card (team variant), final standings (teams first), every round's results (tap to correct), cancelled variant with reason.
