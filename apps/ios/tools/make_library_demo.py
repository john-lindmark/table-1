#!/usr/bin/env python3
"""Builds the Debug-only demo Library (apps/ios/Table1/DebugResources/library-demo.json).

Five Modern decks and a 360-card Vintage cube, resolved to real printing ids from a catalog pack, plus bulk
cards, for exactly TOTAL cards. The collection owns at least as many copies of each card as all decks and the
cube use together, so nothing shows as missing. Deterministic (fixed seed), so the fixture only changes when
this file or the pack does.

  python3 -I tools/make_library_demo.py <catalog pack .tsv.gz> <prices.json or -> <out.json>

prices.json maps card_id -> [usd, usd_foil, usd_etched, eur, eur_foil] (see the docstring at the bottom for
the SQL); pass "-" to write the fixture without prices.
"""
import gzip, json, random, re, sys, unicodedata

TOTAL = 2000
random.seed(20261015)

def norm(s):
    s = unicodedata.normalize("NFKD", s).lower()
    s = re.sub("[̀-ͯ]", "", s).replace("æ", "ae").replace("œ", "oe")
    s = re.sub("['’]", "", s)
    return re.sub("[^a-z0-9]+", " ", s).strip()

# ---- decks: (qty, name); main is padded to 60 with the listed basic, side must be 15 -------------------------
DECKS = [
  ("Boros Energy", "Plains", [
    (4, "Ragavan, Nimble Pilferer"), (4, "Guide of Souls"), (4, "Ocelot Pride"), (4, "Ajani, Nacatl Pariah"),
    (3, "Phlage, Titan of Fire's Fury"), (3, "Ranger-Captain of Eos"), (2, "Seasoned Pyromancer"),
    (4, "Galvanic Discharge"), (4, "Goblin Bombardment"), (2, "Static Prison"), (2, "Lightning Helix"),
    (4, "Arid Mesa"), (3, "Bloodstained Mire"), (2, "Windswept Heath"), (2, "Sacred Foundry"),
    (2, "Inspiring Vantage"), (2, "Elegant Parlor"), (1, "Arena of Glory"), (2, "Mountain")],
   [(2, "Wear // Tear"), (2, "Blood Moon"), (2, "Surgical Extraction"), (2, "Path to Exile"),
    (2, "Rest in Peace"), (2, "Kor Firewalker"), (2, "Wrath of the Skies"), (1, "Pyroclasm")]),
  ("Izzet Murktide", "Island", [
    (4, "Ragavan, Nimble Pilferer"), (4, "Dragon's Rage Channeler"), (4, "Murktide Regent"),
    (4, "Expressive Iteration"), (4, "Lightning Bolt"), (4, "Counterspell"), (4, "Consider"),
    (4, "Unholy Heat"), (2, "Fury"), (1, "Subtlety"), (3, "Mishra's Bauble"),
    (4, "Scalding Tarn"), (3, "Polluted Delta"), (2, "Steam Vents"), (2, "Spirebluff Canal"),
    (1, "Bloodstained Mire"), (2, "Mountain")],
   [(2, "Mystical Dispute"), (2, "Blood Moon"), (2, "Engineered Explosives"), (2, "Force of Negation"),
    (2, "Pyroblast"), (2, "Fire // Ice"), (2, "Subtlety"), (1, "Brazen Borrower // Petty Theft")]),
  ("Amulet Titan", "Forest", [
    (4, "Amulet of Vigor"), (4, "Primeval Titan"), (4, "Arboreal Grazer"), (4, "Dryad of the Ilysian Grove"),
    (4, "Summoner's Pact"), (3, "Scapeshift"), (4, "Explore"), (3, "Spelunking"), (2, "Cultivator Colossus"),
    (4, "Gruul Turf"), (4, "Simic Growth Chamber"), (1, "Boros Garrison"), (4, "Urza's Saga"),
    (1, "Tolaria West"), (1, "Valakut, the Molten Pinnacle"), (1, "Slayers' Stronghold"), (1, "Vesuva"),
    (2, "Misty Rainforest"), (1, "Otawara, Soaring City"), (1, "Boseiju, Who Endures")],
   [(3, "Force of Vigor"), (2, "Pact of Negation"), (2, "Trinisphere"), (2, "Dismember"),
    (2, "Endurance"), (2, "Collector Ouphe"), (2, "Mystical Dispute")]),
  ("Ruby Storm", "Mountain", [
    (4, "Ruby Medallion"), (4, "Ral, Monsoon Mage // Ral, Leyline Prodigy"), (4, "Manamorphose"),
    (4, "Desperate Ritual"), (4, "Pyretic Ritual"), (4, "Grapeshot"), (2, "Empty the Warrens"),
    (4, "Reckless Impulse"), (4, "Wrenn's Resolve"), (3, "Past in Flames"), (1, "Galvanic Relay"),
    (2, "Spirebluff Canal"), (2, "Fiery Islet")],
   [(3, "Orim's Chant"), (2, "Blood Moon"), (2, "Pieces of the Puzzle"), (2, "Prismatic Ending"),
    (2, "Wear // Tear"), (2, "Silence"), (2, "Surgical Extraction")]),
  ("Eldrazi Tron", "Wastes", [
    (4, "Eldrazi Temple"), (4, "Urza's Mine"), (4, "Urza's Power Plant"), (4, "Urza's Tower"),
    (4, "Thought-Knot Seer"), (4, "Reality Smasher"), (4, "Matter Reshaper"), (4, "Karn, the Great Creator"),
    (4, "Expedition Map"), (4, "Chalice of the Void"), (2, "Walking Ballista"), (2, "Ugin, the Spirit Dragon"),
    (2, "Ghost Quarter")],
   [(2, "Relic of Progenitus"), (2, "Torpor Orb"), (2, "Ratchet Bomb"), (2, "Warping Wail"),
    (2, "Spatial Contortion"), (2, "Ensnaring Bridge"), (3, "Dismember")]),
]

