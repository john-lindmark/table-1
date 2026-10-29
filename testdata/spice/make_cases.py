#!/usr/bin/env python3
"""Reference implementation of Spice (contract/spice-2026-10-28.md), written independently of the server function.
It builds a small corpus (tournament lists for two formats and a set of comparison cubes) and writes cases.json:

- supabase/tests/66_spice_test.sql loads the corpus into a fresh database and checks t1_private.spice_deck /
  t1_private.spice_cube give `expect` for every case;
- the iOS (SpiceTests), web (spice.test.ts) and Android (SpiceTest) suites decode every `expect` and check they show
  exactly `display`.

    python3 -I testdata/spice/make_cases.py      # rewrites testdata/spice/cases.json
"""
import json
from datetime import date, timedelta
from fractions import Fraction
from pathlib import Path

TODAY = date(2026, 10, 28)
MIN_LISTS = 30            # peers needed before a basis is used
STOCK = Fraction(1, 4)    # a card in this share of peer lists or more is stock
STOCK_SINGLETON = Fraction(1, 10)
CLOSE = Fraction(1, 4)    # the closest archetype must play this much of the deck
MISSING = Fraction(1, 2)  # stock cards you don't play: in half the peer lists or more
MISSING_MAX = 12
CUBE_PEERS = 20
CUBE_MIN = 5
CUBE_CLOSE = Fraction(15, 100)
SINGLETON = {"canlander"}
SOURCES = {"mtgo": "MTGO", "topdeck": "TopDeck.gg", "melee": "Melee"}


def cid(n):
    return f"c0000000-0000-0000-0000-{n:012d}"


# ---- catalog: name, colour identity, basic? ----
CARDS = {}


def card(n, name, ci="", basic=False):
    CARDS[cid(n)] = {"name": name, "ci": ci, "basic": basic}
    return cid(n)


PLAINS, MOUNTAIN, ISLAND = card(1, "Plains", basic=True), card(2, "Mountain", basic=True), card(3, "Island", basic=True)
# Boros Energy (archetype 1)
BOLT, GUIDE, RAGAVAN, PHLAGE, ORNITHOPTER = (card(10, "Lightning Bolt", "R"), card(11, "Guide of Souls", "W"),
                                             card(12, "Ragavan, Nimble Pilferer", "R"), card(13, "Phlage, Titan of Fire's Fury", "RW"),
                                             card(14, "Ornithopter"))
GALVANIC, SEASONED, FLEX_A, FLEX_B = (card(15, "Galvanic Discharge", "R"), card(16, "Seasoned Pyromancer", "R"),
                                      card(17, "Static Prison", "W"), card(18, "Blood Moon", "R"))
SIDE_A = card(19, "Wear // Tear", "RW")
# Murktide (archetype 2)
MURKTIDE, COUNTERSPELL, DELVER, CONSIDER = (card(20, "Murktide Regent", "U"), card(21, "Counterspell", "U"),
                                            card(22, "Delver of Secrets", "U"), card(23, "Consider", "U"))
# Thin archetype (3): Hammer Time
HAMMER, SIGARDA = card(30, "Colossus Hammer", ""), card(31, "Sigarda's Aid", "W")
# Never seen anywhere
GRUDGE, BRUTE, OATH = card(40, "Ancient Grudge", "RG"), card(41, "Brute Force", "R"), card(42, "Oath of Druids", "G")
# Canadian Highlander
CL = {k: card(50 + i, k, ci) for i, (k, ci) in enumerate([
    ("Sol Ring", ""), ("Brainstorm", "U"), ("Swords to Plowshares", "W"), ("Dark Ritual", "B"), ("Lotus Petal", ""),
    ("Force of Will", "U"), ("Ponder", "U"), ("Thoughtseize", "B"), ("Daze", "U"), ("Kaya's Guile", "WB"),
    ("Skullclamp", ""), ("Retrofitter Foundry", "")])}
# Cubes
CUBE_CARDS = [card(100 + i, f"Cube Card {i:03d}", "WUBRG"[i % 5]) for i in range(120)]

NAMES = {
    1: "Boros Energy", 2: "Murktide", 3: "Hammer Time",
}


# ---- corpus ----

