"""Guess which regions could plausibly produce each of the 26 new commodities, from what the
map data says about the region - a DESIGN TABLE, not anything the game reads.

    py tools/guess_region_commodities.py             # write the CSV, print counts, run check()
    py tools/guess_region_commodities.py --selftest

Signals, each read from CA's data (see docs/TRADE_RESOURCES.md for the deposit chain):
    coastal  - the region has a 'port' slot (start_pos_region_slot_templates, Assembly Kit)
    climate  - campaign_map_settlements.climate_type
    areas    - CA's AI area groups, cai_*region_hint_(sub_)area_<x> (regions_to_region_groups)
    origin   - start_pos_regions.cultural_originator, shortened to its code (dwf, emp, cth...)
    deposits - slot_templates.resource over the region's templates
    templates - the slot template keys themselves, for landmark matches

Writes Modding Files/reference/region_commodity_guesses.csv.
"""
import collections, csv, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import survey_resource_map as srm

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Modding Files", "reference",
                   "region_commodity_guesses.csv")

OLD_WORLD_FARMLAND = {"empire", "northern_empire", "southern_empire", "eastern_empire",
                      "bretonnia", "border_princes", "eastern_border_princes",
                      "western_border_princes", "kislev", "sylvania"}
WORLDS_EDGE = {"dwarf_empire", "northern_worlds_edge_mountains", "southern_worlds_edge_mountains",
               "badlands", "darklands", "northern_darklands", "southern_darklands",
               "mountains_of_mourn", "western_mountains"}
MINED = {"res_rom_iron", "res_gems", "res_gold"}


def R(*names):
    """Named regions, matched on the key tail so one rule covers both campaigns."""
    return lambda g: g["tail"] in names


