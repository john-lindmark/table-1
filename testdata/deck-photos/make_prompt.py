#!/usr/bin/env python3
"""Reference for the deck photo prompt (contract/event-night-2026-10-16.md § 7 "Once your last match is in").

Writes prompt.json, read by iOS DeckPhotoPromptTests, web deckPhotos.test.ts and Android DeckPhotosTest.

done(event, me, rounds) says why a player is finished playing, or None:
  - not in the event, or the event was cancelled: None
  - the event is over (completed / archived): "over"
  - the player dropped: "dropped"
  - their latest match has its result in (a bye, or reported / confirmed) and it was their last:
      a playoff match they lost, or the final: "last"
      the last Swiss round (number >= the event's rounds) with no top cut, or once the playoffs have
      started without them: "last"
  - otherwise None (still playing, or waiting on the cut)
show is "add" when done and the player has no photo of their deck in the event yet, "added" when they do,
else None.
"""
import json
import os

RESULT_IN = ("reported", "confirmed")


def done(event, me, rounds):
    if me is None or event["status"] == "cancelled":
        return None
    if event["status"] in ("completed", "archived"):
        return "over"
    if me.get("status") == "dropped" or me.get("dropped_in_round") is not None:
        return "dropped"
    mine = [r for r in rounds if r.get("mine") is not None]
    if not mine:
        return None
    last = max(mine, key=lambda r: r["number"])
    m = last["mine"]
    if not (m.get("bye") or m.get("status") in RESULT_IN):
        return None
    stage = last.get("stage") or "swiss"
    if stage != "swiss":
        return "last" if stage == "final" or m["my"] < m["their"] else None
    if last["number"] < event["rounds"]:
        return None
    if event.get("top_cut", 0) == 0:
        return "last"
    return "last" if any((r.get("stage") or "swiss") != "swiss" for r in rounds) else None


def show(case):
    why = done(case["event"], case["me"], case["rounds"])
    if why is None:
        return None
    return "added" if case["photo"] else "add"


def m(status="confirmed", my=2, their=0, bye=False):
    return {"bye": bye, "status": status, "my": my, "their": their}


def r(number, mine, stage="swiss"):
    return {"number": number, "stage": stage, "mine": mine}


RUNNING = {"status": "running", "rounds": 3, "top_cut": 0}
CUT = {"status": "running", "rounds": 3, "top_cut": 8}
ME = {"status": "active", "dropped_in_round": None}

CASES = [
    ("round 1 still to play", RUNNING, ME, [r(1, m(status="pending", my=0, their=0))], False),
    ("round 2 of 3 in", RUNNING, ME, [r(1, m()), r(2, m())], False),
    ("last round still playing", RUNNING, ME, [r(1, m()), r(2, m()), r(3, m(status="pending", my=0, their=0))], False),
    ("last round reported by either side", RUNNING, ME, [r(1, m()), r(2, m()), r(3, m(status="reported", my=1, their=2))], False),
    ("last round confirmed, photo already in", RUNNING, ME, [r(1, m()), r(2, m()), r(3, m())], True),
    ("bye in the last round", RUNNING, ME, [r(1, m()), r(2, m()), r(3, m(bye=True, my=2, their=0))], False),
    ("not paired in the last round yet", RUNNING, ME, [r(1, m()), r(2, m()), {"number": 3, "stage": "swiss", "mine": None}], False),
    ("before round 1", {"status": "registration", "rounds": 3, "top_cut": 0}, ME, [], False),
    ("event over", {"status": "completed", "rounds": 3, "top_cut": 0}, ME, [r(1, m()), r(2, m())], False),
    ("event archived, photo in", {"status": "archived", "rounds": 3, "top_cut": 0}, ME, [r(1, m())], True),
    ("cancelled", {"status": "cancelled", "rounds": 3, "top_cut": 0}, ME, [r(1, m()), r(2, m()), r(3, m())], False),
    ("spectator", RUNNING, None, [], False),
    ("dropped", RUNNING, {"status": "dropped", "dropped_in_round": 2}, [r(1, m()), r(2, m(my=0, their=2))], False),
    ("dropped by round only", RUNNING, {"status": "active", "dropped_in_round": 1}, [r(1, m())], False),
    ("top 8: last Swiss round in, cut not made yet", CUT, ME, [r(1, m()), r(2, m()), r(3, m())], False),
    ("top 8: playoffs started without them", CUT, ME,
     [r(1, m()), r(2, m()), r(3, m(my=0, their=2)), {"number": 4, "stage": "quarterfinal", "mine": None}], False),
    ("top 8: quarterfinal still playing", CUT, ME,
     [r(1, m()), r(2, m()), r(3, m()), r(4, m(status="pending", my=0, their=0), "quarterfinal")], False),
    ("top 8: won the quarterfinal", CUT, ME,
     [r(1, m()), r(2, m()), r(3, m()), r(4, m(status="reported", my=2, their=1), "quarterfinal")], False),
    ("top 8: lost the semifinal", CUT, ME,
     [r(1, m()), r(2, m()), r(3, m()), r(4, m(), "quarterfinal"), r(5, m(my=1, their=2), "semifinal")], False),
    ("top 8: won the final", CUT, ME,
     [r(1, m()), r(2, m()), r(3, m()), r(4, m(), "quarterfinal"), r(5, m(), "semifinal"), r(6, m(), "final")], False),
    ("old server without stage", {"status": "running", "rounds": 2}, ME,
     [{"number": 1, "mine": m()}, {"number": 2, "mine": m()}], False),
]


def main():
    out = {
        "_doc": __doc__.strip(),
        "cases": [],
    }
    for name, event, me, rounds, photo in CASES:
        case = {"name": name, "event": event, "me": me, "rounds": rounds, "photo": photo}
        case["why"] = done(event, me, rounds)
        case["show"] = show(case)
        out["cases"].append(case)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompt.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    print(f"wrote {len(out['cases'])} cases to {path}")


if __name__ == "__main__":
    main()
