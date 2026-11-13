#!/usr/bin/env python3
"""Reference implementation of cube rankings (contract/cube-rankings-2026-10-21.md), written independently of the
three clients. It writes cases.json, which the iOS (CubeRankingTests), web (cubeRanking.test.ts) and Android
(CubeRankingTest) suites all read, so the same log gives the same screens, lists and comparisons on every platform.

    python3 -I testdata/cube-ranking/make_cases.py      # rewrites testdata/cube-ranking/cases.json

The engine is pure: everything comes from the ranking's screen log, so undo, redo and watching never need repair.
- A screen is 2-4 cards in the order the ranker put them, best first. Every pair on it is "known": a beats b.
- Knowledge is the transitive closure of every screen's pairs, applied in log order. A pair that contradicts what is
  already known is skipped (only possible when two devices race). It covers the cube's cards and every card in the log,
  so a card that left the cube still carries what it settled (A above X above B keeps A above B); jobs and lists only
  ever hold the cube's cards.
- Cards added to the cube after the ranking last caught up ("new", the cube's cards less its baseline) wait outside the
  lists until they're placed: a job's list is worked out without the new cards it hasn't placed yet, so adding a card
  never empties a sorted list; the next screens place them (mostly placement screens against the sorted run). A list
  with nothing placed yet has nothing to keep: there, new cards are just part of what's left to sort.
- A job (a color's sort, or the final top N across every card) places cards from the top: the next place goes to the
  card known to beat every other card that can still make the list. A card with `target` or more cards known above it
  can't make the list and is left out ("below the top N").
- The next screen shows the cards nothing left is known to beat (fewest known below first, then a seeded hash), filled
  to four with cards whose order against the screen is still unknown, nearest the top first. No two cards on a screen
  ever have a known order, so a screen can't contradict earlier ones. In the final, cards from colors not already on the
  screen come first. When only two cards qualify, the screen is a placement: one free card against up to three
  cards whose order is known, locked (see placement()).
- The final checks before it places (2026-11-07, tightened 2026-11-13, see Support and checked()): a card is placed once
  its order against each other color's best card not yet placed (in the running or not) was asked on a screen, or is
  backed by two chains of screens that share no card, and against its own color's next card on a final screen. Until
  then the next screen is that check, and its answer wins: final screens apply newest first (apply_order). The list
  shows every settled place; `checked` counts the checked ones and `done` waits for them.
"""
import json
import math
from pathlib import Path

M = 0xFFFFFFFF
SESSIONS = ["W", "U", "B", "R", "G", "M", "C", "L"]  # White, Blue, Black, Red, Green, Multicolor, Colorless, Lands
FINAL = "F"
PICK = "P"     # a P1P1 pick: o[0] was picked from a pack of the rest (beats each of them; no order among the rest)
PACK = 15
LOG2_24 = math.log2(24)
# The rules this engine implements, by the date they changed (2026-11-13: the final's checks reach cards out of the
# running and want two chains). Every engine carries the same value and its tests check it against cases.json; the apps
# compare theirs with the downloaded engine's manifest to know when the file has newer rules (see rankEngine.ts).
RULES = "2026-11-13"


def fnv1a(s):
    h = 0x811C9DC5
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 0x01000193) & M
    return h


def bits(m):
    i = 0
    while m:
        if m & 1:
            yield i
        m >>= 1
        i += 1


def pop(m):
    return bin(m).count("1")


class Knowledge:
    """The log as a transitive "beats" relation over the cube's cards (indexed by sorted Oracle id)."""

    def __init__(self, cards, screens):
        self.ids = sorted(set(cards) | {c for sc in screens for c in sc["o"]})
        self.idx = {c: i for i, c in enumerate(self.ids)}
        n = len(self.ids)
        self.log = list(screens)
        self.beats = [0] * n   # beats[x]: cards x is known to beat
        self.below = [0] * n   # below[x]: cards known to beat x
        self.per_session = {}
        self.contradicted = {}  # screen index -> [(winner, loser)] pairs skipped because the opposite was known
        self.screens = len(screens)
        for sc in screens:
            self.per_session[sc["s"]] = self.per_session.get(sc["s"], 0) + 1
        for k in apply_order(screens):
            skipped = [(w, l) for w, l in pairs(self, screens[k]) if not self.add(w, l)]
            if skipped:
                self.contradicted[k] = skipped

    def add(self, a, b):
        """Learns a beats b; False when the opposite was already known (the pair is skipped)."""
        if self.beats[b] >> a & 1:
            return False
        if self.beats[a] >> b & 1:
            return True
        ups = self.below[a] | 1 << a
        downs = self.beats[b] | 1 << b
        for x in bits(ups):
            self.beats[x] |= downs
        for y in bits(downs):
            self.below[y] |= ups
        return True

    def known(self, a, b):
        return bool(self.beats[a] >> b & 1)


