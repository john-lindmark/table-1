#!/usr/bin/env python3
"""Adds the illustrator and frame to every P line of testdata/scan/catalog.tsv.gz from Scryfall's default_cards
bulk file, joined by set code, collector number and language (the test pack's ids are counters, not Scryfall's).

The live pack carries both fields since 2026-10-28 (contract/catalog-2026-10-14.md, P line fields 14 and 15), so a
pack trimmed from live after that already has them and this tool is only for an older test pack:

  python3 -I testdata/scan/tools/art_fields.py <default-cards.jsonl[.gz]>
"""
import gzip, json, os, sys

src = sys.argv[1]
pack = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "catalog.tsv.gz")
opener = gzip.open if src.endswith(".gz") else open
art = {}
with opener(src, "rt", encoding="utf8") as f:
    for line in f:
        c = json.loads(line)
        artist = c.get("artist") or (c.get("card_faces") or [{}])[0].get("artist") or ""
        art[(c.get("set", ""), c.get("collector_number", ""), c.get("lang", ""))] = (artist, c.get("frame") or "")
lines, hit, miss = [], 0, 0
with gzip.open(pack, "rt", encoding="utf8") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if c[0] == "P":
            a = art.get((c[3], c[4], c[5]))
            if a:
                hit += 1
                c = c[:13] + [a[0].replace("\t", " "), a[1]]
            else:
                miss += 1
                c = c[:13]
        lines.append("\t".join(c))
with gzip.open(pack, "wt", encoding="utf8", compresslevel=9) as f:
    f.write("\n".join(lines) + "\n")
print(f"{hit} printings with artist and frame, {miss} not in Scryfall's file, {os.path.getsize(pack)} bytes")