# ---- considering ("maybe" board): ideas, not commitments; never counted as missing -----------------------------
CONSIDERING = {
    "Boros Energy": [(1, "Ocelot Pride"), (2, "Static Prison"), (1, "Sunfall"), (2, "Thraben Inspector")],
    "Izzet Murktide": [(2, "Psychic Frog"), (1, "Spell Pierce"), (2, "Ledger Shredder")],
    "Amulet Titan": [(1, "Aftermath Analyst"), (2, "Sanctum Weaver"), (1, "Castle Garenbrig")],
    "Ruby Storm": [(2, "Glimpse the Impossible"), (1, "Gifts Ungiven"), (2, "Strike It Rich")],
    "Eldrazi Tron": [(2, "Devourer of Destiny"), (1, "Kozilek's Command"), (2, "Emrakul, the Promised End")],
}
CUBE_CONSIDERING = """Sheoldred, the Apocalypse|The Mightstone and Weakstone|Ketramose, the New Dawn|Vren, the Relentless|
Overlord of the Hauntwoods|Overlord of the Boilerbilges|Sunfall|Mosswood Dreadknight // Dread Whispers|
Grief|Fable of the Mirror-Breaker // Reflection of Kiki-Jiki|Sink into Stupor // Soporific Springs|Witch Enchanter // Witch-Blessed Meadow|
Fell the Profane // Fell Mire|Agadeem's Awakening // Agadeem, the Undercrypt|Emeria's Call // Emeria, Shattered Skyclave"""

