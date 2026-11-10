# Foldables: iPhone Duo, Galaxy Z Fold, Pixel Fold (2026-11-10)

John: "build out experiences for foldable devices like the iPhone Duo, Samsung folds, and google folds. Use the best
practices for the experience from each of the OS builders." Sources read 2026-11-10: Apple's iPhone Duo pages
(developer.apple.com/iphone-duo, the "Prepare" page, HIG "Designing for iPhone Duo", the tech overview "Preparing your
app for iPhone Duo") and Android's "Learn about foldables", "Make your app fold aware", "Use window size classes",
"Support foldable display modes" and "Make ConstraintLayout fold-aware". Clients: iOS (iOS 27.1 SDK, Xcode 27.1),
Android (androidx.window 1.5.1), web (Viewport Segments API).

## What the OS builders ask for, and what we do

| Guidance | Apple | Android | Table 1 |
|---|---|---|---|
| Resize, don't reinvent | size classes, layout from the view's own bounds, never `UIScreen.main`, orientation or device identity | window size classes (600 / 840 dp), never device type | one rule, `FoldLayout`, from the container's own size; the one `UIScreen.main` (Rankings tiles) now reads its container |
| More on the big screen | "show an additional level of hierarchy on the larger inner display" | list–detail on expanded widths | two panes when the window is 840+ wide and 480+ tall (`wide`) |
| Keep off the fold | reserved regions (`ReservedRegion`, kind `.division`, active when partly open) | `FoldingFeature` (`isSeparating`, bounds); no controls near the fold, no dialogs over it | the fold and 8 pt/dp on each side (more if the region's margins ask) belong to no pane |
| Postures | book, on a surface, on its edges | tabletop (horizontal fold: content above, controls below), book (vertical fold: two pages) | `tabletop` and `book` modes, the same two panes in each |
| Continuity | "keep functionality and state the same between displays" | the activity restarts on fold/unfold unless it handles the change | iOS keeps its scene; Android's MainActivity handles size, layout, orientation and density changes itself (Compose redraws), so nothing on screen is lost |
| Bars | system bars go to the side on the outer display and in landscape; custom views read `toolbarVerticalEdge` | navigation rail on wider windows | our tab bar becomes a rail on that edge (iOS: `toolbarVerticalEdge`, else trailing; Android: start) in landscape windows; never in tabletop, where it stays on the flat half |
| Orientation | resizing on every pose; only games lock | targetSdk 36 ignores locks on large screens | iOS turns with the device when the window's shorter side is 600+ (inner displays); phones stay portrait |

Not done, and why: dual-screen and rear-display modes (Android `WindowAreaController`) and the iPhone Duo outer-display
camera accessory: nothing in Table 1 shows content to a second person on the other screen today (the scanner uses
the rear camera with the user looking at the screen). System toolbars (`ToolbarItemVisibilityPriority`, overflow
menus): Table 1 draws its own bars (design rule: Table 1 components everywhere), so these don't apply; our Bar stays
horizontal, which Apple's guidance allows for text-labelled bars.

## The rule (`FoldLayout`, cases `testdata/foldables/cases.json` from `make_cases.py`)

Input: a container's size and the folds crossing it, in its own coordinates (`x, y, w, h, vertical, separating,
margin`). Output: width/height size classes, `mode`, `panes`, `rail`, `rotates`.

- **single**: one column, as on a phone.
- **wide**: flat and 840+ wide, 480+ tall: two panes split in half with a 1 pt hairline (the inner display's middle,
  where its crease is).
- **tabletop**: a separating horizontal fold with 120+ on each side: first pane above, second below.
- **book**: a separating vertical fold with 120+ on each side: first pane left, second right.
- A fold that isn't separating (an Android foldable lying flat) is ignored; a dual screen's hinge is separating even
  when flat, so it gets the posture layout (Android's guidance).
- `rail`: landscape windows (w > h) unless tabletop. `rotates`: shorter side 600+.

Each platform's fold source:
- iOS: `GeometryProxy.reservedRegions(kind: .division)` (iOS 27.1+), active regions only, frame in the container's
  space; `vertical` when the frame is taller than wide; margin = the region's largest margin.
- Android: `WindowInfoTracker.windowLayoutInfo(activity)` → `FoldingFeature`s, bounds in window pixels, moved into the
  container's space (`positionInWindow`) and into dp.
- Web: `window.viewport.segments` (two segments = folded): the gap between them is the fold; `vertical` when the
  segments sit side by side.

## The screens

1. **App shell**: the tab bar runs down the side as a rail (icons over labels, selected item marked by a 1 pt accent
   line on its inner edge) when the rule says `rail`; in tabletop the content keeps the top half and the tab bar sits
   along the bottom of the flat half.
2. **Life tracker**: tabletop → every seat stands upright in a row on the top (upright) half, read and tapped as you
   face it; the bottom (flat) half holds the round clock, the match line and Record · Options · Reset as big targets.
   Book → the seats stack upright in the left page, the controls fill the right page. Flat (folded or unfolded) →
   the table as before. The fold's band is drawn as background, so no tap zone sits on it.
3. **Card page**: wide, tabletop or book → the card (or the grid of versions) alone in the first pane, the bar, its
   attribute row, Match collection, the stepper and (Details) the rules and copies in the second. Details no longer
   hides the card: it replaces the attribute side only.
4. **Organizer, live round**: tabletop with the round clock on → the clock fills the upright half as a venue timer
   (pause / +5 below it on the flat half with everything else); wide or book on the Round tab → standings in the
   second pane beside the round.

Design QA without a foldable: iOS Debug `-T1Fold tabletop|book|wide` simulates a fold across the middle of the window
(tabletop/book: a 20 pt division band); Android `--es t1Fold tabletop|book`; web `?fold=tabletop|book` on any page.

## Telemetry

`fold_layout` {mode, screen} once per screen per mode change (tracker, card_detail, organizer_live, shell);
`fold_posture` {posture: tabletop|book|flat, width, height} when the window's posture changes (all three).

## Tests

`FoldLayoutTests` (iOS), `fold.test.ts` (web), `FoldLayoutTest` (Android) check the rule against the shared cases;
Android also checks the FoldingFeature → fold conversion and the manifest's `configChanges`.
