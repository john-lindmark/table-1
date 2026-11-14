#!/usr/bin/env python3
"""Reference for contract/scheduled-events-2026-10-27.md: writes cases.json next to this file.

Sections (every client and events-engine's playoffs.test.ts read them):
  rounds     players -> recommended Swiss rounds (t1_private.swiss_rounds)
  next       the organizer's next step from the paired stages (top 8, top 4, and top 4 for team events, whose
             cases carry active_teams: the teams with at least one active member)
  round_name a round's name from its stage, number and the Swiss count
  sign_up    the sign-up line on the event page
  auto_label the Rounds row when Auto is on
  rounds_line the rounds line on the event page
  button     the event page's state from sign_up / me
  decklist   card counts in a pasted list (t1_private.decklist_counts)
  deck_format which of your decks fit an event's format (null = any deck)
  decklists_line the organizer's count of lists in
Change this file first, then run it, then make the clients agree.
"""
import json
import os

BANDS = [(2, 1), (4, 2), (8, 3), (16, 4), (32, 5), (64, 6), (128, 7), (226, 8), (409, 9)]


def swiss_rounds(players):
    for top, rounds in BANDS:
        if players <= top:
            return rounds
    return 10


def next_step(stages, waiting, number_of_rounds, top_cut, active_players, active_teams=None):
    """The organizer's next step.

    start      no round paired yet
    waiting    the open round has a match without a result, or a dispute
    pair       pair the next Swiss round
    cut        "Cut to top 8": quarterfinals from the Swiss standings (top_cut 8, more than 8 active players)
    cut4       "Cut to top 4": Swiss straight to the semifinals (top_cut 4, more than 4 active players; team
               events: more than 4 active teams)
    semifinals "Pair semifinals" (after the quarterfinals)
    final      "Pair the final"
    finish     "Finish event"

    active_teams is given for team events only (team sealed, Team Trios): the number of teams with at least one
    active member. The cut then counts teams, never players, and a team event has no top 8.
    """
    if not stages:
        return "start"
    if waiting:
        return "waiting"
    last = stages[-1]
    if last == "swiss":
        if sum(1 for s in stages if s == "swiss") < number_of_rounds:
            return "pair"
        if active_teams is None:
            if top_cut == 8 and active_players > 8:
                return "cut"
            if top_cut == 4 and active_players > 4:
                return "cut4"
        elif top_cut == 4 and active_teams > 4:
            return "cut4"
        return "finish"
    return {"quarterfinal": "semifinals", "semifinal": "final"}.get(last, "finish")


def round_name(stage, number, of):
    return {"quarterfinal": "Quarterfinals", "semifinal": "Semifinals", "final": "Final"}.get(
        stage, f"Round {number} of {of}")


def players(n):
    return "1 player" if n == 1 else f"{n} players"


def sign_up_line(count, capacity, waitlist):
    if capacity is None:
        return f"{players(count)} signed up"
    line = f"{count}/{capacity} players"
    if waitlist > 0:
        line += f" · {waitlist} on the waitlist"
    return line


def auto_label(count):
    if count < 2:
        return "Auto · set when round 1 is paired"
    n = swiss_rounds(count)
    return f"Auto · {n} round{'s' if n != 1 else ''} for {count} players"


def rounds_line(auto, rounds, top_cut, open_):
    head = "Auto rounds" if auto and open_ else f"{rounds} round{'s' if rounds != 1 else ''}"
    return head + (f" · Top {top_cut}" if top_cut in (4, 8) else "")


def button(signed_in, sign_up, me):
    if me == "organizer":
        return "organizer"
    if me == "player":
        return "in"
    if me == "waitlisted":
        return "waitlisted"
    if sign_up == "closed":
        return "closed"
    if not signed_in:
        return "sign_in"
    return "waitlist" if sign_up == "full" else "sign_up"


import re

MAIN_HEADS = {"deck", "main", "mainboard", "main deck", "commander"}
SIDE_HEADS = {"sideboard", "side", "side board"}
SKIP_HEADS = {"considering", "maybeboard", "maybe", "tokens", "about", "companion"}
LINE = re.compile(r"^(sb:\s*)?(\d{1,3})\s*x?\s+\S", re.I)


