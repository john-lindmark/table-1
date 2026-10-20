# Deck image (2026-10-20)

Client-only, made on the device (nothing uploaded). iOS built and checked in the demo (`-T1LibraryDemo deck
-T1DeckImage`); web and Android to do. Tests: iOS `DeckImageTests`.

## Where

**Deck image** row on every deck screen you own (next to Export) and on decks shared with you on a profile. Decks
only (a cube is too many cards for one picture). Opens a full screen: options, a live preview, then **Save to Photos**
(add-only Photos permission; iOS `NSPhotoLibraryAddUsageDescription`) and **Share** (a JPEG named for the deck, e.g.
`Boros Energy.jpg`, to the share sheet: Messages, Discord, Save Image, Files).

## The image (melee.gg's visual decklist format)

- 1200 × 675 pt rendered at 2× (2400 × 1350 px), 16:9. Background `#171725`; no texture, shadows or rounding beyond the
  cards' own corners.
- **Header**: deck name (bold, mono, 30); "By <player>"; one line "Oct 20, 2026 · Format: Modern · Deck: 60 cards ·
  Sideboard: 15 cards" (muted). Top right: the Table 1 mark and TABLE-1.SITE.
  - Player: on your own deck, your profile display name (switch "Your name", on by default; no line when you have no
    name); on a shared deck, the owner's name.
- **Cards** (default layout): every card once, main deck as a grid (Commander first, then the Group by groups in
  order, each by mana value then name; no headings), a square count badge over each card's top-right corner. Then a
  vertical divider labelled SIDEBOARD and the sideboard as one overlapping column (each card's title strip shows, the
  last card whole), badges on the right. Considering is never shown.
  - Size: cards grow as big as the canvas allows (columns 2–16 tried; the sideboard column keeps cards at least 10% of a
    card apart). Below 72 pt wide the canvas grows taller instead (big Commander decks).
- **Stacks** (other layout): overlapping columns per group, each titled "<group> · <count>"; a group over 9 cards
  continues in the next column; the sideboard in its own column(s) right of the divider. Height follows the content.
- Options (remembered on the device): layout Cards / Stacks; Group by Type / Mana value / Color (the same groups as
  contract/shared-lists-grouping-2026-10-20.md §4); Sideboard on/off (only when the deck has one); Your name on/off
  (own decks).
- Card art: each line's printing (the most-held printing for a card in several), from Scryfall's CDN at "normal" size,
  downsampled; foils get the sheen. A card whose image can't load shows its name on a plain tile, with a note.

## Telemetry

`deck_image_shared`: `layout` (grid / stacks), `grouping`, `sideboard` (bool), `cards`, `from` (own / profile), `how`
(photos / share).
