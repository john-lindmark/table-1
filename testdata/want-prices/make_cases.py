#!/usr/bin/env python3
"""Shared rules for want prices (contract/want-prices-2026-10-26.md), and the cases every client checks against.

    python3 testdata/want-prices/make_cases.py   # writes cases.json next to this file

- money(v): "$1.40" (two decimals, half up).
- trend(now, then, days): the change from `then` (the oldest price of the last 7 days, `days` ago) to `now`, as
  {dir, text}: dir "up" / "down" / "flat"; text "▲ 8% this week", "▼ 3% in 2 days", "▼ 3% since yesterday",
  "Flat this week". Flat when it moved under 5 cents or rounds to 0%. None without both prices.
- detail(which, max, now, any): a Wanted row's detail: which printing · Max $X · Now $Y (From $Y for any
  printing). The trend goes on a line of its own under it.

Prices are whole cents: clients work in integer cents (round(v * 100)) so a half percent rounds the same everywhere:
pct = (|Δ¢| * 200 + then¢) // (2 * then¢).
"""
import json
import os
from decimal import Decimal, ROUND_HALF_UP

UP, DOWN = "▲", "▼"


def money(v):
    return "$" + str(Decimal(str(v)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def period(days):
    if days >= 7:
        return "this week"
    if days == 1:
        return "since yesterday"
    return f"in {days} days"


def trend(now, then, days):
    if now is None or then is None or days is None or days < 1 or then <= 0:
        return None
    diff = Decimal(str(now)) - Decimal(str(then))
    pct = int((abs(diff) / Decimal(str(then)) * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    if abs(diff) < Decimal("0.05") or pct == 0:
        return {"dir": "flat", "text": f"Flat {period(days)}"}
    if diff > 0:
        return {"dir": "up", "text": f"{UP} {pct}% {period(days)}"}
    return {"dir": "down", "text": f"{DOWN} {pct}% {period(days)}"}


def detail(which, max_usd, now, any_printing):
    parts = [which]
    if max_usd is not None:
        parts.append(f"Max {money(max_usd)}")
    if now is not None:
        parts.append(f"{'From' if any_printing else 'Now'} {money(now)}")
    return " · ".join(p for p in parts if p)


def main():
    trends = []
    for now, then, days in [
        (12.40, 13.50, 7), (13.50, 12.40, 7), (1.40, 1.80, 7), (0.22, 0.20, 7),   # 10% but 2 cents: flat
        (8.00, 8.02, 7), (10.00, 10.04, 3), (2.10, 2.00, 1), (2.00, 2.10, 2), (100.0, 100.4, 7),
        (0.50, 0.40, 5), (7.50, 10.00, 7), (2.05, 2.00, 7), (2.00, 2.05, 7), (None, 2.0, 7), (2.0, None, None), (2.0, 0, 7), (3.0, 2.0, 0),
    ]:
        trends.append({"now": now, "then": then, "days": days, "want": trend(now, then, days)})
    details = []
    for which, mx, now, anyp in [
        ("Any printing", None, 1.40, True),
        ("M10 · Foil", 10, 12.4, False),
        ("XLN", None, None, False),
        ("Any printing", 1.5, 1.4, True),
        ("MH2", None, 8, False),
    ]:
        details.append({"which": which, "max": mx, "now": now, "any": anyp, "want": detail(which, mx, now, anyp)})
    money_cases = [{"v": v, "want": money(v)} for v in [1.4, 0, 12, 0.07, 1234.5]]
    out = {"money": money_cases, "trend": trends, "detail": details}
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases.json"), "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
