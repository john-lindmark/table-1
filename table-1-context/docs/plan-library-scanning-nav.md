# Plan — Library (collection/decks/cubes/trades), card scanning, nav polish, email sign-in (2026-10-13)

Builds on: app-setup.md §8-10 (Events/Account tabs, tracker, organizer phases). Stack: SwiftUI + Kotlin/Compose + React web on Supabase.

## Decisions to date (John, 2026-10-13)
- Collection is split into **All cards · Decks · Cubes · Trades**. A confirmed trade increments/decrements the collection.
- Trade can **scan a card with the camera**; in a trade, matching is limited to cards the user owns.
- **Imports** into collection/decks/cubes from ManaBox, Moxfield, Cube Cobra (and similar).
- **Progressive disclosure** across the app: top level shows summaries, details one tap deeper (e.g. Insights = overall win/loss, matchups behind a tap).
- Play/Events orients around the task at hand: a **player** arriving to play vs an **organizer** arriving to run an event. Past events stay out of the ledger.
- **Email sign-in** added alongside Apple and Google; finish Google auth.
- Design in Figma first (Life Tracker started; John is drawing more key screens), review, then build. Do not do full three-platform builds on every change.
- Scanning must be fast, precise, and tolerant of varied backgrounds.

## Workflow (efficiency)
1. Figma screen -> John reviews -> build.
2. Web first for each feature; iOS next (TestFlight); Android after, batched. Android group can use web meanwhile.
3. Do code work in Claude Code on John's Mac (can compile Swift/Kotlin; the chat workspace cannot reach Apple/Maven, so every chat build was syntax-checked only). Use chat/project for planning and Figma review.
4. Put matching/import/trade logic server-side (Supabase RPCs + edge functions) so it is written once, not three times.

## Phases
**A. Email sign-in + Google auth** (small, unblocks testers)
- Supabase: enable Email provider (currently OFF by an earlier decision; this reverses it). Prefer email OTP/magic link or enable leaked-password protection, since the security advisor warning cleared when email was disabled.
- Clients: email field on sign-in, all three platforms. Finish Google provider setup per app-setup.md §1.

**B. Navigation / progressive disclosure pass** (Figma first)
- Events tab: player-first "what do I do now" (already hero card); organizer entry ("Host") separated from player flow; Past stays collapsed, history lives under Insights.
- Account: record summary (W-L) with tap-through to head-to-head/matchups.
- Collection tab goes live (currently greyed "Soon").

**C. Library data model + import**
- Tables: collection entries (card printing, qty, foil, condition), decks, cubes, deck/cube-card links, trade + trade lines. Card data from Scryfall bulk (extend `sets-sync`).
- Import: CSV/decklist paste first (ManaBox, Moxfield, Cube Cobra); link-based import later.
- Open: a card in a deck being traded -> warn and require choice (unassign vs. block).

**D. Trades**
- Trade = ledger of cards out/in; confirm applies changes atomically in one RPC (idempotent, audit-logged).

**E. Card scanner (spike first; riskiest)**
- On-device: detect card rectangle -> deskew -> read title (iOS Vision, Android ML Kit) -> require N consistent frames -> match against local card cache; collector number/set symbol picks the printing.
- Candidate set: owned cards only in Trades (small, fast); full card list in Collection add, with a batch mode.
- Server fallback: Scryfall-derived card table with fuzzy name search; never call the Scryfall API per frame.
- Build a test set of photos (varied backgrounds, lighting, sleeves, foils) before tuning; track accuracy and time-to-match.

## Open questions
- Confirm "past events shouldn't end up in the ledger" meaning (assumed: history under Insights, not in Library/trade ledger).
- Which Figma screens next (Life Tracker file started).
