#!/usr/bin/env python3
"""Compares the deployed reader with the reference reads (contract/deck-photo-lists-2026-11-13.md § Testing).

  tools/deck-photo-lists/score.py <eval.json>

<eval.json> is the answer of POST {"eval": [photo ids]} to the deck-photo-read function: {"results": [{photo_id,
status, cards: [{name, qty, board, sure}], ms}]}. For each photo: cards read, cards in the reference, copies in both,
recall and precision by card name (`out` lines ignored), and the lines that differ."""
import glob, json, os, re, sys, unicodedata

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "testdata", "deck-photo-lists", "reads")


def norm(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower().replace("æ", "ae")
    return re.sub(r"[^a-z0-9]+", " ", re.sub(r"['’]", "", s)).strip()


def bag(cards):
    m = {}
    for c in cards:
        if c.get("board") != "out":
            m[norm(c["name"])] = m.get(norm(c["name"]), 0) + int(c["qty"])
    return m


def main():
    refs = {json.load(open(f))["photo_id"]: json.load(open(f)) for f in glob.glob(os.path.join(ROOT, "*.json"))}
    tot = [0, 0, 0]
    for r in json.load(open(sys.argv[1]))["results"]:
        ref = refs.get(r["photo_id"])
        if r.get("status") != "done" or not ref:
            print(r["photo_id"][:8], r.get("status"), r.get("message", "no reference"))
            continue
        a, b = bag(r["cards"]), bag(ref["cards"])
        both = sum(min(v, a.get(k, 0)) for k, v in b.items())
        na, nb = sum(a.values()), sum(b.values())
        tot = [tot[0] + na, tot[1] + nb, tot[2] + both]
        diff = sorted(k for k in set(a) | set(b) if a.get(k, 0) != b.get(k, 0))
        print(f"{r['photo_id'][:8]} read {na} ref {nb} both {both} recall {both / max(nb, 1):.2f} precision {both / max(na, 1):.2f} "
              f"check {sum(1 for c in r['cards'] if c.get('board') != 'out' and not c.get('sure', True))} {r.get('ms', 0) / 1000:.0f}s")
        for k in diff:
            print(f"    {k}: read {a.get(k, 0)}, ref {b.get(k, 0)}")
    if tot[1]:
        print(f"all: read {tot[0]} ref {tot[1]} both {tot[2]} recall {tot[2] / tot[1]:.3f} precision {tot[2] / max(tot[0], 1):.3f}")


if __name__ == "__main__":
    main()
