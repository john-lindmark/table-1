# Table 1 design guidance (2026-11-01)

What every Table 1 screen should look and behave like, on iOS, Android and web. Written from the frames John designed
himself in the screens file (`Hbkg1vKjdTFpwYt0NtCCYq`), which are the design source wherever they disagree with a
screen Claude drew from code:

| Frame | Node | What it settles |
| --- | --- | --- |
| Life tracker — On its own / Counters / Counter picker | 73:5420, 92:659, 92:749 | full-bleed tools, the info strip, strip buttons, counter columns |
| Collection — home | 325:10820 (shelves 327:8114, 378:8921; actions 391:9273) | tab roots, icon bar actions, art as surface, shelf headers, the bottom strip |
| Card detail section | 318:10810 (screens 199:8296, 231:9241, 228:8925, 318:10614, 318:10715, 360:8704, 360:8609; pickers 199:8525, 199:8610, 199:8841, 228:9037, 228:9147; attributes 198:8244) | pushed screens, the attribute row, pickers one tap deeper, the Add to drill-down, the bottom bar, the list/tune flip |
| Account | 455:9946 | a tab root that is one number, everything else behind the gear |
| Tab bar | 407:9333 | icons + 9 pt labels, accent line over the selected tab |

This supersedes the "UI/design rules" list that CLAUDE.md carried from 2026-10-13. What that list said about
the hairline grid, zero radius, SF Mono, uppercase tracked labels, the single accent and platform-native alerts still
holds. What changes is how much a screen says, how it is split up, and how actions are drawn.

## 1. Principles

1. **The thing itself first.** A screen opens on its subject, large: the card image, the life total, the art,
   the record. The chrome around it is one bar and one bottom bar. Numbers that matter are the biggest thing
   on screen (162 pt life, 48 pt record), not a tile in a grid.
2. **Nothing explains itself.** No subtitles under titles, no descriptions under rows, no paragraphs telling
   the player what the screen is for. Labels are the shortest true form: `MH2 · EN · NM · NF`,
   `R2 | TABLE 13 | KAI BUDDE`, `39 MATCHES · 11 EVENTS`. A second line is data (a deck's format, a card's set),
   never prose. If a control needs a sentence to be understood, redesign the control.
3. **Go deeper, not longer.** One screen does one job. Anything else is one tap away on its own screen:
   an attribute opens a picker, Add to opens a list that drills into the deck's sections, the card's details
   sit behind the list icon. A tab root shows what you came for and hides the rest behind `+`, search and the gear.
   Long scrolling screens of stacked sections are the old pattern.
4. **Icons say it.** Bar actions, shelf headers, steppers and the tab bar are icons, not words. Material
   Symbols **Sharp**, weight **300**, no fill, grade 0, optical size 24, drawn in an 18 pt box. Words stay for
   actions that are the screen's one big action (`ADD TO`, `RECORD`) and for options in a picker.
5. **The grid is the decoration.** Blocks sit edge to edge, 1 px of background between them, zero radius,
   no shadows, no cards, no borders except the 1 px accent outline that marks the current choice. Art under
   a 60 % scrim is the only texture.
6. **One accent, one meaning.** Teal `#00ffd9` marks the result or the current choice: the lifetime record,
   the selected tab's line, the selected version's outline, the picked option's outline, a reported result.
   Never a button fill for a routine action, never decoration.

## 2. Anatomy

### Bar (every screen)
- 56 pt under the status bar. Left: the Material `arrow_left_alt` back arrow on pushed screens (web and
  Android too), nothing on tab roots. Title 12 pt, uppercase, tracking 2 on tab roots (`COLLECTION`,
  `ACCOUNT`); the object's own name in sentence case on pushed screens (`Ragavan, Nimble Pilferer`).
  **No subtitle line.**
