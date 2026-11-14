# Cube rankings (2026-10-21)

Stack-rank a cube's cards, the way cuberanker.com does for LSV's cube, for any cube on Table 1. A **ranking** is one
person's run through a cube: sort each color, then a final top 100 (or 50) across every card. Each step is a
**screen**: up to four cards you drag into order, best first, then lock in. Everyone who can see the cube can watch,
read and compare the rankings shared with it.

Server: migration `20261021120000_cube_rankings.sql`, tests `supabase/tests/97_cube_rankings_test.sql`, budgets in
`perf_10_library.sql`. Engine: one pure module per client (`CubeRanking.swift`, `cubeRanking.ts`, `CubeRanking.kt`),
checked against `testdata/cube-ranking/cases.json`, written by the independent reference
`testdata/cube-ranking/make_cases.py`. Change the reference first, regenerate, then make all three clients pass.

## Decisions (2026-10-21)

- **Who ranks:** anyone who can see the cube: its owner, or friends / anyone when the owner shares it on their profile
  (contract/friends-sharing-2026-10-18.md). Several rankings per person per cube are fine (cuberanker's "runs"). A ranking
  of someone else's cube is wholly yours: you pick, undo, rename, share or delete it; the cube's owner can only see it
  (when it's shared with the cube) and can't change it.
- **Finding cubes to rank** (John, 2026-10-21): Rankings lists **Cubes you can rank**: cubes your friends and the people
  you've played with share with you. A stranger's public cube isn't listed (nobody can browse all accounts); it's reached
  through their profile, and its Rankings row works the same.
- **Who sees a ranking:** **Shared with the cube** (default): everyone who can see the cube, so a cube's owner sees
  every ranking of it and its audience sees each other's. **Only me**: private. Blocks (either way) hide a person's
  rankings; a restricted account's rankings show to nobody else. Narrowing the cube narrows its rankings with it.
  Unlike decks, a ranking starts shared: ranking someone's cube is taking part in it, and on a private cube "shared with
  the cube" reaches only you.
- **What is ranked:** the cube's main board as it is now, one entry per card (Oracle id; printings and copies merge;
  Considering is left out). Cards added later join the ranking; cards removed drop out of it.
- **Colors** (the cube's Group by color, contract/shared-lists-grouping-2026-10-20.md): White, Blue, Black, Red, Green,
  Multicolor, Colorless, Lands. Keys `W U B R G M C L`; the final is `F`. Empty colors are left out ("5 of 7 sorted").
- **Depth:** **Top half** (default, cuberanker's default for new runs): each color is ordered until its top half
  (rounded up) is in order; the rest sit "below the top N, in no particular order". **Every card**: full sort.
- **Final:** top 100 (default) or top 50, capped at the cube's size. It works before every color is sorted (it then
  also asks about cards inside unsorted colors), but is quickest after.
- **P1P1 refining** (John, 2026-10-21; not on cuberanker): a 15-card pack from the cube; pick one. The pick says the
  picked card beats the other 14 (no order among them), so it refines the ranking like any screen. When the ranking
  already puts a pack card above the picked one, the screen says so ("You ranked Mana Drain #3 and Fury #20, but picked
  Fury") and offers **Keep my ranking** (the pick is saved; its disagreeing pairs are skipped) or **Let the pick win**
  (the screens behind the disagreement come out first, so the pick's order holds; their cards are asked again).
- **Change log** (John, 2026-10-21): every change to a list's places, saved with the ranking: "Mana Drain · Final:
  #5 (new)", "Fury · Final: #4 → #9 (redo screen 12)". On the ranking (newest first, by day) and per card.
- **Not built** (cuberanker has them): Discord sign-in (Table 1 accounts instead), a public watch link (there is no
  signed-out view; rankings open from the cube, see Where), the redo cost estimate ("about N more screens").

## Sets (John, 2026-10-30: "add the ability to rank a limited set from the insights view")

A ranking ranks a cube (`list_id`, as before) or a **Limited subject** (`set_key`): a paper draft set by its code (FRA) or
an Arena cube version (PWR-2510, contract/insights-2026-10-24.md § Arena cubes). Migration
`20261030140000_limited_rankings.sql`, tests `57_limited_rankings_test.sql`, budgets in `perf_10_library.sql`, cases
`testdata/limited-rankings/cases.json` (iOS `LimitedRankingsTests`, web `limitedRank.test.ts`, Android `LimitedRankingsTest`).
- **What is ranked:** a set's English printings, one per card, without basic lands, tokens or art cards, each drawn in its
  lowest collector number in the set (the regular frame); a cube version, the cards 17Lands lists for it (usual art). The
  engine, saving, screens, picks, compare, briefs and the top-100 image are the cube ranker's. Cards Scryfall adds later
  (spoiler season) join like cards added to a cube: they wait outside the lists until placed.
- **Who sees one:** its maker, and with sharing `cube`, shown as **Shared with friends**, their friends (blocks and
  restrictions as before); since 2026-11-10 also whoever the maker's Rankings profile part reaches (Anyone on a public
  profile; contract/friends-sharing-2026-10-18.md § Rankings on profiles). Everyone can see a set, so "shared with the set" would have meant everyone on Table 1. Names are
  moderated whenever shared.
- **Subject ids:** clients treat a set as the subject `set:<KEY>` wherever a cube's list id goes (`RankSubject` iOS /
  Android, `lib/limitedRank.ts` web), so the Rankings screens open either by one id. The server's subject is
  `{id: "set:<KEY>", set, kind: set | cube, name, released, mine: false, owner: null, can_see: true}` (+ `cards`,
  `printings` from `cube_ranking_get`).
- **Calls:** `cube_ranking_create(p_id, p_list_id?, …, p_set?)` (one of the two), `cube_rankings(p_list_id?, p_set?, p_sets
  = false)` (a set's with `p_set`; your own list has your set rankings only with `p_sets`, which builds before this one
  don't send, since they'd try to open the set's cube), `limited_rankable()` → `[{key, name, released, kind, cards, pack,
  mine, rankings}]`: paper sets from the last 400 days with 60+ cards, upcoming sets from 75 days out with 20+ cards
  spoiled (spoiler season; was 45 days and 60+ until `20261030170000_limited_rankable_spoilers.sql`, test
  `58_limited_spoilers_test.sql`), and every Arena cube version.
  Ranking rows carry `set_key` (and `list_id` null for a set).
- **Where:** Insights → Limited: **Rank this set** / **Rank this cube** under each set's stats, **New sets to rank** (sets with
  no 17Lands data yet). Rankings (yours): **Sets you can rank**. The set's Rankings: "Rank <Set>", **Your friends'**
  rankings. Web `/insights/limited/<set>/rankings`; the apps push the Collection Rankings screen in the Insights tab (iOS)
  or route `collection/list/set%3A<KEY>/rankings` (Android).
- **Not done:** the brief's prompt still says "cube" ("how each likes to draft this cube"); pushes to an owner
  (`ranking.started`) don't apply (a set has none); a set's P1P1 pack is 15 cards from the whole set, not a booster's
  rarities.
- Telemetry: `ranking_created` gains `subject`: cube / set.

## Popular cubes (John, 2026-11-10: "From my rankings on profile, I should have the ability to rank and see friends rankings of popular cubes")

Four cubes nobody on Table 1 owns, ranked like a Limited set (§ Sets): **PowerLSV** and **LSVCube** (Cube Cobra
786d3a10… / a525ebe1…), **MTGO Vintage Cube** (mtgo.com's card list) and **Arena Powered Cube** (Scryfall's cube list
`apcube`). Migration `20261110140000_popular_cubes.sql`, tests `supabase/tests/57c_popular_cubes_test.sql`, Deno
`limited-sync/popular.test.ts` (trimmed real pages in `testdata/popular-cubes/`), shared cases
`testdata/popular-cubes/cases.json` (iOS `PopularCubesTests`, web `popularCubes.test.ts`, Android `PopularCubesTest`).
- **The lists:** `t1_private.popular_cubes` (key PLSV / LSV / VCUBE / APCUBE, name, curator, source, link, cards as Oracle
  ids, the printing each is drawn in, names nothing matched). limited-sync `{step:"popular"}` reads them weekly
  (pg_cron `t1-popular-cubes`, Mondays 06:41 UTC; `{step:"popular", set:"PLSV"}` reads one): Cube Cobra's cube JSON (main
  board, in the cube's printings), mtgo.com's first table under a "Full Card List" heading (the page also keeps the last
  list and a change list; names only, usual art), Scryfall's `cube:apcube` search (Scryfall's printing). Scryfall's
  `cube:vintage` is behind MTGO's list (540 cards, ~40 differ on 2026-11-10), so MTGO is read directly.
  `popular_cube_put` (service role) refuses a list under 300 matched cards, so a page that changes shape never empties
  a cube. The key stays as the list changes: cards that join or leave work like a changed cube (§ Cube changes).
- **Ranking one:** the subject `set:<key>`, `kind: popular`, with `curator` and `url`; created, saved, seen, compared
  and shared exactly like a set ranking (Shared with friends, plus whoever your Rankings profile part reaches). Words
  say "cube" for `popular` (and for Arena cube versions), "set" for sets.
- **`popular_cubes()`** → `[{key, id, name, curator, url, cards, updated, mine, rankings, friends}]` in the order above:
  `mine` your rankings, `rankings` all you can see, `friends` your friends'. A cube whose list hasn't been read is left out.
  Popular cubes are never in `limited_rankable` (they're not Limited sets).
- **Where:** your own profile's **Rankings** section always shows (also with none of your own yet) and ends with
  **Popular cubes**: one row each, "LSV · 528 cards · 3 friends' rankings · 1 yours" (`popularDetail`); a tap opens the
  cube's Rankings (Rank PowerLSV, Yours, Your friends'). Not in View as. Rankings (yours) has the same **Popular cubes**
  section above Sets you can rank. A friend's profile lists their popular-cube rankings like any other.
- Telemetry: `profile_section_opened` `section: popular_cube`; `ranking_created` `subject: popular`.

## Cube changes and telling the owner (John, 2026-10-22)

- **A card leaves the cube:** it's in no list any more, and what it settled still counts (knowledge covers the cube's
  cards and every card in the log), so the rest keep their order. Removing a card can free a place (a final's #4 left)
  or shrink a top half: that list then asks one more screen.
- **A card joins:** it waits outside the lists until it's placed ("New in the cube, not placed yet"), so a sorted list
  never empties; the next screens place it, mostly placement screens against what you've sorted. In a list with
  nothing placed yet, new cards are just part of what's left. Adding a card can lengthen a top half by one place.
- **Baseline:** each ranking keeps the cube's cards it last caught up with (`cube_rankings.baseline`, returned by
  `cube_ranking_get`). New = the cube's cards less the baseline; removed = the baseline less the cube's.
  `cube_ranking_catch_up` (the maker) sets it to the cube as it is now: clients call it once every new card is placed
  (nothing waiting in any list), and from **OK** when only cards left. Existing rankings took their cube as it was on
  2026-10-22.
- **Callout** on the ranking: "<Cube> changed since you ranked it: 3 cards joined (…) and 2 cards left (…). Removed cards
  are off your lists. Re-rank to place the new cards: you're only asked about them, and your order stays as it is."
  **Re-rank** opens the first list with new cards (colors, then the final); its screen reads "+1 · placing new cards";
  when it's done, **Next: place new cards in Blue** replaces it (Back still returns to the ranking). Watchers see "<Cube>
  changed since <name> last ranked it…" with no button. Tiles say "1 new card to place".
- **Engine:** `session(…, fresh)` returns `waiting` (new cards still live and not placed) and a `top` worked out without
  them; `done` and the screens count every card. Shared case `cubeChange` in `cases.json` (two removed, three added after
  run B; 7 screens put everything back).
- **ranking.started:** when someone else starts a ranking of your cube that you can see (shared with the cube, not Only
  me), or switches one from Only me to shared, you get a push ("<Cube>: <name> is ranking your cube. Tap to watch.").
  At most one per person and cube a week (`t1_private.ranking_notices`), never for your own rankings or across a block.
  The push carries `ranking_id`; iOS opens that ranking (routing in `Library/Bugs.swift` `PushRoutes`).
- Server: migration `20261022160000_ranking_cube_changes.sql`, tests in `97_cube_rankings_test.sql`; applied to live 2026-10-22 with
  John's OK (the three functions it replaces matched live first) and smoke-tested on his ranking in a rolled-back
  transaction (baseline 540 of 540, catch-up, a new ranking's baseline, no push for your own ranking). The push went
  live with `notify-worker` v5 on 2026-10-22 (deployed with the bug-inbox work, commit eff62f7); the iOS tap that
  opens the ranking reaches phones with the next build.

## The engine (all client-side, from the log)

Read `make_cases.py`'s docstring; in short:
- **Log:** `[{s, o: [oracle ids, best first], t?}]`, oldest first. Knowledge is the transitive closure of every screen's
  pairs, applied final screens newest first, then the colors' screens, then picks (each in log order; since 2026-11-07,
  see § Checks in the final); a pair that contradicts what's known is skipped (two devices racing, a pick, or a check
  that overturns an order). It
  covers the cube's cards and every card in the log (a card that left the cube still carries what it settled); jobs
  only hold the cube's cards. Card indexes are those Oracle ids sorted as strings.
- **A job** (a color, or the final over every card) with a target: a card with `target` or more cards known above it is
  out ("below the top N"). The next place goes to the card known to beat every other card still in. Done when the
  target is placed.
- **Next screen:** the cards no card still in is known to beat, fewest known below first, then FNV-1a 32 of
  `"<ranking id>:<job>:<screens in the log>:<oracle id>"`, then index; filled to four with cards whose order against
  every card already picked is unknown, nearest the top first. In the final, cards from colors not yet on the screen
  come first. **Placement screens:** when only two cards qualify, one is shown with up to three cards from below the
  other (the leader, the middle and the end of the run that sits below it), **locked** in their known order; only the
  free card moves.
- **Picks** (`s` = `P`): `o` is the picked card, then the rest of its pack in pack order. Pairs: the picked card over
  each other card. The pack: the cube's cards sorted by FNV-1a 32 of
  `"<ranking id>:P:<picks so far>:<oracle id>"`, then index; the first 15. Disagreements: pack cards known to beat the
  picked card, in pack order. **Let the pick win**: while there's a disagreement, take the first one's shortest why-chain
  and remove its newest screen (at most 30), then append the pick. Knowledge records each screen's skipped
  (contradicted) pairs; a pick's count is its "disagreements" in the pick history.
- **Changes:** after each saved change the client diffs every list's places before and after (colors then the final;
  each by the better of its two places, then card id) and sends the rows with the push: `{s, c, f, to, t, by, n}`
  (`f`/`to` null = not placed; `by` screen / undo / redo / pick / pick_win / settings; `n` the screen number).
- **Redo:** remove one screen from the log; if its cards' order is open again, they're the next screen of that job.
  When other screens already settle everything it did, say "Removing it changes nothing".
- **Undo:** removes the last screen of the job you're in and shows those cards again.
- **Estimates:** screens for a job = ceil(f · log2(n!/(n−k)!) / log2 24), f = 1.55 for a full sort (k ≥ n − 1), 1.66
  for a top-k; the final = ceil(6.0 · log2(ways) / log2 24) (1.78 before the final's checks, 4.9 before 2026-11-13), ways = the number of color sequences for the top N given
  each color's size. "About N to go" is max(1, estimate − screens so far in that job). Tests allow ±1.
- **Why is A above B:** the shortest chain of screens (each screen one link; every pair on a screen counts, earliest
  screen first) that puts A above B, or "No screen has settled these two yet".
- **Compare** two rankings on one list (a color or the final): a card counts when both have placed it, or one placed it
  and the other finished a list that stops short (then it sits at the first place past the cut, and its gap is "at
  least"). Shows how many compared, the average gap (tenths, half up), the ten biggest gaps (ties: the better best
  place, then index) and "In one top half, not the other" (best place first).

## Checks in the final (2026-11-07)

John: "had a user do the ranking and then 30-40 were all white. Do a deeper dive and make sure the ranking logic can be
thorough." Daniel Shea's Pauper Cube top 50 (every card sorted, 694 screens) had places 30–42 all white. Replaying his
log: one final screen put Colossal Dreadmask over Counterspell and Sparksmith; each white card then only had to beat
Dreadmask, so 13 white creatures went above Counterspell, which was never on a screen with any of them. In the five
finished live finals, 26–44% of the cross-color orders among neighbouring places came through a third color like this.

**Simulation** (noisy rankers: each screen sorts by a card's true value plus noise, 540-card cube in Lindmark Cube's color
sizes, colors a little stronger or weaker, 16 rankers; scripts were scratch work, the numbers are here): the old final's
longest same-color run averaged 6.25 against 2.75 in the true order, the worst card sat 31 places off, and 13 of the true
top 50 were missing or 10+ places off. Depth didn't matter (a quarter and every card gave the same final). Half the error
came from the colors' sorts (a card sorted below a weaker one of its color waits behind it, then comes out in a run), half
from the final's detours. Checking every card against every color directly cost 7× the final; checking each color's best
card only, skipping orders that cards of two other colors back up, is what shipped:

| top 50, quarter depth | screens | longest run (truth 2.75) | worst card | 10+ off or missing | wrong pairs |
|---|---|---|---|---|---|
| before | 392 | 6.25 | 31 | 13.3 | 12.6% |
| checks, noisy ranker | 583 | 2.9 | 25 | 8.8 | 9.7% |
| before, consistent ranker | 401 | 3.8 | 13 | 1.8 | 5.3% |
| checks, consistent ranker | 501 | 3.1 | 15 | 2.3 | 4.2% |

**Rules** (reference `make_cases.py` `Support` / `checked` / `check_screen`; `RankSupport` iOS/Android, `Support` web):
- **Apply order:** final screens newest first, then the colors' screens, then picks, each in log order (`applyOrder`).
  With no contradiction this changes nothing. With one, the newer final answer wins over an older final screen and over
  a color's sort, so a check can correct a color's order or a detour. Picks stay last ("Keep my ranking" unchanged).
  A final screen that contradicts the knowledge rebuilds it from the log; any other screen is added on its own.
- **A place is checked** when the card x known to beat everything still in has, for each other color, met that color's
  best card still in (fewest known above it) on a screen; or x, or a card of its color below x by that color's own
  screens, beat a card of the other color at or above that best card on a screen; or cards of two or more other colors
  sit between them (Black Lotus over Minsc & Boo needs no screen of its own). And x met its own color's best remaining
  card on a final screen, when only the color's screens put x above it.
- **Check screen:** x, its own color's next card, then other colors' unchecked best cards nearest the top, one per color,
  up to four. Nothing locked; `check` is true on the session. It shows as "Final · checking #N of the top 50".
- **Lists stay full** (John's pick, 2026-11-07): the final's `top` is every place the log settles, as before; `checked`
  counts the places checked from the top and `done` waits for it to reach the target. A final finished before this keeps
  its 50/100 places and asks its checks (the five finished live finals: about 41–96 screens each if the ranker agrees
  with everything; the lists come out the same then). With only checks left, "about N to go" is the unchecked places.
- **Ends:** every check puts two cards on a screen that never met; other screens only add unknown orders. Finite.
- Shared case: run G (`…000f`, quarter, top 20) answers the final with a taste up to ten places off the colors' (checks
  overturn orders, 3 contradicted pairs, rebuilds); every step carries `check`, every summary `checked`.
- Perf: web lock-in p95 2.5 ms, opening a 733-screen ranking 14 ms (the Support index is kept on the knowledge and
  updated one screen at a time; rebuilt only when a check overturns an order).

## Brief (John, 2026-10-21)

Comparing two rankings shows **In brief** first: 2–4 short sentences (at most about 60 words), written by Claude, on where the two agree and where they
differ — color preferences, mana fixing, archetypes (aggro, tempo, control, combo, ramp, …), cheap interaction versus big
threats, the curve. One per pair, list (a color or the final top N) and ranking state.
- **Edge function `ranking-brief`** (`supabase/functions/ranking-brief/`): `POST {a, b, list}` with the user's token →
  `{brief, cached, model}` or `{brief: null, reason}` (fewer than 5 cards placed by both). It reads both rankings with
  the caller's own token (`cube_ranking_get`), so a brief only ever covers rankings the caller can see; works both lists
  out with the shared engine (`ranking-brief/cubeRanking.ts`, the web module byte for byte, checked by
  `tools/test/engine-parity.sh`); sends Claude per-card rows (name, colors, type, cost, mana made, both places) plus each
  ranking's shape (colors, average mana value, creatures, lands, fixing, cheap spells), the overlap and the biggest
  differences; and asks for one paragraph (structured output). In the top 100, rows are each list's first 50 places plus
  the 10 biggest differences (~4.3k input tokens at most; a color is ~2k).
- **Agreement is computed, not judged:** `overlap.both_rank_near_the_top` lists the cards in both lists' first quarter (at
  least their first 5); the brief starts there and says they agree on little when it's empty or short (Haiku otherwise
  claimed shared taste that wasn't there).
- **No gendering:** the model never sees the players' names or ranking names: they're "Player A" and "Player B", and
  `named()` puts the display names back afterwards (literally, so a `$` in a name stays). A brief that still says
  he/she/him/his/her/hers (`GENDERED`) is sent back once to be rewritten; if the rewrite does it too, nothing is stored and
  the caller sees "The brief came back empty. Try again." The prompt also forbids counts and averages in the text.
- **Mana roles (2026-10-22):** each row says what the card does for the mana: `fixing land` (makes two or more colors
  or fetches), `utility land, not fixing` (Strip Mine, Karakas, Library of Alexandria, Mishra's Workshop…) or `mana
  fixing` (a nonland that fixes); the shape counts fixing lands, utility lands and other fixing apart. The prompt says
  to call a card fixing only when its row does, and to give a card's color only from its colors column (Haiku had
  called Strip Mine and Karakas "fixing lands" and Pyrogoyf blue-black interaction in a live brief).
- **One rewrite (`problems()`):** a brief that genders a player, runs over 72 words, or calls a utility land fixing in
  the same clause (a clause that also says "utility" is fine) goes back once with what to change. Only gendering is
  fatal after the rewrite.
- **Trimming:** at most four sentences and 700 characters, split only at `.`/`!`/`?` followed by a space (a decimal
  never drops text).
- **Model:** `claude-haiku-5-5` at low effort (John, 2026-10-21: not Opus — a short summary of numbers we compute, cached
  per change; under $0.001 a brief). One constant (`MODEL` in `brief.ts`); move to `claude-sonnet-5-5` if briefs read thin.
  No refusal fallback on Haiku: a refusal reads "A brief couldn't be written for these rankings."
- **Cache:** `public.ranking_briefs (a, b, list, input_hash, brief, model, created_by)`; the hash covers both revs and
  settings, both names, the cube's cards, the model and `PROMPT_VERSION` (bumped with every prompt change, so older briefs are written again),
  so a new screen in either ranking writes a new brief next time.
  RLS on, no policies; deleting a ranking deletes its briefs. 60 new briefs per account per day; cached ones always show.
- **Clients:** the brief loads with the comparison and is kept for the session; "Written by Claude from both rankings";
  a failure shows "No brief yet · <reason>. Tap to try again." The demos show a marked sample (no server).
- **Eval mode:** `POST {eval: {cube: [names], list, depth?, top?, a: {by, order: [names]}, b: {by, order}, model?}}` with
  the DB secret (`x-t1-secret`, posted via pg_net like `moderate`'s eval): plays both rankings from those orders, returns
  the brief with the prompt's size and token use, and stores nothing. `model` may be `claude-sonnet-5-5` to compare.
- Tests: `ranking-brief/brief.test.ts` (colors, lists from logs, prompt contents and trimming, agreement list, labels and
  `named()`, paragraph cleaning incl. decimals, the gendered check, cache key, the eval simulation).
- **Live** (v8, 2026-10-21). Eval on a 63-card vintage-style cube with an aggro ranker and a blue control ranker: v1
  called Sol Ring fixing, recited counts and missed red (fixed: fixing defined, minimum 5); v2 claimed shared taste in the
  top 50 that wasn't there (fixed: `both_rank_near_the_top`); v3–v6 gendered players from their names about one brief in
  three (fixed: labels + check + rewrite) and dropped text at "1.5" (fixed: trimming). v8: 8 of 8 briefs (whole cube,
  red ×3, blue, black, lands ×2) accurate, named, ungendered, first try. Haiku: ~2k input tokens for a color, ~4.3k for
  the top 50, ~250 output. Sonnet read slightly richer on the whole cube at ~20× the cost; Haiku stays.
  v10 (2026-10-22, after John found a live brief too long and calling Strip Mine and Karakas fixing): 2–4 sentences,
  at most 60 words, mana roles on every row, the rewrite check. Eval on a 64-card vintage cube (white aggro + utility
  lands vs blue-black tempo + duals and fetches; whole cube, lands, red, and a near-identical pair): 58–70 words (was
  ~125), utility lands never called fixing, duals and fetches called fixing. Left: on a near-identical pair Haiku still
  names a one-place shift as a difference.

## Server

`public.cube_rankings` (RLS on, no policies; RPCs only). Progress columns (`sorted`, `categories`, `ranked`) are what the
maker's client last reported, for list rows; everything else is worked out from the log.

| Call | Does |
|---|---|
| `cube_ranking_create(p_id, p_list_id, p_name?, p_depth='half', p_top=100, p_sharing='cube')` | Starts a ranking; a retry with the same id returns it. Name: trimmed, ≤ 60, blank → "My ranking" (reads as no label, § Names). At most 200 per account. |
| `cube_ranking_update(p_id, p_name?, p_depth?, p_top?, p_sharing?)` | Yours only. |
| `cube_ranking_push(p_id, p_rev, p_keep, p_add, p_sorted?, p_categories?, p_ranked?, p_op_id?, p_changes?, p_count?, p_removed?, p_drop?)` | Saves the log (see **Saving**). Apps send `p_keep` = `p_count` = the log as they last read it, `p_drop` = the screens they took out (matched by session, cards and time, wherever they sit), `p_add` = what they locked in (2–4 distinct known Oracle ids each, or 2–15 for a pick `P`; `s` one of `W U B R G M C L F P`, optional `t` epoch ms; ≤ 1000 per push, ≤ 6000 in all), `p_removed` = how many screens it takes out, and `p_changes` for the change log (≤ 2000 per push; the newest 5000 kept). `p_rev` and `p_count` must match and the push must remove exactly `p_removed` screens, else PT409 (HTTP 409 "This ranking changed on another device": reload and plan again; never 40001, which PostgREST retries in a loop: see migration `20261022120000_ranking_conflict_409.sql`). Apps built before 2026-10-23 send neither `p_count` nor `p_removed` and may remove at most 25 screens. Every removed screen is kept in `t1_private.cube_ranking_removed` (where it sat, which push), and `t1_private.cube_ranking_restore_removed(entry)` puts one push's removals back (support only). A retry with the same `p_op_id` returns the stored result. Migration `20261022180000_ranking_push_guard.sql`. |
| `cube_ranking_delete(p_id)` | Yours only; `{deleted}`. |
| `rankable_cubes()` | Other people's live cubes the caller can see, owned by a friend or someone they've played with: `[{id, name, owner: Person, cards (distinct main-board cards), rankings (that the caller can see), mine (the caller's own)}]`, by owner then name, at most 300. |
| `cube_rankings(p_list_id?)` | A cube's rankings you can see (yours first, then newest) with `cube` and `can_rank`; no cube = all of yours, each with its `cube`. |
| `cube_ranking_get(p_id)` | One ranking with `log`, `changes` and `cube` (`cards`: the main board's Oracle ids, sorted, when you can see the cube; `printings`: Oracle id → the main-board printing the cube holds most copies of, ties the lowest card id, 2026-10-22, migration `20261022130000_ranking_cube_printings.sql`, applied to live 2026-10-22 with John's OK and smoke-tested read-only on his ranking: 540 of 540 cards carry their printing). Every screen, list, pack and the top-100 image draws a card in that printing, else its usual art. |

Ranking row: `{id, list_id, name, depth, top, sharing, screens, rev, sorted, categories, ranked, created_at,
updated_at, mine, by: Person}`. Errors read like the rest of sharing: not yours / not visible / gone = "That's private"
(42501). Deleting the cube deletes its rankings; deleting the account deletes yours. Moderation: a shared ranking's
name is checked like a list name (`ranking_name`; a block makes it Only me, with a notice and one appeal).

### Tighter checks (2026-11-13)

John: "The ranking logic still appears to be grouping colors at the 50-100 levels … Daniel Shea's ranking of the vintage
cube is the best example." Every finished live final of Lindmark Cube still ran in long same-color blocks: Daniel Shea's
top 50 (every card sorted, 825 screens) had places 35–46 all black and 27–32 all white; John Healy's top 100 (a third)
82–100 all lands; John's top 50 34–45 all lands. **All of them were made without the checks:** Daniel ranks on Android,
and the newest Android build on Play (29896900, 2026-11-04) predates them; the others finished before 2026-11-07.

Replaying Daniel's log through the checks above showed two holes they'd still have let through:
- **Cards out of the running were never checked.** A card leaves the running once `top` cards are known above it, even
  when that's only inferred. At place 35 the only cards still in were black ones, Teferi, Atraxa, Nadu and Duress: every
  white, red and green card had been pushed out by the same chains, so the black run was checked only black against
  black.
- **One chain counted as backing.** The black cards' wins over other colors all came from Duress (the bottom of the black
  sort) beating Wheel of Fortune, Urza, Lord High Artificer and Dack Fayden on one final screen, and every chain to Path
  to Exile also ran through one screen (Urza's Saga over Path). "A card of x's color below x beat it" and "cards of two
  other colors between them" both accepted that.

**Rules now** (reference `make_cases.py` `chains` / `Support.unchecked`; `RULES = "2026-11-13"`):
- The final checks x against each other color's best card **not yet placed**, in the running or not (fewest known above
  it among the cards not placed yet).
- That order is checked when x met the card on a screen, or when **two chains of screens that share no card** lead from x
  down to it (vertex-disjoint paths in the graph of screen wins, `won`; at most two are looked for, by augmenting paths).
  No single answer can then carry a run. Pairs found backed are remembered (`backed`): screens only add wins, and a final
  screen that overturns an order rebuilds the knowledge and its support. The same-color check is unchanged.
- The check screen orders its cards by fewest known above among the cards not placed yet.
- Replayed (answering as his log already says), Daniel's final asks 51 checks instead of 45, and the black run is now
  checked two black cards at a time against Path to Exile and Chrome Mox.

**Simulation** (the TypeScript engine, 540 cards in Lindmark Cube's color sizes, 20 rankers per row, each screen sorted
by a card's value plus noise σ; scripts were scratch work):

| | screens | longest run 51–100 (truth 2.55) | 10+ off | missing | worst |
|---|---|---|---|---|---|
| top 50, quarter, σ 0.05: before → now | 507 → 534 | – | 0.9 → 0.2 | 2.5 → 1.6 | 10 → 8 |
| top 100, third, σ 0.05 | 819 → 912 | 3.40 → 3.00 | 3.9 → 2.5 | 3.6 → 2.4 | 15 → 12 |
| top 50, quarter, σ 0.15 | 589 → 666 | – | 7.9 → 6.0 | 6.0 → 4.7 | 28 → 20 |
| top 100, third, σ 0.15 | 1063 → 1236 | 3.10 → 2.80 | 25.6 → 23.1 | 9.1 → 7.8 | 46 → 33 |

Depth still makes no difference to the final (quarter, third and every card gave the same numbers; every card costs ~450
more screens), so a top 50 or 100 doesn't need deeper color sorts. What's left is the ranker's own inconsistency, which
more screens of the same kind can't remove. Also tried and dropped: requiring 4 or 8 other-color cards between (one
screen can still link a card to many), and "two other colors' cards beaten directly" (Duress's answer still carried it).

## The engine as a file (2026-11-13)

John: "can we design the solution in such a way that updates to the cube logic don't require new builds and just require
a server update?" (picked: a downloaded JavaScript engine over a server that picks each screen, which would put a network
wait on every screen and end offline ranking).

- **One engine, published.** `table-1-events-web/src/lib/rankEngine.ts` wraps the TypeScript engine in a JSON interface
  (`T1Rank`: `api`, `rules`, `version`, `open(json)` → handle, `append(h, screen)` → handle, `free(h)`, `session(h, job)`
  → JSON with card ids, `expected(h, job)`, `selfTest()`). `tools/rank-engine/build.mjs` bundles it (ES2019, no host APIs:
  the hash encodes UTF-8 by hand since JavaScriptCore and QuickJS have no TextEncoder), names it by content
  (`rank-<sha256 12>.js`), replays every shared case through the built file in a bare context, and writes
  `manifest.json` `{api, rules, version, file, sha256, bytes}` plus `testdata/cube-ranking/rank-engine.js` for the apps'
  tests. `tools/rank-engine/publish.sh` (with John's OK) uploads the file, then the manifest, to the public `catalog`
  bucket at `engines/rank/`, and reads both back.
- **Native first.** Every engine carries `rules`, the date its rules last changed (cases.json `rules`; each client's tests
  check theirs). A phone uses the file only when the manifest's `rules` are newer than its own engine's, the `api`
  matches (1), the hash matches and the file's own `rules` and `selfTest()` (run D of the shared cases) pass; anything
  else, or no file, is the app's own engine. A build that's current never runs JavaScript.
- **What the file decides:** each job's session (list, next screen, placement, checks, `checked`, `done`) and the
  estimates. Knowledge, why-chains, picks, comparisons and change diffs stay native: the file's sessions come back as
  card ids and are mapped onto the native knowledge, indexed the same way (sorted oracle ids). `RankingState` holds the
  file's state beside its own (iOS `RankEngineState`, freed on deinit; Android keeps the 16 newest handles, an older one
  asked again falls back to native).
- **iOS:** `Library/RankEngine.swift`, JavaScriptCore (one JSContext, calls under a lock). Android:
  `library/RankEngine.kt`, QuickJS (`wang.harlon.quickjs:wrapper-android` 3.2.0, ~1.3 MB per ABI) on one thread of its
  own. Kept in Application Support/RankEngine and files/rank-engine; loaded at launch, the manifest asked for again at
  most hourly when a ranking opens; a ranking opened after a new file arrives uses it.
- **Speed** (Daniel's 825-screen ranking): JavaScriptCore without JIT (as in an iOS app, measured on a Mac) opens in ~360
  ms, a lock-in 10 ms median, ~340 ms when a check overturns an order and the knowledge rebuilds; QuickJS on the Android
  emulator (busy host) opens in 1.7 s, 28 ms median, 670 ms on a rebuild. Hence native first: the cost applies only
  between a rules change and the build that carries it.
- **Changing the rules:** change the reference (`make_cases.py`, bump `RULES`), the TypeScript engine and both native
  engines together as before (their tests read the same cases), build and publish the file: phones on this build or later
  get the new rules at once, and the next builds carry them natively. To pull a file back, publish a manifest whose
  `rules` are the native ones.
- Telemetry `rank_engine_used` {version, rules, from: kept|downloaded}, `rank_engine_failed` {why: api|hash|self_test|load|call}.
- Debug: Android `--es t1RankEngine /data/local/tmp/rank-engine.js [--es t1RankArgs <open args>]` loads a file in QuickJS
  and logs its self test and timings (tag RankEngine).
- Web and the edge functions (`ranking-brief`, `discord-bot`, `ranking-image`) import the TypeScript engine directly, so a
  web deploy or a function deploy is their update.

## Depth (2026-10-23)

A ranking sorts the **top quarter**, **top third** or **top half** of each color, or **every card** (`depth` `quarter` /
`third` / `half` / `full`; a color of n cards sorts ceil(n/4), ceil(n/3), ceil(n/2) or n). New rankings start at a
quarter for a top 50 and a third for a top 100, until the person picks a depth (John, 2026-10-23: "reduce the cards
needed for each section"). The final top N comes out exact at any depth: it places a card only once it's known to beat
every card still in the running, and asks about a card itself when a color has more cards in the top N than it sorted.
Simulated on a 540-card cube with a top 50 (the reference engine): half 609 screens, third 488, quarter 415, a sixth 356,
every one with the exact top 50, also when Blue and Colorless held 29 of the 50. The new screens say "Each color is
ordered until its top quarter is in order; the rest sit below it. The final top 50 still comes out exact: if a color has
more cards in it than that, the final asks about them itself." The shared cases have a quarter run and a third run
(`testdata/cube-ranking/cases.json`, runs D and E). Server: migration `20261022190000_ranking_depths.sql`. Apps built
before this treat an unknown depth as every card (more screens, nothing wrong).

## Names (John, 2026-10-28)

Every ranking was called "My ranking", which said nothing. A ranking is now titled by **who ranked it** ("Mara Quinn");
a name its maker gave it follows as a **label** ("Mara Quinn · Aggro all the way"). Blank and "My ranking" (any case,
trimmed) are not labels, so every existing ranking reads as its person's name without a migration, and old builds keep
working. New ranking has no name field (clients send "", stored as "My ranking"); Settings has **Label (optional)** with
Save label / Remove label (the server refuses a blank name on update, so Remove label sends "My ranking"). The ranking
screen's bar is the title over the cube's name; rows drop the person from their detail; Compare pickers read "You" /
the person, then the label; the Top 100 image's header is the title and its byline "Ranking of <cube> · …"; Delete asks
"Delete this ranking?". Rule: `RankingName` (iOS `Rankings.swift`, Android `Rankings.kt`), `rankingTitle` /
`rankingLabel` (web `rankings.ts`), cases `testdata/ranking-names/cases.json` (iOS `RankingNameTests` in
`RankingModelTests.swift`, web `rankings.test.ts`, Android `RankingNameTest`). Client-only.

## Saving (2026-10-23)

Twice in one night (00:17 and 03:03 UTC) an iPhone on build 18/20 wiped a 500-screen ranking. Fast lock-ins sent
overlapping pushes (`defer { saving = false }` let a second push start while one was out); one got a conflict; its
recovery set the app's copy of the server's log to empty before reloading, and a push still waiting read that copy late
(`min(keep, serverLog.count)`) and went out as "keep 0, add 1" with a current rev, which the server took. The ranking was
rebuilt by hand (black, red, multicolor, colorless and lands from the change log, white, blue and green from the screens
redone that night) and the guard went live at 03:13 UTC; the person carried on ranking with no further loss.

Now, on every client (`RankSync.swift`, `rankSync.ts`, `RankSync.kt`; reference `testdata/ranking-save/make_cases.py`,
shared cases `testdata/ranking-save/cases.json`):

- **Nothing is worked out by comparing logs.** The app keeps the server's log as it last read it, plus what was done
  here and not yet saved: *adds* (lock-ins, picks) and *drops* (undo, redo, let the pick win), in order. What's shown
  and what's sent both come from `plan(server, adds, drops)`: the server's log, then each add it doesn't already hold,
  less each drop (one that was only an add here cancels it; one already gone is skipped). Screens leave the log only
  through drops the person made.
- **One push at a time**, `p_keep` = `p_count` = the server's log, `p_add`, `p_drop`, `p_removed`. The server refuses it
  unless its log is that long and the push removes exactly that many screens, so a stale app can only be told to reload.
- **A conflict reloads and plans again**: what's waiting goes on top of the server's log; nothing done here is thrown
  away. "This ranking changed on another device. Your screens were added on top of it." when someone else had changed it.
  After 5 conflicts in a row it stops and retries later.
- **What's waiting is kept on the device** (iOS Application Support `Rankings/pending-<id>.json`, Android
  `filesDir/rankings/`, web `localStorage` `t1.ranking.pending.<id>`) after every change, so a crash, a force-quit, a
  closed tab or no signal loses nothing; the next open of that ranking shows it and sends it. A push's op id is kept with
  it, so a push that landed but whose answer was lost is answered, not applied twice.
- **No signal**: "Not saved yet: … It's kept on this device and saved when Table 1 can." Retries after 2 s, 5 s, 15 s,
  30 s, then every minute while the ranking is open, and on each lock-in.
- **Stale taps are ignored**: Lock in only takes the cards of the screen being shown (a double tap, or Enter before the
  next screen draws, would otherwise lock the old order in again); a pick only takes the pack being shown.
- Telemetry: `ranking_save_conflict` (`waiting`), `ranking_save_failed` (`waiting` / `kind`), `ranking_save_restored`
  (`screens`), `ranking_lockin_stale` (`pick`).
- Tests: SQL `97_cube_rankings_test.sql` (the wipe refused three ways, drops, history, restore), perf
  `perf_10_library.sql` (redo of the first of 6000 by `p_drop`); iOS `RankSyncTests` + `RankingModelTests` (fast lock-ins
  with a conflict mid-burst, undo/redo by name, unsaved work surviving a relaunch offline, a landed push retried, a
  conflict never emptying the log); web `rankSync.test.ts`; Android `RankSyncTest` (the same scenarios against a fake
  server that refuses stale pushes like the real one).

## Where (all clients)

- **Cube screen** (yours, and a cube shared with you on a profile): a **Rankings** row, "3 rankings · yours: 5 of 8
  sorted" or "Rank this cube's cards". Hidden while editing.
- **Cubes** list: a **Rankings** row ("Yours, and friends' cubes you can rank") → your rankings across every cube, then
  **Cubes you can rank** (owner, card count, rankings, how many are yours); tapping one opens that cube's Rankings, where
  **Rank <owner>'s cube** starts your own ranking of it.
- **Rankings** (per cube): **New ranking** (Top half / Every card, Top 100 / Top 50, Shared with the cube / Only
  me), **Yours**, **Everyone else's** (title per § Names, "5/8 sorted · 40/100 ranked", updated Oct 21).
- **Ranking**: one tile per color: state (NOT STARTED / IN PROGRESS / SORTED), a thin bar, "Top 31 of 61 sorted in 59
  screens" or "58 cards · about 95 screens"; **Start** / **Continue** (yours) or **Watch**, and **List**. Then **Final
  · Top 100** ("0 of 100 ranked · about 116 screens left once every color is sorted", plus a note when colors aren't
  sorted). Then **Compare with another ranking…**, **Top 100 image**, and (yours) **Settings**: label, depth, top,
  sharing, Delete. Someone else's ranking re-reads every 10 s while open (every 60 s when nothing changed; yours every
  60 s, for picks made on another device).
- **Screen**: "#24" big, "MULTICOLOR · DECIDING #24 OF THE TOP 36", "23 of the top 36 (71 cards) placed", "Screen 442 ·
  about 22 to go in Multicolor", a progress bar, the cards (phone: 2 × 2 grid, numbered 1–4 in reading order; wide: a
  row of four), **Lock in** and **Undo**. Drag a card to a spot (the others shift), or tap two cards to swap them.
  Locked cards (placement screens) show a lock and can't be picked up; the free card moves around them. Watchers see
  the same screen read-only ("Watching <name>'s ranking live"). Web: keys 1–4 pick up a card, ← → move it, another
  number swaps, Enter locks in, Z undoes. Done: "White sorted" with List and Back.
- **Lists**: tabs Top 100 · White · … · Lands; "1. Card" rows (art thumb, name), then "Below the top 31, in no
  particular order · 30" or "Not placed yet · 12" alphabetically; **Copy list** ("1. Name" lines, then the rest);
  **Compare this list with…**. Tap a card: **its history**: its place, **Why is it above/below…** (picker; defaults to
  the card just above, or below for #1) with the chain of screens, and every screen it was on (number, job, order). On
  your own ranking each screen has **Redo**: "Remove screen 12 and ask about these cards again?".
- **Compare**: two pickers (this ranking / compared with), Swap, list tabs, "Comparing 36 white cards both rankings
  have placed. On average they sit 6.6 places apart; these 10 differ the most." (with "at least" wording when a list
  stops short), rows "Agent Bishop · At least 19 places apart · Ana #13 · Ben: below the top 31", then "In one top
  half, not the other".
- **P1P1** tile on the ranking (after the final): "Refine your ranking: pick one card from a pack. 12 picks · 3
  disagreed". Yours: **Open a pack**; anyone's: **Pick history**. The pack screen: 15 cards (phone: 3 across), tap one,
  **Pick**. Then the verdict: "Agrees with your ranking", "This pick settles 9 orders your ranking hadn't", or the
  disagreement with both cards' places and **Keep my ranking** / **Let the pick win** ("takes out 3 screens; those
  cards come back in White and the final"); then **Next pack**. Pick history: each pick, its pack's best card by your
  ranking, and whether it disagreed.
- **Changes** row on the ranking: the change log, newest first, by day; filter by list. Card history shows the card's own
  changes.
- **Top 100 image**: piles of ten in rank order, each card over the one above so only its name bar shows (the last in a
  pile whole), header with the ranking's title, "Ranking of <cube> · Ranked on Table 1 · <date>". Same
  canvas and save/share paths as the deck image (contract/deck-image-2026-10-20.md).

## Telemetry

`ranking_created` (`depth`, `top`, `sharing`, `own_cube`, `subject`: cube / set), `ranking_pick` (`disagreed`: count, `resolution`: none /
keep / pick_wins, `removed`: screens), `ranking_changes_opened`, `ranking_job_done` (`job`: color key or F, `screens`),
`ranking_check` (`overturned`: the check's answer contradicted an order the log had settled; 2026-11-07), `ranking_undo`, `ranking_redo`, `ranking_compared` (`list`), `ranking_brief_shown` / `ranking_brief_missing` (`list`, `cached`), `ranking_list_copied`, `ranking_image` (`how`),
`ranking_deleted`. Never ids or names.

## Status

- **Tighter checks and the engine as a file (2026-11-13; committed; the engine file published and `ranking-brief` v21 / `discord-bot` v17 deployed 2026-11-13; web and app builds not yet):** reference, web, iOS and Android
  engines pass the regenerated cases (web 39 + `rankEngine.test.ts` 5, lock-in p95 2.2 ms; iOS `CubeRankingTests` 10,
  `RankEngineTests` 5; Android `CubeRankingTest` 7, `RankEngineTest` 4, the last through Node). The built file replays
  every shared case in a bare context, in JavaScriptCore on iOS (Simulator) and in QuickJS on the Android emulator
  (`T1-Bars`, Debug hook). Not published (`publish.sh` waits for John's OK); `ranking-brief` / `discord-bot` not
  redeployed with the new engine copy. Phones get the new rules with their next builds; older builds can't load the file.
- Engine: one module per client, all three pass every shared case (`testdata/cube-ranking/cases.json`: three simulated
  rankings replayed screen by screen incl. placement screens and 7 P1P1 picks, comparisons, why-chains, redo, let the
  pick win, change-log diffs, a contradiction, a card that left the cube, estimates). iOS `CubeRankingTests`,
  `RankingModelTests` (save / undo / redo / picks / change log on the demo backend); web `cubeRanking.test.ts`,
  `cubeRanking.perf.test.ts` (540-card cube, 645 screens: open ~19 ms, lock-in p95 ~3.5 ms); Android `CubeRankingTest`.
- Server: migration tested locally (`97_cube_rankings_test.sql`, perf budgets in `perf_10_library.sql`, every DB test
  passes) and **applied to live 2026-10-21** with John's OK, after checking the functions it replaces matched live
  (post-apply definitions match the file); smoke-tested in a rolled-back transaction (create, push, pick, get, owner
  visibility, rankable cubes, moderation queue). `ranking-brief` deployed (v8, `verify_jwt` off; it checks the token itself).
- iOS: built, checked in the Simulator demo (`-T1LibraryDemo rankings|ranking|rankpick|rankfinal|ranklist|rankcard|
  rankcompare|rankimage|rankpack|rankpicks|rankchanges|rankmine|rankfriend`, the last two for ranking Mara's cube, which isn't yours; the demo plays two friends' full rankings on the fixture's cube,
  so it takes ~30 s to open in Debug). Drag and tap were not tried by hand (no simulator input this session).
- Web: built and checked in `/library/rankings?demo` → Mara's Legacy Cube → Rank Mara Quinn's cube → Start, and in `/library/cubes?demo` → Vintage Cube → Rankings (keys, lock in, undo, a disagreeing pick with
  Let the pick win, change log, compare). The demo's writes stay in memory and reset on reload.
- Android: built and unit-tested, not run on a device.
- Not yet used by a signed-in client on any platform.
- **Outage 2026-10-22:** stale pushes raised 40001, which PostgREST retries in a loop holding a connection; from 04:57 to
  13:55 one loop, then ~20, used up the API's pool and every request on the project timed out (504, PGRST003). Fixed live
  in place at 13:55 by raising PT409 instead (migration `20261022120000_ranking_conflict_409.sql` records it, applied to the migration history afterwards with John's OK; a stale push smoke-tested to PT409 with nothing written); clients
  treat PT409 like 40001 (Android matches the message). `30_security_test.sql` fails if any function raises 40001/40P01.
  Why the pushes were stale: a push that timed out on the phone had landed, so the next one carried an old rev.
