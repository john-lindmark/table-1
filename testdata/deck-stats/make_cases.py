#!/usr/bin/env python3
"""Reference implementation of deck and cube stats (contract/lists-2026-10-15.md, "Stats"), written independently of
the three clients. It writes cases.json, which the iOS (DeckStatsTests), web (deckStats.test.ts) and Android
(DeckStatsTest) suites all read, so the same inputs give the same numbers on every platform.

    python3 -I testdata/deck-stats/make_cases.py      # rewrites testdata/deck-stats/cases.json
"""
import json
import math
import re
from pathlib import Path

M = 0xFFFFFFFF
COLORS = "WUBRG"
TYPES = ["Creature", "Planeswalker", "Instant", "Sorcery", "Artifact", "Enchantment", "Battle", "Land"]
BASIC_TYPES = {"Plains": "W", "Island": "U", "Swamp": "B", "Mountain": "R", "Forest": "G"}
COLOR_GROUPS = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"]
COLOR_NAMES = dict(zip(COLORS, COLOR_GROUPS))
LEGALITY_FORMATS = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander", "premodern"]
FOUR_OF = {"standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern"}
SINGLETON = {"commander", "canlander"}
ANY_NUMBER = {"Relentless Rats", "Rat Colony", "Shadowborn Apostle", "Persistent Petitioners", "Dragon's Approach",
              "Slime Against Humanity", "Hare Apparent", "Templar Knight", "Cid, Timeless Artificer"}
UP_TO = {"Seven Dwarves": 7, "Nazgûl": 9}


# ---- random numbers: mulberry32, multiply-shift bounded ints, Fisher-Yates ----

class Rng:
    def __init__(self, seed):
        self.a = seed & M

    def next(self):
        self.a = (self.a + 0x6D2B79F5) & M
        t = self.a
        t = ((t ^ (t >> 15)) * (t | 1)) & M
        t ^= (t + (((t ^ (t >> 7)) * (t | 61)) & M)) & M
        return (t ^ (t >> 14)) & M

    def int(self, bound):
        return (self.next() * bound) >> 32


def shuffle(n, rng):
    a = list(range(n))
    for i in range(n - 1, 0, -1):
        j = rng.int(i + 1)
        a[i], a[j] = a[j], a[i]
    return a


# ---- one card ----

def front(type_line):
    return type_line.split(" // ")[0]


def words(s):
    return re.findall(r"[A-Za-z]+", s)


def is_land(c):
    return "Land" in words(front(c["type"]).split(" — ")[0])


def is_creature(c):
    return "Creature" in words(front(c["type"]).split(" — ")[0])


def bucket(cmc):
    return min(7, int(math.floor(cmc)))


def pips(cost):
    out = [0] * 5
    for sym in re.findall(r"\{([^}]*)\}", cost):
        for i, col in enumerate(COLORS):
            if col in sym.split("/"):
                out[i] += 1
    return out


def produces(c):
    if not is_land(c):
        return ""
    subtypes = set()
    for face in c["type"].split(" // "):
        if " — " in face:
            subtypes.update(words(face.split(" — ", 1)[1]))
    return "".join(col for t, col in BASIC_TYPES.items() if t in subtypes)


def card_types(c):
    w = words(front(c["type"]).split(" — ")[0])
    return [t for t in TYPES if t in w]


def color_group(c):
    if is_land(c):
        return "Lands"
    if len(c["colors"]) == 0:
        return "Colorless"
    if len(c["colors"]) > 1:
        return "Multicolor"
    return COLOR_NAMES[c["colors"]]


# ---- decks ----

def deck_cards(cards):
    return [c for c in cards if c["board"] in ("main", "commander")]


def curve(cards):
    creatures, other = [0] * 8, [0] * 8
    for c in deck_cards(cards):
        if is_land(c):
            continue
        (creatures if is_creature(c) else other)[bucket(c["cmc"])] += c["qty"]
    return {"creatures": creatures, "other": other}


def type_counts(cards):
    out = {t: 0 for t in TYPES}
    for c in cards:
        for t in card_types(c):
            out[t] += c["qty"]
    return [out[t] for t in TYPES]