def decklist_counts(body):
    main = side = 0
    section, headers, seen = "main", False, False
    for line in body.replace("\r", "").split("\n"):
        line = line.strip()
        if not line:
            if not headers and seen and section == "main":
                section = "side"
            continue
        head = re.sub(r"[:\s]*(\(\d+\))?[:\s]*$", "", line).lower()
        if head in MAIN_HEADS:
            section, headers = "main", True
            continue
        if head in SIDE_HEADS:
            section, headers = "side", True
            continue
        if head in SKIP_HEADS:
            section, headers = "skip", True
            continue
        m = LINE.match(line)
        if not m:
            continue
        n = int(m.group(2))
        if m.group(1):
            side += n
        elif section == "main":
            main, seen = main + n, True
        elif section == "side":
            side += n
    return {"main": main, "side": side}


def deck_format(event_format):
    return {"canadian_highlander": "canlander", "other_constructed": None}.get(event_format, event_format)


def decklists_line(sent, players):
    return f"{sent}/{players} decklists in"


DECKS = [
    "4 Lightning Bolt\n4 Monastery Swiftspear\n52 Mountain\n\n3 Smash to Smithereens\n12 Pyroblast",
    "Deck\n4 Ragavan, Nimble Pilferer\n56 Mountain\n\nSideboard\n15 Pyroblast",
    "Deck (60)\n60 Island\nSideboard (15):\n15 Hydroblast\nConsidering\n4 Opt",
    "4x Lightning Bolt\r\n56 Mountain\r\nSB: 4 Pyroblast\r\nSB: 11 Smash to Smithereens",
    "Commander\n1 Kenrith, the Returned King\n\nDeck\n99 Island",
    "Lightning Bolt\nMountain",
    "",
    "  4 Fire // Ice  \n\n\n56 Island\n",
]

cases = {
    "rounds": [{"players": n, "want": swiss_rounds(n)}
               for n in [0, 1, 2, 3, 4, 5, 8, 9, 12, 16, 17, 32, 33, 64, 65, 128, 129, 226, 227, 409, 410, 2000]],
    "next": [],
    "round_name": [
        {"stage": "swiss", "number": 1, "of": 4, "want": round_name("swiss", 1, 4)},
        {"stage": "swiss", "number": 5, "of": 5, "want": round_name("swiss", 5, 5)},
        {"stage": "quarterfinal", "number": 6, "of": 5, "want": round_name("quarterfinal", 6, 5)},
        {"stage": "semifinal", "number": 7, "of": 5, "want": round_name("semifinal", 7, 5)},
        {"stage": "final", "number": 8, "of": 5, "want": round_name("final", 8, 5)},
    ],
    "sign_up": [{"players": p, "capacity": c, "waitlist": w, "want": sign_up_line(p, c, w)}
                for p, c, w in [(0, None, 0), (1, None, 0), (12, None, 0), (1, 8, 0), (12, 16, 0), (16, 16, 0),
                                (16, 16, 3), (17, 16, 1)]],
    "auto_label": [{"players": n, "want": auto_label(n)} for n in [0, 1, 2, 3, 8, 12, 40]],
    "rounds_line": [{"auto": a, "rounds": r, "top_cut": t, "open": o, "want": rounds_line(a, r, t, o)}
                    for a, r, t, o in [(False, 3, 0, True), (False, 1, 0, True), (True, 4, 8, True),
                                       (True, 4, 0, True), (True, 5, 8, False), (False, 6, 8, False),
                                       (True, 3, 4, True), (False, 3, 4, False), (False, 1, 4, True)]],
    "button": [{"signed_in": s, "sign_up": u, "me": m, "want": button(s, u, m)}
               for s, u, m in [(False, "open", None), (False, "full", None), (False, "closed", None),
                               (True, "open", None), (True, "full", None), (True, "closed", None),
                               (True, "open", "player"), (True, "full", "waitlisted"), (True, "closed", "player"),
                               (True, "open", "organizer"), (True, "closed", "organizer")]],
}

