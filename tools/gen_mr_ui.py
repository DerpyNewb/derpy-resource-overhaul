"""Derpy Resource Overhaul: the Stores panel's UI files and its script.

    py tools/gen_mr_ui.py             write the .twui.xml files and the stores script
    py tools/gen_mr_ui.py --check     exit 1 if a shipped file differs from what this builds
    py tools/gen_mr_ui.py --selftest  layout, XML and goods checks, then the Lua harness
    py tools/gen_mr_ui.py --preview   draw the layout to .skilltree_cache/ui_preview/mr_stores.png

The script ships as a generated header (DERPY_MR_STORES_L, the layout below, and
DERPY_MR_STORES_GOODS, the 54 stores) in front of the hand-written
Modding Files/source/resource_overhaul/stores_panel.lua, so every coordinate and the goods list
have one source. gen_resource_overhaul.py's write() calls write_all() and its pack() refuses a
stale() file. An unknown flag is refused: tools here have no --help.

It also writes the flows script (derpy_more_resources_flows.lua: raids, sacks, razes and trade
move stock; the history the panel charts) the same way, from
Modding Files/source/resource_overhaul/flows.lua behind DERPY_MR_FLOWS_DEFAULTS / _KIND / _GOODS,
and runs tools/_resource_overhaul_flows_harness.lua beside the panel's harness.
"""
import functools
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
SRC = os.path.join(ROOT, "Modding Files", "source", "resource_overhaul", "stores_panel.lua")
LUA_REL = "Modding Files/pack/script/campaign/mod/derpy_more_resources_stores.lua"
UI_REL = "Modding Files/pack/ui/campaign ui/"
PACK_REL = "Modding Files/pack/"
HARNESS = os.path.join(ROOT, "tools", "_resource_overhaul_stores_harness.lua")
LUA_EXE = r"C:\Program Files (x86)\Lua\5.1\lua.exe"
FLOWS_SRC = os.path.join(ROOT, "Modding Files", "source", "resource_overhaul", "flows.lua")
FLOWS_REL = "Modding Files/pack/script/campaign/mod/derpy_more_resources_flows.lua"
FLOWS_HARNESS = os.path.join(ROOT, "tools", "_resource_overhaul_flows_harness.lua")
MCT_REL = "Modding Files/pack/script/mct/settings/derpy_more_resources.lua"

# THE RATES (flows spec section 6): key, label, tooltip, min, max, default. One source for the
# flows script's defaults and the MCT sliders, so the two cannot disagree. Plain words: no "AI".
RATES = (
    ("raid", "Raid share per turn",
     "Each turn an army raids a settlement, it carries off this share of every resource the settlement "
     "keeps, into its own nearest settlement as far as that has room. 0 turns this off.", 0, 50, 10),
    ("sack", "Sack share",
     "Sacking a settlement carries off this share of every resource it keeps, into the sacker's "
     "nearest settlement as far as that has room. 0 turns this off.", 0, 100, 50),
    ("raze", "Raze share",
     "Razing a settlement carries off this share of every resource it keeps before it burns. "
     "0 turns this off.", 0, 100, 50),
    ("trade", "Trade share per turn",
     "Each turn, trade partners receive this share of removable surplus toward their capital import targets. "
     "Keep reserves and cargo already on the road are respected. The goods travel the road between the two "
     "capitals, a turn for every 40 hexes, and an army at war with the sender can seize them on the way. "
     "0 turns this off.", 0, 25, 5),
    # IMPORT DUTY (spec 2026-10-08): gold, paid to the partner, never more than the payer holds
    ("duty", "Import duty",
     "Each turn, every faction pays each trade partner this share of the value of what that partner's "
     "settlements made that turn, at the value trade agreements put on it. The gold goes to the partner. "
     "0 turns this off.", 0, 50, 10),
    # TRADE REACH (author, 2026-10-22): 40 hexes a turn (flows.lua F.ROAD_PER_TURN). No 0 = any distance:
    # a cut-off pair's search explores everything within reach, and an unbounded one the whole map.
    ("reach", "Trade reach in turns",
     "Trade agreements move resources and import duty only while the road between the two capitals takes no "
     "more than this many turns and keeps out of lands at war with, or very unfriendly to, either side. "
     "The Trade tab lists the partners cut off and why.", 1, 10, 6),
    # PHASE 5: shipments are drawn on the map, so their number is held down
    ("ships", "Shipments on the road",
     "How many shipments of yours can be on the road at once. Sending a resource between your settlements "
     "takes one to six turns, by the length of its road, and an army at war with you can seize it on the way. "
     "Other factions keep one.", 1, 10, 3),
    # THE RECRUITMENT DRAW (workshop expansion spec 2026-10-08, section 3)
    ("recruit_per", "Resources per 100 gold of a recruit",
     "How many resources a recruit takes from your stores for each 100 gold it is worth. 0 turns this off.",
     0, 5, 1),
    # TOLLS (design 2026-11-01, Part C 6.1): each toll-taker's share of a cargo's value, TOLL_MAX_PCT in all
    ("toll", "Tolls",
     "Each turn, trade that crosses another faction's lands pays that faction this share of the value of the "
     "goods it carries. All the tolls on one cargo together are at most 15%. A faction whose Roads edict is "
     "Open charges nothing. Neither do your allies and vassals. 0 turns tolls off.", 0, 10, 3),
    # BANDITS ON THE ROADS (design 2026-11-01, Part D 7.1): the chance on the most dangerous land, in 100
    ("road_danger", "Road danger",
     "How likely trouble on the road is on the most dangerous land, each turn. Half as dangerous land is half as "
     "likely. 0 turns road encounters off.", 0, 50, 20),
)
TOLL_MAX_PCT = 15   # all the tolls on one cargo together (spec 6.1)
# BANDITS ON THE ROADS (Part D 7.1-7.2). The chance of trouble in a turn is threat x road_danger in 10000;
# guards halve it. A battle's bandit army has ROAD_SIZES units: under 50 threat 5, under 70 8, else 10.
ROAD_ENCOUNTERS = ("ambush", "highwaymen", "washout")
ROAD_COOLDOWN, ROAD_AMBUSH_MIN, ROAD_AI_GUARD = 5, 30, 30
ROAD_SIZES = ((50, 5), (70, 8), (None, 10))
ROAD_GUARD_PCT, ROAD_TOLL_PCT, ROAD_WASH_PCT, ROAD_HALF_PCT = 5, 20, 10, 50
ROAD_QB_DEFAULT = "wh3_main_ogr_ogre_kingdoms_qb1"   # CA's caravans' own bandits
ROAD_QB_SC = "wh3_main_sc_ogr_ogre_kingdoms"        # theirs, and the units they are rolled from
AI_SWITCH = ("ai", "Other factions use their stores",
             "Factions no player controls raid, sack, trade, eat, recruit and gain bonuses from their "
             "stores as a player does. Off: resources move only when a player's faction is one of the "
             "two. Other factions' settlements do not eat or gain bonuses, their grain, beer and kvas do "
             "not spoil, and their recruits take nothing. Turns run faster on a slow machine.", True)
# PHASE 4 (spending spec section 2): settlements eat provisions and well-stocked stores give bonuses
UPKEEP_SWITCH = ("upkeep", "Settlements use their stores",
                 "Each turn every settlement eats provisions from its stores. Five turns of provisions left "
                 "make it Well fed; war materials and luxuries filling a quarter of one store's space give "
                 "Garrison stocked and Comforts. Off: settlements eat nothing and give no bonuses. Spoilage has "
                 "its own switch.", True)
ACTIONS_SWITCH = ("actions", "Resource Vault actions",
                  "The Resource Vault can send a resource between your settlements, buy a Festival, Muster or "
                  "Great Works with your stores, and sell what your stores hold above half their space. "
                  "Off: the panel only shows.", True)
# PHASE 6 (spending spec section 4): a full store now and then offers a choice
EVENTS_SWITCH = ("events", "Store events",
                 "Now and then a full store offers a choice: a feast, opening the stores to a besieged "
                 "garrison, a gift to a neighbour or re-arming an army. Accepting spends the resources. Other "
                 "factions make the same choices on their own. Off: no events.", True)
# PHASE 5 (spending spec section 3): a province capital pays for supplies across its province
SUPPLY_SWITCH = ("supply", "Province supplies",
                 "A province capital can pay from its stores each turn for Materials on hand, Stable stocked "
                 "and Arms stocked in every settlement you hold in its province, and can send for resources from "
                 "the province's other settlements. Off: no province supplies.", True)
RECRUIT_SWITCH = ("recruit", "Recruits use the stores",
                  "Every unit you recruit takes resources from your stores by its type and worth "
                  "(cavalry and monsters take mounts, infantry and war machines take war materials, "
                  "the finest also take your rare resource). What the stores lack is paid in your "
                  "race's own currency where it has one, then in gold. Off: recruiting takes nothing.", True)
ESCORT_SWITCH = ("escort", "Escort battles",
                 "Every shipment travels with an escort of its owner's soldiers. An army that reaches it must "
                 "beat the escort to take the cargo, and you are asked before your army attacks one. Off: an "
                 "army at war takes a shipment without a fight.", True)
# Asked for 2026-10-11, off by default: cm:toggle_dilemma_generation(false), one global switch, so
# not one dilemma at a time. Scripted dilemmas (the store events, a campaign's story) still fire.
RANDOM_SWITCH = ("random_off", "Turn off random dilemmas",
                 "Stops the game's random dilemmas, the ones that come up on their own, for every faction. "
                 "Dilemmas that a campaign's story or this mod's store events bring still come. Off: they come "
                 "as usual.", False)
PROCESSING_SWITCH = ("processing", "Additional processing batches",
    "Allow local workshops to spend stored inputs on extra batches. Passive production is unchanged. Enable individual recipes in a settlement's Stores view.", True)
SERVICES_SWITCH = ("services", "Sustained services",
    "Allow optional province services paid each turn with named goods. Enable them in the province capital's Stores view.", True)
PROVISIONS_SWITCH = ("army_provisions", "Carried army provisions",
    "Armies eat the provisions they carry once a turn. In your own settlements they refill from the stores, "
    "never below what a settlement keeps: Auto keeps 5 turns, and Load fills the army to 10. At sea, or with no "
    "settlements, Load buys two meals at 10 gold each, once a turn. Armies cannot refill in foreign lands. Missed "
    "meals slow an army and its recovery. Caravans and convoys carry none. This is fixed when a campaign starts: "
    "changing it later does nothing to a campaign already under way. In multiplayer it is always on.", True)
SPOIL_SWITCH = ("spoilage", "Spoilage",
                "Each turn, grain loses 4% and beer and kvas 2% of what a store holds above a quarter of its "
                "space. With the Great Granary, grain is safe up to half. Hardtack, salted meat, salted fish, "
                "wine and every other good never spoil. Off: nothing spoils.", True)
# TRADE EDICTS (design 2026-11-01, Part B, section 5)
EDICT_SWITCH = ("edicts", "Trade edicts",
                "Each faction sets three edicts in the Resource Vault: Rations, Workshops and Roads. Each has three "
                "choices. A change waits 10 turns before the next. Other factions choose theirs by their situation. "
                "Off: there are no edicts.", True)
# TOLLS AND BLOCKADES (design 2026-11-01, Part C, section 6)
TOLL_SWITCH = ("tolls", "Tolls and blockades",
               "Trade agreements and partner contracts pay tolls to the factions whose lands their roads cross. "
               "An army at war with either side standing within 3 hexes of the road stops that agreement's trade "
               "for the turn. Off: no tolls and no blockades.", True)
BANDIT_SWITCH = ("bandits", "Bandits on the roads",
                 "Bandits, highwaymen and washed-out roads can meet your cargo on the road. Dangerous lands meet "
                 "them more often. You choose what to do, and some choices lead to a battle. Guards on the Trade "
                 "tab make it less likely. Off: the roads are safe.", True)
SWITCHES = (PROVISIONS_SWITCH, PROCESSING_SWITCH, SERVICES_SWITCH, AI_SWITCH, UPKEEP_SWITCH, ACTIONS_SWITCH, EVENTS_SWITCH, SUPPLY_SWITCH, RECRUIT_SWITCH, ESCORT_SWITCH,
            RANDOM_SWITCH, SPOIL_SWITCH, EDICT_SWITCH, TOLL_SWITCH, BANDIT_SWITCH)
# THE THREE EDICTS: (key, name, tip, default, options); an option is (key, label, tip, bundle or None,
# the Chaos Dwarfs' tip or None). The tips are the player text that lists each option's exact effects,
# one sentence a line. The middle option is the default and changes nothing.
EDICTS = (
    ("rations", "Rations", "How much your settlements eat each turn.", "normal", (
        ("plenty", "Plenty", "Settlements eat 3 provisions a turn for each level.\nGrowth +10 in every province.",
         "derpy_mr_edict_plenty",
         "Settlements eat 3 provisions a turn for each level.\nControl +2 in every province."),
        ("normal", "Normal", "Settlements eat 2 provisions a turn for each level.", None, None),
        ("rationing", "Rationing", "Settlements eat 1 provision a turn for each level.\nControl -2 in every province.",
         "derpy_mr_edict_rationing", None))),
    ("workshops", "Workshops", "What your workshops and trade favour.", "balanced", (
        ("war", "War economy", "Workshops that make blackpowder, tools or leather make half as much again.\n"
         "Trade income -10%.", "derpy_mr_edict_war", None),
        ("balanced", "Balanced", "Workshops make their usual amounts.", None, None),
        ("merchant", "Merchant", "Trade agreements send twice their usual share.\n"
         "Recruits take a quarter more from your stores.", "derpy_mr_edict_merchant", None))),
    ("roads", "Roads", "Who may cross your lands with trade.", "tolled", (
        ("open", "Open", "Trade crossing your lands pays no tolls.\nTrade income +5%.", "derpy_mr_edict_open", None),
        ("tolled", "Tolled", "Trade crossing your lands pays you tolls.", None, None),
        ("closed", "Closed", "Other factions' trade cannot cross your lands.\nControl +1 in every province.",
         "derpy_mr_edict_closed", None))),
)
EDICT_RACE_BUNDLES = {"plenty": {"chd": "derpy_mr_edict_plenty_chd"}}   # growth does nothing for them (NO_GROWTH)
EDICT_COOLDOWN = 10                       # turns between changes of one edict; the cooldown is the price
EDICT_NEED = {"plenty": 3, "normal": 2, "rationing": 1}   # provisions a turn per settlement level
EDICT_WAR_OUTPUTS = ("blackpowder", "leather", "tools")   # War economy: processing with these outputs
EDICT_WAR_PCT = 150                       # makes half as much again, rounded down
EDICT_MERCHANT_TRADE = 2                  # Merchant: twice the MCT trade share
EDICT_MERCHANT_DRAW = 125                 # and the recruitment draw a quarter more
# a computer's rules (spec 5.4): Rationing under ration_low turns of realm food, Plenty over ration_high;
# Merchant with merchant_partners partners and no war; Closed at war with closed_wars neighbours
EDICT_AI = (("ration_low", 2), ("ration_high", 15), ("merchant_partners", 3), ("closed_wars", 2))


def _lstr(s):
    """A Lua string literal of `s`, its line breaks escaped (_lua writes them raw)."""
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def edicts_lua():
    """DERPY_MR_FLOWS_EDICTS: what the flows script's edict rules read."""
    import gen_resource_overhaul as G
    stems = {s for s, _r, _i in goods()}
    outs = {d["output"][0] for d in G.economy_definitions().values() if d.get("output") and d["kind"] == "processing"}
    for s in EDICT_WAR_OUTPUTS:
        assert s in stems and s in outs, "War economy names %s, which no processing recipe makes" % s
    keys = [o[0] for e in EDICTS for o in e[4]]
    assert len(keys) == len(set(keys)), "two edict options share a key"
    assert set(EDICT_NEED) == {o[0] for o in EDICTS[0][4]}, "a ration with no meal size"
    parts = ['order = {%s}' % ", ".join('"%s"' % e[0] for e in EDICTS)]
    for k, _n, _t, d, opts in EDICTS:
        assert d in [o[0] for o in opts] and [o for o in opts if o[0] == d][0][3] is None, "default %s has a bundle" % d
        parts.append('%s = {default = "%s", options = {%s}}' % (k, d, ", ".join('"%s"' % o[0] for o in opts)))
    parts += ["cooldown = %d" % EDICT_COOLDOWN,
              "need = {%s}" % ", ".join("%s = %d" % kv for kv in sorted(EDICT_NEED.items())),
              "war_outputs = {%s}" % ", ".join("%s = true" % s for s in EDICT_WAR_OUTPUTS),
              "war_pct = %d" % EDICT_WAR_PCT, "merchant_trade = %d" % EDICT_MERCHANT_TRADE,
              "merchant_draw = %d" % EDICT_MERCHANT_DRAW,
              "bundles = {%s}" % ", ".join('%s = "%s"' % (o[0], o[3]) for e in EDICTS for o in e[4] if o[3]),
              "race_bundles = {%s}" % ", ".join("%s = {%s}" % (o, ", ".join('%s = "%s"' % kv for kv in sorted(r.items())))
                                                for o, r in sorted(EDICT_RACE_BUNDLES.items())),
              "ai = {%s}" % ", ".join("%s = %d" % kv for kv in EDICT_AI)]
    return "DERPY_MR_FLOWS_EDICTS = {%s}" % ", ".join(parts)
# SPOILAGE (design 2026-11-01, Part A, section 4): the rate in 100 lost each turn on what a store
# holds above SPOIL_SAFE_PCT of its space; the Great Granary (a lasting work) raises Grain's to
# SPOIL_GRANARY_PCT. Every other good keeps.
SPOIL_RATES = {"grain": 4, "beer": 2, "kvas": 2}
SPOIL_SAFE_PCT = 25
SPOIL_GRANARY_PCT = 50
SPOIL_GRANARY_GOOD = "grain"
# the Great Granary, and the Chaos Dwarfs' own (which feeds captives instead of growth): both keep grain
SPOIL_GRANARY_WORKS = ("last_granary", "last_granary_chd")
# THE RECRUITMENT DRAW (workshop expansion spec 2026-10-08, section 3): what a recruited unit draws
# from the stores, by CA's caste (main_units.caste), per RECRUIT_PER gold of its value. Lords,
# heroes and `generic` draw nothing. check_recruit() holds every key to CA's DB.
RECRUIT_PER, RECRUIT_ELITE, RECRUIT_ELITE_PER, RECRUIT_GOLD_X = 100, 1200, 400, 2
CASTE_DRAW = {
    "melee_infantry": [("war", 1)], "missile_infantry": [("war", 1)],
    "monstrous_infantry": [("war", 1.5)],
    "melee_cavalry": [("mounts", 1)], "missile_cavalry": [("mounts", 1)], "chariot": [("mounts", 1)],
    "monstrous_cavalry": [("mounts", 1.5)], "war_beast": [("mounts", 1.5)], "monster": [("mounts", 1.5)],
    "warmachine": [("war", 0.5), ("building", 0.5)],
}
INFANTRY_CASTES = ("melee_infantry", "missile_infantry", "monstrous_infantry")
# an elite's rare good, lore-led (author's rule: a race without the lore basis goes without)
RACE_RARE = {"dwf": "gromril", "hef": "ithilmar", "def": "sea_dragon_hide", "skv": "black_lotus",
             "wef": "starwood", "brt": "feathers", "emp": "feathers", "grn": "wyvern_scales",
             "ogr": "wyvern_scales", "chd": "dragon_bone"}
RACE_RARE_INF = {"def": "black_lotus"}
# the shortfall, in the race's own CA currency: `per` missing goods cost one of it, then gold at
# RECRUIT_GOLD_X x CA's trade value. First values, tuned in game. Tomb Kings and Khorne are in
# NO_STORES: they keep no stores, so they never draw, and a currency charge would be a tax with no
# stores behind it. Ogre Meat is held per army (scope MILITARY_FORCE), out of
# cm:faction_add_pooled_resource's reach, so Ogres pay gold.
CURRENCY = {
    "chd": {"pool": "wh3_dlc23_chd_armaments", "per": 2, "word": "Armaments",
            "line": "The forges took %d %s in place of what the stores lacked."},
    # Food caps at 100 and CA grants 3-5 at a time: one per 5 goods, so a recruit cannot empty it
    "skv": {"pool": "skaven_food", "per": 5, "word": "Food",
            "line": "The warrens gave up %d %s in place of what the stores lacked."},
}
# THE FIVE USES (spending spec section 1): every store has exactly one; check_uses() asserts it.
USES = {
    "provisions": ("grain", "salted_fish", "salted_meat", "olive_oil", "tea", "kvas", "mead", "rum", "beer",
                   "wine", "spices", "salt", "medicine", "hardtack"),
    "building": ("timber", "marble", "pottery", "glassware", "starwood", "cloth", "tools"),
    "war": ("iron", "coal", "brass", "blackpowder", "brimstone", "gromril", "ithilmar", "quicksilver",
            "obsidian", "whale_oil", "leather"),
    "mounts": ("warhorses", "feathers", "rhinox_hides", "wyvern_scales", "dragon_bone", "sea_dragon_hide",
               "animals", "tusks", "furs"),
    "luxuries": ("silk", "jade", "carpets", "porcelain", "pearls", "amber", "lustrian_plumes", "incense",
                 "black_lotus", "pipeweed", "books", "gems", "gold_idols", "dyes", "trinkets", "silver", "wool"),
}
# THE WORKSHOP'S PRICE CELL: one icon per use the bulk is drawn from, CA's own bundle glyphs
USE_ICON = {"war": "weapon_damage.png", "mounts": "mount.png", "building": "construction.png",
            "luxuries": "public_order_jubilant.png", "provisions": "growth.png"}
# THE WORKSHOP'S PURCHASE SOUNDS, one per kind, every one an event in CA's registry (checked)
WORK_SOUND = {"item": "UI_CLICK_Craft_Item", "unit": "UI_CAM_DWF_BookOfGrudges_Purchase_Unit",
              "upgrade": "UI_CLICK_Building_Upgrade", "research": "UI_CLICK_Upgrade_Technology",
              # the named recipes (spec section 4): CA's own events again, by what the work is like
              "convert": "UI_CLICK_Craft_Item", "army": "UI_CAM_DWF_BookOfGrudges_Purchase_Unit",
              "trait": "UI_CLICK_Upgrade_Technology", "lasting": "UI_CLICK_Building_Upgrade"}
# WHO HAS NO STORES TO USE: the subculture tokens whose buildings make nothing
# (gen_resource_overhaul.EXCLUDE); check_uses() asserts the two lists agree.
NO_STORES = ("dae", "kho", "nur", "sla", "tze", "tmb", "nag", "bst")
# Which factor each kind of move books to: the junction is derpy_mr_store_<stem>_<kind>.
FLOW_KIND = {"process": "processed", "raid": "raided", "sack": "plundered", "raze": "plundered", "trade": "traded", "eat": "eaten",
             "move": "moved", "spend": "spent", "sell": "sold", "spoil": "spoiled"}
# PHASE 7: gold a unit when the Zharr Exchange is not there to price it (spending spec section 5)
SELL_RATE = {"provisions": 1, "building": 2, "war": 3, "mounts": 4, "luxuries": 5}
# ESCORT BATTLES (spec 2026-10-09): a cart's escort, rolled when it leaves. Units by the cargo's
# value at SELL_RATE (not the Exchange's market, so another mod cannot change it), CA's power rule
# from the Nagash battle (turn / ESCORT_TURNS, 1-10). CA's own random-army templates by subculture;
# the Border Princes field the Empire's units in CA's own rosters; Cathay has no CA template and
# gets ours. A subculture in neither has no escort, and its carts are taken without a fight.
ESCORT_PER, ESCORT_MIN, ESCORT_MAX, ESCORT_TURNS = 40, 4, 12, 10
ESCORT_OWN_KEY = "derpy_mr_escort_cth"
ESCORT_ALIAS = {"wh_main_sc_teb_teb": "wh_main_sc_emp_empire"}
ESCORT_OWN_SC = "wh3_main_sc_cth_cathay"
ESCORT_OWN = (   # (unit, weight, tier): CA's tiers, weighted as its templates are
    ("wh3_main_cth_inf_peasant_spearmen_1", 12, "low"), ("wh3_main_cth_inf_peasant_archers_0", 10, "low"),
    ("wh3_main_cth_inf_jade_warriors_0", 8, "low"), ("wh3_main_cth_inf_jade_warrior_crossbowmen_0", 6, "low"),
    ("wh3_main_cth_cav_peasant_horsemen_0", 4, "low"),
    ("wh3_main_cth_inf_jade_warriors_1", 4, "mid"), ("wh3_main_cth_inf_jade_warrior_crossbowmen_1", 3, "mid"),
    ("wh3_main_cth_inf_iron_hail_gunners_0", 3, "mid"), ("wh3_main_cth_cav_jade_lancers_0", 3, "mid"),
    ("wh3_main_cth_art_grand_cannon_0", 2, "mid"),
    ("wh3_main_cth_inf_dragon_guard_0", 3, "high"), ("wh3_main_cth_inf_dragon_guard_crossbowmen_0", 2, "high"),
    ("wh3_main_cth_inf_crane_gunners_0", 2, "high"), ("wh3_main_cth_cav_jade_longma_riders_0", 2, "high"),
    ("wh3_main_cth_art_fire_rain_rocket_battery_0", 1, "high"),
)
CA_ARMIES = os.path.join(ROOT, "Modding Files", "reference", "ca_scripts_wh3", "campaign",
                         "wh2_campaign_random_armies.lua")

