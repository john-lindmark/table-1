#!/usr/bin/env python3
"""Writes the collection import fixtures in testdata/collection-import/: the same 24 cards as seven apps export them.

Column layouts follow real exports (ManaBox, Moxfield, Archidekt, Deckbox, Dragon Shield and TCGplayer from the sample
files MtgCsvHelper keeps of each app's own export, May 2026; Delver Lens from a Delver Lens N export in
urza-gatherer-scripts). Cards come from the live catalog pack, so ids, set codes and collector numbers are real; the
iOS and web tests resolve the files against testdata/scan/catalog.tsv.gz (same printings, shortened ids), so they
match by set + collector number there and by Scryfall id in the app.

  python3 -I testdata/collection-import/make_fixtures.py <live pack .tsv.gz> <mtg_sets.json>

mtg_sets.json is `select code, name from mtg_sets` as JSON (paged: PostgREST returns 1000 rows a call). Also writes
sets.json, the mtg_sets rows for the fixtures' sets.
"""
import csv, gzip, io, json, os, sys

pack, sets_path = sys.argv[1], sys.argv[2]
out = os.path.dirname(os.path.abspath(__file__))
set_names = {s["code"]: s["name"] for s in json.load(open(sets_path))}

oracles, printings = {}, {}
with gzip.open(pack, "rt", encoding="utf8") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if c[0] == "O":
            oracles[int(c[1])] = {"name": c[3], "faces": c[9]}
        elif c[0] == "P":
            printings[(c[3], c[4], c[5])] = {"id": c[1], "o": int(c[2]), "set": c[3], "cn": c[4], "lang": c[5],
                                             "rarity": c[6], "finishes": c[7]}

# (set, collector number, printing language, finish, condition, copy language, qty): picked to cover single cards,
# a name with a comma, split / adventure / double-faced cards, foil, etched, a token, a basic land, other languages
# and every condition.
PICKS = [
    ("m11", "149", "en", "nonfoil", "NM", "en", 4),     # Lightning Bolt
    ("ltr", "192", "en", "nonfoil", "NM", "en", 1),     # Aragorn, the Uniter (comma in the name)
    ("ltr", "192", "en", "foil", "LP", "en", 1),
    ("eld", "39", "en", "nonfoil", "NM", "en", 2),      # Brazen Borrower // Petty Theft (adventure)
    ("isd", "51", "en", "nonfoil", "MP", "en", 3),      # Delver of Secrets // Insectile Aberration (DFC)
    ("dgm", "122", "en", "nonfoil", "NM", "en", 1),     # Armed // Dangerous (split)
    ("mh2", "151", "en", "nonfoil", "NM", "de", 1),     # Chatterfang (German copy)
    ("2xm", "117", "en", "foil", "NM", "en", 1),        # Blasphemous Act, foil
    ("cmm", "1", "en", "nonfoil", "HP", "en", 1),       # The Prismatic Piper
    ("mom", "65", "en", "nonfoil", "NM", "ja", 1),      # Jin-Gitaxias // The Great Synthesis (Japanese copy)
    ("znr", "179", "en", "nonfoil", "NM", "en", 2),     # Ashaya, Soul of the Wild
    ("bfz", "233", "en", "nonfoil", "DMG", "en", 1),    # Blighted Woodland
    ("rix", "136", "en", "nonfoil", "HP", "en", 1),     # Jadelight Ranger
    ("clb", "54", "en", "nonfoil", "NM", "ko", 1),      # Aarakocra Sneak (Korean copy)
    ("mid", "2", "en", "nonfoil", "LP", "en", 1),       # Ambitious Farmhand // Seasoned Cathar
    ("tmh2", "14", "en", "nonfoil", "NM", "en", 3),     # Clue token
    ("neo", "292", "en", "nonfoil", "NM", "en", 10),    # Forest
    ("mh2", "300", "en", "etched", "NM", "en", 1),      # Zuran Orb, etched
    ("inv", "290", "en", "nonfoil", "NM", "en", 4),     # Yavimaya Barbarian
    ("tmp", "107", "en", "nonfoil", "MP", "en", 2),     # Abandon Hope
    ("2x2", "117", "en", "nonfoil", "NM", "en", 2),     # Lightning Bolt
    ("voc", "1", "en", "nonfoil", "NM", "en", 1),       # Millicent, Restless Revenant
    ("cmr", "656", "en", "foil", "NM", "en", 1),        # Vampiric Tutor
    ("khm", "113", "en", "nonfoil", "NM", "fr", 2),     # Tergrid's Shadow (French copy)
]

cards = []
for s, cn, lang, finish, cond, copy_lang, qty in PICKS:
    p = printings.get((s, cn, lang))
    if not p:
        sys.exit(f"not in pack: {s} {cn} {lang}")
    want = {"nonfoil": "n", "foil": "f", "etched": "e"}[finish]
    if want not in p["finishes"]:
        f = {"n": "nonfoil", "f": "foil", "e": "etched"}[p["finishes"][0]]
        print(f"note: {s} {cn} has no {finish}, using {f}")
        finish = f
    o = oracles[p["o"]]
    cards.append({**p, "name": o["name"], "front": o["name"].split(" // ")[0], "finish": finish, "cond": cond,
                  "copy_lang": copy_lang, "qty": qty, "set_name": set_names.get(s, s.upper())})

