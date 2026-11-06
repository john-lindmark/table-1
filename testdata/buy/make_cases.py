#!/usr/bin/env python3
"""Reference for the Buy screen (contract/buy-2026-11-06.md).

Which copies of a deck, cube, wants or Missing go into a TCGplayer cart, what they cost, and the tcgplayer_cart calls
that build it. Writes cases.json, which iOS BuyListTests, web buyList.test.ts and Android BuyListTest read.

    python3 -I testdata/buy/make_cases.py      # rewrites testdata/buy/cases.json
"""
import json
from pathlib import Path

HERE = Path(__file__).parent


def rows(lines, owned, oracles, opts):
    """One row per line in a picked board, in line order: copies listed, copies you own that cover it, copies to buy.

    Skip owned: basic lands are left out (they're never missing), then the printing and finish a line names cover it
    first and, with Any printing, the card's other copies cover what's left, lines in order; a copy covers one line.
    Without Skip owned nothing is owned and every copy is bought."""
    boards = set(opts["boards"])
    inc = [l for l in lines if l["board"] in boards and l["qty"] > 0 and not (opts["skip_owned"] and l.get("basic"))]
    exact, spare = {}, {}
    for k, n in owned.items():
        card, finish = k.split("|")[:2]
        exact[f"{card}|{finish}"] = exact.get(f"{card}|{finish}", 0) + n
        o = oracles.get(card, card)
        spare[o] = spare.get(o, 0) + n
    cov = [0] * len(inc)
    if opts["skip_owned"]:
        for i, l in enumerate(inc):
            k = f"{l['card_id']}|{l['finish']}"
            c = min(l["qty"], exact.get(k, 0))
            exact[k] = exact.get(k, 0) - c
            o = oracles.get(l["card_id"], l["card_id"])
            spare[o] = spare.get(o, 0) - c
            cov[i] = c
        if opts["any_printing"]:
            for i, l in enumerate(inc):
                o = oracles.get(l["card_id"], l["card_id"])
                c = min(l["qty"] - cov[i], max(0, spare.get(o, 0)))
                spare[o] = spare.get(o, 0) - c
                cov[i] += c
    return [{"card_id": l["card_id"], "board": l["board"], "finish": l["finish"], "qty": l["qty"], "owned": c,
             "buy": l["qty"] - c} for l, c in zip(inc, cov)]


def totals(lines, rs):
    """Money in cents. price: every row's copies; owned: the copies you own, at the line's price; total: the copies
    bought; unpriced: copies bought with no price."""
    unit = {(l["card_id"], l["board"], l["finish"]): l.get("unit") for l in lines}
    t = {"cards": 0, "owned": 0, "buy": 0, "price": 0, "owned_value": 0, "total": 0, "unpriced": 0}
    for r in rs:
        u = unit[(r["card_id"], r["board"], r["finish"])]
        t["cards"] += r["qty"]
        t["owned"] += r["owned"]
        t["buy"] += r["buy"]
        if u is None:
            t["unpriced"] += r["buy"]
        else:
            t["price"] += r["qty"] * u
            t["owned_value"] += r["owned"] * u
            t["total"] += r["buy"] * u
    return t


def calls(lines, rs, exact):
    """tcgplayer_cart calls: items {card_id} or {oracle_id} (a want for any printing) with copies summed per key in
    row order. Tokens always go to their product pages (p_products true); everything else follows Exact printings.
    One call when both agree; none when nothing is bought."""
    meta = {(l["card_id"], l["board"], l["finish"]): l for l in lines}
    groups = {}
    for r in rs:
        if r["buy"] <= 0:
            continue
        l = meta[(r["card_id"], r["board"], r["finish"])]
        products = True if r["board"] == "tokens" else exact
        key = ("oracle_id", l["oracle_id"]) if l.get("any") else ("card_id", r["card_id"])
        g = groups.setdefault(products, {})
        g[key] = g.get(key, 0) + r["buy"]
    out = []
    for products in ([exact, not exact] if exact is not None else []):
        if products in groups:
            out.append({"products": products,
                        "items": [{k[0]: k[1], "qty": n} for k, n in groups[products].items()]})
    return out


def merge(answers):
    """Two calls' answers as one: Mass Entry parts in order, then every product page by name, set and number."""
    out = {"enabled": all(a["enabled"] for a in answers), "lines": 0, "unknown": 0, "urls": [], "products": []}
    for a in answers:
        out["lines"] += a["lines"]
        out["unknown"] += a["unknown"]
        out["urls"] += a["urls"]
        out["products"] += a["products"]
    out["products"].sort(key=lambda p: (p["name"], p["set"], p["number"]))
    return out


