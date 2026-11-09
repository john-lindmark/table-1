#!/usr/bin/env python3
"""Shared cases for drafts with pods (contract/draft-pods-2026-11-09.md). Run: python3 make_cases.py > cases.json

  plan     pods an organizer's pick makes: pods null = automatic (pods of up to 8), else that many, never a pod under 2
  rounds   automatic Swiss rounds: inside pods, enough for the largest pod; across pods, enough for everyone
  label    how the clients sum up a pick before the draw ("2 pods · 9, 8")
  round1   round 1 across the table in every pod, left-over seats of odd pods against each other, the last a bye
"""
import json, math

def swiss_rounds(n):
    for top, r in [(2, 1), (4, 2), (8, 3), (16, 4), (32, 5), (64, 6), (128, 7), (226, 8), (409, 9)]:
        if n <= top: return r
    return 10

def pod_count(n, pods):
    if n <= 0: return 0
    if pods is None: return math.ceil(n / 8)
    return max(1, min(pods, n // 2))

def plan(n, pods):
    c = pod_count(n, pods)
    if c == 0: return []
    base, extra = divmod(n, c)
    return [base + (1 if i < extra else 0) for i in range(c)]

def rounds(sizes, pairing):
    sizes = [s for s in sizes if s > 0]
    if not sizes: return swiss_rounds(0)
    return swiss_rounds(max(sizes)) if pairing == "pod" else swiss_rounds(sum(sizes))

def label(n, pods):
    sizes = plan(n, pods)
    if not sizes: return "No players yet"
    if len(sizes) == 1: return f"1 pod · {sizes[0]}"
    return f"{len(sizes)} pods · " + ", ".join(str(s) for s in sizes)

def round1(sizes):
    """Seats per pod 1..n; ids 'P<pod>S<seat>' (pods from 1)."""
    pods, left = [], []
    for p, size in enumerate(sizes, 1):
        seats = [f"P{p}S{s}" for s in range(1, size + 1)]
        extra = seats.pop() if len(seats) % 2 else None
        half = len(seats) // 2
        pods.append({"pairs": [[seats[i], seats[i + half]] for i in range(half)], "left": extra})
        if extra: left.append(extra)
    across = [[left[i], left[i + 1]] for i in range(0, len(left) - 1, 2)]
    return {"pods": pods, "across": across, "bye": left[-1] if len(left) % 2 else None}

picks = [None, 1, 2, 3, 4, 6, 16]
players = [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 12, 14, 15, 16, 17, 23, 24, 25, 31, 33, 48, 64, 65, 129]
out = {
    "plan": [{"players": n, "pods": p, "want": plan(n, p)} for n in players for p in picks],
    "rounds": [{"sizes": s, "pod_pairing": pp, "want": rounds(s, pp)}
               for s in [[], [8], [8, 8], [7, 7], [6, 6, 5], [9, 8], [5, 4, 4, 4], [17], [8, 8, 8, 8], [1], [3, 2], [16, 16], [10, 1]]
               for pp in ["pod", "cross"]],
    "label": [{"players": n, "pods": p, "want": label(n, p)} for n in [0, 1, 6, 9, 14, 17, 24] for p in [None, 1, 2, 3]],
    "round1": [{"sizes": s, "want": round1(s)} for s in [[8], [7], [8, 8], [7, 7], [7, 7, 7], [6, 6, 5], [5, 5, 5, 5], [3], [1], [2, 1], [9, 8]]],
}
print(json.dumps(out, indent=1))
