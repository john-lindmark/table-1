"""Writes cases.json: the deck image's card sizes (contract/deck-image-2026-10-20.md), an independent copy of
DeckImage.fit for iOS, web and Android to check against. Run: python3 make_cases.py"""
import json
import math

W, PAD, HEADER, GAP, ROWGAP, GUT, ASP, MINW = 1200, 40, 132, 14, 22, 56, 1.396, 72


def fit(main, side):
    height = W * 9 / 16
    room = height - HEADER - PAD
    flag = 1 if side > 0 else 0
    side_max = room / ((1 + 0.1 * (side - 1)) * ASP) if side > 1 else math.inf
    best = (1, 0.0)
    for cols in range(2, 17):
        r = math.ceil(max(main, 1) / cols)
        by_width = (W - 2 * PAD - flag * GUT - (cols - 1) * GAP) / (cols + flag)
        by_height = (room - (r - 1) * ROWGAP) / (r * ASP)
        cw = math.floor(min(by_width, by_height, side_max))
        if cw > best[1]:
            best = (cols, cw)
    cols, cw = best
    total = height
    if cw < MINW:
        cw = MINW
        cols = max(1, math.floor((W - 2 * PAD - flag * (GUT + cw) + GAP) / (cw + GAP)))
        r = math.ceil(max(main, 1) / cols)
        total = max(height, HEADER + PAD + r * cw * ASP + (r - 1) * ROWGAP)
    ch = cw * ASP
    step = min(ch * 0.19, (total - HEADER - PAD - ch) / (side - 1)) if side > 1 else 0
    return dict(cols=cols, cw=cw, step=round(max(step, 0), 4), height=math.ceil(total))


cases = [dict(main=m, side=s, **fit(m, s)) for m, s in
         [(21, 9), (15, 6), (8, 0), (1, 1), (30, 15), (60, 0), (100, 0), (99, 10), (36, 12)]]
with open("cases.json", "w") as f:
    json.dump(dict(about="Deck image card sizes (contract/deck-image-2026-10-20.md): DeckImage.fit(main unique cards, "
                         "side unique cards) on iOS, web and Android. Written by make_cases.py; step rounded to 4 places.",
                   fit=cases), f, indent=1)
