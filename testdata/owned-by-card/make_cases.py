#!/usr/bin/env python3
"""Reference for owning a card in any printing (contract/owned-by-card-2026-10-31.md).

A deck or cube line is covered by copies of the same card in any printing, finish or language: the printing and finish
the line names first, then any other copy of that card. Also the card detail rules for matching a deck's printings to
the copies you own. Writes cases.json, which iOS OwnedByCardTests, web ownedByCard.test.ts and Android OwnedByCardTest
read, and checks the language rules of testdata/list-to-collection/cases.json still hold with oracles added.

    python3 -I testdata/owned-by-card/make_cases.py      # rewrites testdata/owned-by-card/cases.json
"""
import json
from pathlib import Path

HERE = Path(__file__).parent


def oracle(card, oracles):
    return oracles.get(card, card)


def counted(line, basics):
    return line["board"] != "maybe" and line["card_id"] not in basics


def by_card(owned, oracles):
    """owned is keyed 'card_id|finish' (or 'card_id|finish|lang'); copies per card (oracle)."""
    out = {}
    for k, n in owned.items():
        o = oracle(k.split("|")[0], oracles)
        out[o] = out.get(o, 0) + n
    return out


def by_printing(owned):
    out = {}
    for k, n in owned.items():
        card, finish = k.split("|")[:2]
        out[f"{card}|{finish}"] = out.get(f"{card}|{finish}", 0) + n
    return out


def shorts(lines, owned, oracles, basics):
    """Copies each line still needs, in list order. Considering and basics never need any and never use copies."""
    exact = by_printing(owned)
    spare = by_card(owned, oracles)
    covered = [0] * len(lines)
    for i, l in enumerate(lines):
        if not counted(l, basics):
            continue
        k = f"{l['card_id']}|{l['finish']}"
        c = min(l["qty"], exact.get(k, 0))
        exact[k] = exact.get(k, 0) - c
        o = oracle(l["card_id"], oracles)
        spare[o] = spare.get(o, 0) - c
        covered[i] = c
    for i, l in enumerate(lines):
        if not counted(l, basics):
            continue
        o = oracle(l["card_id"], oracles)
        c = min(l["qty"] - covered[i], spare.get(o, 0))
        spare[o] = spare.get(o, 0) - c
        covered[i] += c
    return [l["qty"] - covered[i] if counted(l, basics) else 0 for i, l in enumerate(lines)]


def missing_lines(lists, owned, oracles, basics):
    """Wants -> Missing: one line per card, the largest shortfall across lists (lists don't reserve copies), shown as
    the first short line of the list that needs most (earliest list on a tie)."""
    have = by_card(owned, oracles)
    need = {}
    for l in lists:
        if l.get("event"):
            continue
        per = {}
        first = {}
        for e, s in zip(l["entries"], shorts(l["entries"], owned, oracles, basics)):
            if not counted(e, basics):
                continue
            o = oracle(e["card_id"], oracles)
            per[o] = per.get(o, 0) + e["qty"]
            if s > 0 and o not in first:
                first[o] = e
        for o, n in per.items():
            short = n - have.get(o, 0)
            if short <= 0:
                continue
            v = need.setdefault(o, {"short": 0, "lists": [], "line": None})
            if short > v["short"]:
                v["short"], v["line"] = short, first[o]
            v["lists"].append(l["name"])
    out = [{"card_id": v["line"]["card_id"], "finish": v["line"]["finish"], "short": v["short"], "lists": sorted(v["lists"])}
           for v in need.values()]
    return sorted(out, key=lambda m: (-m["short"], f"{m['card_id']}|{m['finish']}"))


def lang_order(lang):
    return (lang != "en", lang)


