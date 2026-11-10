#!/usr/bin/env python3
"""Reference for the Limited page's cards and the matchup grid's Overall column
(contract/insights-2026-10-24.md § The Limited page / § Matchups "Overall"). Writes limited-home.json and overall.json,
which iOS InsightsPackTests, web insights.test.ts and Android InsightsPackTest check their rules against.

  python3 -I testdata/insights/make_limited_home.py
"""
import json
import os
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = 10          # cards shown before "Show all"
OTHERS_MAX = 20   # hits from other sets, once the picked set has none
MIN_QUERY = 2


def load(name):
    with open(os.path.join(HERE, name)) as f:
        return json.load(f)


# ---------------------------------------------------------------- cards: filter and sort

COLOR_ORDER = "WUBRGMC"
RARITY_ORDER = ["common", "uncommon", "rare", "mythic"]
RARITY_WORD = {"common": "Common", "uncommon": "Uncommon", "rare": "Rare", "mythic": "Mythic"}


def matches(c, rarity, color, rated):
    """Rarity and Color are both picks of several (empty = any). Rarity keeps a card of any picked rarity. Color keeps
    a colorless card when C is picked, a one-color card when its color is, and a multicolor card when Multi (M) is
    picked or every one of its colors is (W + U keeps white, blue and Azorius gold cards)."""
    if rated and rarity and c.get("r") not in rarity:
        return False
    if not color:
        return True
    col = c.get("col") or "C"
    if col == "C":
        return "C" in color
    if len(col) == 1:
        return col in color
    return "M" in color or all(ch in color for ch in col)


def rarity_label(rarity):
    """The Rarity cell: Any rarity, the one picked, or the picks' first letters in rarity order (C · U)."""
    picked = [r for r in RARITY_ORDER if r in rarity]
    if not picked:
        return "Any rarity"
    if len(picked) == 1:
        return RARITY_WORD[picked[0]]
    return " · ".join(RARITY_WORD[r][0] for r in picked)


def color_label(color):
    """The Color cell: Any color, Multi or Colorless alone, else the colors in WUBRG order then Multi and C (WU · Multi)."""
    picked = [k for k in COLOR_ORDER if k in color]
    if not picked:
        return "Any color"
    letters = "".join(k for k in picked if k in "WUBRG")
    rest = ["Multi" if k == "M" else "C" for k in picked if k in "MC"]
    if not letters and len(rest) == 1:
        return "Multi" if rest[0] == "Multi" else "Colorless"
    return " · ".join(([letters] if letters else []) + rest)


def key(c, sort):
    if sort == "ata":
        return None if c.get("ata") is None else -c["ata"]
    return c.get(sort)


def limited_cards(cards, sort, rarity, color):
    """The cards the filters keep, best first: the sort's value high to low (ATA low to high), cards without one last;
    ties by games in hand, then name."""
    rated = any(c.get("r") for c in cards)
    kept = [c for c in cards if matches(c, rarity, color, rated)]

    def order(c):
        k = key(c, sort)
        return (0 if k is not None else 1, -(k or 0), -c["gih_n"], c["n"])
    return [c["n"] for c in sorted(kept, key=order)]


def pct1(x):
    return "–" if x is None else f"{x * 100:.1f}%"


def delta(d):
    if d is None:
        return ""
    v = abs(d * 100)
    return ("+" if d >= 0 else "-") + (str(int(v + 0.5)) if v >= 10 else f"{v:.1f}")


def value(c, sort, avg):
    """The row's number and, for the win rates, how far it sits from the format's average (points)."""
    if sort == "ata":
        return {"value": "–" if c.get("ata") is None else f"{c['ata']:.1f}", "vs": None}
    if sort == "iwd":
        return {"value": "–" if c.get("iwd") is None else delta(c["iwd"]), "vs": None}
    x = c.get(sort)
    return {"value": pct1(x), "vs": None if x is None else delta(x - avg)}


# ---------------------------------------------------------------- search

