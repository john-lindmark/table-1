# Reference for the card icon widget (contract/icon-widget-2026-11-06.md): the device's list of icon cards and which
# one a widget shows. iOS (Shared/IconCards.swift, IconCardsTests) and Android (widgets/IconCards.kt, IconCardsTest)
# check themselves against cases.json. Change this first, then the apps.
#   python3 -I testdata/icon-widget/make_cases.py   → cases.json next to it
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
LIMIT = 12          # icon cards kept on a device
LOGO_SHARE = 479 / 1024  # the mark's width on the app icon (Figma "App icons" 19726:2784)


def add(cards, card):
    """The card goes first; picking it again moves it up; the oldest past LIMIT drop off."""
    return ([card] + [c for c in cards if c["id"] != card["id"]])[:LIMIT]


def remove(cards, cid):
    return [c for c in cards if c["id"] != cid]


def shown(cards, chosen):
    """A widget shows the card picked in its settings while it's still on the list, else the newest; none → the plain
    icon."""
    hit = next((c for c in cards if c["id"] == chosen), None) if chosen else None
    return (hit or (cards[0] if cards else None) or {}).get("id")


def logo(width):
    """The mark's width in a widget of this width, as on the app icon, in whole points."""
    return round(width * LOGO_SHARE)


def card(i, name):
    return {"id": f"0000000{i}-0000-4000-8000-00000000000{i}", "name": name, "set": f"SET · {i}"}


def main():
    a, b, c = card(1, "Lightning Bolt"), card(2, "Counterspell"), card(3, "Ragavan, Nimble Pilferer")
    many = [card(i % 10, f"Card {i}") | {"id": f"id-{i:02d}"} for i in range(LIMIT)]
    extra = {"id": "id-new", "name": "Brainstorm", "set": "ICE · 61"}
    cases = {
        "limit": LIMIT,
        "add": [
            {"name": "first", "cards": [], "card": a, "want": [a["id"]]},
            {"name": "newest first", "cards": [a], "card": b, "want": [b["id"], a["id"]]},
            {"name": "again moves up", "cards": [b, a, c], "card": a, "want": [a["id"], b["id"], c["id"]]},
            {"name": "oldest drops", "cards": many, "card": extra,
             "want": [x["id"] for x in add(many, extra)]},
        ],
        "remove": [
            {"name": "gone", "cards": [a, b, c], "id": b["id"], "want": [a["id"], c["id"]]},
            {"name": "not there", "cards": [a], "id": "nope", "want": [a["id"]]},
        ],
        "shown": [
            {"name": "newest by default", "cards": [b, a], "chosen": None, "want": b["id"]},
            {"name": "chosen", "cards": [b, a], "chosen": a["id"], "want": a["id"]},
            {"name": "chosen removed", "cards": [b], "chosen": a["id"], "want": b["id"]},
            {"name": "none", "cards": [], "chosen": a["id"], "want": None},
        ],
        "logo": [{"width": w, "want": logo(w)} for w in (40, 57, 110, 158, 170, 1024)],
    }
    for k in ("add", "remove"):
        for t in cases[k]:
            got = add(t["cards"], t["card"]) if k == "add" else remove(t["cards"], t["id"])
            assert [x["id"] for x in got] == t["want"], t["name"]
    for t in cases["shown"]:
        assert shown(t["cards"], t["chosen"]) == t["want"], t["name"]
    with open(os.path.join(HERE, "cases.json"), "w") as f:
        json.dump(cases, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
