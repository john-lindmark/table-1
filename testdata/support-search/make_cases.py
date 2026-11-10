#!/usr/bin/env python3
"""Reference for Support search (contract/support-2026-11-10.md § Search). Writes cases.json, which iOS
(SupportTests), Android (SupportTest) and the web (support.test.ts) each run against their own copy of the rule,
over the real bundled files marketing/bundle/support/faq.json and guide.json. Change the rule here first.

    python3 testdata/support-search/make_cases.py
"""

from __future__ import annotations

import json
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "marketing/bundle/support"

STOP = {"a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "my", "me", "i", "is", "it", "do",
        "does", "how", "can", "what", "why", "when", "where", "you", "your", "are", "be", "at", "by", "from", "this",
        "that", "there", "as", "if", "not"}
LIMIT = 50


def words(text: str) -> list[str]:
    """Lowercase, accents off, apostrophes dropped (don't → dont), anything else not a letter or digit splits."""
    s = unicodedata.normalize("NFKD", text)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = s.replace("'", "").replace("’", "")
    out, cur = [], []
    for c in s:
        if ("a" <= c <= "z") or ("0" <= c <= "9"):
            cur.append(c)
        elif cur:
            out.append("".join(cur))
            cur = []
    if cur:
        out.append("".join(cur))
    return out


def query_words(q: str) -> list[str]:
    allw = words(q)
    kept = [w for w in allw if w not in STOP] or allw
    seen, out = set(), []
    for w in kept:
        if w not in seen:
            seen.add(w)
            out.append(w)
    return out


def hit(q: str, w: str) -> bool:
    return w.startswith(q) or (len(q) >= 4 and q.endswith("s") and w.startswith(q[:-1]))


def docs():
    faq = json.loads((SUPPORT / "faq.json").read_text())
    guide = json.loads((SUPPORT / "guide.json").read_text())
    topics = {t["key"]: t["title"] for t in faq["topics"]}
    sections = {s["id"]: s["title"] for s in guide["sections"]}
    out = []
    for f in faq["faqs"]:
        out.append({"kind": "faq", "id": f["id"], "primary": words(f["q"]),
                    "fields": [(4, words(f["q"])), (3, words(" ".join(f.get("keywords", [])))),
                               (2, words(topics[f["topic"]])), (1, words(f["a"]))]})
    for e in guide["entries"]:
        primary = words(e.get("t") or e.get("h") or "")
        out.append({"kind": "guide", "id": e["id"], "primary": primary,
                    "fields": [(3, words(e.get("t", ""))), (2, words(e.get("h", ""))),
                               (2, words(sections[e["s"]])), (1, words(e["x"]))]})
    return out


def phrase(all_words: list[str], primary: list[str]) -> bool:
    n = len(all_words)
    if n < 2:
        return False
    for i in range(len(primary) - n + 1):
        if all(primary[i + j].startswith(all_words[j]) for j in range(n)):
            return True
    return False


def search(q: str, corpus):
    """[(kind, id, score)], best first, and whether it fell back to the closest matches."""
    if len(q.strip()) < 2:
        return [], False
    qw = query_words(q)
    if not qw:
        return [], False
    allw = words(q)
    scored = []
    for order, d in enumerate(corpus):
        best = []
        for w in qw:
            b = 0
            for weight, field in d["fields"]:
                if weight > b and any(hit(w, x) for x in field):
                    b = weight
            best.append(b)
        matched = sum(1 for b in best if b)
        if not matched:
            continue
        score = 2 * sum(best) + (6 if phrase(allw, d["primary"]) else 0) + (1 if d["kind"] == "faq" else 0)
        scored.append((matched, score, order, d))
    if not scored:
        return [], False
    full = [s for s in scored if s[0] == len(qw)]
    partial = False
    if not full:
        if len(qw) < 2:
            return [], False
        top = max(s[0] for s in scored)
        full = [s for s in scored if s[0] == top]
        partial = True
    full.sort(key=lambda s: (-s[1], 0 if s[3]["kind"] == "faq" else 1, s[2]))
    return [(s[3]["kind"], s[3]["id"], s[1]) for s in full[:LIMIT]], partial


QUERIES = ["join", "how do I join an event", "delete my account", "commander damage", "scan japanese cards",
           "pods", "re-pair", "top 8", "moxfield", "price alert", "Cube Cobra", "dispute", "offline", "no signal",
           "waitlist", "decklist", "sideboard guide", "friends of friends", "share link", "discord bot",
           "dont", "Goryo's", "ranking undo", "tcgplayer optimize", "zzzz", "a", "how", "life", "decks",
           "foil scanner", "insights legacy", "import csv manabox", "block someone", "colour", "notifications android",
           "bolt", "spice brew", "xyzzy deck"]


def main():
    corpus = docs()
    cases = []
    for q in QUERIES:
        res, partial = search(q, corpus)
        cases.append({"query": q, "words": query_words(q), "partial": partial, "count": len(res),
                      "top": [f"{k}:{i}:{s}" for k, i, s in res[:8]]})
    norm = [{"text": t, "words": words(t)} for t in
            ["Goryo's Vengeance", "Æther Vial — Lim-Dûl", "re-pair round 3", "don’t", "MH2 · EN · NM", "Ça va?"]]
    out = {"about": "Support search cases (contract/support-2026-11-10.md § Search), from make_cases.py over the "
                    "bundled faq.json and guide.json. top: kind:id:score, best first, at most 8.",
           "stop": sorted(STOP), "limit": LIMIT, "normalize": norm, "cases": cases}
    (Path(__file__).parent / "cases.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    for c in cases:
        print(f'{c["query"]!r:32} {c["count"]:3} {"partial " if c["partial"] else ""}{c["top"][:3]}')


if __name__ == "__main__":
    main()
