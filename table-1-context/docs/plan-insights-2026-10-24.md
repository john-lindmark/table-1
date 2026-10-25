# Plan: Insights — constructed metagame and Arena draft (2026-10-24)

**Status 2026-10-24: agreed (John's answers in § 11). Nothing built.** I0 needs John: a TopDeck.gg API key and the
MTGOFormatData permission request. Order follows the project
rules: server first, then iOS (Debug simulator, demo flag), web, Android in one batch, Figma after the build.

Insights becomes a dashboard per format. **Constructed** shows how the meta is moving: archetypes, cards played more
or less, and how the meta answers bans and new sets, led by the bigger events. **Limited** does the same for the draft
sets running on MTG Arena now. Every screen opens with a **brief**: two or three plain sentences saying what changed
and why it matters. Then come the charts, with detail one tap deeper (progressive disclosure).

## 1. Sources (checked 2026-10-24)

| Source | What we take | Terms | Gaps |
|---|---|---|---|
| **MTGO decklists** (mtgo.com/decklists, `window.MTGO.decklists.data` on each page) | Challenges (16/32/64/96), Showcase Challenges, RC Super Qualifiers, Championship week: standings (rank, points, OMW/GW/OGW), W-L, final rank, top 8 bracket, decklists, player count. Leagues: a selection of 5-0 decklists. Standard, Pioneer, Modern, Legacy, Vintage, Pauper, Premodern. Month pages (`/decklists/2025/03`) go back at least to early 2025 (417 events that month). | No stated license; every meta site re-posts it. Wizards' Fan Content Policy: Insights must stay free. | Challenges publish only the **top 32** (a 104-player Modern Challenge showed 32 decks). League lists are a hand-picked sample, not a field. No pairings except the top 8 bracket. |
| **TopDeck.gg API** (`POST /v2/tournaments`, free key, 100 req/min) | Paper events: standings with W-L-D (Swiss and bracket apart), decklists once public (`deckObj`), and **every round's tables with winner and game scores**. Filters: `game`, `format`, `last`/`start`/`end`, `participantMin`. Formats include Standard, Pioneer, Modern, Legacy, Vintage, Pauper, Premodern, Limited, Sealed. | Visible credit and link to TopDeck.gg required. | Volume of paper 60-card events on TopDeck is unknown until we have a key (it is cEDH-heavy). |
| **17Lands public datasets** (`17lands-public.s3.amazonaws.com/analysis_data/{game,draft}_data/…{SET}.{PremierDraft,TradDraft,PickTwoDraft,Sealed,TradSealed}.csv.gz`) | Game data: one row per game (deck, opening hand, drawn, colours, splash, on the play, mulligans, turns, rank, won, user win-rate bucket). Draft data: one row per pick. FRA PremierDraft: game data 25 MB gzipped, draft data 86 MB, last updated 2026-10-19. | CC BY 4.0. Their guidelines ask for the credit "clearly visible at the top level", with a link, never implying endorsement. Don't scrape their API. | Dumps arrive late by design: draft data ~2 weeks into a set, game data ~3 weeks. A new set has no Limited Insights until then. Arena only. |
| **Our catalog** (`card_oracles`, `mtg_sets`, `legalities`) | Card names → oracle ids, colours, types, mana value; set release dates for chart markers; daily legality to spot bans (§ 4). | Ours (Scryfall). | Scryfall has no ban dates: we record them ourselves. |
| **Not used** | MTGGoldfish (terms: personal, non-commercial, no republishing), mtgdecks.net (robots.txt blocks Anthropic crawlers and its analysis pages), Melee.gg (API only for organizers and staff they clear; parked 2026-10-24, see § 10), 17Lands' site API (their guidelines). | | |

## 2. Bigger events lead

Each event gets a **tier**, set when it is ingested:

| Tier | Events |
|---|---|
| **Major** | Paper events of 128+ players (TopDeck; Melee if it ever opens), MTGO RC Super Qualifiers, Showcase Challenges, Championship-week finals |
| **Large** | Paper 64–127, MTGO Challenge 64 and 96 |
| **Regular** | Paper 32–63, MTGO Challenge 32 |
| **Small** | MTGO Challenge 16, paper < 32, Leagues |

- The default view is **Big events** (Major + Large). One switch opens **All events** (adds Regular, Small and Leagues).
- Metagame share weights every deck by its tier (Major 4, Large 2, Regular 1, Small 0.5) and its finish (top 8 counts
  double). The weights live in one table, so we can tune them without a new build.
- Every number says what it counts. MTGO shows only the top 32, so the share reads **"share of top finishes"**, never
  "share of the field". A paper event with every deck published also gets a real field share and a conversion rate
  (share of the top 8 against share of the field).
- If a window has fewer than 40 weighted decks, the brief says the sample is thin and the charts grey the window out.

## 3. Archetypes

A deck's archetype comes from **rules**: cards in the main deck or sideboard that must, or must not, be there.
Colours are worked out from the lands and spells. A deck that matches no rule falls back to the nearest **"Other
<colours> <speed>"** group by card overlap. This is how MTGOArchetypeParser works.

- **Where the rules come from:** MTGOFormatData (rules for Standard, Pioneer, Modern, Legacy, Pauper and Vintage,
  kept up by Jiliac) shows no license. We **ask Jiliac/Badaro** for permission to use it with credit. Until they
  answer, we write our own (decision 11.2):
  1. Each night, cluster the unlabelled decks by weighted card overlap.
  2. Claude (Haiku 5.5) suggests a name and the rule (the 3–6 cards that define the cluster).
  3. A suggested archetype only shows once John approves it on an **Archetypes** review screen, beside the Bugs and
     moderation Review screens.
- Rules are versioned. Changing a rule re-labels history, so trend lines never jump because a name changed.
- Every archetype has a colour identity and a **family** (Aggro, Midrange, Control, Combo, Ramp), so the charts can
  roll small archetypes up.
- Cases in `testdata/meta-archetypes/`: real decklists saved from MTGO and TopDeck pages, each with its expected
  archetype. Every rule change runs them.

## 4. Format changes: bans, unbans, sets

`meta_format_changes(format, date, kind: ban | unban | restrict | set_release | rotation, cards[], note, source_url)`

- **Going forward, found automatically:** cards-sync already loads `legalities` every day. A new step compares them
  with yesterday's and writes the changes as **proposed**. John confirms each one on the Archetypes review screen
  (Scryfall sometimes fixes data, and that shouldn't show up as a ban).
- **Backfill:** enter by hand, with links, each B&R announcement in the backfill window (about 12 months, 6–10
  announcements).
- **Set releases** come from `mtg_sets.released_at`, including sets legal in Standard, Pioneer and Modern. Rotation is
  entered by hand.
- These changes draw the vertical markers on every time chart. They also start a **ban study** (§ 5.4).

## 5. Constructed dashboard (per format)

Formats at launch: Standard, Pioneer, Modern, Pauper (decision 11.3). Legacy, Vintage and Premodern next, once their
archetype rules are checked. Windows: 7 / 14 / 30 / 90 days, and "since the last change".

1. **Brief.** For example: "Since the Oct 7 ban, Boros Energy has fallen from 22% to 9% of top finishes. Izzet
   Prowess and Domain Zoo took most of its share. Ocelot Pride is still in 1 in 4 decks through Mardu builds."
2. **Meta now.** Bars of each archetype's share in the window, with the change since the previous window (▲/▼, in
   points), the tier band (≥ 8% / ≥ 3% / below), and conversion where we have field data. The archetype with the
   biggest change is in accent.
3. **Meta over time.** Daily share lines for the top 8 archetypes (7-day rolling, weighted), the rest as "Other". Ban
   and set markers along the time axis; tap a marker for what changed. Tap a line → that archetype.
4. **Ban response** (one per format change). Share before (30 days) and after (14 / 30 / 60 days), as a slope chart:
   - **Who lost:** the archetypes that held the banned cards.
   - **Who filled the gap:** the biggest gains.
   - **What replaced the card:** cards whose play rate rose most in decks of the hit archetype.
   - **Settled by:** the first day the 7-day shares stay within 2 points for 7 days.
   - For an unban, the same study: how fast the card was adopted, and in which archetypes.

   Its own brief: "The meta settled in 19 days. Izzet Prowess gained the most (+6 pts)."
5. **Cards.**
   - Rising and falling: share of decks playing the card and average copies, against the previous window.
   - A main / sideboard switch: sideboard trends tell you what the field fears.
   - New-set adoption: cards from the newest legal set, ranked by play rate since release.
   - Tap a card → its play rate over time, by archetype, and the card page (prices, own/missing, Add to).
6. **Archetype page.**
   - Share over time, with its markers.
   - Record: W-L from TopDeck rounds. MTGO Challenge W-L is shown as "record of top-32 finishers", since it only
     covers players who made the top 32.
   - Conversion.
   - Matchup row.
   - **Core** (in ≥ 80% of lists, average copies), **flex** slots, and the cards gaining or losing play in the list.
   - Best recent finishes (event, place, tier) with the list.
   - **Copy to my Library** (a new private deck) and **What I'm missing** (against the collection; basics never
     missing).
