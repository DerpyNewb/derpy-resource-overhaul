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
     "Each turn, every trade agreement sends this share of a resource from the sender's fullest store "
     "to the partner's capital, for each resource the partner lacks. 0 turns this off.", 0, 25, 5),
    # PHASE 5: shipments are drawn on the map, so their number is held down
    ("ships", "Shipments on the road",
     "How many shipments of yours can be on the road at once. Sending a resource between your settlements "
     "takes two turns, and an army at war with you can seize it on the way. Other factions keep one.", 1, 10, 3),
)
AI_SWITCH = ("ai", "Other factions use their stores",
             "Factions no player controls raid, sack, trade, eat and gain bonuses from their stores as a "
             "player does. Off: resources move only when a player's faction is one of the two, and other "
             "factions' settlements neither eat nor gain bonuses, which makes turns faster on a slow "
             "machine.", True)
# PHASE 4 (spending spec section 2): settlements eat provisions and well-stocked stores give bonuses
UPKEEP_SWITCH = ("upkeep", "Settlements use their stores",
                 "Each turn every settlement eats provisions from its stores. Five turns of provisions left "
                 "make it Well fed; war materials and luxuries filling a quarter of one store's space give "
                 "Garrison stocked and Comforts. Off: stores are only kept, raided and traded.", True)
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
                 "and Arms stocked in every settlement you hold in its province, and can send for goods from "
                 "the province's other settlements. Off: no province supplies.", True)
SWITCHES = (AI_SWITCH, UPKEEP_SWITCH, ACTIONS_SWITCH, EVENTS_SWITCH, SUPPLY_SWITCH)
# THE FIVE USES (spending spec section 1): every store has exactly one; check_uses() asserts it.
USES = {
    "provisions": ("grain", "salted_fish", "salted_meat", "olive_oil", "tea", "kvas", "mead", "rum", "beer",
                   "wine", "spices", "salt", "medicine"),
    "building": ("timber", "marble", "pottery", "glassware", "starwood"),
    "war": ("iron", "coal", "brass", "blackpowder", "brimstone", "gromril", "ithilmar", "quicksilver",
            "obsidian", "whale_oil"),
    "mounts": ("warhorses", "feathers", "rhinox_hides", "wyvern_scales", "dragon_bone", "sea_dragon_hide",
               "animals", "tusks", "furs"),
    "luxuries": ("silk", "jade", "carpets", "porcelain", "pearls", "amber", "lustrian_plumes", "incense",
                 "black_lotus", "pipeweed", "books", "gems", "gold_idols", "dyes", "trinkets", "silver", "wool"),
}
# WHO HAS NO STORES TO USE: the subculture tokens whose buildings make nothing
# (gen_resource_overhaul.EXCLUDE); check_uses() asserts the two lists agree.
NO_STORES = ("dae", "kho", "nur", "sla", "tze", "tmb", "nag", "bst")
# Which factor each kind of move books to: the junction is derpy_mr_store_<stem>_<kind>.
FLOW_KIND = {"raid": "raided", "sack": "plundered", "raze": "plundered", "trade": "traded", "eat": "eaten",
             "move": "moved", "spend": "spent", "sell": "sold"}
# PHASE 7: gold a unit when the Zharr Exchange is not there to price it (spending spec section 5)
SELL_RATE = {"provisions": 1, "building": 2, "war": 3, "mounts": 4, "luxuries": 5}

