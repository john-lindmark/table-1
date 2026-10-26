# Card language (2026-10-19)

Every copy you own, every binder copy and every trade line has a language (Scryfall's codes). It can be changed
wherever such a copy shows. No server change: `collection_items.lang` already takes any `^[a-z]{2,3}$` code and
`collection_apply` moves copies between keys.

## Languages
English, German, French, Italian, Spanish, Portuguese, Japanese, Korean, Russian, Chinese Simplified, Chinese
Traditional (the common eleven, listed first), then Hebrew, Latin, Ancient Greek, Arabic, Sanskrit, Phyrexian, Quenya.
Codes: en de fr it es pt ja ko ru zhs zht he la grc ar sa ph qya. One full-screen picker, current one marked.

## Where
- **Card detail → a copy you own** (tap the printing): Language · English → pick → "One copy" or "All N copies" when
  there are several. Copies stay where they are: taken from Unsorted first, then binders in name order, each moved copy
  going back into the same place. One batch, so Undo puts them back.
- **Change printing** for owned copies (card detail's In collection or a binder's copies): a Language row changes the
  chosen number of copies from the chosen place.
- **New copies**: card detail's Add a printing, binder Add cards (+ New) and the scanner add in the language picked
  for new copies (remembered, like condition). A non-English printing is always added in its own language.
- **Scanner**: each scanned row shows its language and a button to change it; the camera pauses while the picker is
  open. The language is the printing's when that isn't English, else the one the card's text says (2026-10-20): the
  language code printed by a known set code ("WAR • JP"), else the language of the printed name read (a German name
  → German); else the one for new copies. An English name doesn't tell (many cards print the English name in every
  language). Owned-only scans (giving in a trade) keep the owned copy's language.
- **Trades**: a get line's menu has Language. A give line is the copy you own; change that copy's language in the
  collection first.
- Deck and cube lines name a language since 2026-10-26 (contract/lists-2026-10-15.md § Languages): card detail
  opened from a deck or cube has a Language cell. Wants still have no language of their own.

## Rules (shared by every platform)
- `LanguageChange.ops(item, places, to, qty, from?)`: nil when the language is the same, qty is 0 or more than owned,
  or the chosen place holds fewer. Otherwise per place: −n in the old language and +n in the new, with that place's
  binder (none for Unsorted). Order: `from` only when given; else Unsorted, then binders in the order given.
- New copies: `lang = printing.lang != "en" ? printing.lang : picked`.
- Scanned copies: `Languages.forScan(printing, read, picked)`: the printing's language when not English; else, with
  `read` (the matcher's `langs`: `[code]` from the set-code line, or every language that prints the name read, never
  for an English name) non-empty, `picked` when it's in `read` (Spanish and Portuguese names often normalize alike),
  else `read[0]` in the picker's order; else `picked`. Tests: `LanguageTests` / `LanguageTest`, and the photo set
  (`CardMatcherTests.testForeignCards`: 94% of foreign cards named right go in as their own language, floor 93%; no
  English card goes in as another). The misses are names printed the same as the English one (old German and Italian
  cards) and names Spanish and Portuguese print alike.
- Tests: iOS `Table1Tests/LanguageTests.swift`.

## Telemetry
`language_changed` with `where`: owned / collection / binder / trade and `copies`.

## Status
iOS built and unit-tested.
Scanned language from the card's text (2026-10-20): iOS and Android built and unit-tested (same photo-set numbers); not
yet tried on a real camera. Web has no scanner.
Web (2026-10-19): built, unit-tested (`src/lib/languages.test.ts`, same cases) and checked in `/library?demo`; no scanner.
Android (2026-10-19): built and unit-tested (`LanguageTest`, same cases), scanner rows included; not yet run on a device.
