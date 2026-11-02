# Reference for the Insights home screen widgets (contract/widgets-2026-10-22.md § Meta widgets): Meta breakdown,
# Matchup grid and one archetype's matchups. iOS (Shared/MetaWidget.swift, MetaWidgetTests) and Android
# (widgets/MetaWidgetData.kt, MetaWidgetDataTest) check themselves against cases.json. Change this first, then the apps.
#   python3 -I testdata/meta-widgets/make_cases.py   → cases.json next to it
# modern.json is the live Modern pack of 2026-11-02 cut to what the widgets read.
import copy, json, math, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
SLOTS = 8  # the categorical palette's colors; archetypes past the eighth are grey


def window(pack, tier, days):
    return pack["tiers"].get(tier, {}).get("windows", {}).get(str(days))


def tier_for(pack, want, days):
    """The picked tier when its window has decks, else All events."""
    w = window(pack, want, days)
    return want if w and w.get("decks", 0) > 0 else "all"


def name(pack, a):
    return next((x["name"] for x in pack["archetypes"] if x["id"] == a), "Other")


def slots(pack, tier, days):
    """Color slot per archetype: the eight largest named archetypes of the window, largest first. Other (0) has none.
    The same picks give the same archetype the same color in all three widgets."""
    w = window(pack, tier, days) or {"share": []}
    named = [r["a"] for r in w["share"] if r["a"] != 0][:SLOTS]
    return {a: i for i, a in enumerate(named)}


def r4(x):
    return None if x is None else round(x, 4)


def breakdown(pack, tier, days, n):
    """The n largest named archetypes with their share, change on the window before and win rate; `rest` is what's
    left (Other and the smaller archetypes)."""
    w = window(pack, tier, days)
    if not w: return None
    s = slots(pack, tier, days)
    rows = []
    for r in [r for r in w["share"] if r["a"] != 0][:n]:
        prev = r.get("prev")
        rows.append({"a": r["a"], "name": name(pack, r["a"]), "share": r4(r["share"]),
                     "delta": r4(r["share"] - prev) if prev is not None else None,
                     "wr": r4(r.get("wr")), "slot": s.get(r["a"])})
    rest = r4(max(0.0, 1 - sum(r["share"] for r in rows)))
    return {"decks": w["decks"], "rows": rows, "rest": rest}


def chart(pack, tier, days, ids):
    """The share lines of `ids` over the window: the series' last `days` days. Archetypes with no line, or no value in
    the window, are left out; `top` is the largest value (0 with none)."""
    s = pack["tiers"].get(tier, {}).get("series")
    if not s: return {"days": 0, "lines": [], "top": 0}
    total = s["days"]
    offset = max(0, total - days)
    sl = slots(pack, tier, days)
    lines = []
    for a in ids:
        line = next((l for l in s["lines"] if l["a"] == a), None)
        if not line: continue
        v = line["v"][offset:]
        if all(x is None for x in v): continue
        lines.append({"a": a, "slot": sl.get(a), "v": [r4(x) for x in v]})
    top = max([x for l in lines for x in l["v"] if x is not None], default=0)
    return {"days": total - offset, "lines": lines, "top": top}


def code(n):
    words = re.findall(r"[A-Za-z0-9]+", n.replace("'s", ""))
    if not words: return "?"
    if len(words) == 1: return words[0][:3].upper()
    return "".join(w[0] for w in words[:3]).upper()


def codes(names):
    """Short column names: a name's initials (one word: its first three letters). A clash takes the first word's first
    two letters and the other initials, then a number."""
    out = []
    for n in names:
        c = code(n)
        if c in out:
            words = re.findall(r"[A-Za-z0-9]+", n.replace("'s", ""))
            c = (words[0][:2] + "".join(w[0] for w in words[1:3])).upper() if len(words) > 1 else (words[0][:4].upper() if words else "?")
            k = 2
            base = c
            while c in out:
                c = f"{base}{k}"; k += 1
        out.append(c)
    return out


