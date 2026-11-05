#!/usr/bin/env python3
"""Reference for sideboard guides (contract/sideboard-guide-2026-11-04.md).

A deck's guide is a list of matchups, each naming the cards that come in (from the sideboard or Considering) and the
cards that go out (from the main deck), with notes. This file is the one rule for checking a matchup against the deck,
for what the printed guide shows (only cards in the sideboard come in: MTR 2.11 / CR 100.4a) and for the printed page
itself. Writes cases.json and guide.html, which iOS SideboardGuideTests, web sideboardGuide.test.ts and Android
SideboardGuideTest read; each client's printed page must equal guide.html byte for byte.

    python3 -I testdata/sideboard-guide/make_cases.py      # rewrites cases.json and guide.html
"""
import json
import math
from pathlib import Path

HERE = Path(__file__).parent

MAX_MATCHUPS = 40
MAX_CARDS = 40
MAX_NAME = 40
MAX_NOTES = 1000
SIDEBOARD_MAX = 15
NO_GUIDE = {"commander", "oathbreaker"}
# Formats whose sideboard is capped at 15 (CR 100.4a); "other" may be Limited, where every unplayed card is the
# sideboard, so it is never checked.
CAPPED = {"modern", "pioneer", "standard", "legacy", "vintage", "pauper", "canlander"}


def has_guide(fmt):
    return fmt not in NO_GUIDE


def deck_min(fmt):
    if fmt == "canlander":
        return 100
    if fmt in CAPPED:
        return 60
    return None


def pool(lines):
    """Per card (oracle): name and copies in main, side and maybe. The command zone isn't the deck here."""
    out = {}
    for l in lines:
        p = out.setdefault(l["oracle"], {"name": l["name"], "main": 0, "side": 0, "maybe": 0})
        if l["board"] in ("main", "side", "maybe"):
            p[l["board"]] += l["qty"]
    return out


def check(matchup, lines, fmt):
    """In and out counts, the deck size after sideboarding and what's wrong, in the matchup's own order."""
    p = pool(lines)
    main_total = sum(l["qty"] for l in lines if l["board"] == "main")
    issues = []
    took_in = 0
    for oracle, asked in matchup["in"]:
        c = p.get(oracle, {"main": 0, "side": 0, "maybe": 0})
        avail = c["side"] + c["maybe"]
        if avail == 0:
            issues.append({"code": "gone", "side": "in", "oracle": oracle})
            continue
        if asked > avail:
            issues.append({"code": "in_over", "oracle": oracle, "have": avail})
        took = min(asked, avail)
        took_in += took
        cons = took - c["side"]
        if cons > 0:
            issues.append({"code": "considering", "oracle": oracle, "qty": cons})
    took_out = 0
    for oracle, asked in matchup["out"]:
        have = p.get(oracle, {"main": 0})["main"]
        if have == 0:
            issues.append({"code": "gone", "side": "out", "oracle": oracle})
            continue
        if asked > have:
            issues.append({"code": "out_over", "oracle": oracle, "have": have})
        took_out += min(asked, have)
    after = main_total + took_in - took_out
    m = deck_min(fmt)
    if m is not None and after < m:
        issues.append({"code": "below_min", "deck": after, "min": m})
    n_in = sum(q for _, q in matchup["in"])
    n_out = sum(q for _, q in matchup["out"])
    return {"in": n_in, "out": n_out, "deck": after, "label": label(n_in, n_out), "issues": issues}


def label(n_in, n_out):
    """A matchup row's data line: IN 3 · OUT 3, or NO CHANGES."""
    if n_in == 0 and n_out == 0:
        return "NO CHANGES"
    return f"IN {n_in} · OUT {n_out}"


def sideboard_count(lines):
    return sum(l["qty"] for l in lines if l["board"] == "side")


def over_sideboard(lines, fmt):
    """The sideboard's size when it's over 15 in a capped format, else None."""
    n = sideboard_count(lines)
    return n if fmt in CAPPED and n > SIDEBOARD_MAX else None


def uses(guide):
    """How many matchups bring each card in, for the sideboard screen."""
    out = {}
    for m in guide["matchups"]:
        for oracle, q in m["in"]:
            if q > 0:
                out[oracle] = out.get(oracle, 0) + 1
    return out


