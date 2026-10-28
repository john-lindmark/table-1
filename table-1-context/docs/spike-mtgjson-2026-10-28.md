# Spike: MTGJSON as a second price source (2026-10-28)

Question (John): would MTGJSON give us data we've wanted and couldn't get? Prompted also by Mox Sapphire showing no
price. Read-only spike: MTGJSON files downloaded on 2026-10-28 (build 5.3.0+20261028) and compared with live
`cards` / `card_prices` / `collection_items`. Nothing was changed.

## Terms

MIT licence (mtgjson.com/license): free to use, copy, modify, sublicense and sell; keep the copyright notice.
No rate limits or keys. Files are rebuilt daily at about 08:07 UTC.

## Files and sizes

| File | gz | xz | Uncompressed | What it is |
|---|---|---|---|---|
| AllPricesToday | 5.6 MB | 4.3 MB | 54 MB | Today's price per printing × store × retail/buylist × finish |
| AllPrices | 147 MB | 48 MB | (≈ 90 × today) | The same with 90 days of history |
| TcgplayerSkus | 37 MB | | 645 MB | TCGplayer SKU per printing × condition × language × finish |
| AllIdentifiers | 235 MB | | | Every printing; carries `scryfallId` (all 124,856 do) and `tcgplayerProductId` |

MTGJSON keys printings by its own uuid; `identifiers.scryfallId` maps to our `cards.id`. MTGJSON has no separate
foreign-language printings, so its prices map to our English printings only.

AllPricesToday is about the size of a cards-sync bulk step, so a stepped reader like `cards-sync`'s `names` steps fits.
AllPrices and TcgplayerSkus are too big to parse whole in an edge function: they need ranged/streamed reads, or a
one-off load from the Mac.

## Stores in AllPricesToday

| Store | Currency | Printings | Retail | Buylist |
|---|---|---|---|---|
| TCGplayer | USD | 101,615 | yes | **empty** |
| ManaPool | USD | 102,076 | yes | empty |
| Card Kingdom | USD | 99,504 | yes | yes (≈ 46k normal, 36k foil) |
| Cardmarket | EUR | 102,541 | yes | empty |
| Cardhoarder (MTGO) | USD (tix ≈ $) | 63,036 | yes | yes |

MTGJSON's TCGplayer price is the same market price Scryfall gives us (CED Mox Sapphire $647.32 in both), so it has
the same gaps. It has no listings and no lowest listing.

## Mox Sapphire

| Printing | Ours (USD / EUR) | MTGJSON TCGplayer | ManaPool | Card Kingdom retail / buy | Cardmarket |
|---|---|---|---|---|---|
| LEA 265 | — / €20,089.89 | — | — | $22,999.99 / $13,800 | €20,089.89 |
| LEB 266 | — / €7,179.15 | — | $10,211.60 | — / $8,460 | €7,179.15 |
| 2ED 266 | — / €3,577.46 | — | $4,428.50 | — / $5,160 | €3,577.46 |
| CED 266 | $647.32 / €749.57 | $647.32 | $989.90 | — / $720 | €749.57 |
| CEI 266 | — / €849.04 | — | $1,083.66 | — / $650 | €849.04 |

TCGplayer has too few recent sales of Power to publish a market price. **We already hold a Cardmarket EUR price for
every real Mox Sapphire**, but the apps show USD only (EUR left the summary on 2026-10-23), so it reads as unpriced.

## Coverage

- Live catalog: 110,188 printings; **10,013 have no USD price** (8,509 English); 3,121 of those have a EUR price.
- In MTGJSON, 10,789 paper printings lack a TCGplayer price. ManaPool or Card Kingdom (retail or buylist) gives a USD
  price for **4,067** of them; Cardmarket for 3,985; any store for 6,499.
- Owned: 1,600 printings are in collections; **28 have no USD price**. MTGJSON gives 11 of them a USD price,
  including all the Power (Beta Lotus, Recall, Time Walk, Timetwister, Moxen, Unlimited Lotus). The rest are mostly
  Summer Magic, The Reaper King (TRK) lands, Secret Lair (SLZ) and basics, which no store prices.

## Data quality

- Cardmarket in MTGJSON prices Summer Magic Badlands at €0.02, Wheel of Fortune €0.02 and Tundra €0.25. Those cards
  sell for thousands, so the match is wrong (probably to a proxy or reprint product). Any fallback needs a
  sanity guard.
