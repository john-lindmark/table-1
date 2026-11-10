#!/usr/bin/env python3
"""Reference for reading an event code out of pasted text (contract/qr-sign-up-2026-10-23.md § Enter or paste a code).
Writes cases.json, which iOS JoinCodeTests, web joinCode.test.ts and Android JoinCodeTest check JoinCode.parse against.

A table-1.site link wins: /j/<code>?s=<secret> is the QR's own join (code + secret), /join/<code> a code. Else the
whole text, without spaces and dashes, when it is 4 letters or digits. Else a 4-character word right after "code"
("Code: K7PQ", "event code is k7pq"). Else a word of 4 capitals and digits from the code alphabet with a digit in it
("Draft tonight! K7PQ"), never inside another site's link. Codes come back in capitals.

  python3 -I testdata/join-code/make_cases.py
"""
import json
import os
import re
from urllib.parse import urlparse, parse_qs

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
LINK = re.compile(r"(?:https?://)?(?:www\.)?table-1\.site(/[^\s<>\"']*)", re.I)


def parse(text):
    if text is None:
        return None
    m = LINK.search(text)
    if m:
        u = urlparse("https://table-1.site" + m.group(1))
        parts = [p for p in u.path.split("/") if p]
        if len(parts) >= 2 and parts[0] == "j":
            s = parse_qs(u.query).get("s", [""])[0]
            if s and re.fullmatch(r"[A-Za-z0-9]{4}", parts[1]):
                return {"kind": "qr", "code": parts[1].upper(), "secret": s}
        if len(parts) >= 2 and parts[0] == "join" and re.fullmatch(r"[A-Za-z0-9]{4}", parts[1]):
            return {"kind": "code", "code": parts[1].upper()}
        return None
    text = re.sub(r"https?://\S+", " ", text)   # another site's link says nothing about the code
    bare = re.sub(r"[\s\-]", "", text)
    if re.fullmatch(r"[A-Za-z0-9]{4}", bare):
        return {"kind": "code", "code": bare.upper()}
    m = re.search(r"\bcode\b\W{0,3}(?:is\W{1,3})?([A-Za-z0-9]{4})\b", text, re.I)
    if m:
        return {"kind": "code", "code": m.group(1).upper()}
    for w in re.findall(r"[A-Za-z0-9]+", text):
        if len(w) == 4 and all(ch in ALPHABET for ch in w) and any(ch.isdigit() for ch in w):
            return {"kind": "code", "code": w}
    return None


TEXTS = [
    "K7PQ", "k7pq", " K7PQ\n", "K7-PQ", "K 7 P Q", "KPQR", "K7PQX", "K7P", "",
    "https://table-1.site/join/K7PQ", "table-1.site/join/k7pq", "https://www.table-1.site/join/K7PQ?ref=x",
    "Join my draft: https://table-1.site/join/AB3K tonight", "https://table-1.site/j/AB3K?s=9f8e7d", "https://table-1.site/j/AB3K",
    "https://table-1.site/e/7d0c0a7e-0000-4000-8000-000000000000", "https://example.com/join/K7PQ",
    "Code: K7PQ", "event code is k7pq", "the code k7pq!", "Draft tonight! K7PQ at the shop", "JOIN THE DRAFT", "Room 1234 at 7pm",
    "Bring 2 friends and JK3P", "hello world",
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = {"about": __doc__.strip().split("\n\n")[1], "alphabet": ALPHABET,
           "cases": [{"text": t, "want": parse(t)} for t in TEXTS]}
    with open(os.path.join(here, "cases.json"), "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
