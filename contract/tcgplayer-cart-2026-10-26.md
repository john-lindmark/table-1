# Buy on TCGplayer (2026-10-26)

Put your wants, or what your decks and cubes are missing, into a TCGplayer cart in one tap, then run TCGplayer's
Cart Optimizer there. Server: migration `20261026070000_tcgplayer_cart.sql`; tests
`supabase/tests/75_tcgplayer_cart_test.sql`, budget in `perf_10_library.sql`. Builds on
`contract/binders-wants-2026-10-17.md` (wants, Missing) and `contract/want-prices-2026-10-26.md`.

## Decisions (John, 2026-10-26)

- **TCGplayer Mass Entry, then the user optimizes.** We open TCGplayer's Mass Entry with the list filled in; the user
  picks Normal or Foil and a condition there, taps **Add to Cart**, and runs **Optimize** on the cart. TCGplayer has
  no way for another site to run the optimizer, so the app says to tap Optimize.
- **The whole link is the server's** (`tcgplayer_cart`): card names, set and number, encoding, parts and the link
  around it, so an affiliate link (coming) or a change at TCGplayer needs no app update.
- **Affiliate link (live 2026-11-06):** `tcgplayer.link` in `t1_private.settings` (default `{url}`) wraps every
  Mass Entry and product link. John's Impact tracking link, set by migration `20261106120000_tcgplayer_affiliate.sql`:

  ```
  https://partner.tcgplayer.com/c/8048898/1780961/21018?subId1={platform}&subId2={from}&partnerpropertyid=9068666&u={url_encoded}
  ```

  `{url}` is the TCGplayer address as is, `{url_encoded}` encoded for the redirect's `u`. Checked in a browser
  2026-11-06: Impact answers 301 to the exact address with its click id (`irclickid`, `utm_source=impact`) added,
  and Mass Entry fills in. Clicks and sales split by tag in Impact's reports:
  - `{platform}`: `ios` / `android` / `web` / `unknown`, from the Supabase library's `x-client-info` header
    (`t1_private.client_platform()`: supabase-swift, supabase-kt, supabase-js), so every build is tagged.
  - `{from}`: the screen, `p_from` on `tcgplayer_cart`: `wants`, `missing` (later `card`, `deck`, …; any
    `^[a-z][a-z0-9-]{0,23}$`), else `unknown` (builds before 2026-11-06 send none).
  - No account ids or anything personal in a tag.

  **Impact refuses a link over ~8,200 characters** (2026-11-06: 8,218 redirected, 8,272 answered 400), and wrapping
  makes a Mass Entry address about 1.4× longer, so parts are cut by the finished link's length too:
  `tcgplayer.max_link` (default 8000) beside `tcgplayer.max_url` (6000, the Mass Entry address itself).
- **Off switch:** `tcgplayer.enabled` = `false` hides the rows everywhere at the next load (the RPC answers
  `enabled: false`). Also `tcgplayer.massentry` (the address), `tcgplayer.product` (the product page address the id follows, default `https://www.tcgplayer.com/product/`) and `tcgplayer.max_url` (6000).

## The Mass Entry address (checked in a browser 2026-10-26)

`https://www.tcgplayer.com/massentry?productline=Magic&c=<line>||<line>||…`, each line URL-encoded
(encodeURIComponent; `||` between lines stays as is). It opens Mass Entry with Magic picked and the list filled
in; checked with commas, apostrophes, `//`, `[SET] number` and `Æ`. Lines: `<qty> <name>` (§ Printings says where a
printing goes). Names follow TCGplayer's product names, checked in its search:
split cards whole ("Fire // Ice"), every other card with two names by its first ("Delver of Secrets",
"Bonecrusher Giant"). Printing (Normal/Foil) and condition are options for the whole list on TCGplayer, not per
line, so foil wants come in as whatever's picked there.

## Printings (2026-10-28)

Add to Cart failed for John's wants with "Something went wrong": Mass Entry adds nothing when any one line fails
(`mpgateway…/cart/massentry/addtocartandretrieve` answers `success: false`), and `<name> [SET] <number>` lines failed
often. Checked one line at a time against that call on 2026-10-28:

- TCGplayer names many printings with a suffix: "Sire of Seven Deaths (Borderless) [FDN] 292" adds that printing,
  "Sire of Seven Deaths [FDN] 292" matches nothing. Our catalog has no TCGplayer product names.