def add_ops(entries, kind, owned, mode, sideboard=True, only=None, basics=(), oracles=None):
    """Add to collection (contract/list-to-collection-2026-10-22.md), Missing now counting any copy of the card."""
    oracles = oracles or {}
    need = {}  # (card, finish) -> {lang: n}
    for e in entries:
        b = e["board"]
        if not (b in ("main", "commander") or (b == "side" and kind == "deck" and sideboard)):
            continue
        if only is not None and e["card_id"] not in only:
            continue
        if mode == "missing" and e["card_id"] in basics:
            continue
        m = need.setdefault((e["card_id"], e["finish"]), {})
        lang = e.get("lang", "en")
        m[lang] = m.get(lang, 0) + e["qty"]
    left = {k: dict(v) for k, v in need.items()}
    if mode == "missing":
        have = {}  # (card, finish) -> {lang: n}
        for k, n in owned.items():
            p = k.split("|")
            m = have.setdefault((p[0], p[1]), {})
            lang = p[2] if len(p) > 2 else "en"
            m[lang] = m.get(lang, 0) + n
        spare_card = {}
        for (card, finish), langs in sorted(left.items()):
            mine = have.get((card, finish), {})
            spare = sum(mine.values())
            for lang in list(langs):
                c = min(langs[lang], mine.get(lang, 0))
                langs[lang] -= c
                spare -= c
            for lang in sorted(langs, key=lang_order):
                if spare <= 0:
                    break
                c = min(langs[lang], spare)
                langs[lang] -= c
                spare -= c
        # Copies of the card in printings and finishes no line names, then a line's spare copies, cover the rest.
        used = {}
        for (card, finish), langs in need.items():
            mine = have.get((card, finish), {})
            used[(card, finish)] = min(sum(mine.values()), sum(langs.values()))
        for (card, finish), langs in have.items():
            o = oracle(card, oracles)
            spare_card[o] = spare_card.get(o, 0) + sum(langs.values()) - used.get((card, finish), 0)
        for (card, finish) in sorted(left):
            o = oracle(card, oracles)
            langs = left[(card, finish)]
            for lang in sorted(langs, key=lang_order):
                if spare_card.get(o, 0) <= 0:
                    break
                c = min(langs[lang], spare_card[o])
                langs[lang] -= c
                spare_card[o] -= c
    out = []
    for (card, finish), langs in left.items():
        for lang, n in langs.items():
            if n > 0:
                op = {"card_id": card, "finish": finish, "delta": n}
                if lang != "en":
                    op["lang"] = lang
                out.append(op)
    return sorted(out, key=lambda o: (o["card_id"], o["finish"], o.get("lang", "en")))


def auto_match(lines, versions):
    """Card detail, Match collection: which owned versions (printing x finish) the copies of one section take.
    Versions the section already lists first, then the ones you hold most of, then by card_id and finish."""
    total = sum(l["qty"] for l in lines)
    listed = {f"{l['card_id']}|{l['finish']}" for l in lines}
    order = sorted(versions, key=lambda v: (f"{v['card_id']}|{v['finish']}" not in listed, -v["owned"], v["card_id"], v["finish"]))
    picks, left = [], total
    for v in order:
        n = min(v["owned"], left)
        if n > 0:
            picks.append({"card_id": v["card_id"], "finish": v["finish"], "qty": n})
            left -= n
    return picks


def tap(picks, versions, total, card_id, finish):
    """A tap on a version's tile: one more of it, while you own more and copies are left; else back to none."""
    have = next(v["owned"] for v in versions if v["card_id"] == card_id and v["finish"] == finish)
    out = [dict(p) for p in picks]
    p = next((p for p in out if p["card_id"] == card_id and p["finish"] == finish), None)
    used = sum(x["qty"] for x in out)
    if p is None:
        if used < total and have > 0:
            out.append({"card_id": card_id, "finish": finish, "qty": 1})
        return out
    if p["qty"] < have and used < total:
        p["qty"] += 1
        return out
    return [x for x in out if x is not p]


