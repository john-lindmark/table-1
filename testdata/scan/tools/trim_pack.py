#!/usr/bin/env python3
"""Writes testdata/scan/catalog.tsv.gz: the live catalog pack with every card and printing, shrunk for the repo.

Ids become short counters and columns the scanner doesn't use (image timestamps, colors, legality, points) are
emptied; names, type lines, set codes, collector numbers, languages, release dates and the original-printing flag
stay, as do the illustrator and frame, and N lines (printed names in other languages) are kept as they are, so the
matcher sees the same names and printings as on a phone. Re-run when the pack format changes:

  python3 -I testdata/scan/tools/trim_pack.py <pack.tsv or pack.tsv.gz>
"""
import gzip, os, sys

src = sys.argv[1]
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "catalog.tsv.gz")
opener = gzip.open if src.endswith(".gz") else open
lines = []
with opener(src, "rt", encoding="utf8") as f:
    for n, line in enumerate(f):
        c = line.rstrip("\n").split("\t")
        if c[0] == "O":
            # O idx oracle_id name name_norm type_line mana_cost cmc colors face_names legal points
            c = ["O", c[1], f"o{c[1]}", c[3], c[4], c[5], "", "0", "", c[9] if len(c) > 9 else "", "", "0"]
        elif c[0] == "P":
            # P card_id oracle_idx set cn lang rarity finishes released_at image_ts image_faces printed_name original
            #   artist frame (the last two since 2026-10-28; art_fields.py adds them to an older pack)
            c = ["P", f"p{n}", c[2], c[3], c[4], c[5], c[6], c[7], c[8], "", c[10], c[11] if len(c) > 11 else "",
                 c[12] if len(c) > 12 else ""] + c[13:15]
        lines.append("\t".join(c))
with gzip.open(out, "wt", encoding="utf8", compresslevel=9) as f:
    f.write("\n".join(lines) + "\n")
print(out, os.path.getsize(out))