- Right: up to two icon buttons, each a 50 × 50 tap target around an 18 pt icon, 1 px apart (`add`, `search`,
  `settings`, `list` / `tune`). A value that belongs to the object (the card's price) sits in muted text before
  the icons. Text actions in the bar (`VIEW`, `+ NEW`, `LIFE`) are out.

### Tab root
- Bar with icon actions, then the subject full width, then a bottom strip of up to three text actions
  (`TRADE | WANTS | IMPORT`, 11 pt uppercase tracking 1.5, 50 pt tall, 1 px apart, on the background), then
  the tab bar.
- Account is the model for a root with one fact: avatar tile (60 pt, initials 24 pt), the name 48 pt semibold
  uppercase tracking 4, a 11 pt muted label, the record 48 pt in accent, one 11 pt muted stat line.
  Friends, sharing, notices, settings, sign out live behind the gear; adding people behind `+`.
- Collection is the model for a root with many things: a summary strip of two art tiles carrying the count and
  the value in 9 pt over the art, then shelves.

### Shelf
- 32 pt of air, a 50 pt header (icon 18 pt, title 12 pt uppercase tracking 2, `arrow_right_alt` on the right,
  tapping anywhere opens the list), then a sideways row of 258 × 135 tiles 1 px apart.
- A tile is an art crop under a 60 % scrim with the name (11 pt uppercase tracking 1.5) and one line of data
  (9 pt muted: format, owner) 16 pt from the bottom left. No counts in the header.

### Pushed screen
- Bar (back arrow, name, value, one icon), the subject, one attribute row, one bottom bar. Nothing else on
  the first screen. Card detail is the model: the card image fills the middle with 32 pt side margins.
- **Attribute row**: equal cells, 50 pt tall, 11 pt uppercase tracking 1.5 centred, 1 px apart
  (`MH2 · EN · NM · NF`; `MIX` when copies differ). Each cell opens its picker. Not a form, not a segmented
  control in the page.
- **Bottom bar**, 88 pt on the surface color, one of:
  - a stepper: three equal cells, `remove` | count 15 pt semibold tracking 4 | `add`, 1 px apart; the step
    that can't happen is dimmed to 40 % (the card detail design) — see § 7;
  - one action: `ADD TO` 15 pt semibold uppercase tracking 4 across the full width;
  - the tracker's info strip (below).
- **Versions**: several printings in the scope are a 2-column grid of card images; a tap selects one
  (1 px accent outline) and the attribute row and stepper then edit that one. A dimmed card is a new edition
  not yet in the scope.
- **The flip**: the bar's `list` icon turns the screen into its details (rules text in 15 pt mono prose,
  then label-value rows: `PRICE`, `CARD TYPE`, `RARITY`, `ARTIST`, labels 11 pt muted left, values right) and
  the icon becomes `tune`, which flips back. Details are never stacked under the subject.