def heat(wins, losses, minimum=30):
    """testdata/insight-charts make_cases.py `heat` (the apps call their InsightCharts.heat)."""
    n = wins + losses
    if n == 0: return {"label": "", "tone": "none", "strength": 0, "dim": False, "ink": False}
    wr = wins / n; d = wr - 0.5
    tone = "even" if abs(d) < 0.03 else ("up" if d > 0 else "down")
    dim = n < minimum
    strength = (0 if tone == "even" else min(1, 0.25 + abs(d) * 4)) * (0.5 if dim else 1)
    return {"label": str(int(math.floor(wr * 100 + 0.5))), "tone": tone, "strength": round(strength, 4), "dim": dim,
            "ink": abs(d) >= 0.08 and not dim}


def grid_of(pack, tier, days):
    """The window's grid, else the pack's 90-day All events grid (the app's rule), with its title."""
    w = window(pack, tier, days)
    if w and w.get("matchups"):
        return w["matchups"], f"{'Big events' if tier == 'big' else 'All events'}, last {days} days"
    return pack["matchups"], "All events, last 90 days"


def row_ids(m):
    return m.get("rows") or m["archetypes"]


def cell(m, a, b):
    for c in m["cells"]:
        if c[0] == a and c[1] == b: return c[2], c[3], c[4]
        if c[0] == b and c[1] == a: return c[3], c[2], c[4]
    return None


def wilson(wins, n, z=1.6449):
    """testdata/insight-charts make_cases.py `wilson` (the apps call InsightCharts.wilson)."""
    if n <= 0: return [0.0, 1.0]
    p = wins / n; d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d; h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [max(0.0, c - h), min(1.0, c + h)]


def pct(x):
    """InsightCharts.pct: whole percent from 10%, else one decimal."""
    return f"{round(x * 100)}%" if x >= 0.0995 or x == 0 else f"{x * 100:.1f}%"


def cell_detail(pack, tier, days, a, b):
    """A tapped square, worded as the Insights tab's grid: "A vs B", the win rate with its likely range from 30
    matches (else "Only N matches: too few to say"), and the record (draws only when there are some). None when the
    pair has no decided match or a row meets itself."""
    if a == b: return None
    m, _ = grid_of(pack, tier, days)
    x = cell(m, a, b)
    if not x or x[0] + x[1] == 0: return None
    n = x[0] + x[1]
    lo, hi = wilson(x[0], n)
    line = f"{x[0] / n * 100:.1f}% · likely {pct(lo)}–{pct(hi)}" if n >= 30 else f"Only {n} matches: too few to say"
    record = f"{x[0]}-{x[1]}" + (f"-{x[2]}" if x[2] > 0 else "")
    return {"title": f"{name(pack, a)} vs {name(pack, b)}", "line": line, "record": record}


def grid(pack, tier, days, max_rows, max_cols):
    """The top-left of the matchup grid that fits: the most played columns and the first rows. A row's own column is
    null; a pair with no matches is a cell with tone none."""
    m, title = grid_of(pack, tier, days)
    sl = slots(pack, tier, days)
    cols = m["archetypes"][:max_cols]
    rows = row_ids(m)[:max_rows]
    cnames = [name(pack, a) for a in cols]
    cells = []
    for r in rows:
        line = []
        for c in cols:
            if r == c: line.append(None); continue
            x = cell(m, r, c) or (0, 0, 0)
            line.append(heat(x[0], x[1]))
        cells.append(line)
    return {"title": title,
            "cols": [{"a": a, "name": n, "code": k, "slot": sl.get(a)} for a, n, k in zip(cols, cnames, codes(cnames))],
            "rows": [{"a": a, "name": name(pack, a), "slot": sl.get(a)} for a in rows],
            "cells": cells}