class Corpus:
    def __init__(self):
        self.events = []   # {id, source, format, on}
        self.decks = []    # {id, event, format, on, archetype, colors, main: [(c, q)], side: [(c, q)]}

    def event(self, source, fmt, days_ago):
        e = {"id": len(self.events) + 1, "source": source, "format": fmt, "on": (TODAY - timedelta(days=days_ago)).isoformat()}
        self.events.append(e)
        return e

    def deck(self, e, archetype, main, side=(), colors=""):
        d = {"id": len(self.decks) + 1, "event": e["id"], "format": e["format"], "on": e["on"], "archetype": archetype,
             "colors": colors, "main": [list(x) for x in main], "side": [list(x) for x in side]}
        self.decks.append(d)
        return d


C = Corpus()
BOROS_CORE = [(BOLT, 4), (GUIDE, 4), (RAGAVAN, 4), (PHLAGE, 3), (GALVANIC, 4), (MOUNTAIN, 4), (PLAINS, 3)]
MURK_CORE = [(MURKTIDE, 4), (COUNTERSPELL, 4), (DELVER, 4), (CONSIDER, 4), (BOLT, 4), (ISLAND, 6)]

# Modern, 90 days: 40 Boros Energy (MTGO), varying flex slots; 35 Murktide (half TopDeck); 10 Hammer Time
for i in range(40):
    e = C.event("mtgo", "modern", 3 + i % 60)
    flex = []
    if i % 2 == 0:
        flex.append((SEASONED, 2))         # 50%
    if i % 5 == 0:
        flex.append((FLEX_A, 1))           # 20%
    if i % 10 == 0:
        flex.append((FLEX_B, 2))           # 10%
    C.deck(e, 1, BOROS_CORE + flex, side=[(SIDE_A, 2)] if i % 4 == 0 else [], colors="RW")
for i in range(35):
    e = C.event("topdeck" if i % 2 else "mtgo", "modern", 5 + i % 70)
    C.deck(e, 2, MURK_CORE + ([(ORNITHOPTER, 1)] if i == 0 else []), colors="UR")
for i in range(10):
    e = C.event("mtgo", "modern", 10 + i)
    C.deck(e, 3, [(HAMMER, 4), (SIGARDA, 4), (ORNITHOPTER, 4), (PLAINS, 8)], colors="W")
# Hammer Time, 91–300 days ago: 25 more (35 in a year)
for i in range(25):
    e = C.event("mtgo", "modern", 120 + i)
    C.deck(e, 3, [(HAMMER, 4), (SIGARDA, 4), (ORNITHOPTER, 4), (PLAINS, 8)], colors="W")
# Other (archetype 0): 12 piles of the format's cards
for i in range(12):
    e = C.event("mtgo", "modern", 7 + i)
    C.deck(e, 0, [(BOLT, 4), (CONSIDER, 4), (MOUNTAIN, 10)], colors="R")
# A list older than a year never counts
C.deck(C.event("mtgo", "modern", 400), 1, [(GRUDGE, 4), (MOUNTAIN, 20)], colors="R")

# Canadian Highlander: 40 lists in a year, colours vary
CL_SHAPES = [
    ("U", ["Sol Ring", "Brainstorm", "Force of Will", "Ponder", "Daze"]),
    ("UB", ["Sol Ring", "Brainstorm", "Force of Will", "Thoughtseize", "Dark Ritual", "Ponder"]),
    ("WB", ["Sol Ring", "Swords to Plowshares", "Thoughtseize", "Kaya's Guile", "Lotus Petal"]),
    ("W", ["Sol Ring", "Swords to Plowshares", "Lotus Petal", "Skullclamp"]),
]
for i in range(40):
    e = C.event("topdeck", "canlander", 10 + i * 8)
    colors, names = CL_SHAPES[i % 4]
    C.deck(e, 0, [(CL[n], 1) for n in names] + [(PLAINS, 1)], colors=colors)

# Comparison cubes: 24 cubes over the 120 cube cards. Cube k holds cards [k*2, k*2 + 60) (wrapping), so neighbours
# overlap a lot and far ones little; cube 24 is a copy of cube 3 (the lower id, cube 3, is the one left out).
CUBES = []
for k in range(23):
    cards = sorted({CUBE_CARDS[(k * 2 + j) % 120] for j in range(60)})
    CUBES.append({"id": k + 1, "source": "cubecobra", "source_id": f"cube{k + 1:02d}", "name": f"Cube {k + 1:02d}",
                  "cards": cards})
