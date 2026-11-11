#!/usr/bin/env python3
"""Shared cases for drafts with pods (contract/draft-pods-2026-11-09.md). Run: python3 make_cases.py > cases.json

  plan     pods an organizer's pick makes: pods null = automatic (pods of up to 8), else that many, never a pod under 2
  rounds   automatic Swiss rounds: inside pods, enough for the largest pod; across pods, enough for everyone
  label    how the clients sum up a pick before the draw ("2 pods · 9, 8")
  sections        a round's matches under Pod 1 / Pod 2 / Across pods headers (Live, Earlier, Matchups)
  player_sections a list of players under pod headers, then Not seated (the organizer's Players tab)
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

def auto_label(n, pods, pairing):
    """The Automatic rounds switch's detail for a draft (ScheduledEvents autoLabel otherwise)."""
    if n < 2: return "Auto · set when round 1 is paired"
    sizes = plan(n, pods)
    r = rounds(sizes, pairing)
    rs = f"{r} round{'' if r == 1 else 's'}"
    if pairing == "pod" and len(sizes) > 1: return f"Auto · {rs} for pods of {max(sizes)}"
    return f"Auto · {rs} for {n} players"

def note(sizes, p):
    """Round 1 under pod p (0-based) of a seated draft: the pairs, then what its left-over seat does."""
    plan1 = round1(sizes)
    pod = plan1["pods"][p]
    seat = lambda pid: int(pid.split("S")[1])
    podno = lambda pid: int(pid[1:].split("S")[0])
    pairs = ", ".join(f"{seat(a)} v {seat(b)}" for a, b in pod["pairs"])
    text = f"Round 1 pairs across the table: {pairs}." if pairs else "Round 1 pairs across the table."
    left = pod["left"]
    if left:
        if plan1["bye"] == left: text += f" Seat {seat(left)} has the bye."
        else:
            other = next(b if a == left else a for a, b in plan1["across"] if left in (a, b))
            text += f" Seat {seat(left)} plays Pod {podno(other)}'s seat {seat(other)}."
    return text

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


def sections(pods, players, matches, stage="swiss"):
    """Pod sections for a round's matches (clients' Live round, Earlier and Matchups lists).
    pods: [{id, name}] in display order; players: {participant: pod id or None}; matches: [{id, table, bye, players}].
    None when the round isn't grouped: playoffs, or fewer than two pods hold a player.
    A match sits in the pod all its players share (a bye in its player's pod), else under Across pods.
    Inside a section: tables in order, the bye last. Empty pods are left out; Across pods comes last. A pod with no
    name is "Pod N" by its place among all the event's pods."""
    in_play = {p for p in players.values() if p}
    shown = [(i, p) for i, p in enumerate(pods) if p["id"] in in_play]
    if stage not in (None, "swiss") or len(shown) < 2:
        return None
    def pod_of(m):
        ps = {players.get(x) for x in m["players"] if x}
        return next(iter(ps)) if len(ps) == 1 and None not in ps else None
    def order(ms):
        return [m["id"] for m in sorted(ms, key=lambda m: (m["bye"], m["table"] if m["table"] is not None else 0))]
    out = []
    for i, p in shown:
        ms = [m for m in matches if pod_of(m) == p["id"]]
        if ms: out.append({"pod": p["id"], "title": p["name"] or f"Pod {i + 1}", "matches": order(ms)})
    across = [m for m in matches if pod_of(m) is None]
    if across: out.append({"pod": None, "title": "Across pods", "matches": order(across)})
    return out

def player_sections(pods, players):
    """Pod sections for a list of players (the organizer's Players tab). players: [{id, pod, seat}] in list order.
    None with fewer than two pods holding a player. Pods in display order, seats in order (no seat last, list order
    kept), then Not seated for players without a pod."""
    in_play = {p["pod"] for p in players if p["pod"]}
    shown = [(i, p) for i, p in enumerate(pods) if p["id"] in in_play]
    if len(shown) < 2:
        return None
    out = []
    for i, p in shown:
        mine = [x for x in players if x["pod"] == p["id"]]
        mine = sorted(mine, key=lambda x: (x["seat"] is None, x["seat"] or 0))
        out.append({"pod": p["id"], "title": p["name"] or f"Pod {i + 1}", "players": [x["id"] for x in mine]})
    rest = [x["id"] for x in players if not x["pod"]]
    if rest: out.append({"pod": None, "title": "Not seated", "players": rest})
    return out