def normalize(guide):
    """What the server keeps: trimmed names and notes, one entry per card per side (merged, first place kept),
    quantities 1-99, empty matchup names refused (None), limits applied by refusing."""
    ms = guide.get("matchups") or []
    if len(ms) > MAX_MATCHUPS:
        return None
    out = []
    for m in ms:
        name = (m.get("name") or "").strip()
        if not name or len(name) > MAX_NAME:
            return None
        sides = {}
        for side in ("in", "out"):
            merged = {}
            order = []
            for oracle, q in m.get(side) or []:
                if not isinstance(q, int) or q < 1 or q > 99:
                    return None
                if oracle not in merged:
                    order.append(oracle)
                    merged[oracle] = 0
                merged[oracle] = min(99, merged[oracle] + q)
            if len(order) > MAX_CARDS:
                return None
            sides[side] = [[o, merged[o]] for o in order]
        notes = (m.get("notes") or "").strip()
        if len(notes) > MAX_NOTES:
            return None
        out.append({"id": m["id"], "name": name, "archetype": m.get("archetype"), "in": sides["in"],
                    "out": sides["out"], "notes": notes})
    return {"matchups": out} if out else None


def print_model(deck, fmt_name, date, lines, guide, fmt):
    """What the printed guide shows. Only sideboard copies come in (Considering copies are left out and counted);
    outs are capped at the main deck's copies; cards no longer in the deck are left out."""
    p = pool(lines)
    left_considering = 0
    left_gone = 0
    matchups = []
    for m in guide["matchups"]:
        ins = []
        for oracle, asked in m["in"]:
            c = p.get(oracle)
            side = c["side"] if c else 0
            if not c or c["side"] + c["maybe"] == 0:
                left_gone += asked
                continue
            took = min(asked, side)
            left_considering += min(asked, c["side"] + c["maybe"]) - took
            if took > 0:
                ins.append([took, c["name"]])
        outs = []
        for oracle, asked in m["out"]:
            c = p.get(oracle)
            have = c["main"] if c else 0
            if have == 0:
                left_gone += asked
                continue
            outs.append([min(asked, have), c["name"]])
        matchups.append({"name": m["name"], "in": ins, "out": outs, "notes": m["notes"]})
    side = sorted(([c["side"], c["name"]] for c in p.values() if c["side"] > 0), key=lambda x: x[1].lower())
    model = {"deck": deck, "format": fmt_name, "date": date, "sideboard": side, "matchups": matchups}
    warnings = []
    if left_considering:
        warnings.append({"code": "considering", "qty": left_considering})
    if left_gone:
        warnings.append({"code": "gone", "qty": left_gone})
    over = over_sideboard(lines, fmt)
    if over is not None:
        warnings.append({"code": "sideboard_over", "qty": over, "max": SIDEBOARD_MAX})
    s = sheets(model)
    if s > 2:
        warnings.append({"code": "sheets", "qty": s})
    return {"model": model, "warnings": warnings, "sheets": s}


# Roughly how many printed lines fit: two columns of about 60 lines of 9 pt type, minus the header.
LINES_PER_PAGE = 120
HEADER_LINES = 10
NOTE_CHARS_PER_LINE = 40


def sheets(model):
    """About how many pages the printed guide takes (MTR 2.11 allows a sheet or two)."""
    total = HEADER_LINES
    for m in model["matchups"]:
        notes = 0
        if m["notes"]:
            notes = 1 + sum(max(1, math.ceil(len(part) / NOTE_CHARS_PER_LINE)) for part in m["notes"].split("\n"))
        total += 4 + max(len(m["in"]), len(m["out"]), 1) + notes
    total += 4 + max(len(model["sideboard"]), 1)
    return max(1, math.ceil(total / LINES_PER_PAGE))


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;").replace("'", "&#39;"))


