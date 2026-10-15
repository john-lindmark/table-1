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
