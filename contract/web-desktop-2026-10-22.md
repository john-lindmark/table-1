# Desktop web (2026-10-22)

Web only; iOS and Android are unaffected. Phones are expected to stay 70–80% of web traffic, so the phone layout is
unchanged and the desktop layout is added on top of it, behind one breakpoint.

## Breakpoint
- Desktop = window at least **1024 px** wide (`DESKTOP_MIN_WIDTH`, Tailwind `lg:`). Below it (phones, tablets
  in portrait, narrow windows) every screen is exactly the phone layout.
- CSS (`lg:` classes) does the layout wherever it can; `useDesktop()` is only for reordering or adding a column.

## Shell
- Signed in (or the dev `?demo`), a **sidebar** (224 px, fixed, one hairline from the content) replaces the
  Events | Collection | Account tabs. Groups: **Play** (Events, Life tracker), **Collection** (Overview, All cards,
  Add cards, Binders, Wants, Decks, Cubes, Rankings, Trades, Trade matches, Import and export), **Account**
  (Account, Friends, Sharing). The selected item is inverted (text colour fill), like a picked segment; teal stays
  "the result".
- The item stays selected on screens pushed above it (`navKeyFor`): a deck under Decks, a cube under Cubes (by the
  list's kind; Decks when unknown), a card under All cards, a profile under Friends, an event under Events.
- No sidebar on the life tracker (full screen), sign-in, the legal pages, `/auth/*`, the shared standings page
  `/s/:id` and dev demos (`sidebarOn`). Signed out there is no sidebar anywhere.
- Back arrows stay on pushed screens.

## Widths
- `column` (default for `Screen` / `LibScreen`): a centered column up to 960 px. Lists, forms, settings.
- `wide`: up to 1600 px. The organizer screen, the player's event screen, a deck or cube, and All cards / a binder /
  a shared profile section **when their View is Grid or Stacks** (List stays a column, since a 1,400 px row is hard to
  read and those lists are virtualized).
- `full`: the signed-out landing page.

## Two-column screens
The organizer round and the player's event screen split from **1280 px** (the round clock needs the room); between
1024 and 1280 their right column stacks under the left. The others split from 1024 px.
- **Events home**: your events (live, invitations, upcoming, past) on the left; Join with an event code, Create an
  event and Life tracker on the right. On a phone the Join box keeps its place between invitations and upcoming.
- **Organizer, Live → Round**: clock and matches on the left; live standings (with "N open") on the right. The
  Standings tab is still there.
- **Player's event screen**: clock, your match and reporting on the left; draft seating, team standings and
  standings on the right. A phone stacks them in that order (unchanged).
- **Card page**: the card large (300 px) in its own column on the left with type, cost and printing count; tapping a
  printing shows it there. Everything else scrolls on the right.
- **Collection overview**: the summary across the top, the sections two across.
- **Deck / cube (List view, or editing)**: each section's groups flow into columns (min 340 px each), the way deck
  sites show a list; the screen's action rows (Stats, Add/remove/replace, Version history, Export, Deck image…) sit
  three across. Grid and Stacks fill the wider screen.

## Desktop behaviour
- **Card preview**: with a mouse or trackpad on a desktop window, resting the pointer on a card's row (every
  `CardRow`) or on a card in a stack shows the full card (250 px) beside the pointer, flipping left near the right
  edge and kept inside the window (`peekPosition`). It hides on leave, press, scroll, window blur and navigation.
  Touch screens never show it.
- **Menus** (View, Group by and every T1 menu) open as a centered panel instead of rising from the bottom.
- **Esc** closes a menu or dialog. **/** focuses the screen's search (its first text field) unless a field already
  has focus.

## Telemetry
- `$pageview` carries `layout`: `desktop` / `mobile` (what showed at that moment), to measure the desktop share.
- `desktop_nav_used` `{to}`: a sidebar item (its key: `events`, `cards`, `decks`, …).

## Tests and QA
- `table-1-events-web/src/lib/desktop.test.ts`: sidebar selection per path, where the sidebar shows, preview
  placement, which keys `/` leaves alone.
- Design QA without signing in (dev server): `/library?demo` at a ≥1024 px window for the shell and Collection;
  `/dev/events` → **Live** for the organizer round with standings beside it (8 players, round 2).
