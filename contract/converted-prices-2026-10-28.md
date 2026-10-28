# Converted prices (2026-10-28)

John (2026-10-28): Mox Sapphire showed no price. TCGplayer publishes no market price for Alpha, Beta, Unlimited or
Collectors' Edition International Power (too few sales), but Scryfall gives us Cardmarket's EUR price for each. A EUR
fallback must show as USD. Background and numbers: `table-1-context/docs/spike-mtgjson-2026-10-28.md`.

Migration `supabase/migrations/20261028170000_converted_prices.sql`, tests `supabase/tests/67_converted_prices_test.sql`,
shared cases `testdata/converted-prices/cases.json`.

## Rule

- A printing's USD price in a finish is TCGplayer's market price (via Scryfall, as before). When TCGplayer has none,
  it is the Cardmarket price converted: nonfoil from `eur`, foil from `eur_foil`, `round(eur × rate, 2)`. Etched is
  never converted (Cardmarket has no etched price).
- The rate is the ECB euro reference rate (`https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`), read
  hourly by pg_cron `t1-fx-rate` (`t1_private.fx_tick`, pg_net) into `t1_private.fx_rates` once the newest is 20 hours
  old. The ECB publishes around 16:00 CET on working days. A failed or odd answer (not 200, or a rate outside 0.5–2)
  is ignored and asked again next hour.
- **Guard:** a converted price under 10% of the cheapest TCGplayer price (any finish) of any printing of the same card
  is left out, since some Cardmarket links point at the wrong product (Summer Magic Badlands €0.02). It doesn't catch
  every bad link (Summer Magic Underground Sea €280 passes).
- Converted prices are rebuilt nightly at 00:50 UTC (pg_cron `t1-price-fallback`,
  `t1_private.card_price_fallback_refresh`) into `t1_private.card_price_fallback`, after the 23:23 catalog sync and
  before the 01:07 `library_revalue`. A new TCGplayer price wins at once; its converted row goes at the next rebuild.
  `public.card_prices` is unchanged: it stays what Scryfall sends.

## Where it applies

| Uses converted prices | Stays on TCGplayer only |
|---|---|
| `card_prices_get` (every client price) | Want prices and price alerts (`price_days_take`, `want_prices_of`, `want_price_digest`) |
| Collection value (`collection_apply_as`, `library_revalue`) | Trade-wants pushes under your max (`trade_want_digest`) |
| Trade matches' per-copy prices and "over your max" (`trade_matches_for`) | Buy on TCGplayer |
| Redraft pile order and total (`redraft_list`) | |

Server functions read `t1_private.card_prices_usd`, a view of `card_prices` with the gaps filled. Want prices stay on
TCGplayer so a change in the exchange rate never reads as a price drop.

## Wire

`card_prices_get(p_card_ids)` → `[[card_id, usd, usd_foil, usd_etched, eur, eur_foil, converted], …]`. The USD slots
hold the converted price when there is one; `converted` is a bitmask of the converted finishes (1 nonfoil, 2 foil).
Builds already on phones read the first six elements, so they show converted prices with no update, unlabelled.
A row from an older server has six elements: nothing is converted.

## Clients

`PriceBook.converted(cardId, finish)` / `convertedPrice(cardId, finish)` (web) reads the bit. Card detail marks a
converted price: the bar shows `≈ $7,992.55`, and the details' Price row reads `≈ $7,992.55 · from Cardmarket`
(in another condition `≈ $7,193.30 · LP (NM $7,992.55) · from Cardmarket`). Lists, totals and trades show the number
as it is, with no mark.

Tests: iOS `ConvertedPriceTests`, web `convertedPrice.test.ts`, Android `ConvertedPriceTest`, all reading the `rows`
cases.