def average_mv(cards, with_lands):
    n = s = 0
    for c in deck_cards(cards):
        if not with_lands and is_land(c):
            continue
        n += c["qty"]
        s += c["cmc"] * c["qty"]
    return s / n if n else 0.0


def pip_totals(cards):
    out = [0] * 5
    for c in deck_cards(cards):
        for i, p in enumerate(pips(c["cost"])):
            out[i] += p * c["qty"]
    return out


def sources(cards):
    out = [0] * 5
    unread = 0
    for c in deck_cards(cards):
        if not is_land(c):
            continue
        p = produces(c)
        for i, col in enumerate(COLORS):
            if col in p:
                out[i] += c["qty"]
        if not p and "Basic" not in words(c["type"]):
            unread += c["qty"]
    return {"colors": out, "unread": unread}


def price(cards):
    total = 0.0
    unpriced = 0
    for c in cards:
        if c["board"] == "maybe":
            continue
        if c.get("usd") is None:
            unpriced += c["qty"]
        else:
            total += c["usd"] * c["qty"]
    return {"total": round(total, 2), "unpriced": unpriced}


def code_legality(code, fmt):
    f = "vintage" if fmt == "canlander" else fmt
    if f not in LEGALITY_FORMATS:
        return None
    i = LEGALITY_FORMATS.index(f)
    if i >= len(code):
        return None
    ch = code[i]
    if ch == "L":
        return "legal"
    if ch == "R":
        return "legal" if fmt == "canlander" else "restricted"
    if ch == "B":
        return "banned"
    return "not_legal"


def copy_limit(name, fmt, basic):
    """Most copies a deck may hold across main deck and sideboard, or None for no limit."""
    if basic or name in ANY_NUMBER:
        return None
    if name in UP_TO:
        return UP_TO[name]
    if fmt in SINGLETON:
        return 1
    if fmt in FOUR_OF:
        return 4
    return None


def legality(cards, fmt):
    copies, first = {}, {}
    for c in cards:
        if c["board"] == "maybe":
            continue
        copies[c["name"]] = copies.get(c["name"], 0) + c["qty"]
        first.setdefault(c["name"], c)
    out = []
    for name in sorted(copies):
        c, n = first[name], copies[name]
        basic = "Basic" in words(c["type"])
        code = code_legality(c["legal"], fmt)
        reason = None
        if code == "banned":
            reason = "Banned"
        elif code == "not_legal":
            reason = "Not legal"
        elif code == "restricted" and n > 1:
            reason = "Restricted to 1"
        else:
            limit = copy_limit(name, fmt, basic)
            if limit is not None and n > limit:
                reason = "Singleton" if limit == 1 else f"More than {limit} copies"
        if reason:
            out.append({"name": name, "reason": reason})
    return out


def hypergeometric(N, K, n, k):
    """P(at least k successes in n draws without replacement from N cards holding K successes)."""
    n = min(n, N)
    if k <= 0:
        return 1.0
    total = math.comb(N, n)
    return sum(math.comb(K, i) * math.comb(N - K, n - i) for i in range(k, min(K, n) + 1)) / total


def draws_by_turn(turn, on_play):
    return 7 + turn - (1 if on_play else 0)


# ---- the London mulligan, scripted ----

class SampleHand:
    def __init__(self, size, seed):
        self.size, self.rng = size, Rng(seed)
        self.mulligans = 0
        self.deal()

    def deal(self):
        order = shuffle(self.size, self.rng)
        self.hand, self.library = order[:7], order[7:]
        self.to_bottom = self.mulligans

    def mulligan(self):
        self.mulligans += 1
        self.deal()

    def bottom(self, i):
        self.library.append(self.hand.pop(i))
        self.to_bottom -= 1

    def draw(self):
        self.hand.append(self.library.pop(0))

    def state(self):
        return {"hand": list(self.hand), "library": len(self.library), "toBottom": self.to_bottom, "mulligans": self.mulligans}


# ---- cubes ----

def color_balance(cards):
    out = {g: 0 for g in COLOR_GROUPS}
    for c in cards:
        out[color_group(c)] += c["qty"]
    return [out[g] for g in COLOR_GROUPS]