CUBES.append({"id": 24, "source": "cubecobra", "source_id": "copy-of-03", "name": "Cube 03 copy", "cards": CUBES[2]["cards"]})


# ---- reference ----

def is_basic(c):
    return CARDS[c]["basic"]


def fold(lines):
    """[(c, q)] → {c: q} summed, keeping first-seen order."""
    out = {}
    for c, q in lines:
        out[c] = out.get(c, 0) + q
    return out


def same_main(d, main):
    return sorted((c, q) for c, q in fold(d["main"]).items()) == sorted(main.items())


def window(fmt, days, main_all):
    """The format's lists in the window, less one list identical to the deck: the newest of the year's (then the
    highest id), the one a deck copied from Insights most likely came from. Other identical lists stay."""
    year = [d for d in C.decks if d["format"] == fmt and date.fromisoformat(d["on"]) > TODAY - timedelta(days=365)]
    twins = [d for d in year if same_main(d, main_all)]
    twin = max(twins, key=lambda d: (d["on"], d["id"]))["id"] if twins else None
    return [d for d in year if date.fromisoformat(d["on"]) > TODAY - timedelta(days=days) and d["id"] != twin]


def r4(x):
    """Round half up to 4 places (decimal), as numeric round() does."""
    return float(round_half_up(x, 4))


def round_half_up(x, places):
    q = Fraction(10) ** places
    v = x * q
    n = v.numerator // v.denominator
    if v - n >= Fraction(1, 2):
        n += 1
    return Fraction(n) / q


def score_int(x):
    return int(round_half_up(x * 100, 0))


def word(score):
    if score < 10:
        return "stock"
    if score < 25:
        return "tuned"
    if score < 50:
        return "spicy"
    return "brew"


def sources_of(pool):
    ev = {e["id"]: e for e in C.events}
    have = {ev[d["event"]]["source"] for d in pool}
    return [s for s in ("mtgo", "topdeck") if s in have]


def deck_spice(fmt, label, main_lines, side_lines=()):
    main_all = fold(main_lines)
    main = {c: q for c, q in main_all.items() if not is_basic(c)}
    side = {c: q for c, q in fold(side_lines).items() if not is_basic(c)}
    if not main:
        return {"kind": "deck", "score": None, "word": None, "basis": None, "cards": [], "stock_missing": [],
                "reason": "empty"}
    year = window(fmt, 365, main_all)
    if len(year) < MIN_LISTS:
        return {"kind": "deck", "score": None, "word": None, "basis": None, "cards": [], "stock_missing": [],
                "reason": "no_data"}

    if fmt in SINGLETON:
        return singleton_spice(fmt, main, side, year)

    basis = None
    if label:
        for days in (90, 365):
            pool = [d for d in window(fmt, days, main_all) if d["archetype"] == label]
            if len(pool) >= MIN_LISTS:
                basis = ("archetype", label, days, pool)
                break
    if basis is None:
        for days in (90, 365):
            w = window(fmt, days, main_all)
            groups = {}
            for d in w:
                if d["archetype"]:
                    groups.setdefault(d["archetype"], []).append(d)
            groups = {a: p for a, p in groups.items() if len(p) >= MIN_LISTS}
            if not groups:
                continue
            total = sum(main.values())
            best = None
            for a, p in groups.items():
                fit = sum(q * Fraction(sum(1 for d in p if c in fold(d["main"])), len(p)) for c, q in main.items()) / total
                key = (fit, len(p), -a)
                if best is None or key > best[0]:
                    best = (key, a, p)
            if best[0][0] >= CLOSE:
                basis = ("closest", best[1], days, best[2])
            break
    if basis is None:
        w90 = window(fmt, 90, main_all)
        if len(w90) >= MIN_LISTS:
            basis = ("format", None, 90, w90)
        else:
            basis = ("format", None, 365, year)

    kind, arch, days, pool = basis
    n = len(pool)
    mains = [fold(d["main"]) for d in pool]
    sides = [fold(d["side"]) for d in pool]
    seen_main = {c: sum(1 for m in mains if c in m) for c in main}
    seen_side = {c: sum(1 for s in sides if c in s) for c in side}
    total = sum(main.values())
    spice = sum(q * max(Fraction(0), 1 - Fraction(seen_main[c], n) / STOCK) for c, q in main.items()) / total
    cards = []
    for c, q in main.items():
        cards.append({"c": c, "n": CARDS[c]["name"], "section": "main", "copies": q,
                      "rate": r4(Fraction(seen_main[c], n)), "seen": seen_main[c], "of": n})
    for c, q in side.items():
        cards.append({"c": c, "n": CARDS[c]["name"], "section": "side", "copies": q,
                      "rate": r4(Fraction(seen_side[c], n)), "seen": seen_side[c], "of": n})
    cards = [x for x in cards if Fraction(x["seen"], x["of"]) < STOCK]
    cards.sort(key=lambda x: (x["section"] != "main", x["seen"], -x["copies"], x["n"]))
    counts = {}
    for m in mains:
        for c in m:
            if not is_basic(c):
                counts[c] = counts.get(c, 0) + 1
    missing = [{"c": c, "n": CARDS[c]["name"], "rate": r4(Fraction(k, n)), "seen": k, "of": n}
               for c, k in counts.items() if Fraction(k, n) >= MISSING and c not in main]
    missing.sort(key=lambda x: (-x["seen"], x["n"]))
    if kind == "format":
        missing = []        # the whole format's staples say nothing about this deck
    s = score_int(spice)
    return {"kind": "deck", "score": s, "word": word(s), "reason": None,
            "basis": {"kind": kind, "format": fmt, "archetype": arch, "name": NAMES.get(arch), "lists": n,
                      "days": days, "sources": sources_of(pool), "close": None, "cubes": None},
            "cards": cards, "stock_missing": missing[:MISSING_MAX]}


