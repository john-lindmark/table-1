# Plan: Spice, how far a deck or cube is from its peers (2026-10-28)

**Status 2026-10-28: agreed as proposed (John), built, not live.** Contract `contract/spice-2026-10-28.md`, migration
`20261028160000_spice.sql` (not applied: waits for John's OK), clients on iOS, web and Android. Differences from this
plan as built: a deck reads daily per-archetype card counts (`spice_counts`, pg_cron) instead of the lists themselves
(a deck took 120 ms locally; now 2.5 ms); one identical list is left out (the year's newest), not every identical
one; "Stock cards you don't play" is left out when the comparison is the whole format; shared decks and cubes get a
Spice row that opens the section in place. Cubes wait for Cube Cobra (note to them in
`table-1-context/docs/cubecobra-request-2026-10-28.md`, not sent).

Every deck and cube gets a **Spice** score, 0–100: the share of its cards that decks or cubes like it rarely or never
play. A stock Boros Energy list scores about 1. A list with a few personal picks scores 10–20. A real brew scores 50 or
more. The score comes with the cards that make it spicy ("Ancient Grudge: in 2 of 412 lists") and the stock cards the
list doesn't play.

## 1. What "similar" means and where the data comes from

**Decks: Insights' tournament decklists (already ours).** `t1_private.meta_decks` holds every MTGO and TopDeck.gg
list as Oracle ids with an archetype label. Live on 2026-10-28, last 90 days:

| Format | Lists (90 d) | Archetypes with 20+ lists | Other (unlabelled) |
|---|---|---|---|
| Modern | 7,026 | 26 | 828 |
| Pauper | 4,269 | 20 | 416 |
| Standard | 3,651 | 15 | 851 |
| Pioneer | 2,036 | 18 | 375 |
| Canadian Highlander | 80 (153 in a year) | 0 | 3 |

Peers of a deck, in order:
1. **Its archetype**: `meta_label` on the deck's main deck + sideboard (the same rules as Insights), with 30+ lists in
   90 days (else 365 days).
2. **If it labels as Other or its archetype is too thin, the closest archetype**: the one whose lists play the most of
   the deck's cards (copies × main-deck rate, averaged). If even the closest one plays under 25% of the deck, there's
   no close archetype: the deck is compared with the whole format and the screen says "Nothing like this in Modern's
   last 90 days".
3. **Singleton formats (Canadian Highlander)**: 100-card singleton lists share too few cards for archetypes at this
   volume, so each card is compared with the year's lists **that could play it** (deck colours include the card's
   colour identity). Measured on all 153 lists, each left out of its own comparison: median 9, top 10% from 30.

No score for formats without tournament data (Commander, Oathbreaker, Legacy, Vintage, Premodern, cube decks, other).
The row says so. Commander could later use EDHREC (§ 6).

**Cubes: no usable corpus yet.** Table 1 has 3 live cubes, too few to compare with. Cube Cobra has hundreds of
thousands, and its search lists them by popularity with every card as an Oracle id. But **its terms forbid "data
mining, data harvesting, data extracting"**, so we can't build a corpus from it without permission. A one-off test of
the method on 36 popular Cube Cobra cubes (fetched once for this plan, then deleted) gave sensible results: MTGO
Vintage clones 0–6, LSVCube 1, and cubes with no peer in such a small sample (Commander, Battle Box, pauper) 55–80. A
real corpus of about 1,000 cubes would give them peers. The options are in § 7.

With a corpus, a cube's peers are **its 20 nearest cubes** by Jaccard overlap of non-basic Oracle ids, each weighted
by its overlap. If the nearest overlaps under 15%, the screen says "No cubes much like this one".

## 2. The score

For each non-basic card, take **r**, its play rate among the peers: the share of peer lists with the card in the main
deck (decks) or the share of peer cubes holding it, weighted by overlap (cubes). Then:

- card spice `s = max(0, 1 − r / 0.25)` (0.10 for singleton formats). A card in a quarter or more of peer lists is
  stock (0). Below that it gets spicier, up to 1 for a card never seen.
- **Spice = 100 × Σ copies × s ÷ Σ copies** over the non-basic cards of the main deck plus commander (decks) or the
  main section (cubes). Basics never count. Sideboard cards are listed with their sideboard rate but don't score.
- A deck never counts itself: when a user's list is also in the corpus (a copied Insights example), it's left out.

Measured on 1,500 random live lists, each scored against its own archetype:

| Format | Median | Top 10% from | Top 1% from |
|---|---|---|---|
| Modern | 1.0 | 8 | 53 |
| Pauper | 1.9 | 20 | 45 |
| Pioneer | 0.6 | 11 | 40 |
| Standard | 1.5 | 12 | 40 |

So the words are **Stock** (0–9, nine in ten tournament lists), **Tuned** (10–24), **Spicy** (25–49) and **Brew** (50+).
The plain "1 − r" average was rejected: it gives stock lists 11–15 because every flex slot counts. A hard "under 10%"
count was rejected too: it gives 0 to half of all lists and jumps at the line.

## 3. Where it shows

- **The deck or cube screen's Stats row** gets the score in its one-line summary: "24 lands · avg MV 1.72 · $1,535 ·
  Spice 34". Hidden for formats with no data.
- **Stats → Spice**, a new section: the score and its word, what it was compared with ("412 Boros Energy lists, last
  90 days · MTGO and TopDeck.gg", or "20 cubes most like yours" with their names), then **Spiciest cards** (copies,
  peer rate, "never seen"), then **Stock cards you don't play** (cards in half or more of the peer lists, missing from
  the main deck). A tap on a card opens its card page. Shared decks and cubes (profile, link) show the same.