# THE LAYOUT, in panel coordinates: (x, y, w, h). The Lua MoveTo's every component from these;
# the .twui.xml sizes are the same numbers. cols are (x, w) inside a row, which starts at list x.
L = {
    # THE TABLE'S BORDER, this thick, and a section row's fold arrow, this square (in the icon slot)
    "FRAME": 2, "FOLD": 24,
    "W": 860, "H": 640, "PITCH": 28, "ROWS": 16, "SLIDER_W": 18, "HANDLE_H": 40,
    # THE SLIDER IS THE ZHARR EXCHANGE'S (asked 2026-10-04): CA's event message slider, an 18px
    # handle column with a frame cap and an arrow in SLIDER_CAP at each end, outside the track.
    # SLIDER_PARTS: where each end part sits from the track's top-left, the two bottoms from the
    # track's END - measured off CA's art (gen_guilds_ui.CA_SLIDER), because docking is ignored.
    "SLIDER_CAP": 24,
    "SLIDER_PARTS": (("frame_top", -1, -24), ("frame_bottom", -1, 0), ("top", 1, -23), ("bottom", 1, -1)),
    "BUTTON": 48, "GAP": 4,
    "title": (20, 14, 500, 28), "close": (818, 12, 30, 30),
    # A RULE BETWEEN THE TITLE AND THE TABS (asked for 2026-10-02): the two read as one block
    # without it.
    "title_rule": (20, 46, 820, 2),
    # SEVEN TABS, 4 apart and clear of Back at 720 (Production made seven, 2026-10-30). Six at 112
    # left no room, so each is sized to its label: CHAR_W a letter and 10 a side on CA's drawn
    # face (BTN_FACE), at least 80. check_button_faces() holds each label to its tab.
    "tab_goods": (20, 56, 99, 26), "tab_settlements": (123, 56, 116, 26),
    "tab_trade": (243, 56, 80, 26), "tab_spending": (327, 56, 91, 26), "tab_map": (422, 56, 80, 26),
    "tab_workshop": (506, 56, 91, 26), "tab_production": (601, 56, 107, 26),
    # THE MAP TAB: the list's own box, a pad inside it, and no picture of the map - it is framed on
    # the dots it draws, so it fits any campaign. A capital's dot is larger and named; a convoy is
    # CA's convoy icon. The roads are the 3D map's (terrain_routes.lua), in its palette's MAP_PATH_COLOURS
    # colours (four a colour set, the player's MCT choice), at most MAP_PATH_MAX dots, each MAP_PATH across with its 1px dark rim. MAP_MIN_SPAN
    # keeps one lone settlement from being blown up to fill the box.
    "map": (20, 142, 820, 448), "MAP_PAD": 24, "MAP_DOT": 20, "MAP_CAP": 26, "MAP_PATH": 6,
    "MAP_PATH_MAX": 400, "MAP_PATH_COLOURS": 16, "MAP_CART_SIZE": 28, "MAP_MIN_SPAN": 40, "map_label": (160, 16),
    # ON CA'S MINIMAP (one pixel to one logical unit): never closer than MAP_ART_ZOOM, past which
    # the picture is a blur. MAP_CHAR_W is a name's width per letter at 11px, for spacing names.
    "MAP_ART_ZOOM": 2, "MAP_CHAR_W": 6.5,
    # CHAR_W: body_12's flat glyph width, for the line-fit rules here and in the panel (S.last_line)
    "CHAR_W": 7,
    # A ROW'S THREE POLICY BUTTONS: the stock rules' widths (the trade_focus columns), and an edict
    # choice's on the Resources tab, where columns 3-5 are 100, 110 and 240 wide (Part B)
    "POLICY_W": (90, 130, 114), "EDICT_W": 100,
    # ZOOM (asked 2026-10-04): round + and - buttons on the map's bottom-right corner (CA's small
    # round button, the Close button's art; CA ships no minus icon, so both are text), a step of
    # MAP_ZOOM_STEP around the spot in the middle of the box. Closest: MAP_ZOOM_MAX pixels per picture pixel (the
    # plain map: MAP_ZOOM_MAX times its first framing). Farthest: the whole picture, still covering
    # the box (the plain map: its first framing). No wheel: no mouse-wheel event reaches script.
    "MAP_ZOOM_STEP": 1.5, "MAP_ZOOM_MAX": 3,
    "zoom_in": (800, 516, 30, 30), "zoom_out": (800, 550, 30, 30),
    # THE FRAME REACHES THIS FAR PAST THE MAP'S BOX on every side: CA's panel_back_border.png draws
    # its copper line from its 4th pixel in, so a frame on the box left the map showing outside the
    # line (seen in game 2026-10-04). The box cuts off the clear 4px. check_map_frame() measures it.
    "MAP_FRAME_OUT": 4,
    # THE MAP'S KEY on the bottom line, left of the zoom buttons: CA's icon, then its name
    "map_key": {"cap": ((20, 600, 26, 26), (50, 602, 120, 22)),
                "town": ((180, 603, 20, 20), (204, 602, 80, 22)),
                "cart": ((294, 599, 28, 28), (326, 602, 100, 22))},
    # CA's own map markers (asked 2026-10-03: "the icons can be settlement icons"): the 24px
    # castle CA marks a settlement with, and its ringed capital marker for a province capital
    "MAP_TOWN_ICON": "ui/skins/default/icon_marker_settlement.png",
    "MAP_CAP_ICON": "ui/skins/default/icon_offscreen_capital.png",
    # the Spending tab: a supply's box and the icon of the good it pays with, this far apart
    "PAY_GAP": 4,
    # A SHIPMENT'S ESCORT (escort battles, spec 2026-10-09): CA's unit cards at their own 60x130, one
    # per unit and CARD_GAP apart as CA's army strip, under a line saying what the escort does
    "cards": (28, 214, 812, 130), "CARD_W": 60, "CARD_H": 130, "CARD_GAP": 8, "CARDS": ESCORT_MAX,
    "escort_line": (28, 150, 804, 50),
    "MAP_CART": "ui/campaign ui/effect_bundles/convoy_icon.png",
    # the Trade tab's two checkboxes a row, square, centred in the Exports and Imports columns
    "CHECK": 26,
    "back": (720, 56, 120, 26), "sub_title": (20, 90, 820, 22), "head_y": 116,
    # THE HINT SHARES THE SUB-TITLE'S LINE, right-aligned, so the bottom line is the buttons'
    "list": (20, 142, 820, 448), "empty": (20, 154, 820, 60), "hint": (20, 90, 820, 22),
    # THE BOTTOM LINE'S FOUR BUTTON SLOTS, the first's box, then BULK_GAP apart across the full
    # width: the Trade tab's all-at-once buttons, the orders (slots 2-4) and Sell (slot 4).
    # Sized to CA's art's drawn face (BTN_FACE), not its component.
    "bulk": (20, 598, 200, 30), "BULK_GAP": 6,
    # PHASE 7: a settlement drill-down row's Send here button, in the fifth column
    "send": (130, 26),
    "icon": (6, 2, 24, 24),
    # A SETTLEMENTS ROW SHOWS UP TO ICONS GOODS before its name, ICON_PITCH apart; the name moves
    # right past them. ponytail: a long name with four icons runs toward the Level column, whose
    # right-aligned digits leave room; measure in game if one collides.
    "ICONS": 4, "ICON_PITCH": 26,
    # THE USING COLUMN (phase 4): up to USING bundle icons in a Settlements row's third column
    "USING": 4,
    # A NAMED RECIPE'S PRICE (workshop expansion spec section 4): up to four goods from the Workshop's
    # column 3, each its icon then its amount, PRICE_PITCH apart; the amounts are the pn cells
    "PRICE_PITCH": 50,
    # THE CHART (flows spec section 7), on a good's drill-down only: the list drops to CHART_ROWS
    # and twenty bars stand on one baseline under it.
    "CHART_ROWS": 9, "BARS": 20, "BAR_W": 33, "BAR_PITCH": 41, "BAR_MIN": 2,
    "chart_top": (20, 400, 300, 18), "bars": (20, 420, 820, 120),
    "chart_from": (20, 542, 200, 18), "chart_to": (640, 542, 200, 18),
    # THE CHART'S BASELINE, under the bars (asked for polish 2026-10-04). The bars stand at the
    # RIGHT, newest last, so the latest turn is always over "Turn N"; chart_from moves under the
    # first bar and is dropped where it would meet chart_to.
    "chart_base": (20, 540, 820, 1),
    # and a fainter line at the top value, which ties chart_top's figure to the bars it measures
    "chart_grid": (20, 420, 820, 1),
    "chart_line": (20, 564, 820, 22),
    # EACH VIEW HAS ITS OWN COLUMNS (x, w, align) inside a row: sized to what they hold and
    # aligned to it - words left, numbers right, ticks centred. One set for every view left the
    # Trade tab's ticks under right-aligned headers and "Space per good" squeezed into 100px.
    # "focus" is both drill-downs, a good's and a settlement's: the same five columns.
    "VIEWS": {
        # column 2 is 96 wide for an edict's "Wait 10 turns" (Part B); 3-5 hold its three buttons
        "goods": ((36, 204, "left"), (244, 96, "right"), (344, 100, "right"), (448, 110, "right"),
                  (562, 234, "right")),
        "focus": ((36, 230, "left"), (276, 120, "right"), (406, 90, "right"), (506, 80, "right"),
                  (596, 204, "left")),
        "settlements": ((36, 230, "left"), (276, 46, "right"), (330, 90, "left"), (430, 80, "right"),
                        (520, 280, "right")),
        "trade_focus": ((36, 240, "left"), (286, 150, "left"), (446, 90, "centre"), (546, 130, "centre"), (686, 114, "centre")),
        "trade": ((36, 230, "left"), (276, 60, "right"), (346, 90, "centre"), (446, 90, "centre"),
                  (546, 254, "left")),
        # the Spending tab: a capital's four supply boxes in 2-5; a shipment's from, to and turn in
        # 2-4 and its Show button in 5
        "spending": ((36, 230, "left"), (276, 126, "centre"), (408, 126, "centre"), (540, 126, "centre"),
                     (672, 128, "centre")),
        # the Workshop: name, what it gives, the rare good's price and the bulk's, each after its
        # icon (rc.lead), Buy in 5
        "workshop": ((36, 210, "left"), (252, 200, "left"), (458, 100, "left"), (564, 98, "left"),
                     (668, 132, "left")),
        # an upgrade's settlements, Buy here in 5
        "workshop_focus": ((36, 300, "left"), (344, 120, "left"), (472, 100, "left"), (580, 60, "left"),
                           (668, 132, "left")),
        # the Production tab: a recipe's settlement, what it gives after its icon, its inputs as the
        # Workshop's price strip from column 3, the state, Enable/Pause in 5
        "production": ((36, 200, "left"), (240, 150, "left"), (394, 150, "left"), (550, 110, "left"),
                       (668, 132, "left")),
        # no list on the Map tab: the Resources tab's columns, for headers it leaves blank
        "map": ((36, 204, "left"), (244, 90, "right"), (338, 100, "right"), (442, 110, "right"),
                (556, 240, "right")),
    },
    # ponytail: a flat glyph width for a size-12 header, calibrated from the one seen squeezed in
    # game (14 letters in 100px). The harness checks every view's headers against it.
    "HEAD_CHAR_W": 8,
}
COLS = L["VIEWS"]["goods"]      # what the .twui.xml is built with; the Lua resizes per view

# CA's own icon for each of its 17 goods (the Exchange's EX.INFO). Five filenames do not match
# the good: res_rom_lead is Salt, res_rom_glass is Dwarf Beer, res_rom_textiles is Pottery.
CA_ICONS = {
    "res_animals": "resource_animals", "res_dyes": "resource_dyes", "res_gems": "resource_gemstones",
    "res_gold_idols": "resource_gold_idols", "res_ivory": "resource_ivory",
    "res_medicine": "resource_medicine", "res_obsidian": "resource_obsidian",
    "res_rom_furs": "resource_furs", "res_rom_glass": "resource_dwarf_beer",
    "res_rom_iron": "resource_iron", "res_rom_lead": "resource_salt",
    "res_rom_marble": "resource_marble", "res_rom_textiles": "resource_pottery",
    "res_rom_timber": "resource_timber", "res_rom_wine": "resource_wine",
    "res_spices": "resource_spices", "res_trinkets": "resource_trinkets",
}
ICON_DIR = "ui/campaign ui/effect_bundles/"

# Art, all CA's and all checked by check_xml() against the game's ui packs.
PANEL_LAYERS = [   # CA's panel_frame recipe, as the Exchange's (gen_exchange_ui.PANEL_LAYERS)
    {"path": "ui/skins/default/panel_back_tile.png",
     "offset": (0, 0), "dw": 0, "dh": 0, "margin": 5, "tile": True, "dock": None},
    {"path": "ui/skins/default/panel_back_border.png",
     "offset": (0, 0), "dw": 0, "dh": 0, "margin": 30, "tile": True, "dock": None},
]
OPENER_ICON = "ui/campaign ui/technologies/wh2_hef_tech_marble_stockpiles.png"
BTN_BG = "ui/skins/default/button_square_large_text_active.png"
BTN_HOVER = "ui/skins/default/button_square_large_text_hover.png"
WHITE = "ui/skins/default/1x1_blank_white.png"
DIVIDER_COLOUR = "#6B583680"
# THE TABLE'S EDGE: the divider's own colour at full strength, so the frame reads before the grid
FRAME_COLOUR = "#6B5836FF"
# a foldable section's arrow: CA's bronze one, drawn pointing down; the Lua turns it right when folded
FOLD_ARROW = "ui/skins/default/icon_arrow_down.png"
GRID_COLOUR = "#6B583640"         # the chart's top line: the divider at half its strength
ICON_BG = "ui/campaign ui/effect_bundles/resource_gold.png"
SLIDER_TRACK = "ui/skins/default/slider_vertical_mid.png"
SLIDER_HANDLE = "ui/skins/default/slider_vertical_handle.png"
SLIDER_HANDLE_UNDER = "ui/skins/default/slider_vertical_handle_underlay.png"
# CA's slider end parts and the handle's 9-slice, ported from gen_guilds_ui (SLIDER_ART, CA_SLIDER)
# by hand: two mods that ship apart do not share a code path that changes what they emit.
SLIDER_ART = {
    "frame_top": "ui/skins/default/slider_vertical_top.png",
    "frame_bottom": "ui/skins/default/slider_vertical_bottom.png",
    "top": ("ui/skins/default/slider_vertical_top_active.png",
            "ui/skins/default/slider_vertical_top_hover.png"),
    "bottom": ("ui/skins/default/slider_vertical_bottom_active.png",
               "ui/skins/default/slider_vertical_bottom_hover.png"),
}
SLIDER_ROD_X, SLIDER_ROD_W, HANDLE_MIN, HANDLE_SLICE = 6, 6, 39, 17
SND_SLIDER_HANDLE, SND_SLIDER_ARROWS = "UI_GBL_TMP_Slider_Handle", "UI_GBL_TMP_Slider_Arrows"
SND_OPEN = "UI_GBL_TMP_Round_Medium_Button"
SND_SMALL = "UI_GBL_TMP_Round_Small_Button"
MUTED = "#C8B48CFF"
BAR_COLOUR = "#C8A060DD"
ALIGN = ("Left", "Right", "Right", "Right", "Right")
# CA's checkbox art: ticked is allowed, empty is stopped. The Lua swaps 0 and 1 as the tabs do.
CHECK_ON, CHECK_ON_HOVER = "ui/skins/default/checkbox_selected.png", "ui/skins/default/checkbox_selected_hover.png"
BAND_COLOUR = "#FFFFFF10"        # every other row, so a wide row is easy to follow across
SECTION_COLOUR = "#3A2C1ECC"     # the band under "Goods you do not have"
TIP_OPEN = "Resource Vault||What each of your settlements keeps of every resource, and how fast it fills."


# MCT "Panel size" (author, 2026-11-02: "UI size options, same as the derpy great guilds mod"): Small /
# Medium / Large, as gen_guilds_ui.SIZES. No call changes a font, and font_scale stretches the glyphs
# it already drew (soft text in game, Great Guilds 2026-10-08), so each size is a whole second set of
# .twui.xml: every length scaled and every font one real step along CA's body list. Medium is the
# original files, no suffix. The stores script gets each size's factor, suffix and layout from
# DERPY_MR_STORES_SIZES (header()), so nothing here is typed twice.
# suffix -> (num, den, GUID letter in place of MR's R, font map)
SIZES = {
    "_sm": (6, 7, "S", {"body_10": "body_10", "body_12": "body_10", "body_16": "body_12"}),
    "_lg": (4, 3, "L", {"body_10": "body_12", "body_12": "body_16", "body_16": "body_16"}),
}
SIZE_NAME = {"_sm": "small", "": "medium", "_lg": "large"}
# THE OPENER IS ON CA'S HUD, beside the resource strip, so it keeps CA's size at every panel size
UNSIZED_FILES = ("derpy_mr_stores_button",)
# Layout entries that are not lengths on screen: counts, ratios, map units, and MAP_FRAME_OUT, which is
# pixels of CA's border art: a 9-slice draws its edges at the art's own size at every box size, so its
# copper line starts 4px in at Small and Large too (check_map_frame), and 3 left the map showing past it
UNSCALED = ("ROWS", "CHART_ROWS", "ICONS", "USING", "BARS", "CARDS", "MAP_PATH_MAX", "MAP_PATH_COLOURS",
            "MAP_MIN_SPAN", "MAP_ART_ZOOM", "MAP_ZOOM_STEP", "MAP_ZOOM_MAX", "MAP_FRAME_OUT")
# A LETTER'S WIDTH follows its font, not its box: the map's names stay body_10 at Small
GLYPH_FONT = {"CHAR_W": "body_12", "HEAD_CHAR_W": "body_12", "MAP_CHAR_W": "body_10"}
SIZE_OPTION = ("ui_size", "Panel size",
               "Sets the size of the Resource Vault and its text. The new size shows the next time you open "
               "the Vault. On a screen larger than 1080p the Vault grows to fit and some sizes look the same.")
SIZE_VALUES = (("small", "Small", "A seventh smaller than Medium."), ("medium", "Medium", "The standard size."),
               ("large", "Large", "A third larger than Medium."))


def _pt(font):
    return int(re.search(r"\d+", font).group())


def _z(v, n, d):
    """A length at n/d, rounded as the stores script's S.px: half away from zero."""
    return int(v * n / float(d) + 0.5) if v >= 0 else -int(-v * n / float(d) + 0.5)


def scaled_layout(sfx):
    """L at a size: every length scaled, counts and ratios kept, a letter's width by its font."""
    n, d, _g, fonts = SIZES[sfx]

    def walk(v):
        if isinstance(v, (bool, str)):
            return v
        if isinstance(v, (int, float)):
            return _z(v, n, d)
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        return type(v)(walk(x) for x in v)
    out = {}
    for k, v in L.items():
        if k in UNSCALED:
            out[k] = v
        elif k in GLYPH_FONT:
            f = GLYPH_FONT[k]
            out[k] = round(v * _pt(fonts[f]) / float(_pt(f)), 3)
        else:
            out[k] = walk(v)
    return out


def sized(root, sfx):
    """A builder's tree at another size: boxes, layer offsets, text insets, list columns, fonts.
    9-slice margins are texture pixels and stay as they are."""
    import gen_mr_emitter as E
    n, d, _g, fonts = SIZES[sfx]

    def z(v):
        return _z(v, n, d)
    for c in root.walk():
        c.w, c.h = z(c.w), z(c.h)
        kw = c.kw
        for key in ("layers", "hover"):
            if kw.get(key):
                kw[key] = [dict(lay, offset=tuple(float(v) * n / d for v in lay.get("offset", (0, 0))),
                                dw=z(lay.get("dw", 0)), dh=z(lay.get("dh", 0))) for lay in kw[key]]
        if kw.get("text"):
            for k in ("tx", "ty"):
                if k in kw:
                    kw[k] = ",".join("%.2f" % (float(v) * n / d) for v in kw[k].split(","))
            kw["fontcat"] = fonts[E.fontcat(kw)]
            kw["size"] = z(kw.get("size", 12))
        le = kw.get("layoutengine")
        if le and le.get("columns"):
            kw["layoutengine"] = dict(le, columns=[z(v) for v in le["columns"]])
    return root


_SIZING = [""]    # the SIZES suffix the builders are drawing at: "" is Medium


def _emit(root, prefix, comment):
    """A builder's tree as XML, at the size being built: GUIDs MR.. at Medium, MS.. and ML.. off it."""
    import gen_mr_emitter as E
    sfx = _SIZING[0]
    if sfx:
        sized(root, sfx)
        prefix = "M" + SIZES[sfx][2] + prefix[2:]
        comment += " At %s size, %d/%d." % (SIZE_NAME[sfx], SIZES[sfx][0], SIZES[sfx][1])
    E.assign(root, prefix)
    return E.layout(root, comment)


def build_at(build, sfx):
    _SIZING[0] = sfx
    try:
        return build()
    finally:
        _SIZING[0] = ""


def _flat(path, colour=None, offset=(0, 0), dw=0, dh=0, dock=None):
    return {"path": path, "offset": offset, "dw": dw, "dh": dh, "margin": 0, "dock": dock,
            "colour": colour}


def _round(state, icon, inset, size):
    under = "small" if size == "small" else "medium"
    out = [_flat("ui/skins/default/button_round_%s_%s.png" % (under, state))]
    if size != "small":
        out.insert(0, _flat("ui/skins/default/button_round_medium_underlay.png"))
    out.append(_flat(icon, offset=(inset, inset), dw=-2 * inset, dh=-2 * inset, dock="Center"))
    return out


def _cell(E, name, w, h, **kw):
    return E.C(name, w, h, text=True, tx="0.00,0.00", ty="0.00,0.00", **kw)


def build_panel():
    import gen_mr_emitter as E
    root = E.C("root", L["W"], L["H"])
    p = root.add(E.C("derpy_mr_stores_panel", L["W"], L["H"], layers=PANEL_LAYERS, priority=60))
    p.add(_cell(E, "title_text", L["title"][2], L["title"][3], size=16))
    p.add(E.C("title_rule", L["title_rule"][2], L["title_rule"][3], image=WHITE,
              colour_img=DIVIDER_COLOUR))
    p.add(E.C("derpy_mr_close", 30, 30, interactive=True, sound=SND_SMALL, tooltip="Close",
              layers=_round("active", "ui/skins/default/icon_cross_small.png", 5, "small"),
              hover=_round("hover", "ui/skins/default/icon_cross_small.png", 5, "small")))
    for name, box, tip in (
            ("derpy_mr_tab_goods", L["tab_goods"], "Resources||Every resource your settlements keep."),
            ("derpy_mr_tab_settlements", L["tab_settlements"],
             "Settlements||Every settlement you hold, and its stores."),
            ("derpy_mr_tab_trade", L["tab_trade"],
             "Trade||Choose which resources your settlements send and take by trade."),
            ("derpy_mr_tab_spending", L["tab_spending"],
             "Spending||What your stores pay for: province supplies, shipments on the road, orders, recruits and import duty."),
            ("derpy_mr_tab_map", L["tab_map"], "Map||Where your settlements and convoys are."),
            ("derpy_mr_tab_workshop", L["tab_workshop"],
             "Workshop||Spend your stores on items, units, settlement upgrades, research and works for "
             "your armies and characters."),
            ("derpy_mr_tab_production", L["tab_production"],
             "Production||What your settlements can make from their stores, where, and what each is short of."),
            ("derpy_mr_back", L["back"], "Back to the full list.")):
        p.add(_cell(E, name, box[2], box[3], interactive=True, image=BTN_BG,
                    hover=[_flat(BTN_HOVER)], sound=SND_SMALL, align="Center", tooltip=tip))
    p.add(_cell(E, "sub_title", L["sub_title"][2], L["sub_title"][3], size=13, colour=MUTED))
    for j, (_x, w, _a) in enumerate(COLS, 1):
        p.add(_cell(E, "hdr_%d" % j, w, 22, size=12, colour=MUTED, align=ALIGN[j - 1]))
    for j in range(2, len(COLS) + 1):
        p.add(E.C("hdr_line_%d" % j, 1, 22, image=WHITE, colour_img=DIVIDER_COLOUR))
    p.add(E.C("rows_holder", L["list"][2], L["list"][3]))
    # the table's frame and the rule under its header; the Lua places and sizes them
    for k in ("t", "b", "l", "r", "head"):
        p.add(E.C("derpy_mr_frame_" + k, L["FRAME"], L["FRAME"], image=WHITE, colour_img=FRAME_COLOUR))
    p.add(_cell(E, "empty_text", L["empty"][2], L["empty"][3], size=13))
    p.add(_cell(E, "hint_text", L["hint"][2], L["hint"][3], size=12, colour=MUTED, align="Right"))
    for d in ("export", "import"):
        for m in ("allow", "stop"):
            p.add(_cell(E, "derpy_mr_all_%s_%s" % (d, m), L["bulk"][2], L["bulk"][3], interactive=True,
                        image=BTN_BG, hover=[_flat(BTN_HOVER)], sound=SND_SMALL, align="Center", size=12))
    import gen_resource_overhaul as G
    for name in ["derpy_mr_order_" + o[0] for o in G.ORDERS] + ["derpy_mr_sell"]:
        p.add(_cell(E, name, L["bulk"][2], L["bulk"][3], interactive=True, image=BTN_BG,
                    hover=[_flat(BTN_HOVER)], sound=SND_SMALL, align="Center", size=12))
    # the Map tab's bottom line: its key
    for k, (icon, text) in L["map_key"].items():
        p.add(E.C("derpy_mr_mapkey_" + k, icon[2], icon[3], image=MAP_KEY_ICON[k]))
        p.add(_cell(E, "derpy_mr_mapkey_%s_text" % k, text[2], text[3], size=12))
    p.add(_cell(E, "chart_top", L["chart_top"][2], L["chart_top"][3], size=12, colour=MUTED))
    p.add(_cell(E, "chart_from", L["chart_from"][2], L["chart_from"][3], size=12, colour=MUTED))
    p.add(_cell(E, "chart_to", L["chart_to"][2], L["chart_to"][3], size=12, colour=MUTED,
                align="Right"))
    p.add(_cell(E, "chart_line", L["chart_line"][2], L["chart_line"][3], size=12))
    p.add(E.C("chart_base", L["chart_base"][2], L["chart_base"][3], image=WHITE, colour_img=DIVIDER_COLOUR))
    p.add(E.C("chart_grid", L["chart_grid"][2], L["chart_grid"][3], image=WHITE, colour_img=GRID_COLOUR))
    return _emit(root, "MR01", "derpy: Resource Overhaul's Stores panel. Created at runtime by "
                    "script/campaign/mod/derpy_more_resources_stores.lua, which MoveTo's every "
                    "child. Generated by tools/gen_mr_ui.py; do not hand-edit.")


def build_row():
    import gen_mr_emitter as E
    w = L["list"][2] - L["SLIDER_W"]
    root = E.C("root", w, L["PITCH"])
    # A faint wash in both states: it gives the row something to click on, and the hover lifts it.
    r = root.add(E.C("derpy_mr_stores_row", w, L["PITCH"], interactive=True,
                     layers=[_flat(WHITE, colour="#00000033")],
                     hover=[_flat(WHITE, colour="#FFFFFF22")]))
    r.add(E.C("band", w, L["PITCH"], image=WHITE, colour_img=BAND_COLOUR))
    r.add(E.C("section_band", w, L["PITCH"] - 2, image=WHITE, colour_img=SECTION_COLOUR))
    r.add(E.C("divider", w, 2, image=WHITE, colour_img=DIVIDER_COLOUR))
    r.add(E.C("icon", L["icon"][2], L["icon"][3], image=ICON_BG))
    for j in range(2, L["ICONS"] + 1):
        r.add(E.C("icon%d" % j, L["icon"][2], L["icon"][3], image=ICON_BG))
    for j in range(1, L["USING"] + 1):
        r.add(E.C("use%d" % j, L["icon"][2], L["icon"][3], image=ICON_BG))
    r.add(E.C("fold", L["FOLD"], L["FOLD"], image=FOLD_ARROW))
    for j, (_x, cw, _a) in enumerate(COLS, 1):
        r.add(_cell(E, "c%d" % j, cw, 20, size=12, align=ALIGN[j - 1]))
    for j in range(1, L["USING"] + 1):   # a named recipe's amounts, one after each use icon
        r.add(_cell(E, "pn%d" % j, L["PRICE_PITCH"] - L["ICON_PITCH"], 20, size=12, align="Left"))
    for j in range(2, len(COLS) + 1):
        r.add(E.C("vline%d" % j, 1, L["PITCH"], image=WHITE, colour_img=DIVIDER_COLOUR))
    # the Trade tab's two boxes, then the Spending tab's four supply boxes
    for d in ("export", "import") + tuple(k for k, _l, _u in supply_buttons()):
        r.add(E.C("derpy_mr_sw_" + d, L["CHECK"], L["CHECK"], interactive=True, image=CHECK_ON,
                  hover=[_flat(CHECK_ON_HOVER)], sound=SND_SMALL))
    # beside each supply that pays, the icon of the good it pays with (interactive: a tooltip)
    for k, _l, use in supply_buttons():
        if use:
            r.add(E.C("derpy_mr_supic_" + k, L["icon"][2], L["icon"][3], interactive=True, image=ICON_BG))
    r.add(_cell(E, "derpy_mr_sendhere", L["send"][0], L["send"][1], interactive=True, image=BTN_BG,
                hover=[_flat(BTN_HOVER)], sound=SND_SMALL, align="Center", size=12))
    for action, width in zip(("minus", "auto", "plus"), L["POLICY_W"]):
        r.add(_cell(E, "derpy_mr_policy_" + action, width, L["send"][1], interactive=True, image=BTN_BG,
                    hover=[_flat(BTN_HOVER)], sound=SND_SMALL, align="Center", size=12))
    return _emit(root, "MR02", "derpy: one row of the Stores panel, created per row into rows_holder. "
                    "Generated by tools/gen_mr_ui.py; do not hand-edit.")