def match_ops(lines, picks):
    """list_edit move ops that give the section the picked printings; copies not picked stay as they are. Lines that
    already are a picked version keep those copies; the rest move in list order to the picks in pick order."""
    want = {f"{p['card_id']}|{p['finish']}": p["qty"] for p in picks}
    keep = []
    for l in lines:
        k = f"{l['card_id']}|{l['finish']}"
        c = min(l["qty"], want.get(k, 0))
        want[k] = want.get(k, 0) - c
        keep.append(c)
    targets = [[p, want[f"{p['card_id']}|{p['finish']}"]] for p in picks]
    ops = []
    for l, c in zip(lines, keep):
        movable = l["qty"] - c
        for t in targets:
            if movable <= 0:
                break
            n = min(movable, t[1])
            if n <= 0:
                continue
            op = {"card_id": l["card_id"], "finish": l["finish"], "to_card_id": t[0]["card_id"], "to_finish": t[0]["finish"], "qty": n}
            if l.get("lang", "en") != "en":
                op["lang"] = l["lang"]
            ops.append(op)
            t[1] -= n
            movable -= n
    return ops


def line(card, qty, board="main", finish="nonfoil", lang=None):
    e = {"card_id": card, "board": board, "finish": finish, "qty": qty}
    if lang:
        e["lang"] = lang
    return e


ORACLES = {"bolt-lea": "bolt", "bolt-m10": "bolt", "bolt-sta": "bolt", "guide-zen": "guide", "guide-a25": "guide",
           "island-a": "island", "island-b": "island"}
BASICS = ["island-a", "island-b"]


def short_case(name, lines, owned, oracles=ORACLES):
    return {"name": name, "lines": lines, "owned": owned, "oracles": oracles, "shorts": shorts(lines, owned, oracles, set(BASICS))}


SHORTS = [
    short_case("the printing listed covers it", [line("bolt-m10", 4)], {"bolt-m10|nonfoil": 4}),
    short_case("another printing covers it", [line("bolt-m10", 4)], {"bolt-lea|nonfoil": 4}),
    short_case("any finish covers it", [line("bolt-m10", 2, finish="foil")], {"bolt-m10|nonfoil": 1, "bolt-sta|etched": 1}),
    short_case("any language covers it", [line("bolt-m10", 2)], {"bolt-m10|nonfoil|ja": 2}),
    short_case("the listed printing first, then the rest in list order",
               [line("bolt-lea", 2), line("bolt-m10", 2), line("bolt-m10", 1, board="side")],
               {"bolt-m10|nonfoil": 3, "bolt-sta|foil": 1}),
    short_case("copies cover each card once across sections",
               [line("bolt-m10", 3), line("bolt-lea", 2, board="side")], {"bolt-lea|nonfoil": 1, "bolt-m10|nonfoil": 2}),
    short_case("different cards never cover each other", [line("bolt-m10", 1), line("guide-zen", 2)], {"bolt-lea|nonfoil": 3}),
    short_case("considering and basics never need copies or use them",
               [line("guide-a25", 1, board="maybe"), line("guide-zen", 1), line("island-a", 9)],
               {"guide-zen|nonfoil": 1}),
    short_case("without the catalog a printing is its own card", [line("bolt-m10", 2)], {"bolt-lea|nonfoil": 2}, oracles={}),
]

LISTS = [
    {"name": "Burn", "entries": [line("bolt-m10", 4), line("guide-zen", 4), line("island-a", 2)]},
    {"name": "Cube", "entries": [line("bolt-lea", 1), line("guide-a25", 1)]},
    {"name": "Red", "entries": [line("bolt-sta", 2, finish="foil"), line("bolt-m10", 3, board="side")]},
    {"name": "Roto", "event": True, "entries": [line("guide-zen", 9)]},
]
LINES_OWNED = {"bolt-lea|nonfoil": 2, "guide-a25|foil": 1}

