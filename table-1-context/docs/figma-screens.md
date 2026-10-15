# Table 1 — App Screens (Figma)

File: https://www.figma.com/design/Hbkg1vKjdTFpwYt0NtCCYq (Personal Design team), built 2026-10-08 from apps/ios, apps/android, table-1-events-web; updated 2026-10-11 for the Events/Account plan and 2026-10-12 for tracker / formats / teams.

- Pages: Cover · Components (Native, Platform chrome, Web boards) · iOS · Android · Web.
- Colors bound to the **Table 1** library variables: Mode (Dark) Neutral_1/2/3/4/6, Color/Primary, Color/Error, Lines/secondary (1px hairline gaps). Local gap-filler: `T1 Local Color` (surface-hover, warning).
- Spacing (gaps + padding) bound to the library **Space** collection. Local `T1 Spacing` removed; 14/20/26/28 mapped up to 16/24/24/32. Odd one-off values stay as plain numbers.
- Font: local variable `font/mono` (collection "T1 Type", VariableID:37:3) is bound to the family of all 31 `Native/*` and `Web/*` text styles. The Figma MCP can't load SF Mono, so it is temporarily **JetBrains Mono** — set it back to "SF Mono" in the Variables panel on a Mac (one edit restyles everything).
- Open question: library Error is #F2A3E5 (pink) vs code red (#FF6B6B native, #F87171 web).
- Gotchas: paint opacity on variable-bound paints is lost by combineAsVariants → tints are a "Tint" child rectangle with layer opacity. Frames cloned off the screens root lose its explicit Dark mode, so render checks must use get_screenshot on the real node.

## Events / Account plan (2026-10-11)
New components: Tab Bar (iOS, 38:53) · Live Card (38:101: Role=Player/Organizer) · Android Navigation Bar (39:57) · Web Top Nav (39:74). Sign In Graphic (34:6815) is the full-bleed mark used on every Sign in flow; Web Sign-in Buttons now has Google in accent.

Per platform (iOS / Android / Web):
- **Events** replaces Home: Live now · Reported — waiting · Confirm opponent result · Nothing live · Empty.
- **Account** replaces Profile: Default · Edit name · Delete account (iOS adds Developer · TestFlight).
- **Add players** after Create/New event.
- **Cancel event** inside Event — organizer; Event — player gains Cancelled.

