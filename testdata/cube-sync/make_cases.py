#!/usr/bin/env python3
"""Shared rules for syncing a cube with Cube Cobra (contract/cube-sync-2026-10-30.md), and the cases every client
checks against.

    python3 testdata/cube-sync/make_cases.py   # writes cases.json next to this file

sync(printings, current, incoming) compares the cube as it is (`current`, list entries [card, board, qty, finish?,
lang?]) with Cube Cobra's cube resolved to printings (`incoming`, [card, board, qty, finish?]) and returns what's
in, out and changed, and the entries to save. `printings` maps a card id to {oracle, lang}.

Per section (Main, Considering), copies are paired in three passes:
  1. same printing and finish: unchanged (the line keeps its language; English lines first, then by code);
  2. same printing, other finish: changed;
  3. same card (oracle), other printing: changed.
Copies of a section Cube Cobra has and the cube doesn't are In, the other way round Out (a card moved from Main to
Considering is Out of Main and In Considering). Within a pass, copies pair in (card id, finish, lang) order.

A changed copy's language: the new printing's own when it isn't English; else the old line's when the old line
named a language its printing doesn't have (an English printing kept as Japanese); else English. An In copy is
its printing's language.

summary(diff): "N in · N out · N new printing(s)", leaving out zeros; "Up to date" when nothing changes.
"""
import json
import os

LANG_ORDER = lambda lang: (lang != "en", lang)
# A line's condition (contract/lists-2026-10-15.md § Conditions): Cube Cobra records none, so a kept or changed copy
# keeps its line's condition and an In copy is NM. Best first among lines that differ only by condition.
COND_RANK = lambda cond: ["NM", "LP", "MP", "HP", "DMG"].index(cond)


def norm_current(entries):
    out = {}
    for e in entries:
        card, board, qty = e[0], e[1], e[2]
        finish = e[3] if len(e) > 3 and e[3] else "nonfoil"
        lang = e[4] if len(e) > 4 and e[4] else "en"
        cond = e[5] if len(e) > 5 and e[5] else "NM"
        k = (board, card, finish, lang, cond)
        out[k] = out.get(k, 0) + qty
    return out


def norm_incoming(entries):
    out = {}
    for e in entries:
        card, board, qty = e[0], e[1], e[2]
        finish = e[3] if len(e) > 3 and e[3] else "nonfoil"
        k = (board, card, finish)
        out[k] = out.get(k, 0) + qty
    return out


def plang(printings, card):
    return (printings.get(card) or {}).get("lang") or "en"


def oracle(printings, card):
    return (printings.get(card) or {}).get("oracle") or card


def changed_lang(printings, from_card, from_lang, to_card):
    to = plang(printings, to_card)
    if to != "en":
        return to
    if from_lang != plang(printings, from_card):
        return from_lang
    return "en"


def entry(board, card, qty, finish, lang, cond="NM"):
    if cond != "NM":
        return [card, board, qty, finish, lang, cond]
    if lang != "en":
        return [card, board, qty, finish, lang]
    if finish != "nonfoil":
        return [card, board, qty, finish]
    return [card, board, qty]


def sync(printings, current, incoming):
    cur = norm_current(current)
    inc = norm_incoming(incoming)
    final = {}
    changed = {}
    same = 0

    def add(d, k, n):
        d[k] = d.get(k, 0) + n

    # 1. Same printing and finish.
    for (b, c, f) in sorted(inc):
        for k in sorted([k for k in cur if k[:3] == (b, c, f)], key=lambda k: (LANG_ORDER(k[3]), COND_RANK(k[4]))):
            n = min(inc[(b, c, f)], cur[k])
            if n <= 0:
                continue
            cur[k] -= n
            inc[(b, c, f)] -= n
            add(final, k, n)
            same += n

    def pair(match):
        for (b, c, f) in sorted(inc):
            for k in sorted(cur, key=lambda k: (k[0], k[1], k[2], LANG_ORDER(k[3]), COND_RANK(k[4]))):
                if inc[(b, c, f)] <= 0:
                    break
                if cur[k] <= 0 or k[0] != b or not match(k, c):
                    continue
                n = min(inc[(b, c, f)], cur[k])
                cur[k] -= n
                inc[(b, c, f)] -= n
                to_lang = changed_lang(printings, k[1], k[3], c)
                add(final, (b, c, f, to_lang, k[4]), n)
                add(changed, (b, k[1], k[2], k[3], c, f, to_lang), n)

    # 2. Same printing, other finish. 3. Same card, other printing.
    pair(lambda k, c: k[1] == c)
    pair(lambda k, c: oracle(printings, k[1]) == oracle(printings, c))

    ins = {}
    for (b, c, f), n in inc.items():
        if n > 0:
            lang = plang(printings, c)
            add(ins, (b, c, f, lang, "NM"), n)
            add(final, (b, c, f, lang, "NM"), n)
    outs = {k: n for k, n in cur.items() if n > 0}

    row = lambda k, n: {"board": k[0], "card": k[1], "finish": k[2], "lang": k[3], **({"cond": k[4]} if k[4] != "NM" else {}), "qty": n}
    return {
        "in": [row(k, ins[k]) for k in sorted(ins)],
        "out": [row(k, outs[k]) for k in sorted(outs)],
        "changed": [{"board": k[0], "from_card": k[1], "from_finish": k[2], "from_lang": k[3],
                     "to_card": k[4], "to_finish": k[5], "to_lang": k[6], "qty": changed[k]} for k in sorted(changed)],
        "same": same,
        "entries": [entry(k[0], k[1], n, k[2], k[3], k[4]) for k, n in sorted(final.items()) if n > 0],
    }