def build_button():
    import gen_mr_emitter as E
    n = L["BUTTON"]
    root = E.C("root", n, n)
    root.add(E.C("derpy_mr_stores_button", n, n, interactive=True, sound=SND_OPEN,
                 tooltip=TIP_OPEN, layers=_round("active", OPENER_ICON, 10, "medium"),
                 hover=_round("hover", OPENER_ICON, 10, "medium")))
    return _emit(root, "MR03", "derpy: the button that opens the Stores panel. Generated by "
                    "tools/gen_mr_ui.py; do not hand-edit.")


def build_list():
    """CA's listview, as gen_exchange_ui.build_list: the Lua sizes and places every part."""
    import gen_mr_emitter as E
    w, h = L["list"][2], L["ROWS"] * L["PITCH"]
    root = E.C("root", w, h)
    lst = root.add(E.C("listview", w, h, interactive=True, callbacks=["Listview"]))
    clip = lst.add(E.C("list_clip", w, h, clipchildren=True, relativeresize=True,
                       interactive=True))
    clip.add(E.C("list_box", w, 1, interactive=True, callbacks=["List"], docking="Top Left",
                 layoutengine={"type": "List", "sizetocontent": True, "margins": "0.00,0.00",
                               "columns": [w]}))
    lst.add(ca_vslider(h - 2 * L["SLIDER_CAP"], L["HANDLE_H"]))
    return _emit(root, "MR04", "derpy: the Stores panel's scrolling list. rows_holder is adopted into "
                    "list_clip. Generated by tools/gen_mr_ui.py; do not hand-edit.")


def ca_vslider(h, handle_h):
    """CA's vslider for a track `h` tall, as the Zharr Exchange's (gen_guilds_ui.ca_vslider): rod,
    9-sliced handle with CA's hover brighten, two frame caps and two arrow buttons. The Lua places
    the four end parts from L["SLIDER_PARTS"]."""
    import gen_mr_emitter as E
    w = L["SLIDER_W"]
    vs = E.C("vslider", w, h, interactive=True, callbacks=["VSlider"], allowhresize=False,
             props={"Value": 0, "minValue": 0, "maxValue": h - handle_h},
             layers=[{"path": SLIDER_TRACK, "offset": (SLIDER_ROD_X, 0), "dw": SLIDER_ROD_W - w,
                      "dh": 0, "margin": 0, "tile": True, "dock": None}])
    # Children draw in this order, so the caps sit under the handle and the arrows over both.
    vs.add(E.C("frame_top", 20, L["SLIDER_CAP"],
               layers=[{"path": SLIDER_ART["frame_top"], "offset": (0, 0), "dw": 0, "dh": 12,
                        "margin": 0, "dock": None}]))
    vs.add(E.C("frame_bottom", 19, L["SLIDER_CAP"],
               layers=[{"path": SLIDER_ART["frame_bottom"], "offset": (0, -13), "dw": 0, "dh": 13,
                        "margin": 0, "dock": None}]))
    sl = (HANDLE_SLICE, 0, HANDLE_SLICE, 0)

    def gem(colour=None, shader_vars=None):
        lay = {"path": SLIDER_HANDLE, "offset": (0, 0), "dw": 0, "dh": 0, "margin": sl,
               "tile": True, "dock": None, "shader": "brighten_t0"}
        if colour:
            lay["colour"] = colour
            lay["shader_vars"] = shader_vars
        return lay
    under = {"path": SLIDER_HANDLE_UNDER, "offset": (0, 0), "dw": 0, "dh": 0, "margin": sl,
             "tile": True, "dock": None}
    vs.add(E.C("handle", w, handle_h, interactive=True,
               callbacks=["VSliderHandle", "TopmostWhenDraggingCallback"],
               allowhresize=False, moveable="Movable XP", sound=SND_SLIDER_HANDLE,
               props={"max_height": h - handle_h, "min_size": HANDLE_MIN},
               # CA's hover: a third copy of the gem, brightened 0.30, transparent until hover.
               layers=[under, gem(), gem("#FFFFFF00", "0.30,0.00,0.00,0.00")],
               hover=[under, gem(), gem("#FFFFFFFF", "0.30,0.00,0.00,0.00")]))
    for name, cb in (("top", "SliderDecrementButton"), ("bottom", "SliderIncrementButton")):
        std, hov = SLIDER_ART[name]
        vs.add(E.C(name, 15, 22, interactive=True, callbacks=[cb], sound=SND_SLIDER_ARROWS,
                   props={"stepSize": 10},
                   layers=[{"path": std, "offset": (0, 0), "dw": 0, "dh": 0, "margin": 0, "dock": None}],
                   hover=[{"path": hov, "offset": (0, 0), "dw": 0, "dh": 0, "margin": 0, "dock": None}]))
    return vs


def build_sp():
    """ONE EMPTY ROW: no image, no text, no children - it gives the list its length."""
    import gen_mr_emitter as E
    w = L["list"][2]
    root = E.C("root", w, L["PITCH"])
    root.add(E.C("derpy_mr_stores_sp", w, L["PITCH"]))
    return _emit(root, "MR05", "derpy: one empty row of the Stores panel's list. Generated by "
                    "tools/gen_mr_ui.py; do not hand-edit.")


def build_bar():
    """One bar of the history chart: a flat tinted image the Lua sizes and moves."""
    import gen_mr_emitter as E
    root = E.C("root", L["BAR_W"], L["bars"][3])
    root.add(E.C("derpy_mr_stores_bar", L["BAR_W"], L["bars"][3], interactive=True,
                 image=WHITE, colour_img=BAR_COLOUR))
    return _emit(root, "MR06", "derpy: one bar of the Stores panel's history chart, created twenty "
                    "times into the panel. Generated by tools/gen_mr_ui.py; do not hand-edit.")


MAP_DOT_COLOUR = "#E0553CFF"     # a settlement: red ink, read on CA's parchment and on black alike
MAP_ART_DIM = "#8C8C8CFF"        # CA's parchment, dimmed so the panel's beige names read on it
ROUND_SMALL = "ui/skins/default/button_round_small_%s.png"   # the Close button's art
MAP_KEY_ICON = {"cap": L["MAP_CAP_ICON"], "town": L["MAP_TOWN_ICON"], "cart": L["MAP_CART"]}
# THE MAP'S FRAME: CA's own panel border (PANEL_LAYERS' second layer), copper with a clear centre
MAP_FRAME = PANEL_LAYERS[1]


def build_mapdot():
    """A settlement on the Map tab: a tinted square the Lua sizes, with a tooltip and a click."""
    import gen_mr_emitter as E
    root = E.C("root", L["MAP_CAP"], L["MAP_CAP"])
    # HOVER: the same marker brightened, CA's hover shader (brighten_t0 is on 802 of its hover
    # states); the Lua points image 1 at the marker it points image 0 at
    hover = dict(_flat(L["MAP_TOWN_ICON"]), shader="brighten_t0", shader_vars="0.50,0.00,0.00,0.00")
    root.add(E.C("derpy_mr_stores_mapdot", L["MAP_CAP"], L["MAP_CAP"], interactive=True,
                 image=L["MAP_TOWN_ICON"], sound=SND_SMALL, hover=[hover]))
    return _emit(root, "MR07", "derpy: a settlement on the Stores panel's Map tab. Generated by "
                    "tools/gen_mr_ui.py; do not hand-edit.")


def build_mapcart():
    """A convoy on the Map tab: CA's convoy icon, with a tooltip and a click."""
    import gen_mr_emitter as E
    s = L["MAP_CART_SIZE"]
    root = E.C("root", s, s)
    root.add(E.C("derpy_mr_stores_mapcart", s, s, interactive=True, image=L["MAP_CART"], sound=SND_SMALL))
    return _emit(root, "MR08", "derpy: a convoy on the Stores panel's Map tab. Generated by "
                    "tools/gen_mr_ui.py; do not hand-edit.")


def build_mappath(n):
    """One dot of a trade road on the Map tab, in the 3D map's colour n, a little fainter.

    THE DARK RIM: measured 2026-10-21 on the dimmed IE minimap, the red and blue inks alone are
    2.5:1 and 3.2:1 against its median parchment, under the 3:1 a mark needs. A 1px black rim
    reads on parchment and the ink reads on the rim, whatever the colour."""
    import gen_mr_emitter as E
    import build_mr_terrain_routes as T
    # R.ink hands out set * 4 + R.colour (`% 4`): one template per palette colour, or one draws nothing, silently
    src = (T.OUT / "terrain_routes.lua").read_text(encoding="utf-8")
    assert re.search(r"function R\.colour.*?% (\d+)", src, re.S).group(1) == str(len(T.COLOUR_SETS[0][3])) == "4"
    assert len(T.COLOURS) == L["MAP_PATH_COLOURS"] <= 16, T.COLOURS   # 16: one hex digit of the GUID prefix
    ink = "#%02X%02X%02XCC" % tuple(round(255 * v) for v in T.COLOURS[n])
    s = L["MAP_PATH"]
    root = E.C("root", s, s)
    root.add(E.C("derpy_mr_stores_mappath_%d" % n, s, s, layers=[
        _flat(WHITE, colour="#000000CC"), _flat(WHITE, colour=ink, offset=(1, 1), dw=-2, dh=-2)]))
    return _emit(root, "MR9%X" % n, "derpy: one dot of a trade road on the Stores panel's Map tab. Generated "
                    "by tools/gen_mr_ui.py; do not hand-edit.")


def build_maplabel():
    """A province capital's name on the Map tab."""
    import gen_mr_emitter as E
    w, h = L["map_label"]
    root = E.C("root", w, h)
    root.add(_cell(E, "derpy_mr_stores_maplabel", w, h, size=11))
    return _emit(root, "MR10", "derpy: a province capital's name on the Stores panel's Map tab. Generated "
                    "by tools/gen_mr_ui.py; do not hand-edit.")


def build_mapart():
    """CA's campaign minimap under the Map tab: a box that cuts it to the map, and the picture,
    which the Lua points at the campaign's own minimap, sizes and moves."""
    import gen_mr_emitter as E
    w, h = L["map"][2], L["map"][3]
    root = E.C("root", w, h)
    clip = root.add(E.C("derpy_mr_stores_mapart", w, h, clipchildren=True))
    # THE GRAB LAYER, first so beneath everything: clear, the box's size, and the only thing the
    # engine drags ("Movable XP", CA's value). A dragged Movable XP component is put back where the
    # drag began when let go, so the PICTURE is never dragged: the Lua's poll moves it by the grab
    # layer's offset while IsDragged, and the put-back happens to a layer nobody sees.
    # NOT DragAndZoomCallback (tried 2026-10-08): on this layer it took the press, so the drag
    # stopped, and moved or sized nothing a script can read, so the wheel zoomed nothing either.
    clip.add(E.C("derpy_mr_map_grab", w, h, interactive=True, moveable="Movable XP"))
    # The picture: NOT interactive, so a press on bare map goes through it to the grab layer; the
    # dots, names and carts are its children, drawn over it, cut with it and moved with it.
    clip.add(E.C("derpy_mr_map_art", w, h, image=WHITE, colour_img=MAP_ART_DIM))
    # THE FRAME (asked 2026-10-04): after the picture, so drawn over it and all it carries; not
    # interactive, so the grab goes through it to the picture
    o = L["MAP_FRAME_OUT"]
    clip.add(E.C("derpy_mr_map_frame", w + 2 * o, h + 2 * o, layers=[MAP_FRAME]))
    # + and -, after the frame so drawn over it: the map's own controls, in its corner
    for name in ("derpy_mr_zoom_in", "derpy_mr_zoom_out"):
        clip.add(_cell(E, name, L["zoom_in"][2], L["zoom_in"][3], interactive=True, sound=SND_SMALL,
                       align="Center", size=18, layers=[_flat(ROUND_SMALL % "active")],
                       hover=[_flat(ROUND_SMALL % "hover")]))
    return _emit(root, "MR11", "derpy: CA's campaign minimap under the Stores panel's Map tab. Generated "
                    "by tools/gen_mr_ui.py; do not hand-edit.")


def build_card():
    """One unit of a shipment's escort (escort battles, spec 2026-10-09): CA's unit card at its own
    size, with the unit's name as a tooltip. The Lua sets the card; this one is only the default."""
    import gen_mr_emitter as E
    w, h = L["CARD_W"], L["CARD_H"]
    root = E.C("root", w, h)
    root.add(E.C("derpy_mr_stores_card", w, h, interactive=True, image=sorted(unit_cards().values())[0][0]))
    return _emit(root, "MR12", "derpy: one card of a shipment's escort on the Stores panel's Spending tab. "
                    "Generated by tools/gen_mr_ui.py; do not hand-edit.")


BUILDERS = (("derpy_mr_stores_panel", build_panel), ("derpy_mr_stores_row", build_row),
            ("derpy_mr_stores_button", build_button), ("derpy_mr_stores_list", build_list),
            ("derpy_mr_stores_sp", build_sp), ("derpy_mr_stores_bar", build_bar),
            ("derpy_mr_stores_mapdot", build_mapdot), ("derpy_mr_stores_mapcart", build_mapcart),
            ("derpy_mr_stores_maplabel", build_maplabel),
            ("derpy_mr_stores_mapart", build_mapart), ("derpy_mr_stores_card", build_card)) + tuple(
            ("derpy_mr_stores_mappath_%d" % n, functools.partial(build_mappath, n)) for n in range(L["MAP_PATH_COLOURS"]))


def goods():
    """[(stem, resource key, icon path)] in store_stems() order: the mod's 37, then CA's 17."""
    import gen_resource_overhaul as G
    out = []
    for stem, (res, _fx, _name) in G.store_stems().items():
        out.append((stem, res, ICON_DIR + (CA_ICONS.get(res) or G.icon(stem)) + ".png"))
    return out


# THE CAPTURE PANEL'S OPTIONS, by id. Each option component is named for its
# culture_settlement_occupation_options row's `id` (CcoCultureSettlementOccupationOptionRecord's Key),
# and only that row says which decision it is: the option's name is translated text, and picture
# names lie (Norsca's raze_serpent, Vampire Coast's sack_build_cove are other decisions).
# "occupy": the store stays with the settlement and becomes the taker's (loot-and-occupy too).
# Not occupy_and_vassal, resettle or colonise: the store goes to someone else, or there is none.
DECISION_KIND = {"occupation_decision_sack": "sack", "occupation_decision_raze_without_occupy": "raze",
                 "occupation_decision_occupy": "occupy", "occupation_decision_loot": "occupy"}
# read off the Chaos Dwarf panel in game, 2026-10-02
MEASURED_OPTIONS = {1671725074: "sack", 1992765694: "raze", 222165943: "occupy", 1899472825: "occupy"}


@functools.lru_cache(maxsize=None)
def capture_kinds():
    """{option id: "sack" | "raze"} out of CA's db.pack, every culture."""
    import read_vanilla_db as rvd
    out = {}
    for _p, _v, rows in rvd.load(rvd.DB_PACK, "culture_settlement_occupation_options_tables"):
        for r in rows:
            k = DECISION_KIND.get(r["settlement_option"])
            if k:
                out[r["id"]] = k
    return tuple(sorted(out.items()))


def _rare(stem):
    import gen_resource_overhaul as G
    return "true" if stem in G.RARE else "false"


def use_of(stem):
    for use, stems in USES.items():
        if stem in stems:
            return use
    return None


def check_uses():
    import gen_resource_overhaul as G
    stems = list(G.store_stems())
    flat = [s for v in USES.values() for s in v]
    assert len(flat) == len(set(flat)), "a store has two uses"
    assert sorted(flat) == sorted(stems), "uses vs stores: %s" % (set(flat) ^ set(stems))
    toks = set(re.search(r"\((dae[^)]*)\)", G.EXCLUDE.pattern).group(1).split("|")) - {"beastmen", "BEASTMEN"}
    assert toks == set(NO_STORES), "NO_STORES %s, EXCLUDE %s" % (sorted(NO_STORES), sorted(toks))
    assert {u for u, *_ in G.USE_BUNDLES} <= set(USES), "a bundle for a use that does not exist"
    assert {o[1] for o in G.ORDERS} <= set(USES), "an order paid in a use that does not exist"
    assert set(SELL_RATE) == set(USES), "a use with no sell rate"


def check_recruit():
    """The recruitment rules name only real things: CA's castes, our goods' uses and rare stems,
    race tokens a subculture yields, and CA pools that exist (keys fail silently)."""
    import gen_resource_overhaul as G
    castes = {r["caste"] for r in G.db("main_units_tables")[1]}
    assert set(CASTE_DRAW) <= castes, set(CASTE_DRAW) - castes
    assert not {"lord", "hero", "generic"} & set(CASTE_DRAW), "characters draw nothing"
    assert set(INFANTRY_CASTES) <= set(CASTE_DRAW), INFANTRY_CASTES
    uses = {use_of(s) for s, _r, _i in goods()}
    for caste, parts in CASTE_DRAW.items():
        assert parts and all(u in uses and 0 < x <= 2 for u, x in parts), caste
    rare = {s for s, _r, _i in goods() if _rare(s) == "true"}
    assert set(RACE_RARE.values()) | set(RACE_RARE_INF.values()) <= rare
    tokens = {m.group(1) for r in G.db("cultures_subcultures_tables")[1]
              for m in [re.search(r"_sc_([a-z]+)_", r["subculture"])] if m}
    named = set(RACE_RARE) | set(RACE_RARE_INF) | set(CURRENCY)
    assert named <= tokens, named - tokens
    assert named.isdisjoint(NO_STORES), "a race that keeps no stores: %s" % (named & set(NO_STORES))
    pools = {r["key"]: r for r in G.db("pooled_resources_tables")[1]}
    for race, c in CURRENCY.items():
        assert c["pool"] in pools, (race, c["pool"])
        # cm:faction_add_pooled_resource reaches a FACTION pool only: Ogre Meat is held per army
        assert pools[c["pool"]]["scope"] == "FACTION", "%s is a %s pool" % (c["pool"], pools[c["pool"]]["scope"])
        assert c["per"] >= 1 and "%d" in c["line"] and "%s" in c["line"], race


def check_capture_kinds():
    got = dict(capture_kinds())
    assert len(got) > 40, "only %d sack/raze options read" % len(got)
    for oid, kind in MEASURED_OPTIONS.items():
        assert got.get(oid) == kind, "option %d is %r in the table, %r in game" % (oid, got.get(oid), kind)


# what a named recipe carries into the flows header beyond a rare work's fields
RECIPE_FIELDS = ("goods", "amount", "bundle", "turns", "trait", "rank", "wait", "lord", "not_races")