def curve_by_color(cards):
    out = {g: [0] * 8 for g in COLOR_GROUPS[:-1]}
    for c in cards:
        g = color_group(c)
        if g != "Lands":
            out[g][bucket(c["cmc"])] += c["qty"]
    return [out[g] for g in COLOR_GROUPS[:-1]]


def asfan(cards, pack, by):
    total = sum(c["qty"] for c in cards)
    if by == "color":
        counts = color_balance(cards)
    elif by == "type":
        counts = type_counts(cards)
    else:  # mana value buckets 0..7+, then lands
        counts = [0] * 9
        for c in cards:
            counts[8 if is_land(c) else bucket(c["cmc"])] += c["qty"]
    return [pack * n / total if total else 0.0 for n in counts]


# ---- fixtures ----

def card(name, qty, board, type_, cost, cmc, colors, legal, usd=None, rarity="c"):
    return {"name": name, "qty": qty, "board": board, "type": type_, "cost": cost, "cmc": cmc, "colors": colors,
            "legal": legal, "rarity": rarity, "usd": usd}


DECK = [
    card("Lightning Bolt", 4, "main", "Instant", "{R}", 1, "R", "--LLLLLL", 1.5),
    card("Delver of Secrets // Insectile Aberration", 4, "main", "Creature — Human Wizard // Creature — Human Insect",
         "{U}", 1, "U", "--LLLLL-", 0.25),
    card("Brazen Borrower // Petty Theft", 3, "main", "Creature — Faerie Rogue // Instant — Adventure", "{1}{U}{U} // {1}{U}",
         3, "U", "-LLLL-L-", 12.0),
    card("Fire // Ice", 2, "main", "Instant // Instant", "{1}{R} // {1}{U}", 4, "UR", "--LLLLLL", 0.5),
    card("Snapcaster Mage", 2, "main", "Creature — Human Wizard", "{1}{U}", 2, "U", "-LLLL-L-", 20.0),
    card("Tarmogoyf", 1, "main", "Creature — Lhurgoyf", "{1}{G}", 2, "G", "--LLL-L-", 8.0),
    card("Gut Shot", 1, "main", "Instant", "{R/P}", 1, "R", "--BLL-L-", 0.3),
    card("Kitchen Finks", 1, "main", "Creature — Ouphe", "{1}{G/W}{G/W}", 3, "GW", "--LLL-LL", 0.4),
    card("Spectral Procession", 1, "main", "Sorcery", "{2/W}{2/W}{2/W}", 6, "W", "--LLL-L-", 3.0),
    card("Emrakul, the Aeons Torn", 1, "main", "Legendary Creature — Eldrazi", "{15}", 15, "", "--LLL-B-", None),
    card("Jace, the Mind Sculptor", 1, "main", "Legendary Planeswalker — Jace", "{2}{U}{U}", 4, "U", "--LLL-L-", 15.0),
    card("Ornithopter", 1, "main", "Artifact Creature — Thopter", "{0}", 0, "", "-LLLLLLL", 0.1),
    card("Steam Vents", 4, "main", "Land — Island Mountain", "", 0, "", "LLLLL-L-", 14.0),
    card("Island", 4, "main", "Basic Land — Island", "", 0, "", "LLLLLLLL", 0.05),
    card("Mountain", 2, "main", "Basic Land — Mountain", "", 0, "", "LLLLLLLL", 0.05),
    card("Polluted Delta", 4, "main", "Land", "", 0, "", "--LLL-LL", 25.0),
    card("Dryad Arbor", 1, "main", "Land Creature — Forest Dryad", "", 0, "G", "--LLL-L-", 2.0),
    card("Wastes", 1, "main", "Basic Land", "", 0, "", "--LLLLL-", 0.1),
    card("Breeding Pool", 1, "main", "Land — Forest Island", "", 0, "", "-LLLL-L-", 10.0),
    card("Lightning Bolt", 1, "side", "Instant", "{R}", 1, "R", "--LLLLLL", 1.5),
    card("Ancient Grudge", 2, "side", "Instant", "{1}{R}", 2, "R", "--LLLLLL", 0.2),
    card("Black Lotus", 1, "side", "Artifact", "{0}", 0, "", "---BR-B-", None),
    card("Counterspell", 2, "maybe", "Instant", "{U}{U}", 2, "U", "---LLLLL", 1.0),
]

