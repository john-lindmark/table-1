#!/usr/bin/env python3
"""Reference for saving a cube ranking (contract/cube-rankings-2026-10-21.md, "Saving"). It writes cases.json, which iOS
(RankSyncTests), web (rankSync.test.ts) and Android (RankSyncTest) all read.

    python3 -I testdata/ranking-save/make_cases.py      # rewrites testdata/ranking-save/cases.json

Why (2026-10-23): twice in one night an iPhone wiped a 500-screen ranking. Overlapping saves hit a conflict, the recovery
cleared the app's copy of the server's log, and a save still waiting worked out "keep 0, add 1" from it; the server
accepted it. The apps now never work out removals by comparing logs. They keep:
  - server: the log as the server last said it is,
  - adds: screens locked in here and not yet saved (lock-ins, picks), in order,
  - drops: screens taken out here and not yet saved (undo, redo, let the pick win), in order,
and everything shown and sent is plan(server, adds, drops):
  - start from the server's log; append each add the log doesn't already hold (a save that landed but whose answer was
    lost, or one another device made, isn't added twice);
  - then each drop takes out the first screen with its key. One that came from the server is sent as a drop; one that
    was only an add here cancels it, and neither is sent. A drop the log no longer holds is skipped (another device took
    it out already).
  - The push is p_keep = p_count = len(server), p_add, p_drop, p_removed = len(p_drop). The server refuses it unless its
    log is that long and holds those screens, so a stale app can only be told to reload, never remove what it didn't
    mean to.
After a conflict the app reloads `server` and plans again: nothing done here is thrown away. A screen's key is its
session, cards in order and time in whole ms.
"""
import json
from pathlib import Path


def key(s):
    t = s.get("t")
    return s["s"] + "|" + ",".join(s["o"]).lower() + "|" + ("" if t is None else str(round(t)))


def plan(server, adds, drops):
    log = [dict(s, _from="server") for s in server]
    have = {key(s) for s in log}
    for a in adds:
        if key(a) not in have:
            log.append(dict(a, _from="add"))
            have.add(key(a))
    drop = []
    for d in drops:
        k = key(d)
        i = next((i for i, s in enumerate(log) if key(s) == k), None)
        if i is None:
            continue
        gone = log.pop(i)
        have = {key(s) for s in log}
        if gone["_from"] == "server":
            drop.append(d)
    add = [{k: v for k, v in s.items() if k != "_from"} for s in log if s["_from"] == "add"]
    clean = [{k: v for k, v in s.items() if k != "_from"} for s in log]
    return {"log": clean, "add": add, "drop": drop, "keep": len(server), "removed": len(drop)}


def scr(name, s="W", t=None):
    """A screen named by a letter: its cards are made from the name so different names never share a key."""
    o = [f"{name}0000000-0000-4000-8000-00000000000{i}" for i in (1, 2)]
    return {"s": s, "o": o, **({"t": t} if t is not None else {"t": ord(name[0]) * 1000})}


def case(name, server, adds, drops, note):
    return {"name": name, "note": note, "server": server, "adds": adds, "drops": drops,
            "want": plan(server, adds, drops)}


def main():
    a, b, c, d, e, p = (scr(x) for x in "abcdep")
    p = dict(p, s="P")
    cases = [
        case("lock in", [a, b], [c], [], "A lock-in is appended and sent alone."),
        case("nothing to do", [a, b], [], [], "Nothing pending: nothing to send."),
        case("undo a saved screen", [a, b, c], [], [c], "Undo names the screen; the rest of the log is never re-sent."),
        case("redo the first screen", [a, b, c], [], [a], "Redo of screen 1 sends one drop, not the other screens."),
        case("undo before it saved", [a, b], [c], [c], "Locked in and undone before saving: nothing is sent."),
        case("lock in, undo, lock in", [a, b], [c, d], [c], "Only the second lock-in is sent."),
        case("a save that landed", [a, b, c], [c], [], "Its answer was lost; the log already holds it, so it isn't sent again."),
        case("another device added", [a, b, d], [c], [], "After a conflict: their screen stays, ours goes after it."),
        case("another device removed it", [a, b], [], [c], "The screen we undid is already gone: nothing is removed."),
        case("let the pick win", [a, b, c, d], [p], [b, c], "Two screens out and the pick in, in one push."),
        case("the wipe can't happen", [a, b, c, d, e], [], [], "A reload that finds the whole log never turns into removals."),
        case("an empty log from the server", [], [c], [], "Even if the server's log came back empty, only the add is sent."),
        case("same cards, other time", [a, b], [scr("a", t=999)], [], "A screen with the same cards at another time is a new screen."),
        case("times in whole ms", [scr("a", t=1792720614450)], [scr("a", t=1792720614450.0)], [],
             "1792720614450 and 1792720614450.0 are the same screen."),
        case("undo twice", [a, b, c], [], [c, b], "Two undos, two drops, in the order they were made."),
        case("drop listed twice", [a, b, c], [], [c, c], "A screen named twice is only taken out once."),
    ]
    out = {"note": "Generated by make_cases.py: change that first.", "cases": cases}
    Path(__file__).with_name("cases.json").write_text(json.dumps(out, indent=1) + "\n")
    print(f"{len(cases)} cases")


if __name__ == "__main__":
    main()
