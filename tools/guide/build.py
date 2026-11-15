#!/usr/bin/env python3
"""Build the Table 1 Feature Guide from marketing/guide/ (marketing/guide/README.md says how to edit it).

    python3 tools/guide/build.py           writes marketing/guide/build/feature-guide.html (the page to publish),
                                           marketing/bundle/support/guide.json (Support's scrubbed copy) and
                                           testdata/support-search/cases.json
    python3 tools/guide/build.py --published   after publishing the built page: records its hash in manifest.json
    python3 tools/guide/build.py --check   fails if those two committed files are out of date with the sources,
                                           a section file isn't in the manifest (or the other way round), or a
                                           link points at a section that doesn't exist (./test.sh runs this)
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "marketing/guide"
MANIFEST = GUIDE / "manifest.json"
OUT = GUIDE / "build/feature-guide.html"
SUPPORT_JSON = ROOT / "marketing/bundle/support/guide.json"
CASES = ROOT / "testdata/support-search/cases.json"
MAKE_GUIDE = ROOT / "tools/support/make_guide.py"
MAKE_CASES = ROOT / "testdata/support-search/make_cases.py"


def manifest() -> dict:
    return json.loads(MANIFEST.read_text())


def long_date(iso: str) -> str:
    d = date.fromisoformat(iso)
    return f"{d.day} {d.strftime('%B %Y')}"


def page() -> str:
    m = manifest()
    new = '<span class="new">New</span>'
    nav = "".join(f'    <a href="#{s["id"]}">{s["nav"]}{new if s.get("new") else ""}</a>\n' for s in m["sections"])
    sections = "\n".join((GUIDE / "sections" / f'{s["id"]}.html').read_text() for s in m["sections"])
    return ((GUIDE / "page.html").read_text()
            .replace("{{nav}}", nav).replace("{{sections}}", sections).replace("{{updated}}", long_date(m["updated"])))


def problems(html: str) -> list[str]:
    m = manifest()
    ids = [s["id"] for s in m["sections"]]
    files = sorted(p.stem for p in (GUIDE / "sections").glob("*.html"))
    out = []
    if len(set(ids)) != len(ids):
        out.append("manifest.json lists a section twice")
    out += [f"sections/{f}.html isn't in manifest.json" for f in files if f not in ids]
    out += [f"manifest.json lists {i}, but sections/{i}.html is missing" for i in ids if i not in files]
    for sid in ids:
        path = GUIDE / "sections" / f"{sid}.html"
        if not path.exists():
            continue
        body = path.read_text()
        if not body.startswith(f'    <section id="{sid}">') or not body.endswith("</section>\n"):
            out.append(f'sections/{sid}.html must start with <section id="{sid}"> and end with </section>')
    targets = set(re.findall(r'\bid="([^"]+)"', html))
    out += sorted({f"a link to #{t}, which no section or element has" for t in re.findall(r'href="#([^"]+)"', html)
                   if t not in targets})
    return out


def support(html_path: Path, guide_json: Path, cases: Path) -> None:
    """Support's copy (make_guide.py) and the search cases (make_cases.py), written where asked."""
    env = {"T1_GUIDE_JSON": str(guide_json), "T1_SUPPORT_CASES": str(cases)}
    for cmd in ([sys.executable, str(MAKE_GUIDE), str(html_path)], [sys.executable, str(MAKE_CASES)]):
        r = subprocess.run(cmd, cwd=ROOT, env={**__import__("os").environ, **env}, capture_output=True, text=True)
        if r.returncode:
            sys.exit((r.stdout + r.stderr).strip())


def main(argv: list[str]) -> None:
    html = page()
    bad = problems(html)
    if bad:
        sys.exit("Feature Guide sources:\n  " + "\n  ".join(bad))

    if argv[1:] == ["--check"]:
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "guide.html").write_text(html)
            support(t / "guide.html", t / "guide.json", t / "cases.json")
            stale = [p.relative_to(ROOT) for p, fresh in ((SUPPORT_JSON, t / "guide.json"), (CASES, t / "cases.json"))
                     if p.read_text() != fresh.read_text()]
        if stale:
            sys.exit("Out of date with marketing/guide (run python3 tools/guide/build.py): "
                     + ", ".join(map(str, stale)))
        print("Feature Guide: sources, Support copy and search cases agree")
        return
    sha = hashlib.sha256(html.encode()).hexdigest()
    if argv[1:] == ["--published"]:
        m = manifest()
        m["published"] = {"sha256": sha, "on": date.today().isoformat()}
        MANIFEST.write_text(json.dumps(m, ensure_ascii=False, indent=1) + "\n")
        print(f"Recorded the published page ({sha[:12]}) in {MANIFEST.relative_to(ROOT)}")
        return
    if argv[1:]:
        sys.exit(__doc__)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html)
    support(OUT, SUPPORT_JSON, CASES)
    pending = sha != manifest().get("published", {}).get("sha256")
    print(f"{len(manifest()['sections'])} sections, {len(html.encode()) // 1024} KB → {OUT.relative_to(ROOT)}; "
          f"Support copy and search cases rebuilt (review: git diff marketing/bundle/support). "
          + ("The page differs from the published one: publish it with the next build or ship."
             if pending else "The page is the one already published."))


if __name__ == "__main__":
    main(sys.argv)
