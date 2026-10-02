-- Derpy Resource Overhaul: the Stores panel script (derpy_more_resources_stores.lua), run against
-- stub regions, pools and UI. tools/gen_mr_ui.py --selftest writes the script and the generated
-- .twui.xml into a temp folder and fills in __SCRIPT__ and __UIDIR__. Every case is one the game
-- could hand it.
local UIDIR = "__UIDIR__"
local UI_ROOT                       -- the UI stub's root; Task 3 builds it
local ERRORS = {}
out = function(m) ERRORS[#ERRORS + 1] = tostring(m) end

local function eq(a, b, what)
    if a ~= b then error(what .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- ---- the model's world, stubbed -----------------------------------------------------------
local LOC = {
    pooled_resources_display_name_derpy_mr_store_coal = "Coal",
    pooled_resources_display_name_derpy_mr_store_brimstone = "Brimstone",
    pooled_resources_display_name_derpy_mr_store_iron = "Iron",
    regions_onscreen_reg_a = "Alpha", regions_onscreen_reg_b = "Bravo",
    regions_onscreen_reg_c = "Charlie",
}
local CCO = {}
common = {
    get_localised_string = function(k) return LOC[k] or "" end,
    get_context_value = function(_type, cqi, _expr) return CCO[cqi] end,
}

local function list(items)
    return { num_items = function() return #items end,
             item_at = function(_, i) return items[i + 1] end,
             is_empty = function() return #items == 0 end }
end
local NULL = { is_null_interface = function() return true end }
local function pool(key, value, max)
    return { is_null_interface = function() return false end, key = function() return key end,
             value = function() return value end, maximum_value = function() return max end }
end
-- pools: stem -> held, every store at the settlement's space `cap`; nil = a save from before
-- the stores. cco: what the settlement's buildings list, or nil when the read gives nothing.
local function region(key, cqi, level, cap, pools, cco, extra)
    local items = {}
    for stem, v in pairs(pools or {}) do items[#items + 1] = pool("derpy_mr_store_" .. stem, v, cap) end
    for _, x in ipairs(extra or {}) do items[#items + 1] = x end
    CCO[tostring(cqi)] = cco
    local settlement = {
        is_null_interface = function() return false end,
        cqi = function() return cqi end,
        primary_slot = function() return { building = function()
            return { building_level = function() return level end } end } end,
    }
    return {
        is_null_interface = function() return false end,
        name = function() return key end,
        settlement = function() return settlement end,
        pooled_resource_manager = function() return { resources = function() return list(items) end } end,
    }
end
local function faction(name, regions)
    return { is_null_interface = function() return false end, name = function() return name end,
             region_list = function() return list(regions) end }
end

local A = region("reg_a", 1, 2, 400, { coal = 100, brimstone = 0, iron = 0 },
    "derpy_mr_store_coal_stocked=6,derpy_mr_store_brimstone_stocked=6,derpy_mr_store_capacity=400",
    { NULL, pool("wh3_dlc27_sla_thralls_region", 5, 10) })
local B = region("reg_b", 2, 1, 200, { coal = 200, iron = 50 }, "")
local C = region("reg_c", 3, 1, 0, nil, nil)
local FACTIONS = { fac_a = faction("fac_a", { C, B, A }), fac_empty = faction("fac_empty", {}) }
local LOCAL = "fac_a"

local FIRST, REPEATS, LISTENERS = {}, {}, {}
local CHARS = {}
cm = {
    get_character_by_cqi = function(_, cqi) return CHARS[cqi] or false end,
    get_region = function(_, key) return { key = key } end,
    add_first_tick_callback = function(_, fn) FIRST[#FIRST + 1] = fn end,
    callback = function() end,                      -- retries are not run
    repeat_real_callback = function(_, fn, _ms, name) REPEATS[name] = fn end,
    get_local_faction_name = function() return LOCAL end,
    get_faction = function(_, name) return FACTIONS[name] end,
}
core = {
    get_ui_root = function() return UI_ROOT end,
    get_screen_resolution = function() return 1920, 1080 end,
    add_listener = function(_, _name, event, cond, fn)
        LISTENERS[#LISTENERS + 1] = { event = event, cond = cond, fn = fn }
    end,
}

dofile("__SCRIPT__")
local S = DERPY_MR_STORES

-- ---- the model ----------------------------------------------------------------------------
-- parse_made: each good's rows summed, the capacity effect and other mods' effects skipped
local m = S.parse_made("derpy_mr_store_coal_stocked=6,derpy_mr_store_coal_stocked=2.5,"
    .. "derpy_mr_store_capacity=400,derpy_mr_store_salted_fish_stocked=3,wh_main_other=9")
eq(m.coal, 8.5, "coal made"); eq(m.salted_fish, 3, "salted fish made")
eq(m.capacity, nil, "the capacity effect is not a good")
eq(next(S.parse_made("")), nil, "empty read"); eq(next(S.parse_made(nil)), nil, "nil read")

-- read_realm: name order; null pools and other mods' pools skipped; an old save has no space
local realm = S.read_realm(FACTIONS.fac_a)
eq(#realm, 3, "settlements"); eq(realm[1].name, "Alpha", "first by name"); eq(realm[3].name, "Charlie", "last")
eq(realm[1].cap, 400, "Alpha space"); eq(realm[1].held.coal, 100, "Alpha coal")
eq(realm[1].made.brimstone, 6, "Alpha makes brimstone"); eq(realm[1].level, 2, "Alpha level")
eq(realm[1].held.wh3_dlc27_sla_thralls_region, nil, "a pool that is not a store")
eq(realm[3].cap, 0, "old save: no space"); eq(next(realm[3].held), nil, "old save: nothing held")
eq(#S.read_realm(FACTIONS.fac_empty), 0, "no settlements"); eq(#S.read_realm(nil), 0, "no faction")

-- goods_rows: every good kept or made, most held first; space and count over the keepers
local g = S.goods_rows(realm)
eq(#g, 3, "goods"); eq(g[1].stem, "coal", "most held first"); eq(g[2].stem, "iron", "then iron")
eq(g[3].stem, "brimstone", "made but not yet held is listed")
eq(g[1].held, 300, "coal held"); eq(g[1].made, 6, "coal per turn"); eq(g[1].cap, 600, "coal space")
eq(g[1].n, 2, "coal kept in two"); eq(g[1].of, 3, "of three")
eq(g[3].cap, 400, "brimstone space is Alpha's alone")
eq(#S.goods_rows({}), 0, "empty realm")

-- good_detail: the settlements that keep it, most held first, Full at the brim
local d = S.good_detail(realm, "coal")
eq(#d, 2, "coal kept in two"); eq(d[1].name, "Bravo", "most held first")
eq(d[1].full, true, "Bravo is full"); eq(d[2].full, false, "Alpha is not")
eq(S.full(0, 0), false, "no space is not full")

-- settlement_rows and settlement_detail
local s = S.settlement_rows(realm)
eq(s[2].name, "Bravo", "by name"); eq(s[2].goods, 2, "Bravo holds two goods")
eq(s[2].fullest, "coal", "Bravo's fullest"); eq(s[2].pct, 100, "at 100%")
eq(s[3].goods, 0, "Charlie holds nothing"); eq(s[3].fullest, nil, "nothing is fullest")
local sd = S.settlement_detail(realm[1])
eq(#sd, 2, "Alpha keeps coal and makes brimstone"); eq(sd[1].stem, "coal", "held first")
eq(sd[2].made, 6, "brimstone per turn")

-- view_model: what each view puts on screen
S.view, S.focus = "goods", nil
local v = S.view_model(realm)
eq(v.heads[2], "Held", "goods header"); eq(v.rows[1][1], "Coal", "name"); eq(v.rows[1][3], "+6", "per turn")
eq(v.rows[1][4], "300 / 600", "space"); eq(v.rows[1][5], "2 of 3", "stored in"); eq(v.rows[1].open, "coal", "opens coal")
eq(v.rows[3][2], "0", "made, nothing held yet")
S.focus = "coal"; v = S.view_model(realm)
eq(v.title, "Where Coal is kept", "drill-down title")
eq(v.rows[1][1], "Bravo", "by settlement"); eq(v.rows[1][2], "200 / 200", "held / space")
eq(v.rows[1][4], "[[col:red]]Full[[/col]]", "full mark"); eq(v.rows[1].tip, S.FULL_TIP, "full tooltip")
eq(v.rows[2][4], "", "not full")
S.view, S.focus = "settlements", nil; v = S.view_model(realm)
eq(v.rows[2][2], "1", "Bravo level"); eq(v.rows[2][3], "200", "space per good")
eq(v.rows[2][5], "Coal 100%", "fullest"); eq(v.rows[3][5], "-", "none"); eq(v.rows[1].open, "reg_a", "opens Alpha")
S.focus = "reg_a"; v = S.view_model(realm)
eq(v.title, "Stores of Alpha", "settlement drill-down title"); eq(#v.rows, 2, "Alpha's two goods")
eq(v.rows[1][1], "Coal", "held first")
S.focus = "reg_gone"; v = S.view_model(realm)
eq(S.focus, nil, "a settlement no longer held drops the drill-down"); eq(#v.rows, 3, "back to the list")
S.view, S.focus = "goods", nil
eq(S.view_model({}).empty, S.NO_REALM, "no settlements says so")
eq(#S.view_model({ realm[3] }).rows, 0, "an old save lists no goods")
eq(S.view_model({ realm[3] }).empty, S.NOTHING, "and says nothing is stored yet")
eq(S.num(6), "6", "whole numbers"); eq(S.num(1.5), "1.5", "halves")

-- ---- the UI, stubbed from the generated .twui.xml ---------------------------------------
-- CreateComponent builds the hierarchy the generated file declares, so a name the script finds
-- is a name the file has. MoveTo carries a component's children, as the engine's does.
local TEMPLATES = {}
local function template(path)
    if TEMPLATES[path] then return TEMPLATES[path] end
    local f = assert(io.open(UIDIR .. "/" .. path:match("([^/]+)$") .. ".twui.xml"), "no file " .. path)
    local h = f:read("*a"):match("<hierarchy>(.-)</hierarchy>")
    f:close()
    local top = { name = "top", kids = {} }
    local stack = { top }
    for close, name, selfclose in h:gmatch("<(/?)([%w_]+)[^>]-(/?)>") do
        if close == "/" then
            table.remove(stack)
        else
            local node = { name = name, kids = {} }
            table.insert(stack[#stack].kids, node)
            if selfclose ~= "/" then stack[#stack + 1] = node end
        end
    end
    TEMPLATES[path] = top.kids[1].kids[1]          -- <root>'s one child
    return TEMPLATES[path]
end

local UIC = {}
UIC.__index = UIC
local function new(name, parent)
    local c = setmetatable({ name = name, kids = {}, parent = parent, x = 0, y = 0, w = 10, h = 10,
                             visible = true, text = "", tip = "", interactive = false,
                             state = "standard", texts = {},
                             __uic = true }, UIC)
    if parent then parent.kids[#parent.kids + 1] = c end
    return c
end
local function build(node, parent, name)
    local c = new(name or node.name, parent)
    for _, k in ipairs(node.kids) do build(k, c) end
    return c
end
local function unlink(c)
    local p = c.parent
    for i, k in ipairs(p.kids) do if k == c then table.remove(p.kids, i) break end end
    c.parent = nil
end
local function shift(c, dx, dy)
    c.x, c.y = c.x + dx, c.y + dy
    for _, k in ipairs(c.kids) do shift(k, dx, dy) end
end
function UIC:CreateComponent(name, path) return build(template(path), self, name) end
function UIC:Id() return self.name end
function UIC:Address() return self end
function UIC:MoveTo(x, y) shift(self, x - self.x, y - self.y) end
function UIC:Position() return self.x, self.y end
function UIC:Dimensions() return self.w, self.h end
function UIC:Resize(w, h) self.w, self.h = w, h end
function UIC:SetCanResizeWidth() end
function UIC:SetCanResizeHeight() end
function UIC:SetVisible(v) self.visible = v and true or false end
function UIC:Visible() return self.visible end
function UIC:SetInteractive(v) self.interactive = v and true or false end
-- SetStateText writes the CURRENT state only, as the engine's does; .text is the standard one.
function UIC:SetStateText(t) self.texts[self.state] = t; if self.state == "standard" then self.text = t end end
function UIC:GetStateText() return self.texts[self.state] or "" end
function UIC:SetState(s) self.state = s end
function UIC:CurrentState() return self.state end
function UIC:SetTooltipText(t) self.tip = t end
function UIC:SetImagePath(p, i) self.image = p; self.images = self.images or {}; self.images[i or 0] = p end
function UIC:SetProperty(k, v) self[k] = v end
function UIC:Layout() end
function UIC:Adopt(c) unlink(c); c.parent = self; self.kids[#self.kids + 1] = c end
function UIC:Destroy() unlink(self) end
local function find_one(c, name)
    if not is_uicomponent(c) then return false end
    for _, k in ipairs(c.kids) do
        if k.name == name then return k end
        local d = find_one(k, name)
        if d then return d end
    end
    return false
end
-- CA's takes a path: each name is looked for under the one before it
function find_uicomponent(c, ...)
    for _, name in ipairs({ ... }) do
        c = find_one(c, name)
        if not c then return false end
    end
    return c
end
function is_uicomponent(c) return type(c) == "table" and c.__uic == true end
function UIComponent(address) return address end
function UIC:Parent() return self.parent end
function UIC:GetContextObjectId(t) return (self.ctx and self.ctx[t]) or "" end
function UIC:ChildCount() return #self.kids end
function UIC:Find(i) return self.kids[i + 1] end
-- A sibling under the same parent, as the engine's: same images, text, visibility and children
-- (measured 2026-10-02: a copy of dy_income kept its icon child).
local function clone(src, name, parent)
    local c = new(name, parent)
    c.images, c.text, c.visible = {}, src.text, src.visible
    for i, p in pairs(src.images or {}) do c.images[i] = p end
    for _, k in ipairs(src.kids) do clone(k, k.name, c) end
    return c
end
function UIC:CopyComponent(name) return clone(self, name, self.parent) end

UI_ROOT = new("root")
local bar = new("resources_bar", UI_ROOT)
bar.x, bar.y, bar.w, bar.h = 431, -4, 1019, 60

local function fire(event, context)
    for _, l in ipairs(LISTENERS) do
        if l.event == event and (l.cond == true or (type(l.cond) == "function" and l.cond(context))) then
            l.fn(context)
        end
    end
end
local function click(name) fire("ComponentLClickUp", { string = name }) end
local function press(c) fire("ComponentLClickUp", { string = c.name, component = c }) end
local function find(name) return find_uicomponent(UI_ROOT, name) end
local function cell(i, j) return find_uicomponent(find("derpy_mr_row_" .. i), "c" .. j) end
local function shown_rows()
    local n, i = 0, 1
    while find("derpy_mr_row_" .. i) do
        if find("derpy_mr_row_" .. i).visible then n = n + 1 end
        i = i + 1
    end
    return n
end

-- the opener: made at first tick, right of the resource strip and centred on it
for _, fn in ipairs(FIRST) do fn() end
local b = find("derpy_mr_stores_button")
eq(b ~= false, true, "button made"); eq(b.x, 1454, "right of the strip"); eq(b.y, 2, "centred on it")
eq(b.visible, true, "shown once placed")
bar.w = 1100; REPEATS.derpy_mr_follow_bar(); eq(b.x, 1535, "follows the strip's end")
bar.y = -600; REPEATS.derpy_mr_follow_bar(); eq(b.x, 1535, "a strip sliding away is ignored")
eq(b.y, 2, "a strip sliding away leaves the button where it was")
bar.y = -40; REPEATS.derpy_mr_follow_bar(); eq(b.y, 0, "a strip just above the screen clamps the button onto it")
bar.y = -4
unlink(bar); eq(S.anchor(), nil, "no strip, no anchor"); REPEATS.derpy_mr_follow_bar()
eq(b.x, 1535, "and the button stays put"); bar.parent = UI_ROOT; UI_ROOT.kids[#UI_ROOT.kids + 1] = bar
local hub
for _, r in ipairs(DERPY_HUB_QUEUE) do if r.key == "mr" then hub = r end end
eq(hub.button, "derpy_mr_stores_button", "hub entry"); eq(hub.order, 4, "fourth in the column")
eq(hub.label(), "Stores", "hub label"); eq(hub.live(), true, "never greyed")
DERPY_HUB = { manages = function(k) return k == "mr" end }
bar.w = 1019; REPEATS.derpy_mr_follow_bar(); eq(b.x, 1535, "the hub owns its place"); DERPY_HUB = nil

-- open on the Goods tab
click("derpy_mr_stores_button")
local p = find("derpy_mr_stores_panel")
eq(p.visible, true, "open"); eq(p.interactive, true, "eats the mouse while open")
eq(p.x, 530, "centred across"); eq(p.y, 220, "centred down")
eq(find("title_text").text, "Stores", "title"); eq(find("hdr_2").text, "Held", "header")
for name, label in pairs({ derpy_mr_tab_goods = "Goods", derpy_mr_tab_settlements = "Settlements", derpy_mr_back = "Back" }) do
    local c = find(name); c:SetState("hover")
    eq(c:GetStateText(), label, name .. " keeps its label on hover"); c:SetState("standard")
    eq(c:GetStateText(), label, name .. " label")
end
eq(shown_rows(), 3, "three goods"); eq(cell(1, 1).text, "Coal", "first good")
eq(cell(1, 4).text, "300 / 600", "space"); eq(cell(3, 1).text, "Brimstone", "made, not held")
eq(find_uicomponent(find("derpy_mr_row_1"), "icon").image ~= nil, true, "icon set")
eq(find("derpy_mr_row_2").y - find("derpy_mr_row_1").y, 28, "row pitch")
eq(find("derpy_mr_back").visible, false, "no Back on a top view")
local SEL = "ui/skins/default/button_square_large_text_selected.png"
local OFF = "ui/skins/default/button_square_large_text_active.png"
local function lit(name) return (find(name).images or {})[0] end
eq(lit("derpy_mr_tab_goods"), SEL, "the open tab is lit")
eq(find("derpy_mr_tab_goods").images[1], "ui/skins/default/button_square_large_text_selected_hover.png", "and lit on hover")
eq(lit("derpy_mr_tab_settlements"), OFF, "the other is not")
eq(find("empty_text").visible, false, "no empty text over rows")
-- the list: rows_holder inside the clip, no slider for three rows; a scroll carries every row
eq(find_uicomponent(find("list_clip"), "rows_holder") ~= false, true, "rows inside the list")
eq(find("vslider").visible, false, "no slider for three rows")
local box, holder = find("list_box"), find("rows_holder")
box.y = box.y - 56; REPEATS.derpy_mr_stores_scroll()
eq(holder.y, box.y, "rows follow the list"); eq(find("derpy_mr_row_1").y, box.y, "row 1 with them")
-- drill into a good, then back
click("derpy_mr_row_1")
eq(find("sub_title").text, "Where Coal is kept", "drill-down title")
eq(find("rows_holder").y, 358, "a new list starts at the top")
eq(shown_rows(), 2, "two settlements keep coal"); eq(cell(1, 1).text, "Bravo", "most held first")
eq(find("derpy_mr_row_1").tip, S.FULL_TIP, "full tooltip"); eq(find("derpy_mr_back").visible, true, "Back shown")
click("derpy_mr_back"); eq(cell(1, 1).text, "Coal", "back to the goods")
-- the Settlements tab, then one settlement's stores
click("derpy_mr_tab_settlements"); eq(shown_rows(), 3, "three settlements")
eq(lit("derpy_mr_tab_settlements"), SEL, "the clicked tab is lit"); eq(lit("derpy_mr_tab_goods"), OFF, "the old one is not")
eq(cell(2, 5).text, "Coal 100%", "fullest store")
-- the goods each settlement keeps, as icons before its name: most made first, then most held
local function icon(i, j) return find_uicomponent(find("derpy_mr_row_" .. i), j == 1 and "icon" or "icon" .. j) end
local L0 = DERPY_MR_STORES_L
local function good_icon(stem) for _, g in ipairs(DERPY_MR_STORES_GOODS) do if g.stem == stem then return g.icon end end end
eq(icon(1, 1).image, good_icon("coal"), "Alpha's first icon: coal, made and held")
eq(icon(1, 2).image, good_icon("brimstone"), "then brimstone, made"); eq(icon(1, 2).visible, true, "shown")
eq(icon(1, 3).visible, false, "no third good, no third icon")
eq(icon(1, 2).x - icon(1, 1).x, L0.ICON_PITCH, "icons at the pitch")
eq(cell(1, 1).x, find("derpy_mr_row_1").x + L0.cols[1][1] + L0.ICON_PITCH, "the name moves past the icons")
eq(icon(3, 1).visible, false, "Charlie keeps nothing: no icon")
eq(cell(3, 1).x, cell(1, 1).x, "and its name lines up with the rest (seen ragged in game 2026-10-02)")
local alpha_cco = CCO["1"]
CCO["1"] = "derpy_mr_store_coal_stocked=6,derpy_mr_store_brimstone_stocked=9"
click("derpy_mr_tab_settlements")
eq(icon(1, 1).image, good_icon("brimstone"), "made more but held none: what it is FOR comes first")
CCO["1"] = alpha_cco; click("derpy_mr_tab_settlements")
click("derpy_mr_row_1"); eq(find("sub_title").text, "Stores of Alpha", "settlement drill-down")
eq(lit("derpy_mr_tab_settlements"), SEL, "a drill-down keeps its tab lit")
eq(cell(2, 3).text, "+6", "brimstone per turn")
click("derpy_mr_row_9"); eq(find("sub_title").text, "Stores of Alpha", "a row past the data does nothing")
-- turn start reads the realm again while the panel is open
click("derpy_mr_tab_settlements")
FACTIONS.fac_a = faction("fac_a", { A })
fire("FactionTurnStart", { faction = function() return FACTIONS.fac_a end })
eq(shown_rows(), 1, "turn start refreshed the open panel")
-- close, and the mouse goes through again
click("derpy_mr_close"); eq(p.visible, false, "closed"); eq(p.interactive, false, "lets the mouse through")
-- a big empire: every settlement drawn, a slider, keys where the loc has no name
local many = {}
for i = 1, 200 do many[i] = region("r" .. i, 100 + i, 1, 200, { coal = i }, "") end
FACTIONS.fac_many = faction("fac_many", many)
LOCAL = "fac_many"; click("derpy_mr_stores_button")
eq(find("hdr_1").text, "Settlement", "reopened on the Settlements tab")
eq(shown_rows(), 200, "every settlement drawn"); eq(find("vslider").visible, true, "a slider for 200 rows")
eq(cell(1, 1).text, "r1", "a region with no loc name shows its key")
eq(find("derpy_mr_row_200").y - find("derpy_mr_row_1").y, 199 * 28, "drawn whole, at the pitch")
eq(find("rows_holder").h, 200 * 28, "the holder is as tall as what it holds")
-- no settlements
click("derpy_mr_close"); LOCAL = "fac_empty"; click("derpy_mr_stores_button"); click("derpy_mr_tab_goods")
eq(shown_rows(), 0, "nothing listed"); eq(find("empty_text").visible, true, "says why")
eq(find("empty_text").text, S.NO_REALM, "no settlements")

-- ---- the history chart on a good's drill-down (flows spec section 7) ---------------------
local L = DERPY_MR_STORES_L
local HIST = { turns = {}, total = {}, last = {} }
DERPY_MR_FLOWS = {
    series = function(fk, stem)
        eq(fk, LOCAL, "the local faction's history"); eq(stem, "coal", "the focused good's")
        return HIST.turns, HIST.total
    end,
    last = function() return HIST.last end,
}
-- the model
eq(S.chart_model({}, {}, {}).chart_line, S.NO_HISTORY, "no turns: no history")
eq(S.chart_model({ 4 }, { 10 }, {}).bars, nil, "one turn draws no bars")
local c = S.chart_model({ 3, 4, 5 }, { 0, 50, 100 }, { made = 12, raided_out = 30, traded_in = 5 })
eq(#c.bars, 3, "a bar a turn"); eq(c.bars[1].h, L.BAR_MIN, "an empty turn keeps a sliver")
eq(c.bars[2].h, 60, "half the top is half the height"); eq(c.bars[3].h, 120, "the top fills the chart")
eq(c.bars[3].tip, "Turn 5: 100 held", "bar tooltip"); eq(c.chart_top, "100", "top value")
eq(c.chart_from, "Turn 3", "first turn"); eq(c.chart_to, "Turn 5", "last turn")
eq(c.chart_line, "Last turn: made +12, raided -30, traded in +5", "the last-turn line")
eq(S.chart_model({ 1, 2 }, { 0, 0 }, {}).bars[2].h, L.BAR_MIN, "all empty: slivers, no division by zero")
eq(S.last_line({}), "Last turn: no change", "a quiet turn")
eq(S.last_line({ plundered_in = 40, plundered_out = 10, traded_out = 3 }),
   "Last turn: plundered +30, traded out -3", "plunder is netted, trade out shown on its own")
-- 7px a character: gen_mr_ui.CHAR_W, the same flat estimate check_text_fits uses
local widest = S.last_line({ made = 123456, raided_out = 123456, plundered_out = 123456,
                             traded_in = 123456, traded_out = 123456 })
eq(#widest * 7 <= L.chart_line[3], true, "the widest last-turn line fits: " .. widest)
eq(#S.NO_HISTORY * 7 <= L.chart_line[3], true, "the no-history line fits")

-- on screen
local function bars_shown()
    local k = 0
    for i = 1, L.BARS do
        local bar = find("derpy_mr_bar_" .. i)
        if bar and bar.visible then k = k + 1 end
    end
    return k
end
click("derpy_mr_close"); LOCAL = "fac_a"
HIST.turns, HIST.total, HIST.last = { 3, 4, 5 }, { 0, 50, 100 }, { made = 12 }
click("derpy_mr_stores_button")
eq(find("hdr_1").text, "Good", "reopened on the Goods tab")
eq(bars_shown(), 0, "no bars on a top view"); eq(find("chart_line").visible, false, "no chart on a top view")
eq(find("derpy_mr_stores_list").h, L.ROWS * L.PITCH, "the full list on a top view")
click("derpy_mr_row_1")
eq(find("sub_title").text, "Where Coal is kept", "coal's drill-down")
eq(bars_shown(), 3, "three bars for three turns")
local pnl, b3 = find("derpy_mr_stores_panel"), find("derpy_mr_bar_3")
eq(b3.h, 120, "the top bar is full height")
eq(b3.y + b3.h, pnl.y + L.bars[2] + L.bars[4], "bars stand on one baseline")
eq(b3.x - find("derpy_mr_bar_2").x, L.BAR_PITCH, "bar pitch"); eq(b3.tip, "Turn 5: 100 held", "bar tooltip")
eq(find("chart_line").text, "Last turn: made +12", "the last-turn line")
eq(find("chart_line").visible, true, "shown"); eq(find("chart_to").text, "Turn 5", "the last turn's label")
eq(find("derpy_mr_stores_list").h, L.CHART_ROWS * L.PITCH, "the list shortens for the chart")
eq(find("vslider").maxValue, L.CHART_ROWS * L.PITCH - L.HANDLE_H, "and its slider with it")
HIST.turns, HIST.total = { 5 }, { 100 }
click("derpy_mr_back"); click("derpy_mr_row_1")
eq(bars_shown(), 0, "one turn: no bars"); eq(find("chart_line").text, S.NO_HISTORY, "and says why")
click("derpy_mr_back")
eq(find("chart_line").visible, false, "Back hides the chart")
eq(find("derpy_mr_stores_list").h, L.ROWS * L.PITCH, "and restores the full list")
click("derpy_mr_tab_settlements"); click("derpy_mr_row_1")
eq(bars_shown(), 0, "no chart on a settlement's stores")
DERPY_MR_FLOWS = nil
click("derpy_mr_tab_goods"); click("derpy_mr_row_1")
eq(find("chart_line").text, S.NO_HISTORY, "without the flows script: no history, no error")

-- ---- the Trade tab: every good, and a switch each way ----------------------------------
local STOP, SENT = {}, {}
DERPY_MR_FLOWS = {
    stopped = function(fk, dir, stem)
        eq(fk, LOCAL, "the local faction's switches"); return STOP[dir .. "|" .. stem] == true
    end,
    send = function(fk, dir, stem)
        SENT[#SENT + 1] = fk .. "|" .. dir .. "|" .. stem
        STOP[dir .. "|" .. stem] = not STOP[dir .. "|" .. stem]
    end,
    last = function(_, stem)
        if stem == "coal" then return { traded_out = 15, traded_in = 2 } end
        return {}
    end,
    series = function() return {}, {} end,
}
local function switch(i, dir) return find_uicomponent(find("derpy_mr_row_" .. i), "derpy_mr_sw_" .. dir) end
click("derpy_mr_close"); click("derpy_mr_stores_button"); click("derpy_mr_tab_trade")
eq(lit("derpy_mr_tab_trade"), SEL, "the Trade tab is lit"); eq(lit("derpy_mr_tab_goods"), OFF, "Goods is not")
local tt = find("derpy_mr_tab_trade"); tt:SetState("hover")
eq(tt:GetStateText(), "Trade", "Trade keeps its label on hover"); tt:SetState("standard")
eq(find("hdr_3").text, "Exports", "exports header"); eq(find("hdr_4").text, "Imports", "imports header")
eq(shown_rows(), #DERPY_MR_STORES_GOODS, "every good is listed, held or not")
eq(cell(1, 1).text, "Coal", "most held first"); eq(cell(1, 2).text, "100", "held (fac_a now holds Alpha alone)")
eq(cell(1, 3).text, "", "the switch, not the cell, carries the word")
eq(switch(1, "export").visible, true, "an export switch"); eq(switch(1, "export").text, "Allowed", "allowed by default")
eq(switch(1, "import").visible, true, "an import switch")
eq(switch(1, "export").x, find("derpy_mr_row_1").x + DERPY_MR_STORES_L.cols[3][1], "in the Exports column")
eq(cell(1, 5).text, "sent 15, received 2", "last turn's trade"); eq(cell(2, 5).text, "-", "no trade last turn")
-- GOODS YOU NEITHER HOLD NOR MAKE ARE GREYED, LAST: no export switch, but you can still refuse them
eq(cell(2, 1).text, "Brimstone", "a good you make but do not hold yet is not greyed")
eq(switch(2, "export").visible, true, "and can be exported")
eq(cell(3, 1).text, S.grey("Iron"), "the first good you neither hold nor make, greyed")
eq(cell(3, 2).text, S.grey("0"), "its count too")
eq(switch(3, "export").visible, false, "no export switch: there is nothing to send")
eq(switch(3, "import").visible, true, "an import switch: you can still refuse it")
eq(S.grey("x"), "[[col:ui_font_inactive_grey]]x[[/col]]", "CA's own inactive grey (ui_colours_tables)")
local brim = "pooled_resources_display_name_derpy_mr_store_brimstone"
LOC[brim] = "Zz Brimstone"; click("derpy_mr_tab_trade")
eq(cell(2, 1).text, "Zz Brimstone", "a good you make comes before every good you do not, whatever its name")
LOC[brim] = "Brimstone"; click("derpy_mr_tab_trade")
press(switch(1, "export"))
eq(SENT[1], "fac_a|export|coal", "a click sends the local faction's switch")
eq(switch(1, "export").text, S.STOPPED, "and the panel shows it at once")
eq(string.find(switch(1, "export").tip, "allow", 1, true) ~= nil, true, "the tooltip says a click allows it again")
press(switch(2, "import")); eq(SENT[2], "fac_a|import|brimstone", "the row's own good (then by name)")
press(find_uicomponent(find("derpy_mr_row_1"), "c3")); eq(#SENT, 2, "a cell named like ours elsewhere is not a switch")
click("derpy_mr_row_1"); eq(find("sub_title").text, "What your settlements trade", "a Trade row opens nothing")
click("derpy_mr_tab_goods")
eq(switch(1, "export").visible, false, "no switches off the Trade tab")
DERPY_MR_FLOWS = nil; click("derpy_mr_tab_trade")
eq(switch(1, "export").visible, false, "without the flows script: no switches"); eq(#ERRORS, 0, "and no error")

-- ---- the raid plate above a raiding army -----------------------------------------------
local function fits(tip)
    for line in string.gmatch(tip .. "\n", "(.-)\n") do
        eq(#line <= S.TIP_CHARS, true, "a tooltip line fits unwrapped: " .. line)
    end
end
LOC.regions_onscreen_reg_long = "Karak Eight Peaks of the Deep"      -- a long settlement name
local PREVIEW = {}
DERPY_MR_FLOWS = { raid_preview = function(ch) return PREVIEW[ch] end }
local p3d = new("3d_ui_parent", UI_ROOT)
local function army_label(id)
    local lab = new(id, p3d)
    local rh = new("raid_holder", new("icon_stance", new("stance_holder", new("list_parent", lab))))
    local gold = new("raid_value", rh); gold.images = { [1] = "icon_income_plus.png" }
    local labour = new("raid_value_labour", rh); labour.visible = false
    return rh
end
local rh = army_label("label_7")
army_label("label_8"); army_label("label_town_3")
local function char() return { is_null_interface = function() return false end } end
local ch7, ch8 = char(), char()
CHARS[7], CHARS[8] = ch7, ch8
-- prefix: the plates made under `holder`; shown: those visible
local function plates(holder, prefix, shown)
    local k = 0
    for _, c in ipairs(holder.kids) do
        if string.sub(c.name, 1, #prefix) == prefix and (not shown or c.visible) then k = k + 1 end
    end
    return k
end
REPEATS.derpy_mr_raid_plate()
eq(plates(rh, S.PLATE), 0, "no plate while the raid takes nothing")
PREVIEW[ch7] = { total = 10, parts = { { stem = "coal", n = 9 }, { stem = "iron", n = 1 } }, to = "reg_b" }
REPEATS.derpy_mr_raid_plate()
local plate, plate2 = find_uicomponent(rh, S.PLATE .. 1), find_uicomponent(rh, S.PLATE .. 2)
eq(plates(rh, S.PLATE), 2, "a value per good beside CA's raid values")
eq(plate.text, "9", "most first: coal's share"); eq(plate.images[1], good_icon("coal"), "with coal's own icon")
eq(plate2.text, "1", "then iron's"); eq(plate2.images[1], good_icon("iron"), "with iron's")
eq(plate.visible, true, "shown even when copied from a hidden plate")
eq(plate2.tip, plate.tip, "every value carries the whole list")
eq(string.find(plate.tip, "Coal 9", 1, true) ~= nil, true, "the tooltip lists each good")
eq(string.find(plate.tip, "Bravo", 1, true) ~= nil, true, "and where it goes")
PREVIEW[ch7].to = "reg_long"; REPEATS.derpy_mr_raid_plate(); fits(plate.tip)
PREVIEW[ch7].to = "reg_b"
REPEATS.derpy_mr_raid_plate(); eq(plates(rh, S.PLATE), 2, "made once, not once a poll")
PREVIEW[ch7].to = nil; REPEATS.derpy_mr_raid_plate()
eq(string.find(plate.tip, "no settlement", 1, true) ~= nil, true, "a horde's plate says the goods are lost")
fits(plate.tip)
PREVIEW[ch7] = nil; REPEATS.derpy_mr_raid_plate(); eq(plates(rh, S.PLATE, true), 0, "all hidden when the raid stops")
rh.visible = false; PREVIEW[ch7] = { total = 1, parts = { { stem = "coal", n = 1 } }, to = "reg_b" }
REPEATS.derpy_mr_raid_plate(); eq(plate.visible, false, "nothing drawn while CA hides the raid values")
rh.visible = true
local many_parts = {}
for i = 1, 14 do many_parts[i] = { stem = "coal", n = 1 } end
PREVIEW[ch7] = { total = 14, parts = many_parts, to = "reg_b" }
REPEATS.derpy_mr_raid_plate()
eq(string.find(plate.tip, "and 4 more", 1, true) ~= nil, true, "a long list is cut at ten")
eq(plates(rh, S.PLATE, true), S.PLATES, "at most PLATES values; the tooltip has the rest")
PREVIEW[ch7] = { total = 1, parts = { { stem = "coal", n = 1 } }, to = "reg_b" }
REPEATS.derpy_mr_raid_plate(); eq(plates(rh, S.PLATE, true), 1, "a value left from a longer list is hidden")
DERPY_MR_FLOWS = nil; REPEATS.derpy_mr_raid_plate(); eq(plate.visible, false, "without the flows script: no plate")

-- ---- the capture panel: Sack and Raze show the goods they take -------------------------
-- settlement_captured > button_parent > <option id> > frame > icon_parent > dy_income > icon,
-- read in game 2026-10-02; the ids are CA's culture_settlement_occupation_options rows.
eq(DERPY_MR_CAPTURE_KIND[1671725074], "sack", "the generated table knows the Chaos Dwarf sack")
eq(DERPY_MR_CAPTURE_KIND[1992765694], "raze", "and raze"); eq(DERPY_MR_CAPTURE_KIND[222165943], "occupy", "and occupy")
local sc = new("settlement_captured", UI_ROOT)
sc.ctx = { CcoCampaignSettlement = "reg_b" }
local bpar = new("button_parent", sc)
local function option(id)
    local ip = new("icon_parent", new("frame", new(id, bpar)))
    new("icon", new("dy_income", ip))
    return ip
end
local sack_ip, raze_ip, occ_ip = option("1671725074"), option("1992765694"), option("222165943")
local CALLS = {}
local CAP = { sack = { total = 50, parts = { { stem = "coal", n = 50 } }, lost = false },
              raze = { total = 3, parts = { { stem = "iron", n = 3 } }, lost = true },
              occupy = { total = 51, parts = { { stem = "coal", n = 51 } }, lost = false } }
DERPY_MR_FLOWS = { capture_preview = function(region, taker, kind)
    CALLS[#CALLS + 1] = region.key .. "|" .. tostring(taker and taker:name()) .. "|" .. kind
    return CAP[kind]
end }
REPEATS.derpy_mr_raid_plate()
local sg, rg = find_uicomponent(sack_ip, S.CAPTURE .. 1), find_uicomponent(raze_ip, S.CAPTURE .. 1)
eq(sg ~= false, true, "Sack gets a goods value"); eq(sg.text, "50", "the coal a sack takes")
eq(find_uicomponent(sg, "icon").images[0], good_icon("coal"), "with coal's own icon")
eq(find_uicomponent(rg, "icon").images[0], good_icon("iron"), "Raze's with iron's")
eq(string.find(sg.tip, "Coal 50", 1, true) ~= nil, true, "the tooltip lists each good")
eq(string.find(sg.tip, "Sacking", 1, true) ~= nil, true, "and names the choice")
eq(find_uicomponent(sg, "icon").tip, sg.tip, "the icon says the same")
eq(rg.text, "3", "Raze gets its own"); eq(string.find(rg.tip, "no settlement", 1, true) ~= nil, true, "a horde's goods are lost")
local og = find_uicomponent(occ_ip, S.CAPTURE .. 1)
eq(og.text, "51", "an occupy option shows the store it keeps")
eq(string.find(og.tip, "keeps", 1, true) ~= nil, true, "and says it is kept, not taken")
-- CA'S TOOLTIP WRAPS AT ABOUT 50 CHARACTERS (seen in game 2026-10-02: "into Zharr-" / "Naggrund:")
for _, t in ipairs({ sg.tip, rg.tip, og.tip }) do fits(t) end
eq(CALLS[1], "reg_b|fac_a|sack", "read for the panel's settlement and the local faction")
REPEATS.derpy_mr_raid_plate(); eq(#sack_ip.kids, 2, "made once, not once a poll")
CAP.sack = { total = 55, parts = { { stem = "coal", n = 50 }, { stem = "iron", n = 5 } }, lost = false }
REPEATS.derpy_mr_raid_plate(); eq(plates(sack_ip, S.CAPTURE, true), 2, "a value per good on a choice too")
eq(find_uicomponent(sack_ip, S.CAPTURE .. 2).text, "5", "iron's beside coal's")
CAP.sack = nil; REPEATS.derpy_mr_raid_plate(); eq(plates(sack_ip, S.CAPTURE, true), 0, "hidden when the sack takes nothing")
sc.visible = false; CALLS = {}; REPEATS.derpy_mr_raid_plate(); eq(#CALLS, 0, "nothing read while the panel is closed")
DERPY_MR_FLOWS = nil; sc.visible = true; REPEATS.derpy_mr_raid_plate(); eq(#ERRORS, 0, "without the flows script: no error")

eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))
print("harness ok")
