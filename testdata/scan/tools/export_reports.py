#!/usr/bin/env python3
"""Export scan reports (public.scan_reports) as matcher test cases.

Each report becomes testdata/scan/reports/<id>.json, the format the matcher accuracy tests read:
  {"id", "source": "report", "frames": [[line, ...], ...], "name", "set", "cn", ...context}
set/cn are "*" when the right printing isn't known: a card added by hand (wrong_card, missed) is often just the
default printing, so only the name is trusted there. wrong_printing reports keep the chosen set and number.

Reports with no answer (kind "removed": a scanned card was deleted and nothing was added by hand) go to
testdata/scan/reports/unlabelled/<id>.json with "name": null and "not": what the matcher wrongly picked. The
tests don't read that folder; fill in name/set/cn (or delete the file if it was just a duplicate) and move it up.

Existing files are never overwritten, so hand edits survive re-runs.

Usage (service role key, never commit it):
  SUPABASE_SERVICE_ROLE_KEY=... python3 testdata/scan/tools/export_reports.py [--since 2026-10-16] [--dry-run]
SUPABASE_URL defaults to the Table 1 project.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://aaozhfcbvqrgkkrihkrd.supabase.co"
OUT = Path(__file__).resolve().parent.parent / "reports"
PAGE = 1000


def fetch(url: str, key: str, since: str | None):
    rows, offset = [], 0
    while True:
        q = {"select": "id,kind,platform,app_version,pack_version,owned_only,frames,matched,corrected,created_at",
             "order": "created_at.asc,id.asc", "limit": str(PAGE), "offset": str(offset)}
        if since:
            q["created_at"] = f"gte.{since}"
        req = urllib.request.Request(f"{url}/rest/v1/scan_reports?{urllib.parse.urlencode(q)}",
                                     headers={"apikey": key, "Authorization": f"Bearer {key}"})
        with urllib.request.urlopen(req) as r:
            page = json.load(r)
        rows += page
        if len(page) < PAGE:
            return rows
        offset += PAGE


def case(r: dict) -> tuple[Path, dict]:
    matched, corrected = r.get("matched"), r.get("corrected")
    c = {"id": r["id"], "source": "report", "frames": r["frames"]}
    if corrected:
        exact_printing = r["kind"] == "wrong_printing"
        c.update({"name": corrected.get("name"),
              "set": corrected.get("set", "*") if exact_printing else "*",
              "cn": corrected.get("cn", "*") if exact_printing else "*"})
        path = OUT / f"{r['id']}.json"
    else:
        c.update({"name": None, "set": "*", "cn": "*",
              "not": matched and {k: matched.get(k) for k in ("name", "set", "cn")}})
        path = OUT / "unlabelled" / f"{r['id']}.json"
    c.update({"kind": r["kind"], "platform": r["platform"], "app_version": r.get("app_version"),
          "pack_version": r.get("pack_version"), "owned_only": r.get("owned_only", False),
          "matched": matched, "reported_at": r["created_at"]})
    return path, c


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", help="only reports created on or after this ISO date/time")
    ap.add_argument("--dry-run", action="store_true", help="list what would be written")
    a = ap.parse_args()
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not key:
        sys.exit("Set SUPABASE_SERVICE_ROLE_KEY (Supabase dashboard → Project settings → API keys).")
    url = os.environ.get("SUPABASE_URL", DEFAULT_URL).rstrip("/")

    written = skipped = unlabelled = 0
    for r in fetch(url, key, a.since):
        path, c = case(r)
        if path.exists() or (path.parent == OUT / "unlabelled" and (OUT / path.name).exists()):
            skipped += 1
            continue
        if path.parent.name == "unlabelled":
            unlabelled += 1
        written += 1
        if a.dry_run:
            print(f"would write {path.relative_to(OUT.parent)}  {c['kind']}  {c['name'] or '?'}")
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(c, indent=2, ensure_ascii=False) + "\n")
    print(f"{written} new ({unlabelled} unlabelled), {skipped} already exported")


if __name__ == "__main__":
    main()
