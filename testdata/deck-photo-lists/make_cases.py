#!/usr/bin/env python3
"""Reference for the decklist screen's rules (contract/deck-photo-lists-2026-11-13.md § Client rules).
Writes cases.json beside this file; iOS DeckPhotoList / web deckPhotoList.ts / Android DeckPhotoList follow it.
Change the rule here first, run this, then make the three clients pass."""
import copy, json, os

ORDER = {"main": 0, "side": 1, "out": 2}


def row(brief):
    """The line under a photo. brief: the photo row's `list` ({status, cards, check, checked}) or None."""
    if not brief:
        return "Read decklist"
    s = brief.get("status")
    if s in ("queued", "reading"):
        return "Reading the decklist…"
    if s == "failed":
        return "Decklist · couldn't read · try again"
    cards = brief.get("cards", 0)
    if cards <= 0:
        return "Decklist · no cards read"
    text = f"Decklist · {cards} {'card' if cards == 1 else 'cards'}"
    if brief.get("checked"):
        return text + " · checked"
    check = brief.get("check", 0)
    return text + (f" · {check} to check" if check else "")


def target(event_type, fmt):
    """Cards the main deck should hold, or None."""
    fmt = (fmt or "").lower()
    if (event_type or "").lower() == "limited":
        return 40
    if fmt in ("commander", "canadian_highlander", "canlander"):
        return 100
    if (event_type or "").lower() == "constructed":
        return 60
    return None


def counts(entries):
    c = {"main": 0, "side": 0, "out": 0, "check": 0}
    for e in entries:
        c[e["board"]] += e["qty"]
        if e["board"] != "out" and (not e.get("card_id") or not e.get("sure", True)):
            c["check"] += 1
    return c


def size_line(main, tgt):
    text = f"{main} {'card' if main == 1 else 'cards'}"
    if tgt and main < tgt:
        return f"{text} · {tgt - main} short of {tgt}"
    if tgt == 100 and main > 100:
        return f"{text} · {main - 100} over 100"
    return text


def key(e):
    return (e.get("card_id") or "?" + e["name"].lower(), e["board"])


def tidy(entries):
    """Same card on the same board is one line (first place kept); main, then side, then out."""
    out, at = [], {}
    for e in entries:
        k = key(e)
        if k in at:
            had = out[at[k]]
            had["qty"] = min(99, had["qty"] + e["qty"])
            if not e.get("sure", True):
                had["sure"] = False
                if e.get("read") and not had.get("read"):
                    had["read"] = e["read"]
        else:
            at[k] = len(out)
            out.append(copy.deepcopy(e))
    return [e for _, e in sorted(enumerate(out), key=lambda p: (ORDER[p[1]["board"]], p[0]))]


def set_qty(entries, i, qty):
    es = copy.deepcopy(entries)
    if qty <= 0:
        del es[i]
    else:
        es[i]["qty"] = min(99, qty)
    return es


def move(entries, i, board):
    es = copy.deepcopy(entries)
    es[i]["board"] = board
    return tidy(es)


def replace(entries, i, card):
    """The player picked the card this line really is: sure, nothing left to check."""
    es = copy.deepcopy(entries)
    es[i] = {"card_id": card["card_id"], "name": card["name"], "qty": es[i]["qty"], "board": es[i]["board"], "sure": True}
    return tidy(es)


def confirm(entries, i):
    es = copy.deepcopy(entries)
    if es[i].get("card_id"):
        es[i]["sure"] = True
        es[i].pop("read", None)
    return es


def add(entries, card, board):
    es = copy.deepcopy(entries)
    es.append({"card_id": card["card_id"], "name": card["name"], "qty": 1, "board": board, "sure": True})
    return tidy(es)


def deck_entries(entries):
    """What list_create takes: [[card_id, board, qty]] for main and side; lines without a card are left out."""
    m, skipped = {}, 0
    for e in entries:
        if e["board"] == "out":
            continue
        if not e.get("card_id"):
            skipped += 1
            continue
        k = (e["card_id"], e["board"])
        m[k] = m.get(k, 0) + e["qty"]
    return {"entries": [[c, b, q] for (c, b), q in m.items()], "skipped": skipped}


def deck_name(event_name, player, mine):
    name = (event_name or "").strip() or "Deck photo"
    if not mine and (player or "").strip():
        name = f"{player.strip()} · {name}"
    return name[:60].strip()


FORMATS = {"standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander"}


def deck_format(event_type, fmt):
    fmt = (fmt or "").lower()
    if fmt == "canadian_highlander":
        return "canlander"
    return fmt if fmt in FORMATS else "other"


