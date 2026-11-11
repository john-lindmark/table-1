#!/usr/bin/env python3
"""Make marketing/bundle/support/guide.json from the Table 1 Feature Guide (contract/support-2026-11-10.md).

The Feature Guide (the claude.ai artifact named in CLAUDE.md) is written for the team as much as for players: it
carries build numbers, dates, what was tested and what isn't live. Support search reads only the user-facing part,
so this script keeps each section's entries and scrubs the rest:

  * sections in SKIP_SECTIONS go entirely (What's new, Status);
  * "New" / "Updated" tags and the status chips go;
  * a sentence (or parenthesis) that talks about builds, releases, testing, dates or the team goes (DROP patterns);
  * entries listed in scrub.json's "drop" (section id + the start of the entry's text) go whole;
  * "colour" becomes "color".

Then FORBIDDEN is checked over the result: if anything matches, the script fails and names it, so a new guide
paragraph never reaches the apps unread. Usage, after saving the guide's HTML (Artifact read):

    python3 tools/support/make_guide.py <guide.html>

Look at the diff of guide.json before committing; testdata/support-search/make_cases.py then rebuilds the search cases.
"""

from __future__ import annotations

import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "marketing/bundle/support/guide.json"
SCRUB = json.loads((Path(__file__).parent / "scrub.json").read_text())

SKIP_SECTIONS = {"new", "status"}

# A sentence matching any of these is about how the feature was made or shipped, not what it does.
DROP = [r"\bbuilds?\s+\d", r"\bbundle\b", r"TestFlight", r"Play internal", r"Simulator", r"\btested\b", r"\btests?\b",
        r"\bnot yet (tried|seen|run|been|on a (phone|device)|uploaded|live|deployed|tested|posted|placed)", r"\b[Ll]ive (on|since)\b", r"\bJohn\b", r"\bdemo\b", r"next builds?", r"\bdeploy",
        r"smoke", r"rolled back", r"migration", r"set of cases", r"\bcommit", r"\b(September|October|November|December) \d",
        r"\b\d{1,2} (September|October|November|December)\b", r"\bfixed (that day|with|in)\b", r"\b[Uu]ntil \d", r"In progress",
        r"server side", r"\bshadow\b", r"\bsimulat", r"reference", r"golden", r"budget", r"\bms\b", r"\bbatch(es)?\b of",
        r"Android follows", r"\bfirst build\b", r"checked (in|on|there|against)", r"\bbuilt (and tested|on all|on iPhone|on iOS|on Android|on the server)", r"tried again after", r"\bv\d+\b",
        r"\bthe server\b.*\b(live|went)\b", r"\bon the first day\b", r"before 28",
        r"\bphotos?\b.*\b(right|wrong)\b(?!-click).*\b\d+\b", r"speed budget", r"\bper cent\b"]
DROP_RE = re.compile("|".join(DROP), re.I)

# Nothing in the output may match these.
# Nothing in the output may match these (scrub.json "forbidden"; the web's support test checks both files too).
FORBIDDEN_RE = re.compile("|".join(SCRUB["forbidden"]))


def text(fragment: str) -> str:
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", fragment))).strip()


def strip_tags(body: str) -> str:
    """Take out the New/Updated tags and status chips, keeping cell labels like "Missing"."""
    body = re.sub(r'<span class="(?:label|new|tag[^"]*)">(?:New|Updated)[^<]*</span>', "", body)
    body = re.sub(r'<span class="tag[^"]*">[^<]*</span>', "", body)
    body = re.sub(r'<span class="status[^"]*">[^<]*</span>', "", body)
    return body


def american(s: str) -> str:
    return re.sub(r"([Cc])olour", r"\1olor", s)


def sentences(s: str) -> list[str]:
    # Split after . ! ? followed by space and a capital, quote, or bracket; keep "e.g." and decimals together.
    parts = re.split(r'(?<=[.!?])\s+(?=[A-Z"“(\[])', s)
    return [p for p in parts if p]