## Tracker / formats / teams (2026-10-12)
Rule: **T1 components everywhere; only alerts use a platform kit.** iOS alerts = iOS 27 kit Alert (set 52:3984, Mode Dark; the user dropped the kit instance in because the kit can't be imported by key). Android alerts = M3 Basic dialog (imported by key; the Android root has the M3 collection on Teal DT so it renders dark). Web = T1 modal ("T1 Dialog"). Menus/action sheets are the T1 bottom "T1 Menu"; History is a "T1 Panel". Segmented controls, steppers, switches, search, chips are drawn T1 blocks.

- Tab bars 38:53 / 39:57 and web top nav 39:74 carry a dimmed **Collection** item (disabled). Glyph components: 53:14275 Events, 53:14280 Collection, 53:14284 Account, 53:14288 Life. Events bar has **Life**.
- **Life tracker** flow (Android 59:3977, iOS 61:4545, Web 65:4410): On its own · In a match · + Counter · History · Who won? · Confirm game (alert) · Opponent at 0 · Report match (alert) · More. Opponent half rotated 180°.
- **Life tracker redesign (2026-10-14)** — supersedes the tracker screens above. Components page: "Life tracker — On its own" 73:5420, "Life tracker — Counters" 92:659, "Life tracker — Counter picker open" 92:749. Components: Me 73:5836 (Counters=0…3), Counter Column 92:498 (Size=Life/L/M/S), Counter Toggle 92:522 (State=Off/On/Disabled), Counter Picker 92:523, Increment Button 73:5558 (State=Default/Pressed), Lifetracker Info 73:5617 (Clock=Normal/Warning/Overtime), Strip Button 73:5656 (State=Default/Pressed). New text binds its font to the `font/mono` variable.
- **Create event / New event** (Android 60:3815, iOS 62:4528, Web 66:4439): Constructed · Pick a format · Other format · Limited · set · Pick a set · Limited · cube · Team draft.
- **Event — organizer** gains: Seating · Teams · Teams · move to · Teams · rename (alert with text field) · Team seating · Team standings.
- **Event — player** gains: Life tracker on · Team event.
- **Account** gains: Track games (Life tracker | Elsewhere).
- Long lists (seating, team standings, some web forms) clip at the bottom as scroll content.
- Scripts (session scratch): prelude.js + builder2.js + specs_tracker.js / specs_rest2.js.

Organizer event screen flow (2026-10-12): "Event — organizer · setup / live / results" — iOS 69:6396, Android 70:5604, Web 71:6202 (see `plan-organizer-phases.md`).

## Widgets & Watch (2026-10-14)
iOS page, last row of "iOS screens" (row 99:5223), drawn from `apps/ios/Table1Widgets` with the `LiveSnapshot.sample` data (Thursday Draft, R2/3, T4, vs Brit Osei, 42:17): Small widget (in a match / bye / no match), Medium widget (report your result / confirm their result), Lock Screen accessories (inline, circular round gauge, rectangular), Live Activity on the Lock Screen (report / confirm), Dynamic Island (compact, minimal, expanded), and Apple Watch Smart Stack. There is no watchOS app: watchOS 11 shows the iPhone Live Activity's compact leading + trailing views in the Smart Stack. Backdrops are illustrative; system-drawn text (Lock Screen clock, inline accessory, watch time) stays SF Pro, everything the app draws binds to `font/mono`.

## Create event + Setup rework (2026-10-14, code first)
Drawn from the build (`contract/create-event-2026-10-14.md` UI section; iOS `CreateEventView.swift`, `TeamsView.swift`, `OrganizerPhases.swift`, `SetIcon.swift`, demo data from `EventsDemo.swift`). These document what shipped; they are not proposals.

- **Components page** (inside Native components 7:13): **Seat Chip** 104:402 (State=Default 104:386 / Mine 104:391 / Bye 104:396; props Seat, Name, Team, Show team) and **Seating Table** 104:534 (Seats=8 104:403 with seat 3 highlighted and its accent line to 7 · Seats=7 · bye 104:452 · Seats=3 v 3 team 104:496, Ravens/Owls; props Pack, Direction). Geometry follows `PodTable.positions`: 393 wide, aspect 0.92 + 12 padding, seat k at −90° + 360°·(k+½)/n.
- **iOS page, new frame "iOS screens · 2026-10-14"** 112:5354, placed below the main "iOS screens" frame (13:2). Rows can't be added inside 13:2 over the MCP (see gotchas).
  - Row "Create event · built 2026-10-14" 112:5355: Limited · set (DSK set icon row, Round timer on, You switch, guest with Remove, empty Add-by-name) 112:5430 · Limited · cube (Recent cubes with Selected/Use, Cube Cobra link, "Found on Cube Cobra · 540 cards.", Cube name) 112:5530 · Round timer off · Players (Clocks hidden, two guests, Add enabled with a typed name, Who can find it) 112:5612.
  - Row "Event — organizer · Setup · built 2026-10-14" 113:5468: Setup · Players · not playing ("You're not playing · Join as a player", Remove on each player, Add-by-name) 113:5554 · Setup · Remove player (iOS kit Alert 113:5690, Keep / Remove destructive) 113:5663 · Setup · Details (auto-name row, set icon row, Round timer switch, Nearby / Link only / Private) 113:5797 · Setup · Seating · 8 · pack 1 (Re-seat, Pack 1/2/3, table) 113:5924 · Seating · 7 with bye · pack 2 (↺ Pass right) 113:6034 · Seating · team draft 3 v 3 · pack 3 113:6129.
- The title bar on these screens is drawn as in `Kit.swift` (title + subtitle + actions), because the **Bar** component (7:16) now shows the Table 1 logo instead of title/subtitle text. Segmented controls, switches, the set row and the Add-by-name row are drawn T1 blocks; headers, rows, notices, fields, stepper, Ghost, Big Action, status bar and home indicator are component instances.
- Set icon: Scryfall `dsk.svg` imported as vectors, filled with Neutral_6 (text colour), as the app tints it.
- Gotchas (MCP): SF Mono can't load server-side, so any append/move of a node whose text resolves to SF Mono fails, including fresh instances of library components and clones of existing screens. Recipe used: create fresh instances, turn on every boolean prop (hidden layers aren't reachable otherwise, including nested instances), detach the text style, unbind `fontFamily`, set SF Pro, set text, restore the booleans, append, and rebind `fontFamily` to `font/mono` last. Detached styles keep their size/fill/line-height bindings. Bound text can't be edited afterwards. The status-bar clock stays SF Pro (system text).