def singleton_spice(fmt, main, side, pool):
    def eligible(c):
        ci = set(CARDS[c]["ci"])
        return [d for d in pool if ci <= set(d["colors"])]

    def rate_of(c, board):
        e = eligible(c)
        k = sum(1 for d in e if c in fold(d[board]))
        return k, len(e)

    total = sum(main.values())
    spice = Fraction(0)
    cards = []
    for c, q in main.items():
        k, of = rate_of(c, "main")
        r = Fraction(k, of) if of else Fraction(0)
        spice += q * max(Fraction(0), 1 - r / STOCK_SINGLETON)
        if r < STOCK_SINGLETON:
            cards.append({"c": c, "n": CARDS[c]["name"], "section": "main", "copies": q, "rate": r4(r), "seen": k, "of": of})
    for c, q in side.items():
        k, of = rate_of(c, "side")
        r = Fraction(k, of) if of else Fraction(0)
        if r < STOCK_SINGLETON:
            cards.append({"c": c, "n": CARDS[c]["name"], "section": "side", "copies": q, "rate": r4(r), "seen": k, "of": of})
    cards.sort(key=lambda x: (x["section"] != "main", x["seen"], -x["copies"], x["n"]))
    s = score_int(spice / total)
    return {"kind": "deck", "score": s, "word": word(s), "reason": None,
            "basis": {"kind": "colors", "format": fmt, "archetype": None, "name": None, "lists": len(pool), "days": 365,
                      "sources": sources_of(pool), "close": None, "cubes": None},
            "cards": cards, "stock_missing": []}


