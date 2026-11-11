#!/usr/bin/env python3
"""Reference for the life tracker's touch rule (contract/life-tracker-options-2026-10-20.md § Taps and the pull band).

A touch on a seat's +1 / -1 zone always counts, however far the finger drifts. Only a touch that starts in the
pull band, the strip along the player's far edge (their "top"), and then travels toward the player opens the
counter picker (and takes its tap back). A finger that rolls more than HOLD_SLOP before the hold delay is a
sloppy tap, not a hold: no repeat.

Coordinates are screen points inside the seat's box, origin top-left; moves are screen deltas.
Run: python3 testdata/tracker-touch/make_cases.py  (writes cases.json next to it)
"""
import json
import os

BAND = 44  # pt / dp / css px from the player's far edge
SWIPE = 24  # travel toward the player that opens the picker
HOLD_SLOP = 24  # travel before the hold delay that means "not a hold"
MOVED = 10  # the old cancel distance; telemetry still counts taps that travelled past it


def toward(seat, dx, dy):
    return {
        "bottom": (dy, dx),
        "top": (-dy, dx),
        "left": (-dx, dy),
        "right": (dx, dy),
    }[seat]


def opens_picker(seat, dx, dy, minimum=SWIPE):
    down, across = toward(seat, dx, dy)
    return down >= minimum and down > abs(across) * 1.5


def far(seat, x, y, w, h):
    """Distance from the player's far edge (their top) of a seat box w x h."""
    return {"bottom": y, "top": h - y, "left": w - x, "right": x}[seat]


def in_band(seat, x, y, w, h):
    return far(seat, x, y, w, h) <= BAND


def pulls(seat, x, y, w, h, dx, dy):
    return in_band(seat, x, y, w, h) and opens_picker(seat, dx, dy)


def holds(dx, dy):
    return (dx * dx + dy * dy) ** 0.5 <= HOLD_SLOP


BOX = {"bottom": (390, 380), "top": (390, 380), "left": (180, 300), "right": (180, 300)}


def touches():
    out = []

    def add(note, seat, x, y, dx, dy):
        w, h = BOX[seat]
        out.append({
            "note": note, "seat": seat, "box": [w, h], "start": [x, y], "move": [dx, dy],
            "far": far(seat, x, y, w, h), "band": in_band(seat, x, y, w, h),
            "pull": pulls(seat, x, y, w, h, dx, dy), "counts": not pulls(seat, x, y, w, h, dx, dy),
            "holds": holds(dx, dy),
        })

    # The complaint: a tap that drifts a little (or a lot) still counts.
    add("tap in the middle, still", "bottom", 195, 120, 0, 0)
    add("tap that drifts 12 down (was cancelled)", "bottom", 195, 120, 2, 12)
    add("tap that drifts 30 down mid-zone (opened the picker)", "bottom", 195, 120, 3, 30)
    add("tap on -1 drifting 40 down", "bottom", 195, 300, 0, 40)
    add("tap drifting sideways 20", "bottom", 195, 300, 20, 2)
    # The pull band along the far edge.
    add("pull from the top strip", "bottom", 195, 20, 0, 40)
    add("pull from the band's edge", "bottom", 195, 44, 4, 30)
    add("just below the band", "bottom", 195, 45, 0, 60)
    add("in the band, sideways", "bottom", 195, 10, 40, 10)
    add("in the band, away from the player", "bottom", 195, 10, 0, -40)
    add("in the band, short drift", "bottom", 195, 10, 0, 20)
    # Turned seats: the band is along each player's own far edge.
    add("top seat pulls up the screen from its far edge", "top", 195, 360, 0, -40)
    add("top seat, mid-zone drift up", "top", 195, 200, 0, -40)
    add("top seat, screen top is the player's near edge", "top", 195, 20, 0, -40)
    add("left seat pulls left from the right edge", "left", 160, 150, -40, 0)
    add("left seat, its left edge is near the player", "left", 20, 150, -40, 0)
    add("right seat pulls right from the left edge", "right", 20, 150, 40, 0)
    add("right seat, mid-zone drift right", "right", 100, 150, 40, 0)
    # Holds.
    add("rolled thumb, no repeat", "bottom", 195, 300, 18, 18)
    return out


def main():
    cases = {
        "_doc": __doc__.strip().splitlines()[0],
        "band": BAND, "swipe": SWIPE, "holdSlop": HOLD_SLOP, "moved": MOVED,
        "touches": touches(),
    }
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases.json")
    with open(path, "w") as f:
        json.dump(cases, f, indent=2)
        f.write("\n")
    print(f"wrote {len(cases['touches'])} touches to {path}")


if __name__ == "__main__":
    main()
