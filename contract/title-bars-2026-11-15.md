# One title bar everywhere (2026-11-15)

John: "have all the title bars match the style of the collection and card detail title bars. Remove all the
secondary labels that sit below the main title."

Client-only, all three clients. The shared bar (iOS `Bar` in `UI/Kit.swift`, web `Bar` in `components/kit.tsx`,
Android `Bar` in `ui/components/Kit.kt`) now draws what the Collection home (Figma 325:10820) and card detail
(318:10810) bars already did, design guidance § 2 "Bar":

- 50 pt / px / dp tall on the background (`#171725`), not the surface; no vertical padding.
- Pushed screens: the back arrow in a 50 × 50 cell at the leading edge, then the title 4 from it, 12 pt, as written
  (`Boros Energy`, `Friends · Mara`).
- A screen with no back arrow (tab roots, panels with Cancel/Done): the title 16 from the edge, 12 pt, uppercase,
  tracking 2 (`EVENTS`, `INSIGHTS`).
- No subtitle: the parameter is gone on all three, so a bar can't grow a second line again. Where the only thing the
  subtitle said was whose list it is, the title carries it (`Friends · <name>`).
- Actions at the trailing edge, 1 apart: icon buttons are 50 × 50 and flush to the edge; text actions take the bar's
  full height with 16 either side (iOS `BarButton` inside a bar, `EnvironmentValues.inBar`; Android `BarAction`,
  `LocalInBar`; web `.t1-bar-actions` in `globals.css`, `t1-icon-btn` marks icon buttons).

Collection home and card detail keep their own bar code; they were the model.

Not changed: text bar actions (`VIEW`, `+ NEW`, `LIFE`, `EDIT`) are still words (guidance § 7 item 3), and row
second lines (`ListRow` detail) are untouched: they aren't under a title. Figma's kit Bar not yet updated.