- Presales have no listings at all (Thoughtseize SLD 2705), so no line for them can succeed.
- Copies listed with seller photos can't be added by Mass Entry: every NM Beta Mox Ruby that day was one, so
  "Mox Ruby [LEB]" found only a Damaged copy, and nothing at all in NM–MP.
- Plain names always matched, but then TCGplayer picks the printing (a Beta Mox want came in as 30th Anniversary).

So (John's pick): **Mass Entry gets card names only, and a want for a printing becomes a link to that printing's
TCGplayer product page**, where every listing shows, photo ones too. Product ids are Scryfall's `tcgplayer_id`
(`tcgplayer_etched_id` when that's all there is), kept per printing in `t1_private.card_tcgplayer` by `cards-sync`
v11 (migration `20261028200000_tcgplayer_products.sql`). A printing with no TCGplayer product (yet) goes into Mass
Entry by name. Apps from before (no `p_products`) get Mass Entry by name for everything, so their carts fill too.
A name TCGplayer doesn't list would still fail the whole Mass Entry cart.

## RPC (authenticated; anon is refused)

| Call | Does |
|---|---|
| `tcgplayer_cart(p_items, p_products default false, p_from default null)` | `p_items`: `[{oracle_id?, card_id?, qty}]`, up to 2000, qty 1–999 (22023 otherwise). A `card_id` is that printing; an `oracle_id` alone is any printing. Returns `{enabled, lines, unknown, urls, products}`. `urls`: Mass Entry, `<qty> <name>` lines, the same card twice summed. With `p_products` (apps from 2026-10-28) a printing with a TCGplayer product is left out of Mass Entry and comes in `products` instead: `[{card_id, name, set, number, qty, url}]` by name, then set and number, `url` its product page (`tcgplayer.product` + id, wrapped by `tcgplayer.link` like the urls), the same printing twice summed; without it `products` is empty and every printing goes into Mass Entry by name (§ Printings). `lines` counts Mass Entry lines; lines go A–Z, cards the catalog doesn't know are counted in `unknown` and left out, and a long list is split into parts no longer than `max_url`, and no longer than `max_link` once wrapped (each part adds to the same TCGplayer cart). `p_from` tags the affiliate link (§ Decisions). `enabled: false` → no urls. Signed out: 28000. |

## Clients

**Since 2026-11-06 the Wants and Missing rows open the Buy screen** (`contract/buy-2026-11-06.md`: options, cards,
price − owned = total, then Buy on TCGplayer); decks, cubes and the card page buy too. What follows is the tap's
link and menu rule, which the Buy screen keeps.

- **Wants screen:** a **Buy on TCGplayer** row under Price alerts, when you have wants and it's enabled: detail
  "N cards into a cart, then Optimize" (N = wanted copies). Sends every want (qty; its printing when it has one).
- **Missing from decks and cubes:** a **Buy missing on TCGplayer** row at the top of the section, when anything is
  missing, detail "N cards into a cart, then Optimize": sends each Missing line's printing and copies short (basic lands are never missing).
- **Tap:** when the answer holds one link (one Mass Entry part, or one product page) it opens straight away in the
  browser (iOS and Android: the system browser, so the TCGplayer sign-in and cart are the user's own; web: a new
  tab). More links open a Table 1 menu "Buy on TCGplayer" (the menu closes after a pick; tap Buy again for the next):
  Mass Entry parts first, "Part 1 of 3" … "Adds to the same cart" when there are no product pages, else "Any
  printing" "Into one cart, then Optimize" (or "Any printing · part 1 of 2" "Adds to the same cart"), then one row
  per product page: the card's name, "LEB 265 · 1 copy · its own page". Android's menu rows have no detail line, so
  they read "title · detail". Cases `testdata/tcgplayer-cart/cases.json` (`TCGplayerCartTests`, `wantPrices.test.ts`,
  `TCGplayerCartTest`). Cards the server doesn't know (`unknown`, only cards newer than
  the server's catalog) are left out. No urls: "Nothing to buy". Errors show as the screen's error.
- **Tags:** the call sends `p_from` = `wants` / `missing` (the same value as telemetry's `from`); builds before 2026-11-06 send none. A build that sends `p_from` needs the 2026-11-06 server (PostgREST finds no function otherwise).
- **Telemetry:** `tcgplayer_cart_opened` (`from`: wants / missing, `lines`, `parts`, `products`). No card names.
- **Demo:** the rows show; a tap says "Sign in to build a TCGplayer cart" (the demo has no account).