def norm(s):
    s = unicodedata.normalize("NFKD", s.lower().replace("æ", "ae"))
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = s.replace("'", "").replace("’", "")
    out = "".join(ch if ch.isascii() and ch.isalnum() else " " for ch in s)
    return " ".join(out.split())


def rank(name, q):
    n = norm(name)
    if n.startswith(q):
        return 0
    if (" " + q) in (" " + n):
        return 1
    if q in n:
        return 2
    return None


def search(query, here, others):
    """The picked set's cards whose name holds the query (all of them, whatever the filters), starts first; when none
    does, the other sets' (up to OTHERS_MAX), with the set they're in."""
    q = norm(query)
    if len(q) < MIN_QUERY:
        return {"here": [], "elsewhere": []}
    hits = sorted(((rank(c["n"], q), c["n"]) for c in here if rank(c["n"], q) is not None))
    if hits:
        return {"here": [n for _, n in hits], "elsewhere": []}
    more = []
    for si, s in enumerate(others):
        for c in s["cards"]:
            r = rank(c["n"], q)
            if r is not None:
                more.append((r, c["n"], si, s["key"]))
    more.sort()
    return {"here": [], "elsewhere": [[k, n] for _, n, _, k in more[:OTHERS_MAX]]}


# ---------------------------------------------------------------- overall

def overall(share, m, a):
    """A grid row's overall match record: the window's record for the archetype (its Meta now row's `rec`), else the
    sum of its squares against every other row. Draws counted, not in the rate."""
    for s in share:
        if s["a"] == a and s.get("rec") and sum(s["rec"]) > 0 and s["rec"][0] + s["rec"][1] > 0:
            w, l, d = s["rec"]
            return {"wins": w, "losses": l, "draws": d, "from": "meta"}
    rows = m.get("rows") or m["archetypes"]
    w = l = d = 0
    for b in rows:
        if b == a:
            continue
        cell = cell_of(m, a, b)
        if cell:
            w, l, d = w + cell[0], l + cell[1], d + cell[2]
    return {"wins": w, "losses": l, "draws": d, "from": "grid"} if w + l else None


def cell_of(m, a, b):
    for x, y, w, l, d in m["cells"]:
        if x == a and y == b:
            return (w, l, d)
        if x == b and y == a:
            return (l, w, d)
    return None