# THE LAYOUT, in panel coordinates: (x, y, w, h). The Lua MoveTo's every component from these;
# the .twui.xml sizes are the same numbers. cols are (x, w) inside a row, which starts at list x.
L = {
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
    # FIVE TABS, 120 wide and 6 apart, clear of Back at 720
    "tab_goods": (20, 56, 120, 26), "tab_settlements": (146, 56, 120, 26),
    "tab_trade": (272, 56, 120, 26), "tab_spending": (398, 56, 120, 26), "tab_map": (524, 56, 120, 26),
    # THE MAP TAB: the list's own box, a pad inside it, and no picture of the map - it is framed on
    # the dots it draws, so it fits any campaign. A capital's dot is larger and named; a convoy is
    # CA's convoy icon on MAP_STEPS dots from where it left to where it goes. MAP_MIN_SPAN keeps one
    # lone settlement from being blown up to fill the box.
    "map": (20, 142, 820, 448), "MAP_PAD": 24, "MAP_DOT": 20, "MAP_CAP": 26, "MAP_PATH": 4,
    "MAP_STEPS": 6, "MAP_CART_SIZE": 28, "MAP_MIN_SPAN": 40, "map_label": (160, 16),
    # ON CA'S MINIMAP (one pixel to one logical unit): never closer than MAP_ART_ZOOM, past which
    # the picture is a blur. MAP_CHAR_W is a name's width per letter at 11px, for spacing names.
    "MAP_ART_ZOOM": 2, "MAP_CHAR_W": 6.5,
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
    "USING": 3,
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
        "goods": ((36, 204, "left"), (244, 90, "right"), (338, 100, "right"), (442, 110, "right"),
                  (556, 240, "right")),
        "focus": ((36, 230, "left"), (276, 120, "right"), (406, 90, "right"), (506, 80, "left"),
                  (596, 204, "left")),
        "settlements": ((36, 230, "left"), (276, 46, "right"), (330, 90, "left"), (430, 80, "right"),
                        (520, 280, "right")),
        "trade": ((36, 230, "left"), (276, 60, "right"), (346, 90, "centre"), (446, 90, "centre"),
                  (546, 254, "left")),
        # the Spending tab: a capital's four supply boxes in 2-5; a shipment's from, to and turn in
        # 2-4 and its Show button in 5
        "spending": ((36, 230, "left"), (276, 126, "centre"), (408, 126, "centre"), (540, 126, "centre"),
                     (672, 128, "centre")),
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
             "Spending||What your stores pay for: province supplies, shipments on the road, and orders."),
            ("derpy_mr_tab_map", L["tab_map"], "Map||Where your settlements and convoys are."),
            ("derpy_mr_back", L["back"], "Back to the full list.")):
        p.add(_cell(E, name, box[2], box[3], interactive=True, image=BTN_BG,
                    hover=[_flat(BTN_HOVER)], sound=SND_SMALL, align="Center", tooltip=tip))
    p.add(_cell(E, "sub_title", L["sub_title"][2], L["sub_title"][3], size=13, colour=MUTED))
    for j, (_x, w, _a) in enumerate(COLS, 1):
        p.add(_cell(E, "hdr_%d" % j, w, 22, size=12, colour=MUTED, align=ALIGN[j - 1]))
    for j in range(2, len(COLS) + 1):
        p.add(E.C("hdr_line_%d" % j, 1, 22, image=WHITE, colour_img=DIVIDER_COLOUR))
    p.add(E.C("rows_holder", L["list"][2], L["list"][3]))
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
    E.assign(root, "MR01")
    return E.layout(root, "derpy: Resource Overhaul's Stores panel. Created at runtime by "
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
    for j, (_x, cw, _a) in enumerate(COLS, 1):
        r.add(_cell(E, "c%d" % j, cw, 20, size=12, align=ALIGN[j - 1]))
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
    E.assign(root, "MR02")
    return E.layout(root, "derpy: one row of the Stores panel, created per row into rows_holder. "
                    "Generated by tools/gen_mr_ui.py; do not hand-edit.")


def build_button():
    import gen_mr_emitter as E
    n = L["BUTTON"]
    root = E.C("root", n, n)
    root.add(E.C("derpy_mr_stores_button", n, n, interactive=True, sound=SND_OPEN,
                 tooltip=TIP_OPEN, layers=_round("active", OPENER_ICON, 10, "medium"),
                 hover=_round("hover", OPENER_ICON, 10, "medium")))
    E.assign(root, "MR03")
    return E.layout(root, "derpy: the button that opens the Stores panel. Generated by "
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
    E.assign(root, "MR04")
    return E.layout(root, "derpy: the Stores panel's scrolling list. rows_holder is adopted into "
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
    E.assign(root, "MR05")
    return E.layout(root, "derpy: one empty row of the Stores panel's list. Generated by "
                    "tools/gen_mr_ui.py; do not hand-edit.")


def build_bar():
    """One bar of the history chart: a flat tinted image the Lua sizes and moves."""
    import gen_mr_emitter as E
    root = E.C("root", L["BAR_W"], L["bars"][3])
    root.add(E.C("derpy_mr_stores_bar", L["BAR_W"], L["bars"][3], interactive=True,
                 image=WHITE, colour_img=BAR_COLOUR))
    E.assign(root, "MR06")
    return E.layout(root, "derpy: one bar of the Stores panel's history chart, created twenty "
                    "times into the panel. Generated by tools/gen_mr_ui.py; do not hand-edit.")


MAP_DOT_COLOUR = "#E0553CFF"     # a settlement: red ink, read on CA's parchment and on black alike
MAP_PATH_COLOUR = "#E0553CCC"    # the dotted road, the settlements' red, a little fainter
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
    E.assign(root, "MR07")
    return E.layout(root, "derpy: a settlement on the Stores panel's Map tab. Generated by "
                    "tools/gen_mr_ui.py; do not hand-edit.")


def build_mapcart():
    """A convoy on the Map tab: CA's convoy icon, with a tooltip and a click."""
    import gen_mr_emitter as E
    s = L["MAP_CART_SIZE"]
    root = E.C("root", s, s)
    root.add(E.C("derpy_mr_stores_mapcart", s, s, interactive=True, image=L["MAP_CART"], sound=SND_SMALL))
    E.assign(root, "MR08")
    return E.layout(root, "derpy: a convoy on the Stores panel's Map tab. Generated by "
                    "tools/gen_mr_ui.py; do not hand-edit.")


def build_mappath():
    """One dot of a convoy's road on the Map tab."""
    import gen_mr_emitter as E
    root = E.C("root", L["MAP_PATH"], L["MAP_PATH"])
    root.add(E.C("derpy_mr_stores_mappath", L["MAP_PATH"], L["MAP_PATH"], image=WHITE,
                 colour_img=MAP_PATH_COLOUR))
    E.assign(root, "MR09")
    return E.layout(root, "derpy: one dot of a convoy's road on the Stores panel's Map tab. Generated "
                    "by tools/gen_mr_ui.py; do not hand-edit.")


def build_maplabel():
    """A province capital's name on the Map tab."""
    import gen_mr_emitter as E
    w, h = L["map_label"]
    root = E.C("root", w, h)
    root.add(_cell(E, "derpy_mr_stores_maplabel", w, h, size=11))
    E.assign(root, "MR10")
    return E.layout(root, "derpy: a province capital's name on the Stores panel's Map tab. Generated "
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
    E.assign(root, "MR11")
    return E.layout(root, "derpy: CA's campaign minimap under the Stores panel's Map tab. Generated "
                    "by tools/gen_mr_ui.py; do not hand-edit.")


BUILDERS = (("derpy_mr_stores_panel", build_panel), ("derpy_mr_stores_row", build_row),
            ("derpy_mr_stores_button", build_button), ("derpy_mr_stores_list", build_list),
            ("derpy_mr_stores_sp", build_sp), ("derpy_mr_stores_bar", build_bar),
            ("derpy_mr_stores_mapdot", build_mapdot), ("derpy_mr_stores_mapcart", build_mapcart),
            ("derpy_mr_stores_mappath", build_mappath), ("derpy_mr_stores_maplabel", build_maplabel),
            ("derpy_mr_stores_mapart", build_mapart))


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


def check_capture_kinds():
    got = dict(capture_kinds())
    assert len(got) > 40, "only %d sack/raze options read" % len(got)
    for oid, kind in MEASURED_OPTIONS.items():
        assert got.get(oid) == kind, "option %d is %r in the table, %r in game" % (oid, got.get(oid), kind)


def _lua(v):
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
    lines += ["}", "DERPY_MR_STORES_GOODS = {"]
    lines += ['    {stem = "%s", res = "%s", icon = "%s"},' % g for g in goods()]
    lines += ["}", "DERPY_MR_CAPTURE_KIND = {"]
    lines += ['    [%d] = "%s",' % kv for kv in capture_kinds()]
    lines += ["}", "DERPY_MR_STORES_BUNDLES = {"]
    lines += ['    {key = "%s", icon = "ui/campaign ui/effect_bundles/%s"},' % (k, i) for _u, k, i, *_r in bundles()]
    import gen_resource_overhaul as G
    lines += ["}", "DERPY_MR_STORES_ORDERS = {"]
    lines += ['    {key = "%s", use = "%s", label = "%s", what = "%s", turns = %d},' % (k, u, t, w, G.ORDER_TURNS)
              for k, u, _b, _i, t, w, _f in G.ORDERS]
    lines += ["}", "DERPY_MR_STORES_SUPPLY = {"]
    lines += ['    {key = "%s", label = "%s", use = "%s", what = "%s"},' % (k, l, u, w)
              for (k, l, u), w in zip(supply_buttons(), [s[5] for s in G.SUPPLY] + [""])]
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


def flows_header():
    lines = ["-- GENERATED by tools/gen_mr_ui.py from Modding Files/source/resource_overhaul/flows.lua.",
             "-- Edit the source or the generator, never this file.",
             "DERPY_MR_FLOWS_DEFAULTS = {"]
    lines += ["    %s = %d," % (k, d) for k, _l, _t, _lo, _hi, d in RATES]
    lines += ["    %s = %s," % (k, "true" if d else "false") for k, _l, _t, d in SWITCHES]
    lines += ["}", "DERPY_MR_FLOWS_KIND = {"]
    lines += ['    %s = "%s",' % (k, FLOW_KIND[k]) for k in sorted(FLOW_KIND)]
    lines += ["}", "DERPY_MR_FLOWS_GOODS = {"]
    lines += ['    {stem = "%s", res = "%s", use = "%s"},' % (s, r, use_of(s)) for s, r, _i in goods()]
    import gen_resource_overhaul as G
    lines += ["}", "DERPY_MR_FLOWS_ORDERS = {"]
    lines += ['    %s = {use = "%s", bundle = "%s"},' % (k, u, b) for k, u, b, *_r in G.ORDERS]
    lines += ["}", "DERPY_MR_FLOWS_ORDER = {%d, %d, %d}   -- cost, turns, cooldown"
              % (G.ORDER_COST, G.ORDER_TURNS, G.ORDER_COOLDOWN),
              "DERPY_MR_FLOWS_SELL_RATE = {%s}" % ", ".join("%s = %d" % (u, SELL_RATE[u]) for u in sorted(SELL_RATE))]
    lines += ["DERPY_MR_FLOWS_EVENT = {%d, %d}   -- gap in turns, a computer's chance in 100"
              % (G.EVENT_GAP, G.EVENT_AI_PCT), "DERPY_MR_FLOWS_EVENTS = {"]
    for e in G.EVENTS:
        b = e["bundle"]
        lines.append('    %s = {use = "%s", cost = %d, where = "%s", dilemma = "%s", bundle = %s, turns = %d},'
                     % (e["key"], e["use"], e["cost"], e["where"], G.event_dilemma(e["key"]),
                        '"%s"' % b[0] if b else "nil", b[3] if b else 0))
    lines.append("}")
    lines += ["DERPY_MR_FLOWS_SUPPLY = {"]
    lines += ['    %s = {use = "%s", bundle = "%s"},' % (k, u, b) for k, u, b, *_r in G.SUPPLY]
    lines += ["}", "DERPY_MR_FLOWS_SUPPLY_ORDER = {%s}" % ", ".join('"%s"' % s[0] for s in G.SUPPLY),
              "DERPY_MR_FLOWS_SHIP = {per = %d, turns = %d, ai_cap = %d, stand = %d, ai_on = %d, radius = %d, "
              'near = %d, spot = %d, info = "%s"}'
              % (G.SUPPLY_PER, G.SHIP_TURNS, G.SHIP_AI_CAP, G.SHIP_STAND, G.SHIP_AI_ON, G.SHIP_RADIUS,
                 G.SHIP_NEAR, G.SHIP_SPOT, G.SHIP_INFO)]
    lines += ["DERPY_MR_FLOWS_NO_STORES = {%s}" % ", ".join('"%s"' % t for t in NO_STORES),
              "DERPY_MR_FLOWS_BUNDLES = {"]
    lines += ['    %s = "%s",' % (u, k) for u, k, *_r in bundles()]
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
            "they are ignored and every value is the default on every machine.")


def mct_lua():
    lines = ["-- GENERATED by tools/gen_mr_ui.py - do not edit by hand.",
             "--",
             "-- MCT registration for Resource Overhaul's stores. MCT loads every .lua under",
             "-- script/mct/settings/, so this file only ever runs when MCT is installed. The",
             "-- campaign script freezes these values into the save at the first turn start.",
             "",
             "local mct = get_mct and get_mct()",
             "if not mct then return end",
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
                  'o_%s:set_assigned_section("stores")' % k]
    for (k, label, tip, d), section in ((AI_SWITCH, "stores"), (UPKEEP_SWITCH, "using"),
                                        (ACTIONS_SWITCH, "using"), (EVENTS_SWITCH, "using"),
                                        (SUPPLY_SWITCH, "using")):
        if k == "upkeep":
            lines += ["", 'm:add_new_section("using", "Using stores")']
        lines += ["",
                  'local o_%s = m:add_new_option("%s", "checkbox")' % (k, k),
                  'o_%s:set_text("%s")' % (k, label),
                  'o_%s:set_tooltip_text("%s")' % (k, tip),
                  "o_%s:set_default_value(%s)" % (k, "true" if d else "false"),
                  'o_%s:set_assigned_section("%s")' % (k, section)]
    return "\n".join(lines) + "\n"


def files():
    out = {UI_REL + name + ".twui.xml": build() for name, build in BUILDERS}
    out[LUA_REL] = stores_lua()
    out[FLOWS_REL] = flows_lua()
    out[MCT_REL] = mct_lua()
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


def run_harness(harness=HARNESS):
    """A harness against the built files, from a temp folder: (returncode, output).
    __SCRIPT__ and __STORES__ are the stores script, __FLOWS__ the flows script, __MCT__ the MCT
    settings file and __UIDIR__ the folder the .twui.xml files are in."""
    tmp = tempfile.mkdtemp()
    try:
        for rel, text in files().items():
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


def check_layout():
    """Every box inside the panel; headers, list and hint in order; columns clear of each
    other and of the slider. A box that leaves the panel draws over the map."""
    W, H = L["W"], L["H"]
    for k in ("title", "title_rule", "close", "tab_goods", "tab_settlements", "tab_trade", "back",
              "sub_title", "list", "empty", "hint"):
        x, y, w, h = L[k]
        assert 0 <= x and 0 <= y and x + w <= W and y + h <= H, "%s leaves the panel" % k
    lx, ly, lw, lh = L["list"]
    assert lh == L["ROWS"] * L["PITCH"], "the list is not ROWS rows tall"
    assert L["head_y"] + 22 <= ly and ly + lh <= L["bulk"][1], "headers, list and buttons overlap"
    assert L["hint"][:2] == L["sub_title"][:2], "the hint has left the sub-title's line"
    assert L["tab_trade"][0] >= L["tab_settlements"][0] + L["tab_settlements"][2], "the tabs overlap"
    tabs = [L[k] for k in ("tab_goods", "tab_settlements", "tab_trade", "tab_spending", "tab_map")]
    for a, b in zip(tabs, tabs[1:]):
        assert b[0] >= a[0] + a[2], "the tabs overlap"
    assert L["back"][0] >= L["tab_map"][0] + L["tab_map"][2], "back overlaps a tab"
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
               (L["back"], ("Back",)),
               (L["bulk"], ["Allow all exports", "Stop all imports", "Sell surplus"] + [o[4] for o in G.ORDERS]),
               ((0, 0) + L["send"], ("Send here", "Show"))]
    for (_x, _y, w, h), labels in buttons:
        fw, fh = face(w, h)
        for t in labels:
            assert CHAR_W * len(t) + 2 * BTN_PAD <= fw, "%r overruns a %dpx button's %dpx face" % (t, w, fw)
            assert 12 + 4 <= fh, "a %dpx-tall button's face is %dpx, under a 12pt line" % (h, fh)


# ponytail: a flat glyph-width estimate for body_12, not a font metric. The cells are "Never
# split", so text past its column runs into the next one. Measure in game if a column clips.
CHAR_W = 7


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


def check_xml():
    """One file per builder; every GUID unique across them and linked; every image and sound real."""
    import gen_mr_emitter as E
    texts = {rel: t for rel, t in files().items() if rel.endswith(".twui.xml")}
    assert len(texts) == len(BUILDERS), sorted(texts)
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
            assert p in have, "the script names art CA does not ship: %s" % p
    for stem, _res, icon in goods():
        assert icon in have or os.path.isfile(os.path.join(ROOT, PACK_REL, *icon.split("/"))), \
            "no icon for %s: %s" % (stem, icon)


def selftest():
    check_layout()
    check_text_fits()
    check_button_faces()
    check_map_frame()
    check_xml()
    check_capture_kinds()
    check_uses()
    import gen_resource_overhaul as G
    g = goods()
    assert [s for s, _r, _i in g] == list(G.store_stems()), "the panel's goods are not the stores"
    assert len(g) == 54, len(g)
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
