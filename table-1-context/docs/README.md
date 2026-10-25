# Table 1 docs — read this first

These are copies of the docs from the Table 1 Claude project, bundled 2026-10-13. They were written over several weeks, and **several earlier decisions have since been updated.** Each affected doc has an "UPDATED 2026-10-13" banner at the top. Where a doc and this list disagree, this list wins. Ongoing direction is in `plan-library-scanning-nav.md`; the detailed Library plan (catalog, collection, imports, decks/cubes, trades, scanner, with performance targets) is `plan-collection-2026-10-14.md`. Roto (rotisserie) cube events: `plan-roto-2026-10-15.md` (agreed 2026-10-16; server built, clients in progress). Insights (constructed metagame from MTGO and TopDeck.gg, Arena draft from 17Lands, plain-language briefs, charts): `plan-insights-2026-10-24.md` (agreed 2026-10-24, not started).

## Decisions that have changed

| Earlier decision (where) | Now |
| --- | --- |
| **Library cut from v1**: collection, wishlist/trades, deck editor out; "Play is the product; be a layer on Moxfield/Cube Cobra, not a competitor" (`table-1-events.md`) | **Reopened.** Collection goes live as All cards / Decks / Cubes / Trades, with trades that move cards in and out of the collection, plus imports from ManaBox, Moxfield and Cube Cobra. Play stays the priority. |
| **Collection tab greyed out, "Soon"** (`plan-tracker-formats-teams.md` §4, `app-setup.md` §9) | Goes live as part of the Library work. |
| **Sign in with Apple + Google only; email provider OFF** (`events-v1-decisions.md`, `app-setup.md` §1) | **Email sign-in is being added** alongside both. Use email OTP or magic link, or enable leaked-password protection (the advisor warning cleared only because email was off). Finish Google provider setup too. |
| **Players and spectators stay on web; native organizer app later** (`table-1-events.md`) | Already superseded on 2026-10-06 by fully native iOS (SwiftUI) and Android (Compose) clients plus web (`events-v1-decisions.md`). |
| **Two-sided blocking result confirmation** (original plan) | Dropped. Single entry + opponent confirm/dispute + auto-confirm at round end + organizer override. Unresolved disputes now block pairing the next round (`plan-organizer-phases.md`). |
| **Navigation: Events top level shows everything** (`plan-nav-cancel-demo.md`) | Being reworked for progressive disclosure: summaries first, detail one tap deeper; Play split by task for a player arriving to play vs an organizer arriving to run an event. Past events move out of the main Events view (assumed: history under Insights). |
| **Offline posture and organizer-device failure listed as "still open"** (`table-1-events.md`) | Offline posture decided 2026-10-06: online-first with an offline result queue; any co-organizer can take over (`events-v1-decisions.md`). |
| **Build and release approach** | New: design in Figma first, then build; web first, then iOS, then Android in batches; do code work in Claude Code on the Mac (the chat workspace never compiled Swift/Kotlin). |

## Not included (retired)
`architecture.md`, `brand-visual-rules.md`, `gtm-plan.md` and `research.md` in the Claude project describe the earlier Ollo/brand-os work, which was placeholder content and has been retired. The SQL migrations and edge function sources are already in the repo under `supabase/`.

## Still open
- Recommended rounds per player count (MTR Appendix E) is unconfirmed.
- Web is not deployed (table-1.site hosting).
- Push notifications (notify-worker), Google auth setup, universal/app links files.
- Meaning of "past events shouldn't end up in the ledger" is assumed, not confirmed.
- Figma Error color: library pink `#F2A3E5` vs code red `#FF6B6B` / `#F87171`.