@functools.lru_cache(None)
def ca_templates():
    """{template: [unit keys]} out of CA's WH_Random_Army_Generator."""
    with io.open(CA_ARMIES, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    out, cur = {}, None
    for line in text.splitlines():
        m = re.search(r'template_key == "([^"]+)"', line)
        if m:
            cur = out.setdefault(m.group(1), [])
            continue
        m = re.search(r'ram:add_unit\(key,\s*"([^"]+)"', line)
        if m and cur is not None:
            cur.append(m.group(1))
    return out


@functools.lru_cache(None)
def escort_templates():
    """{subculture: template} for every subculture CA's factions use that gets an escort."""
    import gen_resource_overhaul as G
    tpl = ca_templates()
    scs = {r["subculture"] for r in G.db("factions_tables")[1]}
    keeps = {sc for sc in scs if not any("_%s_" % t in sc for t in NO_STORES)}   # the rest never ship
    out = {sc: sc for sc in keeps if sc in tpl}
    out.update({sc: t for sc, t in ESCORT_ALIAS.items() if sc in keeps})
    out[ESCORT_OWN_SC] = ESCORT_OWN_KEY
    return out


def escort_units():
    tpl, units = ca_templates(), {u for u, _w, _t in ESCORT_OWN}
    for t in set(escort_templates().values()) - {ESCORT_OWN_KEY}:
        units.update(tpl[t])
    return units


@functools.lru_cache(None)
def unit_cards():
    """{unit: (card path, land unit)} for every unit an escort can roll: the card is the faction-less
    unit_variants row's unit_card, not the unit key."""
    import gen_resource_overhaul as G
    card = {r["unit"]: r["unit_card"] for r in G.db("unit_variants_tables")[1] if r["faction"] == ""}
    land = {r["unit"]: r["land_unit"] for r in G.db("main_units_tables")[1]}
    return {u: ("ui/units/icons/%s.png" % card[u], land[u]) for u in sorted(escort_units())
            if u in card and u in land}


def escort_drop():
    """The units CA's templates name that ship no card: dropped from every escort the script rolls."""
    return sorted(escort_units() - set(unit_cards()))


def check_escorts():
    """Every subculture CA's factions use either keeps no stores, has an escort, or owns no settlements;
    every escort unit is a CA unit with a card in CA's packs and a land unit."""
    import gen_resource_overhaul as G
    import gen_mr_emitter as E
    scs = {r["subculture"] for r in G.db("factions_tables")[1]}
    esc = escort_templates()
    no_stores = {sc for sc in scs if any("_%s_" % t in sc for t in NO_STORES)}
    homeless = {sc for sc in scs if "_sc_" not in sc or "_pro_sc_" in sc}   # rogue armies, the prologue
    left = scs - set(esc) - no_stores - homeless
    assert not left, "subcultures with stores and no escort: %s" % sorted(left)
    tpl = ca_templates()
    assert len(tpl) >= 40 and all(tpl.values()), "CA's random-army file did not parse"
    for t in set(esc.values()) - {ESCORT_OWN_KEY}:
        assert t in tpl, "no CA template %s" % t
    units = {r["unit"] for r in G.db("main_units_tables")[1]}
    assert all(u in units for u, _w, _t in ESCORT_OWN), "a Cathay escort unit CA does not ship"
    have, cards = E._game_assets(), unit_cards()
    # STALE KEYS IN CA'S TEMPLATES (wh_main_emp_veh_steam_tank, not _driver): no variant row, so no
    # model and no card. The script prunes them from its copy of the force (escort_drop); every
    # template must keep something to roll.
    for t in set(esc.values()) - {ESCORT_OWN_KEY}:
        assert set(tpl[t]) - set(escort_drop()), "template %s is all stale keys" % t
    nopic = sorted(u for u, (c, _l) in cards.items() if c not in have)
    assert not nopic, "cards not in CA's packs: %s" % nopic[:10]


def _lua(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, dict):
        return "{" + ", ".join("%s = %s" % (k, _lua(v[k])) for k in sorted(v)) + "}"
    if isinstance(v, (tuple, list)):
        return "{" + ", ".join(_lua(x) for x in v) + "}"
    if isinstance(v, str):
        return '"%s"' % v
    return str(v)


def header():
    lines = ["-- GENERATED by tools/gen_mr_ui.py from Modding Files/source/resource_overhaul/"
             "stores_panel.lua.",
             "-- Edit the source or the generator, never this file.",
             "DERPY_MR_STORES_L = {"]
    lines += ["    %s = %s," % (k, _lua(L[k])) for k in sorted(L)]
    lines.append("}")
    # EACH PANEL SIZE: its factor (a decimal: a literal left of an operator miscompiles in the game's
    # Lua, CLAUDE.md), its .twui.xml suffix and the layout above at that size
    lines.append("DERPY_MR_STORES_SIZES = {")
    for sfx in ("_sm", "", "_lg"):
        if not sfx:
            lines.append('    medium = {f = 1, suffix = "", layout = DERPY_MR_STORES_L},')
            continue
        n, d = SIZES[sfx][:2]
        lay = scaled_layout(sfx)
        lines.append('    %s = {f = %r, suffix = "%s", layout = {' % (SIZE_NAME[sfx], n / float(d), sfx))
        lines += ["        %s = %s," % (k, _lua(lay[k])) for k in sorted(lay)]
        lines.append("    }},")
    lines += ["}", "DERPY_MR_STORES_GOODS = {"]
    lines += ['    {stem = "%s", res = "%s", icon = "%s", use = "%s", rare = %s},'
              % (s, r, i, use_of(s), _rare(s)) for s, r, i in goods()]
    lines += ["}", "DERPY_MR_CAPTURE_KIND = {"]
    lines += ['    [%d] = "%s",' % kv for kv in capture_kinds()]
    import gen_resource_overhaul as G
    # the race variants last, so the use bundles keep their places
    lines += ["}", "DERPY_MR_STORES_BUNDLES = {"]
    lines += ['    {key = "%s", icon = "ui/campaign ui/effect_bundles/%s"},' % (k, i) for _u, k, i, *_r in G.use_bundles()]
    lines += ["}", "DERPY_MR_STORES_ORDERS = {"]
    lines += ['    {key = "%s", use = "%s", label = "%s", what = "%s", turns = %d},' % (k, u, t, w, G.ORDER_TURNS)
              for k, u, _b, _i, t, w, _f in G.ORDERS]
    lines += ["}", "DERPY_MR_STORES_SUPPLY = {"]
    lines += ['    {key = "%s", label = "%s", use = "%s", what = "%s"},' % (k, l, u, w)
              for (k, l, u), w in zip(supply_buttons(), [s[5] for s in G.SUPPLY] + [""])]
    lines += ["}", "DERPY_MR_STORES_WORKS = {"]
    icon_of = {s: i for s, _r, i in goods()}
    for w in G.works():
        priced = _lua([(st, n, icon_of[st]) for st, n in w.get("goods", ())])
        # a general_to_force_own trait is a lord's alone (stage 2 final review)
        target = "lord" if w.get("lord") else {"army": "army", "trait": "character"}.get(w["kind"], "")
        first = w["rare"] or (w["goods"][0][0] if w.get("goods") else "books")
        lines.append('    {key = "%s", kind = "%s", rare = "%s", use = "%s", name = "%s", gives = "%s", detail = "%s", '
                     'icon = "%s", pool = "%s", goods = %s, target = "%s"},'
                     % (w["key"], w["kind"], w["rare"], w["use"], w["name"], w["gives"], w["detail"], icon_of[first],
                        w.get("pool", ""), priced, target))
    lines += ["}", "DERPY_MR_STORES_USE_ICON = {"]
    lines += ['    %s = "ui/campaign ui/effect_bundles/%s",' % kv for kv in sorted(USE_ICON.items())]
    lines.append("}")
    # ESCORT BATTLES: the card and the land unit (whose loc is its name) of every unit an escort rolls
    lines += ["DERPY_MR_STORES_CARDS = {"]
    lines += ['    %s = {card = "%s", lu = "%s"},' % (u, c, l) for u, (c, l) in sorted(unit_cards().items())]
    lines.append("}")
    import gen_resource_overhaul as G
    # FOUNDING: each rare good's three level names, as CA's building browser shows them
    lines += ["DERPY_MR_STORES_FOUND = {"]
    lines += ['    %s = {"%s", "%s", "%s"},' % ((g,) + tuple(G.RARE[g]["levels"])) for g in sorted(G.RARE)]
    lines.append("}")
    # TRADE EDICTS (Part B): the Resources tab's three rows, each option's label and the text of its effects
    lines += ["DERPY_MR_STORES_EDICTS = {"]
    for k, name, tip, _d, opts in EDICTS:
        lines.append('    {key = "%s", name = "%s", tip = "%s", options = {%s}},'
                     % (k, name, tip, ", ".join('{key = "%s", label = "%s", tip = %s%s}'
                                                % (o[0], o[1], _lstr(o[2]), (", tip_chd = %s" % _lstr(o[4])) if o[4] else "")
                                                for o in opts)))
    lines.append("}")
    return "\n".join(lines) + "\n"


def supply_buttons():
    """(key, label, use) of the four supply boxes on a Spending tab row: the three supplies, then
    Supply the capital, which pays nothing itself."""
    import gen_resource_overhaul as G
    return [(k, t, u) for k, u, _b, _i, t, _w, _f in G.SUPPLY] + [("standing", "Supply the capital", "")]


def stores_lua():
    with io.open(SRC, encoding="utf-8", newline="") as fh:
        return header() + fh.read()


# IMPORT DUTY'S PRICE: what CA's trade pays a unit. Measured 2026-10-08 (Old World): the Trade
# Forecast showed "Resource value: 9" for Salt and Brimstone, both trade_value 50. The Exchange's
# market price (salt 818, blackpowder 4,549) is NOT a trade price: on it one turn's output of 44
# units came to a 6,128 duty, the partner's whole treasury.
CA_UNIT_VALUE = 9 / 50


def trade_values():
    """resource key -> resources_tables.trade_value: CA's rows, and ours (cloned from the donor)."""
    import gen_resource_overhaul as G
    van = G.db("resources_tables")[1]
    out = {r["key"]: r["trade_value"] for r in van}
    donor, = [r for r in van if r["key"] == G.DONOR]
    out.update({G.key(g): donor["trade_value"] for g in G.GOODS})
    return out


@functools.lru_cache(None)
def bandit_qb():
    """{subculture: quest-battle faction} for every escorted subculture CA ships a _qb1 faction for: the
    first by key, which is the main one where there are two (the Empire's, not its rebels')."""
    import gen_resource_overhaul as G
    qb = {}
    for r in G.db("factions_tables")[1]:
        if r["key"].endswith("_qb1"):
            qb.setdefault(r["subculture"], []).append(r["key"])
    return {sc: sorted(qb[sc])[0] for sc in escort_templates() if sc in qb}


def road_lua():
    """DERPY_MR_FLOWS_ROAD and DERPY_MR_FLOWS_BANDIT_QB (Part D): every bandit faction is one CA ships."""
    import gen_resource_overhaul as G
    keys = {r["key"] for r in G.db("factions_tables")[1]}
    qb = bandit_qb()
    assert ROAD_QB_DEFAULT in keys and all(k in keys for k in qb.values()), "a bandit faction CA does not ship"
    assert len(qb) >= 15, "too few races with bandits of their own"
    assert qb.get(ROAD_QB_SC) == ROAD_QB_DEFAULT, "the default bandits are not the ogres' own"
    sizes = ", ".join("{%s, %d}" % ("nil" if t is None else t, n) for t, n in ROAD_SIZES)
    return "\n".join([
        'DERPY_MR_FLOWS_ROAD = {cooldown = %d, ambush_min = %d, ai_guard = %d, guard_pct = %d, toll_pct = %d, '
        'wash_pct = %d, half_pct = %d, sizes = {%s}, encounters = {%s}, qb = "%s", qb_sc = "%s"}'
        % (ROAD_COOLDOWN, ROAD_AMBUSH_MIN, ROAD_AI_GUARD, ROAD_GUARD_PCT, ROAD_TOLL_PCT, ROAD_WASH_PCT,
           ROAD_HALF_PCT, sizes, ", ".join('"%s"' % e for e in ROAD_ENCOUNTERS), ROAD_QB_DEFAULT, ROAD_QB_SC),
        "DERPY_MR_FLOWS_BANDIT_QB = {"] + ['    %s = "%s",' % kv for kv in sorted(qb.items())] + ["}"])


def flows_header():
    lines = ["-- GENERATED by tools/gen_mr_ui.py from Modding Files/source/resource_overhaul/flows.lua.",
             "-- Edit the source or the generator, never this file.",
             "DERPY_MR_FLOWS_DEFAULTS = {"]
    lines += ["    %s = %d," % (k, d) for k, _l, _t, _lo, _hi, d in RATES]
    lines += ["    %s = %s," % (k, "true" if d else "false") for k, _l, _t, d in SWITCHES]
    lines += ["}", "DERPY_MR_FLOWS_KIND = {"]
    lines += ['    %s = "%s",' % (k, FLOW_KIND[k]) for k in sorted(FLOW_KIND)]
    assert set(SPOIL_RATES) <= set(USES["provisions"]), "a spoiling good that is not a provision"
    lines += ["}", 'DERPY_MR_FLOWS_SPOIL = {rates = {%s}, safe = %d, granary = %d, granary_good = "%s", '
              'granary_works = {%s}}' % (", ".join("%s = %d" % kv for kv in sorted(SPOIL_RATES.items())),
                                       SPOIL_SAFE_PCT, SPOIL_GRANARY_PCT, SPOIL_GRANARY_GOOD,
                                       ", ".join('"%s"' % k for k in SPOIL_GRANARY_WORKS))]
    lines.append(edicts_lua())
    assert 0 < TOLL_MAX_PCT <= 100, "the toll limit is a share"
    lines.append("DERPY_MR_FLOWS_TOLL = {max = %d}" % TOLL_MAX_PCT)
    lines.append(road_lua())
    lines += ["DERPY_MR_FLOWS_GOODS = {"]
    worth = trade_values()
    import gen_resource_overhaul as G
    # F.hold_exports applies derpy_mr_hold_<stem>; a stem with no marker bundle holds nothing, silently
    assert {s for s, _r, _i in goods()} == set(G.store_stems()), "goods without a hold marker"
    lines += ['    {stem = "%s", res = "%s", use = "%s", rare = %s, value = %g},'
              % (s, r, use_of(s), _rare(s), worth[r] * CA_UNIT_VALUE) for s, r, _i in goods()]
    import gen_resource_overhaul as G
    lines += ["}", "DERPY_MR_FLOWS_ECONOMY = %s" % _lua(G.economy_definitions()), "DERPY_MR_FLOWS_ORDERS = {"]
    lines += ['    %s = {use = "%s", bundle = "%s"},' % (k, u, b) for k, u, b, *_r in G.ORDERS]
    lines += ["}", "DERPY_MR_FLOWS_ORDER = {%d, %d, %d}   -- cost, turns, cooldown"
              % (G.ORDER_COST, G.ORDER_TURNS, G.ORDER_COOLDOWN),
              "DERPY_MR_FLOWS_SELL_RATE = {%s}" % ", ".join("%s = %d" % (u, SELL_RATE[u]) for u in sorted(SELL_RATE))]
    lines += ["DERPY_MR_FLOWS_EVENT = {%d, %d}   -- gap in turns, a computer's chance in 100"
              % (G.EVENT_GAP, G.EVENT_AI_PCT), "DERPY_MR_FLOWS_EVENTS = {"]
    for e in G.EVENTS:
        b = e["bundle"]
        lines.append('    %s = {use = "%s", cost = %d, where = "%s", dilemma = "%s", bundle = %s, turns = %d, '
                     'races = %s, not_races = %s, needs = %s, human = %s},'
                     % (e["key"], e["use"], e["cost"], e["where"], G.event_dilemma(e["key"]),
                        '"%s"' % b[0] if b else "nil", b[3] if b else 0,
                        _lua(list(e.get("races", ("all",)))), _lua(list(e.get("not_races", ()))),
                        _lua(list(e.get("needs", ()))), "true" if e.get("human") else "false"))
    lines.append("}")
    lines += ["DERPY_MR_FLOWS_SUPPLY = {"]
    lines += ['    %s = {use = "%s", bundle = "%s"},' % (k, u, b) for k, u, b, *_r in G.SUPPLY]
    lines += ["}", "DERPY_MR_FLOWS_SUPPLY_ORDER = {%s}" % ", ".join('"%s"' % s[0] for s in G.SUPPLY),
              "DERPY_MR_FLOWS_SHIP = {per = %d, turns = %d, ai_cap = %d, stand = %d, ai_on = %d, radius = %d, "
              'near = %d, spot = %d, info = "%s", scene = "%s"}'
              % (G.SUPPLY_PER, G.SHIP_TURNS, G.SHIP_AI_CAP, G.SHIP_STAND, G.SHIP_AI_ON, G.SHIP_RADIUS,
                 G.SHIP_NEAR, G.SHIP_SPOT, G.SHIP_INFO, G.SHIP_SCENE)]
    lines += ['DERPY_MR_FLOWS_RECRUIT = {per = %d, elite = %d, elite_per = %d, gold_x = %d, factor = "derpy_mr_recruit"}'
              % (RECRUIT_PER, RECRUIT_ELITE, RECRUIT_ELITE_PER, RECRUIT_GOLD_X), "DERPY_MR_FLOWS_CASTE = {"]
    lines += ["    %s = {%s}," % (c, ", ".join('{"%s", %g}' % p for p in parts)) for c, parts in sorted(CASTE_DRAW.items())]
    lines += ["}", "DERPY_MR_FLOWS_INFANTRY = {%s}" % ", ".join("%s = true" % c for c in INFANTRY_CASTES),
              "DERPY_MR_FLOWS_RACE_RARE = {%s}" % ", ".join('%s = "%s"' % kv for kv in sorted(RACE_RARE.items())),
              "DERPY_MR_FLOWS_RACE_RARE_INF = {%s}" % ", ".join('%s = "%s"' % kv for kv in sorted(RACE_RARE_INF.items())),
              "DERPY_MR_FLOWS_CURRENCY = {"]
    lines += ['    %s = {pool = "%s", per = %d, word = "%s", line = "%s"},' % (r, c["pool"], c["per"], c["word"], c["line"])
              for r, c in sorted(CURRENCY.items())]
    lines += ["}"]
    lines += ['DERPY_MR_FLOWS_ESCORT = {per = %d, min = %d, max = %d, turns = %d, own = "%s"}'
              % (ESCORT_PER, ESCORT_MIN, ESCORT_MAX, ESCORT_TURNS, ESCORT_OWN_KEY),
              "DERPY_MR_FLOWS_ESCORT_SC = {"]
    lines += ['    %s = "%s",' % kv for kv in sorted(escort_templates().items())]
    lines += ["}", "DERPY_MR_FLOWS_ESCORT_OWN = {"]
    lines += ['    {"%s", %d, "%s"},' % u for u in ESCORT_OWN]
    lines += ["}", "DERPY_MR_FLOWS_ESCORT_DROP = {%s}" % ", ".join("%s = true" % u for u in escort_drop())]
    # FOUNDING A RARE BUILDING where no slot offers it (spec 2026-10-09)
    found = G.found_map()
    costs, reqs = G.level_prices()
    lines += ["DERPY_MR_FLOWS_FOUND = {"]
    lines += ['    %s = "%s",' % kv for kv in sorted(found.items())]
    lines += ["}", "DERPY_MR_FLOWS_FOUND_CHAIN = {"]
    for good in sorted(set(found.values())):
        lines.append("    %s = {%s}," % (good, ", ".join('%s = "%s"' % (G.CULTURES[r], ch) for r, ch in G.rare_chains(good))))
    lines += ["}", "DERPY_MR_FLOWS_FOUND_LEVELS = {cost = {%s}, req = {%s}}"
              % (", ".join(map(str, costs)), ", ".join(map(str, reqs)))]
    lines += ["DERPY_MR_FLOWS_NO_STORES = {%s}" % ", ".join('"%s"' % t for t in NO_STORES),
              "DERPY_MR_FLOWS_BUNDLES = {"]
    lines += ['    %s = "%s",' % (u, k) for u, k, *_r in bundles()]
    # a race's own bundle in place of a use's (gen_resource_overhaul RACE_USE_BUNDLES, check_reach)
    base = {u: k for u, k, *_r in bundles()}
    lines += ["}", "DERPY_MR_FLOWS_RACE_BUNDLES = {"]
    for k in sorted({base[u] for u, *_r in G.RACE_USE_BUNDLES}):
        lines.append("    %s = {%s}," % (k, ", ".join('{race = "%s", key = "%s"}' % (race, v)
                                                     for u, race, v, *_r in sorted(G.RACE_USE_BUNDLES, key=lambda r: r[1])
                                                     if base[u] == k)))
    lines += ["}", "DERPY_MR_FLOWS_WORKS = {"]
    for w in G.works():
        # a named recipe's price and payload (workshop expansion spec section 4)
        extra = "".join(", %s = %s" % (k, _lua(w[k])) for k in RECIPE_FIELDS if k in w)
        lines.append('    {key = "%s", kind = "%s", rare = "%s", rare_n = %d, use = "%s", use_n = %d, races = %s, '
                     'grant = "%s", group = "%s", pool = "%s"%s},'
                     % (w["key"], w["kind"], w["rare"], w["rare_n"], w["use"], w["use_n"], _lua(w["races"]),
                        w["grant"], w["group"], w.get("pool", ""), extra))
    lines += ["}", "DERPY_MR_FLOWS_WORK = %s" % _lua(G.work_cfg()),
              "DERPY_MR_FLOWS_WORK_SOUND = %s" % _lua(WORK_SOUND),
              "-- the factions that own each pool (faction_to_mercenary_set_junctions); any other buys into an army",
              "DERPY_MR_FLOWS_POOL_HAS = {"]
    for pool, fs in sorted(G.pool_factions().items()):
        lines.append("    %s = {%s}," % (pool, ", ".join("%s = true" % f for f in fs)))
    lines.append("}")
    return "\n".join(lines) + "\n"


def bundles():
    import gen_resource_overhaul as G
    return G.USE_BUNDLES


def flows_lua():
    with io.open(FLOWS_SRC, encoding="utf-8", newline="") as fh:
        return flows_header() + fh.read()


MCT_TITLE = "Derpy Resource Overhaul"
MCT_DESC = ("How goods move between settlement stores. These are fixed for the life of a campaign: "
            "change them from the main menu before starting a new one. In a multiplayer campaign "
            "they are ignored and every value is the default on every machine. The trade route lines "
            "can be changed at any time.")


# Shown on a greyed setting in a campaign: the values are frozen into the save (flows.lua).
MCT_LOCK = "Fixed when a campaign starts. Change it from the main menu before starting a new one."

# THE ROUTE LINES (author, 2026-10-22): how the campaign map draws trade routes. Neither locked nor frozen:
# they move no goods, so a campaign takes a new choice at the next redraw (terrain_routes.lua R.style).
# Values and their order: build_mr_terrain_routes.SIZES and COLOUR_SETS, which the scenes are built from.
ROUTE_OPTIONS = (
    ("route_size", "Line size", "How big the dashes of the trade route lines on the campaign map are. "
     "A change shows within a few seconds, in a campaign too.", "SIZES", "small"),
    ("route_colours", "Line colours", "The four colours of the trade route lines on the campaign map. Each "
     "faction's routes keep one of the four, so you can tell whose they are. A change shows within a few "
     "seconds, in a campaign too.", "COLOUR_SETS", "default"),
)
ROUTE_SWITCHES = (
    ('agreements', 'Trade agreements', 'Show agreement roads permitted by the resource import and export switches.'),
    ('contracts', 'Standing contracts', 'Show roads for enabled standing contracts.'),
    ('shipments', 'Travelling shipments', 'Show roads and markers for cargo already dispatched. Stopping future trade does not recall it.'),
    ('carts', 'Moving carts and boats', 'Show decorative minecarts on land and transport boats at sea. This does not change deliveries.'),
    ('icons', 'Resource icons above traffic', 'Show an available resource permitted by the trade switches. Shipment and contract vehicles show their assigned resource. Empty returns have no icon.'),
)


def mct_lua():
    lines = ["-- GENERATED by tools/gen_mr_ui.py - do not edit by hand.",
             "--",
             "-- MCT registration for Resource Overhaul's stores. MCT loads every .lua under",
             "-- script/mct/settings/, so this file only ever runs when MCT is installed. The",
             "-- campaign script freezes these values into the save at the first tick; the lock",
             "-- below only shows that in a campaign (MCT has no campaign gating of its own).",
             "",
             "local mct = get_mct and get_mct()",
             "if not mct then return end",
             "local IN_CAMPAIGN = __game_mode == __lib_type_campaign",
             'local LOCK_REASON = "%s"' % MCT_LOCK,
             "",
             'local m = mct:register_mod("derpy_more_resources")',
             'm:set_title("%s")' % MCT_TITLE,
             'm:set_author("_D3rpyN3wb_")',
             'm:set_description("%s")' % MCT_DESC,
             'm:add_new_section("stores", "Stores")']
    for k, label, tip, lo, hi, d in RATES:
        lines += ["",
                  'local o_%s = m:add_new_option("%s", "slider")' % (k, k),
                  'o_%s:set_text("%s")' % (k, label),
                  'o_%s:set_tooltip_text("%s")' % (k, tip),
                  "o_%s:slider_set_precision(0)" % k,
                  "o_%s:slider_set_min_max(%d, %d)" % (k, lo, hi),
                  "o_%s:slider_set_step_size(1, 0)" % k,
                  "o_%s:set_default_value(%d)" % (k, d),
                  'o_%s:set_assigned_section("stores")' % k,
                  "if IN_CAMPAIGN then o_%s:set_locked(true, LOCK_REASON) end" % k]
    for (k, label, tip, d), section in ((PROVISIONS_SWITCH, "using"), (PROCESSING_SWITCH, "using"), (SERVICES_SWITCH, "using"),
                                        (AI_SWITCH, "stores"), (SPOIL_SWITCH, "stores"), (UPKEEP_SWITCH, "using"),
                                        (ACTIONS_SWITCH, "using"), (EVENTS_SWITCH, "using"),
                                        (RANDOM_SWITCH, "using"), (SUPPLY_SWITCH, "using"), (RECRUIT_SWITCH, "using"),
                                        (ESCORT_SWITCH, "using"), (EDICT_SWITCH, "using"), (TOLL_SWITCH, "stores"),
                                        (BANDIT_SWITCH, "using")):
        if k == "upkeep":
            lines += ["", 'm:add_new_section("using", "Using stores")']
        lines += ["",
                  'local o_%s = m:add_new_option("%s", "checkbox")' % (k, k),
                  'o_%s:set_text("%s")' % (k, label),
                  'o_%s:set_tooltip_text("%s")' % (k, tip),
                  "o_%s:set_default_value(%s)" % (k, "true" if d else "false"),
                  'o_%s:set_assigned_section("%s")' % (k, section),
                  "if IN_CAMPAIGN then o_%s:set_locked(true, LOCK_REASON) end" % k]
    import build_mr_terrain_routes as T
    lines += ["", 'm:add_new_section("routes", "Trade route lines")']
    for kind, label, tip in ROUTE_SWITCHES:
        k='route_'+kind
        lines += ['', 'local o_%s = m:add_new_option("%s", "checkbox")' % (k,k),
                  'o_%s:set_text("%s")' % (k,label), 'o_%s:set_tooltip_text("%s")' % (k,tip),
                  'o_%s:set_default_value(true)' % k, 'o_%s:set_assigned_section("routes")' % k]
    for k, label, tip, source, default in ROUTE_OPTIONS:
        values = getattr(T, source)
        assert default in [v[0] for v in values], (k, default)
        lines += ["",
                  'local o_%s = m:add_new_option("%s", "dropdown")' % (k, k),
                  'o_%s:set_text("%s")' % (k, label),
                  'o_%s:set_tooltip_text("%s")' % (k, tip),
                  'o_%s:set_assigned_section("routes")' % k]
        lines += ['o_%s:add_dropdown_value("%s", "%s", "%s", %s)'
                  % (k, v[0], v[1], v[2], "true" if v[0] == default else "false") for v in values]
        lines.append('o_%s:set_default_value("%s")' % (k, default))
    k, label, tip = SIZE_OPTION
    assert [v[0] for v in SIZE_VALUES] == [SIZE_NAME[s] for s in ("_sm", "", "_lg")], SIZE_VALUES
    lines += ["",
              "-- DISPLAY ONLY: never locked and never frozen into the save. The panel reads it on every open,",
              "-- and set_is_global keeps it each player's own in multiplayer: it changes this screen alone.",
              'm:add_new_section("display", "Display")',
              'local o_size = m:add_new_option("%s", "dropdown")' % k,
              'o_size:set_text("%s")' % label,
              'o_size:set_tooltip_text("%s")' % tip]
    lines += ['o_size:add_dropdown_value("%s", "%s", "%s", %s)' % (v, t, d, "true" if v == "medium" else "false")
              for v, t, d in SIZE_VALUES]
    lines += ['o_size:set_default_value("medium")', 'o_size:set_assigned_section("display")',
              "o_size:set_is_global(true)"]
    return "\n".join(lines) + "\n"


def files():
    out = {}
    for name, build in BUILDERS:
        out[UI_REL + name + ".twui.xml"] = build()
        if name not in UNSIZED_FILES:
            for sfx in sorted(SIZES):
                out[UI_REL + name + sfx + ".twui.xml"] = build_at(build, sfx)
    out[LUA_REL] = stores_lua()
    out[FLOWS_REL] = flows_lua()
    out[MCT_REL] = mct_lua()
    import build_mr_terrain_routes
    out[PACK_REL + 'script/campaign/mod/derpy_more_resources_terrain_routes.lua'] = build_mr_terrain_routes.runtime()
    return out


def write_all(root=ROOT):
    for rel, text in files().items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)


def stale(root=ROOT):
    """[rel] - every shipped file that is missing or differs from what this builds."""
    out = []
    for rel, text in files().items():
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            out.append(rel)
            continue
        with io.open(path, encoding="utf-8", newline="") as fh:
            if fh.read() != text:
                out.append(rel)
    return out


def pack_paths():
    return [rel[len(PACK_REL):] for rel in files()]