COMMANDER = [
    card("Atraxa, Praetors' Voice", 1, "commander", "Legendary Creature — Phyrexian Angel Horror", "{G}{W}{U}{B}", 4, "WUBG",
         "--LLL-L-", 6.0),
    card("Sol Ring", 2, "main", "Artifact", "{1}", 1, "", "---BRLL-", 2.0),
    card("Forest", 30, "main", "Basic Land — Forest", "", 0, "", "LLLLLLLL", 0.05),
    card("Relentless Rats", 10, "main", "Creature — Rat", "{1}{B}{B}", 3, "B", "-LLLLLL-", 0.3),
]

CUBE_SPECS = [
    # name, type, cost, cmc, colors
    ("Swords to Plowshares", "Instant", "{W}", 1, "W"),
    ("Thalia, Guardian of Thraben", "Legendary Creature — Human Soldier", "{1}{W}", 2, "W"),
    ("Wrath of God", "Sorcery", "{2}{W}{W}", 4, "W"),
    ("Brightling", "Creature — Shapeshifter", "{1}{W}{W}", 3, "W"),
    ("Counterspell", "Instant", "{U}{U}", 2, "U"),
    ("Ancestral Vision", "Sorcery", "", 0, "U"),
    ("Delver of Secrets // Insectile Aberration", "Creature — Human Wizard // Creature — Human Insect", "{U}", 1, "U"),
    ("Control Magic", "Enchantment — Aura", "{2}{U}{U}", 4, "U"),
    ("Dark Ritual", "Instant", "{B}", 1, "B"),
    ("Bloodghast", "Creature — Vampire Spirit", "{1}{B}", 2, "B"),
    ("Grave Titan", "Creature — Giant", "{4}{B}{B}", 6, "B"),
    ("Lightning Bolt", "Instant", "{R}", 1, "R"),
    ("Goblin Guide", "Creature — Goblin Scout", "{R}", 1, "R"),
    ("Fireblast", "Instant", "{4}{R}{R}", 6, "R"),
    ("Inferno Titan", "Creature — Giant", "{4}{R}{R}", 6, "R"),
    ("Llanowar Elves", "Creature — Elf Druid", "{G}", 1, "G"),
    ("Tarmogoyf", "Creature — Lhurgoyf", "{1}{G}", 2, "G"),
    ("Craterhoof Behemoth", "Creature — Beast", "{5}{G}{G}{G}", 8, "G"),
    ("Fire // Ice", "Instant // Instant", "{1}{R} // {1}{U}", 4, "UR"),
    ("Kitchen Finks", "Creature — Ouphe", "{1}{G/W}{G/W}", 3, "GW"),
    ("Baleful Strix", "Artifact Creature — Bird", "{U}{B}", 2, "UB"),
    ("Sol Ring", "Artifact", "{1}", 1, ""),
    ("Wurmcoil Engine", "Artifact Creature — Phyrexian Wurm", "{6}", 6, ""),
    ("Karn, Scion of Urza", "Legendary Planeswalker — Karn", "{4}", 4, ""),
    ("Kozilek, Butcher of Truth", "Legendary Creature — Eldrazi", "{10}", 10, ""),
    ("Volcanic Island", "Land — Island Mountain", "", 0, ""),
    ("Scalding Tarn", "Land", "", 0, ""),
    ("Strip Mine", "Land", "", 0, ""),
    ("Dryad Arbor", "Land Creature — Forest Dryad", "", 0, "G"),
    ("Invasion of Zendikar // Awakened Skyclash", "Battle — Siege // Creature — Elemental", "{3}{G}", 4, "G"),
]
CUBE = [card(n, 1, "main", t, cost, cmc, col, "") for n, t, cost, cmc, col in CUBE_SPECS]
CUBE.append(card("Lightning Bolt", 1, "maybe", "Instant", "{R}", 1, "R", ""))  # Considering: never counted


