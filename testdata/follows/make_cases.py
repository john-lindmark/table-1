#!/usr/bin/env python3
"""Shared rules for following (contract/follows-2026-10-25.md), and the cases every client checks against.

    python3 testdata/follows/make_cases.py   # writes cases.json next to this file

- ago(seconds): "just now" · "N min ago" · "N h ago" · "N d ago" (under 30 days) · "N mo ago".
- change(added, removed): "+12 −8", "+3", "−2" (a real minus sign), "" for nothing.
- detail(follow, now): a Following row's detail line.
- home(items): the Library home row's detail.
- sections(cards): an update's cards as Added and Taken out, biggest first, then by card id.
"""
import json
import os
from datetime import datetime, timezone

MINUS = "−"


def ago(seconds):
    s = max(0, int(seconds))
    if s < 60:
        return "just now"
    if s < 3600:
        return f"{s // 60} min ago"
    if s < 86400:
        return f"{s // 3600} h ago"
    d = s // 86400
    if d < 30:
        return f"{d} d ago"
    return f"{d // 30} mo ago"


def change(added, removed):
    parts = []
    if added:
        parts.append(f"+{added}")
    if removed:
        parts.append(f"{MINUS}{removed}")
    return " ".join(parts)


def parse(t):
    return datetime.fromisoformat(t.replace("Z", "+00:00"))


def detail(f, now):
    if not f["available"]:
        return "This isn't available"
    u = f.get("last_update")
    if not u:
        return "No changes yet" if f["push"] else "No changes yet · pushes off"
    line = f"{change(u['added'], u['removed'])} · {ago((parse(now) - parse(u['at'])).total_seconds())}"
    return line if f["push"] else f"{line} · pushes off"


def home(items):
    n = len(items)
    updated = sum(1 for f in items if f["available"] and f["unseen"] > 0)
    line = f"{n} followed"
    return f"{line} · {updated} updated" if updated else line


def sections(cards):
    key = lambda r: (-r["qty"], r["card_id"], r["board"] or "")
    added = [{"card_id": c[0], "board": c[1], "qty": c[2]} for c in cards if c[2] > 0]
    removed = [{"card_id": c[0], "board": c[1], "qty": -c[2]} for c in cards if c[2] < 0]
    return {"added": sorted(added, key=key), "removed": sorted(removed, key=key)}


NOW = "2026-10-25T18:00:00Z"
A = "c1000000-0000-0000-0000-000000000001"
B = "c1000000-0000-0000-0000-000000000002"
C = "c1000000-0000-0000-0000-000000000003"


def follow(**kw):
    f = {"kind": "deck", "id": "d1", "available": True, "push": True, "followed_at": "2026-10-01T00:00:00Z", "unseen": 0}
    f.update(kw)
    return f


def update(at, added, removed):
    return {"at": at, "added": added, "removed": removed}


def main():
    ages = [0, 59, 60, 3599, 3600, 86399, 86400, 29 * 86400, 30 * 86400, 400 * 86400, -5]
    changes = [(0, 0), (3, 0), (0, 2), (12, 8)]
    follows = [
        follow(),
        follow(push=False),
        follow(last_update=update("2026-10-25T16:00:00Z", 12, 8)),
        follow(last_update=update("2026-10-25T17:59:30Z", 3, 0)),
        follow(last_update=update("2026-10-20T18:00:00Z", 0, 2), push=False),
        follow(available=False, push=True),
    ]
    homes = [
        [],
        [follow()],
        [follow(unseen=2), follow(unseen=0), follow(available=False)],
        [follow(unseen=1), follow(unseen=3)],
    ]
    cards = [
        [],
        [[A, "main", 2], [B, "side", 1], [C, "main", -1]],
        [[C, None, -3], [A, None, 1], [B, None, -3]],
        [[B, "main", 1], [A, "main", 1], [A, "side", 1]],
    ]
    out = {
        "now": NOW,
        "ago": [{"seconds": s, "text": ago(s)} for s in ages],
        "change": [{"added": a, "removed": r, "text": change(a, r)} for a, r in changes],
        "detail": [{"follow": f, "text": detail(f, NOW)} for f in follows],
        "home": [{"items": items, "text": home(items)} for items in homes],
        "sections": [{"cards": c, **sections(c)} for c in cards],
    }
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases.json")
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
