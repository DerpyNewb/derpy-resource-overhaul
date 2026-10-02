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
cm = {
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
function find_uicomponent(c, name)
    if not is_uicomponent(c) then return false end
    for _, k in ipairs(c.kids) do
        if k.name == name then return k end
        local d = find_uicomponent(k, name)
        if d then return d end
    end
    return false
end
function is_uicomponent(c) return type(c) == "table" and c.__uic == true end

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

eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))
print("harness ok")
