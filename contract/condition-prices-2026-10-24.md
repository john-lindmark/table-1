# Prices follow condition (2026-10-24)

John, 2026-10-24: "Card pricing across the app should respect the condition of the card." Until now every price
was the near-mint market price whatever condition a copy was in (`contract/trades-2026-10-16.md` § Prices).

## Rule

Market prices stay what Scryfall publishes (TCGplayer market in USD, Cardmarket in EUR), which are near-mint
prices. A copy in another condition is worth a fixed share of that:

| Condition | Share |
|---|---|
| NM | 100% |
| LP | 85% |
| MP | 70% |
| HP | 50% |
| DMG | 35% |

One copy's price = near-mint price in whole cents × share, rounded half up to whole cents, never below 1 cent
when the near-mint price is above 0. No price stays no price. An unknown or empty condition counts as NM. The
same rule applies to USD and EUR. Totals sum the rounded per-copy prices.

Scryfall has no per-condition prices, and TCGplayer's API has been closed to new developers for some years (not
re-checked for this change), so the shares are the usual market discounts. They live in one place per platform (`t1_private.condition_percent` on the server,
`Conditions.percent` / `conditionPercent` in each client), so a real per-condition source could replace them
later without touching screens.

## Where it applies

Anywhere a price belongs to copies that have a condition:

- **Collection value** (server): `collection_apply_as` and the nightly `library_revalue` price each item in its
  condition, so the Library home value, profile value (own profile) and the Collection value widget follow it.
  Changing a copy's condition changes the value at once. The migration revalues every collection once.
- **All cards**: Price sort is the most valuable single copy you own, in its condition; an expanded printing row
  shows its best copy's price.
- **Card detail**: the price in the bar and the details panel are the version in view, in its condition (a new
  version: the condition picked for adds). The details panel says what near mint would be when it isn't NM:
  "$8.50 · LP (NM $10.00)".
- **Binders**: binder value and rows.
- **Trades**: each give/get line, the side totals and the difference, and "Want · over your max" on a get.
- **Trade matches** (server): each copy's price, whether it's over your max, and the have/want values.
- **Change printing**: for an owned copy or a trade get, each printing's price is in that copy's condition.
- **CSV import preview**: the value of what will be added.

Unchanged, because no copy is involved (near mint): deck and cube lines and Stats price, Wants (max price is
compared with the copy that meets it), Missing, search and Add cards results, Scryfall `usd>` queries, the redraft
pile and the deck image.

## Server

Migration `20261024120000_condition_prices.sql`: `t1_private.condition_percent(text)`,
`t1_private.condition_price(numeric, text)`, and copies of `collection_apply_as` (from `20261017140000`),
`library_revalue` (from `20261015120000`) and `trade_matches_for` (from `20261018150000`) with only the price
wrapped; then `select t1_private.library_revalue()`. No RPC changes shape. `card_prices_get` still returns
near-mint prices; clients apply the rule.

## Tests

Shared cases `testdata/condition-prices/cases.json` (shares, rounding, totals). Database
`supabase/tests/42_condition_prices_test.sql` (cases, value on add / condition change / undo, revalue) and
`80_friends_sharing_test.sql` (an HP copy comes in under a max price). iOS `ConditionPriceTests`, web
`conditionPrice.test.ts`, Android `ConditionPriceTest`.
