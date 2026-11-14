#!/usr/bin/env python3
"""Reference for the client wording and small rules of finding events, leagues, boards and the TV display
(contract/public-events-leagues-2026-11-13.md). Change the rule here first, run this, then make each client's
implementation pass cases.json: iOS `Leagues.swift`, web `leagues.ts`, Android `Leagues.kt`.

    python3 testdata/leagues/make_cases.py
"""
import json
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

FORMAT_KEYS = [("standard", "Standard"), ("pioneer", "Pioneer"), ("modern", "Modern"), ("legacy", "Legacy"),
               ("vintage", "Vintage"), ("pauper", "Pauper"), ("premodern", "Premodern"),
               ("canadian_highlander", "Canadian Highlander"), ("limited", "Limited"), ("cube", "Cube"), ("other", "Other")]
LABEL = dict(FORMAT_KEYS)

PRESETS = {
    "places": {"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}, {"through": 4, "points": 8},
                          {"through": 8, "points": 6}, {"through": 16, "points": 3}], "participation": 1, "match_win": 0},
    "match_wins": {"places": [], "participation": 1, "match_win": 1},
}


def ordinal(n):
    if 10 <= n % 100 <= 20:
        return f"{n}th"
    return f"{n}{ {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th') }"


def points_words(rule):
    """'1st 12 · 2nd 10 · Top 4 8 · Top 8 6 · Top 16 3 · Others 1'. A bracket one past the last is a single place."""
    parts, last = [], 0
    for b in rule.get("places", []):
        t = b["through"]
        parts.append(f"{ordinal(t) if t == last + 1 else f'Top {t}'} {b['points']}")
        last = t
    if rule.get("participation", 0) > 0:
        parts.append(f"{'Others' if parts else 'Playing'} {rule['participation']}")
    if rule.get("match_win", 0) > 0:
        parts.append(f"Match win {rule['match_win']}")
    return " · ".join(parts)


def place_points(rule, place):
    for b in rule.get("places", []):
        if b["through"] >= place:
            return b["points"]
    return rule.get("participation", 0)


def qualify_words(q):
    winners, top = bool(q.get("winners")), int(q.get("top") or 0)
    if winners and top > 0:
        return f"Event winners and the top {top} on points"
    if winners:
        return "Event winners"
    return f"The top {top} on points" if top > 0 else ""


def row_label(e):
    """The small label above a found event's name."""
    if e.get("league"):
        return e["league"]["name"].upper()
    return "FRIENDS" if e.get("visibility") == "friends" else None


def event_line(e, when):
    """The data line under a found event. `when` is the date piece the client formats in the device's zone."""
    running = e["status"] in ("seated", "in_progress") and e.get("current_round", 0) > 0
    parts = [f"NOW · ROUND {e['current_round']}" if running else when, e["format_label"].upper()]
    if e.get("venue_name"):
        parts.append(e["venue_name"].upper())
    if e.get("capacity"):
        parts.append(f"{e['players']}/{e['capacity']}")
    if e.get("km") is not None:
        parts.append(f"{e['km']} KM")
    return " · ".join(p for p in parts if p)


def when_window(pick, now_iso, zone):
    """[from, to) as UTC instants for a When pick, in the device's zone. Weeks start on Monday."""
    tz = ZoneInfo(zone)
    now = datetime.fromisoformat(now_iso).astimezone(tz)
    day = now.replace(hour=0, minute=0, second=0, microsecond=0)
    next_monday = day + timedelta(days=7 - day.weekday())
    if pick == "today":
        start, end = day, day + timedelta(days=1)
    elif pick == "weekend":
        start, end = (day if day.weekday() >= 5 else day + timedelta(days=5 - day.weekday())), next_monday
    elif pick == "week":
        start, end = day, next_monday
    elif pick == "month":
        start, end = day, (day.replace(day=1) + timedelta(days=32)).replace(day=1)
    else:
        return None
    # Local midnights, re-read in the zone so a clock change inside the window lands on the right instant.
    fix = lambda d: datetime(d.year, d.month, d.day, tzinfo=tz).astimezone(ZoneInfo("UTC")).isoformat().replace("+00:00", "Z")
    return [fix(start), fix(end)]


