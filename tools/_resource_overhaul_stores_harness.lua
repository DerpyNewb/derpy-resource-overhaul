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
    -- one argument is an expression: the Map tab's CampaignRadarPosition, faked as RADAR below
    get_context_value = function(a, cqi, expr)
        if cqi == nil and expr == nil then return RADAR_EVAL(a) end
        return CCO[cqi]
    end,
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
BUNDLED = {}                 -- region key -> {bundle = true}: what region:has_effect_bundle answers
POS = {}                     -- region key -> {x, y}: the settlement's logical position (the Map tab)
CAMPAIGN = "some_mod_map"    -- cm:model():campaign_name_key(): a map with no known picture until set
-- THE ENGINE'S MINIMAP FRAME, faked: a display point's 0-1 place on the picture, from the left and
-- from the top, clamped as the engine's is. Deliberately NOT the logical frame - x and y scale
-- differently - so a map drawn from logical co-ordinates misses. RADAR_OFF: the engine says nothing.
RADAR, RADAR_CALLS, RADAR_OFF = { w = 2400, h = 1800 }, 0, false
function RADAR_EVAL(e)
    RADAR_CALLS = RADAR_CALLS + 1
    if RADAR_OFF then return nil end
    local dx, dy, axis = string.match(e, "^CampaignRadarPosition%(ToVector%(([%-%d%.e]+), 0, ([%-%d%.e]+), 0%)%)%.([xy])$")
    if not dx then return nil end
    local v = axis == "x" and tonumber(dx) / RADAR.w or 1 - tonumber(dy) / RADAR.h
    return math.max(0, math.min(1, v))