- No push and no ranking of players by spice.

## 4. Server or client

**Server.** Labelling uses Insights' archetype rules, which live only in the database, and the per-card rates need
every list of an archetype, not the 20%+ cards the pack carries. Shipping rules and full rate tables to the devices
would duplicate the labeller three times and grow every pack. One RPC gives the same answer on all three clients.

- `list_spice(p_list_id uuid)` → `{ kind, basis: { kind: "archetype" | "closest" | "format" | "colors" | "cubes",
  format, archetype, name, lists, days, sources | cubes: [{ name, overlap }] } | null, score, word, cards: [{ c, n,
  copies, rate, seen, section }], stock_missing: [{ c, n, rate }], reason }`. `reason` says why there's no score
  ("no_data" for a format without lists, "empty"). Reads the list's current version. Anyone who can see the list
  (`t1_private.item_visible`) may call it. Others and unknown lists get the same refusal.
- Results are cached per list version and corpus day (`t1_private.list_spice`), so opening Stats twice costs one
  computation. Perf budget in `perf_10_library.sql`: 40 ms for a 60-card Modern deck against a year of Modern.
- Read-only: no audit row (nothing changes), and it never raises 40001/40P01.
- Cubes: `t1_private.cube_corpus` (source, source id, name, size, overlap index) filled by a weekly sync, once § 7
  allows one.

## 5. How it's built (project rules)

1. Contract `contract/spice-2026-10-28.md`. Shared cases in `testdata/spice/cases.json` from a Python reference
   `testdata/spice/make_cases.py` (peers, rates, closest archetype, singleton colours, the score, words, edge cases:
   all basics, an empty deck, a card never seen, a thin archetype, a list that is also in the corpus).
2. Server: migration with `list_spice` + cache. Tests in `supabase/tests/66_spice_test.sql` (the reference cases,
   happy path, another account's private deck refused, a shared deck allowed, an unknown list refused, a cache hit on
   a retry). Perf budget. **Applying it waits for John's OK.**
3. iOS: the Stats row and the Spice section, decoding tested against fixtures from the cases (`SpiceTests`), demo
   `-T1LibraryDemo spice`. Then web (`spice.test.ts`, `/library/list/:id/stats?demo`), then Android (`SpiceTest`), in
   one batch.
4. Telemetry: screen `deck_spice` / `cube_spice`; event `spice_viewed {kind, format, basis, word}` (the word, not the
   score or the cards).
5. Figma after the build; the Feature Guide on merge.

The deck screen files are being changed by the command zone session right now. The Stats row edit waits until that
work is committed.

## 6. Later

- Copies as well as presence: four copies of a card the archetype runs as a one-of.
- Commander and Oathbreaker against EDHREC averages for the same commander (needs their terms checked too).
- Spice over time in a deck's history.
- Table 1's own shared cubes join the cube corpus once there are enough of them.

## 7. Questions for John

1. **Cubes.** (a) Decks first, cubes once Cube Cobra says yes. I draft a short note to Cube Cobra's maintainers asking
   to read popular public cubes weekly, with credit and a link back. (b) Cubes wait for Table 1's own shared cubes
   (years at today's numbers). (c) No cube spice.
2. **Name and words.** "Spice" with Stock / Tuned / Spicy / Brew, or other words.
3. **Canadian Highlander.** Score it with the colour-based comparison and a "153 lists in a year" note, or leave it out
   until TopDeck has more.
4. **Sideboard.** Listed but not scored (as proposed), or scored at half weight.