# Each rule is (commodity, test, lore). The lore line is the reason; keep it honest.
RULES = [
    ("salted_fish", lambda g: g["coastal"] and g["climate"] not in ("climate_chaotic",),
     "Any working harbour salts its catch; the daemon-tainted coasts of the Wastes excepted."),
    ("whale_oil", lambda g: g["coastal"] and (g["climate"] == "climate_frozen" or g["areas"] & {"norsca"}),
     "Norscan and northern whalers render blubber on the cold coasts."),
    ("sea_dragon_hide", lambda g: g["coastal"] and g["areas"] & {"naggarond", "northern_naggarond",
                                                                 "western_naggarond", "eastern_naggarond",
                                                                 "southern_naggarond"},
     "Druchii corsairs hunt sea dragons in the cold seas off Naggaroth for their cloaks."),
    ("rum", lambda g: g["coastal"] and (
        g["origin"] == "cst" or g["tail"] == "sartosa"
        or (g["climate"] in ("climate_jungle", "climate_island")
            and g["areas"] & {"lustria", "mangrove_coast", "southlands", "eastern_lustria", "western_lustria",
                              "isthmus_of_lustria"})),
     "Cane grows on hot coasts and is distilled in the harbours; the Vampire Coast and Sartosa run on grog."),
    ("amber", lambda g: g["coastal"] and g["areas"] & {"kislev", "norsca"},
     "Amber washes up on the Sea of Claws coasts of Kislev and Norsca."),
    ("grain", lambda g: g["climate"] == "climate_temperate" and g["areas"] & OLD_WORLD_FARMLAND,
     "The farmland of the Empire, Bretonnia, Kislev and the Border Princes feeds the Old World."),
    ("warhorses", lambda g: g["climate"] in ("climate_temperate", "climate_savannah", "climate_desert")
     and (g["areas"] & {"bretonnia", "kislev", "araby"}),
     "Bretonnian destriers, Kislevite steppe horses, Arabyan horses."),
    ("pipeweed", R("the_moot"),
     "Halfling pipeweed comes from the Moot and nowhere else."),
    ("books", R("altdorf", "nuln", "middenheim", "talabheim", "marienburg", "white_tower_of_hoeth"),
     "Printing presses and universities of the great Imperial cities; the library of the White Tower."),
    ("olive_oil", lambda g: g["origin"] == "teb" and g["climate"] in ("climate_temperate", "climate_savannah"),
     "Tilean and Estalian groves - the Southern Realms."),
    ("silk", lambda g: g["areas"] & {"cathay", "northern_cathay", "southern_cathay"}
     and g["climate"] in ("climate_temperate", "climate_jungle", "climate_savannah"),
     "Cathayan sericulture in the lowland provinces; silk is what the Ivory Road carries west."),
    ("tea", lambda g: g["areas"] & {"cathay", "northern_cathay", "southern_cathay"}
     and g["climate"] in ("climate_mountain", "climate_temperate", "climate_jungle"),
     "Tea terraces on Cathay's hills."),
    ("jade", lambda g: g["areas"] & {"cathay", "northern_cathay", "southern_cathay"}
     and g["climate"] == "climate_mountain",
     "Jade is quarried in Cathay's mountains."),
    ("coal", lambda g: "res_rom_iron" in g["deposits"]
     or (g["origin"] in ("dwf", "chd") and g["climate"] in ("climate_mountain", "climate_wasteland")),
     "Coal seams run beside iron, and every Dwarf and Chaos Dwarf hold digs its own fuel."),
    ("silver", lambda g: g["climate"] == "climate_mountain" and g["deposits"] & MINED,
     "Silver veins in mountains already mined for iron, gems or gold."),
    ("gromril", lambda g: g["origin"] == "dwf" and g["climate"] == "climate_mountain" and g["deposits"] & MINED,
     "Meteoric iron found only deep under the old Dwarf holds."),
    ("quicksilver", lambda g: g["deposits"] & {"res_gold", "res_gems", "res_obsidian"}
     and g["climate"] in ("climate_mountain", "climate_wasteland"),
     "Cinnabar forms in volcanic and ore-bearing rock beside gold and gems."),
    ("brimstone", lambda g: "res_obsidian" in g["deposits"]
     or (g["areas"] & {"darklands", "northern_darklands", "southern_darklands"}
         and g["climate"] in ("climate_wasteland", "climate_chaotic")),
     "Sulphur crusts the vents of the Dark Lands and every obsidian field."),
    ("brass", lambda g: g["origin"] == "chd" or g["tail"] == "the_copper_landing"
     or (g["areas"] & {"darklands", "northern_darklands", "southern_darklands"} and "res_rom_iron" in g["deposits"]),
     "Hashut's metal, cast in the Chaos Dwarf forges; copper from the Copper Landing."),
    ("blackpowder", lambda g: ("res_rom_lead" in g["deposits"] and g["origin"] in ("dwf", "emp", "chd", "cth"))
     or g["tail"] == "nuln",
     "Saltpetre from salt pans, worked by the gunpowder races; Nuln's Imperial Gunnery School."),
    # Ulthuan is climate_island throughout (30 of 34), never mountain - so ore, not terrain.
    ("ithilmar", lambda g: g["areas"] & {"ulthuan"} and g["deposits"] & (MINED | {"res_rom_marble"})
     or g["tail"] == "vauls_anvil_ulthuan",
     "Ithilmar is found only in Ulthuan, in the mined rock; Vaul's Anvil is where it is forged."),
    ("dragon_bone", lambda g: g["province"] == "caledor" or any("dragon" in t for t in g["templates"])
     or g["tail"] in ("dragons_death", "the_bone_gulch", "darkhold"),
     "Caledor's dragon-holds, Dragon Fang Mount, Dragonhorn Mines, and the Plain of Bones - the "
     "dragons' graveyard, where the Graves of the Dragons landmark stands."),
    ("lustrian_plumes", lambda g: g["areas"] & {"lustria", "eastern_lustria", "western_lustria",
                                                 "isthmus_of_lustria"} and g["climate"] == "climate_jungle",
     "Feathers of Lustria's jungle birds and serpents."),
    ("black_lotus", lambda g: g["climate"] == "climate_jungle" and g["areas"] & {"southlands", "southern_southlands"},
     "The poison flower of the Southlands jungles, the Witch Elves' favourite. Lustria is left to the plumes."),
    ("incense", lambda g: g["climate"] == "climate_desert" and g["areas"] & {"araby", "nehekara"},
     "Frankincense of Araby, burned in the tombs of Nehekhara."),
    ("salted_meat", lambda g: g["origin"] == "ogr" or g["areas"] & {"mountains_of_mourn"},
     "Ogre Kingdoms herds and hunting grounds - the Mountains of Mourn."),
    # second batch, 2026-10-01
    ("carpets", lambda g: g["areas"] & {"araby"},
     "Arabyan carpets, woven in the cities of Araby."),
    ("kvas", lambda g: g["areas"] & {"kislev"},
     "Kvas, the fermented rye drink of Kislev."),
    ("rhinox_hides", lambda g: g["origin"] == "ogr" or g["areas"] & {"mountains_of_mourn"},
     "Hides of the Ogre Kingdoms' rhinox herds."),
    ("mead", lambda g: g["areas"] & {"norsca"} or g["origin"] == "nor",
     "Honey mead of the Norscan halls."),
    ("glassware", lambda g: g["origin"] == "teb" or g["tail"] in ("marienburg", "lothern"),
     "Glass blown in the Tilean and Estalian cities, Marienburg's workshops, and Lothern."),
    ("wool", lambda g: g["areas"] & OLD_WORLD_FARMLAND and g["climate"] in ("climate_mountain", "climate_frozen"),
     "Sheep graze the uplands and cold hills of the Old World's farmland."),
    ("porcelain", lambda g: g["areas"] & {"cathay", "northern_cathay", "southern_cathay"}
     and g["climate"] in ("climate_temperate", "climate_savannah"),
     "Fired in the kilns of Cathay's lowland cities."),
    ("pearls", lambda g: g["coastal"] and g["climate"] in ("climate_jungle", "climate_island",
                                                         "climate_savannah", "climate_desert"),
     "Pearl divers work the warm coasts."),
    ("starwood", lambda g: g["areas"] & {"athel_loren"} and g["climate"] == "climate_magicforest",
     "Wood shed by the living trees at the heart of Athel Loren - rare, given, never cut."),
    ("feathers", lambda g: g["climate"] == "climate_mountain"
     and g["areas"] & {"bretonnia", "empire", "northern_empire", "southern_empire", "eastern_empire",
                       "western_empire", "border_princes"},
     "Griffon and pegasus feathers from the eyries of the Old World's mountains."),
    ("wyvern_scales", lambda g: g["climate"] == "climate_mountain"
     and g["areas"] & {"badlands", "mountains_of_mourn"},
     "Scales of the wyverns that nest in the Badlands and the Mountains of Mourn."),
]