def filter_labels(f):
    formats = f.get("formats", [])
    more = sum(1 for k in ("team", "league", "open") if f.get(k)) + (1 if f.get("scope", "all") != "all" else 0)
    return {
        "format": "Any format" if not formats else LABEL[formats[0]] if len(formats) == 1 else f"{len(formats)} formats",
        "where": f"{f['km']} km" if f.get("km") else "Everywhere",
        "when": {"today": "Today", "weekend": "This weekend", "week": "This week", "month": "This month"}.get(f.get("when"), "Any time"),
        "more": f"More · {more}" if more else "More",
    }


def board_line(b):
    parts = [f"{b['players']} LISTED"]
    me = b.get("me")
    if me:
        parts.append(f"YOU {me['rating']}")
        parts.append(f"#{me['rank']}" if me.get("rank") else f"{me['to_go']} TO GO" if me.get("to_go", 0) > 0 else "NOT LISTED")
    return " · ".join(parts)


def league_line(c):
    parts = [(c.get("season") or "").upper() or None, (c.get("region") or "").upper() or None,
             f"NEXT {c['next_event']['name'].upper()}" if c.get("next_event") else None]
    return " · ".join(p for p in parts if p)


def display_auto(status, round_number, elapsed, results_in, matches, t):
    """Which view the TV shows on auto. elapsed: seconds into the round; t: seconds the display has been open."""
    if status in ("completed", "archived"):
        return "standings"
    if round_number == 0:
        return "welcome"
    if matches > 0 and results_in >= matches:
        return "standings"
    if elapsed < 300:
        return "pairings"
    if results_in > 0 and t % 120 >= 100:
        return "standings"
    return "clock"


