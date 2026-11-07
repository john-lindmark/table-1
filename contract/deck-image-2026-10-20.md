# Deck image (2026-10-20)

Client-only, made on the device (nothing uploaded). All three platforms (2026-10-20): iOS built and checked in the demo
(`-T1LibraryDemo deck -T1DeckImage`); web built and checked in `/library?demo` (own deck) and the friends demo (Mara
Quinn's deck); Android built and unit-tested, not run on a device. Tests: iOS `DeckImageTests`, web `deckImage.test.ts`,
Android `DeckImageTest`; card sizes from the shared cases `testdata/deck-image/cases.json` (`make_cases.py`).

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

## Per platform

- **iOS**: SwiftUI `ImageRenderer` at 2×; Save to Photos asks for add-only Photos access; Share sends the JPEG.
- **Web**: drawn on a 2D canvas at 2× from Scryfall's CDN images (cross-origin reads allowed). **Download** saves the
  JPEG; **Share** uses the browser's file share sheet where it has one, otherwise reads **Copy image** and copies a PNG
  to the clipboard. Options are remembered in local storage.
- **Android**: drawn on an `android.graphics.Canvas` at 2× from the app's card image cache. **Save to Photos** writes
  `Pictures/Table 1/<deck>.jpg` through MediaStore (no permission on Android 10+; on 8–9 it fails with a note to use
  Share); **Share** sends the JPEG through the FileProvider. Options are remembered in the `library` preferences.

## Long press (2026-11-07)

John: "add the ability in generated deck/ranking images to long press to copy/share/etc via native functions". The
deck image and the Top N ranking image (and their full-screen zoom views) answer a long press with **Copy**, **Save to
Photos** and **Share**, each going straight to the platform's own function. The row under the preview reads "Tap to
zoom · hold to copy, save or share" (web with a mouse: "Click to zoom · right-click to copy or save"). Card art's zoom
view (card detail) has no menu.

- **iOS**: the system context menu (`.contextMenu` with the picture as its preview; text items, no SF Symbols). Copy
  puts the picture on `UIPasteboard`, Save to Photos and Share are the screen's own buttons' actions. In the zoom view
  Copy's and Save's answer shows as a notice under the bar for 3 s. VoiceOver gets the three as custom actions.
  (`MadeImageActions`, `madeImageMenu` in `ZoomImage.swift`; test `MadeImageTests`.)
- **Web**: the browser's own image menu. The preview is a plain `<img>` (no longer inside a `<button>`, which kept
  Safari from offering its image menu) with `-webkit-touch-callout: default`; the row under it is the zoom button.
  Phones' long press gives Safari's Copy / Save to Photos / Share and Chrome's Download / Share / Copy image; a mouse
  gets the right-click menu. (`previewHint` in `lib/zoom.ts`.)
- **Android**: there is no system long-press menu, so a Table 1 menu (`T1Menu`) lists the three; Copy puts the JPEG
  on the system clipboard as a FileProvider content URI (`image/jpeg`; Android 13+ shows its own copied preview), Save
  to Photos writes through MediaStore, Share opens the system share sheet (now with the picture as ClipData, so the
  sheet previews it). In the zoom view Copy's and Save's answer replaces the hint row for 3 s. (`MadeImageActions`,
  `copyImage` in `DeckImageScreen.kt`; test `MadeImageMenuTest`.)

## Telemetry

`deck_image_shared`: `layout` (grid / stacks), `grouping`, `sideboard` (bool), `cards`, `from` (own / profile), `how`
(photos / share / copy; web: download / share / copy). `ranking_image` `how` gains `copy` (apps).
`image_menu` {`screen` (deck_image / ranking_image, `_zoom` in the zoom view), `how` (copy / photos / share; web has no
`how`: it fires when the browser's menu opens)}.