def run_harness(harness=HARNESS, flows_text=None, stores_text=None):
    """A harness against the built files, from a temp folder: (returncode, output).
    __SCRIPT__ and __STORES__ are the stores script, __FLOWS__ the flows script, __MCT__ the MCT
    settings file and __UIDIR__ the folder the .twui.xml files are in."""
    tmp = tempfile.mkdtemp()
    try:
        built = files()
        if flows_text is not None:
            built[FLOWS_REL] = flows_text
        if stores_text is not None:
            built[LUA_REL] = stores_text
        for rel, text in built.items():
            with io.open(os.path.join(tmp, os.path.basename(rel)), "w", encoding="utf-8",
                         newline="\n") as fh:
                fh.write(text)
        fwd = tmp.replace("\\", "/")
        with io.open(harness, encoding="utf-8") as fh:
            h = fh.read()
        for token, rel in (("__SCRIPT__", LUA_REL), ("__STORES__", LUA_REL),
                           ("__FLOWS__", FLOWS_REL), ("__MCT__", MCT_REL)):
            h = h.replace(token, fwd + "/" + os.path.basename(rel))
        h = h.replace("__UIDIR__", fwd)
        hp = os.path.join(tmp, "harness.lua")
        with io.open(hp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(h)
        got = subprocess.run([LUA_EXE, hp], capture_output=True, text=True)
    finally:
        shutil.rmtree(tmp)
    return got.returncode, got.stdout + got.stderr


def check_economy_mutations():
    subject = flows_lua().replace("\r\n", "\n")
    mutations = (
        ("output capacity", "if d.output and F.free(region, d.output[1]) < F.output_n(faction, d) then", "if false then"),
        ("complete inputs", "if F.available_stock(v, stem) < n then", "if false then"),
        ("building health", 'd.levels[b:name()] and b:percent_health() == 100', 'd.levels[b:name()]'),
        ("province capital", 'if cap:is_null_interface() or cap:name() ~= region:name() then', 'if false then'),
        ("once per turn", '(not b or b.done ~= turn)', 'true'),
        ("named keep", 'held - F.FED_TURNS * named,', 'held,'),
        ("named import target", 'F.SHIP.ai_on * named - held - incoming,', ''),
        ("exact input debit", 'changes[#changes + 1] = { stem, -n, KIND.spend }',
         'changes[#changes + 1] = { stem, 0, KIND.spend }'),
        ("actual output", 'changes[#changes + 1] = { d.output[1], F.output_n(faction, d), KIND.process }',
         'changes[#changes + 1] = { d.output[1], 0, KIND.process }'),
        ("service benefit", 'cm:apply_effect_bundle_to_region(d.bundle, region:name(), F.BUNDLE_TURNS)', 'do end'),
        ("compensation", 'local delta = before[c[1]] - F.held(region, c[1])', 'local delta = 0'),
        ("AI budget", 'F.economy_admit(faction, region, d, 2)', 'F.economy_admit(faction, region, d, 1)'),
        ("AI named output", 'return (v.held[stem] or 0) + (v.incoming[stem] or 0) < target',
         'return F.import_need(v, stem) > 0'),
        ("trade share at least 1", "F.share(removable, pct)", "math.floor(removable * pct / 100)"),
        ("input cart computers only",
         "if faction:is_human() or not rates.ai or not F.uses_stores(faction) then return end",
         "if not rates.ai or not F.uses_stores(faction) then return end"),
        ("input cart switch", "if d.kind == kind and rates[kind] and F.economy_open(faction, region, d) then",
         "if d.kind == kind and F.economy_open(faction, region, d) then"),
        ("input cart wanted output", "local plan = F.economy_wanted(v, d) and {} or nil", "local plan = {}"),
        ("input cart covers two batches", "if not fit or fit.got < math.min(short, F.CART_MAX - F.lost(F.CART_MAX)) then",
         "if not fit then"),
        ("input cart full cart allowed", "fit.got < math.min(short, F.CART_MAX - F.lost(F.CART_MAX))", "fit.got < short"),
        ("input cart whole recipe", "then plan = nil; break end", "then break end"),
        ("input cart past reserves", "local have = F.room(v, stem) +", "local have = F.available_stock(v, stem) +"),
        ("input cart fill", "math.min(F.SHIP.ai_on * d.cost[stem] - have, free)", "math.min(short, free)"),
        ("input cart each turn", "    F.guard(F.economy_supply, faction)\n", ""),
        ("campaign switch", 'and F.rates()[kind] and F.economy_open(faction, region, d)',
         'and F.economy_open(faction, region, d)'),
        ("capture cleanup", '    F.economy_clear(region)\n    local ups', '    local ups'),
        ("price swing", "math.floor(F.PRICE_SWING * imbalance / F.PCT) + F.PCT", "F.PCT"),
        ("price spread", "math.floor(c * (F.SPREAD + F.PCT) / F.PCT)", "c"),
        ("cover clamp", "imbalance = clamp_pct(math.floor((F.SHIP.ai_on - cover) * F.PCT / F.SHIP.ai_on))",
         "imbalance = math.floor((F.SHIP.ai_on - cover) * F.PCT / F.SHIP.ai_on)"),
        ("fullness clamp", "imbalance = clamp_pct(F.PCT - math.floor(held * 200 / cap))",
         "imbalance = F.PCT - math.floor(held * 200 / cap)"),
        ("category cover", "local cover = math.floor((v.totals[g.use] or 0) / use)",
         "local cover = math.floor((v.held[stem] or 0) / use)"),
        ("sell at store price", "F.sell_price(F.local_price(v, stem, fkey))",
         "math.floor(F.price(F.GOOD[stem], fkey) * F.PCT)"),
        ("unpriced store", "if k > 0 and F.price_mult(v, stem) then", "if k > 0 then"),
        ("zero-pay lot", "\n            if pay > 0 then\n", "\n            if true then\n"),
        ("price gradient", "pd >= F.buy_price(ps)", "true"),
        ("price gradient boundary", "pd >= F.buy_price(ps)", "pd > F.buy_price(ps)"),
        ("price gradient keys",
         "local ps, pd = F.local_price(source, g.stem, exporter:name()), F.local_price(dest, g.stem, partner:name())",
         "local ps, pd = F.local_price(source, g.stem, partner:name()), F.local_price(dest, g.stem, exporter:name())"),
        ("trade from the cheapest store", "F.cheapest_store(sources, g.stem)", "F.fullest(sources, g.stem)"),
        ("cheapest store tie", "(mult == low and n > amount)", "(mult == low and n < amount)"),
        ("quote buy is the buy price", "buy = F.buy_price(price)", "buy = price"),
        ("quote sell is the sell price", "sell = F.sell_price(price)", "sell = price"),
        ("quote price from the base", "local price = F.gold(base, mult)", "local price = base"),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale mutation anchor: " + label
        mutated = subject.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
                                input=mutated, capture_output=True, text=True)
        assert syntax.returncode == 0, "invalid mutation %s: %s" % (label, syntax.stderr)
        code, out = run_harness(FLOWS_HARNESS, mutated)
        assert code != 0 and 'in function' in out and 'syntax' not in out, "survived or invalid: %s\n%s" % (label, out)
        print("  caught:", label)
    code, out = run_harness(FLOWS_HARNESS)
    assert code == 0, out
    print("economy mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_provision_mutations():
    subject = flows_lua().replace("\r\n", "\n")
    mutations = (
        ("army AI switch", 'or not (rates.ai or faction:is_human()) then return rows end', 'then return rows end'),
        ("starter half capacity", 'row.need * 5', 'row.need * 10'),
        ("starter issue registry", 'if not F.state.army_issued[row.id] then', 'if true then'),
        ("starter first meal", 'b.done = cm:model():turn_number()', 'b.done = -1'),
        ("starter food culture", 'biscuit and "hardtack" or "salted_meat"', '"grain"'),
        ("army duplicate meal", "if b.done ~= turn then", "if true then"),
        ("army reserve", "math.min(left, F.available_stock(view, g.stem))", "math.min(left, view.held[g.stem] or 0)"),
        ("army debit", 'unload and n or -n)', 'unload and n or 0)'),
        ("army transaction factor", 'F.PREFIX .. g.stem .. "_" .. KIND.move, unload', 'F.PREFIX .. g.stem .. "_move", unload'),
        ("army sea refill", 'if ch:is_at_sea() then return nil, "It cannot refill at sea." end', ''),
        ("undead army meals", 'or not F.eats(faction)\n        or not force:has_general()', 'or not F.uses_stores(faction)\n        or not force:has_general()'),
        ("field purchase stamp", 'b and b.field_turn == cm:model():turn_number()', 'false'),
        ("field payment confirmation", 'if paid ~= cost then', 'if false then'),
        ("human auto field spending", 'row.source or not faction:is_human()', 'true'),
        ("field ration cap", 'row.need * 2 - F.provision_total(b)', 'row.need * 10 - F.provision_total(b)'),
        ("army siege", 'if r:garrison_residence():is_under_siege() then return nil, "This settlement is under siege." end', ''),
        ("army unit need", 'local need = math.max(1, math.ceil(force:unit_list():num_items() / 4))', 'local need = 1'),
        ("army meal cargo", 'b.goods[g.stem] = b.goods[g.stem] - n', 'b.goods[g.stem] = b.goods[g.stem]'),
        ("army recovery", 'b.short = left == 0 and 0 or b.short + 1', 'b.short = b.short + 1'),
        ("army owner identity", 'force:faction():name() ~= b.f', 'false'),
        ("army unload pauses", 'if op == "unload" then b.auto = false end', 'do end'),
        ("army garrison exclusion", 'or force:is_armed_citizenry()', ''),
        ("army demand", 'out.provisions = (out.provisions or 0) + army_need', 'out.provisions = out.provisions or 0'),
        ("army reserve release", '- F.FED_TURNS * (v.recurring.army_need or 0)', '- 0'),
        ("army paused demand", 'and (not b or b.auto ~= false) then', 'then'),
        ("army relief dispatch", 'local ship = F.ship(faction, source.region, dest.region, g.stem, fit.n)', 'local ship = nil'),
        ("army relief export hold", 'F.stopped(seller:name(), "export", stem)', 'false'),
        ("army relief import hold", 'F.stopped(fkey, "import", stem) then return nil end', 'false then return nil end'),
        # Workshop reports, 2026-11-05 and 11-06
        ("Load stops at Auto's 5 turns", 'local target = full and row.cap or 5 * row.need', 'local target = 5 * row.need'),
        ("Load not told it is a Load", 'op == "unload", op == "load")', 'op == "unload", false)'),
        ("caravans eat", '        or F.NO_RATIONS[force:force_type():key()]\n', ''),
        ("convoys eat", 'CARAVAN = true, CONVOY = true', 'CARAVAN = true'),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale provision mutation: " + label
        changed = subject.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_harness(FLOWS_HARNESS, changed)
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    code, out = run_harness(FLOWS_HARNESS)
    assert code == 0, out
    print("provision mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_route_mutations():
    subject = flows_lua().replace("\r\n", "\n")
    mutations = (
        ("cart gross limit", 'math.min(n, F.CART_MAX, order and order.batch or F.CART_MAX, F.available_stock(source, stem))', 'math.min(n, order and order.batch or 1000000, F.available_stock(source, stem))'),
        ("saved arrival due", 'if turn >= F.ship_due(s) then', 'if turn - s.at >= F.SHIP.turns then'),
        ("recipient incoming", '(s.recipient or s.f) == fkey', '(s.sender or s.f) == fkey'),
        ("recurring once per turn", 'if o.enabled and o.done ~= turn then', 'if o.enabled then'),
        ("escrow debit", 'F.route_gold(faction, -escrow)', 'F.route_gold(faction, 0)'),
        ("checked stock debit", 'not F.route_goods(from, stem, -n)', 'false'),
        ("paid delivered only", 'math.min(s.escrow, F.gold(delivered, s.price_c))', 's.escrow'),
        ("origin price at dispatch", "local c = F.cart_price(seller, from, faction, to, stem)",
         "local c = DERPY_MR_FLOWS_SELL_RATE[F.GOOD[stem].use] * F.PCT"),
        ("cart floor at destination", "return math.max(F.buy_price(ps), pd and F.sell_price(pd) or 0)",
         "return F.buy_price(ps)"),
        ("cart floor keys", "local pd = F.local_price(F.stock_view(buyer, to), stem, buyer:name())",
         "local pd = F.local_price(F.stock_view(buyer, to), stem, seller:name())"),
        ("zero-gold cart", "if partner and escrow <= 0 then return nil end", ""),
        ("whole gold settlement", "math.min(s.escrow, F.gold(delivered, s.price_c))",
         "math.min(s.escrow, delivered * s.price_c / F.PCT)"),
        ("unpriced origin", "if partner and not F.price_mult(source, stem) then return nil end", ""),
        ("pool check at the source", 'if o.seller ~= faction:name() and not F.pool(from, o.stem) then return nil, "The seller cannot store it" end', ""),
        ("pool check is partner only", 'if o.seller ~= faction:name() and not F.pool(from, o.stem) then',
         'if not F.pool(from, o.stem) then'),
        ("own order stays free", "local partner = order and seller:name() ~= fkey", "local partner = order ~= nil"),
        ("unaffordable cart", "if escrow + toll > 0 and escrow + toll > faction:treasury() then return nil end", ""),
        ("saved cart migration", "F.sanitize_routes()\n    F.sanitize_ships()", "F.sanitize_routes()"),
        ("saved cart price in hundredths", "F.stock_number(s.price) and s.price * F.PCT or 0", "F.stock_number(s.price) and s.price or 0"),
        ("unpaid refund", 'local refund = s.escrow - pay', 'local refund = 0'),
        ("escrow settlement once", 'if not s.sender or s.settled then return end', 'if not s.sender then return end'),
        ("contract cancellation", 'for _, s in ipairs(carts) do F.route_return(s) end', 'do end'),
        ("dead party money loss", 'and v[3] or "lost"', 'and v[3] or "refunded"'),
        ("standing route replacement", 'and not F.route_covers(faction, cap:name(), use)', ''),
        # agreement cargo, task 5: a shipment with a saved road takes the road's length in hexes (F.route_turns, F.ship)
        ("road length duration", "math.ceil(F.road_steps(road) / F.ROAD_PER_TURN)", "1"),
        ("road counts points", "math.ceil(F.road_steps(road) / F.ROAD_PER_TURN)", "math.ceil(#road / F.ROAD_PER_TURN)"),
        ("road counts points less one", "math.ceil(F.road_steps(road) / F.ROAD_PER_TURN)", "math.ceil((#road - 1) / F.ROAD_PER_TURN)"),
        ("road ceiling of six", "math.min(6, math.ceil(F.road_steps(road) / F.ROAD_PER_TURN))", "math.ceil(F.road_steps(road) / F.ROAD_PER_TURN)"),
        ("empty road is no road", "if road and #road > 0 then\n        return math.max(1, math.min(6,",
         "if road then\n        return math.max(1, math.min(6,"),
        ("shipment saves its road's time", "s.duration = F.route_turns(from, to, road)", "s.duration = F.route_turns(from, to)"),
        # no road: the panel's figure is a lower bound, the longer span, not the Euclidean distance
        ("no road: euclidean distance", "math.ceil(math.max(math.abs(dx), math.abs(dy)) / F.ROAD_PER_TURN)",
         "math.ceil(math.sqrt(dx * dx + dy * dy) / F.ROAD_PER_TURN)"),
        ("no road: the y span counts", "math.ceil(math.max(math.abs(dx), math.abs(dy)) / F.ROAD_PER_TURN)",
         "math.ceil(math.abs(dx) / F.ROAD_PER_TURN)"),
        ("no road floor of one", "return math.max(1, math.min(6, math.ceil(math.max(math.abs(dx), math.abs(dy)) / F.ROAD_PER_TURN)))",
         "return math.min(6, math.ceil(math.max(math.abs(dx), math.abs(dy)) / F.ROAD_PER_TURN))"),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale route mutation: " + label
        changed = subject.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_harness(FLOWS_HARNESS, changed)
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    code, out = run_harness(FLOWS_HARNESS)
    assert code == 0, out
    print("route mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_convoy_mutations():
    """Agreement cargo (spec 2026-10-23, 5.1): each rule of the convoy that leaves, broken once."""
    subject = flows_lua().replace("\r\n", "\n")
    mutations = (
        ("duration clamp", "math.max(1, math.min(F.rates().reach, math.ceil(F.road_steps(path) / F.ROAD_PER_TURN)))", "1"),
        # a road is its hexes: a bridge is one point and as many hexes as the reach search charged it (F.road_steps)
        ("convoy road counts points", "math.max(1, math.abs(path[i][1] - path[i - 1][1]), math.abs(path[i][2] - path[i - 1][2]))", "1"),
        ("convoy turns count points less one", "math.ceil(F.road_steps(path) / F.ROAD_PER_TURN)", "math.ceil((#path - 1) / F.ROAD_PER_TURN)"),
        ("road hexes ignore the y span", ", math.abs(path[i][2] - path[i - 1][2]))", ")"),
        ("road hex is at least one", "steps = steps + math.max(1, math.abs(", "steps = steps + math.max(0, math.abs("),
        ("dispatch debit", "F.route_goods(p.source.region, p.stem, -p.n, KIND.trade)", "true"),
        ("road from the exporter", "if path[1][1] ~= hx or path[1][2] ~= hy then path = F.reverse(path) end", "do end"),
        ("trade guarded", "F.guard(F.trade, faction)", "F.trade(faction)"),
        ("refused debit", "if F.route_goods(p.source.region, p.stem, -p.n, KIND.trade) then",
         "if F.route_goods(p.source.region, p.stem, -p.n, KIND.trade) or true then"),
        ("one convoy per partner", "convoy = convoy or F.convoy_new(", "convoy = F.convoy_new("),
        ("departure ledger line", 'F.log(exporter:name(), p.stem, KIND.trade .. "_out", p.n)', "do end"),
        ("reverse is a copy", "    local out = {}\n    for i = #list, 1, -1 do out[#out + 1] = list[i] end\n    return out",
         "    local n = #list\n    for i = 1, math.floor(n / 2) do list[i], list[n + 1 - i] = list[n + 1 - i], list[i] end\n    return list"),
        ("convoy sequence", "F.state.convoy_seq = (F.state.convoy_seq or 0) + 1", "F.state.convoy_seq = 1"),
        # Task 2: cargo on the road counts as incoming (F.ships_to)
        ("convoy incoming", "if c.buyer == fkey and c.to == rkey then", "if false then"),
        ("convoy read creates no list", "return F.state.convoys or {}",
         "F.state.convoys = F.state.convoys or {}; return F.state.convoys"),
        ("empty basket entry", "if n and n > 0 and (stem == nil or g.stem == stem) then",
         "if n and (stem == nil or g.stem == stem) then"),
        ("convoy buyer", "if c.buyer == fkey and c.to == rkey then", "if c.to == rkey then"),
        ("convoy store", "if c.buyer == fkey and c.to == rkey then", "if c.buyer == fkey then"),
        ("convoy stem filter", "if n and n > 0 and (stem == nil or g.stem == stem) then", "if n and n > 0 then"),
        ("convoy goods order", "            for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do\n                local n = c.basket[g.stem]",
         "            for key, n in pairs(c.basket) do\n                local g = { stem = key }"),
        ("convoy arrival turn", "due = due, convoy = c.id }", "due = c.at + F.SHIP.turns, convoy = c.id }"),
        # the turn a human buyer is told (F.convoy_due): a convoy lands at its exporter's turn start, a turn after the
        # human's own start in that round, so a computer exporter's convoy is usable a turn later than it lands
        ("convoy due loses its turn", "return c.due + 1 end", "return c.due end"),
        ("convoy due condition inverted", "if buyer and buyer:is_human() and not (ex and ex:is_human()) then",
         "if not (buyer and buyer:is_human() and not (ex and ex:is_human())) then"),
        ("convoy incoming reports the landing", "due = due or F.convoy_due(c)\n", "due = due or c.due\n"),
        ("convoy cargo reports the landing", "due = F.convoy_due(c),\n", "due = c.due,\n"),
        # the contract cart half of the same count: a free trade that ignored it would send the whole need again
        ("shipments incoming",
         "if (s.recipient or s.f) == fkey and s.to == rkey and (stem == nil or s.stem == stem) then out[#out + 1] = s end",
         "do end"),
        # Task 3: stepping, arrival, seizure, return, sweep (F.convoys_turn and what it calls)
        ("arrival at the current capital", "local to = F.capital(buyer)", "local to = cm:get_region(c.to)"),
        ("convoy seizure removes", "if not F.convoy_drop(c) then return end\n    for stem, n in pairs(c.basket) do F.move(nil, F.nearest(captor",
         "for stem, n in pairs(c.basket) do F.move(nil, F.nearest(captor"),
        ("war returns convoy", "then F.convoy_return(c)", "then F.convoy_drop(c)"),
        ("enemy cache per turn", "if hit and hit.turn == turn then return hit.list end", "if false then return hit.list end"),
        ("convoys at turn start", "F.guard(F.convoys_turn, faction)\n    F.guard(F.ships_turn, faction)", "F.guard(F.ships_turn, faction)"),
        ("convoys of this exporter", "if c.f == fkey then mine[#mine + 1] = c end", "mine[#mine + 1] = c"),
        ("convoy arrival day", "elseif turn >= c.due then F.convoy_arrive(c)", "elseif turn > c.due then F.convoy_arrive(c)"),
        ("convoys in id order", "for _, c in ipairs(mine) do\n        local buyer", "for _, c in ipairs(F.reverse(mine)) do\n        local buyer"),
        ("convoy step index", "math.floor((#road - 1) * elapsed / duration) + 1", "math.floor((#road - 1) * elapsed / duration) + 2"),
        ("convoy seizure asked", "local captor = c.x and c.y and F.captor(faction, c)", "local captor = nil"),
        ("convoy with no position", "local captor = c.x and c.y and F.captor(faction, c)", "local captor = F.captor(faction, c)"),
        ("convoy treaty gone", "or not F.partners(faction, buyer) then F.convoy_return(c)", "then F.convoy_return(c)"),
        ("convoy landless buyer", "or not F.capital(buyer) or", "or"),
        ("convoy dead buyer", "if not buyer or not F.capital(buyer)", "if not F.capital(buyer)"),
        ("return to the nearest", "to = F.nearest(exporter, c.x, c.y) elseif", "to = F.capital(exporter) elseif"),
        ("return without a position", "elseif exporter then to = F.capital(exporter) end", "end"),
        ("arrival books traded", "F.move(nil, to, stem, n, KIND.trade, nil, c.buyer)", "F.move(nil, to, stem, n, KIND.move, nil, c.buyer)"),
        ("seizure books raided", "F.nearest(captor, c.x, c.y), stem, n, KIND.raid, nil, captor:name())",
         "F.nearest(captor, c.x, c.y), stem, n, KIND.move, nil, captor:name())"),
        ("return books moved", "F.move(nil, to, stem, n, KIND.move, nil, c.f)", "F.move(nil, to, stem, n, KIND.move, nil, nil)"),
        ("arrival drops first",
         "    if not F.convoy_drop(c) then return end\n    local buyer = F.live(c.buyer)\n    local to = F.capital(buyer)\n    for stem, n in pairs(c.basket) do F.move(nil, to, stem, n, KIND.trade, nil, c.buyer) end",
         "    local buyer = F.live(c.buyer)\n    local to = F.capital(buyer)\n    for stem, n in pairs(c.basket) do F.move(nil, to, stem, n, KIND.trade, nil, c.buyer) end\n    F.convoy_drop(c)"),
        ("seizure drops first",
         "    if not F.convoy_drop(c) then return end\n    for stem, n in pairs(c.basket) do F.move(nil, F.nearest(captor, c.x, c.y), stem, n, KIND.raid, nil, captor:name()) end",
         "    for stem, n in pairs(c.basket) do F.move(nil, F.nearest(captor, c.x, c.y), stem, n, KIND.raid, nil, captor:name()) end\n    F.convoy_drop(c)"),
        ("return drops first",
         "    if not F.convoy_drop(c) then return end\n    local exporter, to = F.live(c.f), nil\n    if exporter and c.x then to = F.nearest(exporter, c.x, c.y) elseif exporter then to = F.capital(exporter) end\n    for stem, n in pairs(c.basket) do F.move(nil, to, stem, n, KIND.move, nil, c.f) end",
         "    local exporter, to = F.live(c.f), nil\n    if exporter and c.x then to = F.nearest(exporter, c.x, c.y) elseif exporter then to = F.capital(exporter) end\n    for stem, n in pairs(c.basket) do F.move(nil, to, stem, n, KIND.move, nil, c.f) end\n    F.convoy_drop(c)"),
        ("arrival once", "    if not F.convoy_drop(c) then return end\n    local buyer = F.live(c.buyer)",
         "    F.convoy_drop(c)\n    local buyer = F.live(c.buyer)"),
        ("convoy follows the capital", "                c.to = F.capital(buyer):name()\n", ""),
        # onto the pair's road of the day (live check 2026-10-24: 17 hexes off the drawn road), F.convoy_on
        ("convoy keeps yesterday's road", "            if x then c.road, c.x, c.y = F.pack_road(road), x, y end\n", ""),
        ("convoy moved but its road not saved", "if x then c.road, c.x, c.y = F.pack_road(road), x, y end", "if x then c.x, c.y = x, y end"),
        ("convoy moved after the army check",
         "            local open, _, path = F.trade_reach(faction, buyer)\n            local x, y, road = F.convoy_on(c, open and path)\n"
         "            if x then c.road, c.x, c.y = F.pack_road(road), x, y end\n            -- a convoy with no position has no army near it\n"
         "            local captor = c.x and c.y and F.captor(faction, c)\n",
         "            -- a convoy with no position has no army near it\n            local captor = c.x and c.y and F.captor(faction, c)\n"
         "            local open, _, path = F.trade_reach(faction, buyer)\n            local x, y, road = F.convoy_on(c, open and path)\n"
         "            if x then c.road, c.x, c.y = F.pack_road(road), x, y end\n"),
        ("convoy takes a cut-off road", "F.convoy_on(c, open and path)", "F.convoy_on(c, path)"),
        ("today's road not turned to the exporter",
         "if path[1][1] ~= s[1] or path[1][2] ~= s[2] then path = F.reverse(path) end", "do end"),
        ("convoy takes a road from elsewhere", "    if path[1][1] ~= s[1] or path[1][2] ~= s[2] then return nil end\n", ""),
        ("convoy keeps its point number", "local j = math.floor((#path - 1) * (i - 1) / math.max(1, #road - 1)) + 1",
         "local j = math.min(#path, i)"),
        ("the maps get no road", "x = c.x, y = c.y, road = c.road, stem", "x = c.x, y = c.y, stem"),
        ("return needs a settlement", "if exporter and c.x then to = F.nearest(exporter, c.x, c.y) elseif exporter then",
         "if exporter and c.x then to = F.nearest(exporter, c.x, c.y) or cm:get_region(c.from) elseif exporter then"),
        ("destroyed force skipped", "if mf and not mf:is_null_interface() and f and not f:is_null_interface() then",
         "if f and not f:is_null_interface() then"),
        ("garrison is no army", "\n                if not mf:is_armed_citizenry() and mf:has_general() then",
         "\n                if mf:has_general() then"),
        ("sweep dead exporters", "if not F.live(convoys[i].f) then table.remove(convoys, i) end", "if false then table.remove(convoys, i) end"),
        ("sweep keeps living ones", "if not F.live(convoys[i].f) then table.remove(convoys, i) end", "if true then table.remove(convoys, i) end"),
        # Task 4: the load keeps only what the convoy code can read (F.convoy_sound, F.sanitize_convoys)
        ("convoy due not before at", "and c.due >= c.at)", "and true)"),
        ("convoy id end anchored", 'F.CONVOY_PREFIX .. "(%d+)$")', 'F.CONVOY_PREFIX .. "(%d+)")'),
        ("convoy id start anchored", 'string.match(c.id, "^" .. F.CONVOY_PREFIX', "string.match(c.id, F.CONVOY_PREFIX"),
        ("convoy id whole", "if not (n and F.stock_number(n)) then", "if not n then"),
        ("convoy exporter string", 'type(c.f) == "string" and', "true and"),
        ("convoy buyer string", 'type(c.buyer) == "string" and', "true and"),
        ("convoy from string", 'type(c.from) == "string" and', "true and"),
        ("convoy to string", 'and type(c.to) == "string")', "and true)"),
        ("convoy basket a table", 'type(c.basket) ~= "table" or next(c.basket) == nil', "next(c.basket) == nil"),
        ("convoy basket not empty", " or next(c.basket) == nil then", " then"),
        ("convoy basket goods only", "if not (F.GOOD[stem] and F.stock_number(k) and k > 0) then",
         "if not (F.stock_number(k) and k > 0) then"),
        ("convoy amount whole", "F.stock_number(k) and k > 0", 'type(k) == "number" and k > 0'),
        ("convoy amount positive", "F.stock_number(k) and k > 0", "F.stock_number(k)"),
        ("convoy at whole", "F.stock_number(c.at) and F.stock_number(c.due)", 'type(c.at) == "number" and F.stock_number(c.due)'),
        ("convoy due whole", "F.stock_number(c.at) and F.stock_number(c.due)", 'F.stock_number(c.at) and type(c.due) == "number"'),
        ("convoy position pair", "if (c.x ~= nil or c.y ~= nil) and not (", "if (c.x ~= nil and c.y ~= nil) and not ("),
        ("convoy position whole", "not (F.stock_number(c.x) and F.stock_number(c.y))", "not F.stock_number(c.x)"),
        ("convoy position optional", "if (c.x ~= nil or c.y ~= nil) and not (", "if not ("),
        ("convoy road parses", "if c.road ~= nil and not F.unpack_road(c.road) then", 'if c.road ~= nil and type(c.road) ~= "string" then'),
        ("convoy road optional", "if c.road ~= nil and not F.unpack_road(c.road) then", "if not F.unpack_road(c.road) then"),
        ("convoy record a table", 'if type(c) ~= "table" or type(c.id) ~= "string" then', 'if type(c.id) ~= "string" then'),
        ("convoy kept ids move the sequence", "clean[#clean + 1] = c; max_id = math.max(max_id, n)", "clean[#clean + 1] = c"),
        ("convoy saved sequence kept", "F.stock_number(F.state.convoy_seq) and F.state.convoy_seq or 0)", "0)"),
        ("old save makes no convoy list", 'F.state.convoys = type(list) == "table" and clean or nil', "F.state.convoys = clean"),
        ("convoys sanitized at load", "F.sanitize_ships()\n    F.sanitize_convoys()", "F.sanitize_ships()"),
        # Task 6: what the Vault and the maps read (F.convoy_cargo)
        ("cargo of a dead exporter", "if F.live(c.f) then\n            local stem, n", "if true then\n            local stem, n"),
        ("cargo skips a convoy with no position", "if F.live(c.f) then\n            local stem, n",
         "if c.x and c.y and F.live(c.f) then\n            local stem, n"),
        ("cargo largest good", "if not n or v > n or (v == n and k < stem) then", "if not n or v < n or (v == n and k < stem) then"),
        ("cargo ties to the lower stem", "or (v == n and k < stem) then stem, n = k, v end", "then stem, n = k, v end"),
        ("cargo ties to the upper stem", "(v == n and k < stem)", "(v == n and k > stem)"),
        ("cargo names the buyer", "id = c.id, f = c.f, buyer = c.buyer, from = c.from,", "id = c.id, f = c.f, from = c.from,"),
        ("cargo is marked a convoy", "stem = stem, n = n, basket = c.basket, convoy = true }", "stem = stem, n = n, basket = c.basket }"),
        ("cargo read creates no list", "for _, c in ipairs(F.convoys()) do\n        if F.live(c.f) then",
         "F.state.convoys = F.state.convoys or {}\n    for _, c in ipairs(F.convoys()) do\n        if F.live(c.f) then"),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale convoy mutation: " + label
        changed = subject.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_harness(FLOWS_HARNESS, changed)
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    code, out = run_harness(FLOWS_HARNESS)
    assert code == 0, out
    print("convoy mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_map_road_mutations():
    """The Map tab's roads (the 3D map's links): each rule broken once, the stores harness must fail."""
    subject = stores_lua().replace("\r\n", "\n")
    mutations = (
        ("framed on the realm", "grow(point[1], point[2], r.own)", "grow(point[1], point[2], true)"),
        ("surface carries all", "local sx1, sy1 = px(all[3], all[4])", "local sx1, sy1 = px(x1, y1)"),
        ("dot cap", "if #m.path >= L.MAP_PATH_MAX then break end", ""),
        ("road colour", 'place("path" .. d.colour,', 'place("path2",'),
        ("every third point", "if visible[i] and i % 3 == 1 then road[#road + 1]", "if visible[i] then road[#road + 1]"),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale map road mutation: " + label
        code, out = run_harness(HARNESS, stores_text=subject.replace(before, after, 1))
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    print("map road mutations: %d/%d caught" % (len(mutations), len(mutations)))


TERRAIN_SRC = os.path.join(ROOT, "Modding Files", "source", "resource_overhaul", "terrain_routes.lua")
TERRAIN_HARNESS = os.path.join(ROOT, "tools", "_resource_terrain_routes_harness.lua")


def run_terrain_harness(changed=None):
    """The 3D map's harness, from the workspace root: (returncode, output), against `changed` text
    in place of terrain_routes.lua when one is given."""
    tmp = tempfile.mkdtemp()
    try:
        with io.open(TERRAIN_HARNESS, encoding="utf-8", newline="") as fh:
            h = fh.read()
        if changed is not None:
            src = os.path.join(tmp, "terrain_routes.lua")
            with io.open(src, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(changed)
            old = "dofile('Modding Files/source/resource_overhaul/terrain_routes.lua')"
            assert h.count(old) == 1, "the terrain harness loads its script some other way"
            h = h.replace(old, "dofile('" + src.replace("\\", "/") + "')")
        hp = os.path.join(tmp, "harness.lua")
        with io.open(hp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(h)
        got = subprocess.run([LUA_EXE, hp], cwd=ROOT, capture_output=True, text=True)
    finally:
        shutil.rmtree(tmp)
    return got.returncode, got.stdout + got.stderr


def _why(out):
    """The assertion a harness stopped on: the message after `file:line:` in its first line."""
    line = out.strip().splitlines()[0] if out.strip() else ""
    found = re.search(r"\.lua:\d+: (.*)$", line)
    return (found.group(1) if found else line)[:110]


def check_cargo_view_mutations():
    """Agreement cargo, Task 6: who sees a convoy and how it is drawn. The Vault (stores_panel.lua) and the 3D
    map (terrain_routes.lua), each rule broken once; the harness of the file must fail."""
    luac = LUA_EXE.replace("lua.exe", "luac.exe")
    stores = stores_lua().replace("\r\n", "\n")
    panel = (
        ("trade row counts only convoys going out", "if c.f == fk or c.buyer == fk then out[#out + 1] = c end",
         "if c.f == fk then out[#out + 1] = c end"),
        ("trade row counts only convoys coming in", "if c.f == fk or c.buyer == fk then out[#out + 1] = c end",
         "if c.buyer == fk then out[#out + 1] = c end"),
        ("trade row counts a stranger's convoys", "if c.f == fk or c.buyer == fk then out[#out + 1] = c end",
         "out[#out + 1] = c"),
        ("trade row skips a convoy with no position", "if c.f == fk or c.buyer == fk then out[#out + 1] = c end",
         "if c.x and (c.f == fk or c.buyer == fk) then out[#out + 1] = c end"),
        ("trade row out and in swapped", "if c.f == fk then out = out + 1 end", "if c.buyer == fk then out = out + 1 end"),
        ("trade row with nothing on the road", "if #convoys > 0 then", "if true then"),
        ("basket largest first", "return basket[a] > basket[b] end", "return basket[a] < basket[b] end"),
        ("basket equal amounts by name", "        return a < b\n    end)\n    local parts = {}\n    for _, stem in",
         "        return a > b\n    end)\n    local parts = {}\n    for _, stem in"),
        ("tooltip names the arrival turn", '" by turn " .. tostring(c.due)', '" by turn " .. tostring(c.at)'),
        ("tooltip names every convoy", "for i = 1, math.min(#soon, S.CONVOY_LINES) do", "for i = 1, #soon do"),
        ("tooltip names the latest first", "if a.due ~= b.due then return a.due < b.due end",
         "if a.due ~= b.due then return a.due > b.due end"),
        ("map draws a stranger's convoys", "and S.convoys_of(faction:name()) or {}) do\n",
         'and S.ask("convoy_cargo") or {}) do\n'),
        ("map convoys ignore the shipments switch",
         "ipairs((not routes or routes.shown('shipments')) and S.convoys_of(faction:name()) or {}) do\n",
         "ipairs(S.convoys_of(faction:name())) do\n"),
        ("map draws a convoy with no position", "if s.x and s.y then\n            local c = cart(s)", "do\n            local c = cart(s)"),
        ("map tooltip lists the basket", "local what = s.convoy and S.basket_text(s.basket) or (", "local what = ("),
        # a far convoy stays on the surface and out of the frame, as a foreign road does
        ("map frames a convoy's cart", "framed = not s.convoy }", "framed = true }"),
        # convoys on one spot: one cart, whose tooltip lists them
        ("map draws every convoy on a spot", "if stacked[spot] then", "if false then"),
        ("map stacked cart names one convoy", "c.stack and #c.stack > 1 and S.convoy_tip(c.stack) or S.ship_tip(c.s)",
         "S.ship_tip(c.s)"),
        ("tooltip types the hexes", "((sh and sh.near) or 3)", "3"),
        ("tooltip equal turns by id text", "if seq(a) ~= seq(b) then return seq(a) < seq(b) end\n        return a.id < b.id",
         "return a.id < b.id"),
    )
    for label, before, after in panel:
        assert stores.count(before) == 1, "stale cargo view mutation: " + label
        code, out = run_harness(HARNESS, stores_text=stores.replace(before, after, 1))
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    with io.open(TERRAIN_SRC, encoding="utf-8", newline="") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    cond = "c.f == faction:name() or c.buyer == faction:name() or (known[c.f] and visible[c.from] and visible[c.to])"
    markers = (
        ("convoy guard", "F.convoy_cargo and F.convoy_cargo() or {}", "F.convoy_cargo() or {}"),
        ("convoys follow the shipments switch", "R.shown('shipments') and F.convoy_cargo and F.convoy_cargo() or {}",
         "F.convoy_cargo and F.convoy_cargo() or {}"),
        ("convoy of the viewer's own", cond, cond.replace("c.f == faction:name() or ", "")),
        ("convoy bound for the viewer", cond, cond.replace("c.buyer == faction:name() or ", "")),
        ("convoy of a stranger", cond, "true"),
        ("convoy of an unmet faction", cond, cond.replace("known[c.f] and ", "")),
        ("convoy start in the fog", cond, cond.replace("visible[c.from] and ", "")),
        ("convoy end in the fog", cond, cond.replace(" and visible[c.to]", "")),
        ("convoy with no x", "if c.x and c.y and (", "if c.y and ("),
        ("convoy with no y", "if c.x and c.y and (", "if c.x and ("),
        ("convoy draws its own line", "            cargo[#cargo + 1] = c\n",
         "            add(c.f, c.from, c.to, nil, {{c.stem},{}})\n            cargo[#cargo + 1] = c\n"),
        ("convoy marker", "            cargo[#cargo + 1] = c\n", "            do end\n"),
        # the decal budget: a convoy's marker only near the camera, a shipment's as before
        ("convoy marker without the camera test", "if near and count < 512 then", "if count < 512 then"),
        ("shipment marker with the camera test", "        if s.convoy then\n            near = R.in_view(",
         "        if true then\n            near = R.in_view("),
    )
    for label, before, after in markers:
        assert terrain.count(before) == 1, "stale cargo view mutation: " + label
        changed = terrain.replace(before, after, 1)
        syntax = subprocess.run([luac, "-p", "-"], input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_terrain_harness(changed)
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    code, out = run_terrain_harness()
    assert code == 0, out
    print("cargo view mutations: %d/%d caught; restored harnesses pass" % (len(panel) + len(markers), len(panel) + len(markers)))


def check_reach_mutations():
    """Kept reach answers (2026-10-29): R.reach gives a road again only while every region its search looked at
    judges the same, so a kept answer is the one a new search would give. Each rule broken once; the terrain
    harness must fail."""
    luac = LUA_EXE.replace("lua.exe", "luac.exe")
    with io.open(TERRAIN_SRC, encoding="utf-8", newline="") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    kept = "if not (memo and memo.data == g.data and R.unchanged(memo.regions, from, to)) then"
    mutations = (
        ("kept answer never checked", kept, "if not (memo and memo.data == g.data) then"),
        ("kept answer never given", kept, "if true then"),
        ("kept answer outlives the map", kept, "if not (memo and R.unchanged(memo.regions, from, to)) then"),
        ("reach left out of the key", " .. '>' .. tostring(max)", ""),
        ("no shortcut for a pair with no road at all",
         "    if free and not free.open and free.finished then return false, 'far' end\n", ""),
        ("a search that gave up taken as proof", "if free and not free.open and free.finished then",
         "if free and not free.open then"),
        ("road through enemy land outlives the map", "    if free and free.data ~= g.data then free = nil end\n", ""),
        ("only a region turned friendly is noticed", "if not region or region:is_null_interface() or judge(region) ~= was then",
         "if was and judge(region) ~= was then"),
        ("no such region taken as unchanged", "if not region or region:is_null_interface() or judge(region) ~= was then",
         "if region and judge(region) ~= was then"),
        ("heap sifts down to the larger child", "if child < n and F[child + 1] < F[child] then child = child + 1 end",
         "if child < n and F[child + 1] > F[child] then child = child + 1 end"),
        ("heap push never rises", "if F[parent] <= f then break end", "if true then break end"),
    )
    for label, before, after in mutations:
        assert terrain.count(before) == 1, "stale reach mutation: " + label
        changed = terrain.replace(before, after, 1)
        syntax = subprocess.run([luac, "-p", "-"], input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_terrain_harness(changed)
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    code, out = run_terrain_harness()
    assert code == 0, out
    print("reach mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_drag_mutations():
    """Dragging the map (2026-10-29): a camera move only places what is near the camera, the timed refresh
    waits for the camera to stop, a change does not, and a road is converted to display positions and deduplicated once.
    Each rule broken once; the terrain harness must fail."""
    luac = LUA_EXE.replace("lua.exe", "luac.exe")
    with io.open(TERRAIN_SRC, encoding="utf-8", newline="") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    full = "if R.dirty or (R.stale and not moved) or not R.drawn then"
    mutations = (
        ("a camera move works the links out again", "if moved and R.drawn then", "if false then"),
        ("the timed refresh runs mid-drag", full, "if R.dirty or R.stale or not R.drawn then"),
        ("a change waits for the camera to stop", full, "if (R.stale and not moved) or not R.drawn then"),
        ("the timed refresh never settles", "            R.dirty, R.stale = false, false\n", "            R.dirty = false\n"),
        ("a road converted on every refresh", "    local d = R.shown_at[path]\n", "    local d = nil\n"),
        ("shared stretches worked out on every move", "local visible = unshared[link]", "local visible = nil"),
    )
    for label, before, after in mutations:
        assert terrain.count(before) == 1, "stale drag mutation: " + label
        changed = terrain.replace(before, after, 1)
        syntax = subprocess.run([luac, "-p", "-"], input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_terrain_harness(changed)
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    code, out = run_terrain_harness()
    assert code == 0, out
    print("drag mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_map_cost_mutations():
    """The map at a war or diplomatic event (2026-10-29): a shown road is given back unsearched while its land judges
    the same, the network is bundled again only when a road changes or the player's turn starts, the cart goods'
    previews are kept and renewed one seller at a time, and a refresh works out new reach answers for a time budget,
    keeping an agreement's last line up until its answer is worked out (2026-10-30), and the shared stretches of a
    network that came back unchanged. Each rule broken once; the terrain harness (or, for flows.lua, the flows
    harness) must fail."""
    luac = LUA_EXE.replace("lua.exe", "luac.exe")
    with io.open(TERRAIN_SRC, encoding="utf-8", newline="") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    kept = "if kept and kept.data == R.grid.data and R.unchanged(kept.regions, a, b) then"
    show = "if open == nil and (R.shows == 0 or os.clock() < R.show_until) then"
    mutations = (
        ("kept road never checked", kept, "if kept and kept.data == R.grid.data then"),
        ("kept road never given", kept, "if false then"),
        ("kept road outlives its map", kept, "if kept and R.unchanged(kept.regions, a, b) then"),
        ("a finished search keeps nothing",
         "        if j.regions then R.kept[j.key] = { path = path or false, regions = j.regions, data = j.g.data } end\n", ""),
        ("a search records no verdicts", "local avoid = R.avoider(a, b, regions)", "local avoid = R.avoider(a, b)"),
        ("every event bundles the network again", "if not cached or #cached.raw~=#links then same=false end",
         "same=false"),
        ("the player's turn keeps the old network", "R.epoch, R.dirty, R.network_cache, R.bundled = R.epoch + 1, true, nil, {}",
         "R.epoch, R.dirty, R.bundled = R.epoch + 1, true, {}"),
        # 2026-11-07, Workshop reports of a stuttering map: 85 bundles a refresh at 121 links
        ("the player's turn keeps the old bundles", "R.epoch, R.dirty, R.network_cache, R.bundled = R.epoch + 1, true, nil, {}",
         "R.epoch, R.dirty, R.network_cache = R.epoch + 1, true, nil"),
        ("any change bundles every link",
         "if was and was.raw == link.path and was.owner == link.owner and was.own == link.own then", "if false then"),
        ("a kept bundle outlives its road", "was.raw == link.path and ", ""),
        ("a kept bundle outlives its owner", "was.owner == link.owner and ", ""),
        ("bundles never kept", "    R.bundled = kept\n", ""),
        ("a search keeps its hexes on the grid", "                        neighbours[near] = other\n",
         "                        neighbours[near] = other\n                        g.kept_hexes = g.kept_hexes or {}; g.kept_hexes[id] = true\n"),
        ("cart goods worked out every refresh", "local links, cargo, seen, owned, plans, used = {}, {}, {}, {}, R.plans, {}",
         "local links, cargo, seen, owned, plans, used = {}, {}, {}, {}, {}, {}"),
        ("cart goods never dropped",
         "    for seller in pairs(plans) do if not used[seller] then plans[seller] = nil end end   -- renew only what is drawn\n", ""),
        ("renewal stuck on one seller", "R.plan_next = (R.plan_next or 0) % #sellers + 1", "R.plan_next = 1"),
        ("cart goods never renewed", "            R.renew_plan()   -- never on a tick that already refreshed\n", ""),
        ("one reach answer a refresh whatever the time", show, "if open == nil and R.shows == 0 then"),
        ("reach answers without a time budget", show, "if open == nil then"),
        ("a line still to work out is dropped", "                                if was then open, road = was[1], was[2] end\n", ""),
        ("a line with no answer yet is drawn", "if was then open, road = was[1], was[2] end",
         "if was then open, road = was[1], was[2] else open = true end"),
        ("the drawn answer is never kept",
         "                            if open ~= nil then R.reach_shown[pair] = { open, road } end\n", ""),
        ("an unchanged network has its shared stretches worked out again",
         "unshared = R.drawn and R.drawn[1] == links and R.drawn[3] or {}", "unshared = {}"),
        ("a changed network keeps the old shared stretches",
         "unshared = R.drawn and R.drawn[1] == links and R.drawn[3] or {}", "unshared = R.drawn and R.drawn[3] or {}"),
        # a convoy's marker on its pair's road of the day (2026-11-01), worked out again only when something moved
        ("convoy marker on the road it left on", "            if s[5] then c.x, c.y = s[5], s[6] end\n", ""),
        ("convoy marker on no agreement's road", "if open and road then agreed[key .. '>' .. partner:name()] = road end", "do end"),
        ("convoy marker worked out every refresh", "    R.spots = spots\n", "    R.spots = {}\n"),
        ("convoy marker kept past a new road of the day", "if not (s and s[1] == road and", "if not (s and"),
        ("convoy marker kept past a turn start's new road", "s[2] == c.road and ", ""),
        ("convoy marker kept past a step", " and s[3] == c.x and s[4] == c.y)", ")"),
    )
    for label, before, after in mutations:
        assert terrain.count(before) == 1, "stale map cost mutation: " + label
        changed = terrain.replace(before, after, 1)
        syntax = subprocess.run([luac, "-p", "-"], input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_terrain_harness(changed)
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    flows = flows_lua().replace("\r\n", "\n")
    flows_mutations = (
        ("a diplomatic event wipes the drawn roads", "        R.queue, R.queued = {}, {}\n",
         "        R.cache, R.queue, R.queued = {}, {}, {}\n"),
        ("a player's action leaves the map's cart goods", "    if R then R.plans, R.dirty = {}, true end\n", ""),
        ("a computer faction's action redraws the map",
         "function F.dispatch(fkey, parts)\n    if not F.is_human(fkey) then return end\n",
         "function F.dispatch(fkey, parts)\n    if DERPY_MR_TERRAIN_ROUTES then DERPY_MR_TERRAIN_ROUTES.plans, "
         "DERPY_MR_TERRAIN_ROUTES.dirty = {}, true end\n    if not F.is_human(fkey) then return end\n"),
    )
    for label, before, after in flows_mutations:
        assert flows.count(before) == 1, "stale map cost mutation: " + label
        code, out = run_harness(FLOWS_HARNESS, flows_text=flows.replace(before, after, 1))
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    code, out = run_terrain_harness()
    assert code == 0, out
    n = len(mutations) + len(flows_mutations)
    print("map cost mutations: %d/%d caught; restored harnesses pass" % (n, n))


def check_production_mutations():
    """The Production tab (2026-10-30): each rule broken the way somebody would, in the shipped
    stores script; the stores harness must fail on every one."""
    subject = stores_lua().replace("\r\n", "\n")
    mutations = (
        ("every short input, not only admission's", 'local short = (type(have) == "number" and have < need) or st.short',
         'local short = st.short'),
        ("admission's own shortage without the view", 'local short = (type(have) == "number" and have < need) or st.short == "Short of " .. stem',
         'local short = (type(have) == "number" and have < need)'),
        ("a recipe left on where it cannot run", "if st.open or st.on then e.rows", "if st.open then e.rows"),
        ("processing before services", "if da.kind ~= db.kind then return da.kind == \"processing\" end", ""),
        ("the race's own buildings", 'if string.match(lk, "_" .. race .. "_") and string.match', 'if string.match'),
        ("a chain's first level", ' and string.match(lk, "_1$") then', ' then'),
        ("the actions switch", "off = not actions or (not st.open and not st.on)", "off = not st.open and not st.on"),
        ("the grey row", "if #e.rows == 0 then v.rows[#v.rows + 1] = S.production_none(f, e.st) end", ""),
        ("folding", "        if not folded then\n            if #e.rows == 0", "        if true then\n            if #e.rows == 0"),
        ("on but short", 'return st.short == "Output store full" and "Store full" or "Short"', 'return "Paused"'),
        ("a closed recipe's reason", 'return S.ECON_CLOSED[st.reason] or (st.on and "Paused" or "Off")',
         'return st.on and "Paused" or "Off"'),
        ("the tab's clicks", " or name == S.TAB.production", ""),
        ("Gives names the good", "gives = d.output and result or", 'gives = d.output and (S.num(d.output[2]) .. " made") or'),
        ("the view is asked for the recipe", 'S.ask("economy_view", f, r.region, d)', 'S.ask("economy_view", f, r.region, st)'),
        ("a shortage said once", 'string.sub(c.reason, 1, 9) ~= "Short of "', "true"),
        ("Gives' icon", "price = {},\n                  lead = { [2] = c.gives_icon } }", "price = {} }"),
        ("Gives' icon after the inputs'", "local ld = leads[k - np]", "local ld = nil"),
        ("a greyed row's Gives icon", '(pk and pk.short or rc.dim) and "off"', 'pk and pk.short and "off"'),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale production mutation: " + label
        changed = subject.replace(before, after, 1)
        # UTF-8 on the pipe: the stores script carries a non-cp1252 arrow (a route's summary)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True, encoding="utf-8")
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_harness(HARNESS, stores_text=changed)
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    code, out = run_harness(HARNESS)
    assert code == 0, out
    print("production mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_spoil_mutations():
    """Spoilage (design 2026-11-01, Part A): each rule broken the way somebody would, in the shipped
    flows script; the flows harness must fail on every one."""
    subject = flows_lua().replace("\r\n", "\n")
    turn = "    F.guard(F.upkeep, faction)\n    F.guard(F.provisions_turn, faction)\n    F.guard(F.spoil, faction)"
    mutations = (
        ("rounds up", "return math.floor(exposed * rate / 100)", "return math.ceil(exposed * rate / 100)"),
        ("the safe share kept nothing back", "local exposed = (held or 0) - math.floor((capacity or 0) * safe / 100)",
         "local exposed = (held or 0)"),
        ("the Granary keeps every good", "if stem == F.SPOIL.granary_good and lasting", "if lasting"),
        ("the Granary read writes a book",
         "local b = F.state.factions[fkey]\n    local lasting = b and b.works and b.works.lasting",
         "local lasting = F.works_book(fkey).lasting"),
        ("the switch", "return r.spoilage and (r.ai or faction:is_human()) and F.uses_stores(faction)",
         "return (r.ai or faction:is_human()) and F.uses_stores(faction)"),
        ("other factions' stores off", "return r.spoilage and (r.ai or faction:is_human()) and F.uses_stores(faction)",
         "return r.spoilage and F.uses_stores(faction)"),
        ("a race with no stores", "return r.spoilage and (r.ai or faction:is_human()) and F.uses_stores(faction)",
         "return r.spoilage and (r.ai or faction:is_human())"),
        ("never runs", turn, "    F.guard(F.upkeep, faction)\n    F.guard(F.provisions_turn, faction)\n    do end"),
        ("runs before the meals", turn,
         "    F.guard(F.spoil, faction)\n    F.guard(F.upkeep, faction)\n    F.guard(F.provisions_turn, faction)"),
        ("booked as eaten", "n, KIND.spoil, fkey)", "n, KIND.eat, fkey)"),
        ("the forecast's net ignores it", "fc.net = p - d - s", "fc.net = p - d"),
        ("the forecast counts it down like a use", "local d = fc.use_per_turn\n", "local d = fc.use_per_turn + s\n"),
        ("next turn's loss ignores the switch", "if not (F.SPOIL.rates[stem] and F.spoils(v.faction)) then return 0 end",
         "if not F.SPOIL.rates[stem] then return 0 end"),
        ("a computer round reads every store whole", "local p = F.SPOIL.rates[g.stem] and F.pool(region, g.stem)",
         "local p = F.SPOIL.rates[g.stem] and F.stock(region) and F.pool(region, g.stem)"),
    )
    panel = stores_lua().replace("\r\n", "\n")
    shown = (   # (label, harness, before, after) on the stores script
        ("the sentence promises a loss of nothing", HARNESS, "if info.due > 0 then", "if info.due >= 0 then"),
        ("a busy line runs past the chart", HARNESS, "while #line * L.CHAR_W > L.chart_line[3] and #parts > 1 do",
         "while false do"),
        ("the forecast line leaves it out", FLOWS_HARNESS,
         'if (fc.spoil or 0) > 0 then lines[#lines + 1] = "It loses " .. S.num(fc.spoil) .. " to spoiling each turn." end', ''),
        ("the settlement row leaves it out", HARNESS,
         'if region then tip = add_line(tip, S.spoil_sentence(S.ask("spoil_info", model_faction, region, d.stem), d.name)) end',
         ""),
    )
    runs = [(label, FLOWS_HARNESS, subject, before, after, "flows_text") for label, before, after in mutations]
    runs += [(label, harness, panel, before, after, "stores_text") for label, harness, before, after in shown]
    for label, harness, text, before, after, arg in runs:
        assert text.count(before) == 1, "stale spoil mutation: " + label
        changed = text.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True, encoding="utf-8")
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_harness(harness, **{arg: changed})
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    for harness in (FLOWS_HARNESS, HARNESS):
        code, out = run_harness(harness)
        assert code == 0, out
    print("spoil mutations: %d/%d caught; restored harnesses pass" % (len(runs), len(runs)))


def check_race_mutations():
    """Faction-specific buffs (2026-11-01): each way the race's own work, Well fed or Feast could fall
    back to the general one, in the shipped flows script; the flows harness must fail on every one."""
    subject = flows_lua().replace("\r\n", "\n")
    mutations = (
        ("a work's not_races ignored", "    for _, r in ipairs(w.not_races or {}) do\n        if r == race then return false end",
         "    for _, r in ipairs({}) do\n        if r == race then return false end"),
        ("the race's bundle never chosen", "if v.race == race then want = v.key end", "do end"),
        ("both bundles at once", "if on and b == want then", "if on then"),
        ("a former owner's bundle kept", "family[#family + 1] = v.key", "do end"),
        ("an event open to every race", "(F.work_open(faction, e) and F.event_gated(faction, e))",
         "(true and F.event_gated(faction, e))"),
        ("the race's event never in the turn", '"feast", "feast_chd", "arsenal"', '"feast", "arsenal"'),
        ("only the first Granary keeps grain", "if lasting[k] then return F.SPOIL.granary end",
         "if lasting[F.SPOIL.granary_works[1]] then return F.SPOIL.granary end"),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale race mutation: " + label
        changed = subject.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True, encoding="utf-8")
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_harness(FLOWS_HARNESS, flows_text=changed)
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    code, out = run_harness(FLOWS_HARNESS)
    assert code == 0, out
    print("race mutations: %d/%d caught; restored harness passes" % (len(mutations), len(mutations)))


def check_turn_end_mutations():
    """Ending the turn closes the panel (author, 2026-11-01); the stores harness must fail on each."""
    subject = stores_lua().replace("\r\n", "\n")
    mutations = (
        ("never closes", "local done, e = pcall(S.show, false)", "local done, e = true, nil"),
        ("any faction's turn end closes it",
         "return context:faction():name() == cm:get_local_faction_name(true) and S.is_open()", "return S.is_open()"),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale turn end mutation: " + label
        code, out = run_harness(HARNESS, stores_text=subject.replace(before, after, 1))
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    print("turn end mutations: %d/%d caught" % (len(mutations), len(mutations)))


def check_sizes():
    """The panel sizes against the files they name and the fonts they step to."""
    import gen_mr_emitter as E
    for sfx, (n, d, _g, fonts) in SIZES.items():
        assert set(fonts) == {"body_%d" % s for s in E._BODY_SIZES}, (sfx, fonts)
        for a, b in fonts.items():
            # NO FONT MAY GROW PAST ITS BOX (gen_guilds_ui.check_font_steps), or its text runs out of it.
            # body_10 has nothing below it, so Small keeps it; the assert after this loop is why that is safe.
            if a == b == "body_10":
                continue
            assert _pt(b) * d <= _pt(a) * n, "%s maps %s to %s, wider than its box at %d/%d" % (sfx, a, b, n, d)
    built = files()
    medium = {rel: t for rel, t in built.items()
              if rel.endswith(".twui.xml") and not any(rel.endswith(s + ".twui.xml") for s in SIZES)}
    # THE ONE body_10 TEXT is the map's names, whose box S.map_names sizes to the name it measures
    tens = sorted(rel for rel, t in medium.items() if 'fontcat_name="body_10"' in t)
    assert tens == [UI_REL + "derpy_mr_stores_maplabel.twui.xml"], tens
    # EVERY PANEL FILE IS CREATED AT THE SIZE DRAWN: one created without the suffix draws Medium's box
    # inside a Large panel, and the opener created with it asks for a file that does not exist
    made = re.findall(r"CreateComponent\([^,]+, S\.PATH \.\. ([^)]+)\)", stores_lua())
    assert len(made) == 9, made
    for m in made:
        assert m.endswith(" .. S.SUFFIX") != (m == '"derpy_mr_stores_button"'), m
    assert set(UNSCALED) | set(GLYPH_FONT) <= set(L), "a layout entry was renamed: %s" % sorted(set(UNSCALED) | set(GLYPH_FONT) - set(L))
    print("panel sizes: %d files at %d sizes, fonts within their boxes" % (len(built), 1 + len(SIZES)))


def check_size_mutations():
    """MCT Panel size (author, 2026-11-02); the stores harness must fail on each."""
    subject = stores_lua().replace("\r\n", "\n")
    mutations = (
        ("the MCT size is never read", "S.use_size(S.pick_size(S.want_size(), sw, sh",
         'S.use_size(S.pick_size("medium", sw, sh'),
        ("the layout stays Medium's", "S.SIZE, S.F, S.SUFFIX, L = k, z.f, z.suffix, z.layout",
         "S.SIZE, S.F, S.SUFFIX, L = k, z.f, z.suffix, L"),
        ("the panel at the old size is kept", "if is_uicomponent(p) then pcall(function() p:Destroy() end) end", ""),
        ("the opener grows with the panel", "local H = DERPY_MR_STORES_L ", "local H = L "),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale size mutation: " + label
        code, out = run_harness(HARNESS, stores_text=subject.replace(before, after, 1))
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    print("size mutations: %d/%d caught" % (len(mutations), len(mutations)))


def check_edict_mutations():
    """Trade edicts (design 2026-11-01, Part B): each rule broken the way somebody would, in the shipped
    flows, stores and terrain scripts; the harness that owns the rule must fail on every one."""
    flows = flows_lua().replace("\r\n", "\n")
    panel = stores_lua().replace("\r\n", "\n")
    with io.open(os.path.join(ROOT, "Modding Files", "source", "resource_overhaul", "terrain_routes.lua"),
                 encoding="utf-8") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    closed = "    local F = DERPY_MR_FLOWS\n    if F and F.edict and F.edict(owner:name(), 'roads') == 'closed' then return true end\n"
    party = "    for _, p in ipairs(parties) do\n        if owner:name() == p:name() then return false end\n    end\n    -- CLOSED ROADS"
    first = ("    F.guard(F.edict_turn, faction)\n    -- Arrivals fund this turn; essentials and elective local orders precede exports.\n"
             "    F.guard(F.convoys_turn, faction)\n    F.guard(F.ships_turn, faction)\n    F.guard(F.upkeep, faction)\n")
    flows_m = (
        ("the cooldown ignored", "    if not force and F.edict_wait(fkey, which) > 0 then return false end\n", ""),
        ("the race bundle ignored", "return (own and own[F.race(faction)]) or F.EDICT.bundles[option]",
         "return F.EDICT.bundles[option]"),
        ("the default read from a missing switch", "local b = F.edicts_on() and F.state.edicts and F.state.edicts[fkey]",
         "local b = F.state.edicts and F.state.edicts[fkey]"),
        ("F.edict creating a table", "local b = F.edicts_on() and F.state.edicts and F.state.edicts[fkey]",
         "F.state.edicts = F.state.edicts or {}\n    local b = F.edicts_on() and F.state.edicts[fkey]"),
        ("Closed not invalidating reach", '    if which == "roads" then F.invalidate_reach() end\n', ""),
        ("the meal size fixed at F.NEED", 'return F.EDICT.need[F.edict(fkey, "rations")] or F.NEED end',
         "return F.NEED end"),
        ("War economy on every output", 'if F.EDICT.war_outputs[d.output[1]] and F.edict(faction:name(), "workshops") == "war" then',
         'if F.edict(faction:name(), "workshops") == "war" then'),
        ("the Merchant share not doubled", "then pct = pct * F.EDICT.merchant_trade end", "then pct = pct end"),
        ("the draw not scaled", "math.ceil(value / F.RECRUIT.per * per * draw / 100)", "math.ceil(value / F.RECRUIT.per * per)"),
        ("the computer counting rebels", "not o:is_rebel() and o:name() ~= fkey", "o:name() ~= fkey"),
        ("a rebel war barring Merchant", "if not wars:item_at(i):is_rebel() then return true end", "return true"),
        ("edict_turn after upkeep", first, first.replace("    F.guard(F.edict_turn, faction)\n", "", 1)
         + "    F.guard(F.edict_turn, faction)\n"),
        ("a neighbour counted once per region", "o:name() ~= fkey and not seen[o:name()] then", "o:name() ~= fkey then"),
        ("Rationing never chosen", "cover < a.ration_low", "cover < 0"),
        ("Plenty never chosen", "cover > a.ration_high", "cover > 1e9"),
        ("Merchant on any partner", ">= a.merchant_partners", ">= 0"),
        ("Closed at one war", "near >= a.closed_wars", "near > 0"),
        ("Rations for a faction that does not eat",
         'if which == "rations" and not F.eats(faction) then return false end', ""),
        ("a player's bundles not caught up", "if faction:is_human() then return F.edict_bundles(faction) end",
         "if faction:is_human() then return end"),
        ("computer edicts under other factions' stores off", "if r.edicts and r.ai and F.uses_stores(faction)",
         "if r.edicts and F.uses_stores(faction)"),
        ("the rebels' missing trade list read", 'type(partners) ~= "boolean" and partners:num_items()', "partners:num_items()"),
        ("a missing wars list read", '    if type(wars) == "boolean" then return false end\n    for i = 0, wars:num_items() - 1 do\n        if not wars:item_at(i):is_rebel()',
         "    for i = 0, wars:num_items() - 1 do\n        if not wars:item_at(i):is_rebel()"),
        ("Well fed on the edict's own meals", 'fed = F.use_total(held, "provisions") >= F.FED_TURNS * F.NEED * level',
         'fed = F.use_total(held, "provisions") >= F.FED_TURNS * need'),
    )
    panel_m = (
        ("the active button clickable", "if not ch.on and not ch.off then return S.request(", "if not ch.off then return S.request("),
        ("the button size not restored", "sized(button, ch and L.EDICT_W or L.POLICY_W[j], L.send[2])",
         "if ch then sized(button, L.EDICT_W, L.send[2]) end"),
        ("a waiting edict live", "off = o.key ~= now and wait > 0", "off = false"),
        ("a Rations row for a faction that does not eat", 'if e.key ~= "rations" or eats then', "if true then"),
    )
    terrain_m = (
        ("R.hostile ignoring Closed", closed, ""),
        ("a party treated as hostile", party, closed + party),
    )
    _run_mutants("edict", flows, flows_m, panel, panel_m, terrain, terrain_m)


def _run_mutants(kind, flows, flows_m, panel, panel_m, terrain, terrain_m):
    """Each (label, before, after) applied alone to its script; the harness that owns that script must fail."""
    runs = [(label, FLOWS_HARNESS, flows, b, a, "flows_text") for label, b, a in flows_m]
    runs += [(label, HARNESS, panel, b, a, "stores_text") for label, b, a in panel_m]
    runs += [(label, None, terrain, b, a, None) for label, b, a in terrain_m]
    for label, harness, text, before, after, arg in runs:
        assert text.count(before) == 1, "stale %s mutation: %s" % (kind, label)
        changed = text.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True, encoding="utf-8")
        assert syntax.returncode == 0, (label, syntax.stderr)
        if harness is None:
            code, out = run_terrain_harness(changed)
            assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        else:
            code, out = run_harness(harness, **{arg: changed})
            assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    print("%s mutations: %d/%d caught" % (kind, len(runs), len(runs)))


def check_toll_mutations():
    """Tolls (design 2026-11-01, Part C 6.1): each rule broken the way somebody would, in the shipped flows
    script; the flows harness must fail on every one."""
    subject = flows_lua().replace("\r\n", "\n")
    mutations = (
        ("the toll limit off", "return math.min(F.rates().toll * n, F.TOLL.max) end", "return F.rates().toll * n end"),
        ("rounding up", "local each = math.floor(value * F.toll_pct(n) / (n * 100))",
         "local each = math.ceil(value * F.toll_pct(n) / (n * 100))"),
        ("a party charged", "local out, seen = {}, { [a:name()] = true, [b:name()] = true }", "local out, seen = {}, {}"),
        ("a taker charged twice", "if o and not o:is_null_interface() and not seen[o:name()] then",
         "if o and not o:is_null_interface() then"),
        ("an ally charged", " and not friends(o, a) and not friends(o, b) then", " then"),
        ("Open still charging", ' and F.edict(o:name(), "roads") == "tolled"', ""),
        ("Closed still charging", 'F.edict(o:name(), "roads") == "tolled"', 'F.edict(o:name(), "roads") ~= "open"'),
        ("the preview leaving out earlier partners' guards",
         "sources.toll_spent = spent + sum + (fee <= exporter:treasury() - spent - sum and fee or 0)",
         "sources.toll_spent = spent + sum"),
        ("an own cart refused to a faction in debt",
         "if escrow + toll > 0 and escrow + toll > faction:treasury() then return nil end",
         "if escrow + toll > faction:treasury() then return nil end"),
        ("an internal shipment charged", "    if partner then\n        local ps = F.local_price(source, stem, seller:name())",
         "    if true then\n        local ps = F.local_price(source, stem, seller:name())"),
        ("the uphill test without the toll", "pd >= F.buy_price(ps) + F.toll_unit(ps, #takers)", "pd >= F.buy_price(ps)"),
        ("an unaffordable partner still sent", "    if sum > 0 and sum > exporter:treasury() - spent then\n", "    if false then\n"),
        ("a faction in debt refused with nothing due", "    if sum > 0 and sum > exporter:treasury() - spent then\n",
         "    if sum > exporter:treasury() - spent then\n"),
        ("the preview forgetting earlier partners' tolls", "local spent = preview and sources.toll_spent or 0", "local spent = 0"),
        ("the toll charged on the plan and not on what was sent",
         "local due = F.tolls(F.cargo_value(convoy.basket, prices), takers)",
         "local due = F.tolls(F.cargo_value(basket, prices), takers)"),
        ("the toll paid by the seller on a cart", "if toll > 0 and F.pay_tolls(fkey, due) then", "if toll > 0 and F.pay_tolls(seller:name(), due) then"),
        ("a convoy's bad tolls loaded", "    if not F.tolls_sound(c.tolls) then return nil end\n", ""),
        ("a cart's bad tolls kept", "            if not F.tolls_sound(s.tolls) then s.tolls = nil end\n", ""),
    )
    for label, before, after in mutations:
        assert subject.count(before) == 1, "stale toll mutation: " + label
        changed = subject.replace(before, after, 1)
        syntax = subprocess.run([LUA_EXE.replace("lua.exe", "luac.exe"), "-p", "-"],
            input=changed, capture_output=True, text=True, encoding="utf-8")
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_harness(FLOWS_HARNESS, flows_text=changed)
        assert code != 0 and "in function" in out and "syntax" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label)
    print("toll mutations: %d/%d caught" % (len(mutations), len(mutations)))


def check_blockade_mutations():
    """Blockades and the toll rows (design 2026-11-01, Part C 6.2-6.3): each rule broken the way somebody would,
    in the shipped flows, stores and terrain scripts; the harness that owns the rule must fail on every one."""
    with io.open(TERRAIN_SRC, encoding="utf-8") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    flows_m = (
        ("a radius one hex wider", "if dx * dx + dy * dy <= near * near then", "if dx * dx + dy * dy <= (near + 1) * (near + 1) then"),
        ("only the exporter's enemies counted", "for _, side in ipairs({ a, b }) do", "for _, side in ipairs({ a }) do"),
        ("duty paid when blockaded", " or F.blockaded(fkey, partner:name())) and 0", ") and 0"),
        ("the cut-off list without blockades", "        elseif by then out[#out + 1] = { key = p:name(), by = by } end\n", "        end\n"),
        ("the contract status lost", ' or (why == "blockaded" and "Blockaded")', ""),
        ("the preview ignoring blockades", "    if not (opts and opts.blockade_ok) then\n",
         "    if not preview and not (opts and opts.blockade_ok) then\n"),
        ("the blocker not recorded", "        if not preview then F.record_blockade(exporter:name(), partner:name(), by) end\n", ""),
        ("a cart leaving through a blockade",
         '    if partner and F.blockade(seller, faction, road) then return nil, "blockaded" end\n', ""),
        ("the switch ignored", "if not F.rates().tolls or type(path) ~= \"table\" or #path == 0 then return nil end",
         "if type(path) ~= \"table\" or #path == 0 then return nil end"),
        ("the blockades not saved", "        F.state.blockades = F.blockades_kept()\n", ""),
        ("the blockades not loaded", "    F.sanitize_blockades()\n", ""),
        ("a damaged saved blockade kept", 'type(v.by) == "string" and type(v.turn) == "number"', "true"),
    )
    panel_m = (
        ("a blockade naming no blocker", 'local why = c.why or ("Blockaded by " .. loc(', 'local why = c.why or ("Blockaded" or loc('),
        ("the toll rows hidden at 0", "if t[w[1]] > 0 or on then", "if t[w[1]] > 0 then"),
        ("a convoy's tolls left out",
         'if type(c.tolls) == "table" and next(c.tolls) then lines[#lines + 1] = S.tolls_text(c.tolls) end', ""),
    )
    terrain_m = (
        ("the map drawing a blockaded pair",
         "if open and F.blockaded and F.blockaded(key, partner:name()) then open = false end", ""),
    )
    _run_mutants("blockade", flows_lua().replace("\r\n", "\n"), flows_m, stores_lua().replace("\r\n", "\n"), panel_m,
                 terrain, terrain_m)


def check_road_mutations():
    """Bandits on the roads and guards (design 2026-11-01, Part D): each rule broken the way somebody would, in the
    shipped flows and stores scripts; the harness that owns the rule must fail on every one."""
    flows_m = (
        ("the wild rule's rebel case removed", "if region:is_abandoned() or o:is_null_interface() or o:is_rebel() then return 100 end",
         "if region:is_abandoned() or o:is_null_interface() then return 100 end"),
        ("CA's figure trusted at 0", 'if ok and type(v) == "number" and v > 0 then', 'if ok and type(v) == "number" and v >= 0 then'),
        ("the guard halving removed", "(guarded and 50 or 100)", "100"),
        ("the patrol radius one wider", "    local r2 = F.SHIP.near * F.SHIP.near\n    for _, f in ipairs({ owner, buyer }) do",
         "    local r2 = (F.SHIP.near + 1) * (F.SHIP.near + 1)\n    for _, f in ipairs({ owner, buyer }) do"),
        ("a garrison on patrol", "\n            if not mf:is_armed_citizenry() and mf:has_general() then",
         "\n            if mf:has_general() then"),
        ("the ambush minimum removed", '(e ~= "ambush" or threat >= F.ROAD.ambush_min)', "true"),
        ("the washout at sea", ' and (e ~= "washout" or land)', ""),
        ("the cooldown not recorded", "    cool[e] = turn\n", ""),
        ("half rounding up", "local cut = math.floor(n * pct / 100)", "local cut = math.ceil(n * pct / 100)"),
        ("the highwaymen paying past the treasury",
         "math.min(math.floor(F.cargo_value_base(rec) * F.ROAD.toll_pct / 100), math.max(0, faction:treasury()))",
         "math.floor(F.cargo_value_base(rec) * F.ROAD.toll_pct / 100)"),
        ("a computer offered a dilemma", "if faction:is_human() and not cm:is_multiplayer() and", "if not cm:is_multiplayer() and"),
        ("multiplayer offered a dilemma", "if faction:is_human() and not cm:is_multiplayer() and", "if faction:is_human() and"),
        ("the lost battle not losing the cargo", "        F.cargo_lose(f.cargo, rec, 100)\n", ""),
        ("the bandits left after a battle",
         '    F.bandit_kill(f.force)\n    pcall(function() cm:get_campaign_ui_manager():override("retreat"):unlock() end)\nend',
         '    pcall(function() cm:get_campaign_ui_manager():override("retreat"):unlock() end)\nend'),
        ("the bandits not killed after a decline", "    F.bandit_kill(p.bandit)\n    if not rec then return end", "    if not rec then return end"),
        ("the stale pending encounter not cleared", "if p and (tonumber(p.turn) or 0) < turn then", "if false then"),
        ("the one-pending rule removed", '        if F.pending(fkey, "road_" .. e) then return false end\n', ""),
        ("Guards not charged", "        F.guard_fee(exporter, convoy)\n", ""),
        ("Guards not charged on a cart", "    F.guard_fee(faction, s)\n", ""),
        ("Guards taken past the treasury", "    if fee > payer:treasury() then return end\n", ""),
        ("a computer's guards kept too long", "((F.state.road_seen or {})[fkey] or -1000000) >= cm:model():turn_number() - 1",
         "((F.state.road_seen or {})[fkey] or -1000000) >= cm:model():turn_number() - 3"),
        ("a convoy's road never rolled", '                F.road_event(faction, "convoy", c, from)\n', ""),
        ("a cart's road never rolled", '            if F.ship_by_id(s.id) == s then F.road_event(faction, "ship", s, from) end\n', ""),
        ("the spawn's callback reading the owner's interface", "cm:force_declare_war(qb, owner_key, false, false)",
         "cm:force_declare_war(qb, owner:name(), false, false)"),
        ("an encounter rolled at sea", "    if not here or here:is_null_interface() then return end\n", ""),
        ("Guards a toggle", 'F.state.guards[faction:name()] = want == "on" or nil',
         "F.state.guards[faction:name()] = not F.state.guards[faction:name()] or nil"),
        ("Guards taking any request", '    if want ~= "on" and want ~= "off" then return end\n', ""),
    )
    panel_m = (
        ("the guards row without the bandits", "if rates and f and rates().bandits and S.ask(\"uses_stores\", f) then",
         "if rates and f and S.ask(\"uses_stores\", f) then"),
        ("Hire sends nothing", '        return S.request("guards", rc.guards)\n', "        return\n"),
        ("Dismiss asking for guards on", 'guards = on and "off" or "on"', 'guards = "on"'),
    )
    _run_mutants("road", flows_lua().replace("\r\n", "\n"), flows_m, stores_lua().replace("\r\n", "\n"), panel_m, "", ())


def check_event_mutations():
    """The six store events (design 2026-11-01, Part E): each rule broken the way somebody would, in the shipped
    flows script and its event table; the flows harness must fail on every one."""
    flows_m = (
        ("Smugglers below 2 turns turned to 3", "if per > 0 and held < per * 2 then", "if per > 0 and held < per * 3 then"),
        ("Smugglers' 100 limit removed", "local n = math.min(100, per * 5 - held)", "local n = per * 5 - held"),
        ("Smugglers at the local price", "math.ceil(n * buy * 150 / (F.PCT * F.PCT))", "math.ceil(n * buy * 100 / (F.PCT * F.PCT))"),
        # Workshop report, 2026-11-07: every store starts empty, so Smugglers came on turn 1 everywhere
        ("Smugglers' start grace removed", "    if cm:model():turn_number() <= F.EVENT_GAP then return nil end\n", ""),
        ("Smugglers' start grace a turn short", "if cm:model():turn_number() <= F.EVENT_GAP then", "if cm:model():turn_number() < F.EVENT_GAP then"),
        ("the guild above 75% turned to 50", "h * 100 > c * 75", "h * 100 > c * 50"),
        # the live pass's cost (2026-11-02): F.stocks has read every store, and the offers read none again
        ("the guild reading every store again", "        for stem, c in pairs(s.capacity) do",
         "        local _h, _c, capacity = F.stock(s.region)\n        for stem, c in pairs(capacity) do"),
        ("Smugglers building a whole view of every store",
         "            local per, held = uses[r:name()][use] or 0, F.use_total(s.held, use)",
         "            local per, held = uses[r:name()][use] or 0, F.use_total(s.held, use)\n"
         "            F.stock_view(faction, r, provinces)"),
        ("the sale not ending", "if s.left <= 0 or sold < s.per then", "if sold < s.per then"),
        ("the sale paid at the local price", "F.gold(sold, math.floor(q.sell * 120 / 100))", "F.gold(sold, q.sell)"),
        ("a finished sale kept on load", "type(s.left) == \"number\" and s.left > 0", "type(s.left) == \"number\" and s.left >= 0"),
        ("Grain rot's SECOND ignored", "    local fkey, pct = faction:name(), 30\n",
         "    if choice ~= \"FIRST\" then return end\n    local fkey, pct = faction:name(), 30\n"),
        ("Grain rot's 50 gold taken from an empty treasury", "if faction:treasury() >= 50 then", "if true then"),
        ("Grain rot offered to computers", 'needs = {"spoilage"}, human = true', 'needs = {"spoilage"}, human = false'),
        ("Caravan master's suppression ignored", "    if ((F.state.road_safe or {})[fkey] or -1) >= turn then return end\n", ""),
        ("Caravan master hired with no gold", "    if fee > faction:treasury() then return end\n    if fee > 0 then cm:treasury_mod(fkey, -fee) end\n    F.state.road_safe",
         "    if fee > 0 then cm:treasury_mod(fkey, -fee) end\n    F.state.road_safe"),
        ("Toll dispute's force removed", 'F.edict_set(faction, "roads", "open", true)', 'F.edict_set(faction, "roads", "open")'),
        ("Toll dispute's bonus sign", "else bonus = -F.DIPLO_BONUS end", "else bonus = F.DIPLO_BONUS end"),
        ("Blockade runner sending twice", "or not trades_with(faction, p.target) or sent_this_turn(fkey, p.target, turn) then",
         "or not trades_with(faction, p.target) then"),
        ("Blockade runner with nothing to run",
         "if partner and F.trade_pair(faction, partner, nil, true, { blockade_ok = true }) then", "if partner then"),
        ("Blockade runner past a lapsed trade", "or not trades_with(faction, p.target) ", ""),
        ("still Blockaded after the runner", "    F.record_blockade(fkey, p.target, nil)\n", ""),
        ("Toll dispute with the roads Open", '    if F.edict(faction:name(), "roads") ~= "tolled" then return nil end\n', ""),
        ("the guild's good not named", '        if o.key == "guild" then tf = F.name_good(faction, o.stem) end\n', ""),
        ("a waiting guild offer not named after a load", "    F.guard(F.name_pending_goods)\n", ""),
        ("Blockade runner's tenth not paid", "if fee > 0 and fee <= faction:treasury() then cm:treasury_mod(fkey, -fee) end", "do end"),
        ("an event offered with its part off", "        if not r[s] then return false end\n", ""),
    )
    _run_mutants("event", flows_lua().replace("\r\n", "\n"), flows_m, "", (), "", ())


def check_kept_mutations():
    """Nothing from the engine kept past its script entry (the 1.0 live pass, 2026-11-02: a faction interface kept in
    F.enemy_cache crashed the game from the map's next plan refresh). Each way of keeping one again, in the shipped
    flows, stores and terrain scripts; the harness that owns the script must fail on every one."""
    with io.open(os.path.join(ROOT, "Modding Files", "source", "resource_overhaul", "terrain_routes.lua"),
                 encoding="utf-8") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    lookup = ("            local now = {}\n            for _, key in ipairs(parties) do\n"
              "                local p = cm:get_faction(key)\n"
              "                if p and not p:is_null_interface() then now[#now + 1] = p end\n            end\n"
              "            verdicts[name] = R.hostile(owner, now)")
    flows_m = (
        ("the enemy list keeping the faction", "list[#list + 1] = { fkey = o:name(), cqi",
         "list[#list + 1] = { f = o, fkey = o:name(), cqi"),
        # the final review (2026-11-02): kept positions are as stale as kept interfaces are dead
        ("a turn start reading a list made earlier in the round",
         "    -- the armies where they stand now: a list made earlier in the round has them where they stood then\n"
         "    F.enemy_cache = {}\n", ""),
    )
    panel_m = (
        ("the panel remembering the player's faction", "if ok and f and not f:is_null_interface() then return f end",
         "if ok and f and not f:is_null_interface() then S.viewer = f; return f end"),
    )
    terrain_m = (
        ("a queued search keeping its parties", "parties[#parties + 1] = owner:name() end", "parties[#parties + 1] = owner end"),
        ("a queued search judging by its kept parties", lookup, "            verdicts[name] = R.hostile(owner, parties)"),
        ("a queued search keeping the model",
         "    return function(x, y, model)\n        local region = (model or cm:model()):get_region_at_logical_position(x, y)",
         "    local kept = cm:model()\n    return function(x, y, model)\n        local region = kept:get_region_at_logical_position(x, y)"),
        ("the map remembering the player's faction",
         "    local faction = cm:get_faction(cm:get_local_faction_name(true))\n"
         "    if not faction or faction:is_null_interface() then return end\n    local wanted, count",
         "    R.viewer = R.viewer or cm:get_faction(cm:get_local_faction_name(true))\n    local faction = R.viewer\n"
         "    if not faction or faction:is_null_interface() then return end\n    local wanted, count"),
    )
    _run_mutants("kept", flows_lua().replace("\r\n", "\n"), flows_m, stores_lua().replace("\r\n", "\n"), panel_m,
                 terrain, terrain_m)


def check_layout():
    """Every box inside the panel; headers, list and hint in order; columns clear of each
    other and of the slider. A box that leaves the panel draws over the map."""
    W, H = L["W"], L["H"]
    for k in ("title", "title_rule", "close", "tab_goods", "tab_settlements", "tab_trade", "tab_spending",
              "tab_map", "tab_workshop", "tab_production", "back",
              "sub_title", "list", "empty", "hint", "cards", "escort_line"):
        x, y, w, h = L[k]
        assert 0 <= x and 0 <= y and x + w <= W and y + h <= H, "%s leaves the panel" % k
    # THE ESCORT: the most units an escort can roll fit one row of cards, under the line and inside the list
    assert ESCORT_MAX * (L["CARD_W"] + L["CARD_GAP"]) - L["CARD_GAP"] <= L["cards"][2], "the escort's cards do not fit"
    assert L["cards"][3] == L["CARD_H"], "the card row is not a card tall"
    assert L["escort_line"][1] + L["escort_line"][3] <= L["cards"][1], "the escort's line runs into its cards"
    assert L["cards"][1] >= L["list"][1] and L["cards"][1] + L["cards"][3] <= L["list"][1] + L["list"][3],         "the cards leave the list's box"
    lx, ly, lw, lh = L["list"]
    assert lh == L["ROWS"] * L["PITCH"], "the list is not ROWS rows tall"
    assert L["head_y"] + 22 <= ly and ly + lh <= L["bulk"][1], "headers, list and buttons overlap"
    assert L["hint"][:2] == L["sub_title"][:2], "the hint has left the sub-title's line"
    assert L["tab_trade"][0] >= L["tab_settlements"][0] + L["tab_settlements"][2], "the tabs overlap"
    tabs = [L[k] for k in ("tab_goods", "tab_settlements", "tab_trade", "tab_spending", "tab_map", "tab_workshop",
                           "tab_production")]
    for a, b in zip(tabs, tabs[1:]):
        assert b[0] >= a[0] + a[2], "the tabs overlap"
        assert (b[1], b[3]) == (a[1], a[3]), "the tabs are not on one line at one height"
    assert L["back"][0] >= tabs[-1][0] + tabs[-1][2], "back overlaps a tab"
    for view in ("workshop", "workshop_focus", "production"):   # Buy, Enable or Pause in the fifth column
        assert L["send"][0] <= L["VIEWS"][view][4][1], "the button overruns %s's last column" % view
    # THE PRODUCTION TAB'S INPUTS: the most goods a recipe takes, as the price strip from column 3,
    # end before the State column; the gives and the state each fit theirs
    import gen_resource_overhaul as G
    pc = L["VIEWS"]["production"]
    recipes = dict(G.PROCESSING, **G.SERVICES)
    most = max(len(d["cost"]) for d in recipes.values())
    assert most <= L["USING"], "a recipe takes more goods than a row has icons"
    assert pc[2][0] + most * L["PRICE_PITCH"] <= pc[3][0], "a recipe's inputs run into the State column"
    for d in recipes.values():
        for n in d["cost"].values():
            assert CHAR_W * len(str(n)) <= L["PRICE_PITCH"] - L["ICON_PITCH"], "an input amount %d does not fit" % n
    names = dict((s, n) for s, (_r, _f, n) in G.store_stems().items())
    for w in G.works():   # the Workshop's Gives cell: no comma to shorten it with since 2026-11-01
        assert CHAR_W * len(w["gives"]) <= L["VIEWS"]["workshop"][1][1], "%r overflows the Workshop's Gives" % w["gives"]
    gives = ["%d %s" % (d["output"][1], names[d["output"][0]]) for d in G.PROCESSING.values()]
    gives += ["+2 control", "+5 growth", "-5% cost", "+3% replen."]
    for t in gives:   # after its icon
        assert L["ICON_PITCH"] + CHAR_W * len(t) <= pc[1][1], "%r overflows the Production tab's Gives" % t
    for t in ("None of your settlements", "No workshop", "Capital only", "Switched off", "Store full", "Next turn"):
        assert CHAR_W * len(t) <= (pc[0][1] if t.startswith("None") else pc[3][1]), "%r overflows its column" % t
    # EVERY WORKSHOP ROW'S TEXT FITS ITS COLUMN: the name, the short line, and each price part
    # after its icon (a part's figure starts ICON_PITCH in)
    import gen_resource_overhaul as G
    wc = L["VIEWS"]["workshop"]
    for w in G.works():
        for text, (_x, cw, _a) in ((w["name"], wc[0]), (w["gives"], wc[1])):
            assert CHAR_W * len(text) <= cw, "%r is %dpx in a %dpx column" % (text, CHAR_W * len(text), cw)
        for n, (_x, cw, _a) in ((w["rare_n"], wc[2]), (w["use_n"], wc[3])):
            assert L["ICON_PITCH"] + CHAR_W * len(str(n)) <= cw, "%s's price %d does not fit" % (w["key"], n)
    assert L["USING"] >= 2, "a Workshop row's two price icons use the row's use1 and use2"
    # A NAMED RECIPE'S PRICE STRIP stops short of Buy, and each amount fits after its icon
    for w in G.works():
        goods = w.get("goods", ())
        assert len(goods) <= L["USING"], "%s names more goods than a row has icons" % w["key"]
        assert wc[2][0] + len(goods) * L["PRICE_PITCH"] <= wc[4][0], "%s's price runs into Buy" % w["key"]
        for _s, n in goods:
            assert CHAR_W * len(str(n)) <= L["PRICE_PITCH"] - L["ICON_PITCH"], "%s: %d does not fit" % (w["key"], n)
    assert L["map"] == L["list"], "the map draws in the list's box"
    assert 2 * L["MAP_PAD"] + L["MAP_CART_SIZE"] < min(L["map"][2], L["map"][3]), "the map's pad leaves no room"
    bx, by, bw, bh = L["bulk"]
    assert bx + 4 * bw + 3 * L["BULK_GAP"] <= W - 20, "the four buttons leave the panel's margin"
    assert by >= ly + lh and by + bh <= H, "the buttons are not under the list"
    assert CHAR_W * len("Allow all exports") <= bw, "a button's label does not fit"
    import gen_resource_overhaul as G
    assert len(G.ORDERS) <= 3, "the orders take bottom-line slots 2-4"
    for o in G.ORDERS:
        assert CHAR_W * len(o[4]) <= bw, "order label %r does not fit" % o[4]
    assert CHAR_W * len("Sell surplus") <= bw, "Sell's label does not fit"
    # the map's key: on the bottom line, each name right of its icon, all of it left of slot 3
    slot3 = bx + 2 * (bw + L["BULK_GAP"])
    for k, (icon, text) in L["map_key"].items():
        for x, y, w, h in (icon, text):
            assert by <= y and y + h <= by + bh and x + w <= slot3, "the map key's %s leaves its place" % k
        assert text[0] >= icon[0] + icon[2], "the map key's %s name is on its icon" % k
    for k, label in (("cap", "Province capital"), ("town", "Settlement"), ("cart", "Convoy")):
        assert CHAR_W * len(label) <= L["map_key"][k][1][2], "the map key's %r does not fit" % label
    keys = sorted(L["map_key"].values())
    for a, b in zip(keys, keys[1:]):
        assert b[0][0] >= a[1][0] + a[1][2], "two map key entries overlap"
    # + and - inside the map, clear of the frame's line, one above the other
    mx, my, mw, mh = L["map"]
    zi, zo = L["zoom_in"], L["zoom_out"]
    edge = L["MAP_FRAME_OUT"] + 4
    for z in (zi, zo):
        assert mx + edge <= z[0] and z[0] + z[2] <= mx + mw - edge, "zoom leaves the map"
        assert my + edge <= z[1] and z[1] + z[3] <= my + mh - edge, "zoom leaves the map"
    assert zi[1] + zi[3] < zo[1] and zi[0] == zo[0] and zi[2:] == zo[2:], "+ is not above - at one size"
    comps = build_mapart().split("<components>", 1)[1]
    part = lambda n: re.search(r"<%s\b.*?</%s>" % (n, n), comps, re.S).group(0)
    grab, art = part("derpy_mr_map_grab"), part("derpy_mr_map_art")
    assert 'interactive="true"' in grab and 'moveable="Movable XP"' in grab, "nothing to drag the map by"
    assert "DragAndZoomCallback" not in grab, "DragAndZoomCallback stops the drag (seen in game 2026-10-08)"
    assert 'interactive="true"' not in art and "moveable" not in art, \
        "the picture would take the press (and be put back on release) instead of the grab layer"
    assert comps.index("<derpy_mr_map_grab") < comps.index("<derpy_mr_map_art"), "the grab layer is over the markers"
    frame = re.search(r"<derpy_mr_map_frame\b.*?</derpy_mr_map_frame>", comps, re.S)
    assert frame and 'interactive="true"' not in frame.group(0), "the map's frame would take the grab"
    assert len(supply_buttons()) <= 4, "a Spending row has four box columns"
    for j in (2, 3, 4, 5):
        assert L["CHECK"] <= L["VIEWS"]["spending"][j - 1][1], "a supply box is wider than its column"
    assert L["send"][0] <= L["VIEWS"]["spending"][4][1] + 4, "Show overruns the last column"
    fx, fw, _a = L["VIEWS"]["focus"][4]
    assert L["send"][0] <= fw and L["send"][1] <= L["PITCH"] - 2, "Send here does not fit its column"
    assert CHAR_W * len("Send here") <= L["send"][0], "Send here's label does not fit"
    t, r = L["title"], L["title_rule"]
    assert t[1] + t[3] + 2 <= r[1] and r[1] + r[3] + 6 <= L["tab_goods"][1], "the rule touches the title or the tabs"
    for j in (2, 3):                       # the checkboxes sit in the Exports and Imports columns
        assert L["CHECK"] <= L["VIEWS"]["trade"][j][1], "a checkbox is wider than its column"
    assert L["CHECK"] <= L["PITCH"] - 2, "a checkbox is taller than a row"
    for view, cols in L["VIEWS"].items():
        assert len(cols) == 5, view
        end = L["icon"][0] + L["icon"][2]
        for j, (x, w, a) in enumerate(cols):
            assert a in ("left", "centre", "right"), "%s: %r is not an alignment SetTextHAlign takes" % (view, a)
            assert x >= end + (2 if j else 0), "%s: no gap for the line before the column at %d" % (view, x)
            end = x + w
        assert end <= lw - L["SLIDER_W"], "%s: the last column runs under the slider" % view
    # THE EDICTS (Part B) on the Resources tab, at every panel size: each option's label inside its
    # button, the three buttons inside columns 3-5, the longest wait inside column 2
    for lay in (L, scaled_layout("_sm"), scaled_layout("_lg")):
        gc, ew, cw = lay["VIEWS"]["goods"], lay["EDICT_W"], lay["CHAR_W"]
        for _k, _n, _t, _d, options in EDICTS:
            for o in options:
                assert cw * len(o[1]) + 8 <= ew, "edict option %r does not fit its button" % o[1]
        for j in (2, 3, 4):
            assert ew <= gc[j][1], "an edict button is wider than goods column %d" % (j + 1)
        assert cw * len("Wait %d turns" % EDICT_COOLDOWN) <= gc[1][1], "an edict's wait does not fit column 2"
    for k in ("chart_top", "bars", "chart_from", "chart_to", "chart_line"):
        x, y, w, h = L[k]
        assert 0 <= x and 0 <= y and x + w <= W and y + h <= H, "%s leaves the panel" % k
    assert ly + L["CHART_ROWS"] * L["PITCH"] <= L["chart_top"][1], "the short list runs into the chart"
    assert L["chart_top"][1] + L["chart_top"][3] <= L["bars"][1], "the top label overlaps the bars"
    assert L["bars"][1] + L["bars"][3] <= L["chart_from"][1], "the bars run into the turn labels"
    assert L["chart_from"][0] + L["chart_from"][2] <= L["chart_to"][0], "the turn labels overlap"
    assert L["chart_from"][1] + L["chart_from"][3] <= L["chart_line"][1], "the turn labels overlap the line"
    assert L["chart_line"][1] + L["chart_line"][3] <= L["bulk"][1], "the chart runs into the buttons"
    assert (L["BARS"] - 1) * L["BAR_PITCH"] + L["BAR_W"] <= L["bars"][2], "twenty bars do not fit"
    assert L["BAR_MIN"] <= L["bars"][3], "a sliver taller than the chart"
    cb, bb = L["chart_base"], L["bars"]
    assert cb[0] == bb[0] and cb[2] == bb[2] and cb[1] == bb[1] + bb[3], "the baseline is not under the bars"
    assert cb[1] + cb[3] <= L["chart_from"][1], "the baseline runs into the turn labels"
    cg = L["chart_grid"]
    assert cg[0] == bb[0] and cg[2] == bb[2] and cg[1] == bb[1], "the top line is not at the bars' full height"
    assert L["chart_top"][1] + L["chart_top"][3] <= cg[1], "the top figure is not above its line"
    assert L["chart_to"][0] + L["chart_to"][2] == bb[0] + bb[2], "Turn N does not end where the bars do"


# CA'S BUTTON ART IS NOT ALL BUTTON: button_square_large_text_*.png is 339x51 and draws only
# x 27-312, y 6-42 (its alpha, measured 2026-10-02). Stretched to a component, the face is that
# share of it, so a label sized to the component overran the face in game ("Allow all exports"
# on a 140px button, author's screenshot 2026-10-02).
BTN_FACE = ((27, 312, 339), (6, 42, 51))
BTN_PAD = 6          # each side of a label, inside the face


def face(w, h):
    (x0, x1, aw), (y0, y1, ah) = BTN_FACE
    return w * (x1 - x0) / aw, h * (y1 - y0) / ah


def check_map_frame():
    """MAP_FRAME_OUT is where CA's border art starts drawing, read off the art itself on all four
    sides (the preview's extracted copy; skipped when it has not been extracted yet)."""
    path = os.path.join(ROOT, ".skilltree_cache", "ui_preview", *MAP_FRAME["path"].split("/"))
    if not os.path.exists(path):
        return
    from PIL import Image
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    a = lambda x, y: im.getpixel((x, y))[3]
    sides = (next(x for x in range(w) if a(x, h // 2) == 255),
             next(y for y in range(h) if a(w // 2, y) == 255),
             next(x for x in range(w) if a(w - 1 - x, h // 2) == 255),
             next(y for y in range(h) if a(w // 2, h - 1 - y) == 255))
    assert set(sides) == {L["MAP_FRAME_OUT"]}, "CA's border starts %s px in, not MAP_FRAME_OUT" % (sides,)


def check_button_faces():
    """Every text button's longest label fits the drawn face of CA's art, not the component."""
    import gen_resource_overhaul as G
    buttons = [(L["tab_goods"], ("Resources",)), (L["tab_settlements"], ("Settlements",)),
               (L["tab_trade"], ("Trade",)), (L["tab_spending"], ("Spending",)), (L["tab_map"], ("Map",)),
               (L["tab_workshop"], ("Workshop",)), (L["tab_production"], ("Production",)),
               (L["back"], ("Back",)),
               (L["bulk"], ["Allow all exports", "Stop all imports", "Sell surplus"] + [o[4] for o in G.ORDERS]),
               ((0, 0) + L["send"], ("Send here", "Show", "Buy", "Buy here", "Forged", "Built", "Choose", "Enable", "Pause"))]
    for (_x, _y, w, h), labels in buttons:
        fw, fh = face(w, h)
        for t in labels:
            assert CHAR_W * len(t) + 2 * BTN_PAD <= fw, "%r overruns a %dpx button's %dpx face" % (t, w, fw)
            assert 12 + 4 <= fh, "a %dpx-tall button's face is %dpx, under a 12pt line" % (h, fh)


# ponytail: a flat glyph-width estimate for body_12, not a font metric. The cells are "Never
# split", so text past its column runs into the next one. Measure in game if a column clips.
CHAR_W = L["CHAR_W"]


def check_text_fits():
    """The longest good name fits every view's name column and, with " 100%", the Settlements
    tab's Fullest store; the widest Space sum fits the Goods tab's. The headers are checked by
    the harness, against what each view actually writes."""
    import gen_resource_overhaul as G
    longest = max((n for _r, _f, n in G.store_stems().values()), key=len)
    V = L["VIEWS"]
    for view, cols in V.items():
        assert CHAR_W * len(longest) <= cols[0][1], "%r overflows %s's name column" % (longest, view)
    assert CHAR_W * len(longest + " 100%") <= V["settlements"][4][1], "%r overflows Fullest store" % longest
    assert CHAR_W * len("123456 / 200000") <= V["goods"][3][1], "a realm-wide Space sum overflows"
    assert CHAR_W * len("123456 / 200000") <= V["focus"][1][1], "a drill-down's Held / Space overflows"
    top = G.STORE_BASE + G.STORE_STEP * G.STORE_TOP     # the most space a settlement's store can have
    assert CHAR_W * len("%d / %d Full" % (top, top)) <= V["focus"][1][1], "a full store's Held / Space and mark overflow"
    assert CHAR_W * len("999.99") <= V["focus"][3][1], "a drill-down's Price overflows"


def check_xml():
    """One file per builder; every GUID unique across them and linked; every image and sound real."""
    import gen_mr_emitter as E
    texts = {rel: t for rel, t in files().items() if rel.endswith(".twui.xml")}
    assert len(texts) == len(BUILDERS) * (1 + len(SIZES)) - len(SIZES) * len(UNSIZED_FILES), sorted(texts)
    seen = {}
    for rel, text in texts.items():
        for g in set(re.findall(r'uniqueguid="([^"]+)"', text)):
            assert g not in seen, "GUID %s in %s and %s" % (g, seen[g], rel)
            seen[g] = rel
            assert text.count(g) >= 2, "GUID %s appears once in %s" % (g, rel)
    have = E._game_assets()
    cats = E._game_sound_categories()
    for rel, text in texts.items():
        for p in re.findall(r'imagepath="([^"]+)"', text):
            assert p in have, "%s: not in CA's ui packs: %s" % (rel, p)
        for s in re.findall(r'soundcategory="([^"]+)"', text):
            assert s in cats, "%s: a sound CA never uses: %s" % (rel, s)
    with io.open(SRC, encoding="utf-8") as fh:       # art the script swaps in at runtime
        for p in re.findall(r'"(ui/[^"]+\.png)"', fh.read()):
            assert p in have or (p == "ui/skins/default/derpy_mr_provisions.png" and os.path.isfile(os.path.join(ROOT, PACK_REL, *p.split("/")))), "missing runtime art: %s" % p
    for stem, _res, icon in goods():
        assert icon in have or os.path.isfile(os.path.join(ROOT, PACK_REL, *icon.split("/"))), \
            "no icon for %s: %s" % (stem, icon)
    import gen_iron_court
    reg = gen_iron_court.sound_registry()
    for kind, ev in WORK_SOUND.items():   # the Workshop's purchase sounds: an unknown name is silence
        assert ev.lower() in reg, "the %s purchase sound %s is not in CA's sound registry" % (kind, ev)
    for use, icon in USE_ICON.items():   # the Workshop's price cell
        assert "ui/campaign ui/effect_bundles/" + icon in have, "no icon for the %s price: %s" % (use, icon)
    import gen_resource_overhaul as G
    for key, d in G.SERVICES.items():    # the Production tab's Gives, by the service's own bundle icon
        assert "ui/campaign ui/effect_bundles/" + d["icon"] in have, "no icon for the %s service: %s" % (key, d["icon"])


def check_smooth_mutations():
    """The pre-upload pass (2026-11-03): the carts step on the real clock and only where the camera looks, the map
    rests in the computers' turns, a turn start reads each store whole once, and the four live findings (the Chaos
    Dwarf bandits that never came, the runner offered after the goods went, the guards' double click). Each rule
    broken once; the harness that owns the script must fail on every one."""
    luac = LUA_EXE.replace("lua.exe", "luac.exe")
    with io.open(TERRAIN_SRC, encoding="utf-8", newline="") as fh:
        terrain = fh.read().replace("\r\n", "\n")
    beat = "trip.due = now - trip.due > R.STEP_LATE and now + R.STEP or trip.due + R.STEP"
    terrain_m = (
        ("the beat drifts by the timer's lateness", beat, "trip.due = now + R.STEP"),
        ("a stall catches up in a burst", beat, "trip.due = trip.due + R.STEP"),
        ("a cart steps every call", "if trip and trip.active and now >= trip.due then",
         "if trip and trip.active then"),
        ("every frame reads the map", "pl = trip.place or R.place(trip)", "pl = R.place(trip)"),
        ("a step keeps the last hex's scene", "            trip.fresh, trip.place = true, nil\n",
         "            trip.fresh = true\n"),
        ("a cleared map keeps the departure wait", "    R.depart_at = nil\n", ""),
        ("the view ignores the bearing", "v.ux, v.uy = math.sin(b), math.cos(b)", "v.ux, v.uy = 0, 1"),
        ("the view is the circle alone", "    if not v.ux then return true end\n", "    do return true end\n"),
        ("a camera turned on the spot is no move", " or math.abs((b or 0)-(camera.b or 0)) > 0.05", ""),
        ("the map redrawn in the computers' turn", "        if not cm:is_local_players_turn() then return end\n", ""),
        ("the icon held at the join the old 100 ms", "R.ICON_HOLD = 40\n", "R.ICON_HOLD = 100\n"),
        ("the old icon dropped as the new one starts", "old=current and current.bank,retire", "old=nil,retire"),
    )
    for label, before, after in terrain_m:
        assert terrain.count(before) == 1, "stale smooth mutation: " + label
        changed = terrain.replace(before, after, 1)
        syntax = subprocess.run([luac, "-p", "-"], input=changed, capture_output=True, text=True)
        assert syntax.returncode == 0, (label, syntax.stderr)
        code, out = run_terrain_harness(changed)
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    flows = flows_lua().replace("\r\n", "\n")
    hit = "    if hit then return copy(hit[1]), hit[2], copy(hit[3]) end\n"
    flows_m = (
        ("a turn start reads a store whole every time", hit, ""),
        ("a reader's change reaches the kept copy", hit, "    if hit then return hit[1], hit[2], hit[3] end\n"),
        ("the kept copy is the first reader's table", "kept[rk] = { copy(held), cap, copy(capacity) }",
         "kept[rk] = { held, cap, capacity }"),
        ("a write keeps the stale copy", "    if F.stock_cache then F.stock_cache[region:name()] = nil end\n", ""),
        ("the copy outlives the turn start", "    F.stock_cache = nil\n    if not ok then error(e, 0) end\n",
         "    if not ok then error(e, 0) end\n"),
        ("a throw leaves the copy", "local ok, e = pcall(F.turn_start, faction)", "local ok, e = true, F.turn_start(faction)"),
        ("the runner offered after the goods went", " and not sent_this_turn(fkey, k, turn)", ""),
        ("the Ogre bandits never asked", "for _, s in ipairs(sc == F.ROAD.qb_sc and { sc } or { sc, F.ROAD.qb_sc }) do",
         "for _, s in ipairs({ sc }) do"),
        ("a race's bandits that never came taken as made", "            if force then return force end\n",
         "            do return force end\n"),
    )
    for label, before, after in flows_m:
        assert flows.count(before) == 1, "stale smooth mutation: " + label
        code, out = run_harness(FLOWS_HARNESS, flows_text=flows.replace(before, after, 1))
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    stores = stores_lua().replace("\r\n", "\n")
    stores_m = (
        ("a double click sends the guards away", "        if S.guards_at and t - S.guards_at < 0.5 then return end\n", ""),
    )
    for label, before, after in stores_m:
        assert stores.count(before) == 1, "stale smooth mutation: " + label
        code, out = run_harness(HARNESS, stores_text=stores.replace(before, after, 1))
        assert code != 0 and "harness ok" not in out, "survived: %s\n%s" % (label, out)
        print("  caught:", label, "-", _why(out))
    code, out = run_terrain_harness()
    assert code == 0, out
    n = len(terrain_m) + len(flows_m) + len(stores_m)
    print("smooth mutations: %d/%d caught; restored harnesses pass" % (n, n))


def selftest():
    import build_mr_terrain_routes
    build_mr_terrain_routes.selftest()
    route_check = subprocess.run([LUA_EXE, os.path.join(ROOT, 'tools', '_resource_terrain_routes_harness.lua')],
                                 cwd=ROOT, capture_output=True, text=True)
    assert route_check.returncode == 0, route_check.stdout + route_check.stderr
    import test_service_labels
    test_service_labels.check()
    check_layout()
    check_text_fits()
    check_button_faces()
    check_map_frame()
    check_xml()
    check_sizes()
    check_capture_kinds()
    check_uses()
    check_recruit()
    check_escorts()
    import gen_resource_overhaul as G
    g = goods()
    assert [s for s, _r, _i in g] == list(G.store_stems()), "the panel's goods are not the stores"
    assert len(g) == 58, len(g)
    # stale() sees a hand edit, so pack() cannot ship one
    tmp = tempfile.mkdtemp()
    try:
        write_all(tmp)
        assert stale(tmp) == [], stale(tmp)
        with io.open(os.path.join(tmp, LUA_REL), "a", encoding="utf-8", newline="\n") as fh:
            fh.write("-- edited by hand\n")
        assert stale(tmp) == [LUA_REL], stale(tmp)
    finally:
        shutil.rmtree(tmp)
    assert os.path.isfile(LUA_EXE), "lua.exe is required for the harness"
    for h in (HARNESS, FLOWS_HARNESS):
        code, out = run_harness(h)
        assert code == 0 and "harness ok" in out, "%s:\n%s" % (os.path.basename(h), out)
    check_economy_mutations()
    check_provision_mutations()
    check_route_mutations()
    check_convoy_mutations()
    check_map_road_mutations()
    check_cargo_view_mutations()
    check_reach_mutations()
    check_drag_mutations()
    check_map_cost_mutations()
    check_production_mutations()
    check_spoil_mutations()
    check_race_mutations()
    check_turn_end_mutations()
    check_size_mutations()
    check_edict_mutations()
    check_toll_mutations()
    check_blockade_mutations()
    check_road_mutations()
    check_event_mutations()
    check_kept_mutations()
    check_smooth_mutations()
    # the Lua builds derpy_mr_store_<stem>_<kind> from FLOW_KIND; those must be Task 2's junctions
    assert set(FLOW_KIND.values()) == {k for k, _p, _n in G.FLOW_FACTORS}, FLOW_KIND
    assert G.flow_junction("coal", "raided") == "derpy_mr_store_coal_raided"
    problems = stale()
    assert not problems, "stale, run py tools/gen_mr_ui.py: %s" % problems
    import preview_guilds_panel as PV
    if os.path.isdir(PV.STUDIO):            # TWUI Studio: in the workspace, never in the repo
        bad = PV.validate("derpy_mr_stores_")
        assert not bad, "\n".join(bad)
    print("gen_mr_ui selftest: ok")


SAMPLE_HEADS = ("Resource", "Held", "Per turn", "Space", "Stored in")
SAMPLE = (("Salted Fish", "1240", "+18", "1240 / 4000", "7 of 12"),
          ("Medicinal Plants", "300", "+6", "300 / 600", "2 of 12"),
          ("Iron", "0", "+4", "0 / 200", "1 of 12"))


def preview(path=None, chart=False):
    """The layout drawn from L, with sample rows: a design-review picture, not the engine.
    chart=True draws a good's drill-down: the short list and a demo history under it."""
    from PIL import Image, ImageDraw
    name = "mr_stores_chart.png" if chart else "mr_stores.png"
    path = path or os.path.join(ROOT, ".skilltree_cache", "ui_preview", name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    W, H = L["W"], L["H"]
    im = Image.new("RGB", (W, H), (43, 33, 22))
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, W - 1, H - 1), outline=(200, 160, 90), width=3)
    ink, line = (255, 248, 215), (107, 88, 54)

    def box(b, label):
        x, y, w, h = b
        d.rectangle((x, y, x + w, y + h), outline=line)
        d.text((x + 4, y + 4), label, fill=ink)

    for k, label in (("title", "Resource Vault"), ("close", "X"), ("tab_goods", "Goods"),
                     ("tab_settlements", "Settlements"), ("tab_trade", "Trade"), ("back", "Back"),
                     ("sub_title", "Where Salted Fish is kept" if chart else
                      "Every resource your settlements keep"),
                     ("hint", "" if chart else "Click a resource to see where it is kept.")):
        box(L[k], label)
    lx, ly, lw, _lh = L["list"]
    rows = L["CHART_ROWS"] if chart else L["ROWS"]
    for j, (x, w, _a) in enumerate(COLS):
        box((lx + x, L["head_y"], w, 22), SAMPLE_HEADS[j])
    for i in range(rows):
        y = ly + i * L["PITCH"]
        d.rectangle((lx, y, lx + lw - L["SLIDER_W"], y + L["PITCH"] - 2), fill=(30, 24, 16))
        ix, iy, iw, ih = L["icon"]
        d.rectangle((lx + ix, y + iy, lx + ix + iw, y + iy + ih), outline=(200, 160, 90))
        for j, (x, w, _a) in enumerate(COLS):
            t = SAMPLE[i % len(SAMPLE)][j]
            tx = lx + x if ALIGN[j] == "Left" else lx + x + w - d.textlength(t)
            d.text((tx, y + 8), t, fill=ink)
    d.rectangle((lx + lw - L["SLIDER_W"], ly, lx + lw, ly + rows * L["PITCH"]), outline=(200, 160, 90))
    if chart:
        demo = [40, 55, 60, 52, 80, 95, 90, 120, 118, 130, 160, 150, 170, 168, 190, 210, 205, 220, 240, 236]
        bx, by, _bw, bh = L["bars"]
        top = max(demo)
        for i, v in enumerate(demo):
            h = max(L["BAR_MIN"], v * bh // top)
            x = bx + i * L["BAR_PITCH"]
            d.rectangle((x, by + bh - h, x + L["BAR_W"], by + bh), fill=(200, 160, 96))
        box(L["chart_top"], str(top))
        box(L["chart_from"], "Turn 31")
        box(L["chart_to"], "Turn 50")
        box(L["chart_line"], "Last turn: made +12, raided -30, traded in +5")
    im.save(path)
    return path


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == []:
        write_all()
        print("wrote %d files" % len(files()))
    elif args == ["--check"]:
        bad = stale()
        for b in bad:
            print("stale:", b)
        sys.exit(1 if bad else 0)
    elif args == ["--selftest"]:
        selftest()
    elif args == ["--preview"]:
        print("wrote", preview())
        print("wrote", preview(chart=True))
    else:
        raise SystemExit("unknown arguments %r - see the docstring" % (args,))
