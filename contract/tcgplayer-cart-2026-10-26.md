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
- **Affiliate link:** `tcgplayer.link` in `t1_private.settings`, default `{url}`. When the affiliate link arrives:

  ```sql
  insert into t1_private.settings (name, value)
  values ('tcgplayer.link', 'https://partner.tcgplayer.com/c/<id>/<ad>/<campaign>?u={url_encoded}')
  on conflict (name) do update set value = excluded.value;
  ```

  `{url}` is the Mass Entry address as is, `{url_encoded}` encoded for a redirect's parameter (the exact shape comes
  with the affiliate program's link; check one in a browser before setting it).
- **Off switch:** `tcgplayer.enabled` = `false` hides the rows everywhere at the next load (the RPC answers
  `enabled: false`). Also `tcgplayer.massentry` (the address) and `tcgplayer.max_url` (6000).

## The Mass Entry address (checked in a browser 2026-10-26)

`https://www.tcgplayer.com/massentry?productline=Magic&c=<line>||<line>||…`, each line URL-encoded
(encodeURIComponent; `||` between lines stays as is). It opens Mass Entry with Magic picked and the list filled
in; checked with commas, apostrophes, `//`, `[SET] number` and `Æ`. Lines: `<qty> <name>` (any printing) or
`<qty> <name> [<SET>] <number>` (a printing). Names follow TCGplayer's product names, checked in its search:
split cards whole ("Fire // Ice"), every other card with two names by its first ("Delver of Secrets",
"Bonecrusher Giant"). Printing (Normal/Foil) and condition are options for the whole list on TCGplayer, not per
line, so foil wants come in as whatever's picked there. Not checked: that every line matches a product once Add
to Cart is pressed (set codes are Scryfall's, upper case, which are TCGplayer's for most sets).

## RPC (authenticated; anon is refused)

| Call | Does |
|---|---|
| `tcgplayer_cart(p_items)` | `p_items`: `[{oracle_id?, card_id?, qty}]`, up to 2000, qty 1–999 (22023 otherwise). A `card_id` is that printing; an `oracle_id` alone is any printing. Returns `{enabled, lines, unknown, urls}`: the same line twice is summed, lines go A–Z, cards the catalog doesn't know are counted in `unknown` and left out, and a long list is split into parts no longer than `max_url` (each part adds to the same TCGplayer cart). `enabled: false` → no urls. Signed out: 28000. |

## Clients

- **Wants screen:** a **Buy on TCGplayer** row under Price alerts, when you have wants and it's enabled: detail
  "N cards into a cart, then Optimize" (N = wanted copies). Sends every want (qty; its printing when it has one).
- **Missing from decks and cubes:** a **Buy missing on TCGplayer** row at the top of the section, when anything is
  missing, detail "N cards into a cart, then Optimize": sends each Missing line's printing and copies short (basic lands are never missing).
- **Tap:** one part opens straight away in the browser (iOS and Android: the system browser, so the TCGplayer
  sign-in and cart are the user's own; web: a new tab). Several parts open a Table 1 menu "Part 1 of 3", "Part 2 of 3" … with detail "Adds to the same cart" (the menu closes after a pick; tap Buy again for the next part), all into the same cart. Cards the server doesn't know (`unknown`, only cards newer than
  the server's catalog) are left out. No urls: "Nothing to buy". Errors show as the screen's error.
- **Telemetry:** `tcgplayer_cart_opened` (`from`: wants / missing, `lines`, `parts`). No card names.
- **Demo:** the rows show; a tap says "Sign in to build a TCGplayer cart" (the demo has no account).