# CA's own common goods, made as common as ours (2026-10-02): CA put each on only 11-13 deposits.
# Same shape as RULES; gen_resource_overhaul ships these through CA's own production effects.
CA_RULES = [
    ("salt", lambda g: g["coastal"] and g["climate"] in ("climate_temperate", "climate_savannah", "climate_desert",
                                                         "climate_island"),
     "Sea salt raked from the pans of every warm or temperate coast."),
    ("furs", lambda g: g["climate"] == "climate_frozen" or (g["climate"] == "climate_mountain" and g["origin"] == "ogr"),
     "Trappers of the frozen north - Kislev, Norsca, Naggaroth - and the Ogre hunters' mountains."),
    ("pottery", lambda g: g["climate"] not in ("climate_frozen", "climate_chaotic", "climate_mountain")
     and (g["areas"] & (OLD_WORLD_FARMLAND | {"araby"}) or g["origin"] == "teb"),
     "Clay and kilns in every lowland town of the Old World, the Southern Realms and Araby."),
    ("wine", lambda g: g["climate"] in ("climate_temperate", "climate_savannah", "climate_island")
     and (g["areas"] & {"bretonnia", "southern_empire", "border_princes", "eastern_border_princes",
                        "western_border_princes", "ulthuan"} or g["origin"] == "teb"),
     "Vineyards of Bretonnia, the southern Empire, the Border Princes, Tilea, Estalia and Ulthuan."),
]


def signals():
    """One dict per (campaign, region) with every signal the rules read."""
    sp = srm.ak("start_pos_region_slot_templates")
    tpl_res = {r["key"]: r["resource"] for r in srm.db("slot_templates_tables")}
    climate = {r["settlement_id"].split(":")[-1]: r["climate_type"] for r in srm.db("campaign_map_settlements_tables")}
    areas = collections.defaultdict(set)
    for r in srm.db("regions_to_region_groups_junctions_tables"):
        m = re.match(r"cai_(?:chaos_)?region_hint_(?:sub_)?area_(.+)$", r["region_group"])
        if m:
            areas[r["region"]].add(m.group(1))
    origin = {}
    for r in srm.ak("start_pos_regions"):
        m = re.search(r"_sc_([a-z]+)_", r["cultural_originator"])
        origin[(r["campaign"], r["region"])] = m.group(1) if m else ""
    out = {}
    for r in sp:
        key = (r["campaign"], r["region"])
        g = out.setdefault(key, {"campaign": r["campaign"], "region": r["region"],
                                 "tail": r["region"].split("_region_")[-1], "templates": set(),
                                 "coastal": False, "deposits": set()})
        g["templates"].add(r["slot_template"])
        g["coastal"] |= r["slot_type"] == "port"
        if tpl_res.get(r["slot_template"]):
            g["deposits"].add(tpl_res[r["slot_template"]])
    province = {r["region"]: r["province"].split("_province_")[-1] for r in srm.db("region_to_province_junctions_tables")}
    for key, g in out.items():
        g["province"] = province.get(g["region"], "")
        g["climate"] = climate.get(g["region"], "")
        g["areas"] = areas.get(g["region"], set())
        g["origin"] = origin.get(key, "")
    return out