CSS = (
    "@page{margin:12mm}"
    "*{box-sizing:border-box;margin:0;padding:0}"
    "html{-webkit-print-color-adjust:exact;print-color-adjust:exact}"
    "body{font-family:ui-monospace,\"SF Mono\",\"JetBrains Mono\",Menlo,Consolas,monospace;color:#171725;"
    "background:#fff;font-size:9pt;line-height:1.35}"
    "header{border-bottom:2px solid #00ffd9;padding-bottom:6pt;margin-bottom:8pt}"
    ".mark,.meta,.rule,.lab,h2{text-transform:uppercase;letter-spacing:.15em}"
    ".mark{font-size:7pt;color:#545461}"
    "h1{font-size:16pt;font-weight:600;margin:2pt 0}"
    ".meta{font-size:7.5pt;color:#545461}"
    ".rule{font-size:6.5pt;color:#545461;margin-top:2pt}"
    "main{columns:2;column-gap:8pt}"
    "section{break-inside:avoid;border:1px solid #c4c4ca;margin-bottom:8pt;padding:6pt}"
    "h2{font-size:8pt;font-weight:600;padding-bottom:4pt;border-bottom:1px solid #c4c4ca;margin-bottom:4pt}"
    ".io{display:flex;gap:6pt}"
    ".col{flex:1;min-width:0}"
    ".lab{font-size:6.5pt;color:#545461;margin-bottom:2pt}"
    ".row{display:flex;gap:4pt}"
    ".q{width:2.4em;flex:none;font-weight:600}"
    ".none{color:#545461}"
    ".notes{margin-top:4pt;padding-top:4pt;border-top:1px solid #c4c4ca;font-size:8pt;white-space:pre-wrap}"
)

RULE = "MTR 2.11 · Between games only · Remove from the play area before each game"


def rows(cards, sign):
    if not cards:
        return '<div class="none">—</div>'
    return "".join(f'<div class="row"><span class="q">{sign}{q}</span><span>{esc(n)}</span></div>' for q, n in cards)


def html(model):
    """The printed page. Light paper in Table 1's type, labels and hairline grid; the accent is the line under the
    header only (teal text doesn't read on paper)."""
    out = ['<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n',
           f"<title>{esc(model['deck'])} · Sideboard guide</title>\n",
           f"<style>{CSS}</style>\n</head>\n<body>\n<header>\n",
           '<div class="mark">Table 1</div>\n',
           f"<h1>{esc(model['deck'])}</h1>\n",
           f'<div class="meta">{esc(model["format"])} · Sideboard guide · {esc(model["date"])}</div>\n',
           f'<div class="rule">{RULE}</div>\n</header>\n<main>\n']
    for m in model["matchups"]:
        n_in = sum(q for q, _ in m["in"])
        n_out = sum(q for q, _ in m["out"])
        out.append(f"<section>\n<h2>{esc(m['name'])}</h2>\n<div class=\"io\">\n")
        out.append(f'<div class="col"><div class="lab">In · {n_in}</div>{rows(m["in"], "+")}</div>\n')
        out.append(f'<div class="col"><div class="lab">Out · {n_out}</div>{rows(m["out"], "−")}</div>\n</div>\n')
        if m["notes"]:
            out.append(f'<p class="notes">{esc(m["notes"])}</p>\n')
        out.append("</section>\n")
    n_side = sum(q for q, _ in model["sideboard"])
    out.append(f"<section>\n<h2>Sideboard · {n_side}</h2>\n{rows(model['sideboard'], '')}\n</section>\n")
    out.append("</main>\n</body>\n</html>\n")
    return "".join(out)


# --- fixture -------------------------------------------------------------------------------------------------

BOLT, RAGAVAN, BLOOD, FURY, SPELL, PIERCE, RELIC, ENGINEER, DRESS, ISLAND = (
    "o-bolt", "o-ragavan", "o-blood", "o-fury", "o-spell", "o-pierce", "o-relic", "o-engineer", "o-dress", "o-island")

LINES = [
    {"oracle": BOLT, "name": "Lightning Bolt", "board": "main", "qty": 4},
    {"oracle": RAGAVAN, "name": "Ragavan, Nimble Pilferer", "board": "main", "qty": 4},
    {"oracle": ENGINEER, "name": "Dragon's Rage Channeler", "board": "main", "qty": 4},
    {"oracle": SPELL, "name": "Spell Pierce", "board": "main", "qty": 2},
    {"oracle": ISLAND, "name": "Island", "board": "main", "qty": 46},
    {"oracle": BLOOD, "name": "Blood Moon", "board": "side", "qty": 2},
    {"oracle": FURY, "name": "Fury", "board": "side", "qty": 2},
    {"oracle": PIERCE, "name": "Mystical Dispute", "board": "side", "qty": 3},
    {"oracle": RELIC, "name": "Relic of Progenitus", "board": "side", "qty": 1},
    {"oracle": RELIC, "name": "Relic of Progenitus", "board": "maybe", "qty": 2},
    {"oracle": DRESS, "name": "Dress Down", "board": "maybe", "qty": 1},
]