ADD_CASES = [
    {"name": "missing: another printing of the card covers a line", "kind": "deck", "mode": "missing",
     "entries": [line("bolt-m10", 4)], "owned": {"bolt-lea|nonfoil": 3}},
    {"name": "missing: the listed printing first, then the card's other copies by card_id",
     "kind": "deck", "mode": "missing", "entries": [line("bolt-m10", 2), line("bolt-lea", 2), line("guide-zen", 1)],
     "owned": {"bolt-m10|nonfoil": 3, "guide-a25|nonfoil|ja": 1}},
    {"name": "missing: a line's spare copies cover another printing's line", "kind": "cube", "mode": "missing",
     "entries": [line("bolt-lea", 1), line("bolt-m10", 1, lang="ja")], "owned": {"bolt-lea|nonfoil": 2}},
    {"name": "every card still adds every copy", "kind": "deck", "mode": "all",
     "entries": [line("bolt-m10", 2)], "owned": {"bolt-lea|nonfoil": 2}},
]
for c in ADD_CASES:
    c["oracles"] = ORACLES
    c["ops"] = add_ops(c["entries"], c["kind"], c["owned"], c["mode"], oracles=ORACLES)
    c["copies"] = sum(o["delta"] for o in c["ops"])

VERSIONS = [{"card_id": "bolt-lea", "finish": "nonfoil", "owned": 1}, {"card_id": "bolt-m10", "finish": "foil", "owned": 3},
            {"card_id": "bolt-sta", "finish": "etched", "owned": 3}]


def match_case(name, lines, versions, taps=()):
    total = sum(l["qty"] for l in lines)
    picks = auto_match(lines, versions)
    after = picks
    for t in taps:
        after = tap(after, versions, total, *t)
    return {"name": name, "lines": lines, "versions": versions, "auto": picks,
            "taps": [list(t) for t in taps], "picks": after, "ops": match_ops(lines, after)}


MATCHES = [
    match_case("auto: listed versions first, then the most held, then by card_id",
               [line("bolt-lea", 4)], VERSIONS),
    match_case("auto: you own fewer than listed, the rest stay", [line("bolt-m10", 3), line("bolt-lea", 2, lang="de")],
               [{"card_id": "bolt-sta", "finish": "etched", "owned": 2}]),
    match_case("taps: nothing while full; at the most you own back to none; one more each tap", [line("bolt-m10", 4)], VERSIONS,
               taps=[("bolt-lea", "nonfoil"), ("bolt-m10", "foil"), ("bolt-lea", "nonfoil"), ("bolt-lea", "nonfoil"), ("bolt-sta", "etched")]),
    match_case("taps: with every copy picked, a picked tile goes back to none and another tile does nothing",
               [line("bolt-m10", 2)], VERSIONS, taps=[("bolt-sta", "etched"), ("bolt-m10", "foil")]),
    match_case("nothing to move when the section already matches", [line("bolt-m10", 3, finish="foil")], VERSIONS),
]


def check_list_to_collection():
    d = json.loads((HERE.parent / "list-to-collection" / "cases.json").read_text())
    for c in d["cases"]:
        got = add_ops(c["entries"], c["kind"], c["owned"], c["mode"], c.get("sideboard", True),
                      set(c["only"]) if "only" in c else None, set(c.get("basics", [])), c.get("oracles"))
        assert got == c["ops"], (c["name"], got, c["ops"])


def main():
    cases = {
        "about": "Owning a card in any printing (contract/owned-by-card-2026-10-31.md). owned is keyed 'card_id|finish' "
                 "or 'card_id|finish|lang'; oracles maps a printing to its card (a printing missing from it is its own "
                 "card). 'shorts': copies each line still needs, in list order (Considering and basics: 0). 'lines': "
                 "Wants -> Missing, one per card. 'add': Add to collection's Missing mode. 'match': card detail's Match "
                 "collection: 'auto' picks, then each tap in 'taps' ([card_id, finish]) gives 'picks', and 'ops' are the "
                 "list_edit move ops for 'picks'. Generated by make_cases.py.",
        "basics": BASICS,
        "shorts": SHORTS,
        "lines": {"lists": LISTS, "owned": LINES_OWNED, "oracles": ORACLES,
                  "expect": missing_lines(LISTS, LINES_OWNED, ORACLES, set(BASICS))},
        "add": ADD_CASES,
        "match": MATCHES,
    }
    check_list_to_collection()
    (HERE / "cases.json").write_text(json.dumps(cases, indent=1) + "\n")


if __name__ == "__main__":
    main()