### Picker (one tap deeper)
- A screen or sheet on the background with the options listed down the middle, one per row, 50 pt tall,
  12 pt uppercase tracking 1.5 centred, muted; the current one in white with a 1 px accent outline. Printings
  are a grid of card images with the same outline on the current one. A second 8 pt line holds data only
  (a deck's format).
- A drill-down keeps a small header: `arrow_left_alt` + the parent in 12 pt uppercase muted (`← DECK`), then
  the next level's options. Levels: Add to → Collection / Deck / Cube / Binder / Want / Trade → the deck →
  the section.
- Picking closes the picker and changes the screen behind it. No Save button, no confirmation unless the
  change is destructive.

### Full-bleed tools (life tracker)
- No bar. Two halves, the opponent's rotated 180°, 1 px apart. The total is 162 pt semibold tracking −4 in the
  middle of its half; the top and bottom of each half are the invisible + and − targets, a 40 pt hairline
  marks the midline. Counters split the half into columns with a 50 % life column.
- The info strip between the halves is three rows 1 px apart: the clock 11 pt (warning amber under a
  threshold, error pink in overtime) with `R2 | TABLE 13 | KAI BUDDE` in Neutral_3 on the right; a 4 pt
  progress bar; `RECORD | OPTIONS | RESET` as strip buttons. Everything reachable from here opens over the
  tracker (Options panel, History, Who won?), never beside it.

### Tab bar
- 82 pt, on the background, four tabs: 18 pt icon over a 9 pt uppercase label tracking 1.5. The selected tab
  is white under a 1 px accent line along its top; the others Neutral_4. No surface cells, no fill.
  Only the four tab roots draw it.

### Lists
- Where a list is the subject (All cards, a deck's cards, standings), rows are 50–62 pt on the surface,
  1 px apart: image or tile, name 14 pt, one line of data 11 pt uppercase tracking 1.5 muted (set and
  number, record), the number on the right. A tap opens the object. No per-row explanations, no chevrons.
- Section headers are 11 pt uppercase muted on the surface, the count only where it is the point
  (`WANTED · 3`); a header that opens something is a shelf header (icon + title + arrow).

## 3. Type

SF Mono everywhere (JetBrains Mono stands in inside Figma); web uses the same stack. Sizes used by the frames:

| Role | Size / weight / tracking | Case |
| --- | --- | --- |
| Life total | 162 semibold, −4 | — |
| Name, record on a root | 48 semibold / regular, 4 | upper |
| Counter total | 48 regular | — |
| Clock on an event | 56 regular | — |
| Big action, stepper count | 15 semibold, 4 | upper |
| Prose (rules text, a brief) | 15 regular | sentence |
| Row title, object name in the bar | 14 / 12 regular | sentence |
| Screen title, picker option, shelf title | 12 regular, 2 (bar) / 1.5 (options) | upper |
| Label, attribute, strip button, stat line | 11 regular, 1.5 | upper |
| Tab label, tile data, summary numbers | 9 regular, 1.5 | upper |
| Picker second line | 8 regular, 1.5 | upper |

Prose appears only where the content is prose (a card's rules text, an Insights brief, a notice that must be a
sentence). Nothing else gets a sentence.

## 4. Color

| Token | Value | Use |
| --- | --- | --- |
| Neutral_1 (background) | `#171725` | every screen, the bar, the tab bar, hairlines between surface blocks |
| Neutral_2 (surface) | `#282839` | bottom bars, list rows, pickers' selected fill, the tracker's hairline mark and clock track |
| Neutral_3 | `#545461` | disabled fills, the quietest text (the tracker's match line) |
| Neutral_4 (muted) | `#c4c4ca` | labels, values that aren't the point, unselected tabs and options |
| Neutral_6 | `#ffffff` | text, icons, the selected tab |
| Primary (accent) | `#00ffd9` | the result, the current choice (outline or line), the selected tab's line |
| Warning | `#fbbf24` | the tracker clock under its threshold |
| Error | `#f2a3e5` (library) | overtime, a lost total; the code's reds (`#ff6b6b`, `#f87171`) are still open |
| Scrim | black 60 % | over art under text |

Disabled is a flat Neutral_3 fill on buttons, never opacity. Surface-hover `#33334a` is web only.

## 5. Icons

- **Material Symbols Sharp, weight 300, FILL 0, GRAD 0, opsz 24**, exported as a path and drawn in an 18 pt
  box: iOS `T1Icon` in `apps/ios/Table1/UI/Icons.swift`, web `ICON` / `TAB_ICON` in `kit.tsx` and
  `Library.tsx`, Android `T1Icon` in `LibraryScreens.kt` / `Kit.kt`. Add a new icon by copying its path from
  the Figma instance (or from fonts.google.com/icons with those settings) into all three files in the same
  commit, named after the Material symbol. No SF Symbols on iOS, no Material theme icons on Android, no emoji.
- In use: `arrow_left_alt` (back), `arrow_right_alt` (opens a list), `add`, `remove`, `search`, `settings`,
  `list` / `tune` (the detail flip), the decks / binders / cubes marks on the Collection home (Figma 326:7992,
  326:7982, 326:7987; `+` 50:3149, search 385:9021, arrow 378:8823) and the tab icons (Events, Collection,
  Insights, Account; Figma 378:9015, 378:8908, 385:9042, 378:9003). Copy a path from its Figma instance rather
  than guessing the symbol's name.
- Icons are white, or Neutral_4 when the thing they stand for is not selected. They never carry the accent on
  their own; the accent line or outline does.
- An icon stands alone in a bar and a shelf header. Elsewhere an icon with a label is fine (the tab bar);
  a label with a decorative icon in front of it is not.

## 6. Copy

- Titles are nouns: `COLLECTION`, `DECKS`, the card's name. Actions are verbs or the destination:
  `ADD TO`, `RECORD`, `RESET`, `TRADE`.
- Codes over words wherever a player reads the code anyway: set codes, `NM / LP / MP / HP / DMG`,
  `NF / F / E`, `EN / JA`, `W-L-D`.
- Cut: "Your cards, decks and trades", "Search, Scryfall syntax or scan", "Open the event for your table and
  opponent", "Pick the list, then the section", "Highlighted in your collection and where it…". Every one of
  these is a feature explained in the row. The feature's screen shows what it does.
- A notice is allowed when something has happened that the screen can't show otherwise (couldn't refresh,
  nothing live, a dispute). One sentence, on the surface, no heading.
- "Anyone" not "Public"; "color" not "colour"; no exclamation marks; sentence case for prose and object names,
  uppercase for everything that is a label.

## 7. What changes on the screens built so far

The screens Claude drew from code (iOS `140:6288`, `414:8252` and their web and Android twins) use an older
pattern. When a screen is touched for any reason, bring it to this guidance; when a new screen is built, start
from it. In order of how much it changes the look:

1. **Bar subtitles go.** `Events / 1 LIVE`, `Collection / YOUR CARDS, DECKS AND TRADES`, `Wants / 5 WANTED ·
   5 MISSING`, `annito / ACCOUNT`. The count, if it matters, moves into the content; the description is cut.
   `Bar(title:subtitle:)` on iOS, `Bar` on web and Android keep the parameter for now, but new screens don't
   pass it.
2. **Row descriptions go.** `ListRow(detail:)` lines that explain the row (`SEARCH, SCRYFALL SYNTAX OR SCAN`,
   `TRADES MARKS IT WHEN YOU GET ONE`, `WHO SEES YOUR PROFILE AND LIBRARY`) are cut; lines that are data
   (`MH2 #138 · SHOWCASE`, `6 MATCHES · GAMES 9–5`, `MODERN`) stay.
3. **Text bar actions become icons**: `+ NEW` → `add`, `VIEW` → `tune`, `LIFE` → a tracker icon, `EDIT` →
   `settings` or `tune`, `ADV` / `SCAN` inside a search field → icons. `OPEN ›` rows become the object itself
   (tap the card) with no chevron.
4. **Stacked sections become depth.** Card detail already moved (2026-10-24). Next: Account (record only;
   friends, sharing, notices, head-to-head, settings behind the gear), Events home (what's live, then
   upcoming; invitations, Nearby and Scan QR behind `+` / an icon), the event screen (the clock and your match;
   standings and the rest one tap deeper), deck/cube screens (the cards; Stats, Spice, Export, Share, Sync in a
   menu or on their own screens), Wants and Trades (the list; Buy, alerts, Share in the bar).
5. **Stat tiles become lines.** `CARDS 2,000 / 947 DISTINCT · $50,691` becomes the number large with one
   11 pt line under it, or numbers over art as on the Collection home.
6. **Pickers leave the page.** Condition segments, `Add a printing` rows, `+ CARD / + FOIL` buttons inside
   card detail, format pickers inside forms: each becomes a cell that opens a picker.
7. **The old grid tab icons** (squares) are gone since 2026-10-28; any screen still drawing them is stale.

Open with John (2026-11-01):
- The card detail design dims a stepper's unavailable step to 40 % opacity, while the rule for disabled
  buttons is a flat Neutral_3 fill. Until decided, steppers follow the design (40 %), buttons the rule.
- The tracker design shows the clock in warning amber at 6:12; the threshold and whether the bar is amber or
  accent above it are the code's (`Lifetracker Info` Clock=Normal/Warning/Overtime).
- Figma's library Error is pink (`#F2A3E5`); the apps use red for errors. The tracker uses the pink.

## 8. Platforms

- **iOS** is the reference. Build there first, then web, then Android.
- **Web** keeps the same screens at phone width; at ≥ 1024 px the tab bar is a sidebar and busy screens split
  into two columns (contract/web-desktop-2026-10-22.md). Depth still applies: a picker is a centred panel,
  a drill-down a panel that replaces its parent, the details flip a second column on wide screens only.
  Hover shows the full card; no hover-only actions.
- **Android** draws the same bar, icons and bottom bars; the system back gesture equals the back arrow;
  pickers are screens, not dialogs; the only Material components are the alert dialog and the system
  date picker.
- **Figma**: build first, then draw the built screen beside John's frame (`figma-screens.md` says how); John's
  frames stay the source. New text binds `font/mono` last.
