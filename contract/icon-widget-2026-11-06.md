# Card icon widget (2026-11-06; iOS and Android, client-only)

John: "Add the ability for users to select a card to be the background on their app icon behind the logo."

## Why a widget, not the app icon

Neither platform can make an app icon at run time. iOS `setAlternateIconName` and Android launcher aliases only switch
between icons built into the app, so the choice would be a fixed list. John chose any card, shown as a home screen
widget that looks like the icon and opens the app. The app icon itself does not change.

## What it looks like

- The card's art crop (Scryfall `art_crop`), cropped to fill, under the 60% `#171725` scrim (the art rule in the
  design guidance), with the Table 1 mark in white, centered, at the app icon's share: the mark is 479/1024 of the
  widget's width (on Android, of its shorter side, since it can be resized to any shape).
- No card, or its art missing: the plain icon (mark on `#171725`).
- No text and no accent. A tap opens the app as its icon does, back where you left it (iOS: no `widgetURL`; Android:
  the launch intent with `FLAG_ACTIVITY_RESET_TASK_IF_NEEDED`).
- iOS: `systemSmall` only (the smallest home screen widget, 2×2 icon spaces), drawn as the container background so it
  runs edge to edge, content margins off. Android: one cell (40 dp) by default, resizable in both directions.

## Icon cards

- Picked on a card's page: details (the list icon) → **Use for the icon widget**, after the hero row. It shows only for a
  printing that has an image. The row then reads **On your icon widget**, and a tap offers **Remove from icon widgets**.
- The app downloads the art through its image loader (at most 640 px on the long side), saves it as a JPEG and puts the
  card first on the device's icon cards list, newest first. Picking a card again moves it up. At most 12 are kept (the
  oldest's art is deleted). A card is `{id, name, set}`: the printing's Scryfall id, the card's name, and "MH2 #438".
- Kept on the device, not in the account. Signing out keeps them. iOS: App Group `UserDefaults` `iconCards.v1`, art in
  the group container's `icon-cards/<id>.jpg`. Android: preferences `t1.iconcards` (`cards`, `pick.<widget id>`), art in
  `files/widgets/icon/<id>.jpg`.
- Adding or removing a card reloads every card icon widget (iOS kind `site.table1.icon`, timeline policy `.never`;
  Android `Widgets.refresh` by the receiver's ids).

## Which card a widget shows

Each widget can pick one of the icon cards in its own settings: iOS Edit Widget (`IconWidgetIntent`, a `Card` parameter
listing the icon cards with their set), Android `IconWidgetConfigActivity` (Newest, then each card with its art). It
shows that card while it is still on the list, else the newest (`IconCards.shown`). Android forgets a removed widget's
pick.

## Telemetry

`icon_card_added` {count}, `icon_card_removed` {count}; Android `widget_configured` {widget: "icon", newest, cards}.

## Tests

Shared cases `testdata/icon-widget/cases.json` from `make_cases.py` (add, remove, shown, logo width):
iOS `IconCardsTests`, Android `IconCardsTest`. Design QA: iOS `-T1WidgetsDemo icon` (Lightning Bolt from Scryfall, the
newest icon card, none); Android `WidgetGalleryTest.cardIcon` (stand-in art, every size from 1×1).

## Not on the web

The web has no home screen widgets.
