#!/usr/bin/env python3
"""Split a Feature Guide page into marketing/guide/ (the reverse of build.py).

Used once to move the guide into the repository, and again whenever the published page was changed somewhere else
(an edit on claude.ai, another session's publish): save the live page with Artifact read, run this on it, and
`git diff marketing/guide` shows what changed outside the repository. No diff means the sources match the page.

    python3 tools/guide/split.py <guide.html>

Writes marketing/guide/page.html (everything but the index links and the sections, with {{nav}}, {{sections}} and
{{updated}} in their places), marketing/guide/manifest.json (date, section order, index titles) and one
marketing/guide/sections/<id>.html per section. Fails if building them back doesn't give the same page.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import build  # noqa: E402

GUIDE = build.GUIDE
NAV_LINK = re.compile(r'    <a href="#([^"]+)">(.*?)(<span class="new">New</span>)?</a>\n')


def unwrap(src: str) -> str:
    """Artifact read hands back the page inside the service's own skeleton; keep the page as published."""
    start = src.find("<!doctype html>\n<html")
    if start > 0:
        src = src[start:]
        end = src.rfind("</html>\n")
        src = src[:end + len("</html>\n")]
    return src


def main(path: str) -> None:
    src = unwrap(Path(path).read_text())

    m = re.search(r"updated (\d{1,2} \w+ \d{4})</span>", src)
    if not m:
        sys.exit("No 'updated <date>' in the header.")
    date = m.group(1)
    updated = datetime.strptime(date, "%d %B %Y").date().isoformat()

    links = list(NAV_LINK.finditer(src))
    nav_start, nav_end = links[0].start(), links[-1].end()

    main_open = src.index("  <main>\n") + len("  <main>\n")
    main_close = src.index("  </main>\n")
    sections = re.findall(r'    <section id="([^"]+)">.*?</section>', src[main_open:main_close], re.S)
    bodies = re.findall(r'(    <section id="[^"]+">.*?</section>)', src[main_open:main_close], re.S)

    nav = {l.group(1): (l.group(2), bool(l.group(3))) for l in links}
    if [l.group(1) for l in links] != sections:
        sys.exit("The index and the sections are in a different order; fix the page first.")

    page = src[:nav_start] + "{{nav}}" + src[nav_end:main_open] + "{{sections}}" + src[main_close:]
    page = page.replace(date, "{{updated}}")

    (GUIDE / "sections").mkdir(parents=True, exist_ok=True)
    for old in (GUIDE / "sections").glob("*.html"):
        if old.stem not in sections:
            old.unlink()
    for sid, body in zip(sections, bodies):
        (GUIDE / "sections" / f"{sid}.html").write_text(body + "\n")
    (GUIDE / "page.html").write_text(page)

    manifest = json.loads(build.MANIFEST.read_text()) if build.MANIFEST.exists() else {}
    manifest["updated"] = updated
    manifest["sections"] = [dict({"id": sid, "nav": nav[sid][0]}, **({"new": True} if nav[sid][1] else {}))
                            for sid in sections]
    build.MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")

    if build.page() != src:
        sys.exit("Building the split files back doesn't give the same page; split.py needs fixing.")
    print(f"{len(sections)} sections, updated {updated} → {GUIDE.relative_to(build.ROOT)} (round trip identical)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