# Version history per list: the first version (note only), then each later version as (note, changes from the
# previous version). Replaying the changes on the first version gives the current list. Considering cards arrive
# in the second version, so the first is the bare list.
HISTORY = {
    "Boros Energy": ("Imported from Moxfield", [
        ("Ranger-Captain over Inspector", [("main", 2, "Ranger-Captain of Eos"), ("main", -2, "Thraben Inspector")]),
        ("Sideboard for the RCQ", [("side", 1, "Kor Firewalker"), ("side", -1, "Pyroclasm")])]),
    "Izzet Murktide": ("Imported from Moxfield", [
        ("Subtlety main", [("main", 1, "Subtlety"), ("main", -1, "Spell Pierce")]),
        ("Second Fury", [("main", 1, "Fury"), ("main", -1, "Consider")])]),
    "Amulet Titan": ("First list", [
        ("Colossus in", [("main", 1, "Cultivator Colossus"), ("main", -1, "Spelunking")])]),
    "Ruby Storm": ("First list", [
        ("Relay test", [("main", 1, "Galvanic Relay"), ("main", -1, "Reckless Impulse")]),
        ("More Silence", [("side", 1, "Silence"), ("side", -1, "Orim's Chant")])]),
    "Eldrazi Tron": ("First list", [
        ("Ballista back", [("main", 2, "Walking Ballista"), ("main", -2, "Matter Reshaper")])]),
    "Vintage Cube": ("Initial 360", [
        ("Considering list started", [])]),
}