cases["decklist"] = [{"body": b, "want": decklist_counts(b)} for b in DECKS]
cases["deck_format"] = [{"event": f, "want": deck_format(f)} for f in
                        ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern",
                         "canadian_highlander", "other_constructed"]]
cases["decklists_line"] = [{"sent": a, "players": b, "want": decklists_line(a, b)} for a, b in [(0, 8), (7, 8), (8, 8)]]

for stages, waiting, rounds, cut, active in [
    ([], False, 3, 0, 8),
    ([], False, 4, 8, 12),
    (["swiss"], True, 3, 0, 8),
    (["swiss"], False, 3, 0, 8),
    (["swiss", "swiss", "swiss"], False, 3, 0, 8),
    (["swiss", "swiss", "swiss"], False, 3, 8, 8),
    (["swiss", "swiss", "swiss", "swiss"], False, 4, 8, 12),
    (["swiss", "swiss", "swiss", "swiss"], True, 4, 8, 12),
    (["swiss", "swiss", "swiss", "swiss", "quarterfinal"], False, 4, 8, 12),
    (["swiss", "swiss", "swiss", "swiss", "quarterfinal"], True, 4, 8, 12),
    (["swiss", "swiss", "swiss", "swiss", "quarterfinal", "semifinal"], False, 4, 8, 12),
    (["swiss", "swiss", "swiss", "swiss", "quarterfinal", "semifinal", "final"], False, 4, 8, 12),
    (["swiss", "swiss", "swiss", "swiss", "quarterfinal"], False, 4, 8, 7),
]:
    cases["next"].append({"stages": stages, "waiting": waiting, "number_of_rounds": rounds, "top_cut": cut,
                          "active_players": active, "want": next_step(stages, waiting, rounds, cut, active)})

# Top 4 (2026-11-13): Swiss straight to the semifinals. Appended, so the cases above stay as they were.
S3, S4 = ["swiss"] * 3, ["swiss"] * 4
for stages, waiting, rounds, cut, active in [
    ([], False, 3, 4, 8),
    (["swiss", "swiss"], False, 3, 4, 8),
    (S3, True, 3, 4, 8),
    (S3, False, 3, 4, 8),
    (S3, False, 3, 4, 5),
    (S3, False, 3, 4, 4),
    (S4, False, 4, 4, 12),
    (S3 + ["semifinal"], True, 3, 4, 8),
    (S3 + ["semifinal"], False, 3, 4, 8),
    (S3 + ["semifinal"], False, 3, 4, 3),
    (S3 + ["semifinal", "final"], False, 3, 4, 8),
    (S4, False, 4, 8, 9),
]:
    cases["next"].append({"stages": stages, "waiting": waiting, "number_of_rounds": rounds, "top_cut": cut,
                          "active_players": active, "want": next_step(stages, waiting, rounds, cut, active)})

# Team events (team sealed, Team Trios): active_teams decides the cut; active_players is still the players.
for stages, waiting, rounds, cut, active, teams in [
    ([], False, 3, 4, 18, 6),
    (["swiss", "swiss"], False, 3, 4, 18, 6),
    (S3, True, 3, 4, 18, 6),
    (S3, False, 3, 4, 18, 6),
    (S3, False, 3, 4, 15, 5),
    (S3, False, 3, 4, 12, 4),
    (S3, False, 3, 4, 16, 4),
    (S3, False, 3, 4, 24, 6),
    (S3, False, 3, 4, 4, 5),
    (S3 + ["semifinal"], True, 3, 4, 18, 6),
    (S3 + ["semifinal"], False, 3, 4, 18, 6),
    (S3 + ["semifinal"], False, 3, 4, 9, 3),
    (S3 + ["semifinal", "final"], False, 3, 4, 18, 6),
    (S3, False, 3, 0, 18, 6),
    (S4, False, 4, 8, 27, 9),
]:
    cases["next"].append({"stages": stages, "waiting": waiting, "number_of_rounds": rounds, "top_cut": cut,
                          "active_players": active, "active_teams": teams,
                          "want": next_step(stages, waiting, rounds, cut, active, teams)})

with open(os.path.join(os.path.dirname(__file__), "cases.json"), "w") as f:
    json.dump(cases, f, indent=1, ensure_ascii=False)
    f.write("\n")