7. **Matchups.** A grid of the top 8–10 archetypes: match win %, with the number of matches and a 90% interval.
   - Sources: TopDeck rounds where both decks are known, plus MTGO top 8 brackets.
   - A cell with fewer than 30 matches is left empty, never guessed.
   - Tap a cell for the games and its brief.
8. **Events.** Recent big events: size, tier, winner, the top 8 by archetype, and links back to the source page.

## 6. Limited dashboard (Arena sets)

**Which sets are on:** sets with a 17Lands game-data dump updated in the last 45 days, newest first (FRA today). An
older set in a dump that has stopped updating moves to **Past sets**. Event types: Premier Draft (default),
Traditional Draft, Pick Two Draft, Sealed. A **Top players** switch uses only players in the top win-rate buckets.
**Weeks** is the window: the format's first weeks are dominated by newcomers, so trends run per week of the format.

1. **Brief.** For example: "Blue-black is the best pair in FRA Premier Draft at 57.1% and climbing since week 1.
   White's commons are the weakest in the set. Red aggro is underdrafted: its best uncommons go 2 picks later than
   their win rate suggests."
2. **Colour pairs.** Win rate and share for each pair (with splash rates), as bars against the set average. Under it,
   share by week, showing how the format settled.
3. **Cards.** Sort by game-in-hand win rate (GIH WR), opened-hand win rate (OH WR), improvement when drawn (IWD) and
   average last seen (ALSA, from draft data), with rarity and colour filters. Cards with fewer than 500 games in hand
   are left out.