G = {"card_id": "g", "name": "Goblin Guide"}
I = {"card_id": "i", "name": "Island"}
M = {"card_id": "m", "name": "Mana Drain"}
LIST = [
    {"card_id": "g", "name": "Goblin Guide", "qty": 2, "board": "main", "sure": True},
    {"card_id": "i", "name": "Island", "qty": 16, "board": "main", "sure": False, "read": "pile of about 16"},
    {"card_id": None, "name": "Room of", "qty": 1, "board": "main", "sure": False},
    {"card_id": "m", "name": "Mana Drain", "qty": 1, "board": "side", "sure": True},
    {"card_id": "g", "name": "Goblin Guide", "qty": 1, "board": "out", "sure": True},
]

cases = {
    "row": [{"brief": b, "text": row(b)} for b in [
        None, {"status": "queued", "cards": 0, "check": 0, "checked": False}, {"status": "reading", "cards": 12, "check": 0, "checked": True},
        {"status": "failed", "cards": 0, "check": 0, "checked": False}, {"status": "done", "cards": 0, "check": 0, "checked": False},
        {"status": "done", "cards": 40, "check": 0, "checked": False}, {"status": "done", "cards": 38, "check": 3, "checked": False},
        {"status": "done", "cards": 40, "check": 2, "checked": True}, {"status": "done", "cards": 1, "check": 1, "checked": False}]],
    "target": [{"event_type": t, "format": f, "target": target(t, f)} for t, f in [
        ("limited", "draft"), ("limited", "team_sealed"), ("constructed", "modern"), ("constructed", "commander"),
        ("constructed", "canadian_highlander"), ("constructed", "other_constructed"), (None, None), ("", "modern")]],
    "counts": [{"entries": LIST, "counts": counts(LIST)}, {"entries": [], "counts": counts([])}],
    "sizeLine": [{"main": m, "target": t, "text": size_line(m, t)} for m, t in [
        (40, 40), (38, 40), (41, 40), (1, None), (0, 40), (60, 60), (59, 60), (75, 60), (100, 100), (101, 100), (99, 100)]],
    "edits": [
        {"op": "setQty", "i": 1, "qty": 17, "entries": LIST, "out": set_qty(LIST, 1, 17)},
        {"op": "setQty", "i": 2, "qty": 0, "entries": LIST, "out": set_qty(LIST, 2, 0)},
        {"op": "setQty", "i": 0, "qty": 500, "entries": LIST, "out": set_qty(LIST, 0, 500)},
        {"op": "move", "i": 4, "board": "main", "entries": LIST, "out": move(LIST, 4, "main")},
        {"op": "move", "i": 0, "board": "side", "entries": LIST, "out": move(LIST, 0, "side")},
        {"op": "move", "i": 3, "board": "out", "entries": LIST, "out": move(LIST, 3, "out")},
        {"op": "replace", "i": 2, "card": M, "entries": LIST, "out": replace(LIST, 2, M)},
        {"op": "replace", "i": 2, "card": I, "entries": LIST, "out": replace(LIST, 2, I)},
        {"op": "replace", "i": 1, "card": G, "entries": LIST, "out": replace(LIST, 1, G)},
        {"op": "confirm", "i": 1, "entries": LIST, "out": confirm(LIST, 1)},
        {"op": "confirm", "i": 2, "entries": LIST, "out": confirm(LIST, 2)},
        {"op": "add", "card": M, "board": "main", "entries": LIST, "out": add(LIST, M, "main")},
        {"op": "add", "card": I, "board": "main", "entries": LIST, "out": add(LIST, I, "main")},
        {"op": "add", "card": I, "board": "side", "entries": LIST, "out": add(LIST, I, "side")},
        {"op": "add", "card": G, "board": "main", "entries": [], "out": add([], G, "main")},
    ],
    "deckEntries": [{"entries": LIST, "out": deck_entries(LIST)},
                    {"entries": LIST + [{"card_id": "g", "name": "Goblin Guide", "qty": 2, "board": "main", "sure": True}], "out": deck_entries(LIST + [{"card_id": "g", "name": "Goblin Guide", "qty": 2, "board": "main", "sure": True}])},
                    {"entries": [], "out": deck_entries([])}],
    "deckName": [{"event": e, "player": p, "mine": m, "name": deck_name(e, p, m)} for e, p, m in [
        ("Friday draft", "Bea", True), ("Friday draft", "Bea", False), ("", "Bea", True), (None, "", False),
        ("Team draft · Lindmark Cube · Thu 12 Nov with a very long name that keeps going", "Alexandria", False)]],
    "deckFormat": [{"event_type": t, "format": f, "deck": deck_format(t, f)} for t, f in [
        ("limited", "draft"), ("constructed", "modern"), ("constructed", "canadian_highlander"), ("constructed", "other_constructed"),
        ("constructed", "premodern"), ("constructed", "commander"), (None, None)]],
}
json.dump(cases, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases.json"), "w"), ensure_ascii=False, indent=1)
print(sum(len(v) for v in cases.values()), "cases")