# ---- vintage cube: singleton -----------------------------------------------------------------------------------
CUBE = """
Ancestral Recall|Black Lotus|Mox Pearl|Mox Sapphire|Mox Jet|Mox Ruby|Mox Emerald|Time Walk|Timetwister|Sol Ring|
Mana Crypt|Mana Vault|Grim Monolith|Chrome Mox|Mox Diamond|Lotus Petal|Mox Opal|Mind Stone|Arcane Signet|
Fellwar Stone|Coalition Relic|Lion's Eye Diamond|Basalt Monolith|Mana Drain|Force of Will|Force of Negation|
Counterspell|Mental Misstep|Brainstorm|Ponder|Preordain|Mystical Tutor|Demonic Tutor|Vampiric Tutor|Imperial Seal|
Wheel of Fortune|Windfall|Time Spiral|Tinker|Yawgmoth's Will|Necropotence|Bazaar of Baghdad|Library of Alexandria|
Strip Mine|Wasteland|Mishra's Workshop|Tolarian Academy|Gaea's Cradle|Ancient Tomb|City of Traitors|
Urza's Saga|Karakas|Maze of Ith|Mana Confluence|City of Brass|Forbidden Orchard|Gemstone Caverns|
Underground Sea|Volcanic Island|Tropical Island|Badlands|Bayou|Plateau|Savannah|Scrubland|Taiga|Tundra|
Watery Grave|Steam Vents|Breeding Pool|Blood Crypt|Overgrown Tomb|Sacred Foundry|Temple Garden|Godless Shrine|
Hallowed Fountain|Stomping Ground|Polluted Delta|Scalding Tarn|Misty Rainforest|Verdant Catacombs|Marsh Flats|
Arid Mesa|Flooded Strand|Bloodstained Mire|Wooded Foothills|Windswept Heath|Otawara, Soaring City|
Boseiju, Who Endures|Takenuma, Abandoned Mire|Sokenzan, Crucible of Defiance|Eiganjo, Seat of the Empire|
Shelldock Isle|Mutavault|Hall of Heliod's Generosity|Prismatic Vista|Fabled Passage|
Swords to Plowshares|Path to Exile|Balance|Wrath of God|Armageddon|Ravages of War|Council's Judgment|
Oust|Containment Priest|Thalia, Guardian of Thraben|Stoneforge Mystic|Adeline, Resplendent Cathar|
Solitude|Ranger-Captain of Eos|Esper Sentinel|Mother of Runes|Ocelot Pride|Thraben Inspector|
Recruiter of the Guard|Skyclave Apparition|Palace Jailer|Restoration Angel|Elspeth, Sun's Champion|
Elspeth, Knight-Errant|Gideon Blackblade|Grand Abolisher|Flickerwisp|Leonin Relic-Warder|Spectral Procession|
Unexpectedly Absent|Enlightened Tutor|Land Tax|Sevinne's Reclamation|Portable Hole|Lingering Souls|
Monastery Mentor|Serra Ascendant|Kor Skyfisher|Seasoned Dungeoneer|Archon of Emeria|Sun Titan|Reveillark|
Jace, the Mind Sculptor|Jace, Vryn's Prodigy // Jace, Telepath Unbound|Snapcaster Mage|Brazen Borrower // Petty Theft|
Thing in the Ice // Awoken Horror|Fact or Fiction|Dig Through Time|Treasure Cruise|Gush|Frantic Search|Daze|
Remand|Memory Lapse|Mana Leak|Cryptic Command|Opposition|Control Magic|Treachery|Tolarian Terror|
Delver of Secrets // Insectile Aberration|Phantasmal Image|Thassa's Oracle|Urza, Lord High Artificer|
Hullbreacher|Displacer Kitten|True-Name Nemesis|Consecrated Sphinx|Shark Typhoon|Opt|Impulse|Intuition|
Show and Tell|Upheaval|Time Warp|Mystic Sanctuary|Repeal|Echo of Eons|Narset, Parter of Veils|
Teferi, Time Raveler|Teferi, Hero of Dominaria|Murktide Regent|Spellseeker|Hard Evidence|Psychic Frog|
Toxic Deluge|Damnation|Reanimate|Animate Dead|Entomb|Buried Alive|Exhume|Dark Ritual|Cabal Ritual|
Bloodghast|Gravecrawler|Dark Confidant|Grief|Sheoldred, the Apocalypse|Griselbrand|Archon of Cruelty|
Liliana of the Veil|Liliana, the Last Hope|Thoughtseize|Duress|Inquisition of Kozilek|Hymn to Tourach|
Bitterblossom|Night's Whisper|Sign in Blood|Fatal Push|Snuff Out|Dismember|Collective Brutality|
Phyrexian Arena|Yawgmoth, Thran Physician|Tendrils of Agony|Bone Shards|Unearth|Kitesail Freebooter|
Orcish Bowmasters|Tourach, Dread Cantor|Doomsday|Sheoldred's Edict|Troll of Khazad-dûm|Woe Strider|
Lightning Bolt|Chain Lightning|Fireblast|Burst Lightning|Fiery Confluence|Sneak Attack|Through the Breach|
Goblin Welder|Goblin Guide|Monastery Swiftspear|Young Pyromancer|Ragavan, Nimble Pilferer|
Laelia, the Blade Reforged|Fury|Inferno Titan|Pyrogoyf|Bonecrusher Giant // Stomp|Embereth Shieldbreaker // Battle Display|
Imperial Recruiter|Kiki-Jiki, Mirror Breaker|Zealous Conscripts|Goblin Rabblemaster|Hellrider|
Chandra, Torch of Defiance|Fable of the Mirror-Breaker // Reflection of Kiki-Jiki|Wheel of Misfortune|Mizzix's Mastery|
Light Up the Stage|Underworld Breach|Pyrokinesis|Abrade|Unholy Heat|Galvanic Discharge|Seasoned Pyromancer|
Glorybringer|Bloodbraid Elf|Grim Lavamancer|Magda, the Hoardmaster|
Birds of Paradise|Llanowar Elves|Elvish Mystic|Fyndhorn Elves|Noble Hierarch|Delighted Halfling|
Ignoble Hierarch|Sylvan Caryatid|Lotus Cobra|Oracle of Mul Daya|Eternal Witness|Sylvan Library|Green Sun's Zenith|
Natural Order|Survival of the Fittest|Channel|Fastbond|Oath of Druids|Craterhoof Behemoth|Primeval Titan|
Titania, Protector of Argoth|Hexdrinker|Tarmogoyf|Sakura-Tribe Elder|Wall of Roots|Rofellos, Llanowar Emissary|
Life from the Loam|Crop Rotation|Endurance|Six|Up the Beanstalk|Tamiyo's Safekeeping|Garruk Wildspeaker|
Elvish Reclaimer|Ramunap Excavator|Collected Company|Scavenging Ooze|Mox Amber|Uro, Titan of Nature's Wrath|
Oko, Thief of Crowns|Nissa, Who Shakes the World|Exploration|Utopia Sprawl|Splendid Reclamation|
Hogaak, Arisen Necropolis|Atraxa, Grand Unifier|Kolaghan's Command|Leovold, Emissary of Trest|
Dack Fayden|Saheeli, Sublime Artificer|Thief of Sanity|Fire // Ice|Expressive Iteration|Lightning Helix|
Ajani, Nacatl Pariah|Fractured Identity|Teferi, Master of Time|Abrupt Decay|Assassin's Trophy|Vindicate|
Anguished Unmaking|Kaya, Orzhov Usurper|Dreadbore|Prismatic Ending|Comet, Stellar Pup|
Wrenn and Six|Bloodsoaked Champion|Sylvan Safekeeper|Nature's Claim|Biorhythm|
Wurmcoil Engine|Myr Battlesphere|Sundering Titan|Karn, Scion of Urza|Karn, the Great Creator|Ugin, the Spirit Dragon|
Walking Ballista|Smokestack|Trinisphere|Sphere of Resistance|Thorn of Amethyst|Chalice of the Void|Null Rod|
Grafdigger's Cage|Sword of Fire and Ice|Sword of Feast and Famine|Sword of Body and Mind|Umezawa's Jitte|
Batterskull|Skullclamp|Shadowspear|Lightning Greaves|Coercive Portal|Time Vault|Voltaic Key|Memory Jar|
Mindslaver|Lodestone Golem|Kuldotha Forgemaster|Metalworker|Phyrexian Revoker|Ensnaring Bridge|
Painter's Servant|Grindstone|Bolas's Citadel|The One Ring|Portal to Phyrexia|Emry, Lurker of the Loch|
Stonecoil Serpent|Golos, Tireless Pilgrim|Retrofitter Foundry|Patchwork Automaton|Cityscape Leveler|
Kozilek, Butcher of Truth|Emrakul, the Aeons Torn|Emrakul, the Promised End|Ulamog, the Ceaseless Hunger|
Thought-Knot Seer|Reality Smasher|Eldrazi Temple|Cavern of Souls|Gilded Lotus|Coveted Jewel|Sensei's Divining Top|
Engineered Explosives|Expedition Map|Relic of Progenitus|Soul-Guide Lantern|Mishra's Bauble|Urza's Bauble|Lotus Bloom|
Mox Tantalite|Pentad Prism|Talisman of Dominance|Talisman of Creativity|Talisman of Progress|Talisman of Indulgence|
Talisman of Hierarchy|Signal Pest|Smuggler's Copter|Esika's Chariot|Shrieking Drake|Barbarian Ring|Field of the Dead
"""