def summary(d):
    n_in = sum(r["qty"] for r in d["in"])
    n_out = sum(r["qty"] for r in d["out"])
    n_ch = sum(r["qty"] for r in d["changed"])
    parts = []
    if n_in:
        parts.append(f"{n_in} in")
    if n_out:
        parts.append(f"{n_out} out")
    if n_ch:
        parts.append(f"{n_ch} new printing" + ("" if n_ch == 1 else "s"))
    return " · ".join(parts) if parts else "Up to date"


# Printings: Bolt in M10 / 2XM / a Japanese STA; Opt in XLN; Counterspell in 7ED; Ponder in LRW (Japanese-only JPN).
P = {
    "bolt-m10": {"oracle": "bolt", "lang": "en"},
    "bolt-2xm": {"oracle": "bolt", "lang": "en"},
    "bolt-sta-ja": {"oracle": "bolt", "lang": "ja"},
    "opt-xln": {"oracle": "opt", "lang": "en"},
    "cs-7ed": {"oracle": "counterspell", "lang": "en"},
    "ponder-lrw": {"oracle": "ponder", "lang": "en"},
}

CASES = [
    ("nothing changed", [["bolt-m10", "main", 1], ["opt-xln", "maybe", 1]],
     [["bolt-m10", "main", 1], ["opt-xln", "maybe", 1]]),
    ("a card in and a card out", [["bolt-m10", "main", 1], ["opt-xln", "main", 1]],
     [["bolt-m10", "main", 1], ["cs-7ed", "main", 1]]),
    ("a new printing", [["bolt-m10", "main", 1]], [["bolt-2xm", "main", 1]]),
    ("a new finish", [["bolt-m10", "main", 1]], [["bolt-m10", "main", 1, "foil"]]),
    ("a new finish is paired before another printing",
     [["bolt-m10", "main", 1], ["bolt-2xm", "main", 1]],
     [["bolt-2xm", "main", 1, "foil"], ["bolt-m10", "main", 1]]),
    ("a kept language stays on an unchanged line", [["bolt-m10", "main", 1, "nonfoil", "de"]], [["bolt-m10", "main", 1]]),
    ("a kept language follows a new English printing", [["bolt-m10", "main", 1, "nonfoil", "de"]], [["bolt-2xm", "main", 1]]),
    ("a Japanese printing's language doesn't follow to an English one",
     [["bolt-sta-ja", "main", 1, "nonfoil", "ja"]], [["bolt-2xm", "main", 1]]),
    ("a new Japanese printing is Japanese", [["bolt-m10", "main", 1, "nonfoil", "de"]], [["bolt-sta-ja", "main", 1]]),
    ("an In copy of a Japanese printing is Japanese", [], [["bolt-sta-ja", "main", 1]]),
    ("moved to Considering is out of Main and in Considering", [["opt-xln", "main", 1]], [["opt-xln", "maybe", 1]]),
    ("more copies: two of four change, one goes",
     [["bolt-m10", "main", 4]], [["bolt-m10", "main", 1], ["bolt-2xm", "main", 2]]),
    ("more copies: one comes in", [["opt-xln", "main", 1]], [["opt-xln", "main", 2]]),
    ("English copies pair first when languages differ",
     [["bolt-m10", "main", 1], ["bolt-m10", "main", 1, "nonfoil", "fr"]], [["bolt-m10", "main", 1], ["bolt-2xm", "main", 1]]),
    ("duplicate incoming lines merge", [], [["opt-xln", "main", 1], ["opt-xln", "main", 1]]),
    ("everything out", [["cs-7ed", "main", 1], ["ponder-lrw", "maybe", 2]], []),
    ("a kept condition stays; NM copies pair first", [["bolt-m10", "main", 1, "nonfoil", "en", "LP"], ["bolt-m10", "main", 1]],
     [["bolt-m10", "main", 1]]),
    ("a condition follows a new printing; In copies are NM",
     [["bolt-m10", "main", 1, "nonfoil", "de", "HP"]], [["bolt-2xm", "main", 1], ["opt-xln", "main", 1]]),
]


def main():
    cases = []
    for name, current, incoming in CASES:
        d = sync(P, current, incoming)
        cases.append({"name": name, "current": current, "incoming": incoming, "want": d, "summary": summary(d)})
    out = {"printings": P, "cases": cases}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {len(cases)} cases to {path}")


if __name__ == "__main__":
    main()