def display_pages(rows, height, row_height, header):
    """How many rows fit a page and how many pages a list takes (at least one row, one page)."""
    per = max(1, int((height - header) // row_height))
    return {"per_page": per, "pages": max(1, -(-rows // per))}


mms = PRESETS["places"]
events = [
    {"name": "Modern Open", "status": "setup", "current_round": 0, "format_label": "Modern", "venue_name": "MeH Games",
     "capacity": None, "players": 12, "km": 19, "visibility": "public", "league": {"name": "The Mountain Magic Series"}},
    {"name": "Friday draft", "status": "setup", "current_round": 0, "format_label": "Draft", "venue_name": None,
     "capacity": 8, "players": 5, "km": None, "visibility": "friends", "league": None},
    {"name": "Legacy Open", "status": "in_progress", "current_round": 3, "format_label": "Legacy", "venue_name": "Mythic Games",
     "capacity": 32, "players": 30, "km": 4, "visibility": "public", "league": None},
    {"name": "Seated draft", "status": "seated", "current_round": 0, "format_label": "Draft", "venue_name": "Level 7",
     "capacity": None, "players": 8, "km": None, "visibility": "public", "league": None},
]
rules = [mms, PRESETS["match_wins"],
         {"places": [{"through": 1, "points": 5}, {"through": 2, "points": 3}, {"through": 3, "points": 2}, {"through": 8, "points": 1}], "participation": 0, "match_win": 2},
         {"places": [{"through": 4, "points": 4}], "participation": 0, "match_win": 0},
         {"places": [{"through": 11, "points": 1}, {"through": 12, "points": 0}, {"through": 13, "points": 0}], "participation": 0, "match_win": 0}]
windows = [("today", "2026-11-13T18:30:00-07:00", "America/Denver"), ("weekend", "2026-11-13T18:30:00-07:00", "America/Denver"),
           ("weekend", "2026-11-14T09:00:00-07:00", "America/Denver"), ("weekend", "2026-11-15T23:30:00-07:00", "America/Denver"),
           ("week", "2026-11-13T18:30:00-07:00", "America/Denver"), ("week", "2026-11-16T00:10:00-07:00", "America/Denver"),
           ("month", "2026-11-13T18:30:00-07:00", "America/Denver"), ("month", "2026-12-31T23:59:00+01:00", "Europe/Stockholm"),
           ("today", "2026-03-29T01:30:00+01:00", "Europe/Stockholm"), ("week", "2026-10-31T12:00:00-06:00", "America/Denver"),
           ("any", "2026-11-13T18:30:00-07:00", "America/Denver")]
filters = [{}, {"formats": ["modern"]}, {"formats": ["modern", "limited", "cube"], "km": 50, "when": "weekend"},
           {"team": True, "open": True}, {"scope": "friends", "league": True, "when": "month"}, {"km": 250, "scope": "all"}]
boards = [{"players": 124, "me": {"rating": 1612, "rank": 14, "to_go": 0}}, {"players": 124, "me": {"rating": 1540, "rank": None, "to_go": 4}},
          {"players": 0, "me": None}, {"players": 9, "me": {"rating": 1580, "rank": None, "to_go": 0}}]
cards = [{"season": "2026", "region": "Denver, Colorado", "next_event": {"name": "Modern Open"}},
         {"season": None, "region": None, "next_event": None}, {"season": "Spring", "region": None, "next_event": {"name": "Week 6"}}]
autos = [("setup", 0, 0, 0, 0, 10), ("in_progress", 1, 60, 0, 8, 10), ("in_progress", 1, 299, 3, 8, 110), ("in_progress", 2, 300, 0, 8, 110),
         ("in_progress", 2, 900, 3, 8, 99), ("in_progress", 2, 900, 3, 8, 100), ("in_progress", 2, 900, 3, 8, 119), ("in_progress", 2, 900, 3, 8, 120),
         ("in_progress", 3, 2000, 8, 8, 30), ("completed", 3, 9000, 8, 8, 30), ("seated", 0, 0, 0, 0, 500)]
pages = [(8, 1080, 72, 240), (64, 1080, 72, 240), (65, 1080, 72, 240), (0, 1080, 72, 240), (200, 720, 60, 180), (5, 200, 72, 240)]

cases = {
    "format_keys": [{"key": k, "label": v} for k, v in FORMAT_KEYS],
    "presets": PRESETS,
    "points_words": [{"rule": r, "want": points_words(r)} for r in rules],
    "place_points": [{"rule": mms, "place": p, "want": place_points(mms, p)} for p in (1, 2, 3, 4, 5, 8, 9, 16, 17, 200)],
    "qualify_words": [{"qualify": q, "want": qualify_words(q)} for q in (
        {"winners": True, "pass_down": True, "top": 10}, {"winners": True, "pass_down": False, "top": 0},
        {"winners": False, "pass_down": True, "top": 8}, {"winners": False, "pass_down": True, "top": 0})],
    "row_label": [{"event": e, "want": row_label(e)} for e in events],
    "event_line": [{"event": e, "when": "SUN 29 MAR · 10:00", "want": event_line(e, "SUN 29 MAR · 10:00")} for e in events]
                  + [{"event": events[1], "when": None, "want": event_line(events[1], None)}],
    "when_window": [{"pick": p, "now": n, "zone": z, "want": when_window(p, n, z)} for p, n, z in windows],
    "filter_labels": [{"filters": f, "want": filter_labels(f)} for f in filters],
    "board_line": [{"board": b, "want": board_line(b)} for b in boards],
    "league_line": [{"card": c, "want": league_line(c)} for c in cards],
    "display_auto": [{"status": s, "round": r, "elapsed": e, "results_in": i, "matches": m, "t": t, "want": display_auto(s, r, e, i, m, t)}
                     for s, r, e, i, m, t in autos],
    "display_pages": [{"rows": r, "height": h, "row_height": rh, "header": hd, "want": display_pages(r, h, rh, hd)} for r, h, rh, hd in pages],
}
Path(__file__).with_name("cases.json").write_text(json.dumps(cases, indent=1, ensure_ascii=False) + "\n")
print({k: len(v) for k, v in cases.items()})