- Stores disagree a lot at the top end (Beta Mox Sapphire: ManaPool $10,212, CK buy $8,460, Cardmarket €7,179). A
  fallback price must always name its store.
- Card Kingdom often has only a buylist price for old cards (out of stock). A buylist price is a floor, not a market
  price.

## What we'd add (ranked)

1. **Converted EUR fallback (no MTGJSON needed).** When a printing has no TCGplayer price, use the Cardmarket EUR we
   already hold, converted to USD at the day's rate (John, 2026-10-28: it must convert). This fixes Mox Sapphire and
   ~3,100 printings now. Design in "Converted EUR fallback" below.
2. **USD fallback from MTGJSON** (new `cards-sync` steps on AllPricesToday). Store the price with its source, in a
   new column or table rather than overwriting `usd`. Order: TCGplayer (Scryfall) → ManaPool → Card Kingdom retail →
   Card Kingdom buylist (marked "buylist"). Skip a store's price that is under 10% of another store's for the same
   printing. Covers ~4,000 more printings, incl. all owned Power.
3. **Trade values from buylists:** Card Kingdom buylist as a "store pays" number in Trades and card detail.
4. **History backfill:** read AllPrices once into `t1_private.price_days` so want-price trends and alerts don't wait
   for our own history (ours started 2026-10-26). One-off load, not a daily read.
5. **TCGplayer SKUs:** exact product/SKU ids by condition/language/finish for a future listings reader or a
   product-ID cart. 645 MB, so load only what wants need, and only once TCGplayer access exists.
6. **MTGO tix (Cardhoarder):** deck cost in tix on Insights' MTGO decks.

Not covered by MTGJSON: TCGplayer listings or lowest listing, Canadian Highlander points, tournament results.

## Converted EUR fallback

John (2026-10-28): a EUR fallback must show as USD.

**Rate.** ECB euro reference rate, published each working day around 16:00 CET, free, no key:
`https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml` (2026-10-28: 1 EUR = 1.1133 USD). Read it in the daily
`cards-sync` run into `t1_private.fx_rates (day, usd_per_eur)`. Keep the last rate on weekends, holidays and failed
reads.

**One place on the server.** Clients get prices only through `card_prices_get`; collection value, trade matches and
want prices read `card_prices` in SQL. Keep `usd` as TCGplayer's price and add one SQL helper,
`t1_private.usd_price(card_id, finish)`: `usd` when present, else `eur × rate` rounded to the cent (normal from
`eur`, foil from `eur_foil`, etched never converted). `card_prices_get`, `collection_apply_as` / `library_revalue`
and `trade_matches_for` go through it. `card_prices_get` returns the converted number in the existing USD slots, so
**builds already on phones show it with no update**. It appends one trailing element, a bitmask of the finishes that
were converted; old apps ignore it, new apps use it to label the price.

**Label.** New builds mark a converted price on card detail: "≈ $7,992.55" in the bar, "≈ $7,992.55 · from
Cardmarket" in the details. Lists, totals and trades show the number with no mark.

**Guard.** Scryfall's Cardmarket links share MTGJSON's bad matches: Summer Magic Badlands €0.02, Wheel of Fortune €0.02,
Tundra €0.25, 30th Anniversary Mox Jet €25. Skip conversion when the EUR price is under 10% of the cheapest USD
price of any other printing of the same card. That skips 32 of the 3,121. It doesn't catch every bad link: Summer
Magic Underground Sea at €280 passes. Open: leave Summer Magic (`sum`) out entirely.

**Want prices.** Want prices, their alerts and trade-wants pushes stay on TCGplayer alone, so a change in the
exchange rate never reads as a price drop.

Built 2026-10-28: `contract/converted-prices-2026-10-28.md`.

**Mox Sapphire at 1.1133:** Alpha ≈ $22,366.07, Beta ≈ $7,992.55, Unlimited ≈ $3,982.79, CE International
≈ $945.24. Collectors' Edition keeps TCGplayer's $647.32.

**Work:** one migration (fx table, helper, the three replaced functions and `card_prices_get`, `cards-sync` reading
the rate), SQL tests (conversion, the guard, unchanged TCGplayer prices, refusals as before), a shared cases file,
then the "≈ · from Cardmarket" label on iOS, web and Android. Collection values are revalued once after the migration
is applied.