ORACLES = {"bolt-m11": "bolt", "bolt-2x2": "bolt", "bolt-lea": "bolt", "ragavan-mh2": "ragavan",
           "ragavan-promo": "ragavan", "island-1": "island", "treasure-t": "treasure", "opt-eld": "opt"}

DECK = [
    {"card_id": "ragavan-mh2", "board": "main", "finish": "nonfoil", "qty": 4, "unit": 5500},
    {"card_id": "bolt-m11", "board": "main", "finish": "nonfoil", "qty": 4, "unit": 150},
    {"card_id": "island-1", "board": "main", "finish": "nonfoil", "qty": 6, "unit": 10, "basic": True},
    {"card_id": "bolt-2x2", "board": "side", "finish": "foil", "qty": 2, "unit": 400},
    {"card_id": "opt-eld", "board": "maybe", "finish": "nonfoil", "qty": 1, "unit": None},
    {"card_id": "treasure-t", "board": "tokens", "finish": "nonfoil", "qty": 1, "unit": 25},
]
OWNED = {"ragavan-promo|foil|en": 1, "bolt-m11|nonfoil|en|LP": 3, "bolt-lea|nonfoil": 2, "island-1|nonfoil": 20}
MAIN_SIDE = ["main", "side"]


def case(name, lines, owned, opts):
    rs = rows(lines, owned, ORACLES, opts)
    return {"name": name, "lines": lines, "owned": owned, "options": opts, "rows": rs, "totals": totals(lines, rs),
            "calls": calls(lines, rs, opts["exact"])}


def opts(skip=True, anyp=True, exact=False, boards=MAIN_SIDE):
    return {"skip_owned": skip, "any_printing": anyp, "exact": exact, "boards": boards}


cases = [
    case("skip owned, any printing counts", DECK, OWNED, opts()),
    case("only the exact printing counts", DECK, OWNED, opts(anyp=False)),
    case("buy every card, basics too", DECK, OWNED, opts(skip=False)),
    case("exact printings: one call with product pages", DECK, OWNED, opts(exact=True)),
    case("considering and tokens: tokens to their pages, the rest by name", DECK, OWNED,
         opts(boards=["main", "side", "maybe", "tokens"])),
    case("exact printings with tokens: one call", DECK, OWNED, opts(exact=True, boards=["main", "tokens"])),
    case("nothing to buy", DECK, {"ragavan-mh2|nonfoil": 4, "bolt-m11|nonfoil": 4, "bolt-2x2|foil": 2}, opts()),
    case("wants: any printing by card, a printing by its page", [
        {"card_id": "bolt-m11", "oracle_id": "o-bolt", "any": True, "board": "main", "finish": "nonfoil", "qty": 4, "unit": 150},
        {"card_id": "ragavan-promo", "board": "main", "finish": "foil", "qty": 1, "unit": 9000},
        {"card_id": "bolt-lea", "board": "main", "finish": "nonfoil", "qty": 1, "unit": None},
    ], {}, opts(skip=False, exact=True, boards=["main"])),
    case("the same printing twice is summed", [
        {"card_id": "bolt-m11", "board": "main", "finish": "nonfoil", "qty": 3, "unit": 150},
        {"card_id": "bolt-m11", "board": "side", "finish": "nonfoil", "qty": 1, "unit": 150},
    ], {}, opts()),
]

answers = [
    {"enabled": True, "lines": 2, "unknown": 0, "urls": ["https://e/1"],
     "products": [{"card_id": "t2", "name": "Treasure", "set": "TMH2", "number": "21", "qty": 1, "url": "https://p/2"}]},
    {"enabled": True, "lines": 0, "unknown": 1, "urls": [],
     "products": [{"card_id": "t1", "name": "Goblin", "set": "TM11", "number": "6", "qty": 1, "url": "https://p/1"}]},
]
merges = [{"name": "cards and tokens", "answers": answers, "merged": merge(answers)}]

(HERE / "cases.json").write_text(json.dumps({
    "_about": "Buy screen (contract/buy-2026-11-06.md): rows (copies listed, owned, bought) for the picked options, "
              "totals in cents, the tcgplayer_cart calls, and two answers merged. Owned keys are card_id|finish[|lang[|cond]]; "
              "oracles maps a printing to its card.",
    "oracles": ORACLES, "cases": cases, "merge": merges}, indent=1, ensure_ascii=False) + "\n")
print(f"{len(cases)} cases, {len(merges)} merge")
