# Reference for the Insights chart maths every client implements (InsightCharts.swift, insightCharts.ts,
# InsightCharts.kt; contract/insights-2026-10-24.md). Change this first, run it, then the clients.
#   python3 -I testdata/insight-charts/make_cases.py   → cases.json next to it
import json, math, os
from datetime import date, timedelta

def nice_step(raw):
    """1, 2, 2.5 or 5 × a power of ten, the smallest at least raw."""
    if raw <= 0: return 1.0
    e = math.floor(math.log10(raw)); base = 10 ** e
    for m in (1, 2, 2.5, 5, 10):
        if m * base >= raw - 1e-12: return round(m * base, 12)

def ticks(lo, hi, count):
    """Evenly spaced round values covering [lo, hi] with about `count` intervals; lo == hi widens to a step."""
    if hi < lo: lo, hi = hi, lo
    if hi == lo: hi = lo + (abs(lo) * 0.1 or 1)
    step = nice_step((hi - lo) / max(1, count))
    start = math.floor(lo / step + 1e-9) * step; end = math.ceil(hi / step - 1e-9) * step
    n = int(round((end - start) / step))
    return [round(start + i * step, 10) for i in range(n + 1)]

def segments(values):
    """Runs of non-null values as [index, value] pairs; a null breaks the line."""
    out, cur = [], []
    for i, v in enumerate(values):
        if v is None:
            if cur: out.append(cur); cur = []
        else: cur.append([i, v])
    if cur: out.append(cur)
    return out

def wilson(wins, n, z=1.6449):
    """90% Wilson interval for a win rate; [0, 1] with no games."""
    if n <= 0: return [0.0, 1.0]
    p = wins / n; d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d; h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(max(0.0, c - h), 6), round(min(1.0, c + h), 6)]

def fit(xs, ys):
    """Least-squares line y = a + b·x; null with fewer than two distinct x."""
    n = len(xs)
    if n < 2: return None
    mx = sum(xs) / n; my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0: return None
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return {"a": round(my - b * mx, 8), "b": round(b, 8)}

def spread(ys, gap, lo, hi):
    """End labels at ys (screen y, down is larger) moved apart to at least `gap`, kept inside [lo, hi], in input order."""
    order = sorted(range(len(ys)), key=lambda i: (ys[i], i))
    pos = [0.0] * len(ys); prev = None
    for i in order:
        y = max(ys[i], lo) if prev is None else max(ys[i], prev + gap)
        pos[i] = y; prev = y
    over = (pos[order[-1]] - hi) if order else 0
    if over > 0:
        nxt = None
        for i in reversed(order):
            y = pos[i] - over if nxt is None else min(pos[i], nxt - gap)
            pos[i] = max(lo, y); nxt = pos[i]
    return [round(p, 6) for p in pos]

def pct(x):
    """21% / 3.4% (under 10% keeps one decimal), as the briefs write shares."""
    if x is None: return "–"
    return f"{round(x * 100):.0f}%" if x >= 0.0995 or x == 0 else f"{x * 100:.1f}%"

def pct1(x):
    """57.1%: win rates always keep one decimal."""
    return "–" if x is None else f"{x * 100:.1f}%"

def delta(d):
    """+2.1 / -12 percentage points as a signed label; under 10 keeps one decimal."""
    if d is None: return ""
    v = abs(d * 100)
    s = f"{v:.0f}" if v >= 10 else f"{v:.1f}"
    return ("+" if d >= 0 else "-") + s

def months(start, days):
    """Index and upper-case month name of each month's first day in a daily series starting at `start`."""
    d0 = date.fromisoformat(start); out = []
    for i in range(days):
        d = d0 + timedelta(days=i)
        if d.day == 1: out.append([i, d.strftime("%b").upper()])
    return out

def round_half_even_safe(x): return x

cases = {
    "ticks": [{"in": [lo, hi, c], "out": ticks(lo, hi, c)} for lo, hi, c in [
        (0, 0.27, 4), (0, 0.4286, 4), (0.48, 0.62, 4), (0, 1, 5), (0, 0.05, 4), (0, 0, 4), (0.5, 0.5, 4), (3, 97, 5), (1.2, 13.9, 4), (0.531, 0.577, 3)]],
    "segments": [{"in": v, "out": segments(v)} for v in [[0.1, 0.2, None, 0.3], [None, None], [0.5], [], [None, 0.2, 0.3, None, None, 0.1]]],
    "wilson": [{"in": [w, n], "out": wilson(w, n)} for w, n in [(31, 53), (0, 0), (30, 30), (0, 12), (500, 1000), (17, 40)]],
    "fit": [{"in": [xs, ys], "out": fit(xs, ys)} for xs, ys in [
        ([1, 2, 3, 4], [0.62, 0.60, 0.58, 0.56]), ([2, 2], [0.5, 0.6]), ([1], [0.5]), ([1.5, 3.2, 7.8, 10.1, 12.4], [0.61, 0.58, 0.55, 0.57, 0.52])]],
    "spread": [{"in": [ys, g, lo, hi], "out": spread(ys, g, lo, hi)} for ys, g, lo, hi in [
        ([10, 12, 50], 14, 0, 100), ([95, 96, 97], 10, 0, 100), ([-5, 3], 8, 0, 100), ([40], 14, 0, 100), ([], 14, 0, 100), ([30, 30, 30, 30], 12, 0, 40)]],
    "pct": [{"in": x, "out": pct(x)} for x in [0.214, 0.1, 0.0999, 0.034, 0, 1, 0.005, None]],
    "pct1": [{"in": x, "out": pct1(x)} for x in [0.5714, 0.6, 0.12345, None]],
    "delta": [{"in": d, "out": delta(d)} for d in [0.021, -0.12, 0, -0.004, 0.1, None]],
    "months": [{"in": [s, n], "out": months(s, n)} for s, n in [("2026-04-28", 180), ("2026-10-01", 3), ("2026-02-15", 20)]],
}
json.dump(cases, open(os.path.join(os.path.dirname(__file__), "cases.json"), "w"), indent=1)
print({k: len(v) for k, v in cases.items()})