def scrub(s: str) -> str:
    s = american(s).replace("centre", "center")
    # Parentheses that only date or place a change: "(since 30 October)", "(from build 44)".
    s = re.sub(r"\s*\((?:[^()]*?)(?:October|November|September|build|since \d|next build|Android's next|iPhone's next)[^()]*\)", "", s)
    kept = [x for x in sentences(s) if not DROP_RE.search(x)]
    out = " ".join(kept).strip()
    out = re.sub(r"\s+([,.;:])(?=\s|$)", r"\1", out)
    out = re.sub(r"\s{2,}", " ", out)
    return out


def dropped(section: str, heading: str | None, title: str | None, body: str) -> bool:
    for rule in SCRUB["drop"]:
        if rule["section"] != section:
            continue
        if "heading" in rule and heading == rule["heading"]:
            return True
        start = rule.get("starts")
        if start and ((title and title.startswith(start)) or body.startswith(start)):
            return True
    return False


def replaced(section: str, body: str) -> str:
    for rule in SCRUB["replace"]:
        if rule["section"] == section and rule["from"] in body:
            body = body.replace(rule["from"], rule["to"])
    return body


def entries(section_id: str, body: str):
    """Walk h3 / cell labels / p / li / tables in order. Yields (heading, title, text)."""
    heading = None
    for m in re.finditer(r"<h3[^>]*>(.*?)</h3>|<div class=\"cell\"[^>]*>\s*<span class=\"label\">(.*?)</span>|"
                         r"<(p|li)(?: [^>]*)?>(.*?)</\3>|<table[^>]*>(.*?)</table>", body, re.S):
        h3, cell, tag, inner, table = m.groups()
        if h3 is not None:
            heading = american(text(h3)) or None
            continue
        if cell is not None:
            heading = american(text(cell)) or None
            continue
        if table is not None:
            head = [text(c) for c in re.findall(r"<th[^>]*>(.*?)</th>", table, re.S)]
            for row in re.findall(r"<tr[^>]*>(.*?)</tr>", table, re.S):
                cells = [text(c) for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
                if not cells:
                    continue
                rest = [f"{h}: {c}" if h else c for h, c in zip(head[1:], cells[1:])] if head else cells[1:]
                yield heading, american(cells[0]), ". ".join(r.rstrip(".") for r in rest) + "."
            continue
        lead = re.match(r"\s*<strong>(.*?)</strong>\s*:?\s*", inner, re.S)
        title = None
        if lead:
            title = american(text(lead.group(1))).rstrip(":").strip() or None
            inner = inner[lead.end():]
        t = text(inner)
        if title and t[:1] in ":·–—":
            t = t[1:].strip()
        yield heading, title, t


def main(path: str) -> None:
    src = Path(path).read_text()
    sections = []
    items = []
    for sid, body in re.findall(r'<section id="([^"]+)">(.*?)</section>', src, re.S):
        if sid in SKIP_SECTIONS or sid in SCRUB.get("skip_sections", []):
            continue
        body = strip_tags(body)
        h2 = re.search(r"<h2[^>]*>(.*?)</h2>", body, re.S)
        title = SCRUB["titles"].get(sid) or american(text(h2.group(1))) if h2 else sid
        n = 0
        for heading, lead, raw in entries(sid, body):
            if dropped(sid, heading, lead, raw):
                continue
            x = scrub(replaced(sid, raw))
            if not x or len(x) < 12:
                continue
            n += 1
            item = {"id": f"{sid}-{n}", "s": sid}
            if heading:
                item["h"] = heading
            if lead:
                item["t"] = lead
            item["x"] = x
            items.append(item)
        if n:
            sections.append({"id": sid, "title": title})

    bad = []
    for it in items:
        for field in ("h", "t", "x"):
            v = it.get(field)
            if v and FORBIDDEN_RE.search(v):
                bad.append(f'{it["id"]}.{field}: …{FORBIDDEN_RE.search(v).group(0)}… in "{v[:120]}"')
    if bad:
        sys.exit("Not user-facing, add a scrub rule:\n  " + "\n  ".join(bad))

    OUT.write_text(json.dumps({"source": "Table 1 Feature Guide", "sections": sections, "entries": items},
                              ensure_ascii=False, indent=1) + "\n")
    print(f"{len(sections)} sections, {len(items)} entries, {OUT.stat().st_size // 1024} KB → {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