def main():
    fra = load("limited-FRA.json")
    cube = load("limited-CUBE.json")
    v = fra["events"]["PremierDraft"]["groups"]["all"]
    cards = [{k: c.get(k) for k in ("n", "r", "col", "gih", "gih_n", "oh", "iwd", "ata")} for c in v["cards"][:60]]
    # a tie on GIH to pin the tie-break, and a card with no win rate
    cards.append({"n": "Tied Twin", "r": "common", "col": "W", "gih": cards[3]["gih"], "gih_n": cards[3]["gih_n"], "oh": None, "iwd": None, "ata": None})
    cards.append({"n": "Rare Sight", "r": "rare", "col": "G", "gih": None, "gih_n": 120, "oh": None, "iwd": None, "ata": 2.0})
    avg = v["wr"]
    sorts = [("gih", [], []), ("oh", [], []), ("iwd", [], []), ("ata", [], []),
             ("gih", ["common"], []), ("gih", [], ["W"]), ("gih", [], ["M"]), ("gih", [], ["C"]), ("gih", ["rare"], ["G"]),
             ("gih", ["common", "uncommon"], []), ("gih", [], ["W", "U"]), ("gih", [], ["U", "B", "C"]), ("gih", [], ["R", "M"]),
             ("gih", ["rare", "mythic"], ["W", "U", "B", "R", "G"])]
    # gold cards to pin "every one of its colors"
    cards.append({"n": "Azorius Pact", "r": "uncommon", "col": "WU", "gih": 0.58, "gih_n": 900, "oh": None, "iwd": None, "ata": 4.1})
    cards.append({"n": "Esper Pact", "r": "rare", "col": "WUB", "gih": 0.57, "gih_n": 400, "oh": None, "iwd": None, "ata": 3.2})
    rated_less = [{**c, "r": None} for c in cards[:12]]
    case_cards = [{"name": f"{s} · {'+'.join(r) or 'any'} · {'+'.join(col) or 'any'}", "sort": s, "rarity": r, "color": col,
                   "want": limited_cards(cards, s, r, col)} for s, r, col in sorts]
    case_cards.append({"name": "a cube: no rarity, so no rarity filter", "unrated": True, "sort": "gih", "rarity": ["common"], "color": [],
                       "want": limited_cards(rated_less, "gih", ["common"], [])})
    picks = [[], ["common"], ["uncommon", "common"], ["mythic", "rare", "uncommon", "common"]]
    case_rarity = [{"picked": r, "want": rarity_label(r)} for r in picks]
    cpicks = [[], ["W"], ["M"], ["C"], ["U", "W"], ["G", "M"], ["B", "C"], ["M", "C"], ["W", "U", "B", "R", "G", "M", "C"]]
    case_color = [{"picked": c, "want": color_label(c)} for c in cpicks]
    values = []
    for s in ("gih", "oh", "iwd", "ata"):
        for c in cards[:3] + cards[-1:]:
            values.append({"card": c["n"], "sort": s, "want": value(c, s, avg)})
    other_sets = [{"key": "CUBE", "cards": [{"n": c["n"]} for c in cube["events"]["PremierDraft"]["groups"]["all"]["cards"][:80]]},
                  {"key": "OLD", "cards": [{"n": "Lightning Bolt"}, {"n": "Bolt Bend"}, {"n": "Thunderbolt"}, {"n": "Æther Vial"}, {"n": "Urza's Saga"}]}]
    here = [{"n": c["n"]} for c in cards]
    queries = ["is", "isl", "  ISLAND ", "x", "bolt", "aether", "urzas", "zzzz", cards[5]["n"].split()[0][:4], cards[7]["n"][-4:]]
    case_search = [{"query": q, "want": search(q, here, other_sets)} for q in queries]
    out = {
        "about": "The Limited page's cards (contract/insights-2026-10-24.md § The Limited page). `cards` are a pack view's cards; "
                 "each `filters` case is limitedCards(cards, sort, rarity, color) → names in order, rarity and color "
                 "each a list of picks, empty = any (`unrated`: the cards with rarity removed, as in an Arena cube). `labels` are the "
                 "Rarity and Color cells' words for a pick. `values` are the row's number and how far it sits from `avg` (the view's "
                 "average game win rate). `search` cases are limitedSearch(query, cards, others).",
        "top": TOP, "others_max": OTHERS_MAX, "min_query": MIN_QUERY, "avg": avg,
        "cards": cards, "others": other_sets,
        "filters": case_cards, "labels": {"rarity": case_rarity, "color": case_color}, "values": values, "search": case_search,
    }
    with open(os.path.join(HERE, "limited-home.json"), "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")

    modern = load("constructed-modern.json")
    tier = modern["tiers"]["big"]
    w = tier["windows"]["30"]
    m = modern["matchups"]
    share = w["share"]
    rows = m.get("rows") or m["archetypes"]
    with_rec = [{"a": s["a"], "rec": s.get("rec")} for s in share]
    # the demo pack predates `rec`: one archetype gets a record, so both sources are pinned
    if rows:
        with_rec = [r for r in with_rec if r["a"] != rows[0]] + [{"a": rows[0], "rec": [40, 30, 2]}]
    cases = [{"a": a, "want": overall(with_rec, m, a)} for a in rows] + [{"a": 999999, "want": overall(with_rec, m, 999999)}]
    with open(os.path.join(HERE, "overall.json"), "w") as f:
        json.dump({"about": "The matchup grid's Overall column (contract/insights-2026-10-24.md § Matchups 'Overall'): overall(share, grid, a) "
                            "is the window's Meta now record (`rec`: wins, losses, draws) when it has one, else the sum of the row's "
                            "squares against every other row. null when there's no match at all.",
                   "share": with_rec, "matchups": m, "cases": cases}, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