def guess(g):
    return [c for c, test, _lore in RULES + CA_RULES if test(g)]


def check(sig):
    """Every icon has a rule; every rule hits something on IE and is not a blanket."""
    import gen_commodity_icons
    names = [c for c, _t, _l in RULES]
    assert sorted(names) == sorted(gen_commodity_icons.ICONS), set(names) ^ set(gen_commodity_icons.ICONS)
    ie = [g for g in sig.values() if g["campaign"] == "wh3_main_combi"]
    bad = []
    for c, test, _l in RULES + CA_RULES:
        n = sum(1 for g in ie if test(g))
        if n == 0 or n > 0.3 * len(ie):
            bad.append("%s matches %d of %d IE regions" % (c, n, len(ie)))
    # a signal that silently came back empty would zero half the rules
    # 7 IE regions have no climate row in 9.0 (dawns_light, soteks_trail, nonchang, ...) - real gaps
    assert sum(g["coastal"] for g in ie) > 100 and sum(1 for g in ie if g["climate"]) > 0.95 * len(ie), \
        "a signal failed to load"
    assert sum(1 for g in ie if g["areas"]) > 400 and sum(1 for g in ie if g["origin"]) > 500
    if bad:
        sys.exit("rules out of bounds:\n  " + "\n  ".join(bad))


def main():
    import read_vanilla_loc as loc
    names = loc.load("regions")
    sig = signals()
    check(sig)
    rows = []
    for (camp, reg), g in sorted(sig.items()):
        if camp == "wh3_main_prologue":
            continue
        rows.append({"campaign": camp, "region": names.get("regions_onscreen_" + reg, reg), "region_key": reg,
                     "province": names.get("provinces_onscreen_%s_province_%s" % (camp, g["province"]), g["province"]),
                     "coastal": "yes" if g["coastal"] else "", "climate": g["climate"].replace("climate_", ""),
                     "origin": g["origin"], "areas": " ".join(sorted(g["areas"])),
                     "deposit": " ".join(sorted(g["deposits"])), "guessed": ", ".join(guess(g))})
    with open(OUT, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    for camp in ("wh3_main_combi", "wh3_main_chaos"):
        cr = [r for r in rows if r["campaign"] == camp]
        cnt = collections.Counter(c for r in cr for c in r["guessed"].split(", ") if c)
        print("%s: %d regions, %d get at least one guess" % (camp, len(cr), sum(1 for r in cr if r["guessed"])))
        print("   " + ", ".join("%s %d" % (c, cnt[c]) for c, _t, _l in RULES + CA_RULES))
    print("wrote %s" % OUT)


def selftest():
    base = {"campaign": "wh3_main_combi", "region": "x", "tail": "x", "province": "", "templates": set(), "coastal": False,
            "deposits": set(), "climate": "climate_temperate", "areas": set(), "origin": ""}
    g = lambda **k: dict(base, **k)
    assert "salted_fish" in guess(g(coastal=True))
    assert "salted_fish" not in guess(g(coastal=True, climate="climate_chaotic"))
    assert "pipeweed" in guess(g(tail="the_moot")) and "pipeweed" not in guess(g())
    assert "gromril" in guess(g(origin="dwf", climate="climate_mountain", deposits={"res_rom_iron"}))
    assert "gromril" not in guess(g(origin="emp", climate="climate_mountain", deposits={"res_rom_iron"}))
    assert "blackpowder" in guess(g(origin="dwf", deposits={"res_rom_lead"}))
    assert guess(g(climate="climate_chaotic")) == []
    print("selftest ok")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main()