# Not tournament-legal reprints (gold-bordered, 30th Anniversary): a real cube holds the originals.
NOT_REAL_PRINTINGS = {"30a", "ced", "cei", "wc97", "wc98", "wc99", "wc00", "wc01", "wc02", "wc03", "wc04"}
FILLER_SETS = ["fdn", "dsk", "blb", "otj", "mkm", "lci", "woe", "mom", "one", "dmu"]

def load_pack(path):
    oracles, printings = [], []
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if p[0] == "O":
                oracles.append({"id": p[2], "name": p[3], "norm": p[4], "type": p[5]})
            elif p[0] == "P":
                printings.append({"id": p[1], "o": int(p[2]), "set": p[3], "cn": p[4], "lang": p[5], "rarity": p[6],
                                  "fin": p[7], "rel": p[8], "img": p[9]})
    return oracles, printings

def versions_for(name, current, best_printing):
    """Snapshots oldest first, each {version, at, note, entries}; the last equals `current`. Built by undoing the
    HISTORY changes from the newest, so the diff between neighbours is exactly that step's changes."""
    first_note, steps = HISTORY.get(name, ("First list", []))
    snaps = [[list(e) for e in current]]
    for note, changes in reversed(steps):
        older = [list(e) for e in snaps[-1]]
        for board, dq, card in changes:
            p = best_printing(card)
            if p is None:
                continue
            row = next((e for e in older if e[0] == p["id"] and e[1] == board), None)
            if row is None:
                if dq < 0:
                    older.append([p["id"], board, -dq])
            else:
                row[2] -= dq
                if row[2] <= 0:
                    older.remove(row)
        snaps.append(older)
    snaps.reverse()
    if len(snaps) > 1:
        snaps[0] = [e for e in snaps[0] if e[1] != "maybe"]
    notes = [first_note] + [n for n, _ in steps]
    base = 1_760_000_000
    return [{"version": i + 1, "at": base + i * 86_400 * 9, "note": notes[i], "entries": snap} for i, snap in enumerate(snaps)]