TWO = [{"id": "A", "name": "Pod 1"}, {"id": "B", "name": "Pod 2"}]
THREE = TWO + [{"id": "C", "name": None}]
def m(id, table, *ps, bye=False): return {"id": id, "table": table, "bye": bye, "players": list(ps)}
SECTION_CASES = [
    # One pod: never grouped.
    {"pods": TWO, "players": {"a1": "A", "a2": "A"}, "matches": [m("m1", 1, "a1", "a2")]},
    # Round 1 of 7 + 7: pod tables, across-pod left-overs, no bye.
    {"pods": TWO, "players": {"a1": "A", "a2": "A", "a3": "A", "b1": "B", "b2": "B", "b3": "B"},
     "matches": [m("m3", 3, "a3", "b3"), m("m2", 2, "b1", "b2"), m("m1", 1, "a1", "a2")]},
    # Odd event: the bye sits in its player's pod, after the tables.
    {"pods": TWO, "players": {"a1": "A", "a2": "A", "a3": "A", "b1": "B", "b2": "B"},
     "matches": [m("bye", None, "a3", bye=True), m("m2", 2, "b1", "b2"), m("m1", 1, "a1", "a2")]},
    # Across pods rounds 2+: mostly across, kept in table order.
    {"pods": TWO, "players": {"a1": "A", "a2": "A", "b1": "B", "b2": "B"},
     "matches": [m("m2", 2, "b1", "a2"), m("m1", 1, "a1", "b2")]},
    # Third pod without a name, an empty pod, a player with no pod.
    {"pods": THREE + [{"id": "D", "name": "Pod 4"}], "players": {"a1": "A", "a2": "A", "c1": "C", "c2": "C", "x": None, "b1": "B"},
     "matches": [m("m1", 1, "a1", "a2"), m("m2", 2, "c1", "c2"), m("m3", 3, "x", "b1")]},
    # Playoffs: never grouped.
    {"pods": TWO, "players": {"a1": "A", "b1": "B"}, "matches": [m("m1", 1, "a1", "b1")], "stage": "final"},
]
PLAYER_CASES = [
    {"pods": TWO, "players": [{"id": "a1", "pod": "A", "seat": 1}]},
    {"pods": TWO, "players": [{"id": "b2", "pod": "B", "seat": 2}, {"id": "a2", "pod": "A", "seat": 2},
                              {"id": "late", "pod": None, "seat": None}, {"id": "a1", "pod": "A", "seat": 1},
                              {"id": "b1", "pod": "B", "seat": 1}]},
    {"pods": THREE, "players": [{"id": "c1", "pod": "C", "seat": None}, {"id": "a1", "pod": "A", "seat": 1}]},
]

picks = [None, 1, 2, 3, 4, 6, 16]
players = [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 12, 14, 15, 16, 17, 23, 24, 25, 31, 33, 48, 64, 65, 129]
out = {
    "plan": [{"players": n, "pods": p, "want": plan(n, p)} for n in players for p in picks],
    "rounds": [{"sizes": s, "pod_pairing": pp, "want": rounds(s, pp)}
               for s in [[], [8], [8, 8], [7, 7], [6, 6, 5], [9, 8], [5, 4, 4, 4], [17], [8, 8, 8, 8], [1], [3, 2], [16, 16], [10, 1]]
               for pp in ["pod", "cross"]],
    "label": [{"players": n, "pods": p, "want": label(n, p)} for n in [0, 1, 6, 9, 14, 17, 24] for p in [None, 1, 2, 3]],
    "auto_label": [{"players": n, "pods": p, "pod_pairing": pp, "want": auto_label(n, p, pp)}
                   for n in [0, 1, 2, 8, 9, 16, 17, 24] for p in [None, 1, 2] for pp in ["pod", "cross"]],
    "note": [{"sizes": s, "pod": i, "want": note(s, i)} for s in [[8], [7], [7, 7], [7, 7, 7], [6, 6, 5], [9, 8], [1], [2, 1]] for i in range(len(s))],
    "round1": [{"sizes": s, "want": round1(s)} for s in [[8], [7], [8, 8], [7, 7], [7, 7, 7], [6, 6, 5], [5, 5, 5, 5], [3], [1], [2, 1], [9, 8]]],
    "sections": [{**c, "stage": c.get("stage", "swiss"),
                  "want": sections(c["pods"], c["players"], c["matches"], c.get("stage", "swiss"))} for c in SECTION_CASES],
    "player_sections": [{**c, "want": player_sections(c["pods"], c["players"])} for c in PLAYER_CASES],
}
print(json.dumps(out, indent=1))
