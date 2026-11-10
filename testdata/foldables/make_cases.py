#!/usr/bin/env python3
"""Reference for fold-aware layouts (contract/foldables-2026-11-10.md). Writes cases.json, which iOS FoldLayoutTests,
web fold.test.ts and Android FoldLayoutTest check `FoldLayout` against.

Input: a container's size (pt on iOS, dp on Android, CSS px on the web) and the folds crossing it, in the container's
own coordinates: {x, y, w, h, vertical, separating, margin}. `vertical` = the fold runs top to bottom (book);
`separating` = it splits the screen in two right now (iOS: an active `.division` reserved region; Android:
FoldingFeature.isSeparating, true when half opened and on a dual screen's hinge; web: two viewport segments).

Output:
  width / height  size classes: compact < 600 <= medium < 840 <= expanded (width); compact < 480 <= medium < 900 (height)
  mode            single (one column, as on a phone), wide (two side by side, split in half, nothing folded),
                  tabletop (a separating horizontal fold: first pane above it, second below),
                  book (a separating vertical fold: first pane left of it, second right)
  panes           one rect (single) or two (first, second); the fold and CLEAR on each side of it belong to neither
  rail            the tab bar runs down the side: landscape windows (wider than tall), never in tabletop, where it
                  would cross the fold (it stays along the bottom, on the flat half)
  rotates         iOS only: the app turns with the device once the window's shorter side is 600 or more (the inner
                  display of a foldable); phones stay portrait

A fold counts only when it is separating and leaves at least MIN_PANE on both sides of it (a container that the fold
only grazes keeps its one column). The first fold that counts wins.

  python3 -I testdata/foldables/make_cases.py
"""
import json
import os

CLEAR = 8        # keep-clear on each side of a fold (more when the platform asks: iOS region margins)
MIN_PANE = 120   # each side of a fold must have this much room to become a pane
WIDE = 840       # flat and at least this wide (and HEIGHT_MIN tall): two panes side by side
HEIGHT_MIN = 480


def width_class(w):
    return "compact" if w < 600 else "medium" if w < 840 else "expanded"


def height_class(h):
    return "compact" if h < 480 else "medium" if h < 900 else "expanded"


def r(x, y, w, h):
    return [round(x, 2), round(y, 2), round(max(w, 0), 2), round(max(h, 0), 2)]


def layout(w, h, folds):
    mode, panes = "single", [r(0, 0, w, h)]
    for f in folds:
        if not f.get("separating"):
            continue
        clear = max(CLEAR, f.get("margin", 0))
        if f["vertical"]:
            a, b = f["x"] - clear, f["x"] + f["w"] + clear
            if a >= MIN_PANE and w - b >= MIN_PANE:
                mode, panes = "book", [r(0, 0, a, h), r(b, 0, w - b, h)]
                break
        else:
            a, b = f["y"] - clear, f["y"] + f["h"] + clear
            if a >= MIN_PANE and h - b >= MIN_PANE:
                mode, panes = "tabletop", [r(0, 0, w, a), r(0, b, w, h - b)]
                break
    if mode == "single" and w >= WIDE and h >= HEIGHT_MIN:
        half = (w - 1) / 2
        mode, panes = "wide", [r(0, 0, half, h), r(half + 1, 0, w - half - 1, h)]
    return {
        "width": width_class(w),
        "height": height_class(h),
        "mode": mode,
        "panes": panes,
        "rail": mode != "tabletop" and w > h,
        "rotates": min(w, h) >= 600,
    }


def fold(x, y, w, h, vertical, separating=True, margin=0):
    return {"x": x, "y": y, "w": w, "h": h, "vertical": vertical, "separating": separating, "margin": margin}


CASES = [
    ("phone portrait", 390, 844, []),
    ("phone landscape", 844, 390, []),
    ("foldable cover screen", 412, 915, []),
    ("unfolded, portrait, flat", 673, 841, []),
    ("unfolded, landscape, flat", 841, 673, []),
    ("unfolded, flat fold is not separating", 841, 673, [fold(420, 0, 0, 673, True, separating=False)]),
    ("tabletop: horizontal fold half opened", 841, 673, [fold(0, 336, 841, 0, False)]),
    ("book: vertical fold half opened", 673, 841, [fold(336, 0, 0, 841, True)]),
    ("book on a landscape window", 1000, 700, [fold(500, 0, 0, 700, True)]),
    ("dual screen: flat but a 34 dp hinge separates", 1114, 720, [fold(540, 0, 34, 720, True)]),
    ("iPhone-style division region with margins", 700, 820, [fold(0, 400, 700, 20, False, margin=12)]),
    ("fold grazes the container's top: one column", 841, 400, [fold(0, 60, 841, 0, False)]),
    ("fold grazes the container's right edge", 673, 841, [fold(600, 0, 0, 841, True)]),
    ("container below a bar: fold offset", 841, 623, [fold(0, 286, 841, 0, False)]),
    ("second fold wins when the first doesn't count", 841, 673,
     [fold(0, 20, 841, 0, False), fold(420, 0, 0, 673, True)]),
    ("small wide window: not tall enough for two", 900, 420, []),
    ("square tablet-ish window", 900, 900, []),
    ("exactly the wide breakpoint", 840, 600, []),
    ("just under", 839, 600, []),
]


def main():
    cases = [{"name": n, "w": w, "h": h, "folds": folds, "out": layout(w, h, folds)} for n, w, h, folds in CASES]
    out = {"constants": {"clear": CLEAR, "minPane": MIN_PANE, "wide": WIDE, "heightMin": HEIGHT_MIN}, "cases": cases}
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "cases.json"), "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print(f"{len(cases)} cases")


if __name__ == "__main__":
    main()