end
local function region(key, cqi, level, cap, pools, cco, extra)
    local items = {}
    for stem, v in pairs(pools or {}) do items[#items + 1] = pool("derpy_mr_store_" .. stem, v, cap) end
    for _, x in ipairs(extra or {}) do items[#items + 1] = x end
    CCO[tostring(cqi)] = cco
    local settlement = {
        is_null_interface = function() return false end,
        cqi = function() return cqi end,
        logical_position_x = function() return (POS[key] or { 0, 0 })[1] end,
        logical_position_y = function() return (POS[key] or { 0, 0 })[2] end,
        -- display co-ordinates are twice the logical ones here, as cm:log_to_dis below
        display_position_x = function() return 2 * (POS[key] or { 0, 0 })[1] end,
        display_position_y = function() return 2 * (POS[key] or { 0, 0 })[2] end,
        primary_slot = function() return { building = function()
            return { building_level = function() return level end } end } end,
    }
    return {
        is_null_interface = function() return false end,
        name = function() return key end,
        settlement = function() return settlement end,
        has_effect_bundle = function(_, b) return BUNDLED[key] ~= nil and BUNDLED[key][b] == true end,
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
WORLD = { A, B }             -- every settlement on the map: the Map tab reads its frame off the extremes
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
    model = function() return { campaign_name_key = function() return CAMPAIGN end,
        world = function() return { region_manager = function() return {
            region_list = function() return list(WORLD) end } end } end } end,
    -- the Spending tab's Show button: display co-ordinates are twice the logical ones here
    log_to_dis = function(_, x, y) return x * 2, y * 2 end,
    get_camera_position = function() return 0, 0, 15, 0.3, 12 end,
    scroll_camera_from_current = function(_, correct, t, pos)
        if correct ~= false or type(t) ~= "number" then error("scroll_camera_from_current: bad arguments") end
        CAMERA = pos
    end,
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
eq(v.rows[2][2], "1", "Bravo level")
-- USING (phase 4): the bundles a settlement's stores give, as icons; the row's tooltip names them
eq(v.heads[3], "Using", "the Using column"); eq(v.rows[2][3], "-", "Bravo uses nothing yet")
eq(#v.rows[2].using, 0, "no icons"); eq(v.rows[2].tip, "", "and no tooltip")
local WF, CF = DERPY_MR_STORES_BUNDLES[1], DERPY_MR_STORES_BUNDLES[3]
eq(WF.key, "derpy_mr_well_fed", "Well fed first"); eq(CF.key, "derpy_mr_comforts", "Comforts third")
LOC["effect_bundles_localised_title_derpy_mr_well_fed"] = "Well fed"
LOC["effect_bundles_localised_title_derpy_mr_comforts"] = "Comforts"
BUNDLED.reg_b = { derpy_mr_comforts = true, derpy_mr_well_fed = true }
realm = S.read_realm(FACTIONS.fac_a); v = S.view_model(realm)
eq(v.rows[2][3], "", "icons in place of the dash"); eq(#v.rows[2].using, 2, "two in use")
eq(v.rows[2].using[1], WF.icon, "in the bundles' own order: Well fed"); eq(v.rows[2].using[2], CF.icon, "then Comforts")
eq(v.rows[2].tip, "Using: Well fed, Comforts", "the tooltip names them")
eq(v.rows[1].tip, "", "Alpha uses nothing")
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
local function build(node, parent, name, file)
    local c = new(name or node.name, parent)
    c.xid, c.file = node.name, file                -- which XML component it is, for MR_DUMP
    for _, k in ipairs(node.kids) do build(k, c, nil, file) end
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
function UIC:CreateComponent(name, path) return build(template(path), self, name, path:match("([^/]+)$")) end
function UIC:Id() return self.name end
function UIC:Address() return self end
function UIC:MoveTo(x, y) self.moved = true; shift(self, x - self.x, y - self.y) end
function UIC:Position() return self.x, self.y end
function UIC:Dimensions() return self.w, self.h end
function UIC:Resize(w, h) self.w, self.h, self.sized = w, h, true end
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
function UIC:SetTextHAlign(a) self.halign = a end
-- not the panel's own 6.5 a letter, so a name spaced by that budget instead of measured shows up
function UIC:WidthOfTextLine(t) return math.ceil(string.len(t or "") * 7.25) end
function UIC:SetOpacity(o) self.opacity = o end
function UIC:SetDisabled(v) self.disabled = v end
function UIC:IsDragged() return self.dragged == true end
function UIC:ShaderTechniqueSet(t) self.shader = t end
function UIC:ShaderVarsSet(a, b, c, d) self.vars = { a, b, c, d } end
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

-- MR_DUMP (tools/preview_resource_vault.py): every component the panel shows, in drawing order,
-- written where a tab has its most telling contents. A size the script never set is "nil": the
-- preview takes the XML's.
local DUMP = os.getenv("MR_DUMP")
local function dump(tag)
    if not DUMP then return end
    local f = assert(io.open(DUMP .. "/" .. tag .. ".tsv", "w"))
    local function clean(s) return (tostring(s or ""):gsub("[\t\r\n]", " ")) end
    local function walk(c, depth)
        if not c.visible then return end
        f:write(table.concat({ depth, c.file or "", c.xid or "", c.name, c.x, c.y,
                               c.sized and c.w or "nil", c.sized and c.h or "nil", clean(c.text),
                               clean((c.images or {})[0]), clean(c.tip), c.parent and c.parent.name or "",
                               c.halign or "" },
                             "\t"), "\n")
        for _, k in ipairs(c.kids) do walk(k, depth + 1) end
    end
    walk(find("derpy_mr_stores_panel"), 0)
    f:close()
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
eq(hub.label(), "Resource Vault", "hub label"); eq(hub.live(), true, "never greyed")
DERPY_HUB = { manages = function(k) return k == "mr" end }
bar.w = 1019; REPEATS.derpy_mr_follow_bar(); eq(b.x, 1535, "the hub owns its place"); DERPY_HUB = nil

-- open on the Goods tab
click("derpy_mr_stores_button")
local p = find("derpy_mr_stores_panel")
eq(p.visible, true, "open"); eq(p.interactive, true, "eats the mouse while open")
eq(p.x, 530, "centred across"); eq(p.y, 220, "centred down")
eq(find("title_text").text, "Resource Vault", "title"); eq(find("hdr_2").text, "Held", "header")
-- A RULE BETWEEN THE TITLE AND THE TABS (asked for 2026-10-02), with room each side
local rule, ttl, tg = find("title_rule"), find("title_text"), find("derpy_mr_tab_goods")
eq(rule.visible, true, "a rule under the title")
eq(rule.y >= ttl.y + ttl.h + 2, true, "clear of the title"); eq(tg.y >= rule.y + rule.h + 6, true, "and of the tabs")
for name, label in pairs({ derpy_mr_tab_goods = "Resources", derpy_mr_tab_settlements = "Settlements", derpy_mr_back = "Back" }) do
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
dump("goods")
-- the list: rows_holder inside the clip, no slider for three rows; a scroll carries every row
eq(find_uicomponent(find("list_clip"), "rows_holder") ~= false, true, "rows inside the list")
eq(find("vslider").visible, false, "no slider for three rows")
local box, holder = find("list_box"), find("rows_holder")
box.y = box.y - 56; REPEATS.derpy_mr_stores_scroll()
eq(holder.y, box.y, "rows follow the list"); eq(find("derpy_mr_row_1").y, box.y, "row 1 with them")
-- drill into a good, then back
click("derpy_mr_row_1")
eq(find("sub_title").text, "Where Coal is kept", "drill-down title")
eq(find_uicomponent(find("derpy_mr_row_1"), "vline3").visible, true, "a line before a column with a header")
eq(find_uicomponent(find("derpy_mr_row_1"), "vline4").visible, false, "none before a column without one")
eq(find("hdr_line_5").visible, false, "nor in its header")
eq(find("rows_holder").y, 220 + DERPY_MR_STORES_L.list[2], "a new list starts at the top")
eq(shown_rows(), 2, "two settlements keep coal"); eq(cell(1, 1).text, "Bravo", "most held first")
eq(find("derpy_mr_row_1").tip, S.FULL_TIP, "full tooltip"); eq(find("derpy_mr_back").visible, true, "Back shown")
click("derpy_mr_back"); eq(cell(1, 1).text, "Coal", "back to the goods")
-- the Settlements tab, then one settlement's stores
click("derpy_mr_tab_settlements"); eq(shown_rows(), 3, "three settlements")
dump("settlements")
eq(lit("derpy_mr_tab_settlements"), SEL, "the clicked tab is lit"); eq(lit("derpy_mr_tab_goods"), OFF, "the old one is not")
eq(cell(2, 5).text, "Coal 100%", "fullest store")
-- the goods each settlement keeps, as icons before its name: most made first, then most held
local function icon(i, j) return find_uicomponent(find("derpy_mr_row_" .. i), j == 1 and "icon" or "icon" .. j) end
local L0 = DERPY_MR_STORES_L
local function good_icon(stem) for _, g in ipairs(DERPY_MR_STORES_GOODS) do if g.stem == stem then return g.icon end end end
-- WHICH GOODS A USE IS (author, 2026-10-07: "no icon for materials on what resource that is"): a
-- tooltip that prices a use names every good of it, each after its icon, and no other good
-- a rare good never pays as its use (flows.lua F.bulk), so every list leaves them out
local function names_use(tip, use, what)
    local n = 0
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do
        local has = string.find(tip, "[[img:" .. g.icon .. "]][[/img]] " .. S.name(g.stem), 1, true) ~= nil
        local want = g.use == use and not g.rare
        eq(has, want, what .. (want and " names " or " leaves out ") .. g.stem)
        if want then n = n + 1 end
    end
    eq(n >= 3, true, what .. ": the goods carry their use")
end
eq(icon(1, 1).image, good_icon("coal"), "Alpha's first icon: coal, made and held")
eq(icon(1, 2).image, good_icon("brimstone"), "then brimstone, made"); eq(icon(1, 2).visible, true, "shown")
eq(icon(1, 3).visible, false, "no third good, no third icon")
eq(icon(1, 2).x - icon(1, 1).x, L0.ICON_PITCH, "icons at the pitch")
eq(cell(1, 1).x, find("derpy_mr_row_1").x + L0.VIEWS.settlements[1][1] + L0.ICON_PITCH, "the name moves past the icons")
eq(icon(3, 1).visible, false, "Charlie keeps nothing: no icon")
local function use(i, k) return find_uicomponent(find("derpy_mr_row_" .. i), "use" .. k) end
eq(find("hdr_3").text, "Using", "the Using header")
eq(use(2, 1).visible, true, "Bravo's first bundle shown"); eq(use(2, 1).image, WF.icon, "Well fed's icon")
eq(use(2, 1).x, find("derpy_mr_row_2").x + L0.VIEWS.settlements[3][1], "at the Using column")
eq(use(2, 2).image, CF.icon, "then Comforts"); eq(use(2, 2).x - use(2, 1).x, L0.ICON_PITCH, "at the pitch")
eq(use(2, 3).visible, false, "no third"); eq(use(1, 1).visible, false, "Alpha uses nothing")
eq(find("derpy_mr_row_2").tip, "Using: Well fed, Comforts", "the row's tooltip names them")
eq(L0.VIEWS.settlements[3][2] >= 3 * L0.ICON_PITCH, true, "three icons fit the column")
eq(cell(3, 1).x, cell(1, 1).x, "and its name lines up with the rest (seen ragged in game 2026-10-02)")
local alpha_cco = CCO["1"]
CCO["1"] = "derpy_mr_store_coal_stocked=6,derpy_mr_store_brimstone_stocked=9"
click("derpy_mr_tab_settlements")
eq(icon(1, 1).image, good_icon("brimstone"), "made more but held none: what it is FOR comes first")
CCO["1"] = alpha_cco; click("derpy_mr_tab_settlements")
click("derpy_mr_row_1"); eq(find("sub_title").text, "Stores of Alpha", "settlement drill-down")
eq(use(2, 1).visible, false, "no Using icons on a drill-down")
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
-- THE EXCHANGE'S SLIDER (asked 2026-10-04): CA's caps and arrows at each end, outside the track
do
    local L = DERPY_MR_STORES_L
    local vs, lst = find("vslider"), find("derpy_mr_stores_list")
    eq(vs.y, lst.y + L.SLIDER_CAP, "the track starts under the top cap")
    eq(vs.y + vs.h, lst.y + lst.h - L.SLIDER_CAP, "and ends over the bottom one")
    eq(vs.x + vs.w, lst.x + lst.w, "at the list's right edge")
    for _, part in ipairs(L.SLIDER_PARTS) do
        local c = find_uicomponent(vs, part[1])
        local base = (part[1] == "frame_bottom" or part[1] == "bottom") and vs.y + vs.h or vs.y
        eq(c ~= false and c.x == vs.x + part[2] and c.y == base + part[3], true, part[1] .. " in CA's place")
    end
    eq(vs.maxValue, vs.h - L.HANDLE_H, "the travel is the track less the handle")
end
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
eq(c.bars[3].tip, "Start of turn 5: 100 held", "bar tooltip"); eq(c.chart_top, "100", "top value")
eq(c.chart_from, "Turn 3", "first turn"); eq(c.chart_to, "Turn 5", "last turn")
eq(c.chart_line, "Last turn: made +12, raided -30, traded in +5", "the last-turn line")
eq(S.chart_model({ 1, 2 }, { 0, 0 }, {}).bars[2].h, L.BAR_MIN, "all empty: slivers, no division by zero")
eq(S.last_line({}), "Last turn: no change", "a quiet turn")
eq(S.last_line({ plundered_in = 40, plundered_out = 10, traded_out = 3 }),
   "Last turn: plundered +30, traded out -3", "plunder is netted, trade out shown on its own")
eq(S.last_line({ made = 4, eaten_out = 6 }), "Last turn: made +4, eaten -6", "what the settlements ate")
-- 7px a character: gen_mr_ui.CHAR_W, the same flat estimate check_text_fits uses
eq(S.last_line({ moved_in = 10, moved_out = 12, spent_out = 200, sold_out = 120 }),
   "Last turn: moved -2, spent -200, sold -120", "moving is netted (the loss), spending and selling shown")
local busy = S.last_line({ made = 1234, raided_out = 1234, traded_in = 1234, traded_out = 1234,
                           eaten_out = 1234, sold_out = 1234 })
eq(#busy * 7 <= L.chart_line[3], true, "a busy turn's line fits: " .. busy)
local widest = S.last_line({ made = 123456, raided_out = 123456, plundered_out = 123456,
                             traded_in = 123456, traded_out = 123456, eaten_out = 123456 })
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
eq(find("hdr_1").text, "Resource", "reopened on the Resources tab")
eq(bars_shown(), 0, "no bars on a top view"); eq(find("chart_line").visible, false, "no chart on a top view")
eq(find("derpy_mr_stores_list").h, L.ROWS * L.PITCH, "the full list on a top view")
click("derpy_mr_row_1")
eq(find("sub_title").text, "Where Coal is kept", "coal's drill-down")
eq(bars_shown(), 3, "three bars for three turns")
local pnl, b3 = find("derpy_mr_stores_panel"), find("derpy_mr_bar_3")
eq(b3.h, 120, "the top bar is full height")
eq(b3.y + b3.h, pnl.y + L.bars[2] + L.bars[4], "bars stand on one baseline")
eq(b3.x - find("derpy_mr_bar_2").x, L.BAR_PITCH, "bar pitch"); eq(b3.tip, "Start of turn 5: 100 held", "bar tooltip")
eq(find("chart_line").text, "Last turn: made +12", "the last-turn line")
eq(find("chart_line").visible, true, "shown"); eq(find("chart_to").text, "Turn 5", "the last turn's label")
-- THE NEWEST TURN OVER "Turn N" (polish 2026-10-04): the bars stand at the right, the first
-- turn's name under the first bar, a baseline under them all
do
    local to, from, base, b1 = find("chart_to"), find("chart_from"), find("chart_base"), find("derpy_mr_bar_1")
    eq(b3.x + b3.w, pnl.x + L.bars[1] + L.bars[3], "the newest bar ends where the chart does")
    eq(to.x + to.w, b3.x + b3.w, "under it, Turn 5 ends with it")
    eq(from.x, b1.x, "Turn 3 starts under the first bar")
    eq(from.visible, true, "three turns: Turn 3 is named")
    eq(from.x + #from.text * L.HEAD_CHAR_W < to.x + to.w - #to.text * L.HEAD_CHAR_W, true, "clear of Turn 5")
    eq(base.visible, true, "a baseline"); eq(base.y, b3.y + b3.h, "right under the bars")
    eq(base.x <= b1.x and base.x + base.w >= b3.x + b3.w, true, "under every bar")
    local grid = find("chart_grid")
    eq(grid.visible, true, "a line at the top value"); eq(grid.y, b3.y, "level with the tallest bar's top")
end
dump("goods_focus")
HIST.turns, HIST.total = { 4, 5 }, { 50, 100 }
click("derpy_mr_back"); click("derpy_mr_row_1")
eq(bars_shown(), 2, "two turns, two bars"); eq(find("chart_from").visible, false, "Turn 4 would meet Turn 5: left off")
eq(find("derpy_mr_bar_2").x + find("derpy_mr_bar_2").w, find("chart_to").x + find("chart_to").w, "the newest still over Turn 5")
HIST.turns, HIST.total = { 3, 4, 5 }, { 0, 50, 100 }
click("derpy_mr_back"); click("derpy_mr_row_1")
eq(find("derpy_mr_stores_list").h, L.CHART_ROWS * L.PITCH, "the list shortens for the chart")
eq(find("vslider").maxValue, L.CHART_ROWS * L.PITCH - 2 * L.SLIDER_CAP - L.HANDLE_H, "and its slider with it")
HIST.turns, HIST.total = { 5 }, { 100 }
click("derpy_mr_back"); click("derpy_mr_row_1")
eq(bars_shown(), 0, "one turn: no bars"); eq(find("chart_line").text, S.NO_HISTORY, "and says why")
eq(find("chart_base").visible or find("chart_grid").visible, false, "and no chart lines")
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
        if stem == "all_stop" or stem == "all_allow" then
            for _, g in ipairs(DERPY_MR_STORES_GOODS) do STOP[dir .. "|" .. g.stem] = stem == "all_stop" end
        else
            STOP[dir .. "|" .. stem] = not STOP[dir .. "|" .. stem]
        end
    end,
    last = function(_, stem)
        if stem == "coal" then return { traded_out = 15, traded_in = 2 } end
        return {}
    end,
    series = function() return {}, {} end,
    ALL_STOP = "all_stop", ALL_ALLOW = "all_allow",     -- as flows.lua's F.ALL_STOP / F.ALL_ALLOW
}
local function switch(i, dir) return find_uicomponent(find("derpy_mr_row_" .. i), "derpy_mr_sw_" .. dir) end
click("derpy_mr_close"); click("derpy_mr_stores_button"); click("derpy_mr_tab_trade")
eq(lit("derpy_mr_tab_trade"), SEL, "the Trade tab is lit"); eq(lit("derpy_mr_tab_goods"), OFF, "Goods is not")
dump("trade")
local tt = find("derpy_mr_tab_trade"); tt:SetState("hover")
eq(tt:GetStateText(), "Trade", "Trade keeps its label on hover"); tt:SetState("standard")
eq(find("hdr_3").text, "Exports", "exports header"); eq(find("hdr_4").text, "Imports", "imports header")
local LL = DERPY_MR_STORES_L
local TC = LL.VIEWS.trade
local pnl0 = find("derpy_mr_stores_panel")
-- EACH TAB HAS ITS OWN COLUMNS (approved design 2026-10-02): sized to what they hold, aligned to it
eq(find("hdr_3").x, pnl0.x + LL.list[1] + TC[3][1], "the Exports header sits on the Trade tab's own column")
eq(find("hdr_3").halign, "centre", "a tick column's header is centred"); eq(find("hdr_5").halign, "left", "Last turn reads left")
eq(cell(1, 5).halign, "left", "and so does its cell"); eq(cell(1, 2).halign, "right", "numbers stay right")
eq(cell(1, 1).w, TC[1][2], "a cell takes its tab's width")
-- the section row: your goods, then a band naming the rest
eq(shown_rows(), #DERPY_MR_STORES_GOODS + 1, "every good is listed, held or not, and one section row")
eq(cell(1, 1).text, "Coal", "most held first"); eq(cell(1, 2).text, "100", "held (fac_a now holds Alpha alone)")
eq(cell(2, 1).text, "Brimstone", "a good you make but do not hold yet is not greyed")
local others = #DERPY_MR_STORES_GOODS - 2
eq(cell(3, 1).text, S.section("Resources you do not have (" .. others .. ")"), "a section row before the rest")
eq(find_uicomponent(find("derpy_mr_row_3"), "section_band").visible, true, "on its own band")
eq(switch(3, "import").visible, false, "with no switches"); eq(find_uicomponent(find("derpy_mr_row_3"), "icon").visible, false, "no icon")
eq(find_uicomponent(find("derpy_mr_row_3"), "vline3").visible, false, "and no column lines")
eq(find_uicomponent(find("derpy_mr_row_1"), "section_band").visible, false, "a good's row has no section band")
-- rows banded in turn, so a wide row is easy to follow across
eq(find_uicomponent(find("derpy_mr_row_1"), "band").visible, false, "row 1 plain")
eq(find_uicomponent(find("derpy_mr_row_2"), "band").visible, true, "row 2 banded")
-- CHECKBOXES, CA's own art: ticked is allowed, empty is stopped; the word is in the tooltip
eq(switch(1, "export").visible, true, "an export box"); eq(switch(1, "import").visible, true, "an import box")
eq(switch(1, "export").images[0], S.CHECK[true][1], "ticked: allowed by default")
eq(switch(1, "export").images[1], S.CHECK[true][2], "and ticked on hover")
eq(switch(1, "export").x, find("derpy_mr_row_1").x + TC[3][1] + math.floor((TC[3][2] - LL.CHECK) / 2),
   "centred in its column, under its centred header")
eq(switch(1, "export").opacity, 255, "your goods' boxes at full strength")
-- GOODS YOU NEITHER HOLD NOR MAKE ARE GREYED, LAST: no export box, a dimmed import box
eq(cell(4, 1).text, S.grey("Iron"), "the first good you neither hold nor make, greyed")
eq(cell(4, 2).text, S.grey("0"), "its count too")
eq(switch(4, "export").visible, false, "no export box: there is nothing to send")
eq(switch(4, "import").visible, true, "an import box: you can still refuse it")
eq(switch(4, "import").opacity < 255, true, "greyed with its row")
eq(S.grey("x"), "[[col:ui_font_inactive_grey]]x[[/col]]", "CA's own inactive grey (ui_colours_tables)")
-- COLUMN LINES: one in each gap from the second column, through the header and every row
for j = 2, 5 do
    local vl = find_uicomponent(find("derpy_mr_row_1"), "vline" .. j)
    local gap = math.floor((TC[j - 1][1] + TC[j - 1][2] + TC[j][1]) / 2)
    eq(vl.visible, true, "a column line before column " .. j)
    eq(vl.x, find("derpy_mr_row_1").x + gap, "in the middle of the gap")
    eq(find("hdr_line_" .. j).visible, true, "and through the header")
    eq(find("hdr_line_" .. j).x, vl.x, "lined up with the rows'")
end
eq(cell(1, 5).text, "sent 15, received 2", "last turn's trade"); eq(cell(2, 5).text, "-", "no trade last turn")
local brim = "pooled_resources_display_name_derpy_mr_store_brimstone"
LOC[brim] = "Zz Brimstone"; click("derpy_mr_tab_trade")
eq(cell(2, 1).text, "Zz Brimstone", "a good you make comes before every good you do not, whatever its name")
LOC[brim] = "Brimstone"; click("derpy_mr_tab_trade")
press(switch(1, "export"))
eq(SENT[1], "fac_a|export|coal", "a click sends the local faction's switch")
eq(switch(1, "export").images[0], S.CHECK[false][1], "and the box empties at once")
eq(string.find(switch(1, "export").tip, "allow", 1, true) ~= nil, true, "the tooltip says a click allows it again")
press(switch(2, "import")); eq(SENT[2], "fac_a|import|brimstone", "the row's own good (then by name)")
press(find_uicomponent(find("derpy_mr_row_1"), "c3")); eq(#SENT, 2, "a cell named like ours elsewhere is not a switch")
-- a greyed row's name cell carries grey markup; its switch's tooltip names the good plainly
eq(string.find(cell(4, 1).text, "[[col:", 1, true) ~= nil, true, "row 4 is a greyed good")
eq(string.find(switch(4, "import").tip, "[[col:", 1, true), nil, "its Imports tooltip carries no colour markup")
click("derpy_mr_row_1"); eq(find("sub_title").text, "What your settlements trade", "a Trade row opens nothing")
-- THE SECTION ROW FOLDS: a click hides the resources you do not have, another shows them again
eq(find("derpy_mr_row_3").tip, S.FOLD_TIP[false], "the section row says a click hides them")
click("derpy_mr_row_3"); eq(shown_rows(), 3, "folded: your two resources and the section row")
eq(cell(3, 1).text, S.section("Resources you do not have (" .. others .. ")" .. S.FOLDED), "and it says so")
eq(find("derpy_mr_row_3").tip, S.FOLD_TIP[true], "and that a click shows them")
click("derpy_mr_close"); click("derpy_mr_stores_button"); eq(shown_rows(), 3, "kept folded while the campaign runs")
click("derpy_mr_row_3"); eq(shown_rows(), #DERPY_MR_STORES_GOODS + 1, "unfolded again")
do
    -- IMPORT DUTY: a first row with last turn's gold each way, its partners in the tooltip
    local fl = DERPY_MR_FLOWS
    local pct, stores = 12, true                -- not the default 10: the tooltip must carry the rate
    fl.rates = function() return { duty = pct } end
    fl.uses_stores = function(f) eq(f:name(), LOCAL, "asked of the local faction"); return stores end
    fl.duty_last = function(fk)
        eq(fk, LOCAL, "the local faction's duty"); return { paid = 11, got = 4, by = { fac_b = { paid = 11, got = 4 } } }
    end
    click("derpy_mr_tab_trade")
    dump("trade")   -- the preview draws the tab with its duty row (overwrites the plain dump)
    eq(cell(1, 1).text, "Import duty", "the duty row comes first"); eq(cell(1, 5).text, "paid 11, received 4", "both ways")
    eq(string.find(find("derpy_mr_row_1").tip, ": paid 11, received 4", 1, true) ~= nil, true, "each partner in its tooltip")
    eq(string.find(find("derpy_mr_row_1").tip, "12%", 1, true) ~= nil, true, "with the rate")
    eq(switch(1, "export").visible or switch(1, "import").visible, false, "and no switches")
    eq(cell(2, 1).text, "Coal", "the goods follow")
    fl.duty_last = function() return nil end; click("derpy_mr_tab_trade")
    eq(cell(1, 5).text, "paid 0, received 0", "nothing booked yet reads as nothing")
    stores = false; click("derpy_mr_tab_trade"); eq(cell(1, 1).text, "Coal", "no row for a faction that never pays it")
    stores, pct = true, 0; click("derpy_mr_tab_trade"); eq(cell(1, 1).text, "Coal", "no row while the duty is off")
    fl.rates, fl.duty_last, fl.uses_stores = nil, nil, nil; click("derpy_mr_tab_trade")
end
-- ALL AT ONCE: four buttons under the list, on the Trade tab only
local function bulk(dir, mode) return find("derpy_mr_all_" .. dir .. "_" .. mode) end
for _, dm in ipairs({ { "export", "allow" }, { "export", "stop" }, { "import", "allow" }, { "import", "stop" } }) do
    local bt = bulk(dm[1], dm[2])
    eq(bt.visible, true, "a button to " .. dm[2] .. " every " .. dm[1])
    eq(bt.y, pnl0.y + LL.bulk[2], "on the bottom line")
    bt:SetState("hover"); eq(bt:GetStateText() ~= "", true, "labelled on hover"); bt:SetState("standard")
end
eq(bulk("export", "stop").text, "Stop all exports", "plain label")
eq(bulk("export", "stop").x < bulk("import", "allow").x, true, "exports left of imports")
-- THE HINT SHARES THE SUB-TITLE'S LINE, at its right end, so the bottom line is the buttons' alone
eq(find("hint_text").y, find("sub_title").y, "the hint is on the sub-title's line")
eq(find("hint_text").halign, "right", "at its right end")
eq(bulk("import", "stop").x + bulk("import", "stop").w <= pnl0.x + LL.W - 20, true, "the last button inside the margin")
SENT = {}
press(bulk("export", "stop")); eq(SENT[1], "fac_a|export|all_stop", "stop all exports, in one message")
eq(switch(1, "export").images[0], S.CHECK[false][1], "every export box empties at once")
eq(switch(2, "export").images[0], S.CHECK[false][1], "the second too")
eq(switch(1, "import").images[0], S.CHECK[true][1], "the imports untouched")
press(bulk("export", "allow")); eq(SENT[2], "fac_a|export|all_allow", "allow all exports")
eq(switch(1, "export").images[0], S.CHECK[true][1], "ticked again")
-- EVERY HEADER FITS ITS COLUMN, on every tab: a header that did not was shrunk by the engine
-- (seen in game 2026-10-02: "Space per good" in 100px). HEAD_CHAR_W is calibrated from that.
local saved_view, saved_focus = S.view, S.focus
local alpha_realm = S.read_realm(FACTIONS.fac_a)
for _, vf in ipairs({ { "goods" }, { "goods", "coal" }, { "settlements" }, { "settlements", "reg_a" }, { "trade" },
                     { "spending" }, { "map" } }) do
    S.view, S.focus = vf[1], vf[2]
    local v = S.view_model(alpha_realm)
    -- the sub-title and the hint share one line: together they must fit it
    eq((#v.title + #(v.hint or "")) * 7 + 16 <= LL.sub_title[3], true, "title and hint fit one line on " .. vf[1])
    for j, h in ipairs(v.heads) do
        eq(#h * LL.HEAD_CHAR_W <= v.cols[j][2], true, "header '" .. h .. "' fits its column on " .. vf[1])
    end
end
S.view, S.focus = saved_view, saved_focus
click("derpy_mr_tab_goods")
eq(switch(1, "export").visible, false, "no switches off the Trade tab")
eq(bulk("export", "stop").visible, false, "and no all-at-once buttons")
eq(find("hdr_3").halign, "right", "and the Goods tab's own alignment back")
DERPY_MR_FLOWS = nil; click("derpy_mr_tab_trade")
eq(switch(1, "export").visible, false, "without the flows script: no switches"); eq(#ERRORS, 0, "and no error")
eq(bulk("import", "allow").visible, false, "nor all-at-once buttons")

-- ---- phase 7: the panel's actions ------------------------------------------------------
local REQ, PLAN, ORDER_ST, SALE, ACT_ON = {}, {}, {}, nil, true
local SUP_ON, SUPPLY_ST, SHIPS_TO, SHIP_N = true, nil, {}, 0
CAPS, SHIPS = {}, {}
DERPY_MR_FLOWS = {
    capitals = function(f) eq(f:name(), LOCAL, "the local faction's capitals"); return CAPS end,
    ships = function() return SHIPS end,
    rates = function() return { actions = ACT_ON, supply = SUP_ON } end,
    SHIP = { turns = 2 },
    ship_count = function(fk) eq(fk, LOCAL, "the local faction's shipments"); return SHIP_N end,
    ship_cap = function(f) eq(f:name(), LOCAL, "the local faction's number"); return 3 end,
    ships_to = function(_fk, rk, stem) return (rk == "reg_a" and SHIPS_TO[stem]) or {} end,
    supply_state = function(_f, rk) if rk == "reg_a" then return SUPPLY_ST end return nil end,
    request = function(fk, ...) REQ[#REQ + 1] = fk .. "|" .. table.concat({ ... }, "|") end,
    send_plan = function(f, _rk, stem) eq(f:name(), LOCAL, "the local faction's plan"); return PLAN[stem] end,
    order_state = function(_, key) return ORDER_ST[key] end,
    sale = function() return SALE end,
    series = function() return {}, {} end,
    last = function() return {} end,
}
local function act(name) return find(name) end
local function slot(i) return pnl0.x + LL.bulk[1] + (i - 1) * (LL.bulk[3] + LL.BULK_GAP) end
-- SEND HERE, on a settlement's drill-down: every row has one; one that cannot send is greyed and says why
PLAN.coal = { from = B, n = 12, got = 10 }
click("derpy_mr_tab_settlements"); click("derpy_mr_row_1")
eq(find("sub_title").text, "Stores of Alpha", "Alpha's stores")
local function sendb(i) return find_uicomponent(find("derpy_mr_row_" .. i), "derpy_mr_sendhere") end
eq(sendb(1).visible, true, "a Send here button"); eq(sendb(1).text, "Send here", "labelled")
dump("settlement_focus")
eq(sendb(1).x, find("derpy_mr_row_1").x + LL.VIEWS.focus[5][1], "in the fifth column")
eq(sendb(1).disabled, false, "live when something can come"); eq(sendb(1).shader, "normal_t0", "and drawn live")
eq(sendb(1).tip, "Ship 12 Coal from Bravo: 10 arrive in 2 turns, 2 are lost on the way. An army at war "
   .. "with you can seize it on the road.", "the tooltip says what happens")
eq(sendb(2).disabled, true, "Brimstone: nobody can send it"); eq(sendb(2).shader, "set_greyscale_t0", "and it looks it")
eq(sendb(2).tip, "No other settlement of yours can send Brimstone.", "the tooltip says why")
eq(S.send_tip(nil, { name = "Coal", full = true }), "This store of Coal is full.", "a full store says so")
press(sendb(1)); eq(REQ[1], "fac_a|send|coal|reg_a", "a click asks for this resource into this settlement")
press(sendb(2)); eq(#REQ, 1, "a greyed button asks for nothing")
-- SHIPMENTS (phase 5): the most on the road greys every Send here, and what is coming is listed
PLAN.coal.busy = true; SHIPS_TO.coal = { { n = 34, due = 52 }, { n = 5, due = 53 } }
click("derpy_mr_back"); click("derpy_mr_row_1")
eq(sendb(1).disabled, true, "the most shipments on the road: greyed")
eq(sendb(1).tip, "You have 3 shipments on the road already, the most you can have.\nOn the road here: 34, "
   .. "arriving on turn 52.\nOn the road here: 5, arriving on turn 53.", "says why, and what is coming")
press(sendb(1)); eq(#REQ, 1, "and asks for nothing")
PLAN.coal.busy, SHIPS_TO.coal = nil, nil
-- what is on the road fills the store: that is why nothing more can be sent, not a lack of senders
PLAN.coal, SHIPS_TO.coal = nil, { { n = 300, due = 60 } }
click("derpy_mr_back"); click("derpy_mr_row_1")
eq(string.find(sendb(1).tip, "What is already on the road will fill this store of Coal.", 1, true), 1,
   "says the road fills it")
PLAN.coal, SHIPS_TO.coal = { from = B, n = 12, got = 10 }, nil
-- ORDERS, on the Spending tab's bottom line
ORDER_ST.festival = { ok = true, have = 250, cost = 200, use = "luxuries" }
ORDER_ST.muster = { ok = false, wait = 7, have = 300, cost = 200, use = "war" }
ORDER_ST.great_works = { ok = false, have = 120, cost = 200, use = "building" }
-- THE SPENDING TAB (asked for 2026-10-03): every province capital you hold with its four supply
-- boxes, the shipments on the road with a Show button each, and the three orders
CAPS = { "reg_a" }
SUPPLY_ST = { cost = 4, on = { materials = true }, short = { arms = 37 }, have = { building = 26, mounts = 0, war = 3 },
              pay = { building = { stem = "coal", n = 26 }, mounts = { stem = "iron", n = 0 }, war = { stem = "brimstone", n = 3 } } }
SHIPS = { { id = "derpy_mr_ship_1", f = LOCAL, stem = "coal", n = 22, from = "reg_b", to = "reg_a", due = 52, leg = 1,
            x = 40, y = 50 },
          { id = "derpy_mr_ship_2", f = "someone_else", stem = "coal", n = 9, from = "reg_b", to = "reg_a", due = 52,
            leg = 1, x = 1, y = 1 } }
SHIP_N = 1
click("derpy_mr_tab_spending")
eq(find("derpy_mr_tab_spending").text, "Spending", "a fourth tab")
eq(find("derpy_mr_tab_spending").images[0], S.TAB_ART[true][1], "lit when open")
eq(find("sub_title").text, "What your stores pay for", "its own title")
eq(cell(1, 1).text, "Alpha", "a row for each province capital you hold")
local function box(i, k) return find_uicomponent(find("derpy_mr_row_" .. i), "derpy_mr_sw_" .. k) end
local SC = LL.VIEWS.spending
-- WHAT EACH SUPPLY PAYS WITH (asked 2026-10-03): the good the payment takes first, as an icon
-- beside its box, greyed when the store cannot cover the price; Supply the capital ships, not pays
local function payic(i, k) return find_uicomponent(find("derpy_mr_row_" .. i), "derpy_mr_supic_" .. k) end
for i, sp in ipairs(DERPY_MR_STORES_SUPPLY) do
    eq(box(1, sp.key).visible, true, sp.label .. " box")
    local col = find("derpy_mr_row_1").x + SC[1 + i][1]
    if sp.use ~= "" then
        local ic = payic(1, sp.key)
        eq(ic.visible, true, sp.label .. ": the good it pays with")
        local pair = LL.CHECK + LL.PAY_GAP + LL.icon[3]   -- the icon's XML width
        eq(box(1, sp.key).x, col + math.floor((SC[1 + i][2] - pair) / 2), "box and icon centred as a pair in column " .. (1 + i))
        eq(ic.x, box(1, sp.key).x + LL.CHECK + LL.PAY_GAP, "the icon just right of the box")
    else
        eq(not payic(1, sp.key), true, "Supply the capital has no single good, so no icon")
        eq(box(1, sp.key).x, col + math.floor((SC[1 + i][2] - LL.CHECK) / 2), "its box centred alone")
    end
end
eq(payic(1, "materials").images[0], good_icon("coal"), "Materials pays with the capital's fullest: coal here")
eq(payic(1, "stable").images[0], good_icon("iron"), "a use with none held still shows its good")
eq(payic(1, "materials").shader, "glow_pulse_t0", "on, and 26 covers the 4 a turn: it glows as it pays")
eq(payic(1, "materials").vars[3], S.FX.glow[4], "at CA's pulse")
eq(payic(1, "stable").shader, "set_greyscale_t0", "none held: greyed")
eq(payic(1, "arms").shader, "set_greyscale_t0", "off, and 3 is short of 4: greyed")
SUPPLY_ST.on.arms = true
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
eq(payic(1, "arms").shader, "red_pulse_t0", "on but short: CA's insufficient red pulse")
eq(payic(1, "materials").shader, "glow_pulse_t0", "beside one that pays")
-- SHORT ON THE USE'S TOTAL, as F.supply decides: 3 brimstone and 6 more war materials pay the 4
SUPPLY_ST.have.war = 9
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
eq(payic(1, "arms").shader, "glow_pulse_t0", "its fullest good alone is short, but the war materials cover it")
SUPPLY_ST.have.war = 3
SUPPLY_ST.on.arms = nil
SUPPLY_ST.pay.building.n = 30; SUPPLY_ST.on.materials = nil
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
eq(payic(1, "materials").shader, "normal_t0", "off and covered: plain")
SUPPLY_ST.pay.building.n = 26; SUPPLY_ST.on.materials = true
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
eq(string.find(payic(1, "materials").tip, "Paid from Coal first, the fullest store.", 1, true) ~= nil, true,
   "the icon says what pays and why that one")
eq(string.find(payic(1, "stable").tip, "Nothing to pay with: the stores of Alpha hold none.", 1, true) ~= nil, true,
   "and when there is nothing to pay with")
eq(box(1, "materials").images[0], S.CHECK[true][1], "a supply that is on is ticked")
eq(box(1, "arms").images[0], S.CHECK[false][1], "one that is off is not")
eq(box(1, "export").visible, false, "no trade boxes here")
local mtip, atip = box(1, "materials").tip, box(1, "arms").tip
eq(string.find(mtip, "Pay 4 building materials a turn from the stores of Alpha", 1, true) ~= nil, true, "the price")
eq(string.find(mtip, "construction cost -25% in every settlement you hold in this province", 1, true) ~= nil, true,
   "what it buys, and where")
eq(string.find(mtip, "The stores of Alpha hold 26.", 1, true) ~= nil, true, "what the capital holds")
names_use(mtip, "building", "Materials on hand"); names_use(atip, "war", "Arms stocked")
eq(string.find(box(1, "standing").tip, "[[img:", 1, true), nil, "Supply the capital pays nothing, so names no goods")
eq(string.find(mtip, "On. Click to stop it.", 1, true) ~= nil, true, "and what a click does")
eq(string.find(atip, "Turned off on turn 37: the stores of Alpha ran short.", 1, true) ~= nil, true,
   "a supply that ran short says when")
eq(string.find(box(1, "standing").tip, "Off. Click to start it.", 1, true) ~= nil, true, "Supply the capital, off")
REQ = {}
press(box(1, "materials")); eq(REQ[1], "fac_a|supply|reg_a|materials", "a click toggles that capital's supply")
-- the shipments: a section row, then one row each, the local faction's only
eq(cell(2, 1).text, S.section("On the road (1 of 3)"), "a section row counting them against the most there can be")
eq(cell(2, 2).text, S.section("From"), "the road has its own headings, not the supplies'")
eq(cell(2, 3).text, S.section("To"), "to"); eq(cell(2, 4).text, S.section("Arrives"), "and when")
eq(cell(3, 1).text, "22 Coal", "what and how much"); eq(cell(3, 2).text, "Bravo", "from")
eq(cell(3, 3).text, "Alpha", "to"); eq(cell(3, 4).text, "turn 52", "and when it arrives")
eq(shown_rows(), 3, "another faction's shipment is not listed")
dump("spending")
local show = find_uicomponent(find("derpy_mr_row_3"), "derpy_mr_sendhere")
eq(show.visible, true, "a Show button"); eq(show.text, "Show", "labelled")
eq(string.find(show.tip, "beside Bravo", 1, true) ~= nil, true, "the tooltip says where it is now")
eq(box(3, "materials").visible, false, "no boxes on a shipment row")
for _, k in ipairs({ "materials", "stable", "arms" }) do
    eq(payic(2, k).visible, false, "no pay icon on the road's section row (seen in the preview, 2026-10-03)")
    eq(payic(3, k).visible, false, "nor on a shipment row")
end
press(show)
eq(CAMERA[1], 40 * 2, "the camera goes to the cart's display x"); eq(CAMERA[2], 50 * 2, "and y")
eq(CAMERA[3], 15, "keeping its distance"); eq(CAMERA[5], 12, "and height")
eq(find("derpy_mr_stores_panel").visible, false, "and the panel closes to show it")
eq(#REQ, 1, "Show asks the model for nothing")
click("derpy_mr_stores_button"); click("derpy_mr_tab_spending")
-- nothing on the road
SHIPS = {}
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
eq(cell(2, 1).text, S.section("On the road (0 of 3)"), "the count with nothing on the road")
eq(cell(3, 1).text, S.NO_SHIPS, "and a line saying how to send one")
-- the supplies switched off: no capitals listed, the road still is
SUP_ON = false; click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
eq(cell(1, 1).text, S.section("On the road (0 of 3)"), "province supplies off: the road comes first")
eq(find("hdr_2").text, "", "and no supply headings stand over it")
SUP_ON = true
do
    -- RECRUITS (workshop expansion spec section 3): last turn's draw, at the foot of the Spending tab
    local fl = DERPY_MR_FLOWS
    local function row_of(text)
        for i = 1, 60 do
            local r = find("derpy_mr_row_" .. i)
            if r and r.visible and cell(i, 1).text == text then return i end
        end
    end
    fl.recruit_last = function(fk)
        eq(fk, LOCAL, "the local faction's recruits")
        return { goods = 46, paid = { Armaments = 6 }, gold = 120, line = "The forges took %d %s in place of what the stores lacked." }
    end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
    dump("spending")   -- the preview draws the tab with its recruits row (overwrites the plain dump)
    eq(cell(1, 1).text, "Alpha", "the supply rows keep their place")
    local i = row_of(S.section(S.RECRUIT_HEAD))
    eq(i ~= nil, true, "a recruits section")
    eq(cell(i + 1, 1).text, "46 resources, 6 Armaments, 120 gold", "what they took")
    eq(string.find(find("derpy_mr_row_" .. (i + 1)).tip, "The forges took 6 Armaments", 1, true) ~= nil, true, "in the race's words")
    fl.recruit_last = function() return { goods = 9, paid = {}, gold = 0 } end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
    eq(cell(row_of(S.section(S.RECRUIT_HEAD)) + 1, 1).text, "9 resources", "no currency, no gold: only the goods")
    eq(string.find(find("derpy_mr_row_" .. (row_of(S.section(S.RECRUIT_HEAD)) + 1)).tip, "own currency", 1, true), nil,
       "and no currency named for a race without one")
    fl.recruit_last = function() return nil end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
    eq(row_of(S.section(S.RECRUIT_HEAD)), nil, "nothing recruited: no section")
    fl.recruit_last = function() return { goods = 0, paid = {}, gold = 0 } end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
    eq(row_of(S.section(S.RECRUIT_HEAD)), nil, "recruits that took nothing: no section")
    fl.recruit_last = nil
end
-- moved, not copied: the toggles and orders are nowhere else
click("derpy_mr_tab_settlements"); click("derpy_mr_row_1")
eq(not act("derpy_mr_supply_materials"), true, "no supply buttons on a capital's drill-down any more")
click("derpy_mr_tab_goods")
eq(act("derpy_mr_order_festival").visible, false, "no orders on the Resources tab any more")
eq(find("hint_text").text, "Click a resource to see where it is kept.", "and no shipments in its hint")
-- THE MAP TAB (asked for 2026-10-03): your settlements as dots, north up, the province capitals
-- larger and named, and every convoy of yours as a cart on a dotted line from where it left to
-- where it goes. Framed on what it shows, so it fits any campaign map with no picture of it.
FACTIONS.fac_a = faction("fac_a", { A, B })
POS.reg_a, POS.reg_b = { 100, 300 }, { 300, 100 }
CAPS = { "reg_a" }
SHIPS = { { id = "derpy_mr_ship_1", f = LOCAL, stem = "coal", n = 22, from = "reg_b", to = "reg_a", due = 52, leg = 2,
            x = 110, y = 290 } }
click("derpy_mr_tab_map")
eq(find("derpy_mr_tab_map").text, "Map", "a fifth tab")
eq(find("sub_title").text, "Where your settlements and convoys are", "its own title")
eq(shown_rows(), 0, "no list rows on the map")
eq(find("empty_text").visible, false, "and no empty-list text over it")
local function mapc(kind, i) return find("derpy_mr_map" .. kind .. "_" .. i) end
local box = LL.map
local function inside(c)
    return c.x >= pnl0.x + box[1] and c.y >= pnl0.y + box[2]
        and c.x + c.w <= pnl0.x + box[1] + box[3] and c.y + c.h <= pnl0.y + box[2] + box[4]
end
-- dots, in the realm's order (Alpha, then Bravo by name)
local da, db = mapc("dot", 1), mapc("dot", 2)
eq(da.visible and db.visible, true, "a dot for each settlement")
eq(string.find(da.tip, "Alpha", 1, true) ~= nil, true, "named in its tooltip")
eq(inside(da) and inside(db), true, "both inside the map's box")
eq(da.y < db.y, true, "north up: Alpha, further north, is drawn higher")
eq(da.x < db.x, true, "and west to the left")
eq(da.w > db.w, true, "a province capital's dot is larger")
eq(da.images[0], LL.MAP_CAP_ICON, "a province capital wears CA's capital marker")
eq(da.images[1], LL.MAP_CAP_ICON, "and brightens as itself under the mouse")
eq(db.images[1], LL.MAP_TOWN_ICON, "a settlement too")
eq(db.images[0], LL.MAP_TOWN_ICON, "another settlement CA's settlement marker")
eq(mapc("label", 1).visible, true, "and named on the map"); eq(mapc("label", 1).text, "Alpha", "by its name")
eq(mapc("label", 2).visible, true, "every settlement is named"); eq(mapc("label", 2).text, "Bravo", "Bravo too")
-- one scale for both axes: the map is not stretched
eq(math.abs((db.x - da.x) - (db.y - da.y)) <= 1, true, "equal distances north and east draw equal")
-- the convoy
local cart = mapc("cart", 1)
eq(cart.visible, true, "a cart for the convoy")
eq(cart.shader, "glow_pulse_t0", "pulsing: a convoy on the road")
dump("map")
eq(inside(cart), true, "inside the box")
eq(math.abs(cart.x + cart.w / 2 - (da.x + da.w / 2)) < 40, true, "near Alpha, where it is now")
eq(string.find(cart.tip, "22 Coal from Bravo to Alpha", 1, true) ~= nil, true, "what it carries, from and to")
eq(string.find(cart.tip, "turn 52", 1, true) ~= nil, true, "and when it arrives")
local path = 0
for i = 1, 50 do
    local c = mapc("path", i)
    if c and c.visible then
        path = path + 1
        eq(c.x > da.x and c.x < db.x + db.w, true, "a path dot between the two settlements")
    end
end
eq(path, LL.MAP_STEPS, "a dotted line from where it left to where it goes")
press(cart)
eq(CAMERA[1], 110 * 2, "a click on the cart flies the camera to it"); eq(CAMERA[2], 290 * 2, "both co-ordinates")
eq(find("derpy_mr_stores_panel").visible, false, "and closes the panel")
click("derpy_mr_stores_button"); click("derpy_mr_tab_map")
press(mapc("dot", 2)); eq(CAMERA[1], 300 * 2, "a click on a settlement flies there too")
click("derpy_mr_stores_button"); click("derpy_mr_tab_map")
-- NAMES THAT WOULD COLLIDE ARE DROPPED, capitals kept first; the dot and its tooltip stay
local C3 = region("reg_c3", 33, 1, 0, nil, nil)
LOC["regions_onscreen_reg_c3"] = "Charlie"
FACTIONS.fac_a = faction("fac_a", { A, B, C3 }); POS.reg_c3 = { 103, 297 }
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
local function labels()
    local out, i = {}, 1
    while mapc("label", i) do
        if mapc("label", i).visible then out[#out + 1] = mapc("label", i) end
        i = i + 1
    end
    return out
end
-- WHERE A NAME'S LETTERS ARE: from the box's left edge, as wide as the font draws them. Seen in game
-- 2026-10-07: a name put on its dot's left with SetTextHAlign("right") after its text still drew
-- from the box's left edge, ~75px short of the dot. So the halign a label was given is ignored here.
local function letters(l) return l.x, l:WidthOfTextLine(l.text) end
local function meets(a, b)
    local ax, aw = letters(a)
    local bx, bw = letters(b)
    return ax < bx + bw and bx < ax + aw and a.y < b.y + b.h and b.y < a.y + a.h
end
local ls = labels()
eq(#ls, 2, "three settlements, two names: Charlie's would sit on Alpha's")
eq(ls[1].text, "Alpha", "the capital keeps its name"); eq(ls[2].text, "Bravo", "Bravo, clear of both, keeps its")
eq(mapc("dot", 3).visible, true, "Charlie is still drawn")
eq(string.find(mapc("dot", 3).tip, "Charlie", 1, true) ~= nil, true, "and named in its tooltip")
eq(meets(ls[1], ls[2]), false, "no two names overlap")
-- A NAME AT THE RIGHT EDGE GOES ON THE DOT'S LEFT, inside the map
POS.reg_c3 = { 520, 200 }
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
for _, l in ipairs(labels()) do
    eq(l.x >= pnl0.x + box[1] and l.x + l.w <= pnl0.x + box[1] + box[3], true, l.text .. "'s name inside the map")
end
local east = labels()[3]
eq(east.text, "Charlie", "the eastmost is named")
local ex, ew = letters(east)
local gap = mapc("dot", 3).x + mapc("dot", 3).w / 2 - (ex + ew)
eq(gap > 0 and gap <= LL.MAP_CAP / 2 + 6, true, "on its dot's left, its letters ending just before it (gap " .. gap .. ")")
local wx, ww = letters(labels()[1])
local wgap = wx - (mapc("dot", 1).x + mapc("dot", 1).w / 2)
eq(wgap > 0 and wgap <= LL.MAP_CAP / 2 + 6, true, "a name on the right starts just after its dot (gap " .. wgap .. ")")
POS.reg_c3 = nil
-- CA'S MAP UNDER IT (asked for 2026-10-03, "too bare bones"; placement corrected the same day):
-- every point goes through the ENGINE'S frame, CampaignRadarPosition, read once a session off the
-- world's extreme settlements. Measured in game: the picture is drawn in display space, so the
-- logical frame put Zharr-Naggrund visibly south of its place.
FACTIONS.fac_a = faction("fac_a", { A, B }); WORLD = { A, B }; S.frame = nil
local function art() return find("derpy_mr_map_art") end
local function radar(k)
    local dx, dy = 2 * POS[k][1], 2 * POS[k][2]
    return math.max(0, math.min(1, dx / RADAR.w)), math.max(0, math.min(1, 1 - dy / RADAR.h))
end
local function on_place(a, d, k, what)
    local fx, fy = radar(k)
    eq(math.abs(d.x + d.w / 2 - (a.x + a.w * fx)) <= 1.5, true, what .. " sits on its place in the picture, across")
    eq(math.abs(d.y + d.h / 2 - (a.y + a.h * fy)) <= 1.5, true, what .. " and down")
end
eq(find("derpy_mr_map_clip").visible, true, "a map with no known picture still has its surface")
eq(art().images[0], S.NO_ART, "but no picture on it")
local WANT = { wh3_main_combi = { "campaign_maps/wh3_main_combi_map_7/wh3_main_combi_map_minimap.png", 1440, 1120 },
               cr_combi_expanded = { "campaign_maps/cr_combi_expanded_map_1/cr_combi_expanded_map_minimap.png", 1600, 1120 },
               wh3_main_chaos = { "campaign_maps/wh3_main_chaos_map_4/wh3_main_chaos_map_minimap.png", 1108, 834 } }
for _, key in ipairs({ "wh3_main_combi", "cr_combi_expanded", "wh3_main_chaos" }) do
    CAMPAIGN = key; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    local a, w = art(), WANT[key]
    eq(a.visible and find("derpy_mr_map_clip").visible, true, key .. " draws its map"); eq(a.images[0], w[1], key .. "'s own minimap")
    local sc = a.w / w[2]
    eq(math.abs(a.h / w[3] - sc) < 0.01, true, "the picture is not stretched")
    eq(sc <= LL.MAP_ART_ZOOM + 1e-9, true, "zoomed no closer than the picture has detail for")
    on_place(a, mapc("dot", 1), "reg_a", key .. ": Alpha"); on_place(a, mapc("dot", 2), "reg_b", key .. ": Bravo")
    local clip = find("derpy_mr_map_clip")
    eq(clip.x, pnl0.x + box[1], "the picture is cut to the map's box"); eq(clip.y, pnl0.y + box[2], "down")
    eq(clip.w, box[3], "its width"); eq(clip.h, box[4], "its height")
    eq(find_uicomponent(clip, "derpy_mr_map_art") ~= false, true, "inside the box that cuts it")
    -- EVERYTHING ON THE PICTURE IS IN IT: drawn over it, cut with it, and dragged with it
    for _, kind in ipairs({ "dot", "label", "path", "cart" }) do
        if mapc(kind, 1) then eq(find_uicomponent(a, "derpy_mr_map" .. kind .. "_1") ~= false, true, "the " .. kind .. "s ride on the picture") end
    end
    eq(a.x <= clip.x and a.x + a.w >= clip.x + clip.w, true, "the picture fills the box across, no blank past its edge")
    eq(a.y <= clip.y and a.y + a.h >= clip.y + clip.h, true, "and down")
    dump("map_" .. key)
end
eq(mapc("cart", 1).visible, true, "the convoy is drawn on the picture")
-- THE FRAME IS READ ONCE: not a CampaignRadarPosition per settlement per draw
local calls = RADAR_CALLS
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(RADAR_CALLS, calls, "a second draw asks the engine nothing")
-- NOTHING LIES OVER THE MAP (seen in game 2026-10-03): the empty scrolling list kept the map's
-- box, and made after it, it took every grab meant for the picture
eq(find("derpy_mr_stores_list"), false, "the map tab has no list over the map")
click("derpy_mr_tab_goods")
eq(find("derpy_mr_stores_list") ~= false, true, "and the goods tab gets its list back")
click("derpy_mr_tab_map")
-- GRAB AND DRAG (asked 2026-10-03): the picture moves with the mouse, everything on it with it,
-- and a 16ms poll keeps it covering the box
do
    local a, clip = art(), find("derpy_mr_map_clip")
    local d1 = mapc("dot", 1)
    local off = d1.x - a.x
    a:MoveTo(a.x - 5000, a.y - 5000); REPEATS.derpy_mr_stores_scroll()
    eq(a.x, clip.x + clip.w - a.w, "dragged too far west, it stops at the picture's east edge")
    eq(a.y, clip.y + clip.h - a.h, "too far north, at its south edge")
    eq(mapc("dot", 1).x - a.x, off, "the settlements move with it")
    a:MoveTo(a.x + 30, a.y + 20); REPEATS.derpy_mr_stores_scroll()
    eq(a.x, clip.x + clip.w - a.w + 30, "a drag that stays on the picture is kept")
    eq(a.y, clip.y + clip.h - a.h + 20, "both ways")
    a:MoveTo(clip.x + 5000, clip.y + 5000); REPEATS.derpy_mr_stores_scroll()
    eq(a.x, clip.x, "dragged too far east, it stops at its west edge"); eq(a.y, clip.y, "and its north")
end
-- A FRAME, A KEY AND ZOOM (asked 2026-10-04, once the drag was seen working in game)
local function zoom_in() return find("derpy_mr_zoom_in") end
local function zoom_out() return find("derpy_mr_zoom_out") end
-- the picture's spot under the middle of the box, as a 0-1 fraction of the picture
local function mid_frac()
    local a, c = art(), find("derpy_mr_map_clip")
    return (c.x + c.w / 2 - a.x) / a.w, (c.y + c.h / 2 - a.y) / a.h
end
do
    -- the box not yet in place, as on a session's first draw (seen in game 2026-10-04: no + and -,
    -- placed before the box's own MoveTo carried them off)
    click("derpy_mr_tab_goods"); find("derpy_mr_map_clip"):MoveTo(0, 0); click("derpy_mr_tab_map")
    local clip, fr = find("derpy_mr_map_clip"), find("derpy_mr_map_frame")
    eq(fr ~= false and fr.visible, true, "the map has a frame")
    local o = LL.MAP_FRAME_OUT
    eq(fr.x == clip.x - o and fr.y == clip.y - o and fr.w == clip.w + 2 * o and fr.h == clip.h + 2 * o, true,
       "past the map's box by the art's clear edge, so its line lands on the box's edge")
    local at = {}
    for i, k in ipairs(clip.kids) do at[k.name] = i end
    eq(at.derpy_mr_map_frame > at.derpy_mr_map_art, true, "made after the picture, so drawn over it and everything on it")
    for _, k in ipairs({ { "cap", LL.MAP_CAP_ICON, "Province capital" }, { "town", LL.MAP_TOWN_ICON, "Settlement" },
                         { "cart", LL.MAP_CART, "Convoy" } }) do
        local ic, tx = find("derpy_mr_mapkey_" .. k[1]), find("derpy_mr_mapkey_" .. k[1] .. "_text")
        eq(ic.visible and tx.visible, true, k[3] .. " in the key")
        eq(ic.images[0], k[2], k[3] .. ": the icon the map draws"); eq(tx.text, k[3], "and its name")
        eq(ic.y >= pnl0.y + LL.bulk[2] and ic.y + ic.h <= pnl0.y + LL.bulk[2] + LL.bulk[4], true, k[3] .. " on the bottom line")
        eq(tx.x >= ic.x + ic.w, true, k[3] .. ": the name right of its icon")
    end
    eq(zoom_out().visible and zoom_in().visible, true, "two zoom buttons")
    eq(zoom_in().x, pnl0.x + LL.zoom_in[1], "+ in the map's corner"); eq(zoom_in().y, pnl0.y + LL.zoom_in[2], "down")
    eq(zoom_out().x, pnl0.x + LL.zoom_out[1], "- under it"); eq(zoom_out().y, pnl0.y + LL.zoom_out[2], "down")
    eq(zoom_in().text, "+", "a plus"); eq(zoom_out().text, "-", "a minus")
    eq(string.find(zoom_in().tip, "Zoom in", 1, true) == 1, true, "+ says what it does")
    eq(at.derpy_mr_zoom_in > at.derpy_mr_map_frame and at.derpy_mr_zoom_out > at.derpy_mr_map_frame, true,
       "made after the frame, so drawn over it")
    -- ZOOM KEEPS THE SPOT YOU ARE LOOKING AT, after a drag too
    local a = art()
    a:MoveTo(a.x - 40, a.y - 30); REPEATS.derpy_mr_stores_scroll()
    local w0, fx, fy = art().w, mid_frac()
    press(zoom_in())
    eq(math.abs(art().w - w0 * LL.MAP_ZOOM_STEP) <= 1, true, "Zoom in draws the picture a step larger")
    local gx, gy = mid_frac()
    eq(math.abs(gx - fx) < 0.002 and math.abs(gy - fy) < 0.002, true, "around the spot that was in the middle")
    on_place(art(), mapc("dot", 1), "reg_a", "zoomed in, Alpha"); on_place(art(), mapc("dot", 2), "reg_b", "and Bravo")
    eq(math.abs(art().h / art().w - 834 / 1108) < 0.01, true, "not stretched")
    local n = 0
    while not zoom_in().disabled and n < 20 do press(zoom_in()); n = n + 1 end
    eq(zoom_in().disabled, true, "Zoom in greys at the closest")
    eq(art().w / 1108 <= LL.MAP_ZOOM_MAX + 1e-6, true, "no closer than MAP_ZOOM_MAX")
    eq(art().w / 1108 >= LL.MAP_ZOOM_MAX / LL.MAP_ZOOM_STEP, true, "and it got there")
    local wmax = art().w; press(zoom_in())
    eq(art().w, wmax, "a greyed Zoom in does nothing")
    n = 0
    while not zoom_out().disabled and n < 20 do press(zoom_out()); n = n + 1 end
    eq(zoom_out().disabled, true, "Zoom out greys at the farthest"); eq(zoom_in().disabled, false, "and Zoom in is back")
    local ca = art()
    eq(ca.w >= clip.w and ca.h >= clip.h, true, "zoomed out, the picture still covers the box")
    eq(math.abs(ca.w - clip.w) <= 1 or math.abs(ca.h - clip.h) <= 1, true, "and one side of it fits the box: the whole map")
    eq(ca.x <= clip.x and ca.x + ca.w >= clip.x + clip.w and ca.y <= clip.y and ca.y + ca.h >= clip.y + clip.h, true,
       "kept on the picture")
    -- reopening, or coming back to the tab, frames the map as it first was
    click("derpy_mr_stores_button"); click("derpy_mr_stores_button")
    eq(find("sub_title").text, "Where your settlements and convoys are", "reopened on the Map tab")
    eq(art().w, w0, "reopened, the first framing"); eq(zoom_out().disabled, false, "Zoom out lit again")
    press(zoom_in()); click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    eq(art().w, w0, "another tab and back, the first framing")
    -- off the map, none of it shows
    click("derpy_mr_tab_goods")
    eq(zoom_in().visible or zoom_out().visible, false, "no zoom buttons off the map")
    eq(find("derpy_mr_mapkey_cap").visible or find("derpy_mr_mapkey_cap_text").visible, false, "and no key")
    click("derpy_mr_tab_map")
end
-- THE ENGINE DRAGS THE GRAB LAYER, NEVER THE PICTURE (seen in game 2026-10-04: let go, a dragged
-- "Movable XP" picture went back where the drag began; held there after, it still flickered home
-- for one frame). The picture follows the grab layer; the put-back happens to the clear layer.
do
    local poll = REPEATS.derpy_mr_stores_scroll
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    local a, g, clip = art(), find("derpy_mr_map_grab"), find("derpy_mr_map_clip")
    eq(g.x == clip.x and g.y == clip.y and g.w == clip.w and g.h == clip.h, true, "the grab layer covers the map's box")
    eq(clip.kids[1], g, "beneath the picture, so the markers on it keep their clicks")
    local x0, y0 = a.x, a.y
    g.dragged = true; g:MoveTo(clip.x - 30, clip.y - 20); poll()
    eq(a.x, x0 - 30, "dragging the grab layer drags the picture"); eq(a.y, y0 - 20, "both ways")
    g:MoveTo(clip.x - 50, clip.y - 20); poll()
    eq(a.x, x0 - 50, "and it keeps following")
    g.dragged = false; g:MoveTo(clip.x, clip.y); poll()   -- the engine's put-back, of the grab layer
    eq(a.x, x0 - 50, "let go: the picture stays, with nothing to flicker back"); eq(a.y, y0 - 20, "both ways")
    g:MoveTo(clip.x - 7, clip.y + 3); poll()
    eq(g.x == clip.x and g.y == clip.y, true, "a grab layer left out of place goes back under the box")
    eq(a.x, x0 - 50, "without moving the picture")
    g.dragged = true; g:MoveTo(clip.x - 99999, clip.y); poll()
    eq(a.x, clip.x + clip.w - a.w, "a drag past the picture's edge stops at it")
    g.dragged = false; g:MoveTo(clip.x, clip.y); poll()
    g.dragged = true; g:MoveTo(clip.x + 10, clip.y); poll(); g.dragged = false
    press(zoom_in())
    local zx = art().x
    g:MoveTo(clip.x, clip.y); poll()
    eq(art().x, zx, "a zoom straight after a drag keeps its own framing")
end
-- NO ANSWER FROM THE ENGINE: the plain map, never a picture in the wrong frame
RADAR_OFF, S.frame = true, nil
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(art().images[0], S.NO_ART, "no frame, no picture"); eq(mapc("dot", 1).visible, true, "the settlements still drawn")
do
    -- the plain map zooms too: the settlements spread, and the surface grows to carry every one
    local function gap() return mapc("dot", 2).x - mapc("dot", 1).x end
    local g0 = gap()
    press(zoom_in())
    eq(math.abs(gap() - g0 * LL.MAP_ZOOM_STEP) <= 2, true, "the plain map draws the settlements a step apart")
    local a = art()
    for i = 1, 2 do
        local d = mapc("dot", i)
        eq(d.x >= a.x and d.x + d.w <= a.x + a.w and d.y >= a.y and d.y + d.h <= a.y + a.h, true,
           "dot " .. i .. " on the surface, so a drag carries it")
    end
    eq(find("derpy_mr_map_frame").visible, true, "framed too")
end
RADAR_OFF, S.frame = false, nil
-- TWO SETTLEMENTS CLOSE TOGETHER BY THE MAP'S SOUTH EDGE: zoomed only as far as the picture has
-- detail for, and the view kept on the picture rather than showing the blank below it
POS.reg_a, POS.reg_b = { 600, 30 }, { 612, 22 }
local ships0 = SHIPS; SHIPS = {}
CAMPAIGN = "wh3_main_combi"; S.frame = nil; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
local ea, eclip = art(), find("derpy_mr_map_clip")
eq(ea.w, 1440 * LL.MAP_ART_ZOOM, "a tight cluster is drawn at the closest zoom, no closer")
eq(ea.y + ea.h >= eclip.y + eclip.h, true, "and the picture still reaches the box's foot")
eq(ea.y + ea.h - (eclip.y + eclip.h) <= 1, true, "its own foot on the box's: the view went no further south")
on_place(ea, mapc("dot", 2), "reg_b", "by the edge, Bravo")
POS.reg_a, POS.reg_b = { 100, 300 }, { 300, 100 }
SHIPS = ships0; S.frame = nil
CAMPAIGN = "some_mod_map"; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(art().images[0], S.NO_ART, "back on an unknown map, the picture goes")
CAMPAIGN = "wh3_main_combi"; click("derpy_mr_tab_goods")
eq(find("derpy_mr_map_clip").visible, false, "and off the Map tab")
CAMPAIGN = "some_mod_map"
-- a single settlement and no convoy: framed on that one, nothing stretched to a point
FACTIONS.fac_a = faction("fac_a", { A }); SHIPS = {}
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(mapc("dot", 1).visible, true, "one settlement still draws"); eq(inside(mapc("dot", 1)), true, "inside the box")
eq(mapc("dot", 2).visible, false, "the second dot is hidden, not left behind")
eq(mapc("cart", 1).visible, false, "no convoy, no cart"); eq(mapc("path", 1).visible, false, "and no path")
eq(#ERRORS, 0, "no errors drawing the map")
-- leaving the map hides it all
click("derpy_mr_tab_goods")
eq(mapc("dot", 1).visible, false, "off the Map tab, no dots")
eq(shown_rows() > 0, true, "and the list is back")
POS.reg_a, POS.reg_b = nil, nil
click("derpy_mr_tab_spending")
for i, o in ipairs(DERPY_MR_STORES_ORDERS) do
    local bt = act("derpy_mr_order_" .. o.key)
    eq(bt.visible, true, o.label .. " shown"); eq(bt.text, o.label, "labelled")
    eq(bt.x, slot(i + 1), "in bottom-line slot " .. (i + 1)); eq(bt.y, pnl0.y + LL.bulk[2], "on the bottom line")
end
local fest = act("derpy_mr_order_festival")
eq(fest.disabled, false, "Festival can be bought")
eq(string.find(fest.tip, "Spend 200 luxuries", 1, true) ~= nil, true, "the tooltip gives the price")
eq(string.find(fest.tip, "public order +4 in every province, for 5 turns", 1, true) ~= nil, true, "and what it buys")
for _, o in ipairs(DERPY_MR_STORES_ORDERS) do names_use(act("derpy_mr_order_" .. o.key).tip, o.use, o.label) end
eq(act("derpy_mr_order_muster").disabled, true, "Muster is waiting")
eq(string.find(act("derpy_mr_order_muster").tip, "Ready again in 7 turns.", 1, true) ~= nil, true, "and says how long")
eq(act("derpy_mr_order_great_works").disabled, true, "Great Works is short")
eq(string.find(act("derpy_mr_order_great_works").tip, "Your stores hold 120 building materials.", 1, true) ~= nil, true,
   "and says how short")
eq(find("hint_text").y < fest.y, true, "the hint is clear of the orders' line")
-- A RUNNING ORDER GLOWS (CA's active-state glow_pulse_t0) and still cannot be bought
ORDER_ST.festival = { ok = false, wait = 8, active = 3, have = 250, cost = 200, use = "luxuries" }
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
local runb = act("derpy_mr_order_festival")
eq(runb.shader, "glow_pulse_t0", "a running order glows"); eq(runb.disabled, true, "and cannot be bought again")
eq(runb.vars[1] == S.FX.glow[2] and runb.vars[2] == S.FX.glow[3], true, "at CA's values")
eq(string.find(runb.tip, "Running: 3 turns left. Ready again in 8 turns.", 1, true) ~= nil, true, "and says so")
REQ = {}; press(runb); eq(#REQ, 0, "a click on a running order asks for nothing")
eq(act("derpy_mr_order_muster").shader, "set_greyscale_t0", "a waiting one is grey, not glowing")
ORDER_ST.festival = { ok = true, have = 250, cost = 200, use = "luxuries" }
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
eq(act("derpy_mr_order_festival").shader, "normal_t0", "over and ready: live again")
fest = act("derpy_mr_order_festival")
REQ = {}
press(fest); eq(REQ[1], "fac_a|order|festival", "a click buys it")
press(act("derpy_mr_order_muster")); eq(#REQ, 1, "a greyed order asks for nothing")
eq(act("derpy_mr_sell").visible, false, "no Sell on the Spending tab")
-- SELL, on a resource's drill-down
SALE = { n = 120, gold = 840, price = 7 }
click("derpy_mr_tab_goods"); click("derpy_mr_row_1"); eq(find("sub_title").text, "Where Coal is kept", "Coal's drill-down")
local sell = act("derpy_mr_sell")
eq(sell.visible, true, "a Sell button"); eq(sell.text, "Sell surplus", "labelled"); eq(sell.x, slot(4), "in slot 4")
eq(sell.tip, "Sell 120 Coal for 840 gold: what your stores hold above half their space.", "priced in its tooltip")
eq(act("derpy_mr_order_festival").visible, false, "no orders on a drill-down")
press(sell); eq(REQ[2], "fac_a|sell|coal", "a click sells it")
SALE = nil; click("derpy_mr_back"); click("derpy_mr_row_1")
eq(act("derpy_mr_sell").disabled, true, "nothing to sell: greyed")
eq(act("derpy_mr_sell").tip, "Nothing to sell: your stores of Coal are no more than half full.", "and says why")
press(act("derpy_mr_sell")); eq(#REQ, 2, "a greyed Sell asks for nothing")
-- the MCT switch, and no flows script: no buttons, no error
ACT_ON = false; click("derpy_mr_back"); click("derpy_mr_row_1")
eq(act("derpy_mr_sell").visible, false, "switched off: no Sell")
click("derpy_mr_tab_spending"); eq(act("derpy_mr_order_festival").visible, false, "nor orders")
DERPY_MR_FLOWS = nil; click("derpy_mr_tab_settlements"); click("derpy_mr_row_1")
eq(sendb(1).visible, false, "without the flows script: no Send here"); eq(#ERRORS, 0, "and no error")
click("derpy_mr_tab_goods")

-- ---- THE WORKSHOP TAB (spec 2026-10-07) --------------------------------------------------
;(function()
    local WORK_ST, WORK_AT, WREQ, WON = {}, {}, {}, true
    local realm0 = FACTIONS.fac_a
    FACTIONS.fac_a = faction("fac_a", { A, B })
    DERPY_MR_FLOWS = {
        rates = function() return { actions = WON } end,
        request = function(fk, ...) WREQ[#WREQ + 1] = fk .. "|" .. table.concat({ ... }, "|") end,
        work_state = function(f, key, rk)
            eq(f:name(), LOCAL, "the local faction's state")
            if rk then return WORK_AT[rk] end
            return WORK_ST[key]
        end,
    }
    WORK_ST.item_gromril_armour = { ok = true, rare = { have = 80, cost = 40 }, bulk = { have = 200, cost = 150 } }
    WORK_ST.item_dragonhelm = { ok = false, why = "short", rare = { have = 10, cost = 40 }, bulk = { have = 200, cost = 150 } }
    WORK_ST.item_gromril_greataxe = { ok = false, why = "done", rare = { have = 80, cost = 40 }, bulk = { have = 200, cost = 150 } }
    WORK_ST.up_gromril = { ok = false, why = "where", rare = { have = 80, cost = 60 }, bulk = { have = 200, cost = 200 } }
    WORK_ST.research = { ok = false, why = "wait", wait = 4, bulk = { have = 500, cost = 300 } }
    WORK_ST.unit_wh_main_dwf_inf_ironbreakers = { ok = true, route = "pool", rare = { have = 80, cost = 30 },
                                                  bulk = { have = 200, cost = 100 } }
    WORK_ST.unit_wh_main_dwf_inf_hammerers = { ok = false, why = "no_army", route = "army", rare = { have = 80, cost = 30 },
                                               bulk = { have = 200, cost = 100 } }
    click("derpy_mr_tab_workshop")
    local t, back = find("derpy_mr_tab_workshop"), find("derpy_mr_back")
    eq(t.visible, true, "a sixth tab"); eq(t.text, "Workshop", "labelled")
    eq(t.x + t.w <= back.x, true, "clear of Back"); eq(lit("derpy_mr_tab_workshop"), SEL, "and lit when open")
    eq(find("sub_title").text, "What your stores can buy", "its title")
    local function row_of(key)
        for i, r in ipairs(S.data) do if r.work == key then return i, r end end
    end
    local secs = {}
    for _, r in ipairs(S.data) do if r.section then secs[#secs + 1] = r[1] end end
    eq(table.concat(secs, ","), table.concat({ S.section("Items"), S.section("Units"), S.section("Settlement upgrades"),
                                               S.section("Research") }, ","), "sections in order")
    -- A UNIT SAYS WHERE IT GOES: its race's pool (and that recruiting it still costs gold), or an army
    local _, ib = row_of("unit_wh_main_dwf_inf_ironbreakers")
    eq(string.find(ib.tip, "Goes into your Book of Grudges to recruit. Recruiting it still costs its gold.", 1, true) ~= nil,
       true, "the pool route says where, and that gold is still due")
    local ihm, hm = row_of("unit_wh_main_dwf_inf_hammerers")
    eq(string.find(hm.tip, "Goes straight into your largest army with room.", 1, true) ~= nil, true, "the army route says so")
    eq(sendb(ihm).disabled, true, "no army with room: greyed"); eq(sendb(ihm).tip, "No army of yours has room for it.", "says why")
    eq(S.data[1].section, true, "a section row first")
    local ia, arm = row_of("item_gromril_armour")
    local ih, helm = row_of("item_dragonhelm")
    local _, axe = row_of("item_gromril_greataxe")
    eq(cell(ia, 1).text, "Gromril Armour", "its name"); eq(cell(ia, 2).text, "Armour", "what it gives")
    eq(string.find(arm.tip, "Armour for a lord or hero.", 1, true) ~= nil, true, "its tooltip says the whole of it")
    eq(sendb(ia).visible, true, "a Buy button"); eq(sendb(ia).text, "Buy", "labelled")
    eq(sendb(ia).x, find("derpy_mr_row_" .. ia).x + LL.VIEWS.workshop[5][1], "in the fifth column")
    eq(sendb(ia).disabled, false, "a row you can pay: live")
    eq(sendb(ih).disabled, true, "short: greyed"); eq(sendb(ih).tip, "Your stores hold 10 of 40 " .. S.name("dragon_bone") .. ".", "and says why")
    eq(axe.send.label, "Forged", "forged once: says so"); eq(sendb(row_of("item_gromril_greataxe")).disabled, true, "greyed")
    -- the price: two parts, each a real icon at its column's start and the figure after it
    local hr = find("derpy_mr_row_" .. ih)
    local u1, u2 = find_uicomponent(hr, "use1"), find_uicomponent(hr, "use2")
    eq(u1.visible and u1.image, good_icon("dragon_bone"), "the rare good's icon")
    eq(u1.x, hr.x + LL.VIEWS.workshop[3][1], "at the start of column 3")
    eq(cell(ih, 3).text, "[[col:red]]40[[/col]]", "its price red, as it is short")
    eq(cell(ih, 3).x, u1.x + LL.ICON_PITCH, "after the icon")
    eq(u2.visible and u2.image, DERPY_MR_STORES_USE_ICON.mounts, "the bulk's use icon")
    eq(u2.x, hr.x + LL.VIEWS.workshop[4][1], "at the start of column 4")
    eq(cell(ih, 4).text, "150", "the bulk is not short: not red")
    local _, rres = row_of("research")
    local rr = find("derpy_mr_row_" .. row_of("research"))
    eq(cell(row_of("research"), 3).text, "", "research has no rare part")
    eq(find_uicomponent(rr, "use1").x, rr.x + LL.VIEWS.workshop[4][1], "its one icon in the bulk's column")
    eq(find_uicomponent(rr, "use2").visible, false, "and no second")
    names_use(helm.tip, "mounts", "Dragonhelm")
    eq(string.find(helm.tip, "not counting rare resources", 1, true) ~= nil, true, "the tooltip says rare resources do not pay")
    -- the research row waits
    local _, res = row_of("research")
    eq(res.send.off, true, "research waiting: greyed"); eq(res.send.tip, "Ready again in 4 turns.", "says how long")
    -- Buy asks the one door; a greyed Buy asks nothing
    press(sendb(ia)); eq(WREQ[1], LOCAL .. "|work|item_gromril_armour", "Buy asks for that row")
    press(sendb(ih)); eq(#WREQ, 1, "a greyed Buy asks nothing")
    -- an upgrade has no Buy of its own: Choose (or the row) opens a list of settlements
    local iu, up = row_of("up_gromril")
    eq(sendb(iu).text, "Choose", "an upgrade row's button chooses"); eq(sendb(iu).disabled, false, "and is live")
    eq(up.open, "up_gromril", "the row opens too")
    WORK_AT.reg_a = { ok = true, rare = { have = 80, cost = 60 }, bulk = { have = 200, cost = 200 } }
    WORK_AT.reg_b = { ok = false, why = "built", rare = { have = 80, cost = 60 }, bulk = { have = 200, cost = 200 } }
    local nreq = #WREQ
    press(sendb(iu)); eq(#WREQ, nreq, "Choose buys nothing")
    eq(back.visible, true, "a drill-down, with Back")
    eq(find("sub_title").text, "Where to build Gromril Gate", "titled for it")
    eq(find("hdr_1").w, LL.VIEWS.workshop_focus[1][2], "in its own columns")
    eq(find("hint_text").text, "Paid from all your stores: 60 " .. S.name("gromril") .. " and 200 war materials.",
       "the price on the hint's line")
    click("derpy_mr_back"); click("derpy_mr_row_" .. iu)
    eq(find("sub_title").text, "Where to build Gromril Gate", "a click on the row opens it as well")
    local ra, rb
    for i, r in ipairs(S.data) do
        if r.region == "reg_a" then ra = i elseif r.region == "reg_b" then rb = i end
    end
    eq(sendb(ra).text, "Buy here", "each settlement: Buy here"); eq(sendb(ra).disabled, false, "live where it can be built")
    eq(sendb(rb).text, "Built", "built already: says so"); eq(sendb(rb).disabled, true, "and greyed")
    dump("workshop_focus")
    press(sendb(ra)); eq(WREQ[2], LOCAL .. "|upgrade|up_gromril|reg_a", "Buy here asks for that settlement")
    press(sendb(rb)); eq(#WREQ, 2, "a greyed one asks nothing")
    click("derpy_mr_back"); eq(S.focus, nil, "Back returns to the Workshop")
    eq(find("sub_title").text, "What your stores can buy", "the list again")
    dump("workshop")
    -- the actions switch off: rows shown, every Buy greyed and saying why
    WON = false; click("derpy_mr_tab_goods"); click("derpy_mr_tab_workshop")
    ia = row_of("item_gromril_armour")
    eq(sendb(ia).disabled, true, "switched off: greyed")
    eq(sendb(ia).tip, "Resource Vault actions are switched off in the mod's settings.", "and says why")
    press(sendb(ia)); eq(#WREQ, 2, "and asks nothing")
    -- no flows script: no rows, no error
    DERPY_MR_FLOWS = nil; click("derpy_mr_tab_goods"); click("derpy_mr_tab_workshop")
    eq(shown_rows(), 0, "without the flows script: nothing to buy"); eq(#ERRORS, 0, "and no error")
    click("derpy_mr_tab_goods")
    FACTIONS.fac_a = realm0
end)()
-- ---- THE NAMED RECIPES ON THE WORKSHOP TAB (workshop expansion spec section 4) ----
;(function()
    local WORK_ST, WREQ, SEL = {}, {}, nil
    local realm0, flows0, cuim0 = FACTIONS.fac_a, DERPY_MR_FLOWS, cm.get_campaign_ui_manager
    FACTIONS.fac_a = faction("fac_a", { A, B })
    DERPY_MR_FLOWS = {
        rates = function() return { actions = true } end,
        request = function(fk, ...) WREQ[#WREQ + 1] = fk .. "|" .. table.concat({ ... }, "|") end,
        work_state = function(f, key, rk, cqi)
            local st = WORK_ST[key]
            if type(st) == "function" then return st(cqi) end
            return st
        end,
    }
    cm.get_campaign_ui_manager = function() return { get_char_selected_cqi = function() return SEL end } end
    LOC.names_name_1, LOC.names_name_2 = "Karl", "Franz"
    CHARS[91] = { is_null_interface = function() return false end, get_forename = function() return "names_name_1" end,
                  get_surname = function() return "names_name_2" end }
    local gran = { { stem = "grain", have = 200, cost = 120 }, { stem = "salt", have = 50, cost = 120 },
                   { stem = "salted_meat", have = 300, cost = 120 }, { stem = "pottery", have = 120, cost = 120 } }
    WORK_ST.last_granary = { ok = false, why = "short", goods = gran }
    local ammo = { { stem = "blackpowder", have = 100, cost = 50 }, { stem = "brass", have = 100, cost = 50 } }
    WORK_ST.army_ammo = function(cqi)
        if not cqi then return { ok = false, why = "aim", goods = ammo } end
        return { ok = true, goods = ammo }
    end
    WORK_ST.trait_steel = function(cqi) return { ok = false, why = "aim", goods = ammo } end
    WORK_ST.trait_spice = function(cqi) return { ok = false, why = cqi and "not_lord" or "aim", goods = ammo } end
    local function row_of(key)
        for i, r in ipairs(S.data) do if r.work == key then return i, r end end
    end
    local function sec_of(title)
        for i, r in ipairs(S.data) do
            if r.section and string.find(r[1], title, 1, true) then return i end
        end
    end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_workshop")
    local ig = row_of("last_granary")
    eq(ig ~= nil, true, "a lasting work's row")
    local hr = find("derpy_mr_row_" .. ig)
    for k, g in ipairs(gran) do
        local u, n = find_uicomponent(hr, "use" .. k), find_uicomponent(hr, "pn" .. k)
        eq(u.visible and u.image, good_icon(g.stem), "good " .. k .. "'s icon")
        eq(u.x, hr.x + LL.VIEWS.workshop[3][1] + (k - 1) * LL.PRICE_PITCH, "the pairs from column 3, a pitch apart")
        eq(n.visible, true, "its amount shown"); eq(n.x, u.x + LL.ICON_PITCH, "after its icon")
    end
    eq(find_uicomponent(hr, "pn2").text, "[[col:red]]120[[/col]]", "a short good's amount red")
    eq(find_uicomponent(hr, "pn1").text, "120", "a covered one plain")
    eq(find_uicomponent(hr, "use2").shader, "set_greyscale_t0", "a short good's icon grey")
    eq(find_uicomponent(hr, "use1").shader, "normal_t0", "a covered one's not")
    eq(cell(ig, 3).text .. cell(ig, 4).text, "", "no rare or bulk figures")
    eq(sendb(ig).tip, "Your stores hold 50 of 120 " .. S.name("salt") .. ".", "short: says which good")
    eq(string.find(S.data[ig].tip, "Your stores hold 50 of 120 " .. S.name("salt"), 1, true) ~= nil, true,
       "the tooltip lists each good")
    -- AN ARMY WORK: greyed with nothing selected and says so; with a lord selected it names him and aims
    local ia = row_of("army_ammo")
    eq(sendb(ia).disabled, true, "nothing selected: greyed")
    eq(sendb(ia).tip, "Select one of your armies on the map first.", "says so")
    eq(sendb(row_of("trait_steel")).tip, "Select one of your lords or heroes on the map first.", "a trait says lord or hero")
    eq(sendb(row_of("trait_spice")).tip, "Select one of your lords on the map first.", "a lord's trait says lord")
    -- THE PREVIEW'S PICTURE: one row or more of every kind, with a lord selected
    WORK_ST.item_gromril_armour = { ok = true, rare = { have = 80, cost = 40 }, bulk = { have = 200, cost = 150 } }
    WORK_ST.conv_oathgold = { ok = true, goods = { { stem = "gold_idols", have = 90, cost = 30 },
                                                   { stem = "silver", have = 12, cost = 30 } } }
    WORK_ST.army_forge = function(cqi) return { ok = cqi ~= nil, why = not cqi and "aim" or nil,
        goods = { { stem = "iron", have = 300, cost = 50 }, { stem = "coal", have = 300, cost = 50 } } } end
    WORK_ST.trait_spice = function(cqi) return { ok = cqi ~= nil, why = not cqi and "aim" or nil,
        goods = { { stem = "spices", have = 60, cost = 60 }, { stem = "incense", have = 70, cost = 60 } } } end
    WORK_ST.last_arsenal = { ok = true, goods = { { stem = "iron", have = 300, cost = 150 }, { stem = "coal", have = 300, cost = 150 },
                                                  { stem = "brass", have = 160, cost = 150 }, { stem = "blackpowder", have = 150, cost = 150 } } }
    WORK_ST.research = { ok = true, bulk = { have = 500, cost = 300 } }
    SEL = 91; click("derpy_mr_tab_goods"); click("derpy_mr_tab_workshop")
    dump("workshop")   -- the preview draws every kind (overwrites the rare-only dump)
    ia = row_of("army_ammo")
    eq(string.find(S.data[ia].tip, "Applies to: Karl Franz", 1, true) ~= nil, true, "names the selected lord")
    eq(sendb(ia).disabled, false, "and can be bought")
    press(sendb(ia)); eq(WREQ[#WREQ], LOCAL .. "|aim|army_ammo|91", "Buy aims at him")
    -- STAGE 2 FINAL REVIEW: another army selected since the draw - no purchase on the old one
    local n0 = #WREQ
    SEL = 92; press(sendb(ia)); eq(#WREQ, n0, "the selection moved since the draw: nothing bought")
    eq(S.data[ia].aim, 92, "and the rows are drawn again for the new one")
    SEL = 91; fire("CharacterSelected", {}); eq(S.data[ia].aim, 91, "selecting on the map redraws the rows")
    local spice0 = WORK_ST.trait_spice
    WORK_ST.trait_spice = function(cqi) return { ok = false, why = cqi and "not_lord" or "aim", goods = ammo } end
    fire("CharacterSelected", {})
    eq(sendb(row_of("trait_spice")).disabled, true, "a hero selected: a lord's trait greyed")
    eq(sendb(row_of("trait_spice")).tip, "Only a lord can take this.", "and says why")
    WORK_ST.trait_spice = spice0
    local rare_row = find("derpy_mr_row_" .. ia)
    eq(find_uicomponent(rare_row, "pn3").visible, false, "two goods: the third pair hidden")
    -- FOLDING: a section's click hides its kind and says so
    click("derpy_mr_row_" .. sec_of("Works that last"))
    eq(row_of("last_granary"), nil, "folded: its rows hidden")
    eq(string.find(S.data[sec_of("Works that last")][1], S.FOLDED, 1, true) ~= nil, true, "the section says so")
    eq(row_of("army_ammo") ~= nil, true, "other kinds stay")
    click("derpy_mr_row_" .. sec_of("Works that last")); eq(row_of("last_granary") ~= nil, true, "unfolded again")
    eq(#ERRORS, 0, "no errors: " .. table.concat(ERRORS, "; "))
    FACTIONS.fac_a, DERPY_MR_FLOWS, cm.get_campaign_ui_manager = realm0, flows0, cuim0
    CHARS[91] = nil
end)()

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

-- EVERY TAB IS PLACED (seen in game 2026-10-03: Spending and Map sat in the panel's top corner,
-- because the layout named three tabs by hand), and every component directly under the panel was
-- moved there by the script on every tab: the engine ignores a runtime component's XML offsets.
click("derpy_mr_close"); click("derpy_mr_stores_button")
local pv = find("derpy_mr_stores_panel")
eq(pv.visible, true, "open for the placement check")
for view, name in pairs(S.TAB) do
    local tc, tb = find(name), L0["tab_" .. view]
    eq(tc.x - pv.x, tb[1], name .. " placed across"); eq(tc.y - pv.y, tb[2], name .. " placed down")
end
for view, name in pairs(S.TAB) do
    click(name)
    for _, k in ipairs(pv.kids) do
        if k.visible and not k.moved then eq(k.name, "a placed component", "left at the XML's place on " .. view) end
    end
end

eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))
print("harness ok")