def cube_spice(main_lines, corpus=CUBES):
    main = {c: q for c, q in fold(main_lines).items() if not is_basic(c)}
    if not main:
        return {"kind": "cube", "score": None, "word": None, "basis": None, "cards": [], "stock_missing": [],
                "reason": "empty"}
    mine = set(main)
    twin = min((k["id"] for k in corpus if set(k["cards"]) == mine), default=None)   # one copy left out, as for decks
    sims = []
    for k in corpus:
        other = set(k["cards"])
        if k["id"] == twin:
            continue
        inter = len(mine & other)
        if inter == 0:
            continue
        sims.append((Fraction(inter, len(mine | other)), k))
    if len(sims) < CUBE_MIN:
        return {"kind": "cube", "score": None, "word": None, "basis": None, "cards": [], "stock_missing": [],
                "reason": "no_cubes"}
    sims.sort(key=lambda x: (-x[0], x[1]["source_id"]))
    peers = sims[:CUBE_PEERS]
    wsum = sum(w for w, _ in peers)
    total = sum(main.values())

    def rate(c):
        return sum(w for w, k in peers if c in k["cards"]) / wsum

    spice = sum(q * max(Fraction(0), 1 - rate(c) / STOCK) for c, q in main.items()) / total
    cards = []
    for c, q in main.items():
        r = rate(c)
        if r < STOCK:
            cards.append({"c": c, "n": CARDS[c]["name"], "section": "main", "copies": q, "rate": r4(r),
                          "seen": sum(1 for _, k in peers if c in k["cards"]), "of": len(peers)})
    cards.sort(key=lambda x: (x["rate"], -x["copies"], x["n"]))
    pool = set().union(*(set(k["cards"]) for _, k in peers))
    missing = []
    for c in pool:
        if c in mine or is_basic(c):
            continue
        r = rate(c)
        if r >= MISSING:
            missing.append({"c": c, "n": CARDS[c]["name"], "rate": r4(r),
                            "seen": sum(1 for _, k in peers if c in k["cards"]), "of": len(peers)})
    missing.sort(key=lambda x: (-x["rate"], x["n"]))
    s = score_int(spice)
    return {"kind": "cube", "score": s, "word": word(s), "reason": None,
            "basis": {"kind": "cubes", "format": None, "archetype": None, "name": None, "lists": len(peers), "days": None,
                      "sources": ["cubecobra"], "close": peers[0][0] >= CUBE_CLOSE,
                      "cubes": [{"name": k["name"], "overlap": r4(w)} for w, k in peers[:5]]},
            "cards": cards, "stock_missing": missing[:MISSING_MAX]}


# ---- what every client shows ----

FORMAT_NAMES = {"modern": "Modern", "canlander": "Canadian Highlander", "legacy": "Legacy", "pauper": "Pauper",
                "standard": "Standard", "pioneer": "Pioneer"}
WORDS = {"stock": "Stock", "tuned": "Tuned", "spicy": "Spicy", "brew": "Brew"}
REASONS = {"empty": "Add cards to see how spicy this is",
           "no_data": "No tournament lists for this format yet",
           "no_cubes": "No cubes to compare with yet"}


def plural(n, one, many):
    return f"{n} {one if n == 1 else many}"


def display(r):
    if r["score"] is None:
        return {"summary": None, "headline": None, "basis": None, "cubes": [], "cards": [], "missing": [],
                "reason": REASONS[r["reason"]]}
    b = r["basis"]
    when = "last year" if b["days"] == 365 else f"last {b['days']} days" if b["days"] else None
    names = [SOURCES.get(s, "Cube Cobra") for s in b["sources"]]
    src = names[0] if len(names) < 2 else ", ".join(names[:-1]) + " and " + names[-1]
    fmt = FORMAT_NAMES.get(b["format"], b["format"])
    if b["kind"] == "archetype":
        line = f"{plural(b['lists'], b['name'] + ' list', b['name'] + ' lists')} · {when} · {src}"
    elif b["kind"] == "closest":
        line = f"Closest archetype: {b['name']} · {plural(b['lists'], 'list', 'lists')} · {when} · {src}"
    elif b["kind"] == "format":
        line = f"Nothing close in {fmt} · {plural(b['lists'], 'list', 'lists')} · {when} · {src}"
    elif b["kind"] == "colors":
        line = f"{fmt} lists that can play each card · {plural(b['lists'], 'list', 'lists')} · {when} · {src}"
    else:
        lead = f"The {b['lists']} cubes most like yours" if b["close"] else "No cubes much like this one"
        line = f"{lead} · {src}"

    def card_line(x):
        noun = {"colors": "lists that can play it", "cubes": "similar cubes"}.get(b["kind"], "lists")
        if x["seen"] == 0:
            return "never seen" if b["kind"] != "cubes" else "in no similar cube"
        return f"in {x['seen']} of {x['of']} {noun}"

    return {
        "summary": f"Spice {r['score']}",
        "headline": f"{r['score']} · {WORDS[r['word']]}",
        "basis": line,
        # Whole percent from the 4-place overlap: basis points, half up.
        "cubes": [f"{k['name']} · {(round(k['overlap'] * 10000) + 50) // 100}% alike" for k in (b["cubes"] or [])],
        "cards": [f"{x['copies']} {x['n']} · {card_line(x)}" + (" · sideboard" if x["section"] == "side" else "")
                  for x in r["cards"]],
        "missing": [f"{x['n']} · in {x['seen']} of {x['of']} {'similar cubes' if b['kind'] == 'cubes' else 'lists'}"
                    for x in r["stock_missing"]],
        "reason": None,
    }