LANG = {"en": "English", "de": "German", "fr": "French", "ja": "Japanese", "ko": "Korean"}
RARITY = {"c": "common", "u": "uncommon", "r": "rare", "m": "mythic", "s": "special", "b": "bonus"}
# Each app's own words for the five conditions (Cardmarket's scale for ManaBox and Dragon Shield).
COND = {
    "manabox": {"NM": "near_mint", "LP": "excellent", "MP": "light_played", "HP": "played", "DMG": "poor"},
    "moxfield": {"NM": "Near Mint", "LP": "Lightly Played", "MP": "Moderately Played", "HP": "Heavily Played", "DMG": "Damaged"},
    "archidekt": {"NM": "NM", "LP": "LP", "MP": "MP", "HP": "HP", "DMG": "D"},
    "deckbox": {"NM": "Near Mint", "LP": "Good (Lightly Played)", "MP": "Played", "HP": "Heavily Played", "DMG": "Poor"},
    "dragonshield": {"NM": "NearMint", "LP": "Excellent", "MP": "LightPlayed", "HP": "Played", "DMG": "Poor"},
    "tcgplayer": {"NM": "Near Mint", "LP": "Lightly Played", "MP": "Moderately Played", "HP": "Heavily Played", "DMG": "Damaged"},
}
# Lines no catalog has: the preview lists them to fix or skip.
UNKNOWN = {"name": "Totally Not A Card", "set": "zzz", "set_name": "Imaginary Set", "cn": "999"}


def write(name, header, rows, delimiter=",", quote_all=False, preamble=""):
    buf = io.StringIO()
    buf.write(preamble)
    w = csv.writer(buf, delimiter=delimiter, lineterminator="\r\n" if delimiter == "," else "\n",
                   quoting=csv.QUOTE_ALL if quote_all else csv.QUOTE_MINIMAL)
    w.writerow(header)
    w.writerows(rows)
    with open(os.path.join(out, name), "w", encoding="utf8", newline="") as f:
        f.write(buf.getvalue())


write("manabox.csv",
      ["Binder Name", "Binder Type", "Name", "Set code", "Set name", "Collector number", "Foil", "Rarity", "Quantity",
       "ManaBox ID", "Scryfall ID", "Purchase price", "Misprint", "Altered", "Condition", "Language", "Purchase price currency"],
      [["Trade binder" if i % 3 else "My collection", "binder", c["name"], c["set"].upper(), c["set_name"], c["cn"],
        "normal" if c["finish"] == "nonfoil" else c["finish"], RARITY[c["rarity"]], c["qty"], 50000 + i, c["id"],
        f"{0.25 * (i + 1):.2f}", "false", "false", COND["manabox"][c["cond"]], c["copy_lang"], "USD"] for i, c in enumerate(cards)]
      + [["My collection", "binder", UNKNOWN["name"], UNKNOWN["set"].upper(), UNKNOWN["set_name"], UNKNOWN["cn"], "normal",
          "rare", 1, 1, "", "0.00", "false", "false", "near_mint", "en", "USD"]])

write("moxfield.csv",
      ["Count", "Tradelist Count", "Name", "Edition", "Condition", "Language", "Foil", "Tags", "Last Modified",
       "Collector Number", "Alter", "Proxy", "Purchase Price"],
      [[c["qty"], 0, c["name"], c["set"], COND["moxfield"][c["cond"]], LANG[c["copy_lang"]],
        "" if c["finish"] == "nonfoil" else c["finish"], "", "2026-10-01 12:00:00.000000", c["cn"], "False", "False", ""]
       for c in cards]
      + [[1, 0, UNKNOWN["name"], UNKNOWN["set"], "Near Mint", "English", "", "", "2026-10-01 12:00:00.000000",
          UNKNOWN["cn"], "False", "False", ""]],
      quote_all=True)

write("archidekt.csv",
      ["Quantity", "Name", "Finish", "Condition", "Date Added", "Language", "Purchase Price", "Tags", "Edition Name",
       "Edition Code", "Multiverse Id", "Scryfall ID", "Collector Number"],
      [[c["qty"], c["name"], c["finish"].capitalize() if c["finish"] != "nonfoil" else "Normal", COND["archidekt"][c["cond"]],
        "2026-10-01", c["copy_lang"].upper(), "", "", c["set_name"], c["set"], 0, c["id"], c["cn"]] for c in cards]
      + [[1, UNKNOWN["name"], "Normal", "NM", "2026-10-01", "EN", "", "", UNKNOWN["set_name"], UNKNOWN["set"], 0, "", UNKNOWN["cn"]]])