4. **Under- and overdrafted.** A scatter of GIH WR against ALSA, with a fitted line. Cards well above the line are
   *sleepers*, well below are *traps*. Tap a dot → the card.
5. **Card page (Limited).** Win rates over the weeks, by colour pair, play rate, and P1P1 / pick position.
6. **Pair page.** Best commons and uncommons in that pair, the curve and creature count of winning decks against
   losing ones, and common splashes.
7. **Game facts.** On the play vs on the draw, mulligans (keep 7 vs 6), average turns, and how each pair does on the
   play.

Every Limited screen carries "Data from 17Lands" with a link at the top, as their guidelines ask, and never
suggests they endorse us.

## 7. Briefs (the plain-language part)

- An edge function **`insight-brief`**, built like `ranking-brief`.
  - It writes 2–3 sentences, ≤ 60 words, from a small facts table (archetypes and cards with their numbers, deltas,
    sample sizes and format changes). It never sees decklists or player names.
  - Model: `claude-haiku-5-5`, low effort, structured output (`{sentences: string[]}`).
- **Checks before saving, and one rewrite if any fails:**
  - Every number in the text must be in the facts (to the shown rounding).
  - No more than 3 sentences or 60 words.
  - No card or archetype name that isn't in the facts.
  - "Thin sample" must be said when the facts say so.
  - A second failure keeps the previous brief.
- **Written once per data refresh per view**, not per viewer. Cached in `insight_briefs` by view, window and hash of
  the facts, so the cost is about formats × views × windows a day (a few hundred short calls).
- Tests `insight-brief/brief.test.ts`: the number check, the length, a refusal, and cases in
  `testdata/insight-briefs/cases.json`.

## 8. Server

New `meta_*` and `limited_*` tables, readable by everyone signed in, written only by the sync functions. No player
names are stored: MTGO login names and TopDeck names are dropped at ingest, keeping only a salted hash to remove
duplicate decks.

- **`meta-sync`** (edge function, stepped like cards-sync, driven by pg_cron + pg_net with the shared secret):
  - `{step:"mtgo"}` hourly: read this month's index, queue new event pages; one page per step → `meta_ingest`.
  - `{step:"topdeck"}` every 6 h: `last: 3`, `participantMin: 32`, `rounds: true`, per format; past events re-read
    for 3 days, since decklists open after the event.
  - `{step:"backfill", month}`: month pages back 12 months, at most 1 request a second.
  - `{step:"label"}` after each ingest: apply the archetype rules to new decks. `{step:"cluster"}` nightly.
  - `{step:"aggregate"}` → daily sums per format × tier × archetype and per format × tier × card
    (decks, copies, main/side). Windows are added up from the daily rows, so a 90-day view stays cheap.
  - Card names map through `card_oracles.name_norm` / `face_names`. An unknown name goes in `meta_unmatched` for
    review, never dropped silently.
- **`limited-sync`:**
  - Daily HEAD on each dump. When `Last-Modified` changes, stream and gunzip into pieces in a staging bucket.
  - One piece per step adds to partial sums per card / pair / week / rank bucket (the 2 s CPU limit, as cards-sync).
  - A final step folds them into `limited_cards`, `limited_pairs` and `limited_weeks`.
  - Draft data adds pick position and ALSA.