def apply_order(screens):
    """The order screens are applied in (2026-11-07): final screens newest first, then the colors' screens, then picks,
    each in log order. Without a contradiction the order changes nothing (the closure is the same). With one, a newer
    final screen wins over an older one and over a color's sort: the final's checks (see checked()) can correct an
    order the colors or a detour settled. Picks stay last, so "Keep my ranking" still skips a pick's disagreeing pairs."""
    finals = [k for k in range(len(screens) - 1, -1, -1) if screens[k]["s"] == FINAL]
    colors = [k for k, sc in enumerate(screens) if sc["s"] not in (FINAL, PICK)]
    picks = [k for k, sc in enumerate(screens) if sc["s"] == PICK]
    return finals + colors + picks


def indexes(K, cards):
    xs = []
    for c in cards:
        i = K.idx.get(c)
        if i is not None and i not in xs:
            xs.append(i)
    return xs


def pairs(K, sc):
    """What a screen says, as (winner, loser) index pairs: every pair in order, or for a pick the picked card over
    each other card in its pack."""
    xs = indexes(K, sc["o"])
    if sc["s"] == PICK:
        return [(xs[0], y) for y in xs[1:]] if xs else []
    return [(xs[i], xs[j]) for i in range(len(xs)) for j in range(i + 1, len(xs))]


def ranked(K, U, T):
    """Places from the top: the next place goes to the card in U known to beat every other card in U."""
    top = []
    while len(top) < T:
        found = None
        for x in bits(U):
            if (U & ~(1 << x)) & ~K.beats[x] == 0:
                found = x
                break
        if found is None:
            break
        top.append(found)
        U &= ~(1 << found)
    return top, U


def chains(won, x, y, limit=2):
    """How many chains of screens that share no card lead from x down to y, at most `limit` (2026-11-13): vertex-disjoint
    paths in the graph of screen wins (won[a]: the cards a beat on a screen and still beats), found by augmenting paths
    over split vertices (in(v) = 2v, out(v) = 2v + 1), breadth first, cards in index order."""
    used_v, used_e = set(), set()  # vertices and (a, b) edges carrying a chain; x and y never count as vertices
    flow = 0
    while flow < limit:
        start, goal = 2 * x + 1, 2 * y
        prev = {start: None}
        queue, found = [start], False
        for st in queue:
            v, out = st >> 1, st & 1
            nxt = []
            if out:
                nxt += [2 * b for b in bits(won[v]) if (v, b) not in used_e]
                if v in used_v and v != x:
                    nxt.append(2 * v)
            else:
                if v != y and v not in used_v:
                    nxt.append(2 * v + 1)
                nxt += [2 * a + 1 for a, b in sorted(used_e) if b == v]
            for t in nxt:
                if t not in prev:
                    prev[t] = st
                    queue.append(t)
                    if t == goal:
                        found = True
                        break
            if found:
                break
        if not found:
            break
        t = goal
        while prev[t] is not None:
            f = prev[t]
            fv, tv = f >> 1, t >> 1
            if f & 1 and not t & 1:      # out(fv) -> in(tv): through an edge, or back across a used vertex
                if fv == tv:
                    used_v.discard(fv)
                else:
                    used_e.add((fv, tv))
            elif not f & 1 and t & 1:    # in(fv) -> out(tv): across a vertex, or back along a used edge
                if fv == tv:
                    used_v.add(fv)
                else:
                    used_e.discard((tv, fv))
            t = f
        flow += 1
    return flow


class Support:
    """What the final needs before it places a card (2026-11-07): which orders a screen asked about directly. Built from
    the log: `met[x]` the cards x was ordered against on any screen (a pick: the picked card and the rest), `met_final[x]`
    on a final screen, `won[x]` the cards x beat on a screen (and still beats); `sorted` the same-color order the color's
    own screens set."""

    def __init__(self, K, groups):
        n = len(K.ids)
        self.groups = groups
        self.met, self.met_final, self.won = [0] * n, [0] * n, [0] * n
        self.sorted = Knowledge([], [])
        self.sorted.ids, self.sorted.idx, self.sorted.beats, self.sorted.below = K.ids, K.idx, [0] * n, [0] * n
        for sc in K.log:
            for w, l in pairs(K, sc):
                self.met[w] |= 1 << l
                self.met[l] |= 1 << w
                if sc["s"] == FINAL:
                    self.met_final[w] |= 1 << l
                    self.met_final[l] |= 1 << w
                if K.known(w, l):
                    self.won[w] |= 1 << l
                    if groups[w] == groups[l] and sc["s"] not in (FINAL, PICK):
                        self.sorted.add(w, l)

    def unchecked(self, K, x, P):
        """x is known to beat every other card still in the running. P is the final's cards not placed yet, in the
        running or not (2026-11-13: in Daniel Shea's Lindmark Cube top 50 every white, red and green card had been
        pushed out of the running by answers nothing checked, so places 35-46 were twelve black cards checked only
        against each other). The cards x still needs a screen with, one per color at most: each other color's best card
        in P (fewest known above it in P, then index) unless x met it on a screen or two chains of screens that share no
        card put x above it (one chain is one answer away from wrong: Duress over Wheel of Fortune carried the twelve
        black cards, all through Urza's Saga over Path to Exile); and x's own color's best card when only the color's own
        screens put x above it (a color sorted wrong holds its better cards back, then lets them out in a run)."""
        rest = P & ~(1 << x)
        best = {}
        for y in bits(rest):
            g = self.groups[y]
            k = (pop(K.below[y] & P), y)
            if g not in best or k < best[g][0]:
                best[g] = (k, y)
        miss = 0
        for g, (_, y) in best.items():
            if g == self.groups[x]:
                if self.sorted.known(x, y) and not self.met_final[x] >> y & 1:
                    miss |= 1 << y
            elif not self.met[x] >> y & 1 and chains(self.won, x, y) < 2:
                miss |= 1 << y
        return miss


