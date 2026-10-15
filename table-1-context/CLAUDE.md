# Table 1 — project context for Claude Code

Table 1 is John's suite of products for competitive Magic: The Gathering players. First product: **Table 1 Events** (table-1.site), a tournament runner. Play (events) is the product; Library and Insights were deliberately cut back in September 2026 and are now being reopened (see "Current direction").

## Stack and layout
- Backend: Supabase project `aaozhfcbvqrgkkrihkrd` (us-east-1). Migrations in `supabase/migrations/`, edge functions in `supabase/functions/` (`events-engine`, `delete-account`, `sets-sync`, live-activity), RPC contract in `contract/rpc.schema.json` (source of truth for wire names; generates Swift/Kotlin/TS models). Feature specs in `contract/*.md`.
- Clients, all native, one backend: `apps/ios` (SwiftUI, XcodeGen `project.yml`, Xcode 16+/iOS 17+), `apps/android` (Kotlin + Jetpack Compose, JDK 17), `table-1-events-web` (React 18 + Vite 6 + Tailwind v4).
- Expo/React Native was considered and rejected. No shared UI codebase.
- Setup/run steps per platform: `SETUP.md` (also `docs/app-setup.md`).
- Native code compiles (first real build 2026-10-13: iOS Debug sim + Release device, Android assembleDebug; no errors, no project warnings). Not yet run on device/emulator. Build commands on John's Mac:
  - iOS: `cd apps/ios && xcodegen && xcodebuild -project "Table 1.xcodeproj" -scheme "Table 1" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. TestFlight uploads still go through Xcode → Product → Archive.
  - Android: `cd apps/android && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew assembleDebug` (JDK 17 + SDK from Homebrew; SDK at `/opt/homebrew/share/android-commandlinetools`, set in `local.properties`).

## Rules that must hold
- **Server-authoritative rules.** Pairings in `events-engine`, standings from a Postgres function. Clients render and submit only. Standings are computed from results, never stored.
- A match holds *sides*, not player_a/player_b. Pods are first-class even with one pod. Every mutation writes an audit row.
- Claim tokens live in `participant_tokens` (RLS on, no policy). Event location lives in `event_locations`.
- Results: single entry counts; opponent's same score confirms, different score disputes; auto-confirm at round end; organizer can override (audited). Unresolved disputes block pairing the next round.
- Tournament rules follow the WPN Magic Tournament Rules (Feb 27 2026): 3/1/0 match points, bye 3, OMW/GW/OGW with 33% floor. Open: Appendix E recommended-rounds table is unconfirmed.
- Auth: Sign in with Apple + Google (email provider currently OFF; being re-enabled, see below). Account deletion must revoke the Apple token.
- Demo data is `is_demo`, shown only on TestFlight/Debug iOS, and never in real records.
- Credits/efficiency: avoid full three-platform builds per change. Build order (John, 2026-10-14): iOS first, then web, then Android, in batches.
- Test iOS changes in the Simulator in Debug. Other Claude sessions build and run here too: use your own simulator device and your own `-derivedDataPath` (e.g. in your scratchpad), never shut down or reuse a simulator another session booted.

## UI/design rules
- Design source of truth: Figma file `Hbkg1vKjdTFpwYt0NtCCYq` (screens) and `R9h660jfTHZEcnFZ2DJtLA` (roto (Copy), tokens). Figma Make prototype `qjTBMsO4R5LgfSv1ihavu8` is visual reference only; do not build on it.
- Table 1 components everywhere (tab bars, segmented controls, switches, steppers, menus, sheets). Only alert dialogs are platform-native.
- Look: SF Mono (temporarily JetBrains Mono in Figma), uppercase labels with wide tracking, zero radius, no shadows/cards, 1px hairline grid, dark default `#171725`, surface `#282839`, one accent teal `#00ffd9` meaning "the result", disabled = flat `#545461` fill (no opacity dimming).
- Build first, then Figma (John, 2026-10-14; reverses "Figma first"): build the feature in code, then add or update the Figma screens/components to match what was built.

## Where things stand (as of 2026-10-13)
Built on all three platforms: Events and Account tabs (live card, invitations, upcoming, past collapsed), create event (Constructed/Limited formats, sets from Scryfall via `sets-sync`, team events of 3-4, draft seating), life tracker (synced per match), cancel event, add players (invite only, by email finds existing accounts), organizer screen in three phases (Setup / Live / Results), Live Activities and widgets (iOS), TestFlight demo data. Collection tab exists but is greyed out ("Soon").
Pending: notify-worker (push), web deploy to table-1.site, Google auth provider setup, universal/app links files, Android release signing.

## Current direction (John, 2026-10-13) — reopens Library
1. **Email sign-in** alongside Apple/Google (reverses the earlier Apple/Google-only decision; prefer email OTP/magic link or enable leaked-password protection). Finish Google auth.
2. **Progressive disclosure** across the app: summaries at top level, detail one tap deeper (e.g. Insights shows overall win/loss, matchups behind a tap). Orient Play around task at hand: a player arriving to play vs an organizer arriving to run an event. Past events shouldn't end up in the ledger (assumed: history under Insights).
3. **Collection tab goes live**: All cards, Decks, Cubes, Trades. A confirmed trade increments/decrements the collection. Card in a deck being traded: warn and require a choice.
4. **Imports** into collection/decks/cubes from ManaBox, Moxfield, Cube Cobra (CSV and decklist paste first, links later). Earlier principle: be a layer on those tools, not a competitor.
5. **Card scanning** (camera) for trades and adding to collection. Must be fast, precise, tolerant of varied backgrounds. Plan: on-device rectangle detect, deskew, title OCR (iOS Vision / Android ML Kit), consistent-frame confirmation, match against a local Scryfall-derived cache; collector number/set symbol picks the printing. In Trades, match only against owned cards. Never call the Scryfall API per frame. Build a photo test set before tuning. Spike first.
6. Tracker/design polish in Figma is ongoing (Life Tracker started; more key screens coming).

Note: this reverses the Sept 8 decision to cut collection/trades from v1. Keep Play the priority; build Library in the order above and keep Library features from compromising Play correctness.

## Docs
Full history and decisions are in `docs/` (copies of the project docs): `table-1-events.md`, `events-v1-decisions.md`, `app-setup.md`, `plan-nav-cancel-demo.md`, `plan-tracker-formats-teams.md`, `plan-organizer-phases.md`, `plan-library-scanning-nav.md`, `figma-screens.md`. Start with `docs/README.md`: it lists which earlier decisions have been superseded, and wins where a doc disagrees. `architecture.md`, `brand-visual-rules.md`, `gtm-plan.md` and `research.md` describe the retired Ollo/brand-os work and are not included.
Client feature specs live in `../contract/` (in the repo) (`features-2026-10-13.md`, `organizer-phases-2026-10-14.md`). `SETUP.md` is the run/setup guide (same as `docs/app-setup.md`, which carries the superseded-decision notes).