def main(pack, prices_path, out):
    oracles, printings = load_pack(pack)
    by_norm = {}
    for i, o in enumerate(oracles):
        if "Card" in o["type"].split(" // ")[0] and o["type"].startswith("Card"):
            continue  # art-series cards share names with real ones
        by_norm.setdefault(o["norm"], i)
        # Double-faced and split cards are usually listed by their front face ("Ajani, Nacatl Pariah").
        by_norm.setdefault(norm(o["name"].split(" // ")[0]), i)
    by_oracle = {}
    for p in printings:
        by_oracle.setdefault(p["o"], []).append(p)

    def best_printing(name):
        n = norm(name)
        if n not in by_norm:
            missing.append(name)
            return None
        cands = by_oracle[by_norm[n]]
        # A plain English printing with a non-foil, from a normal set code, newest first; else anything.
        good = [p for p in cands if p["lang"] == "en" and "n" in p["fin"] and p["img"] and re.fullmatch("[a-z0-9]{3}", p["set"])
                and not p["set"].startswith("p") and p["set"] not in NOT_REAL_PRINTINGS]
        pool = good or [p for p in cands if p["lang"] == "en"] or cands
        return max(pool, key=lambda p: (p["rel"], p["set"], p["cn"]))

    missing = []
    lists, need = [], {}
    maybe_cards = []
    def use(card, qty):
        need[card] = need.get(card, 0) + qty

    for name, basic, main_, side in DECKS:
        n_main = sum(q for q, _ in main_)
        n_side = sum(q for q, _ in side)
        if n_main > 60 or n_side != 15:
            raise SystemExit(f"{name}: main {n_main}, side {n_side}")
        if n_main < 60:
            main_ = main_ + [(60 - n_main, basic)]
        entries = []
        for board, cards in (("main", main_), ("side", side)):
            for q, c in cards:
                p = best_printing(c)
                if p is None:
                    continue
                entries.append([p["id"], board, q])
                use(p["id"], q)
        for q, c in CONSIDERING.get(name, []):
            p = best_printing(c)
            if p is not None:
                entries.append([p["id"], "maybe", q])
                maybe_cards.append(p["id"])
        lists.append({"id": f"demo-deck-{norm(name).replace(' ', '-')}", "kind": "deck", "name": name, "format": "modern",
                      "entries": entries, "versions": versions_for(name, entries, best_printing)})

    if missing:
        raise SystemExit("not in catalog: " + " | ".join(missing))
    cube_names = [c.strip() for c in CUBE.replace("\n", "").split("|") if c.strip()]
    seen, cube = set(), []
    for c in cube_names:
        n = norm(c)
        if n in seen:
            continue
        seen.add(n)
        cube.append(c)
    if len(cube) < 360:
        raise SystemExit(f"cube has only {len(cube)} cards")
    found = [c for c in cube if norm(c) in by_norm]
    if len(found) < 360:
        raise SystemExit(f"cube: only {len(found)} found; missing: " + " | ".join(c for c in cube if norm(c) not in by_norm))
    cube = found[:360]
    entries = []
    for c in cube:
        p = best_printing(c)
        if p is None:
            continue
        entries.append([p["id"], "main", 1])
        use(p["id"], 1)
    for c in [x.strip() for x in CUBE_CONSIDERING.replace("\n", "").split("|") if x.strip()]:
        p = best_printing(c)
        if p is not None and p["id"] not in {e[0] for e in entries}:
            entries.append([p["id"], "maybe", 1])
            maybe_cards.append(p["id"])
    if missing:
        raise SystemExit("not in catalog: " + " | ".join(missing))
    lists.append({"id": "demo-cube-vintage", "kind": "cube", "name": "Vintage Cube", "format": "vintage", "entries": entries,
                  "versions": versions_for("Vintage Cube", entries, best_printing)})

    # Collection: exactly what the lists use, a few foils/played/Japanese copies, then bulk up to TOTAL.
    pr_by_id = {p["id"]: p for p in printings}
    items = {}
    def add(card, finish, cond, lang, qty):
        k = (card, finish, cond, lang)
        items[k] = items.get(k, 0) + qty
    for card, q in sorted(need.items()):
        p = pr_by_id[card]
        foil = "f" in p["fin"] and random.random() < 0.12
        if foil and q > 1:
            add(card, "foil", "NM", "en", 1)
            q -= 1
        cond = random.choices(["NM", "LP", "MP"], [0.85, 0.12, 0.03])[0]
        add(card, "foil" if (foil and q == 1 and "n" not in p["fin"]) else "nonfoil" if "n" in p["fin"] else "foil", cond, "en", q)
    for i, card in enumerate(sorted(set(maybe_cards))):
        if card not in need and i % 2 == 0:
            p = pr_by_id[card]
            add(card, "nonfoil" if "n" in p["fin"] else "foil", "NM", "en", 1)
    owned = sum(items.values())
    if owned > TOTAL:
        raise SystemExit(f"lists alone need {owned} cards, more than {TOTAL}")
    bulk = [p for p in printings if p["set"] in FILLER_SETS and p["lang"] == "en" and p["rarity"] in "cu" and "n" in p["fin"]
            and p["id"] not in need]
    random.shuffle(bulk)
    for p in bulk:
        if owned >= TOTAL:
            break
        q = min(random.choice([1, 1, 2, 3, 4]), TOTAL - owned)
        lang = "ja" if random.random() < 0.03 else "en"
        add(p["id"], "nonfoil", "NM", lang, q)
        owned += q

    prices = {}
    if prices_path != "-":
        prices = json.load(open(prices_path))
    def unit(card, finish, cur):
        v = prices.get(card)
        if not v:
            return 0.0
        usd, usd_foil, usd_etched, eur, eur_foil = [x or 0.0 for x in v]
        if cur == "usd":
            return usd_foil if finish == "foil" else usd_etched if finish == "etched" else usd
        return eur if finish == "nonfoil" else eur_foil

    rows = [[c, f, cond, lang, q] for (c, f, cond, lang), q in sorted(items.items())]
    oracle_of = {p["id"]: p["o"] for p in printings}
    summary = {
        "total_qty": sum(r[4] for r in rows),
        "unique_printings": len({r[0] for r in rows}),
        "unique_cards": len({oracle_of[r[0]] for r in rows}),
        "value_usd": round(sum(r[4] * unit(r[0], r[1], "usd") for r in rows), 2),
        "value_eur": round(sum(r[4] * unit(r[0], r[1], "eur") for r in rows), 2),
        "seq": len(rows),
    }
    doc = {"format": 1, "summary": summary, "items": rows, "lists": lists,
           "prices": {c: prices[c] for c in sorted({r[0] for r in rows}) if c in prices}}
    with open(out, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    print(json.dumps(summary), f"lists={[ (l['name'], sum(e[2] for e in l['entries'])) for l in lists]}", file=sys.stderr)
    print(" ".join(sorted({r[0] for r in rows})), file=open(out + ".ids", "w"))

if __name__ == "__main__":
    main(*sys.argv[1:4])

# Prices for the fixture (run in the Supabase SQL editor or via MCP with the ids from <out>.ids):
#   select jsonb_object_agg(card_id, jsonb_build_array(usd, usd_foil, usd_etched, eur, eur_foil))
#     from public.card_prices where card_id = any('{...ids...}'::uuid[]);