def case(name, kind, fmt, label, main, side=(), **extra):
    exp = cube_spice(main) if kind == "cube" else deck_spice(fmt, label, main, side)
    return {"name": name, "kind": kind, "format": fmt, "label": label,
            "main": [list(x) for x in main], "side": [list(x) for x in side], **extra,
            "expect": exp, "display": display(exp)}


CASES = [
    case("stock Boros Energy", "deck", "modern", 1, BOROS_CORE + [(SEASONED, 2)], side=[(SIDE_A, 2)]),
    case("tuned Boros Energy", "deck", "modern", 1, BOROS_CORE + [(FLEX_A, 2), (FLEX_B, 2), (GRUDGE, 1)]),
    case("brewed Boros Energy", "deck", "modern", 1,
         [(BOLT, 4), (GUIDE, 4), (GRUDGE, 4), (BRUTE, 4), (OATH, 4), (MOUNTAIN, 20)], side=[(OATH, 1), (SIDE_A, 3)]),
    case("Other labels to the closest archetype", "deck", "modern", 0,
         [(MURKTIDE, 4), (COUNTERSPELL, 4), (DELVER, 2), (BRUTE, 4), (ISLAND, 10)]),
    case("nothing close: the whole format", "deck", "modern", 0, [(GRUDGE, 4), (BRUTE, 4), (OATH, 4), (BOLT, 1)]),
    case("thin archetype reads a year", "deck", "modern", 3, [(HAMMER, 4), (SIGARDA, 4), (GRUDGE, 4), (PLAINS, 8)]),
    case("a copy of a corpus list leaves it out", "deck", "modern", 3,
         [(HAMMER, 4), (SIGARDA, 4), (ORNITHOPTER, 4), (PLAINS, 8)]),
    case("only basics", "deck", "modern", 1, [(MOUNTAIN, 20), (PLAINS, 20)]),
    case("a format without lists", "deck", "legacy", 0, [(BOLT, 4), (MOUNTAIN, 16)]),
    case("Canadian Highlander by colours", "deck", "canlander", 0,
         [(CL[n], 1) for n in ["Sol Ring", "Brainstorm", "Force of Will", "Daze", "Retrofitter Foundry", "Swords to Plowshares"]]
         + [(GRUDGE, 1), (PLAINS, 1)]),
    case("cube among close cubes", "cube", None, None, [(c, 1) for c in CUBES[5]["cards"][:50]] + [(GRUDGE, 1), (BRUTE, 1)]),
    case("cube with nothing close", "cube", None, None, [(c, 1) for c in CUBE_CARDS[::10]] + [(CL[n], 1) for n in CL]),
    case("cube identical to a corpus cube", "cube", None, None, [(c, 1) for c in CUBES[2]["cards"]]),
    case("cube of strangers", "cube", None, None, [(GRUDGE, 1), (BRUTE, 1), (OATH, 1)]),
]

OUT = {
    "today": TODAY.isoformat(),
    "constants": {"min_lists": MIN_LISTS, "stock": float(STOCK), "stock_singleton": float(STOCK_SINGLETON),
                  "close": float(CLOSE), "missing": float(MISSING), "cube_peers": CUBE_PEERS, "cube_min": CUBE_MIN,
                  "cube_close": float(CUBE_CLOSE)},
    "words": [{"score": s, "word": word(s), "label": WORDS[word(s)]} for s in (0, 9, 10, 24, 25, 49, 50, 100)],
    "corpus": {
        "cards": [{"c": c, "n": v["name"], "ci": v["ci"], "basic": v["basic"]} for c, v in CARDS.items()],
        "archetypes": [{"id": a, "format": "modern", "name": n} for a, n in NAMES.items()],
        "events": C.events,
        "decks": C.decks,
        "cubes": CUBES,
    },
    "cases": CASES,
}

if __name__ == "__main__":
    path = Path(__file__).with_name("cases.json")
    path.write_text(json.dumps(OUT, indent=1, ensure_ascii=False) + "\n")
    for c in CASES:
        d = c["display"]
        print(f"{c['name']:42} {d['headline'] or d['reason']}  |  {d['basis'] or ''}")