def deck_expected(cards, fmt):
    return {
        "curve": curve(cards),
        "types": type_counts(deck_cards(cards)),
        "averageWithLands": average_mv(cards, True),
        "averageWithoutLands": average_mv(cards, False),
        "pips": pip_totals(cards),
        "sources": sources(cards),
        "price": price(cards),
        "legality": legality(cards, fmt),
        "librarySize": sum(c["qty"] for c in cards if c["board"] == "main"),
    }


def main():
    rng = Rng(42)
    prng = {"seed": 42, "first": [rng.next() for _ in range(8)]}
    rng = Rng(7)
    bounded = {"seed": 7, "bound": 60, "first": [rng.int(60) for _ in range(8)]}
    shuffles = [{"seed": s, "n": n, "order": shuffle(n, Rng(s))} for s, n in [(1, 10), (2026, 60), (0xFFFFFFFF, 7)]]

    pip_cases = [{"cost": c, "pips": pips(c)} for c in
                 ["{R}", "{1}{U}{U} // {1}{U}", "{2/W}{2/W}{2/W}", "{R/P}", "{G/U/P}", "{X}{X}{B}", "{1}{G/W}{G/W}", "{C}{S}{15}", ""]]

    hyper = []
    for N, K, n, k in [(60, 4, 7, 1), (60, 4, 8, 1), (60, 4, 7, 2), (60, 24, 7, 3), (60, 24, 10, 4), (40, 17, 9, 3),
                       (99, 1, 7, 1), (100, 36, 13, 6), (60, 0, 7, 1), (60, 4, 7, 5), (60, 60, 7, 7), (10, 4, 20, 4),
                       (60, 4, 7, 0), (250, 40, 15, 2)]:
        hyper.append({"N": N, "K": K, "n": n, "k": k, "p": hypergeometric(N, K, n, k)})
    turns = [{"turn": t, "onPlay": p, "draws": draws_by_turn(t, p)} for t, p in [(1, True), (1, False), (3, True), (4, False)]]

    # London mulligan: deal, mulligan to 6 (bottom one), then to 5 (bottom two), then draw two.
    h = SampleHand(40, 12345)
    script = [{"do": "deal", "expect": h.state()}]
    h.mulligan()
    script.append({"do": "mulligan", "expect": h.state()})
    h.bottom(3)
    script.append({"do": "bottom", "index": 3, "expect": h.state()})
    h.mulligan()
    script.append({"do": "mulligan", "expect": h.state()})
    h.bottom(0)
    script.append({"do": "bottom", "index": 0, "expect": h.state()})
    h.bottom(4)
    script.append({"do": "bottom", "index": 4, "expect": h.state()})
    h.draw()
    script.append({"do": "draw", "expect": h.state()})
    h.draw()
    script.append({"do": "draw", "expect": h.state()})

    cube_main = [c for c in CUBE if c["board"] == "main"]
    cube = {
        "cards": CUBE,
        "expected": {
            "size": sum(c["qty"] for c in cube_main),
            "colorBalance": color_balance(cube_main),
            "curveByColor": curve_by_color(cube_main),
            "types": type_counts(cube_main),
            "asfan": {by: asfan(cube_main, 15, by) for by in ("color", "type", "mv")},
            "pack": {"seed": 99, "size": 15, "cards": shuffle(len(cube_main), Rng(99))[:15]},
        },
    }

    out = {
        "_": "Generated by make_cases.py; do not edit by hand.",
        "prng": prng, "bounded": bounded, "shuffles": shuffles, "pips": pip_cases, "hypergeometric": hyper,
        "drawsByTurn": turns,
        "deck": {"format": "modern", "cards": DECK, "expected": deck_expected(DECK, "modern"),
                 "legalityIn": {f: legality(DECK, f) for f in ("legacy", "vintage", "pauper", "canlander", "cube")}},
        "commander": {"format": "commander", "cards": COMMANDER, "expected": deck_expected(COMMANDER, "commander")},
        "mulligan": {"size": 40, "seed": 12345, "script": script},
        "cube": cube,
    }
    path = Path(__file__).with_name("cases.json")
    path.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