def matchups(pack, tier, days, a):
    """One archetype against every other row of the grid, in the grid's order (most played first); pairs with no
    decided match are left out. Good / bad against: 20+ decided matches above / below 50%, three each, best (worst)
    first, then most matches (the deck screen's rule), never Other. Win rate and record from the window's Meta now row."""
    m, title = grid_of(pack, tier, days)
    w = window(pack, tier, days) or {"share": []}
    sl = slots(pack, tier, days)
    me = next((r for r in w["share"] if r["a"] == a), None)
    rows = []
    if a in row_ids(m):
        for b in row_ids(m):
            if b == a: continue
            x = cell(m, a, b)
            if not x or x[0] + x[1] == 0: continue
            rows.append({"vs": b, "name": name(pack, b), "slot": sl.get(b), "wins": x[0], "losses": x[1], "draws": x[2],
                         "wr": r4(x[0] / (x[0] + x[1])), "heat": heat(x[0], x[1])})
    decided = [r for r in rows if r["wins"] + r["losses"] >= 20 and r["vs"] != 0]
    good = sorted([r for r in decided if r["wr"] > 0.5], key=lambda r: (-r["wr"], -(r["wins"] + r["losses"])))[:3]
    bad = sorted([r for r in decided if r["wr"] < 0.5], key=lambda r: (r["wr"], -(r["wins"] + r["losses"])))[:3]
    rec = me.get("rec") if me else None
    return {"a": a, "name": name(pack, a), "slot": sl.get(a), "title": title,
            "share": r4(me["share"]) if me else None, "wr": r4(me.get("wr")) if me else None,
            "record": rec, "rows": rows, "good": [r["vs"] for r in good], "bad": [r["vs"] for r in bad]}


def choices(pack):
    """The archetypes a widget can follow: the 90-day grid's rows (they have matchups), then the other named ones by
    name. Never Other."""
    rows = [a for a in row_ids(pack["matchups"]) if a != 0]
    rest = sorted([x for x in pack["archetypes"] if x["id"] != 0 and x["id"] not in rows], key=lambda x: x["name"])
    return rows + [x["id"] for x in rest]


def main():
    pack = json.load(open(os.path.join(HERE, "modern.json")))
    thin = copy.deepcopy(pack)
    thin["tiers"]["big"]["windows"]["7"]["decks"] = 0
    del thin["tiers"]["big"]["windows"]["14"]
    for w in thin["tiers"]["all"]["windows"].values(): w.pop("matchups", None)

    top = [r["a"] for r in window(pack, "big", 30)["share"] if r["a"] != 0]
    cases = {
        "slots": SLOTS,
        "tier_for": [{"pack": p, "want": want, "days": d, "out": tier_for(P, want, d)}
                     for p, P in (("modern", pack), ("thin", thin)) for want in ("big", "all") for d in (7, 14, 30)],
        "breakdown": [{"tier": t, "days": d, "n": n, "out": breakdown(pack, t, d, n)}
                      for t, d, n in (("big", 30, 5), ("all", 7, 8), ("all", 90, 4), ("big", 14, 10))],
        "chart": [{"tier": t, "days": d, "ids": ids, "out": chart(pack, t, d, ids)}
                  for t, d, ids in (("big", 30, top[:5]), ("all", 7, top[:8]), ("all", 90, top[:3] + [999]))],
        "codes": [{"names": n, "out": codes(n)} for n in (
            ["Boros Energy", "Eldrazi Ramp", "Amulet Titan", "Esper Goryo's", "Burn"],
            ["Boros Energy", "Broodscale Engine", "Bant Energy", "Bogles", "Burn", "Burn Deluxe"],
            ["Grixis Reanimator", "Grixis Ragavan", "Grixis Ragavan", "Mono-Red", "Mono Red"])],
        "grid": [{"tier": t, "days": d, "rows": r, "cols": c, "out": grid(pack, t, d, r, c)}
                 for t, d, r, c in (("all", 30, 5, 5), ("big", 90, 12, 7), ("all", 7, 3, 10))],
        "grid_thin": {"tier": "all", "days": 30, "rows": 4, "cols": 4, "out": grid(thin, "all", 30, 4, 4)},
        "matchups": [{"tier": t, "days": d, "a": a, "out": matchups(pack, t, d, a)}
                     for t, d, a in (("all", 30, top[0]), ("big", 90, top[3]), ("all", 30, 999), ("all", 7, top[1]))],
        "choices": choices(pack),
        "cell_detail": [{"tier": t, "days": d, "a": a, "b": b, "out": cell_detail(pack, t, d, a, b)}
                        for t, d, a, b in (("big", 30, top[0], top[1]), ("all", 90, top[1], top[0]),
                                           ("all", 7, top[2], top[5]), ("big", 30, top[0], top[0]),
                                           ("all", 30, top[0], 999), ("big", 7, top[3], top[7]))],
    }
    with open(os.path.join(HERE, "cases.json"), "w") as f:
        json.dump(cases, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