def checked(K, U, P, T, sup):
    """ranked() for the final: a card known to beat every other card still in (U) is placed only once its order against
    the cards not yet placed (P) has been checked (Support.unchecked). Returns (places, what's left in the running,
    what's left unplaced, (the card, its unchecked cards) or None)."""
    top = []
    while len(top) < T:
        found = None
        for x in bits(U):
            if (U & ~(1 << x)) & ~K.beats[x] == 0:
                found = x
                break
        if found is None:
            break
        miss = sup.unchecked(K, found, P)
        if miss:
            return top, U, P, (found, miss)
        top.append(found)
        U &= ~(1 << found)
        P &= ~(1 << found)
    return top, U, P, None


def check_screen(K, P, x, miss, groups, h):
    """The check: x with up to three of the cards it hasn't been checked against: its own color's next card first,
    then other colors' cards nearest the top (fewest known above them among the cards not yet placed), one per color
    first. Nothing is locked: the answer is new and wins."""
    ys = sorted(bits(miss), key=lambda y: (pop(K.below[y] & P), h(y), y))
    picked = [x] + [y for y in ys if groups[y] == groups[x]][:1]
    for y in ys:
        if len(picked) < 4 and y not in picked and groups[y] not in {groups[p] for p in picked}:
            picked.append(y)
    for y in ys:
        if len(picked) < 4 and y not in picked:
            picked.append(y)
    return picked


def session(K, scope, target, seed, groups=None, new=0):
    """One job: scope is a bitmask of card indexes; groups maps a card index to its color (final only); new is the
    cube's new cards (bitmask). The list (`top`) leaves out new cards still waiting to be placed (`waiting`); the
    screens and `done` count every card. The final's list shows every place the log settles, but it's done only once
    `checked` reaches the target: places are checked from the top (checked()), and until the next one is, the next
    screen is its check (`check`)."""
    n = pop(scope)
    T = min(target, n)
    live = 0
    for x in bits(scope):
        if pop(K.below[x] & scope) < T:
            live |= 1 << x
    top, U = ranked(K, live, T)
    sure, stuck = len(top), None
    if groups is not None:
        good, left, unplaced, stuck = checked(K, live, scope, T, Support(K, groups))
        sure = len(good)
    done = sure >= T
    waiting = [x for x in bits(new & live) if x not in top]
    shown = ranked(K, live & ~new | sum(1 << x for x in bits(new & live) if x in top), T)[0] if waiting else top
    if not shown:  # a list with nothing placed yet: new cards are simply part of what's left to sort
        waiting, shown = [], top
    question, pinned = None, []
    h = lambda x: fnv1a(seed + ":" + K.ids[x])
    if not done and stuck:
        question = check_screen(K, unplaced, stuck[0], stuck[1], groups, h)
    elif not done:
        cands = [x for x in bits(U) if K.below[x] & U == 0]
        cands.sort(key=lambda x: (pop(K.beats[x] & U), h(x), x))
        picked = choose(K, cands, groups, [])
        if len(picked) < 4:
            others = [x for x in bits(U) if x not in cands]
            others.sort(key=lambda x: (pop(K.below[x] & U), pop(K.beats[x] & U), h(x), x))
            picked = choose(K, others, groups, picked)
        question, pinned = picked, []
        if len(picked) == 2:
            question, pinned = placement(K, U, picked[0], picked[1], h)
    return {"top": shown, "done": done, "target": T, "size": n, "question": question, "pinned": pinned, "open": U,
            "waiting": waiting, "check": bool(stuck) and not done, "checked": sure}