- **Insights pack** per format and per set: one JSON file in the public `catalog` bucket (or an `insights` bucket),
  rebuilt after each aggregate, about 100–300 KB. It holds everything the first screen and its charts need, plus
  briefs. Clients load it once and cache it, with an ETag. Deeper screens (an archetype's lists, a card's history)
  use RPCs:
  - `meta_archetype(format, archetype, window, tiers)`
  - `meta_card(format, oracle_id, window)`
  - `meta_matchup(format, a, b, window)`
  - `limited_card(set, event_type, oracle_id)`
- Tests: `supabase/tests/97_insights_test.sql` (ingest is idempotent, a bad page is refused, weights, windows, ban
  study numbers on a fixed fixture, no names stored, review screen moderator-only). Fixtures in `testdata/meta/`
  (saved MTGO pages, TopDeck answers, a 2,000-row slice of a 17Lands file). Perf budget for the pack build and the
  four RPCs in `perf_30_insights.sql`.
- Never raise 40001/40P01 from these RPCs (the 2026-10-22 rule).

## 9. Clients

- **Placement** (decision 11.1): an **Insights** tab next to Play and Collection, opening on **Constructed |
  Limited** (Table 1 segmented control), then the format or set picker. Your own record (event history, win/loss,
  matchups) gets a third segment, **You**, later; this plan leaves room for it but doesn't build it.
- **Charts, drawn by us in the Table 1 look:** hairline axes, no fills or shadows, zero radius, uppercase mono labels.
  Grey for the context lines, and teal only for the series the brief is about.
  - iOS: Swift Charts, styled with our tokens.
  - Web: hand-written SVG, no new dependency.
  - Android: Compose Canvas.
  - Kinds: line (share over time, with markers), bars ± change, slope (before/after a ban), heatmap grid
    (matchups), scatter with a fitted line (GIH WR vs ALSA).
  - All three share one **chart maths** module: scales, nice ticks, 7-day rolling, Wilson intervals, the fitted line
    and label placement, with cases in `testdata/insight-charts/cases.json` from a Python reference `make_cases.py`.
- Tap a point or bar for its value. A long press on a line shows that archetype alone.
- Offline: the last pack stays readable, with "Updated <time>".
- **Ties to the Library** (cheap, and unique to us): "Copy to my Library", "What I'm missing", and on the Collection
  home "3 cards you own are rising in Modern".
- Demo: iOS `-T1InsightsDemo [constructed|archetype|ban|cards|matchups|limited|scatter]`, web `/insights?demo`, from
  packs saved in `apps/ios/Table1/DebugResources/` (Debug only).
- Telemetry (all platforms): `$screen` insights_constructed / insights_limited / insights_archetype /
  insights_card / insights_ban / insights_matchups / insights_pair. Events: `insights_window_changed`,
  `insights_tier_changed`, `insights_brief_expanded`, `insights_copy_to_library`, `insights_missing_opened`.

## 10. Build order

| Step | What | Done when |
|---|---|---|
| **I0** | TopDeck key (John), MTGOFormatData permission asked (decisions done, § 11) | Key in secrets; permission answer recorded here |
| **I1** | Server: tables, `meta-sync` MTGO + TopDeck, 12-month MTGO backfill, archetype rules for the 4 launch formats, format changes (backfill + legality diff) | SQL tests pass; one month of Modern labelled and spot-checked against a public meta page by John |
| **I2** | Aggregates, ban studies, packs, `insight-brief` | Packs published; briefs pass the checks for every launch view |
| **I3** | `limited-sync` for every set on Arena with a dump | FRA pack published with briefs; numbers checked against 17Lands' own card page for 10 cards |
| **I4** | iOS Insights tab, charts, demo flags | Checked in the Simulator demo and signed in against live |
| **I5** | Web `/insights` (desktop columns) | Checked in `?demo` and live |
| **I6** | Android | Built and unit-tested |
| **I7** | Figma screens to match; Feature Guide | Guide updated on merge |
| Later | Melee events if they grant read access; the **You** segment; pushes ("a card you own is rising"); Legacy / Vintage / Premodern; MTGO Limited (RC Super Qualifiers) | |

## 11. Answers (John, 2026-10-24)

1. **Where Insights lives:** its own **Insights** tab, next to Play and Collection.
2. **Archetype rules:** ask Jiliac/Badaro for permission to use MTGOFormatData with credit, and write our own
   (clustering, Claude-suggested names, John approves) until they answer.
3. **Launch formats:** Standard, Pioneer, Modern, Pauper. Legacy, Vintage and Premodern follow.
4. **Free:** Insights stays free (the Fan Content Policy needs it for MTGO-derived content).
5. **Names:** no player names anywhere in Insights; only a salted hash is kept to remove duplicate decks.
6. **Backfill:** 12 months of MTGO history (covers the last rotation and recent bans).
