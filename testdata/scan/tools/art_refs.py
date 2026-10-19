#!/usr/bin/env python3
"""Art matching spike, step 1: the reference list (see testdata/scan/README.md, "Art matching spike").

Reads Scryfall's `unique_artwork` and `default_cards` bulk files (download them into the cache first, see below) and
writes, into the cache:
  arts.tsv      one row per scannable illustration (front and back faces of double-faced cards each count): order,
                illustration_id, card name, face name, set, collector number, frame, full_art, art_crop URL. The
                illustrations the test photos show come first, then the rest shuffled (seed 1), so the first N rows
                are "the test set plus N - k random distractors".
  cards.tsv     the same for whole-card matching: one row per card face image (Scryfall border_crop): the exact
                printings the test photos show first, then each art's printing from arts.tsv in that order. Columns:
                order, file id (card id + face), card name, face name, set, collector number, frame, full_art,
                illustration_id, border_crop URL.
  expected.tsv  per photo: the illustration ids that count as the right art (every printing of that card in that set
                and number; any printing of the card when the set or number is `*`).

Cache: ~/Library/Caches/table1-art-spike (outside the repo). Bulk files, from https://api.scryfall.com/bulk-data:
  unique.jsonl.gz   unique_artwork jsonl_download_uri
  default.jsonl.gz  default_cards jsonl_download_uri

Run from the repo root:  python3 testdata/scan/tools/art_refs.py
"""
import gzip, json, os, random, sys

CACHE = os.path.expanduser("~/Library/Caches/table1-art-spike")
ROOT = "testdata/scan"
# Not cards a player scans (the matcher can't name them either).
SKIP_LAYOUTS = {"token", "double_faced_token", "art_series", "emblem", "vanguard", "scheme", "planar", "augment", "host"}


def faces(c, image="art_crop"):
    """(face name, illustration_id, image url) for each face with its own art."""
    if c.get("image_uris") and c.get("illustration_id"):
        yield c["name"].split(" // ")[0], c["illustration_id"], c["image_uris"][image]
    for f in c.get("card_faces") or []:
        if f.get("image_uris") and f.get("illustration_id"):
            yield f["name"], f["illustration_id"], f["image_uris"][image]


def card_rows(c):
    """cards.tsv rows (without order) for each face image of a printing."""
    for i, (face, ill, url) in enumerate(faces(c, "border_crop")):
        yield [f"{c['id']}-{i}", c["name"], face, c["set"], c["collector_number"], c.get("frame", ""),
               "1" if c.get("full_art") else "0", ill, url]


def scannable(c):
    return c.get("layout") not in SKIP_LAYOUTS and "paper" in (c.get("games") or []) and not c.get("set_type") == "token"


def read(path):
    with gzip.open(os.path.join(CACHE, path), "rt") as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)


def main():
    photos = [l.rstrip("\n").split("\t") for l in open(os.path.join(ROOT, "photos.tsv"), encoding="utf-8")][1:]

    # Every printing: (set, cn) and name → illustrations.
    by_print, by_name, printings = {}, {}, {}
    for c in read("default.jsonl.gz"):
        if not scannable(c):
            continue
        printings.setdefault((c["set"], c["collector_number"].lower()), []).extend(card_rows(c))
        printings.setdefault((c["set"], "*", c["name"].lower()), []).extend(card_rows(c))
        for face, ill, _ in faces(c):
            by_print.setdefault((c["set"], c["collector_number"].lower()), set()).add(ill)
            by_print.setdefault((c["set"], "*", c["name"].lower()), set()).add(ill)
            by_name.setdefault(c["name"].lower(), set()).add(ill)
            by_name.setdefault(c["name"].split(" // ")[0].lower(), set()).add(ill)

    expected, wanted, test_cards = [], set(), []
    for p in photos:
        file, name, st, cn = p[0], p[1], p[2], p[3]
        n = name.lower()
        if st == "*":
            ills = by_name.get(n, set())
        elif cn == "*":
            ills = by_print.get((st, "*", n), set()) or set().union(
                *[v for k, v in by_print.items() if len(k) == 3 and k[0] == st and k[2].split(" // ")[0] == n] or [set()])
        else:
            ills = by_print.get((st, cn.lower().lstrip("0") or "0"), set()) | by_print.get((st, cn.lower()), set())
        if not ills:
            ills = by_name.get(n, set())
            print(f"{file}: no printing {st} {cn}, any art of {name} counts ({len(ills)})", file=sys.stderr)
        expected.append((file, name, sorted(ills)))
        wanted |= ills
        if st != "*":
            k = (st, "*", n) if cn == "*" else (st, cn.lower())
            test_cards.extend(printings.get(k, []) or printings.get((st, cn.lower().lstrip("0") or "0"), []))

    arts, seen, rep = [], set(), {}
    for c in read("unique.jsonl.gz"):
        if not scannable(c):
            continue
        for row in card_rows(c):
            rep.setdefault(row[7], row)
        for face, ill, url in faces(c):
            if ill in seen:
                continue
            seen.add(ill)
            arts.append([ill, c["name"], face, c["set"], c["collector_number"], c.get("frame", ""),
                         "1" if c.get("full_art") else "0", url])
    missing = wanted - seen
    if missing:
        print(f"{len(missing)} expected illustrations aren't in unique_artwork", file=sys.stderr)
    first = [a for a in arts if a[0] in wanted]
    rest = [a for a in arts if a[0] not in wanted]
    random.Random(1).shuffle(rest)
    with open(os.path.join(CACHE, "arts.tsv"), "w", encoding="utf-8") as f:
        for i, a in enumerate(first + rest):
            f.write("\t".join([str(i)] + a) + "\n")
    cards, ids = [], set()
    for row in test_cards + [rep[a[0]] for a in first + rest]:
        if row[0] not in ids:
            ids.add(row[0])
            cards.append(row)
    with open(os.path.join(CACHE, "cards.tsv"), "w", encoding="utf-8") as f:
        for i, a in enumerate(cards):
            f.write("\t".join([str(i)] + a) + "\n")
    print(f"{len(cards)} card images ({len(set(r[0] for r in test_cards))} printings shown in the test photos)")
    with open(os.path.join(CACHE, "expected.tsv"), "w", encoding="utf-8") as f:
        for file, name, ills in expected:
            f.write(f"{file}\t{name}\t{','.join(ills)}\n")
    print(f"{len(arts)} illustrations ({len(first)} shown in the test photos), {len(expected)} photos")


main()