GUIDE = {"matchups": [
    {"id": "m1", "name": "Boros Energy", "archetype": 12,
     "in": [[FURY, 2], [BLOOD, 1]], "out": [[SPELL, 2], [ENGINEER, 1]],
     "notes": "Keep hands with two removal spells.\nOn the draw: Fury over Blood Moon."},
    {"id": "m2", "name": "Esper Goryo's & <friends>", "archetype": None,
     "in": [[RELIC, 3], [DRESS, 1], [PIERCE, 3]], "out": [[RAGAVAN, 2], [BOLT, 4], [ENGINEER, 2]],
     "notes": ""},
    {"id": "m3", "name": "Mirror", "archetype": None, "in": [], "out": [], "notes": ""},
]}


def main():
    cases = {
        "lines": LINES,
        "guide": GUIDE,
        "has_guide": {f: has_guide(f) for f in ["modern", "commander", "oathbreaker", "other", "canlander"]},
        "deck_min": {f: deck_min(f) for f in ["modern", "canlander", "other", "commander"]},
        "check": [
            {"format": "modern", "matchup": m["id"], "expect": check(m, LINES, "modern")} for m in GUIDE["matchups"]
        ] + [
            # Taking out more than goes in drops below 60 in Modern; "other" has no minimum.
            {"format": "modern", "matchup": "short", "in": [], "out": [[BOLT, 4], [RAGAVAN, 1]],
             "expect": check({"in": [], "out": [[BOLT, 4], [RAGAVAN, 1]]}, LINES, "modern")},
            {"format": "other", "matchup": "short", "in": [], "out": [[BOLT, 4], [RAGAVAN, 1]],
             "expect": check({"in": [], "out": [[BOLT, 4], [RAGAVAN, 1]]}, LINES, "other")},
            # A card that left the deck, on both sides.
            {"format": "modern", "matchup": "gone", "in": [["o-missing", 1]], "out": [["o-missing", 1]],
             "expect": check({"in": [["o-missing", 1]], "out": [["o-missing", 1]]}, LINES, "modern")},
        ],
        "sideboard_count": sideboard_count(LINES),
        "over_sideboard": [
            {"format": "modern", "lines": LINES, "expect": over_sideboard(LINES, "modern")},
            {"format": "modern", "lines": LINES + [{"oracle": "o-x", "name": "X", "board": "side", "qty": 8}],
             "expect": over_sideboard(LINES + [{"oracle": "o-x", "name": "X", "board": "side", "qty": 8}], "modern")},
            {"format": "other", "lines": LINES + [{"oracle": "o-x", "name": "X", "board": "side", "qty": 8}],
             "expect": over_sideboard(LINES + [{"oracle": "o-x", "name": "X", "board": "side", "qty": 8}], "other")},
        ],
        "uses": uses(GUIDE),
        "normalize": [
            {"in": {"matchups": [{"id": "a", "name": "  Burn  ", "in": [[BOLT, 1], [BOLT, 2]], "out": [],
                                  "notes": "  go wide \n"}]},
             "expect": normalize({"matchups": [{"id": "a", "name": "  Burn  ", "in": [[BOLT, 1], [BOLT, 2]],
                                                "out": [], "notes": "  go wide \n"}]})},
            {"in": {"matchups": [{"id": "a", "name": "   ", "in": [], "out": []}]}, "expect": None},
            {"in": {"matchups": [{"id": "a", "name": "Burn", "in": [[BOLT, 0]], "out": []}]}, "expect": None},
            {"in": {"matchups": []}, "expect": None},
        ],
        "print": print_model("Izzet Murktide", "Modern", "2026-11-04", LINES, GUIDE, "modern"),
        "sheets": [
            {"matchups": n, "expect": sheets({"sideboard": [[1, "x"]] * 15, "matchups": [
                {"name": "m", "in": [[1, "a"]] * 5, "out": [[1, "b"]] * 5, "notes": "x" * 120}] * n})}
            for n in (1, 8, 12, 20)
        ],
    }
    (HERE / "cases.json").write_text(json.dumps(cases, indent=1, ensure_ascii=False) + "\n")
    (HERE / "guide.html").write_text(html(cases["print"]["model"]))


if __name__ == "__main__":
    main()
