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
- **Scanner**: each scanned row shows its language (its printing's, else the one for new copies) and a button to change
  it; the camera pauses while the picker is open. Owned-only scans (giving in a trade) keep the owned copy's language.
- **Trades**: a get line's menu has Language. A give line is the copy you own; change that copy's language in the
  collection first.
- Not here: deck and cube lines and wants have no language of their own; a line's language is its printing's, and
  Change printing lists every language's printings.

## Rules (shared by every platform)
- `LanguageChange.ops(item, places, to, qty, from?)`: nil when the language is the same, qty is 0 or more than owned,
  or the chosen place holds fewer. Otherwise per place: −n in the old language and +n in the new, with that place's
  binder (none for Unsorted). Order: `from` only when given; else Unsorted, then binders in the order given.
- New copies: `lang = printing.lang != "en" ? printing.lang : picked`.
- Tests: iOS `Table1Tests/LanguageTests.swift`.

## Telemetry
`language_changed` with `where`: owned / collection / binder / trade and `copies`.

## Status
iOS built and unit-tested. Web and Android to do.
