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

## The engine (all client-side, from the log)

Read `make_cases.py`'s docstring; in short:
- **Log:** `[{s, o: [oracle ids, best first], t?}]`, oldest first. Knowledge is the transitive closure of every screen's
  pairs, applied in order; a pair that contradicts what's known is skipped (only two devices racing can cause it);
  cards no longer in the cube are left out. Card indexes are the cube's Oracle ids sorted as strings.
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
  each other card (only while the picked card is in the cube). The pack: the cube's cards sorted by FNV-1a 32 of
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
  for a top-k; the final = ceil(1.78 · log2(ways) / log2 24), ways = the number of color sequences for the top N given
  each color's size. "About N to go" is max(1, estimate − screens so far in that job). Tests allow ±1.
- **Why is A above B:** the shortest chain of screens (each screen one link; every pair on a screen counts, earliest
  screen first) that puts A above B, or "No screen has settled these two yet".
- **Compare** two rankings on one list (a color or the final): a card counts when both have placed it, or one placed it
  and the other finished a list that stops short (then it sits at the first place past the cut, and its gap is "at
  least"). Shows how many compared, the average gap (tenths, half up), the ten biggest gaps (ties: the better best
  place, then index) and "In one top half, not the other" (best place first).

## Brief (John, 2026-10-21)

Comparing two rankings shows **In brief** first: 2–5 sentences, written by Claude, on where the two agree and where they
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
- **Trimming:** at most five sentences, split only at `.`/`!`/`?` followed by a space (a decimal never drops text).
- **Model:** `claude-haiku-5-5` at low effort (John, 2026-10-21: not Opus — a short summary of numbers we compute, cached
  per change; under $0.001 a brief). One constant (`MODEL` in `brief.ts`); move to `claude-sonnet-5-5` if briefs read thin.
  No refusal fallback on Haiku: a refusal reads "A brief couldn't be written for these rankings."
- **Cache:** `public.ranking_briefs (a, b, list, input_hash, brief, model, created_by)`; the hash covers both revs and
  settings, both names, the cube's cards and the model, so a new screen in either ranking writes a new brief next time.
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

## Server

`public.cube_rankings` (RLS on, no policies; RPCs only). Progress columns (`sorted`, `categories`, `ranked`) are what the
maker's client last reported, for list rows; everything else is worked out from the log.

| Call | Does |
|---|---|
| `cube_ranking_create(p_id, p_list_id, p_name?, p_depth='half', p_top=100, p_sharing='cube')` | Starts a ranking; a retry with the same id returns it. Name: trimmed, ≤ 60, blank → "My ranking". At most 200 per account. |
| `cube_ranking_update(p_id, p_name?, p_depth?, p_top?, p_sharing?)` | Yours only. |
| `cube_ranking_push(p_id, p_rev, p_keep, p_add, p_sorted?, p_categories?, p_ranked?, p_op_id?, p_changes?)` | Keeps the first `p_keep` screens, appends `p_add` (2–4 distinct known Oracle ids each, or 2–15 for a pick `P`; `s` one of `W U B R G M C L F P`, optional `t` epoch ms; ≤ 1000 per push, ≤ 6000 in all) and `p_changes` to the change log (≤ 2000 per push; the newest 5000 kept). `p_rev` must match (else 40001 "This ranking changed on another device": reload, check the last screen). A retry with the same `p_op_id` returns the stored result. |
| `cube_ranking_delete(p_id)` | Yours only; `{deleted}`. |
| `rankable_cubes()` | Other people's live cubes the caller can see, owned by a friend or someone they've played with: `[{id, name, owner: Person, cards (distinct main-board cards), rankings (that the caller can see), mine (the caller's own)}]`, by owner then name, at most 300. |
| `cube_rankings(p_list_id?)` | A cube's rankings you can see (yours first, then newest) with `cube` and `can_rank`; no cube = all of yours, each with its `cube`. |
| `cube_ranking_get(p_id)` | One ranking with `log`, `changes` and `cube` (`cards`: the main board's Oracle ids, sorted, when you can see the cube). |

Ranking row: `{id, list_id, name, depth, top, sharing, screens, rev, sorted, categories, ranked, created_at,
updated_at, mine, by: Person}`. Errors read like the rest of sharing: not yours / not visible / gone = "That's private"
(42501). Deleting the cube deletes its rankings; deleting the account deletes yours. Moderation: a shared ranking's
name is checked like a list name (`ranking_name`; a block makes it Only me, with a notice and one appeal).

## Where (all clients)

- **Cube screen** (yours, and a cube shared with you on a profile): a **Rankings** row, "3 rankings · yours: 5 of 8
  sorted" or "Rank this cube's cards". Hidden while editing.
- **Cubes** list: a **Rankings** row ("Yours, and friends' cubes you can rank") → your rankings across every cube, then
  **Cubes you can rank** (owner, card count, rankings, how many are yours); tapping one opens that cube's Rankings, where
  **Rank <owner>'s cube** starts your own ranking of it.
- **Rankings** (per cube): **New ranking** (name, Top half / Every card, Top 100 / Top 50, Shared with the cube / Only
  me), **Yours**, **Everyone else's** (name, "<person>'s ranking · updated Oct 21", "5/8 sorted · 40/100 ranked").
- **Ranking**: one tile per color: state (NOT STARTED / IN PROGRESS / SORTED), a thin bar, "Top 31 of 61 sorted in 59
  screens" or "58 cards · about 95 screens"; **Start** / **Continue** (yours) or **Watch**, and **List**. Then **Final
  · Top 100** ("0 of 100 ranked · about 116 screens left once every color is sorted", plus a note when colors aren't
  sorted). Then **Compare with another ranking…**, **Top 100 image**, and (yours) **Settings**: name, depth, top,
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
  pile whole), header with the ranking's name, "<person>'s ranking of <cube> · Ranked on Table 1 · <date>". Same
  canvas and save/share paths as the deck image (contract/deck-image-2026-10-20.md).

## Telemetry

`ranking_created` (`depth`, `top`, `sharing`, `own_cube`), `ranking_pick` (`disagreed`: count, `resolution`: none /
keep / pick_wins, `removed`: screens), `ranking_changes_opened`, `ranking_job_done` (`job`: color key or F, `screens`),
`ranking_undo`, `ranking_redo`, `ranking_compared` (`list`), `ranking_brief_shown` / `ranking_brief_missing` (`list`, `cached`), `ranking_list_copied`, `ranking_image` (`how`),
`ranking_deleted`. Never ids or names.

## Status

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