def placement(K, U, a, b, h):
    """Only two cards qualify: usually one unsettled card against a run whose order is known. Show the free card with
    up to three of that run (the leader, the middle and the end of what sits below it), locked in their known order;
    only the free card moves. Returns (cards in shown order, pinned cards in known order)."""
    best = None
    for lead, free in ((a, b), (b, a)):
        below = [c for c in bits(U) if K.known(lead, c) and not K.known(free, c) and not K.known(c, free)]
        below.sort(key=lambda c: (pop(K.below[c] & U), h(c), c))
        chain = [lead]
        for c in below:
            if K.known(chain[-1], c):
                chain.append(c)
        if best is None or len(chain) > len(best[0]):
            best = (chain, free)
    chain, free = best
    if len(chain) == 1:
        return [a, b], []
    if len(chain) > 3:
        rest = chain[1:]
        chain = [chain[0], rest[(len(rest) - 1) // 2], rest[-1]]
    return chain + [free], chain


def choose(K, order, groups, picked):
    picked = list(picked)

    def ok(x):
        return x not in picked and all(not K.known(x, y) and not K.known(y, x) for y in picked)

    if groups is not None:
        for x in order:
            if len(picked) == 4:
                break
            if ok(x) and groups[x] not in {groups[y] for y in picked}:
                picked.append(x)
    for x in order:
        if len(picked) == 4:
            break
        if ok(x):
            picked.append(x)
    return picked


def reask_open(K, st, cards):
    """A redone screen's cards come back first while each can still make the list and their order is open."""
    xs = [K.idx.get(c) for c in cards]
    if any(x is None for x in xs) or len(xs) < 2:
        return False
    for x in xs:
        if not st["open"] >> x & 1:
            return False
    for i in range(len(xs)):
        for j in range(i + 1, len(xs)):
            if K.known(xs[i], xs[j]) or K.known(xs[j], xs[i]):
                return False
    return True


# ---- the whole ranking ----

def scope_of(K, cats, key):
    """The job's cards: the cube's (cats holds only the cube's cards), in one color or (final) all of them."""
    m = 0
    for i, c in enumerate(K.ids):
        if c in cats and (key == FINAL or cats[c] == key):
            m |= 1 << i
    return m


def new_of(K, new_cards):
    m = 0
    for c in new_cards:
        if c in K.idx:
            m |= 1 << K.idx[c]
    return m


# How much of each color a ranking sorts (2026-10-23: "third" and "quarter" added; the final top N still comes out exact,
# it just asks about a card itself when a color has more cards in the top N than it sorted).
DEPTHS = {"half": 2, "third": 3, "quarter": 4}


def target_of(K, cats, key, depth, top_size):
    if key == FINAL:
        return top_size
    n = pop(scope_of(K, cats, key))
    return n if depth == "full" else -(-n // DEPTHS.get(depth, 2))


def seed_of(ranking_id, key, K):
    return f"{ranking_id}:{key}:{K.screens}"


def state(K, cats, ranking_id, key, depth, top_size, new_cards=()):
    groups = None
    if key == FINAL:
        groups = [SESSIONS.index(cats.get(c, "C")) for c in K.ids]
    return session(K, scope_of(K, cats, key), target_of(K, cats, key, depth, top_size),
                   seed_of(ranking_id, key, K), groups, new_of(K, new_cards))


# ---- estimates ----

def expected_sort(n, k):
    k = min(k, n)
    if n <= 1 or k <= 0:
        return 0
    b = 0.0
    for i in range(n - k + 1, n + 1):
        b += math.log2(i)
    f = 1.55 if k >= n - 1 else 1.66  # simulated with this engine: a full sort, the top half
    return math.ceil(f * b / LOG2_24)


def expected_merge(sizes, top):
    T = min(top, sum(sizes))
    if T <= 0 or len([s for s in sizes if s > 0]) <= 1:
        return 0
    C = [[1.0]]
    for t in range(1, T + 1):
        row = [1.0] * (t + 1)
        for k in range(1, t):
            row[k] = C[t - 1][k - 1] + C[t - 1][k]
        C.append(row)
    f = [1.0] + [0.0] * T
    for s in sizes:
        g = [0.0] * (T + 1)
        for t in range(T + 1):
            for k in range(0, min(s, t) + 1):
                g[t] += f[t - k] * C[t][k]
        f = g
    return math.ceil(6.0 * math.log2(f[T]) / LOG2_24)  # 1.78 before the final's checks (2026-11-07), 4.9 before 2026-11-13


# ---- explaining a place ----

def why(K, screens, hi, lo):
    """Shortest chain of screens that put hi above lo: [(winner, loser, screen number from 1)], or None."""
    a, b = K.idx.get(hi), K.idx.get(lo)
    if a is None or b is None or a == b or not K.known(a, b):
        return None
    first = {}
    for k, sc in enumerate(screens):
        for w, l in pairs(K, sc):
            if K.known(w, l) and (w, l) not in first:
                first[(w, l)] = k
    adj = {}
    for (w, l), k in first.items():
        adj.setdefault(w, []).append((k, l))
    for w in adj:
        adj[w].sort()
    prev = {a: None}
    queue = [a]
    while queue:
        nxt = []
        for x in queue:
            for k, y in adj.get(x, []):
                if y not in prev:
                    prev[y] = (x, k)
                    nxt.append(y)
        if b in prev:
            break
        queue = nxt
    if b not in prev:
        return None
    chain, y = [], b
    while prev[y] is not None:
        x, k = prev[y]
        chain.append([K.ids[x], K.ids[y], k + 1])
        y = x
    return chain[::-1]


# ---- P1P1 picks ----

def pack(ranking_id, K):
    """The next pack: up to 15 of the cube's cards, by a hash of the ranking, the number of picks so far and the card."""
    n = K.per_session.get(PICK, 0)
    order = sorted(range(len(K.ids)), key=lambda x: (fnv1a(f"{ranking_id}:{PICK}:{n}:{K.ids[x]}"), x))
    return [K.ids[x] for x in order[:PACK]]


def disagreements(K, picked, pack_ids):
    """Cards in the pack the ranking already puts above the picked card (pack order)."""
    p = K.idx.get(picked)
    if p is None:
        return []
    return [c for c in pack_ids if c != picked and K.idx.get(c) is not None and K.known(K.idx[c], p)]


def pick_wins(cards, log, picked, pack_ids):
    """"Let the pick win": while the ranking puts a pack card above the picked one, take out the newest screen of the
    shortest chain that says so (at most 30). Returns the indexes removed from `log`, ascending."""
    alive = list(range(len(log)))
    removed = []
    for _ in range(30):
        cur = [log[i] for i in alive]
        K = Knowledge(cards, cur)
        ds = disagreements(K, picked, pack_ids)
        if not ds:
            break
        chain = why(K, cur, ds[0], picked)
        k = max(link[2] for link in chain) - 1
        removed.append(alive.pop(k))
    return sorted(removed)


# ---- the change log ----

def places(K, cats, ranking_id, depth, top_size, new_cards=()):
    out = {}
    for key in SESSIONS + [FINAL]:
        if pop(scope_of(K, cats, key)) == 0:
            continue
        st = state(K, cats, ranking_id, key, depth, top_size, new_cards)
        out[key] = {K.ids[x]: i + 1 for i, x in enumerate(st["top"])}
    return out


def changes(before, after):
    """What moved between two states' places: [job, card, from, to] (None = not placed), colors then the final, each by
    the better of its places then card id."""
    out = []
    for key in SESSIONS + [FINAL]:
        a, b = before.get(key, {}), after.get(key, {})
        rows = [(c, a.get(c), b.get(c)) for c in set(a) | set(b) if a.get(c) != b.get(c)]
        rows.sort(key=lambda r: (min(x for x in (r[1], r[2]) if x is not None), r[0]))
        out += [[key, c, f, t] for c, f, t in rows]
    return out


# ---- comparing two rankings ----

def compare(K, st_a, st_b, scope):
    def place(st, x):
        if x in st["top"]:
            return st["top"].index(x) + 1, False
        if st["done"] and len(st["top"]) < st["size"]:
            return len(st["top"]) + 1, True
        return None

    rows = []
    for x in bits(scope):
        pa, pb = place(st_a, x), place(st_b, x)
        if pa is None or pb is None or (pa[1] and pb[1]):
            continue
        gap = abs(pa[0] - pb[0])
        best = min(p for p, out in (pa, pb) if not out)
        rows.append({"x": x, "a": pa, "b": pb, "gap": gap, "atLeast": pa[1] or pb[1], "best": best})
    n = len(rows)
    total = sum(r["gap"] for r in rows)
    avg_tenths = (20 * total + n) // (2 * n) if n else 0
    biggest = sorted(rows, key=lambda r: (-r["gap"], r["best"], r["x"]))[:10]
    one_side = sorted([r for r in rows if r["a"][1] != r["b"][1]], key=lambda r: (r["best"], r["x"]))

    def out(r):
        return [K.ids[r["x"]], r["a"][0], r["a"][1], r["b"][0], r["b"][1], r["gap"], r["atLeast"]]

    return {"compared": n, "avgTenths": avg_tenths, "atLeast": any(r["atLeast"] for r in rows),
            "biggest": [out(r) for r in biggest], "oneSide": [out(r) for r in one_side]}


# ---- cases ----

def card_id(i):
    h = fnv1a(f"card{i}")
    g = fnv1a(f"oracle{i}")
    return f"{h:08x}-{g >> 16:04x}-4{g & 0xFFF:03x}-8{i:03x}-{(h * 7919 + g) & 0xFFFFFFFFFFFF:012x}"


def make_cube():
    counts = {"W": 7, "U": 8, "B": 6, "R": 5, "G": 4, "M": 6, "C": 3, "L": 9}
    cards, cats, i = [], {}, 0
    for key in SESSIONS:
        for _ in range(counts[key]):
            c = card_id(i)
            cards.append(c)
            cats[c] = key
            i += 1
    return cards, cats


def truth(cards, salt):
    return sorted(cards, key=lambda c: fnv1a(salt + c))


def simulate(ranking_id, cards, cats, depth, top_size, order_of_jobs, true_order, stop_after=None, final_order=None):
    """Answers every screen by true_order (the final's by final_order when given: a ranker who changes their mind, so
    the final's checks overturn what the colors said); records each step for the clients to replay."""
    rank = {c: i for i, c in enumerate(true_order)}
    final_rank = {c: i for i, c in enumerate(final_order or true_order)}
    log, steps = [], []
    for key in order_of_jobs:
        count = 0
        while True:
            K = Knowledge(cards, log)
            st = state(K, cats, ranking_id, key, depth, top_size)
            if st["done"] or (stop_after and key in stop_after and count >= stop_after[key]):
                break
            q = [K.ids[x] for x in st["question"]]
            answer = sorted(q, key=lambda c: (final_rank if key == FINAL else rank)[c])
            steps.append({"s": key, "at": len(log), "question": q, "pinned": [K.ids[x] for x in st["pinned"]],
                          "check": st["check"], "answer": answer})
            log.append({"s": key, "o": answer})
            count += 1
    return log, steps


def summary(K, cats, ranking_id, depth, top_size, new_cards=()):
    out = {}
    for key in SESSIONS + [FINAL]:
        if pop(scope_of(K, cats, key)) == 0:
            continue
        st = state(K, cats, ranking_id, key, depth, top_size, new_cards)
        out[key] = {"top": [K.ids[x] for x in st["top"]], "done": st["done"], "target": st["target"],
                    "waiting": [K.ids[x] for x in st["waiting"]],
                    "size": st["size"], "screens": K.per_session.get(key, 0),
                    "question": [K.ids[x] for x in st["question"]] if st["question"] else None,
                    "pinned": [K.ids[x] for x in st["pinned"]] if st["question"] else None, "check": st["check"],
                    "checked": st["checked"]}
    return out


def main():
    cards, cats = make_cube()
    a_id, b_id = "a1b2c3d4-0000-4000-8000-00000000000a", "a1b2c3d4-0000-4000-8000-00000000000b"
    true_a, true_b = truth(cards, "a:"), truth(cards, "b:")
    top = 20
    # A: top half of each color, then the final.
    log_a, steps_a = simulate(a_id, cards, cats, "half", top, SESSIONS + [FINAL], true_a)
    # B: sorts White and Blue fully, starts the final early (12 screens), then sorts the rest and finishes.
    log_b1, steps_b1 = simulate(b_id, cards, cats, "full", top, ["W", "U", FINAL], true_b, {FINAL: 12})
    rank_b = {c: i for i, c in enumerate(true_b)}
    log_b, steps_b = list(log_b1), list(steps_b1)
    for key in ["B", "R", "G", "M", "C", "L", FINAL]:
        while True:
            K = Knowledge(cards, log_b)
            st = state(K, cats, b_id, key, "full", top)
            if st["done"]:
                break
            q = [K.ids[x] for x in st["question"]]
            ans = sorted(q, key=lambda c: rank_b[c])
            steps_b.append({"s": key, "at": len(log_b), "question": q, "pinned": [K.ids[x] for x in st["pinned"]],
                            "check": st["check"], "answer": ans})
            log_b.append({"s": key, "o": ans})

    # D and E: the top quarter and the top third of each color, then the final (exact either way).
    q_id, t_id = "a1b2c3d4-0000-4000-8000-00000000000d", "a1b2c3d4-0000-4000-8000-00000000000e"
    true_q = truth(cards, "d:")
    log_q, steps_q = simulate(q_id, cards, cats, "quarter", top, SESSIONS + [FINAL], true_q)
    sum_q = summary(Knowledge(cards, log_q), cats, q_id, "quarter", top)
    assert sum_q[FINAL]["top"] == true_q[:top], "a quarter of each color still gives the exact final"
    log_t, steps_t = simulate(t_id, cards, cats, "third", top, SESSIONS + [FINAL], true_q)
    sum_t = summary(Knowledge(cards, log_t), cats, t_id, "third", top)
    assert sum_t[FINAL]["top"] == true_q[:top]

    # G: a ranker whose final disagrees with their colors here and there (cards up to ten places apart swap): the final's
    # checks put those orders right, newest answer first, and the final still ends with the final answers' top N.
    g_id = "a1b2c3d4-0000-4000-8000-00000000000f"
    true_g = truth(cards, "g:")
    shift = {c: i + (fnv1a("shift:" + c) % 11) - 5 for i, c in enumerate(true_g)}
    final_g = sorted(true_g, key=lambda c: (shift[c], c))
    log_g, steps_g = simulate(g_id, cards, cats, "quarter", top, SESSIONS + [FINAL], true_g, final_order=final_g)
    Kg = Knowledge(cards, log_g)
    sum_g = summary(Kg, cats, g_id, "quarter", top)
    assert any(st["check"] for st in steps_g) and Kg.contradicted, "run G overturns orders through checks"
    contradicted_g = {str(k): [[Kg.ids[w], Kg.ids[l]] for w, l in v] for k, v in sorted(Kg.contradicted.items())}

    Ka, Kb = Knowledge(cards, log_a), Knowledge(cards, log_b)
    sum_a = summary(Ka, cats, a_id, "half", top)
    sum_b = summary(Kb, cats, b_id, "full", top)

    comparisons = {}
    for key in SESSIONS + [FINAL]:
        sa = state(Ka, cats, a_id, key, "half", top)
        sb = state(Kb, cats, b_id, key, "full", top)
        comparisons[key] = compare(Ka, sa, sb, scope_of(Ka, cats, key))

    # Why: a few pairs from A's final and colors.
    fa = sum_a[FINAL]["top"]
    wa = sum_a["W"]["top"]
    pairs = [(fa[0], fa[5]), (fa[3], fa[4]), (fa[0], fa[-1]), (wa[0], wa[-1]), (fa[5], fa[0])]
    whys = [{"hi": hi, "lo": lo, "chain": why(Ka, log_a, hi, lo)} for hi, lo in pairs]

    # Redo: take one screen out of A's log; what changes, and is the screen's order still open (asked again first)?
    redos = []
    for i in [0, 3, len(log_a) // 2, len(log_a) - 1]:
        rest = log_a[:i] + log_a[i + 1:]
        K2 = Knowledge(cards, rest)
        key = log_a[i]["s"]
        st = state(K2, cats, a_id, key, "half", top)
        redos.append({"remove": i, "changesNothing": K2.beats == Ka.beats, "session": key,
                      "changes": changes(places(Ka, cats, a_id, "half", top), places(K2, cats, a_id, "half", top)),
                      "reaskOpen": reask_open(K2, st, log_a[i]["o"]),
                      "after": summary(K2, cats, a_id, "half", top)})

    # Edge cases: a contradiction (two devices raced) and a card that left the cube.
    c = cards
    gone = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    edge_log = [{"s": "W", "o": [c[0], c[1], c[2]]}, {"s": "W", "o": [c[2], c[0], gone]},
                {"s": "W", "o": [c[3], gone, c[1]]}, {"s": "W", "o": [c[1], c[3]]}]
    Ke = Knowledge(cards, edge_log)
    edge_known = [[Ke.ids[x], Ke.ids[y]] for x in range(len(Ke.ids)) for y in bits(Ke.beats[x])]
    edge_known.sort()

    sizes = [pop(scope_of(Ka, cats, k)) for k in SESSIONS]
    estimates = {
        "sort": [[n, k, expected_sort(n, k)] for n, k in [(1, 1), (2, 2), (7, 4), (7, 7), (49, 25), (61, 31), (93, 93), (93, 47), (540, 270)]],
        "merge": [[s, t, expected_merge(s, t)] for s, t in [(sizes, 20), ([61, 76, 60, 55, 49, 63, 71, 93], 100),
                                                             ([61, 76, 60, 55, 49, 63, 71, 93], 50), ([30], 20), ([0, 5, 5], 8)]],
    }

    # C: P1P1 picks. Sorts White and Blue, makes 3 picks it agrees with, finishes, then 4 picks by another taste (some
    # disagree with the ranking); then "let the pick win" for one more contrary pick.
    c_id = "a1b2c3d4-0000-4000-8000-00000000000c"
    true_c, contrary = truth(cards, "c:"), truth(cards, "contrary:")
    log_c, steps_c = simulate(c_id, cards, cats, "half", top, ["W", "U"], true_c)

    def picks(n, taste):
        rank = {c: i for i, c in enumerate(taste)}
        for _ in range(n):
            K = Knowledge(cards, log_c)
            pk = pack(c_id, K)
            picked = min(pk, key=lambda c: rank[c])
            answer = [picked] + [c for c in pk if c != picked]
            steps_c.append({"s": PICK, "at": len(log_c), "pack": pk, "answer": answer,
                            "disagree": disagreements(K, picked, pk)})
            log_c.append({"s": PICK, "o": answer})

    picks(3, true_c)
    rank_c = {c: i for i, c in enumerate(true_c)}
    for key in ["B", "R", "G", "M", "C", "L", FINAL]:
        while True:
            K = Knowledge(cards, log_c)
            st = state(K, cats, c_id, key, "half", top)
            if st["done"]:
                break
            q = [K.ids[x] for x in st["question"]]
            ans = sorted(q, key=lambda c: rank_c[c])
            steps_c.append({"s": key, "at": len(log_c), "question": q, "pinned": [K.ids[x] for x in st["pinned"]],
                            "check": st["check"], "answer": ans})
            log_c.append({"s": key, "o": ans})
    picks(4, contrary)
    Kc = Knowledge(cards, log_c)
    sum_c = summary(Kc, cats, c_id, "half", top)
    rank_x = {c: i for i, c in enumerate(contrary)}
    pk = pack(c_id, Kc)
    picked = min(pk, key=lambda c: rank_x[c])
    ds = disagreements(Kc, picked, pk)
    removed = pick_wins(cards, log_c, picked, pk)
    after_log = [sc for i, sc in enumerate(log_c) if i not in removed] + [{"s": PICK, "o": [picked] + [c for c in pk if c != picked]}]
    K_after = Knowledge(cards, after_log)
    win = {"at": len(log_c), "pack": pk, "picked": picked, "disagree": ds, "removed": removed,
           "after": summary(K_after, cats, c_id, "half", top),
           "changes": changes(places(Kc, cats, c_id, "half", top), places(K_after, cats, c_id, "half", top))}
    contradicted = {str(k): [[Kc.ids[w], Kc.ids[l]] for w, l in v] for k, v in Kc.contradicted.items()}

    # D: the cube changes after B finished. Two cards leave (one sat in B's final), three join (White, Lands,
    # Multicolor). Lists keep their order without the removed cards, the new ones wait; then only the new cards (and
    # the final's freed place) are asked, in the order a re-rank goes: colors with new cards, then the final.
    gone = [sum_b["W"]["top"][2], sum_b[FINAL]["top"][4]]
    added = {card_id(900): "W", card_id(901): "L", card_id(902): "M"}
    cards_d = [c for c in cards if c not in gone] + list(added)
    cats_d = {c: k for c, k in cats.items() if c not in gone}
    cats_d.update(added)
    true_d = truth(cards_d, "b:")
    rank_d = {c: i for i, c in enumerate(true_b) if c in cats_d}
    for c in added:
        rank_d[c] = true_d.index(c) * len(true_b) / len(true_d)
    new_d = list(added)
    log_d, steps_d = list(log_b), []
    Kd0 = Knowledge(cards_d, log_d)
    before_d = summary(Kd0, cats_d, b_id, "full", top, new_d)
    for key in [k for k in SESSIONS if before_d.get(k, {}).get("waiting")] + [FINAL]:
        while True:
            K = Knowledge(cards_d, log_d)
            st = state(K, cats_d, b_id, key, "full", top, new_d)
            if st["done"]:
                break
            q = [K.ids[x] for x in st["question"]]
            ans = sorted(q, key=lambda c: rank_d[c])
            steps_d.append({"s": key, "at": len(log_d), "question": q, "pinned": [K.ids[x] for x in st["pinned"]],
                            "check": st["check"], "answer": ans, "waiting": [K.ids[x] for x in st["waiting"]], "top": [K.ids[x] for x in st["top"]]})
            log_d.append({"s": key, "o": ans})
    Kd = Knowledge(cards_d, log_d)
    cube_change = {
        "id": b_id, "depth": "full", "top": top, "removed": gone, "added": added, "new": new_d,
        "before": before_d, "steps": steps_d, "after": summary(Kd, cats_d, b_id, "full", top, new_d),
        "changes": changes(places(Kd0, cats_d, b_id, "full", top, new_d), places(Kd, cats_d, b_id, "full", top, new_d)),
    }

    out = {
        "about": "Cube rankings (contract/cube-rankings-2026-10-21.md). Written by make_cases.py, the reference engine; "
                 "iOS CubeRankingTests, web cubeRanking.test.ts and Android CubeRankingTest read it. Cards are indexed by "
                 "sorted Oracle id. Replay each run's steps: before each step the engine's next screen for that session, "
                 "from the log so far, must equal `question` (same cards, same order); then append `answer`. Estimates may "
                 "differ by 1 (floating point).",
        "rules": RULES,
        "cube": {"cards": cards, "category": cats},
        "runs": [
            {"id": a_id, "depth": "half", "top": top, "steps": steps_a, "summary": sum_a},
            {"id": b_id, "depth": "full", "top": top, "steps": steps_b, "summary": sum_b},
            {"id": c_id, "depth": "half", "top": top, "steps": steps_c, "summary": sum_c, "contradicted": contradicted},
            {"id": q_id, "depth": "quarter", "top": top, "steps": steps_q, "summary": sum_q},
            {"id": t_id, "depth": "third", "top": top, "steps": steps_t, "summary": sum_t},
            {"id": g_id, "depth": "quarter", "top": top, "steps": steps_g, "summary": sum_g, "contradicted": contradicted_g},
        ],
        "pickWins": win,
        "compare": comparisons,
        "why": whys,
        "redo": redos,
        "edge": {"log": edge_log, "known": edge_known},
        "cubeChange": cube_change,
        "estimates": estimates,
    }
    path = Path(__file__).with_name("cases.json")
    path.write_text(json.dumps(out, indent=1) + "\n")
    print(f"wrote {path}: A {len(log_a)} screens, B {len(log_b)} screens, cube change {len(steps_d)} screens")


if __name__ == "__main__":
    main()