# Deckbox has its own edition codes and names for some sets (tokens are "Extras: <set>", code ex_NNN), so the token row
# carries no Scryfall id: it has to match by name.
def deckbox_set(c):
    if c["set"].startswith("t") and "Tokens" in c["set_name"]:
        return f"Extras: {c['set_name'].replace(' Tokens', '')}", "ex_127"
    return c["set_name"], c["set"]

write("deckbox.csv",
      ["Count", "Tradelist Count", "Name", "Edition", "Edition Code", "Card Number", "Condition", "Language", "Foil",
       "Signed", "Artist Proof", "Altered Art", "Misprint", "Promo", "Textless", "Printing Id", "Printing Note", "Tags",
       "My Price", "Cost", "Rarity", "Price", "TcgPlayer ID", "Scryfall ID"],
      [[c["qty"], 0, c["name"], *deckbox_set(c), c["cn"], COND["deckbox"][c["cond"]], LANG[c["copy_lang"]],
        "" if c["finish"] == "nonfoil" else c["finish"], "", "", "", "", "", "", 70000 + i, "", "", "$0.00", "",
        RARITY[c["rarity"]].capitalize(), "$0.25", "", "" if deckbox_set(c)[1] == "ex_127" else c["id"]]
       for i, c in enumerate(cards)]
      + [[1, 0, UNKNOWN["name"], UNKNOWN["set_name"], UNKNOWN["set"], UNKNOWN["cn"], "Near Mint", "English", "", "", "", "",
          "", "", "", "", "", "", "$0.00", "", "Rare", "$0.00", "", ""]])

write("dragonshield.csv",
      ["Folder Name", "Quantity", "Trade Quantity", "Card Name", "Set Code", "Set Name", "Card Number", "Condition",
       "Printing", "Language", "Price Bought", "Date Bought", "LOW", "MID", "MARKET"],
      [["Binder", c["qty"], 0, c["name"], c["set"].upper(), c["set_name"], c["cn"], COND["dragonshield"][c["cond"]],
        {"nonfoil": "Normal", "foil": "Foil", "etched": "Etched"}[c["finish"]], LANG[c["copy_lang"]], "0.00", "2026-10-01",
        "", "", ""] for c in cards]
      + [["Binder", 1, 0, UNKNOWN["name"], UNKNOWN["set"].upper(), UNKNOWN["set_name"], UNKNOWN["cn"], "NearMint", "Normal",
          "English", "0.00", "2026-10-01", "", "", ""]],
      preamble='"sep=,"\r\n')

write("tcgplayer.csv",
      ["Quantity", "Name", "Simple Name", "Set", "Card Number", "Set Code", "Printing", "Condition", "Language", "Rarity",
       "Product ID", "SKU"],
      [[c["qty"], c["name"] + (" (Foil Etched)" if c["finish"] == "etched" else ""), c["front"], c["set_name"], c["cn"],
        c["set"].upper(), "Foil" if c["finish"] != "nonfoil" else "Normal", COND["tcgplayer"][c["cond"]], LANG[c["copy_lang"]],
        RARITY[c["rarity"]].capitalize(), "", ""] for c in cards]
      + [[1, UNKNOWN["name"], UNKNOWN["name"], UNKNOWN["set_name"], UNKNOWN["cn"], UNKNOWN["set"].upper(), "Normal",
          "Near Mint", "English", "Rare", "", ""]])

# Delver Lens N's own CSV (no preset): tab-separated, "2x" counts, set names only, foil "Foil" or blank.
write("delverlens.csv",
      ["QuantityX", "Name", "Edition", "Foil", "Price", "Scryfall ID", "MultiverseID", "Delver Local ID", "TCGPlayer productID"],
      [[f"{c['qty']}x", c["name"], c["set_name"], "" if c["finish"] == "nonfoil" else "Foil", "$0.25", c["id"], 0, i + 1, 0]
       for i, c in enumerate(cards)]
      + [["1x", UNKNOWN["name"], UNKNOWN["set_name"], "", "$0.00", "", 0, 99, 0]],
      delimiter="\t")

# What every file should resolve to (the Delver Lens and TCGplayer files lose etched: their foil column only says Foil).
with open(os.path.join(out, "expected.json"), "w", encoding="utf8") as f:
    json.dump({"unmatched": UNKNOWN["name"], "cards": [
        {"set": c["set"], "cn": c["cn"], "name": c["name"], "finish": c["finish"], "condition": c["cond"],
         "lang": c["copy_lang"], "qty": c["qty"]} for c in cards]}, f, indent=1, ensure_ascii=False)
    f.write("\n")
# The mtg_sets rows the fixtures name, for tests that match by set name.
with open(os.path.join(out, "sets.json"), "w", encoding="utf8") as f:
    json.dump(sorted(({"code": c, "name": set_names[c]} for c in {c["set"] for c in cards} if c in set_names),
                     key=lambda s: s["code"]), f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"{len(cards)} cards → {out}")
