# Want prices: trend and price alerts (2026-10-26)

The Wants list shows whether each want's price is going up or down, and a push says when a want got meaningfully
cheaper or fell to your max price. Server: migration `20261026060000_want_prices.sql`; tests
`supabase/tests/74_want_prices_test.sql`, budgets in `perf_10_library.sql` (`price_days_take`, `wants_prices`,
`want_price_digest`). Push copy in `supabase/functions/notify-worker/want-price.ts` (tests `want-price.test.ts`).
Shared client rules `testdata/want-prices/cases.json` from `make_cases.py`. Builds on
`contract/binders-wants-2026-10-17.md` (wants) and `contract/trades-2026-10-16.md` (prices).

## Decisions (John, 2026-10-26; the numbers are first picks, easy to change)

- **Source: market price now, listings later.** John asked for TCGplayer *listings*. We only have TCGplayer's
  market price as Scryfall publishes it (one near-mint number per printing and finish, refreshed nightly), with no
  history and no individual listings. Reading listings needs TCGplayer API keys, and TCGplayer no longer gives new
  developers access; scraping their site breaks their terms. So this version keeps its own daily history of the
  market price and alerts on that. § Later says where a lowest-listing source would plug in.
- **A want's price** is the cheapest near-mint price among what it takes: any printing = every English printing,
  any finish; a printing = its finishes; a printing + finish = that one. (Non-English printings are left out of any
  printing: their prices are rare and odd.)
- **History** starts when a card is wanted: every printing of every wanted card gets one row a day, kept 120 days.
  A newly wanted card shows no trend until there's a day behind it, and no 30-day average until there are 7 days.
- **Trend (Wants list):** now vs the oldest price of the last 7 days: "▼ 8% this week" (or "in 3 days" /
  "since yesterday" while the history is shorter). Moves under 5 cents, or that round to 0%, read "Flat".
- **Price alert** (`want.price` push), checked once a day at 16:05 UTC:
  - **Drop:** now at least **15%** and at least **$1** under the want's 30-day average (needs 7 days of history).
    At most once per want every **7 days**; within 30 days of the last push it also has to be **5%** under the
    price last pushed (so a flat-low price doesn't repeat).
  - **Under your max:** now at or under the want's max price. Once per crossing: it pushes again only after the price
    has gone back over the max.
  - One push per account a day, listing the wants (under your max first, then the deepest drop).
  - On by default; **Price alerts** on the Wants screen turns them off for the account (mutes the `want.price`
    kind). Not demo or deleted accounts.

## RPCs (authenticated; anon is refused)

| Call | Does |
|---|---|
| `wants_prices()` | `{alerts, items: [WantPrice]}`: your wants with qty > 0. |
| `want_alerts_set(p_on)` | Price alerts on or off. Returns `{alerts}`. Same value = no change, no audit row; a change is audited in `account_audit` (`want_alerts.set`). Null: 22023. |

```
WantPrice: {oracle_id, card_id | null, finish | null,      the want's key, as in library_changes
            now | null, now_card_id | null, now_finish | null,   cheapest price now, and which printing/finish
            then | null, then_days | null,                 the oldest price of the last 7 days, and how many days ago (1–7)
            avg30 | null}                                  mean of the last 30 days; null under 7 days of history
```

Prices are near mint (wants don't have a condition). Signed out: 28000.

## Server

- `t1_private.price_days (card_id, day, usd, usd_foil, usd_etched)`: `t1_private.price_days_take()` (pg_cron
  `t1-price-days`, 03:15 UTC, after the 23:23 catalog sync) copies `card_prices` for every printing of every
  wanted card; the same day again refreshes it. Rows older than 120 days are removed.
- `t1_private.want_prices_of(user | null, today)`: each want's now / then / avg30 (one account, or all).
- `t1_private.want_price_digest()` (pg_cron `t1-want-prices`, 16:05 UTC): applies the rules above and keeps per
  want the price and time of its last push and whether it was under its max (`t1_private.want_price_alerts`).
- Deleting your account clears `want_price_alerts`; your wants go with the account as before.

Push (`notify-worker`): `want.price`, `data: {n, names (up to 3, under your max first, then the deepest drop),
name, price, pct, reason: drop | under_max, max}` (name … max describe the first). Title "Price alert" (one) /
"Price alerts". Body (`want-price.ts`): "Counterspell is $7.50, 25% under its 30-day average." / "Lightning Bolt
is $1.40, under your max of $1.50." and with more: "… Also cheaper: Opt, Ponder and 3 more." Thread `wants`;
priority 5. iOS only (Android push waits for FCM).

## Clients

- **Wanted rows** (Wants screen): detail "<which printing> · Max $10.00 · Now $12.40" (any printing says **From**
  instead of Now), and the trend on a line of its own under it, "▼ 8% this week" (it was cut off at the end of
  the detail on a phone). The trend is drawn in the accent when the price went down (good news for a buyer), muted
  when up or flat. Prices come from `wants_prices` (falling back to the session's prices for a
  specific printing until it answers, with no trend); nothing at all without a price.
- **Price alerts** row on the Wants screen, under Add a want: a Table 1 switch (On / Off), detail "A push when a
  want gets 15% cheaper or reaches your max". Hidden signed out.
- **Push tap** (`want.price`): opens Wants on the Collection tab (iOS).
- **Rules** (`WantPrices.trend` / `.detail` / `.money`), against `testdata/want-prices/cases.json`: work in whole
  cents so a half percent rounds the same everywhere. Client tests: iOS `WantPricesTests`, web `wantPrices.test.ts`,
  Android `WantPricesTest`.
- **Telemetry** (no ids): `want_alerts_changed` (`on`), `want_prices_loaded` (`wants`, `with_trend`, `down`, `up`).
- **Demo:** iOS Debug `-T1LibraryDemo wants` (seeded prices and trends); web `/library/wants?demo`.

## Later: listings

If TCGplayer API access (or another source of live listings) comes through, a daily or hourly reader would keep
`t1_private.listing_lows (card_id, finish, condition, low, seen_at)` for wanted printings, and the digest gains a
third reason, `listing`: the lowest near-mint listing at least 15% and $1 under the market price (same cooldowns).
Wants would then show "Lowest listing $X". Nothing else changes: the trend stays on the market price.
