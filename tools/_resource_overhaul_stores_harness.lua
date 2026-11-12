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
    -- AND CA'S QUEUE: core.event_listeners[event] is the list lib_core's dispatcher walks in
    -- order, so a test can ask where in it a listener sits.
    event_listeners = {},
    add_listener = function(self, name, event, cond, fn)
        LISTENERS[#LISTENERS + 1] = { event = event, cond = cond, fn = fn }
        self.event_listeners[event] = self.event_listeners[event] or {}
        table.insert(self.event_listeners[event], { name = name, condition = cond, callback = fn })
    end,
}

dofile("__SCRIPT__")
local S = DERPY_MR_STORES
assert(type(S.army_button_poll) == "function", "selected-lord provisions button is missing")

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
eq(realm[1].made_known, true, "successful production read is known")
eq(realm[3].made_known, nil, "failed production read stays unknown")
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
-- TRANSLATION (2026-11-08): a loc row replaces the English with its placeholders in its own order, and
-- the view carries it; with no row the English is back
do
    local key = DERPY_MR_LOC_KEYS["{1} of {2}"]
    eq(type(key), "string", "the template has a loc key")
    LOC[key] = "[{2}] <- {1}"; S.T_CACHE = {}
    eq(S.view_model(realm).rows[1][5], "[3] <- 2", "a translation draws, its placeholders reordered")
    LOC[key] = nil; S.T_CACHE = {}
    eq(S.view_model(realm).rows[1][5], "2 of 3", "no loc row: the English")
    -- the game trims a loc string's leading spaces (2026-11-10: "It eats 4provisions a turn")
    local pk = DERPY_MR_LOC_KEYS[" provisions"]
    LOC[pk] = "provisions"; S.T_CACHE = {}
    eq(S.T(" provisions"), " provisions", "a loc string the game trimmed gets its leading space back")
    LOC[pk] = nil; S.T_CACHE = {}
    -- THE HISTORY LINE'S WORDS (a translator's report, 2026-11-10): "made", "spoiled" and the rest were bare English
    for _, w in ipairs({ { "made", "made", "+1" }, { "raided", "raided_in", "+1" }, { "plundered", "plundered_in", "+1" },
                         { "traded in", "traded_in", "+1" }, { "traded out", "traded_out", "-1" }, { "eaten", "eaten_out", "-1" },
                         { "spoiled", "spoiled_out", "-1" }, { "moved", "moved_in", "+1" }, { "spent", "spent_out", "-1" },
                         { "sold", "sold_out", "-1" } }) do
        local wk = DERPY_MR_LOC_KEYS[w[1]]
        eq(type(wk), "string", "the history word '" .. w[1] .. "' has a loc key")
        if wk then
            LOC[wk] = "<" .. w[1] .. ">"; S.T_CACHE = {}
            eq(S.last_line({ [w[2]] = 1 }), "Last turn: <" .. w[1] .. "> " .. w[3], "'" .. w[1] .. "' draws translated")
            LOC[wk] = nil; S.T_CACHE = {}
        end
    end
end
eq(v.rows[3][2], "0", "made, nothing held yet")
S.focus = "coal"; v = S.view_model(realm)
eq(v.title, "Where Coal is kept", "drill-down title")
eq(v.rows[1][1], "Bravo", "by settlement"); eq(v.rows[1][2], "200 / 200 [[col:red]]Full[[/col]]", "held / space carries the full mark")
eq(v.rows[1][4], "-", "no price without the flows script"); eq(v.rows[1].tip, S.FULL_TIP, "full tooltip")
eq(v.rows[2][2], "100 / 400", "not full: no mark")
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
function UIC:NumStates() return 3 end
function UIC:GetStateByIndex(i) return ({"standard","hover","selected"})[i+1] end
function UIC:SetTooltipText(t) self.tip = t end
function UIC:SetTextHAlign(a) self.halign = a end
function UIC:SetTextVAlign(a) self.valign = a end
-- not the panel's own 6.5 a letter, so a name spaced by that budget instead of measured shows up
function UIC:WidthOfTextLine(t) return math.ceil(string.len(t or "") * 7.25) end
function UIC:SetOpacity(o) self.opacity = o end
function UIC:SetDisabled(v) self.disabled = v end
function UIC:IsDragged() return self.dragged == true end
function UIC:ShaderTechniqueSet(t) self.shader = t end
function UIC:ShaderVarsSet(a, b, c, d) self.vars = { a, b, c, d } end
function UIC:SetImagePath(p, i) self.image = p; self.images = self.images or {}; self.images[i or 0] = p end
function UIC:SetImageRotation(i, r) self.rot = self.rot or {}; self.rot[i] = r end
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
                               c.halign or "", (c.rot or {})[0] or 0 },
                             "\t"), "\n")
        for _, k in ipairs(c.kids) do walk(k, depth + 1) end
    end
    walk(find("derpy_mr_stores_panel"), 0)
    f:close()
end

-- ANOTHER MOD'S CLICK LISTENER WHOSE CONDITION THROWS, queued before the first tick as every
-- listener registered at load is (Great Guilds player report, 2026-10-09: "click sound, nothing
-- opens", and again after the first fix). core:event_callback tests every condition before it
-- calls any callback, unprotected, so this drops the whole click wherever ours sits in core's
-- queue. Straight into CA's queue, not LISTENERS, so fire() below never meets it.
-- events.ComponentLClickUp is the engine's list, with core's dispatcher one entry of it.
events = { ComponentLClickUp = { function(context)
    local go = {}
    for _, l in ipairs(core.event_listeners.ComponentLClickUp) do
        if l.condition == true or l.condition(context) then go[#go + 1] = l end
    end
    for _, l in ipairs(go) do l.callback(context) end
end } }
core.event_listeners.ComponentLClickUp = core.event_listeners.ComponentLClickUp or {}
table.insert(core.event_listeners.ComponentLClickUp,
             { name = "stranger_throws", callback = function() end, condition = function()
                 if STRANGER_THROWS then error("another mod's click condition") end
                 return false
             end })

-- the opener: made at first tick, right of the resource strip and centred on it
for _, fn in ipairs(FIRST) do fn() end

do
    -- the engine's pass, in list order; a throw ends it, the worst case
    -- then a click the stranger lets through: a copy left in core's queue would run it twice
    local seen, real = 0, S.click
    S.click = function() seen = seen + 1 end
    for _, throws in ipairs({ true, false }) do
        STRANGER_THROWS, seen = throws, 0
        pcall(function()
            for _, fn in ipairs(events.ComponentLClickUp) do fn({ string = "derpy_mr_close" }) end
        end)
        eq(seen, 1, "a click reaches the stores click exactly once, stranger throwing: " .. tostring(throws))
    end
    S.click = real
end
local b = find("derpy_mr_stores_button")
eq(b ~= false, true, "button made"); eq(b.x, 1454, "right of the strip"); eq(b.y, 2, "centred on it")
eq(b.visible, true, "shown once placed")
bar.w = 1100; REPEATS.derpy_mr_follow_bar(); eq(b.x, 1535, "follows the strip's end")
b.visible = false; REPEATS.derpy_mr_follow_bar()
eq(b.visible, false, "the follow never re-shows: the hub hides it off the main screen"); b.visible = true
bar.y = -600; REPEATS.derpy_mr_follow_bar(); eq(b.x, 1535, "a strip sliding away is ignored")
eq(b.y, 2, "a strip sliding away leaves the button where it was")
bar.y = -40; REPEATS.derpy_mr_follow_bar(); eq(b.y, 0, "a strip just above the screen clamps the button onto it")
bar.y = -4
unlink(bar); eq(S.anchor(), nil, "no strip, no anchor"); REPEATS.derpy_mr_follow_bar()
eq(b.x, 1535, "and the button stays put"); bar.parent = UI_ROOT; UI_ROOT.kids[#UI_ROOT.kids + 1] = bar
-- THE RETRIES RAN OUT (2026-11-04: an opening screen kept the strip away past all 150): the follow places it
S.placed, b.visible = false, false; unlink(bar); REPEATS.derpy_mr_follow_bar()
eq(b.visible, false, "no strip yet, so still hidden")
bar.parent = UI_ROOT; UI_ROOT.kids[#UI_ROOT.kids + 1] = bar; REPEATS.derpy_mr_follow_bar()
eq(S.placed, true, "the follow places a button the retries gave up on")
eq(b.visible, true, "and shows it"); eq(b.x, 1535, "at the strip's end")
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
eq(find_uicomponent(find("derpy_mr_row_1"), "vline4").visible, true, "a line before the Price column")
eq(find_uicomponent(find("derpy_mr_row_1"), "vline5").visible, false, "none before a column without one")
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
-- ENDING THE TURN CLOSES IT (author, 2026-11-01: it stayed open through the computers' turns)
fire("FactionTurnEnd", { faction = function() return faction("fac_b", {}) end })
eq(p.visible, true, "another faction's turn end leaves it open")
fire("FactionTurnEnd", { faction = function() return FACTIONS.fac_a end })
eq(p.visible, false, "the player's turn end closes it"); eq(p.interactive, false, "and lets the mouse through")
click("derpy_mr_stores_button"); eq(p.visible, true, "reopened")
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
-- SPOILAGE (2026-11-01): its own part of the line, and a line of every part still fits
eq(S.last_line({ made = 40, eaten_out = 20, spoiled_out = 6 }), "Last turn: made +40, eaten -20, spoiled -6", "what spoiled")
local every = S.last_line({ made = 123456, raided_out = 123456, plundered_out = 123456, traded_in = 123456,
                            traded_out = 123456, eaten_out = 123456, spoiled_out = 123456, moved_out = 123456,
                            spent_out = 123456, sold_out = 123456 })
eq(#every * L.CHAR_W <= L.chart_line[3], true, "every part at once still fits: " .. every)
eq(string.sub(every, -5), ", ...", "and says it left some out")
eq(S.spoil_sentence({ rate = 4, keep = 250, due = 6 }, "Grain"),
   "Grain over 250 spoils at 4% a turn and about 6 will spoil next turn.", "the spoiling sentence")
eq(S.spoil_sentence({ rate = 4, keep = 250, due = 0 }, "Grain"), "Grain over 250 spoils at 4% a turn.", "with nothing due")
eq(S.spoil_sentence(nil, "Salt"), nil, "a good that keeps says nothing")

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
eq(cell(1, 5).text, "sent 15 and received 2", "last turn's trade"); eq(cell(2, 5).text, "-", "no trade last turn")
local brim = "pooled_resources_display_name_derpy_mr_store_brimstone"
LOC[brim] = "Zz Brimstone"; click("derpy_mr_tab_trade")
eq(cell(2, 1).text, "Zz Brimstone", "a good you make comes before every good you do not, whatever its name")
LOC[brim] = "Brimstone"; click("derpy_mr_tab_trade")
press(switch(1, "export"))
eq(SENT[1], "fac_a|export|coal", "a click sends the local faction's switch")
eq(switch(1, "export").images[0], S.CHECK[false][1], "and the box empties at once")
eq(string.find(switch(1, "export").tip, "trade it again", 1, true) ~= nil, true, "the tooltip says a click trades it again")
press(switch(2, "import")); eq(SENT[2], "fac_a|import|brimstone", "the row's own good (then by name)")
press(find_uicomponent(find("derpy_mr_row_1"), "c3")); eq(#SENT, 2, "a cell named like ours elsewhere is not a switch")
-- a greyed row's name cell carries grey markup; its switch's tooltip names the good plainly
eq(string.find(cell(4, 1).text, "[[col:", 1, true) ~= nil, true, "row 4 is a greyed good")
eq(string.find(switch(4, "import").tip, "[[col:", 1, true), nil, "its Imports tooltip carries no colour markup")
-- Dedicated row controls use requests and re-read the current policy at click time.
;(function()
    local fl = DERPY_MR_FLOWS
    local policy, requests = {}, {}
    fl.capital = function() return A end
    fl.stock_view = function(f, r) return { faction = f, region = r, policy = { coal = policy },
        auto_keep = { war = 105 }, auto_target = { war = 200 }, work_target = {}, capacity = { coal = 400 },
        held = { coal = 100 }, incoming = {}, totals = { war = 100 }, due = {} } end
    fl.import_need = function() return 100 end
    fl.request = function(fk, action, stem, field, value)
        eq(fk, LOCAL, "policy request faction"); eq(action, "stock", "policy action")
        eq(stem, "coal", "policy good")
        requests[#requests + 1] = field .. "|" .. value
        policy[field] = value ~= "auto" and tonumber(value) or nil
    end
    click("derpy_mr_row_1")
    eq(find("sub_title").text, "Stock rules: Coal", "Trade row opens stock rules")
    eq(S.view_key(), "trade_focus", "own policy columns")
    eq(cell(1, 2).text, "Auto: 105", "resolved shared Auto")
    eq(string.find(S.data[1].tip, "covers all common", 1, true) ~= nil, true, "category explanation")
    local function pb(i, action) return find_uicomponent(find("derpy_mr_row_" .. i), "derpy_mr_policy_" .. action) end
    eq(pb(1, "plus").visible, true, "policy button visible")
    eq(pb(3, "plus").visible, false, "other row hides policy controls")
    -- the price the trade rule reads, and a target tip that says the rule
    local priced
    fl.quote = function(f, r, stem) eq(r, A, "the capital's own quote"); eq(stem, "coal", "of this good"); return priced end
    S.refresh()
    eq(S.data[6][1], "Price at capital", "the capital's price follows the import need"); eq(S.data[6][2], "-", "no quote shows a dash")
    priced = { price = 321 }; S.refresh()
    eq(S.data[6][2], "3.21", "the price in gold to the hundredth")
    eq(S.data[6].tip, "Partners only send it while it sells for at least 10% more here than at home.", "and its tip says the rule")
    eq(string.find(S.data[2].tip, "Your trade partners send it to " .. S.place("reg_a")
        .. " until you have this much.\nSet it to 0 to stop them.", 1, true) == 1, true, "the target tip says the same")
    dump("trade_focus")
    press(pb(1, "minus")); eq(policy.keep, 100, "Auto minus rounds down to ten")
    press(pb(1, "auto")); eq(policy.keep, nil, "Auto reset")
    press(pb(1, "plus")); eq(policy.keep, 110, "Auto plus rounds up to ten")
    policy.keep = 0; S.refresh(); eq(cell(1, 2).text, "0", "explicit zero differs from Auto")
    press(pb(1, "minus")); eq(policy.keep, 0, "zero clamp")
    policy.keep = 1000000; press(pb(1, "plus")); eq(policy.keep, 1000000, "upper clamp")
    local count = #requests
    S.view_model(S.read_realm(FACTIONS.fac_a)); S.view_model(S.read_realm(FACTIONS.fac_a))
    eq(#requests, count, "repeated reads do not write")
    click("derpy_mr_back"); eq(S.focus, nil, "Back returns to Trade")
    eq(pb(1, "plus").visible, false, "ordinary rows hide policy buttons")
    press(pb(1, "plus")); eq(#requests, count, "stale control cannot write")
    fl.capital, fl.stock_view, fl.import_need, fl.request, fl.quote = nil, nil, nil, nil, nil
end)()
-- THE SECTION ROW FOLDS: a click hides the resources you do not have, another shows them again
eq(find("derpy_mr_row_3").tip, S.FOLD_TIP[false], "the section row says a click hides them")
local function arrow(i) return find_uicomponent(find("derpy_mr_row_" .. i), "fold") end
eq(arrow(3).visible, true, "a foldable section row carries an arrow")
eq(arrow(3).rot[0], 0, "open: it points down, as drawn")
eq(arrow(1).visible, false, "a resource row has none")
click("derpy_mr_row_3"); eq(shown_rows(), 3, "folded: your two resources and the section row")
eq(cell(3, 1).text, S.section("Resources you do not have (" .. others .. ")"), "the text stays as it was")
eq(arrow(3).rot[0], math.pi * 3 / 2, "folded: it points right (CA's rotation is clockwise, lib_text_pointers)")
eq(find("derpy_mr_row_3").tip, S.FOLD_TIP[true], "and that a click shows them")
click("derpy_mr_close"); click("derpy_mr_stores_button"); eq(shown_rows(), 3, "kept folded while the campaign runs")
click("derpy_mr_row_3"); eq(shown_rows(), #DERPY_MR_STORES_GOODS + 1, "unfolded again")
eq(arrow(3).rot[0], 0, "and points down again")
-- THE TABLE'S BORDER: a full-strength frame round the header and the list, a rule under the header
do
    local t, b, l, r = find("derpy_mr_frame_t"), find("derpy_mr_frame_b"), find("derpy_mr_frame_l"), find("derpy_mr_frame_r")
    local L, hd, holder = DERPY_MR_STORES_L, find("hdr_1"), find("rows_holder")
    eq(t.visible and b.visible and l.visible and r.visible, true, "the table is framed")
    eq(t.y <= hd.y and t.x <= hd.x, true, "the frame's top edge is above the header")
    eq(b.y >= holder.y + L.list[4] - L.FRAME and l.x + L.FRAME <= holder.x, true, "and its bottom and left edges outside the list")
    eq(r.x >= holder.x + L.list[3] - L.FRAME, true, "its right edge outside the slider")
    local rule = find("derpy_mr_frame_head")
    eq(rule.visible, true, "a rule under the header")
    eq(rule.y >= hd.y + 20 and rule.y + L.FRAME <= holder.y, true, "between the header and the first row")
end
do
    -- IMPORT DUTY: a first row with last turn's gold each way, its partners in the tooltip
    local fl = DERPY_MR_FLOWS
    local pct, stores = 12, true                -- not the default 10: the tooltip must carry the rate
    fl.rates = function() return { duty = pct, reach = 7 } end   -- not the default 6: the tooltip must carry it
    fl.uses_stores = function(f) eq(f:name(), LOCAL, "asked of the local faction"); return stores end
    fl.duty_last = function(fk)
        eq(fk, LOCAL, "the local faction's duty"); return { paid = 11, got = 4, by = { fac_b = { paid = 11, got = 4 } } }
    end
    -- TRADE REACH: the partners whose agreement moves nothing, and why (flows.lua F.cut_off)
    local cut = { { key = "fac_c", why = "Too far for trade" }, { key = "fac_d", why = "Cut off by enemy lands" } }
    fl.cut_off = function(f) eq(f:name(), LOCAL, "cut off from the local faction"); return cut end
    -- CARGO ON THE ROAD (agreement convoys, flows.lua F.convoy_cargo): two of the local faction's out, one in, and a
    -- stranger's that is neither. The listing is the flows script's, every faction's: the panel picks the viewer's.
    CONVOYS = {
        { id = "derpy_mr_cv_1", f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 12, x = 150, y = 250,
          stem = "coal", n = 40, basket = { iron = 12, coal = 40 }, convoy = true },
        { id = "derpy_mr_cv_2", f = LOCAL, buyer = "fac_c", from = "reg_a", to = "reg_c", due = 13, x = 120, y = 280,
          stem = "brimstone", n = 5, basket = { brimstone = 5 }, convoy = true },
        { id = "derpy_mr_cv_3", f = "fac_b", buyer = LOCAL, from = "reg_b", to = "reg_a", due = 14, x = 250, y = 150,
          stem = "iron", n = 8, basket = { iron = 8, coal = 8 }, convoy = true },
        { id = "derpy_mr_cv_4", f = "fac_c", buyer = "fac_d", from = "reg_c", to = "reg_d", due = 15, x = 900, y = 900,
          stem = "coal", n = 99, basket = { coal = 99 }, convoy = true },
    }
    fl.convoy_cargo = function() return CONVOYS end
    click("derpy_mr_tab_trade")
    dump("trade")   -- the preview draws the tab with its duty, cut-off and cargo rows (overwrites the plain dump)
    eq(cell(1, 1).text, "Import duty", "the duty row comes first"); eq(cell(1, 5).text, "paid 11 and received 4", "both ways")
    eq(string.find(find("derpy_mr_row_1").tip, ": paid 11 and received 4", 1, true) ~= nil, true, "each partner in its tooltip")
    eq(string.find(find("derpy_mr_row_1").tip, "12%", 1, true) ~= nil, true, "with the rate")
    eq(switch(1, "export").visible or switch(1, "import").visible, false, "and no switches")
    eq(cell(2, 1).text, "Trade cut off", "then the partners cut off"); eq(cell(2, 5).text, "2 partners", "counted")
    local tip = find("derpy_mr_row_2").tip
    eq(string.find(tip, ": Too far for trade", 1, true) ~= nil and string.find(tip, ": Cut off by enemy lands", 1, true) ~= nil,
       true, "each with why"); eq(string.find(tip, "7 turns", 1, true) ~= nil, true, "and the reach")
    eq(switch(2, "export").visible or switch(2, "import").visible, false, "no switches on it either")
    eq(cell(3, 1).text, "Cargo on the road", "then what the convoys carry"); eq(cell(3, 5).text, "2 out and 1 in", "two out, one in, never the stranger's")
    local cargo_tip = find("derpy_mr_row_3").tip
    eq(string.find(cargo_tip, "From Alpha to Bravo by turn 12: 40 Coal, 12 Iron", 1, true) ~= nil, true,
       "each convoy: where from and to, when, and its basket, the most first")
    eq(string.find(cargo_tip, "From Bravo to Alpha by turn 14: 8 Coal, 8 Iron", 1, true) ~= nil, true, "the one coming in, equal amounts by name")
    eq(string.find(cargo_tip, "by turn 13: 5 Brimstone", 1, true) ~= nil, true, "and the other going out")
    eq(string.find(cargo_tip, "99 Coal", 1, true), nil, "and not a stranger's")
    eq(find_uicomponent(find("derpy_mr_row_3"), "icon").image, DERPY_MR_STORES_L.MAP_CART, "wearing the convoy icon the Map tab's key does")
    eq(switch(3, "export").visible or switch(3, "import").visible, false, "no switches on it either")
    eq(cell(4, 1).text, "Coal", "the goods follow")
    local all = CONVOYS
    CONVOYS = { all[3] }; click("derpy_mr_tab_trade"); eq(cell(3, 5).text, "0 out and 1 in", "none out is still said")
    CONVOYS = { all[1] }; click("derpy_mr_tab_trade"); eq(cell(3, 5).text, "1 out and 0 in", "and none in")
    -- A CONVOY WITH NO POSITION is on the road all the same: counted and listed here, drawn on no map
    local unplaced = { id = "derpy_mr_cv_5", f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 17,
                       stem = "coal", n = 3, basket = { coal = 3 }, convoy = true }
    CONVOYS = { unplaced }; click("derpy_mr_tab_trade")
    eq(cell(3, 1).text, "Cargo on the road", "a convoy with no position still has its row"); eq(cell(3, 5).text, "1 out and 0 in", "and is counted")
    eq(string.find(find("derpy_mr_row_3").tip, "From Alpha to Bravo by turn 17: 3 Coal", 1, true) ~= nil, true, "and listed in the tooltip")
    -- A BIG REALM: ten convoys out, the tooltip names the eight that land soonest and counts the rest
    fl.SHIP = { near = 4 }   -- not the real 3: the tooltip's number is shown to come from here
    CONVOYS = {}
    for i = 1, 10 do
        CONVOYS[i] = { id = "derpy_mr_cv_" .. (20 + i), f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 31 - i,
                       x = 150, y = 250, stem = "coal", n = i, basket = { coal = i }, convoy = true }
    end
    click("derpy_mr_tab_trade")
    local big = find("derpy_mr_row_3").tip
    local _, shown = string.gsub(big, "by turn", "")
    eq(cell(3, 5).text, "10 out and 0 in", "all ten counted"); eq(shown, 8, "eight named")
    eq(string.find(big, "by turn 21: 10 Coal", 1, true) ~= nil, true, "starting with the soonest")
    eq(string.find(big, "by turn 29", 1, true), nil, "the two that land last are not named")
    eq(string.sub(big, -#"and 2 more convoys"), "and 2 more convoys", "but counted")
    -- THE SEIZURE RULE as the flows script keeps it: the sender's enemy, near the convoy at the sender's turn start
    eq(string.find(big, "An army at war with the sender can seize these goods from within 4 hexes when the sender begins its turn.", 1, true) ~= nil,
       true, "the tooltip says who seizes it and from how near")
    -- EQUAL TURNS LIST IN THE ORDER THE CONVOYS LEFT: by the number in the id, not its text, where "10" sorts before "9"
    CONVOYS = {
        { id = "derpy_mr_cv_10", f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 20, x = 150, y = 250,
          stem = "iron", n = 6, basket = { iron = 6 }, convoy = true },
        { id = "derpy_mr_cv_9", f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 20, x = 150, y = 250,
          stem = "brimstone", n = 5, basket = { brimstone = 5 }, convoy = true },
    }
    click("derpy_mr_tab_trade")
    local tied = find("derpy_mr_row_3").tip
    eq(string.find(tied, "5 Brimstone", 1, true) < string.find(tied, "6 Iron", 1, true), true, "convoy 9 is listed before convoy 10")
    CONVOYS = {}; click("derpy_mr_tab_trade"); eq(cell(3, 1).text, "Coal", "nothing on the road, no row")
    fl.convoy_cargo = nil; click("derpy_mr_tab_trade"); eq(cell(3, 1).text, "Coal", "a flows script without convoy_cargo: no row, no error")
    cut = { cut[1] }; click("derpy_mr_tab_trade"); eq(cell(2, 5).text, "1 partner", "one is one partner")
    cut = {}; click("derpy_mr_tab_trade"); eq(cell(2, 1).text, "Coal", "nobody cut off, no row")
    fl.duty_last = function() return nil end; click("derpy_mr_tab_trade")
    eq(cell(1, 5).text, "paid 0 and received 0", "nothing booked yet reads as nothing")
    stores = false; click("derpy_mr_tab_trade"); eq(cell(1, 1).text, "Coal", "no row for a faction that never pays it")
    stores, pct = true, 0; click("derpy_mr_tab_trade"); eq(cell(1, 1).text, "Coal", "no row while the duty is off")
    fl.rates, fl.duty_last, fl.uses_stores, fl.cut_off, fl.SHIP = nil, nil, nil, nil, nil; click("derpy_mr_tab_trade")
end
do
    -- TOLLS AND BLOCKADES (Part C): last turn's tolls each way after Import duty, a blockaded partner among those
    -- cut off, and each convoy's tolls in the cargo tooltip
    local fl, f = DERPY_MR_FLOWS, FACTIONS[LOCAL]
    local partners = f.factions_trading_with
    local rate, book = 3, { paid = 30, got = 12, by = { fac_b = { paid = 30, got = 0 }, fac_c = { paid = 0, got = 12 } } }
    fl.rates = function() return { duty = 12, tolls = true, toll = rate, reach = 6, bandits = true } end
    fl.guards_on = function() return false end   -- the preview draws the Road guards row too (Part D)
    fl.uses_stores = function() return true end
    fl.duty_last = function() return { paid = 11, got = 4, by = { fac_b = { paid = 11, got = 4 } } } end
    fl.tolls_last = function(fk) eq(fk, LOCAL, "the local faction's tolls"); return book end
    fl.cut_off = function() return { { key = "fac_c", why = "Too far for trade" }, { key = "fac_d", by = "fac_b" } } end
    CONVOYS = { { id = "derpy_mr_cv_1", f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 12, x = 150, y = 250,
                  stem = "coal", n = 40, basket = { coal = 40 }, convoy = true, tolls = { fac_c = 12, fac_d = 30 } } }
    fl.convoy_cargo = function() return CONVOYS end
    f.factions_trading_with = function() return list({ faction("fac_b", {}) }) end
    click("derpy_mr_tab_trade")
    dump("trade")   -- the preview draws the tab with duty, tolls, cut-off and cargo rows (overwrites the plain dump)
    local function has(i, part) return string.find(find("derpy_mr_row_" .. i).tip, part, 1, true) ~= nil end
    eq(cell(1, 1).text, "Import duty", "the duty row first")
    eq(cell(2, 1).text .. "|" .. cell(2, 5).text, "Tolls paid|30 gold", "then the tolls paid")
    eq(cell(3, 1).text .. "|" .. cell(3, 5).text, "Tolls received|12 gold", "and received")
    eq(has(2, "Last turn you paid these factions to cross their lands.") and has(2, ": 30"), true, "each faction paid in its tooltip")
    eq(has(2, ": 12"), false, "and only those paid")
    eq(has(3, "Last turn these factions paid you to cross your lands.") and has(3, ": 12"), true, "each faction that paid you")
    eq(find_uicomponent(find("derpy_mr_row_2"), "icon").image, S.DUTY_ICON, "in the duty's icon")
    eq(cell(4, 1).text, "Trade cut off", "then the partners cut off")
    eq(has(4, "Nothing moves between you and these partners.") and has(4, ": Blockaded by "), true, "a blockaded partner says by whom")
    eq(has(4, ": Too far for trade") and has(4, "6 turns"), true, "beside the reach reasons")
    eq(has(5, "Tolls: 30 to ") and has(5, ", 12 to "), true, "a convoy's tolls, the most first")
    -- nothing booked: both rows at 0 while the rate is on and you have a partner
    book = { paid = 0, got = 0, by = {} }; click("derpy_mr_tab_trade")
    eq(cell(2, 5).text .. "|" .. cell(3, 5).text, "0 gold|0 gold", "nothing booked reads as nothing")
    f.factions_trading_with = function() return list({}) end; click("derpy_mr_tab_trade")
    eq(cell(2, 1).text, "Trade cut off", "no partner and nothing booked: no toll rows")
    f.factions_trading_with = function() return list({ faction("fac_b", {}) }) end
    rate = 0; click("derpy_mr_tab_trade")
    eq(cell(2, 1).text, "Trade cut off", "tolls off and nothing booked: no toll rows")
    book = { paid = 7, got = 0, by = { fac_b = { paid = 7, got = 0 } } }; click("derpy_mr_tab_trade")
    eq(cell(2, 1).text .. "|" .. cell(3, 1).text, "Tolls paid|Trade cut off", "tolls off but paid last turn: that row only")
    f.factions_trading_with = partners
    fl.rates, fl.duty_last, fl.uses_stores, fl.cut_off, fl.tolls_last, fl.convoy_cargo = nil, nil, nil, nil, nil, nil
    fl.guards_on = nil
    CONVOYS = {}; click("derpy_mr_tab_trade")
end
do
    -- ROAD GUARDS (Part D 7.4): the player's switch on the Trade tab while the bandits are on
    local fl, on, sent = DERPY_MR_FLOWS, false, {}
    local req = fl.request
    fl.rates = function() return { duty = 0, bandits = true } end
    fl.uses_stores = function() return true end
    fl.guards_on = function(fk) eq(fk, LOCAL, "the local faction's guards"); return on end
    fl.request = function(_, ...) sent[#sent + 1] = table.concat({ ... }, ",") end
    local function guards()
        for i, rc in ipairs(S.data) do
            if rc[1] == "Road guards" then return i, rc, find_uicomponent(find("derpy_mr_row_" .. i), S.SEND) end
        end
    end
    click("derpy_mr_tab_trade")
    local i, rc, b = guards()
    eq(rc ~= nil and rc[2], "Off", "a Road guards row, off")
    eq(b.visible and b.text, "Hire", "with a Hire button")
    eq(find("derpy_mr_row_" .. i).tip, "Guards ride with every cart and convoy you send.\nThey cost 5% of the cargo's value "
       .. "when it leaves.\nThey make trouble on the road half as likely.", "its tooltip says what they do and cost")
    local clock, now = os.clock, 100
    os.clock = function() return now end
    press(b); eq(table.concat(sent, ";"), "guards,on", "Hire asks for guards on")
    on = true; click("derpy_mr_tab_trade")
    i, rc, b = guards()
    eq(rc[2] .. "," .. b.text, "On,Dismiss", "guards on: Dismiss")
    -- A DOUBLE CLICK (seen 2026-11-03): the row redraws as Dismiss under the cursor, and the second click sent them away
    now = now + 0.2
    press(b); eq(#sent, 1, "a second click straight after: nothing more")
    now = now + 1
    press(b); eq(sent[#sent], "guards,off", "Dismiss asks for them off")
    os.clock = clock
    fl.rates = function() return { duty = 0, bandits = false } end; click("derpy_mr_tab_trade")
    eq(guards(), nil, "the bandits off: no row")
    fl.rates, fl.uses_stores, fl.guards_on, fl.request = nil, nil, nil, req
    click("derpy_mr_tab_trade")
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
-- ONE SENTENCE A LABEL (a translator's report, 2026-11-10): "Stop all " .. "export" .. "s" could not be translated
for _, t in ipairs({ "Allow all exports", "Stop all exports", "Allow all imports", "Stop all imports" }) do
    eq(type(DERPY_MR_LOC_KEYS[t]), "string", "'" .. t .. "' has a loc key of its own")
end
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
-- WHAT A SWITCH DOES, in its tooltip (Workshop, 2026-11-10: "how does the mod choose what to import? do these imports
-- cost me something?"): how a partner picks the good, that it is free, and that a switch stops your own carts too
do
    local function has(c, text) return string.find(c.tip or "", text, 1, true) ~= nil end
    eq(has(switch(1, "import"), "from the partner's cheapest store"), true, "an import box says how a partner picks it: " .. tostring(switch(1, "import").tip))
    eq(has(switch(1, "import"), "until your capital holds the wanted amount"), true, "and how much it sends")
    eq(has(switch(1, "import"), "The goods cost you nothing."), true, "and that it is free")
    eq(has(switch(1, "import"), "Your own carts stop carrying it at once."), true, "and what refusing it stops, at once")
    eq(has(switch(1, "export"), "Your own carts stop carrying it at once."), true, "an export box warns the same")
    eq(has(bulk("import", "stop"), "You and your partners still pay import duty."), true, "Stop all imports: duty is still paid, by both")
    eq(has(bulk("import", "stop"), "still come in"), false, "and no longer says imports still come in")
    eq(has(bulk("export", "stop"), "Your own carts stop carrying them at once."), true, "Stop all exports warns about your carts")
    press(switch(1, "import"))
    eq(has(switch(1, "import"), "You and your partners still pay import duty."), true, "a refused import: duty is still paid")
    eq(has(switch(1, "import"), "your own carts do not carry it"), true, "and your carts stop")
    eq(has(switch(1, "import"), "still come in"), false, "and no word of imports still coming in")
    press(switch(1, "import"))
    eq(switch(1, "import").images[0], S.CHECK[true][1], "the import box ticked again")
end
-- EVERY HEADER FITS ITS COLUMN, on every tab: a header that did not was shrunk by the engine
-- (seen in game 2026-10-02: "Space per good" in 100px). HEAD_CHAR_W is calibrated from that.
local saved_view, saved_focus = S.view, S.focus
local alpha_realm = S.read_realm(FACTIONS.fac_a)
for _, vf in ipairs({ { "goods" }, { "goods", "coal" }, { "settlements" }, { "settlements", "reg_a" }, { "trade" },
                     { "spending" }, { "map" }, { "production" } }) do
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

-- ---- TRADE EDICTS (design 2026-11-01 Part B): the Edicts section at the top of the Resources tab ----
-- EDICT_FLOWS(base): the flows script's edict answers over `base`; the size previews draw with it too.
EDICT_NOW, EDICT_WAIT, EDICT_SENT, EDICT_RACE, EDICT_ON, EDICT_EATS = {}, {}, {}, "emp", true, true
function EDICT_FLOWS(base)
    return setmetatable({
        edicts_on = function() return EDICT_ON end,
        uses_stores = function() return true end,
        eats = function() return EDICT_EATS end,
        race = function() return EDICT_RACE end,
        edict = function(fk, which)
            eq(fk, LOCAL, "the local faction's edict")
            return EDICT_NOW[which] or ({ rations = "normal", workshops = "balanced", roads = "tolled" })[which]
        end,
        edict_wait = function(_, which) return EDICT_WAIT[which] or 0 end,
        request = function(_, ...) EDICT_SENT[#EDICT_SENT + 1] = table.concat({ ... }, ",") end,
    }, { __index = base or {} })
end
;(function()   -- a function, not a do block: the main chunk is at its 200 locals
    DERPY_MR_FLOWS = EDICT_FLOWS(nil)
    click("derpy_mr_tab_goods")
    local function labels(i)
        local t = {}
        for _, c in ipairs(S.data[i].choices or {}) do t[#t + 1] = c.label end
        return table.concat(t, ",")
    end
    local function eb(i, j) return find_uicomponent(find("derpy_mr_row_" .. i), "derpy_mr_policy_" .. ({ "minus", "auto", "plus" })[j]) end
    eq(S.data[1][1], S.section("Edicts"), "the first row is the Edicts section")
    eq(S.data[1].section and not S.data[1].fold, true, "a section row that does not fold")
    eq(S.data[2][1] .. "|" .. S.data[2][2] .. "|" .. labels(2), "Rations|Ready|Plenty,Normal,Rationing", "Rations, ready, its three options")
    eq(S.data[2].choices[2].on, true, "Normal is the one in force")
    eq(S.data[2].choices[1].on or S.data[2].choices[1].off, false, "and Plenty can be chosen")
    eq(S.data[3][1] .. "," .. labels(3), "Workshops,Wartime,Balanced,Merchant", "then Workshops")
    eq(S.data[4][1] .. "," .. labels(4), "Roads,Open,Tolled,Closed", "then Roads")
    eq(S.data[5][1], S.section("Resources"), "and a Resources section above the goods")
    eq(S.data[6].open ~= nil, true, "the goods follow it")
    eq(eb(2, 1).text .. "," .. eb(2, 2).text .. "," .. eb(2, 3).text, "Plenty,Normal,Rationing", "each button is labelled with its option")
    eq(eb(2, 1).w .. "," .. eb(2, 2).w .. "," .. eb(2, 3).w, LL.EDICT_W .. "," .. LL.EDICT_W .. "," .. LL.EDICT_W, "at the edict width")
    eq(eb(2, 2).shader, "glow_pulse_t0", "the option in force glows")
    eq(eb(2, 1).shader .. "," .. tostring(eb(2, 1).disabled), "normal_t0,false", "a ready option is live")
    eq(eb(1, 1).visible or eb(5, 1).visible, false, "a section row has no buttons")
    eq(eb(2, 1).tip, "Settlements eat 3 provisions a turn for each level.\nGrowth +10 in every province.", "an option's tooltip says its effects")
    -- a waiting edict: its status, its other options greyed, and every tooltip says when
    EDICT_WAIT.roads, EDICT_NOW.roads = 4, "closed"
    S.refresh()
    eq(S.data[4][2], "Wait 4 turns", "Roads waits 4 turns")
    eq(S.data[4].choices[1].off and S.data[4].choices[2].off, true, "its two other options are off")
    eq(S.data[4].choices[3].on and not S.data[4].choices[3].off, true, "and Closed is in force")
    eq(eb(4, 1).shader .. "," .. tostring(eb(4, 1).disabled), "set_greyscale_t0,true", "a waiting option is greyed")
    for j = 1, 3 do
        local tip = S.data[4].choices[j].tip
        eq(string.sub(tip, -#"This edict can change again in 4 turns."), "This edict can change again in 4 turns.", "tooltip " .. j .. " says when")
    end
    EDICT_WAIT.roads = 1; S.refresh(); eq(S.data[4][2], "Wait 1 turn", "one turn is singular")
    -- a Chaos Dwarf viewer: Plenty gives control, not growth
    EDICT_RACE = "chd"; S.refresh()
    local plenty = S.data[2].choices[1].tip
    eq(string.find(plenty, "Control +2", 1, true) ~= nil and string.find(plenty, "Growth", 1, true) == nil, true, "a Chaos Dwarf's Plenty")
    EDICT_RACE = "emp"
    -- clicks: Rationing sends the change, the option in force and a waiting one send nothing
    EDICT_SENT = {}
    press(eb(2, 3)); eq(table.concat(EDICT_SENT, ";"), "edict,rations,rationing", "Rationing is asked for")
    EDICT_SENT = {}
    press(eb(2, 2)); press(eb(4, 1)); press(eb(4, 3))
    eq(#EDICT_SENT, 0, "the option in force and a waiting edict send nothing")
    -- POOLED ROWS: the same row's buttons go back to their own widths on a view with stock rules
    local v = S.view_model(S.read_realm(FACTIONS[LOCAL]))
    S.draw_rows(find("derpy_mr_stores_panel"), { { "a", "", "", "", "", policy = "keep", tip = "" },
        { "b", "", "", "", "", policy = "keep", tip = "" } }, v.heads, v.cols)
    eq(eb(2, 1).w .. "," .. eb(2, 2).w .. "," .. eb(2, 3).w, table.concat(LL.POLICY_W, ","), "a policy row sizes them back")
    eq(eb(2, 2).text .. "," .. eb(2, 2).shader, "Auto,normal_t0", "with its own label and no glow")
    -- a faction that does not eat has no Rations row
    EDICT_EATS = false; S.refresh()
    eq(S.data[2][1] .. "," .. S.data[3][1], "Workshops,Roads", "no Rations for a faction that does not eat")
    EDICT_EATS = true
    -- the switch off: no section at all
    EDICT_ON = false; S.refresh()
    eq(S.data[1].section == nil and S.data[1].open ~= nil, true, "with edicts off the goods come first")
    EDICT_ON, EDICT_WAIT, EDICT_NOW = true, {}, {}
    S.refresh()
    dump("goods")   -- the preview draws the tab with its Edicts section (overwrites the plain dump)
    DERPY_MR_FLOWS = nil
    eq(#ERRORS, 0, "edicts: no script errors")
end)()

-- ---- phase 7: the panel's actions ------------------------------------------------------
local REQ, PLAN, ORDER_ST, SALE, ACT_ON = {}, {}, {}, nil, true
local FOUND_ST = {}
local SUP_ON, SUPPLY_ST, SHIPS_TO, SHIP_N = true, nil, {}, 0
CAPS, SHIPS = {}, {}
DERPY_MR_FLOWS = {
    capitals = function(f) eq(f:name(), LOCAL, "the local faction's capitals"); return CAPS end,
    ships = function() return SHIPS end,
    convoy_cargo = function() return CONVOYS end,
    rates = function() return { actions = ACT_ON, supply = SUP_ON } end,
    SHIP = { turns = 2 },
    ship_count = function(fk) eq(fk, LOCAL, "the local faction's shipments"); return SHIP_N end,
    ship_cap = function(f) eq(f:name(), LOCAL, "the local faction's number"); return 3 end,
    ships_to = function(_fk, rk, stem) return (rk == "reg_a" and SHIPS_TO[stem]) or {} end,
    supply_state = function(_f, rk) if rk == "reg_a" then return SUPPLY_ST end return nil end,
    request = function(fk, ...) REQ[#REQ + 1] = fk .. "|" .. table.concat({ ... }, "|") end,
    send_plan = function(f, _rk, stem) eq(f:name(), LOCAL, "the local faction's plan"); return PLAN[stem] end,
    order_state = function(_, key) return ORDER_ST[key] end,
    found_state = function(f, rk) eq(f:name(), LOCAL, "the local faction's founding"); return FOUND_ST[rk] end,
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
-- The existing settlement rows also carry paid processing/service controls.
do
    local fl, owned_before = DERPY_MR_FLOWS, DERPY_MR_FLOWS.owned
    fl.owned = function(_f, key) if key == "reg_a" then return A end end
    fl.economy_rows = function(_f, region)
        eq(region:name(), "reg_a", "economy reads selected local settlement")
        return {
            { key = "brew", on = true, open = true, paid = true,
              definition = { label = "Brewing", cost = { grain = 12 }, output = { "beer", 8 } } },
            { key = "halls", on = false, open = true, ready = false, short = "Short of pipeweed",
              definition = { label = "Drinking halls", cost = { beer = 4, pipeweed = 1 },
                    benefit = "Province control +2", value = 2, effect = "wh_main_effect_public_order_events" } },
            { key = "weave", on = false, open = false, reason = "Needs an undamaged workshop",
              definition = { label = "Carpet weaving", cost = { silk = 8 }, output = { "carpets", 8 } } },
        }
    end
    S.refresh()
    -- A RECIPE'S INPUTS GET A ROW (Bilbo Bagins, 2026-11-12): Vitevo's biscuits needed salt it had none of
    local by = {}
    for _, row in ipairs(S.data) do if row.stem then by[row.stem] = row end end
    eq(by.grain ~= nil, true, "a running recipe's input gets a row with none held")
    eq(by.pipeweed ~= nil and by.beer ~= nil, true, "so do an open recipe's")
    eq(by.pipeweed.send ~= nil, true, "with Send here"); eq(by.pipeweed.open, "routes:reg_a:pipeweed", "and a regular supply")
    eq(by.silk, nil, "a recipe this settlement cannot run adds no row")
    eq(by.coal ~= nil and by.brimstone ~= nil, true, "the goods it holds and makes keep theirs")
    eq(S.data[2].economy, "brew", "recipe row retains validated key")
    eq(S.data[2].send.label, "Pause", "active recipe can pause")
    eq(S.data[3].send.label, "Enable", "service starts disabled")
    eq(S.data[3][2], "4 + 1 / turn", "recurring full basket shown")
    eq(string.find(S.data[2].tip, "Your buildings still make their usual goods") ~= nil, true, "additional batch explained")
    local n = #REQ
    press(sendb(2))
    eq(REQ[#REQ], LOCAL .. "|economy|reg_a|brew", "recipe button uses synchronized request door")
    eq(#REQ, n + 1, "one click sends one request")
    dump("economy")
    table.remove(REQ)
    fl.economy_rows, fl.owned = nil, owned_before
    S.refresh()
end
-- SPOILAGE on the drill-down: a spoiling good's row says what is safe and what goes next turn
do
    local fl = DERPY_MR_FLOWS
    local owned_before = fl.owned
    fl.owned = function(_f, key) if key == "reg_a" then return A end end
    fl.spoil_info = function(_f, region, stem)
        eq(region:name(), "reg_a", "asked about the settlement on screen")
        if stem == "coal" then return { rate = 4, keep = 250, due = 6 } end
    end
    S.refresh()
    local coal, other
    for _, row in ipairs(S.data) do
        if row.stem == "coal" then coal = row elseif row.stem then other = row end
    end
    eq(string.find(coal.tip, "Coal over 250 spoils at 4% a turn and about 6 will spoil next turn.", 1, true) ~= nil, true,
       "the row says it: " .. coal.tip)
    eq(string.find(other.tip, "spoils", 1, true), nil, "a good that keeps says nothing")
    fl.spoil_info, fl.owned = nil, owned_before
    S.refresh()
end
-- A TRADE SWITCH GREYS SEND HERE AND SAYS WHY (2026-11-10): flows.lua F.send_plan has no plan, and the tooltip names
-- the switch rather than blaming the stores
do
    local fl, plan = DERPY_MR_FLOWS, PLAN.coal
    local function coal_send()
        for _, row in ipairs(S.data) do if row.stem == "coal" then return row.send end end
    end
    PLAN.coal = nil; S.refresh()
    eq(string.find(coal_send().tip, "trade switches", 1, true), nil, "no switch: another reason")
    fl.stopped = function(fk, dir, stem) eq(fk, LOCAL, "the local faction's switch"); return dir == "import" and stem == "coal" end
    S.refresh()
    eq(coal_send().off, true, "a switched-off good cannot be sent")
    eq(string.find(coal_send().tip, "Your trade switches stop carts carrying Coal.", 1, true) ~= nil, true,
       "and the button says it is the switch: " .. coal_send().tip)
    fl.stopped = function(_fk, dir, stem) return dir == "export" and stem == "coal" end
    S.refresh()
    eq(string.find(coal_send().tip, "Your trade switches stop carts carrying Coal.", 1, true) ~= nil, true, "the export switch too")
    fl.stopped, PLAN.coal = nil, plan
    S.refresh()
end
-- WHAT USES A STORE (Workshop, 2026-11-10: "what exactly consumes my food?"): the forecast tooltip names each part of
-- the "uses" figure, and they add up to it (4 + 5 + 2 + 1 = 12). Iron's production is war materials, not food.
do
    local fl = DERPY_MR_FLOWS
    local saved = { fl.stock_view, fl.stock_forecast, fl.need }
    local rec = { provisions = 12, meals = 4, army_need = 5, supplied = { provisions = 2 }, named = { grain = 1, iron = 3 } }
    local fc = { held = 100, use_per_turn = 12, spoil = 0, mode = "stored", cover = 8 }
    fl.stock_view = function(_f, region) eq(region:name(), "reg_a", "the settlement asked about"); return { recurring = rec, due = {} } end
    fl.stock_forecast = function() return { provisions = fc } end
    fl.need = function(fk) eq(fk, LOCAL, "the local faction's rations"); return 2 end
    local function has(tip, text) return string.find(tip, text, 1, true) ~= nil end
    local tip = S.forecast_tip(S.local_faction(), A, nil, "provisions")
    eq(has(tip, "The settlement itself eats 4 of that each turn, 2 for each settlement level."), true, "its own meals: " .. tip)
    eq(has(tip, "Armies refilling here take 5 of that each turn."), true, "the armies")
    eq(has(tip, "Province supplies take 2 of that each turn."), true, "the province supplies")
    eq(has(tip, "Production here takes 1 of that each turn."), true, "this category's production only")
    fc.use_per_turn = 0
    tip = S.forecast_tip(S.local_faction(), A, nil, "provisions")
    eq(has(tip, "of that each turn"), false, "nothing used: no parts")
    fl.stock_view, fl.stock_forecast, fl.need = saved[1], saved[2], saved[3]
end
-- WHAT A SETTLEMENT EATS (Workshop, 2026-11-10: "does every settlement consume something, and how much?"): the
-- Settlements list's tooltip, from flows.lua F.settlement_meals; Alpha is level 2, so the stub's 2 a level makes 4
do
    local fl = DERPY_MR_FLOWS
    local view, focus = S.view, S.focus
    fl.settlement_meals = function(f, level) eq(f:name(), LOCAL, "the local faction's meals"); return 2 * level end
    fl.need = function() return 2 end
    S.view, S.focus = "settlements", nil
    local function alpha_tip()
        for _, row in ipairs(S.view_model(S.read_realm(FACTIONS.fac_a)).rows) do
            if row.open == "reg_a" then return row.tip end
        end
    end
    eq(string.find(alpha_tip(), "It eats 4 provisions a turn, 2 for each settlement level.", 1, true) ~= nil, true,
       "Alpha's row says what it eats: " .. alpha_tip())
    fl.settlement_meals, fl.need = function() return 1 end, function() return 1 end
    eq(string.find(alpha_tip(), "It eats 1 provision a turn, 1 for each settlement level.", 1, true) ~= nil, true,
       "one meal is singular: " .. alpha_tip())
    fl.settlement_meals = function() return 0 end
    eq(string.find(alpha_tip(), "It eats", 1, true), nil, "a settlement that eats nothing says nothing")
    -- AN UNCHARTED SETTLEMENT SAYS WHY IT MAKES NOTHING (faction flavour design 2026-11-11, section 7)
    local line, charted0 = "Its buildings make no goods yet. It grows its own food, and other goods come by trade.", fl.charted
    fl.charted = function(k) return k ~= "reg_a" end
    eq(string.find(alpha_tip(), line, 1, true) ~= nil, true, "an uncharted settlement says why: " .. alpha_tip())
    fl.charted = function() return true end
    eq(string.find(alpha_tip(), line, 1, true), nil, "a charted settlement does not")
    fl.charted = nil
    eq(string.find(alpha_tip(), line, 1, true), nil, "nor with a flows script that cannot tell")
    fl.charted = charted0
    fl.settlement_meals, fl.need = nil, nil
    S.view, S.focus = view, focus
    S.refresh()
end
-- A RECIPE'S STATE, the word both views show: the economy's own verdict, never a guess
eq(S.economy_status({ on = true, open = true, paid = true }), "Paid", "paid this turn")
eq(S.economy_status({ on = true, open = true, ready = true }), "Next turn", "will pay next turn")
eq(S.economy_status({ on = true, open = true, ready = false, short = "Short of iron" }), "Short", "on but short")
eq(S.economy_status({ on = true, open = true, ready = false, short = "Output store full" }), "Store full", "nowhere to put it")
eq(S.economy_status({ on = false, open = true, ready = true }), "Off", "not ordered")
eq(S.economy_status({ on = false, open = false, reason = "Needs an undamaged workshop" }), "No workshop", "cannot run here")
eq(S.economy_status({ on = true, open = false, reason = "Province capital only" }), "Capital only", "ordered, can no longer run")
eq(S.economy_status({ on = true, open = false, reason = "a reason nobody wrote a word for" }), "Paused", "an unknown reason, ordered")

-- THE PRODUCTION TAB (asked 2026-10-30): a section per recipe, the settlements that can run it under
-- it. The world is the hardest the economy hands it: two inputs short where admission names only the
-- first, a recipe left on where it can no longer run, a recipe no settlement can run, and a service
-- in three settlements.
do
    local fl = DERPY_MR_FLOWS
    local saved = { owned = fl.owned, economy_rows = fl.economy_rows, economy_view = fl.economy_view,
                    available_stock = fl.available_stock, race = fl.race }
    for k, v in pairs({ tools = "Tools", timber = "Timber", cloth = "Cloth", leather = "Leather", medicine = "Medicine" }) do
        LOC["pooled_resources_display_name_derpy_mr_store_" .. k] = v
    end
    LOC.building_culture_variants_name_wh3_dlc23_chd_tower_furnace_1 = "Cinerator"
    LOC.building_culture_variants_name_wh3_dlc23_chd_tower_furnace_2 = "Great Cinerator"
    LOC.building_culture_variants_name_wh3_dlc23_chd_factory_assembly_line_1 = "Gunsmith"
    LOC.building_culture_variants_name_wh_main_dwf_industry_1 = "Trinket Maker"
    local TOOLS = { label = "Toolmaking", kind = "processing", cost = { iron = 6, timber = 2 }, output = { "tools", 8 } }
    local POWDER = { label = "Powder mixing", kind = "processing", cost = { brimstone = 4, coal = 8 },
                     output = { "blackpowder", 8 },
                     levels = { wh3_dlc23_chd_tower_furnace_1 = true, wh3_dlc23_chd_tower_furnace_2 = true,
                                wh3_dlc23_chd_factory_assembly_line_1 = true, wh_main_dwf_industry_1 = true } }
    local BUILD = { label = "Builders' yards", kind = "services", cost = { tools = 2, cloth = 1 }, value = -5,
                    benefit = "Province construction cost -5%", effect = "wh_main_effect_building_construction_cost_mod_all",
                    icon = "construction.png" }
    local MESS = { label = "Factory mess", kind = "services", cost = { salted_meat = 3, beer = 2 }, value = 2,
                   benefit = "Province control +2", effect = "wh_main_effect_public_order_events",
                   icon = "public_order_happy.png" }
    local HOSP = { label = "Field hospitals", kind = "services", cost = { cloth = 2, leather = 1, medicine = 1 }, value = 3,
                   benefit = "Own armies in the province: replenishment +3%",
                   effect = "wh_main_effect_force_all_campaign_replenishment_rate", icon = "replenishment.png" }
    local WORKSHOP, CAPITAL = "Needs an undamaged workshop", "Province capital only"
    local function st(key, d, t) t.key, t.definition = key, d; return t end
    -- what F.economy_rows hands back for each settlement, in its own key order
    local ROWS = {
        reg_a = { st("builders", BUILD, { open = true, on = true, paid = true, ready = true }),
                  st("hospital", HOSP, { open = true, on = false, ready = true }),
                  st("mess", MESS, { open = true, on = false, ready = true }),
                  st("powder", POWDER, { open = false, on = false, reason = WORKSHOP }),
                  st("toolmaking", TOOLS, { open = true, on = true, ready = false, short = "Short of iron" }) },
        reg_b = { st("builders", BUILD, { open = true, on = false, ready = false, short = "Short of cloth" }),
                  st("hospital", HOSP, { open = true, on = true, ready = false, short = "Short of cloth" }),
                  st("mess", MESS, { open = true, on = false, ready = true }),
                  st("powder", POWDER, { open = false, on = false, reason = WORKSHOP }),
                  st("toolmaking", TOOLS, { open = false, on = false, reason = WORKSHOP }) },
        reg_c = { st("builders", BUILD, { open = false, on = false, reason = CAPITAL }),
                  st("hospital", HOSP, { open = false, on = false, reason = CAPITAL }),
                  st("mess", MESS, { open = false, on = true, reason = CAPITAL }),
                  st("powder", POWDER, { open = false, on = false, reason = WORKSHOP }),
                  st("toolmaking", TOOLS, { open = false, on = false, reason = WORKSHOP }) },
    }
    -- what each settlement can spend: Bravo is short of cloth AND leather, admission names cloth
    local HAVE = { reg_a = { iron = 3, timber = 9, tools = 4, cloth = 3, leather = 1, medicine = 1, beer = 2, salted_meat = 3 },
                   reg_b = { tools = 2, cloth = 0, leather = 0, medicine = 5, beer = 2, salted_meat = 3 },
                   reg_c = { beer = 9 } }
    local VIEWS_ASKED = 0
    local fac_before = FACTIONS.fac_a
    FACTIONS.fac_a = faction("fac_a", { C, B, A })
    fl.owned = function(_f, key) return ({ reg_a = A, reg_b = B, reg_c = C })[key] end
    fl.economy_rows = function(f, region) eq(f:name(), LOCAL, "the local faction's recipes"); return ROWS[region:name()] end
    fl.economy_view = function(_f, region, d)
        VIEWS_ASKED = VIEWS_ASKED + 1
        eq(type(d.cost), "table", "the view is asked for a recipe")
        return { rk = region:name() }
    end
    fl.available_stock = function(v, stem) return HAVE[v.rk][stem] or 0 end
    fl.race = function() return "chd" end
    click("derpy_mr_tab_production")
    local tab = find("derpy_mr_tab_production")
    eq(tab.text, "Production", "the tab is labelled")
    tab:SetState("hover"); eq(tab:GetStateText(), "Production", "and keeps it on hover"); tab:SetState("standard")
    eq(lit("derpy_mr_tab_production"), SEL, "the open tab is lit"); eq(lit("derpy_mr_tab_workshop"), OFF, "the Workshop is not")
    eq(find("sub_title").text, "What your settlements can make", "the tab's title")
    eq(find("derpy_mr_back").visible, false, "no Back: the tab has no drill-down")
    local D = S.data
    eq(#D, 14, "five recipes, each a section, and their settlements")
    -- processing first, then services, each by name; every section folds
    local sections = {}
    for i, r in ipairs(D) do if r.section then sections[#sections + 1] = i .. ":" .. r[1] end end
    eq(table.concat(sections, ","), table.concat({ "1:" .. S.section("Powder mixing"), "3:" .. S.section("Toolmaking"),
        "5:" .. S.section("Builders' yards"), "8:" .. S.section("Factory mess"), "12:" .. S.section("Field hospitals") }, ","),
        "the sections, in order")
    eq(D[3].fold, "prod_toolmaking", "a section folds by its recipe")
    -- A RECIPE NO SETTLEMENT CAN RUN: one grey row saying why, naming the race's own buildings
    eq(D[2][1], S.grey("None of your settlements"), "nobody can run powder"); eq(D[2][4], S.grey("No workshop"), "and why")
    eq(D[2].send, nil, "nothing to enable"); eq(D[2].dim, true, "greyed")
    eq(string.find(D[2].tip, "Buildings that run it: Cinerator, Gunsmith.", 1, true) ~= nil, true, "names what to build")
    eq(string.find(D[2].tip, "Trinket Maker", 1, true), nil, "not another race's building")
    eq(string.find(D[2].tip, "Great Cinerator", 1, true), nil, "and only a chain's first level")
    eq(D[2].price[1].short and D[2].price[2].short, true, "its inputs drawn greyed")
    -- Toolmaking: only Alpha can run it; it is on and short of iron
    eq(D[4][1], "Alpha", "where it runs"); eq(D[4][2], "8 Tools", "what it gives"); eq(D[4][4], "Short", "on, short")
    eq(D[4].price[1].text, "[[col:red]]6[[/col]]", "iron is red"); eq(D[4].price[2].text, "2", "timber is not")
    eq(D[4].price[1].icon, S.icon_of("iron"), "each input after its icon")
    eq(string.find(D[4].tip, "It needs 6 Iron and Alpha has 3 to spare.", 1, true) ~= nil, true, "the tooltip says how short")
    eq(string.find(D[4].tip, "Short of", 1, true), nil, "and does not say it twice")
    eq(D[4].send.label, "Pause", "it can be paused"); eq(D[4].send.off, false, "live")
    eq(D[6][1] .. "|" .. D[6][4] .. "|" .. D[6][2], "Alpha|Paid|-5% cost", "a paid service")
    eq(D[7][1] .. "|" .. D[7][4] .. "|" .. D[7].send.label, "Bravo|Off|Enable", "a service that can be enabled")
    eq(D[11][1], "Charlie", "a service left on where it can no longer run is still listed")
    eq(D[11][4], "Capital only", "saying why"); eq(D[11].send.label .. tostring(D[11].send.off), "Pausefalse", "and can be paused")
    eq(string.find(D[11].tip, "Province capital only", 1, true) ~= nil, true, "the tooltip gives the reason")
    -- BRAVO'S HOSPITAL: admission stopped at cloth; leather is short too, medicine is not
    eq(D[14][1] .. "|" .. D[14][4], "Bravo|Short", "short")
    eq(tostring(D[14].price[1].short) .. tostring(D[14].price[2].short) .. tostring(D[14].price[3].short), "truetruefalse",
       "cloth and leather red, medicine not")
    eq(VIEWS_ASKED, 8, "a view for each listed row, none for one that cannot run")
    -- ON SCREEN: the inputs from column 3, PRICE_PITCH apart; a third icon only where there is a third input
    local PC, r4, r14 = LL.VIEWS.production, find("derpy_mr_row_4"), find("derpy_mr_row_14")
    local u1, u2 = find_uicomponent(r4, "use1"), find_uicomponent(r4, "use2")
    eq(u1.visible and u1.x == r4.x + PC[3][1], true, "the first input at column 3")
    eq(u2.x - u1.x, LL.PRICE_PITCH, "the second after it")
    eq(find_uicomponent(r4, "pn1").text, "[[col:red]]6[[/col]]", "the short amount on screen")
    -- GIVES AFTER ITS ICON: the slot after the inputs', at column 2, the text moved past it
    local g4, g14 = find_uicomponent(r4, "use3"), find_uicomponent(r14, "use4")
    eq((D[4].lead or {})[2], S.icon_of("tools"), "a good's own icon")
    eq((D[6].lead or {})[2], "ui/campaign ui/effect_bundles/construction.png", "a service's, its bundle's")
    eq(g4.visible and g4.x == r4.x + PC[2][1] and g4.image == S.icon_of("tools"), true, "Tools' icon before 8 Tools")
    eq(find_uicomponent(r4, "pn3").visible, false, "and no amount after it")
    eq(find_uicomponent(r4, "c2").x, r4.x + PC[2][1] + LL.ICON_PITCH, "the text after the icon")
    eq(find_uicomponent(r14, "use3").visible and find_uicomponent(r14, "use3").x == r14.x + PC[3][1] + 2 * LL.PRICE_PITCH,
       true, "three inputs, three icons")
    eq(g14.visible and g14.x == r14.x + PC[2][1] and g14.image == "ui/campaign ui/effect_bundles/replenishment.png", true,
       "and the fourth slot is Gives'")
    eq(g4.shader, "normal_t0", "drawn live")
    local g2 = find_uicomponent(find("derpy_mr_row_2"), "use3")
    eq(g2.visible and g2.shader == "set_greyscale_t0", true, "greyed on the row nobody can run")
    eq(find_uicomponent(r4, "c4").x, r4.x + PC[4][1], "the state in column 4")
    eq(sendb(4).visible and sendb(4).x == r4.x + PC[5][1], true, "Pause in the fifth column")
    eq(sendb(2).visible, false, "no button on a recipe nobody can run")
    dump("production")
    local n = #REQ
    press(sendb(7))
    eq(REQ[#REQ], LOCAL .. "|economy|reg_b|builders", "Enable goes through the request door, naming the settlement")
    eq(#REQ, n + 1, "one click, one request"); table.remove(REQ)
    press(sendb(2)); eq(#REQ, n, "the grey row sends nothing")
    -- FOLDING a section hides its settlements and keeps the others
    click("derpy_mr_row_3")
    eq(#S.data, 13, "Toolmaking folded"); eq(S.data[4][1], S.section("Builders' yards"), "the next section moves up")
    eq(S.data[3].folded, true, "drawn folded")
    click("derpy_mr_row_3"); eq(#S.data, 14, "and back")
    -- WITH THE ACTIONS OFF the list still shows, its buttons greyed saying why
    ACT_ON = false; S.refresh()
    eq(S.data[4].send.off, true, "greyed"); eq(S.data[4].send.tip, S.WORK_OFF, "saying why")
    press(sendb(4)); eq(#REQ, n, "and sends nothing"); ACT_ON = true
    -- AN OLDER FLOWS SCRIPT WITHOUT THE VIEW: admission's own shortage still shows
    fl.economy_view = nil; S.refresh()
    eq(tostring(S.data[14].price[1].short) .. tostring(S.data[14].price[2].short), "truefalse", "the one admission named")
    eq(string.find(S.data[14].tip, "Short of Cloth", 1, true) ~= nil, true, "and the tooltip says it")
    -- NOTHING TO SHOW
    fl.economy_rows = function() return {} end; S.refresh()
    eq(#S.data, 0, "a race with no recipes"); eq(find("empty_text").text, S.NO_RECIPES, "says so")
    eq(find("empty_text").visible, true, "shown")
    eq(S.view_model({}).empty, S.NO_REALM, "no settlements says that instead")
    eq(#ERRORS, 0, "no error on the Production tab")
    fl.owned, fl.economy_rows, fl.economy_view = saved.owned, saved.economy_rows, saved.economy_view
    fl.available_stock, fl.race = saved.available_stock, saved.race
    FACTIONS.fac_a = fac_before
    for k in pairs(LOC) do
        if string.find(k, "^building_culture_variants_name_") then LOC[k] = nil end
    end
    for _, k in ipairs({ "tools", "timber", "cloth", "leather", "medicine" }) do
        LOC["pooled_resources_display_name_derpy_mr_store_" .. k] = nil
    end
    click("derpy_mr_tab_settlements"); click("derpy_mr_row_1")
end

eq(sendb(1).x, find("derpy_mr_row_1").x + LL.VIEWS.focus[5][1], "in the fifth column")
eq(sendb(1).disabled, false, "live when something can come"); eq(sendb(1).shader, "normal_t0", "and drawn live")
eq(sendb(1).tip, "Send 12 Coal from Bravo.\n2 are lost on the way and the rest arrive in 2 turns or more.\n"
   .. "An army at war with you can seize it.", "the tooltip says what happens")
eq(sendb(2).disabled, true, "Brimstone: nobody can send it"); eq(sendb(2).shader, "set_greyscale_t0", "and it looks it")
eq(sendb(2).tip, "No other settlement of yours can send Brimstone.", "the tooltip says why")
eq(S.send_tip(nil, { name = "Coal", full = true }), "This store of Coal is full.", "a full store says so")
press(sendb(1)); eq(REQ[1], "fac_a|send|coal|reg_a", "a click asks for this resource into this settlement")
press(sendb(2)); eq(#REQ, 1, "a greyed button asks for nothing")
-- SHIPMENTS (phase 5): the most on the road greys every Send here, and what is coming is listed
PLAN.coal.busy = true; SHIPS_TO.coal = { { n = 34, due = 52 }, { n = 5, due = 53 } }
click("derpy_mr_back"); click("derpy_mr_row_1")
eq(sendb(1).disabled, true, "the most shipments on the road: greyed")
eq(sendb(1).tip, "You already have 3 shipments on the road and cannot send more.\n34 more arrive here "
   .. "on turn 52.\n5 more arrive here on turn 53.", "says why, and what is coming")
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
eq(string.find(payic(1, "materials").tip, "It pays with Coal first because that store is the fullest.", 1, true) ~= nil, true,
   "the icon says what pays and why that one")
eq(string.find(payic(1, "stable").tip, "The stores of Alpha have nothing to pay with.", 1, true) ~= nil, true,
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
eq(string.find(mtip, "Click to stop it.", 1, true) ~= nil, true, "and what a click does")
eq(string.find(atip, "Turned off on turn 37 because the stores of Alpha ran short.", 1, true) ~= nil, true,
   "a supply that ran short says when")
eq(string.find(box(1, "standing").tip, "Click to start it.", 1, true) ~= nil, true, "Supply the capital, off")
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
-- THE ESCORT VIEW (escort battles, spec 2026-10-09): a shipment row opens its escort, one CA card a unit
do
    local W, Q = "wh_main_dwf_inf_dwarf_warrior_0", "wh_main_dwf_inf_quarrellers_0"
    local ships0 = SHIPS
    SHIPS = { { id = "derpy_mr_ship_1", f = LOCAL, stem = "coal", n = 22, from = "reg_b", to = "reg_a", due = 52,
                leg = 1, x = 40, y = 50 } }
    SHIPS[1].escort = W .. "," .. W .. "," .. Q
    LOC["land_units_onscreen_name_" .. DERPY_MR_STORES_CARDS[W].lu] = "Dwarf Warriors"
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
    eq(find("derpy_mr_row_3").tip, "Click to see its escort.", "the shipment row says it opens")
    eq(find("derpy_mr_card_1").visible, false, "no card on the Spending tab itself")
    click("derpy_mr_row_3")
    eq(find("sub_title").text, "Escort of 22 Coal, Bravo to Alpha", "the view names the shipment")
    local p = find("derpy_mr_stores_panel")
    local c1, c2, c3 = find("derpy_mr_card_1"), find("derpy_mr_card_2"), find("derpy_mr_card_3")
    eq(c1.visible and c2.visible and c3.visible, true, "a card per unit")
    eq(find("derpy_mr_card_4").visible, false, "no card past the escort")
    eq(c1.images[0], DERPY_MR_STORES_CARDS[W].card, "CA's card for the unit, not its key")
    eq(c3.images[0], DERPY_MR_STORES_CARDS[Q].card, "in the order it was rolled")
    eq(c1.tip, "Dwarf Warriors", "its name on hover"); eq(c3.tip, Q, "a name with no loc falls back to the key")
    eq(c1.x, p.x + LL.cards[1], "the row starts at the list's left"); eq(c1.y, p.y + LL.cards[2], "under the line")
    eq(c2.x - c1.x, LL.CARD_W + LL.CARD_GAP, "spaced as CA's army strip")
    eq(c1.w, LL.CARD_W, "at the card's own width"); eq(c1.h, LL.CARD_H, "and height")
    eq(shown_rows(), 0, "no list under the cards")
    local line = find("empty_text")
    eq(line.visible, true, "a line says what the escort does"); eq(line.text, S.ESCORT_LINE, "this line")
    eq(line.y, p.y + LL.escort_line[2], "over the cards, not on them")
    eq(find("derpy_mr_back").visible, true, "Back leads out")
    dump("escort")
    click("derpy_mr_back")
    eq(find("derpy_mr_card_1").visible, false, "Back hides the cards"); eq(shown_rows() > 0, true, "and the list is back")
    eq(find("empty_text").y, p.y + LL.empty[2], "the empty line back in its own place")
    -- no escort
    SHIPS[1].escort = ""
    click("derpy_mr_row_3")
    eq(find("empty_text").text, S.NO_ESCORT, "no escort: says the cart is taken without a fight")
    eq(find("derpy_mr_card_1").visible, false, "and draws no card")
    -- the shipment arrived while the view was open: back to the list, no error
    local keep = SHIPS; SHIPS = {}
    click("derpy_mr_tab_spending")
    S.focus = "ship:derpy_mr_ship_1"; S.refresh()
    eq(S.focus, nil, "a shipment gone drops the view"); eq(find("derpy_mr_card_1").visible, false, "with its cards")
    SHIPS = ships0
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
    eq(#ERRORS, 0, "no panel errors in the escort view: " .. table.concat(ERRORS, "; "))
end
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
-- THE ROADS ARE THE 3D MAP'S (terrain_routes.lua, 2026-10-21): every link it draws, on its solved
-- path, in its colour. Here the convoy's road, bent off the straight line, and a foreign treaty
-- road far to the east that the realm's frame must not chase.
local ROAD, FAR = {}, {}
for i = 0, 20 do ROAD[#ROAD + 1] = { 300 - 10 * i, 100 + 10 * i + ((i > 0 and i < 20) and 20 or 0) } end
for i = 0, 29 do FAR[#FAR + 1] = { 2000 + 10 * i, 100 } end
local MINE = { owner = LOCAL, from = "reg_b", to = "reg_a", own = true }
local THEIRS = { owner = "fac_far", from = "reg_x", to = "reg_y", own = false }
ROUTE_LINKS = { MINE, THEIRS }
-- AGREEMENT CONVOYS (flows.lua F.convoy_cargo lists every faction's): one of the viewer's out and one in, both on the
-- road (the points 11 and 5 of it), and a stranger's the panel must not draw. They ride after the shipment's cart.
CONVOYS = {
    { id = "derpy_mr_cv_1", f = LOCAL, buyer = "fac_b", from = "reg_b", to = "reg_a", due = 14, x = 190, y = 230,
      stem = "coal", n = 40, basket = { iron = 12, coal = 40 }, convoy = true },
    { id = "derpy_mr_cv_2", f = "fac_b", buyer = LOCAL, from = "reg_b", to = "reg_a", due = 15, x = 250, y = 170,
      stem = "iron", n = 8, basket = { iron = 8 }, convoy = true },
    { id = "derpy_mr_cv_3", f = "fac_c", buyer = "fac_d", from = "reg_c", to = "reg_d", due = 16, x = 290, y = 110,
      stem = "coal", n = 99, basket = { coal = 99 }, convoy = true },
}
DERPY_MR_TERRAIN_ROUTES = {
    links = function(f) eq(f:name(), LOCAL, "the 3D map's links, asked for the viewer"); return ROUTE_LINKS, {} end,
    path = function(a, b) return ({ reg_b = ROAD, reg_x = FAR })[a] end,
    ink = function(owner) return owner == LOCAL and 2 or 1 end,
}
local terrain_file = assert(io.open('__UIDIR__/derpy_more_resources_terrain_routes.lua'))
local terrain_source = terrain_file:read('*a')
terrain_file:close()
local helpers='local R = {}\n'
for _,name in ipairs({'corner','sample','unshared','shown'}) do helpers=helpers..assert(terrain_source:match('function R.'..name..'%b().-\nend'))..'\n' end
local real_helpers=assert(loadstring(helpers..'return R'))()
for name,fn in pairs(real_helpers) do DERPY_MR_TERRAIN_ROUTES[name]=fn end
click("derpy_mr_tab_map")
eq(find("derpy_mr_tab_map").text, "Map", "a fifth tab")
eq(find("derpy_mr_frame_t").visible or find("derpy_mr_frame_head").visible, false, "no table frame on the map")
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
-- the viewer's convoys, out and in, each a cart after the shipment's; the stranger's is not drawn
local out_cart, in_cart = mapc("cart", 2), mapc("cart", 3)
eq(out_cart.visible and in_cart.visible, true, "a cart for the convoy going out and one for the convoy coming in")
eq(mapc("cart", 4) == false or mapc("cart", 4).visible == false, true, "and none for a stranger's convoy")
eq(out_cart.shader, "glow_pulse_t0", "pulsing, like any convoy on the road")
eq(inside(out_cart) and inside(in_cart), true, "both inside the box")
eq(string.find(out_cart.tip, "40 Coal, 12 Iron from Bravo to Alpha.\nIt arrives on turn 14.", 1, true) ~= nil, true,
   "the tooltip lists the basket, the most first, with where from and to and when")
eq(string.find(in_cart.tip, "8 Iron from Bravo to Alpha.\nIt arrives on turn 15.", 1, true) ~= nil, true, "the one coming in too")
eq(out_cart.x > cart.x and out_cart.y > cart.y, true, "the convoy is further along the road from Alpha to Bravo than the shipment, east and south")
local function road(colour, each)
    local n, i = 0, 1
    while mapc("path" .. colour, i) do
        local c = mapc("path" .. colour, i)
        if c.visible then n = n + 1; if each then each(c) end end
        i = i + 1
    end
    return n
end
local bent = false
local ax, ay, bx, by = da.x + da.w / 2, da.y + da.h / 2, db.x + db.w / 2, db.y + db.h / 2
eq(road(2, function(c)
    eq(c.x > da.x and c.x < db.x + db.w, true, "a road dot between the two settlements")
    local cx, cy = c.x + c.w / 2, c.y + c.h / 2
    bent = bent or cy < ay + (by - ay) * (cx - ax) / (bx - ax) - 4
end), 7, "the convoy's road: every third point of its path, in the realm's colour")
eq(bent, true, "on the solved path, not the straight line between the two")
eq(road(1), 10, "the foreign road too, in its owner's colour")
eq(road(0) + road(3), 0, "and no colour the 3D map did not give them")
local reverse_road = {}
for i = #ROAD, 1, -1 do reverse_road[#reverse_road+1] = ROAD[i] end
ROUTE_LINKS = {MINE, {owner='fac_far',path=reverse_road}, THEIRS}
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(road(2), 7, "shared trunk keeps the first route's colour")
eq(road(1), 10, "reverse shared route adds no overlapping Vault dots")
ROUTE_LINKS = {MINE, THEIRS}
-- another colour set (MCT): the same road in a palette colour past the first set's four
local first_ink = DERPY_MR_TERRAIN_ROUTES.ink
DERPY_MR_TERRAIN_ROUTES.ink = function(owner) return owner == LOCAL and 2 or 13 end
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(road(13), 10, "a later colour set: the foreign road in its own template")
eq(road(1), 0, "and no longer in the first set's colour")
DERPY_MR_TERRAIN_ROUTES.ink = first_ink
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
-- AN AGREEMENT'S OWN TRADE ROAD (trade reach's link.path), as the 3D map draws it, before the display
-- search: 12 points draw 4 dots where the search's 30 draw 10
THEIRS.path = {}
for i = 0, 11 do THEIRS.path[#THEIRS.path + 1] = { 2000 + 10 * i, 300 } end
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(road(1), 4, "an agreement's own trade road, not the display search's")
THEIRS.path = nil
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
local gap0 = db.x - da.x
ROUTE_LINKS = { MINE }; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(mapc("dot", 2).x - mapc("dot", 1).x, gap0, "framed on the realm: a far foreign road does not shrink it")
eq(road(1), 0, "a road the 3D map no longer draws is hidden")
ROUTE_LINKS = { MINE, THEIRS }; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
local surface = find("derpy_mr_map_art")
road(1, function(c)
    eq(c.x >= surface.x and c.x + c.w <= surface.x + surface.w, true, "the plain map's surface carries the far road, so a drag reaches it")
end)
-- A CONVOY FAR FROM THE REALM (an incoming one starts at the partner's capital) rides the surface and stays out of the frame
do
    local listed = CONVOYS
    CONVOYS = { listed[1], listed[2], listed[3],
                { id = "derpy_mr_cv_9", f = "fac_far", buyer = LOCAL, from = "reg_x", to = "reg_a", due = 18, x = 2100, y = 100,
                  stem = "coal", n = 5, basket = { coal = 5 }, convoy = true } }
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    eq(mapc("dot", 2).x - mapc("dot", 1).x, gap0, "framed on the realm: a far incoming convoy does not shrink it")
    local far = mapc("cart", 4)
    eq(far.visible, true, "though its cart is drawn")
    eq(far.x >= surface.x and far.x + far.w <= surface.x + surface.w, true, "on the surface, so a drag reaches it")
    CONVOYS = listed
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
end
-- no path yet (still being worked out, or none at all): nothing, never a straight line instead
local solved = DERPY_MR_TERRAIN_ROUTES.path
DERPY_MR_TERRAIN_ROUTES.path = function() return nil end
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(road(1) + road(2), 0, "no solved path, no road")
eq(mapc("cart", 1).visible, true, "the convoy is still drawn where it is")
-- A CROWDED MAP: at most MAP_PATH_MAX dots, the realm's road first
DERPY_MR_TERRAIN_ROUTES.path = solved
for i = 30, 3 * LL.MAP_PATH_MAX do FAR[#FAR + 1] = { 2000 + 10 * i, 100 } end
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(road(2), 7, "the realm's road keeps every dot"); eq(road(1), LL.MAP_PATH_MAX - 7, "the rest go to the foreign road, up to the most")
for i = #FAR, 31, -1 do FAR[i] = nil end
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
press(cart)
eq(CAMERA[1], 110 * 2, "a click on the cart flies the camera to it"); eq(CAMERA[2], 290 * 2, "both co-ordinates")
eq(find("derpy_mr_stores_panel").visible, false, "and closes the panel")
click("derpy_mr_stores_button"); click("derpy_mr_tab_map")
press(mapc("cart", 2)); eq(CAMERA[1], 190 * 2, "a click on a convoy flies the camera to it"); eq(CAMERA[2], 230 * 2, "both co-ordinates")
click("derpy_mr_stores_button"); click("derpy_mr_tab_map")
-- A CONVOY WITH NO POSITION is on the road but has no place for a cart (the Trade tab counts it). The stub's
-- log_to_dis tolerates the nil here, as the engine's does not, so it is the rule that is measured and not the throw.
do
    local real, listed = cm.log_to_dis, CONVOYS
    CONVOYS = { listed[1], { id = "derpy_mr_cv_4", f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 17,
                              stem = "coal", n = 3, basket = { coal = 3 }, convoy = true } }
    cm.log_to_dis = function(_, x, y) return (x or 0) * 2, (y or 0) * 2 end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    eq(mapc("cart", 2).visible, true, "the convoy with a position is drawn")
    eq(mapc("cart", 3).visible, false, "the one with no position is not")
    cm.log_to_dis, CONVOYS = real, listed
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
end
-- CONVOYS ON ONE SPOT SHARE A CART (a one-turn convoy waits at its exporter's capital): twenty at Alpha are one cart on its
-- dot, and its tooltip names the eight that land soonest and counts the rest
do
    local listed = CONVOYS
    CONVOYS = {}
    for i = 1, 20 do
        CONVOYS[i] = { id = "derpy_mr_cv_" .. (40 + i), f = LOCAL, buyer = "fac_b", from = "reg_a", to = "reg_b", due = 20 + i,
                       x = 100, y = 300, stem = "coal", n = i, basket = { coal = i }, convoy = true }
    end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    local stack = mapc("cart", 2)
    eq(stack.visible, true, "a cart for the twenty convoys"); eq(mapc("cart", 3).visible, false, "and no second one")
    eq(math.abs(stack.x + stack.w / 2 - (da.x + da.w / 2)) <= 1 and math.abs(stack.y + stack.h / 2 - (da.y + da.h / 2)) <= 1, true,
       "on the capital where they stand")
    local _, named = string.gsub(stack.tip, "by turn", "")
    eq(named, 8, "its tooltip names eight")
    eq(string.find(stack.tip, "by turn 21: 1 Coal", 1, true) ~= nil, true, "the soonest first")
    eq(string.sub(stack.tip, -#"and 12 more convoys"), "and 12 more convoys", "and counts the other twelve")
    -- a convoy somewhere else keeps its own cart and its own tooltip
    CONVOYS[21] = listed[1]
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    eq(mapc("cart", 3).visible, true, "a convoy on another spot has a cart of its own")
    eq(string.find(mapc("cart", 3).tip, "40 Coal, 12 Iron from Bravo to Alpha.\nIt arrives on turn 14.", 1, true) ~= nil, true,
       "with the tooltip a lone convoy has")
    press(mapc("cart", 2)); eq(CAMERA[1], 100 * 2, "a click on the stack flies the camera to it"); eq(CAMERA[2], 300 * 2, "both co-ordinates")
    CONVOYS = listed
    click("derpy_mr_stores_button"); click("derpy_mr_tab_map")
end
-- the 3D map's shipments switch hides convoys with the shipments: no carts at all on the Map tab
do
    local fl = DERPY_MR_FLOWS
    fl.mct = function(k) if k == "route_shipments" then return false end end
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    eq(mapc("cart", 1).visible or mapc("cart", 2).visible or mapc("cart", 3).visible, false, "the shipments switch is off: no shipment, no convoy")
    fl.mct = nil
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
    eq(mapc("cart", 1).visible and mapc("cart", 2).visible and mapc("cart", 3).visible, true, "and on again")
end
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
    for _, kind in ipairs({ "dot", "label", "path2", "cart" }) do
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
local ships0, links0, convoys0 = SHIPS, ROUTE_LINKS, CONVOYS; SHIPS, ROUTE_LINKS, CONVOYS = {}, {}, {}
CAMPAIGN = "wh3_main_combi"; S.frame = nil; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
local ea, eclip = art(), find("derpy_mr_map_clip")
eq(ea.w, 1440 * LL.MAP_ART_ZOOM, "a tight cluster is drawn at the closest zoom, no closer")
eq(ea.y + ea.h >= eclip.y + eclip.h, true, "and the picture still reaches the box's foot")
eq(ea.y + ea.h - (eclip.y + eclip.h) <= 1, true, "its own foot on the box's: the view went no further south")
on_place(ea, mapc("dot", 2), "reg_b", "by the edge, Bravo")
POS.reg_a, POS.reg_b = { 100, 300 }, { 300, 100 }
SHIPS, ROUTE_LINKS, CONVOYS = ships0, links0, convoys0; S.frame = nil
CAMPAIGN = "some_mod_map"; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(art().images[0], S.NO_ART, "back on an unknown map, the picture goes")
CAMPAIGN = "wh3_main_combi"; click("derpy_mr_tab_goods")
eq(find("derpy_mr_map_clip").visible, false, "and off the Map tab")
CAMPAIGN = "some_mod_map"
-- a single settlement and no convoy: framed on that one, nothing stretched to a point
FACTIONS.fac_a = faction("fac_a", { A }); SHIPS, CONVOYS = {}, {}
click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(mapc("dot", 1).visible, true, "one settlement still draws"); eq(inside(mapc("dot", 1)), true, "inside the box")
eq(mapc("dot", 2).visible, false, "the second dot is hidden, not left behind")
eq(mapc("cart", 1).visible, false, "no convoy, no cart")
ROUTE_LINKS = {}; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(mapc("path2", 1).visible or mapc("path1", 1).visible, false, "and no road")
DERPY_MR_TERRAIN_ROUTES = nil; click("derpy_mr_tab_goods"); click("derpy_mr_tab_map")
eq(mapc("dot", 1).visible, true, "with no route script the settlements still draw")
eq(mapc("path2", 1).visible or mapc("path1", 1).visible, false, "and no road at all")
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
eq(string.find(fest.tip, "public order +4 in every province for 5 turns", 1, true) ~= nil, true, "and what it buys")
for _, o in ipairs(DERPY_MR_STORES_ORDERS) do names_use(act("derpy_mr_order_" .. o.key).tip, o.use, o.label) end
eq(act("derpy_mr_order_muster").disabled, true, "Muster is waiting")
eq(string.find(act("derpy_mr_order_muster").tip, "Ready again in 7 turns.", 1, true) ~= nil, true, "and says how long")
eq(act("derpy_mr_order_great_works").disabled, true, "Great Works is short")
eq(string.find(act("derpy_mr_order_great_works").tip, "You have 120 building materials.", 1, true) ~= nil, true,
   "and says how short")
eq(find("hint_text").y < fest.y, true, "the hint is clear of the orders' line")
-- A RUNNING ORDER GLOWS (CA's active-state glow_pulse_t0) and still cannot be bought
ORDER_ST.festival = { ok = false, wait = 8, active = 3, have = 250, cost = 200, use = "luxuries" }
click("derpy_mr_tab_goods"); click("derpy_mr_tab_spending")
local runb = act("derpy_mr_order_festival")
eq(runb.shader, "glow_pulse_t0", "a running order glows"); eq(runb.disabled, true, "and cannot be bought again")
eq(runb.vars[1] == S.FX.glow[2] and runb.vars[2] == S.FX.glow[3], true, "at CA's values")
eq(string.find(runb.tip, "Running for 3 turns more and ready again in 8 turns.", 1, true) ~= nil, true, "and says so")
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
SALE = { n = 120, gold = 840, price = 700 }
click("derpy_mr_tab_goods"); click("derpy_mr_row_1"); eq(find("sub_title").text, "Where Coal is kept", "Coal's drill-down")
local sell = act("derpy_mr_sell")
eq(sell.visible, true, "a Sell button"); eq(sell.text, "Sell surplus", "labelled"); eq(sell.x, slot(4), "in slot 4")
eq(sell.tip, "Sell the 120 Coal your stores hold over half full for 840 gold (7.00 each).", "priced in its tooltip")
eq(act("derpy_mr_order_festival").visible, false, "no orders on a drill-down")
press(sell); eq(REQ[2], "fac_a|sell|coal", "a click sells it")
SALE = nil; click("derpy_mr_back"); click("derpy_mr_row_1")
eq(act("derpy_mr_sell").disabled, true, "nothing to sell: greyed")
eq(act("derpy_mr_sell").tip, "There is nothing worth selling.\nOnly what your stores of Coal hold over half full can be sold.", "and says why")
press(act("derpy_mr_sell")); eq(#REQ, 2, "a greyed Sell asks for nothing")
-- FOUNDING (spec 2026-10-09): a row above the goods of a region no slot offers its rare building in
;(function()
    REQ = {}
    FOUND_ST.reg_a = { good = "dragon_bone", level = 0, next = 1, cost = 1000, tier_need = 1 }
    click("derpy_mr_tab_goods"); click("derpy_mr_tab_settlements"); click("derpy_mr_row_1")
    eq(S.focus, "reg_a", "reg_a's drill-down")
    local names = DERPY_MR_STORES_FOUND.dragon_bone
    eq(cell(1, 1).text, names[1], "the first row names the building it founds")
    eq(cell(1, 2).text, "Not built", "not built yet"); eq(cell(1, 4).text, "1000 gold", "CA's price, beside its button")
    eq(cell(1, 3).text, "", "nothing under Per turn: a price there reads as income")
    eq(sendb(1).visible, true, "a button"); eq(sendb(1).text, "Found", "labelled Found")
    eq(sendb(1).disabled, false, "live")
    eq(string.find(sendb(1).tip, "no building slot here normally takes it", 1, true) ~= nil, true,
       "the tooltip says why it is here")
    eq(S.data[1].icon, S.icon_of("dragon_bone"), "the good's own icon")
    eq(S.data[2].stem ~= nil, true, "the goods follow it")
    dump("found")
    press(sendb(1)); eq(REQ[1], "fac_a|found|reg_a", "a click founds it")
    local stem2 = S.data[2].stem
    local keep_plan = PLAN[stem2]
    PLAN[stem2] = { from = B, n = 12, got = 10 }
    click("derpy_mr_back"); click("derpy_mr_row_1")
    press(sendb(2)); eq(REQ[2], "fac_a|send|" .. stem2 .. "|reg_a", "Send here under it still sends its own good")
    PLAN[stem2] = keep_plan
    FOUND_ST.reg_a = { good = "dragon_bone", level = 1, next = 2, cost = 2000, tier_need = 2, why = "tier" }
    click("derpy_mr_back"); click("derpy_mr_row_1")
    eq(cell(1, 1).text, names[1], "the building it has"); eq(cell(1, 2).text, "Level 1 of 3", "at its level")
    eq(sendb(1).text, "Upgrade", "Upgrade after"); eq(sendb(1).disabled, true, "greyed below the tier")
    eq(sendb(1).tip, "It needs a level 2 settlement.", "says why")
    -- filled by {1}, not string.format: a "%" a translator writes stays text instead of an error (2026-11-11)
    local tk = DERPY_MR_LOC_KEYS["It needs a level {1} settlement."]
    eq(type(tk), "string", "the tier refusal has a {1} key")
    if tk then
        LOC[tk] = "Nivel {1} al 100%"; S.T_CACHE = {}
        click("derpy_mr_back"); click("derpy_mr_row_1"); eq(sendb(1).tip, "Nivel 2 al 100%", "a % in a translation stays text")
        LOC[tk] = nil; S.T_CACHE = {}
    end
    local n = #REQ; press(sendb(1)); eq(#REQ, n, "a greyed row asks for nothing")
    FOUND_ST.reg_a = { good = "dragon_bone", level = 0, next = 1, cost = 1000, tier_need = 1, why = "gold" }
    click("derpy_mr_back"); click("derpy_mr_row_1"); eq(sendb(1).tip, "It needs 1000 gold.", "short of gold")
    FOUND_ST.reg_a = { good = "dragon_bone", level = 0, next = 1, cost = 1000, tier_need = 1, why = "slot" }
    click("derpy_mr_back"); click("derpy_mr_row_1"); eq(sendb(1).tip, "It needs an empty building slot.", "no slot")
    ACT_ON = false; click("derpy_mr_back"); click("derpy_mr_row_1")
    eq(S.data[1].found, nil, "actions off: no row"); ACT_ON = true
    FOUND_ST.reg_a = nil
    click("derpy_mr_back"); click("derpy_mr_row_1"); eq(S.data[1].found, nil, "nothing to found: no row")
    eq(#ERRORS, 0, "no panel errors in the founding row: " .. table.concat(ERRORS, "; "))
    -- back where the Sell tests left the panel, so the switch tests after still look at Coal's drill-down
    click("derpy_mr_tab_settlements"); click("derpy_mr_tab_goods"); click("derpy_mr_row_1")
    eq(act("derpy_mr_sell").visible, true, "Coal's drill-down again")
end)()
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
    eq(string.find(ib.tip, "It goes into your Book of Grudges.\nRecruiting it there still costs its gold.", 1, true) ~= nil,
       true, "the pool route says where, and that gold is still due")
    local ihm, hm = row_of("unit_wh_main_dwf_inf_hammerers")
    eq(string.find(hm.tip, "It goes straight into your largest army with room.", 1, true) ~= nil, true, "the army route says so")
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
    eq(sendb(ih).disabled, true, "short: greyed"); eq(sendb(ih).tip, "It needs 40 " .. S.name("dragon_bone") .. " and you have 10.", "and says why")
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
    eq(string.find(helm.tip, "common mounts and you have", 1, true) ~= nil, true, "the tooltip says only common goods pay")
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
    eq(find("hint_text").text, "It is paid from all your stores: 60 " .. S.name("gromril") .. " and 200 war materials.",
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
    eq(sendb(ia).tip, "Resource Vault actions are switched off in the mod settings.", "and says why")
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
    eq(sendb(ig).tip, "It needs 120 " .. S.name("salt") .. " and you have 50.", "short: says which good")
    eq(string.find(S.data[ig].tip, "It needs 120 " .. S.name("salt") .. " and you have 50", 1, true) ~= nil, true,
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
    click("derpy_mr_row_" .. sec_of("Permanent works"))
    eq(row_of("last_granary"), nil, "folded: its rows hidden")
    dump("workshop_folded")   -- the preview draws a folded section's arrow
    local wl = find_uicomponent(find("derpy_mr_row_" .. sec_of("Permanent works")), "fold")
    eq(wl.visible and wl.rot[0], math.pi * 3 / 2, "the section's arrow points right")
    eq(string.find(S.data[sec_of("Permanent works")][1], "hidden", 1, true), nil, "and no word says so")
    eq(row_of("army_ammo") ~= nil, true, "other kinds stay")
    click("derpy_mr_row_" .. sec_of("Permanent works")); eq(row_of("last_granary") ~= nil, true, "unfolded again")
    eq(find_uicomponent(find("derpy_mr_row_" .. sec_of("Permanent works")), "fold").rot[0], 0, "its arrow points down")
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
eq(string.find(plate.tip, "armies are raiding here", 1, true), nil, "a lone raider's plate says nothing of others")
PREVIEW[ch7].to, PREVIEW[ch7].raiders = "reg_b", 3; REPEATS.derpy_mr_raid_plate()
eq(string.find(plate.tip, "3 armies are raiding here.\nEach one takes from what the others leave.", 1, true) ~= nil, true,
   "several raiders: the plate says its share comes from what the others leave")
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

do
    local fl = DERPY_MR_FLOWS
    DERPY_MR_FLOWS = { rates = function() return {actions=true,army_provisions=true} end, provision_rows = function()
        return {{id="801", held=25, cap=50, need=5, short=0, auto=true, source=A, reason="It refills from this settlement."}}
    end, request=function(f,...) REQ[#REQ+1]=f .. "|" .. table.concat({...},"|") end }
    local view, focus = S.view, S.focus
    S.view, S.focus = "spending", "army:801"
    S.refresh()
    eq(S.data[1][2], "25 / 50", "army cargo and capacity")
    eq(S.data[1][4], "5 turns", "army cover")
    eq(S.data[1].send.label,"Pause","army auto toggle")
    local n=#REQ
    press(sendb(2))
    eq(REQ[#REQ],LOCAL .. "|provisions|801|load","army load uses synchronized door")
    eq(#REQ,n+1,"one army request")
    table.remove(REQ)
    dump("army")
    DERPY_MR_FLOWS.provision_rows=function()
        return {{id="801",held=0,cap=50,need=5,short=2,auto=true,mobile=true,buy=10,price=100,
            reason="You can buy 10 rations for 100 gold."}}
    end
    S.refresh()
    eq(S.data[2][1],"Buy rations","mobile purchase is explicit")
    eq(S.data[2][3],"100 gold","field price is visible")
    eq(S.data[2].send.label,"Buy","field action names its payment")
    eq(S.data[2].send.off,false,"mobile army may buy without local store")
    eq(S.data[3][1],"Supply cart","Send supplies sits beside Load")
    eq(S.data[4].send.off,true,"mobile army cannot unload remotely")
    dump("army_mobile")
    -- THE SUPPLY LINE (Task 3): a section of its own under the meals, one row of state, source, turns and upkeep
    ;(function()   -- a function of its own: the main chunk is at Lua's 200-local limit
    local NOTE, ASKED
    DERPY_MR_FLOWS.supply_note=function(f,id) ASKED=f:name().."|"..id; return NOTE end
    DERPY_MR_FLOWS.provision_rows=function()
        return {{id="801",held=25,cap=50,need=5,short=0,auto=true,reason="It refills from this settlement."}}
    end
    local function road_rows()
        for i,r in ipairs(S.data) do
            if string.find(r[1],"Supply road",1,true) then return r,S.data[i+1] end
        end
    end
    NOTE=nil; S.refresh(); eq(road_rows(),nil,"no note, no supply road section")
    NOTE={state="none"}; S.refresh(); eq(road_rows(),nil,"an army with no line has no section")
    NOTE={state="stretched",source="reg_a",turns=5,upkeep=20}; S.refresh()
    local head,row=road_rows()
    eq(head.section,true,"the supply road has its own section row")
    eq(ASKED,LOCAL.."|801","the panel asks for the local faction's army by its number")
    eq(row[1].."/"..row[2].."/"..row[3].."/"..row[4],"Stretched/Alpha/5 turns/+20%","state, source, turns and upkeep")
    eq(row.tip,"Stretched: 5 turns from Alpha. Upkeep +20%.","and the row's tooltip says it in a sentence")
    NOTE={state="home",source="reg_a",turns=0,upkeep=0}; S.refresh()
    head,row=road_rows(); eq(row[1].."/"..row[2].."/"..row[3].."/"..row[4],"At home/Alpha/-/+0%","an army at home")
    eq(row.tip,"In your own lands.","says so")
    NOTE={state="cut",upkeep=25}; S.refresh()
    head,row=road_rows(); eq(row[1].."/"..row[2].."/"..row[3].."/"..row[4],"Cut off/-/-/+25%","a cut army has no source and no length")
    eq(row.tip,"Cut off. Upkeep +25%.\nForaging and buying from the locals costs the most.","and its sentence says why it costs the most")
    NOTE={state="cut",upkeep=25,by="fac_x"}; S.refresh()
    head,row=road_rows(); eq(row.tip,"Cut off. Upkeep +25%.\nForaging and buying from the locals costs the most.\nAn enemy army blocks the road.","an enemy on the road is named on a line of its own")
    -- SEND SUPPLIES (Task 5): Auto's supply cart by hand, beside Load, refused with the reason and sent through the door
    local function cart_row()
        for i,r in ipairs(S.data) do if r.provisions=="send" then return r,i end end
    end
    local CART
    DERPY_MR_FLOWS.supply_cart_of=function(id) return CART end
    NOTE={state="cut",upkeep=25}; S.refresh()
    local cr,ci=cart_row()
    eq(cr.send.label,"Send supplies","the button says what it does")
    eq(cr.send.off,true,"a cut army cannot be sent supplies")
    eq(cr.send.tip,"Cut off. Supplies cannot reach this army.","and says why")
    NOTE={state="home",source="reg_a",turns=0,upkeep=0}; S.refresh(); cr=cart_row()
    eq(cr.send.off,true,"an army at home loads instead"); eq(cr.send.tip,"This army is in your own lands.\nLoad it here instead.","and says so")
    NOTE={state="none"}; S.refresh(); cr=cart_row()
    eq(cr.send.off,true,"no line, no cart"); eq(cr.send.tip,"This army has no supply road.","and says so")
    NOTE={state="stretched",source="reg_a",turns=5,upkeep=20}; CART={due=14}; S.refresh(); cr=cart_row()
    eq(cr.send.off,true,"one cart at a time"); eq(cr.send.tip,"A cart is already on its way.\nIt arrives on turn 14.","and says when it lands")
    CART=nil; S.refresh(); cr=cart_row()
    eq(cr.send.off,true,"an army with five turns aboard"); eq(cr.send.tip,"This army already carries 5 turns of provisions.","says so")
    DERPY_MR_FLOWS.provision_rows=function()
        return {{id="801",held=10,cap=50,need=5,short=0,auto=true,reason="It refills from this settlement."}}
    end
    local SPARE,SPARE_ASKED=5
    DERPY_MR_FLOWS.provision_spare=function(f,k) SPARE_ASKED=f:name().."|"..k; return SPARE end
    S.refresh(); cr,ci=cart_row()
    eq(cr.send.off,false,"a stretched army can be sent supplies")
    eq(cr.send.tip,"Send a cart of provisions from Alpha.\nIt arrives in 5 turns.\nAn army at war with you can seize it.","and is told where from and how long")
    local n=#REQ
    press(sendb(ci))
    eq(REQ[#REQ],LOCAL.."|provisions|801|send","Send supplies goes through the synchronized door")
    eq(#REQ,n+1,"one request"); table.remove(REQ)
    -- A SOURCE WITH NOTHING TO SPARE (review 2026-11-09): refused with the reason, not enabled and silent
    SPARE=0; S.refresh(); cr=cart_row()
    eq(cr.send.off,true,"a source with no food to spare sends no cart")
    -- and why (Gidwelion, 2026-11-11: "has nothing to spare" while the settlement made spare grain)
    eq(cr.send.tip,"Alpha has no food to spare.\nA settlement keeps 5 turns of the food it eats and uses before it feeds an army.","and says so, and why")
    DERPY_MR_FLOWS.FED_TURNS=4; S.refresh(); cr=cart_row()
    eq(cr.send.tip,"Alpha has no food to spare.\nA settlement keeps 4 turns of the food it eats and uses before it feeds an army.","the turns are the flows script's own")
    DERPY_MR_FLOWS.FED_TURNS=nil; S.refresh(); cr=cart_row()
    eq(SPARE_ASKED,LOCAL.."|reg_a","the line's own source is asked, for the local faction")
    SPARE=3; S.refresh(); cr=cart_row()
    eq(cr.send.off,false,"a source with food to spare sends one")
    DERPY_MR_FLOWS.provision_spare=nil
    NOTE=nil
    end)()
    DERPY_MR_FLOWS,S.view,S.focus=fl,view,focus
    S.refresh()
end

do
    local fl, view, focus = DERPY_MR_FLOWS, S.view, S.focus
    local prior_local=LOCAL; LOCAL="fac_a"
    eq(S.money(75),"0.75","hundredths read as gold"); eq(S.money(1483),"14.83","more than a gold")
    eq(S.money(300),"3.00","whole gold keeps its zeros"); eq(S.money(5),"0.05","a hundredth is padded")
    local order={id="77",from="reg_b",to="reg_a",stem="coal",seller=LOCAL,target=100,batch=100,enabled=true}
    local NEXT_CART=157   -- what F.cart_price answers: the partner's price or the buyer's own store's, whichever is more
    local CART_ARGS
    local f=FACTIONS[LOCAL]
    local partners=f.factions_trading_with
    local regions=f.region_list
    f.region_list=function() return list({A,B}) end
    f.factions_trading_with=function() return list({}) end
    DERPY_MR_FLOWS={rates=function() return {actions=true} end,request=function(fk,...)
        REQ[#REQ+1]=fk.."|"..table.concat({...},"|")
    end,routes=function() return {order} end, ships=function() return {} end,
    GOOD={coal={use="war"}}, SELL_RATE={war=3}, owned=function(_,key) if key=="reg_a" then return A end end,
    stock_view=function(_,r) return {region=r,held={coal=200},capacity={coal=400}} end,
    available_stock=function(v) return v.region==B and 200 or 0 end,
    route_status=function() return {seller="t_seller",from="t_from",to="t_to"} end,
    cart_price=function(...) CART_ARGS={...}; return NEXT_CART end,
    route_turns=function() return 3 end,free=function() return 300 end}
    S.view,S.focus="spending","route:77"; S.refresh()
    eq(S.view_key(),"trade_focus","order editor uses rule columns")
    eq(S.data[2].route,"77","target row identifies saved order")
    eq(S.data[4][1],"Your own goods: free","an own-faction order carries no price")
    eq(S.data[5][1],"Gold set aside","and no last-cart row")
    local n=#REQ
    press(find_uicomponent(find("derpy_mr_row_2"),"derpy_mr_policy_plus"))
    eq(REQ[#REQ],LOCAL.."|route_edit|77|target|110","target button reaches synchronized door")
    press(sendb(6)); eq(REQ[#REQ],LOCAL.."|route_ctl|77|toggle","pause button requests correct action")
    press(sendb(7)); eq(REQ[#REQ],LOCAL.."|route_ctl|77|cancel","cancel button requests correct action")
    dump("route")
    order.seller="fac_p"; order.last_price_c=82; S.refresh()
    eq(S.data[4][1],"Price each","a partner order is priced per cart")
    eq(S.data[4][2],"0.82","at the last cart's price, in gold to the hundredth")
    local WHY="The last cart cost this and the next one costs "
    eq(S.data[4].tip,WHY.."1.57 each.","and the tip says what it costs and what the next cart will")
    eq(CART_ARGS[1],"t_seller","the next cart is priced for the order's seller"); eq(CART_ARGS[2],"t_from","from its source")
    eq(CART_ARGS[3]:name(),LOCAL,"for the buyer"); eq(CART_ARGS[4],"t_to","into its destination"); eq(CART_ARGS[5],"coal","in its good")
    NEXT_CART=nil; S.refresh()
    eq(S.data[4].tip,WHY.."an unknown amount.","a cart with no price shows a dash"); NEXT_CART=157; S.refresh()
    eq(S.data[5][1],"Gold set aside","in one row, not two")
    dump("route_partner")
    order.last_price_c=nil; S.refresh()
    eq(S.data[4][2],"Set per cart","no price to show before the first cart")
    order.seller=LOCAL
    order.from="reg_c"
    S.view,S.focus="settlements","routes:reg_a:coal"; S.refresh()
    eq(S.data[1][3],"at least 3 turns","offer displays the calculator's figure as a least: no road is searched for a panel")
    eq(string.find(S.data[1].tip,"depending on the road",1,true)~=nil,true,"and the tip says a cart takes its road's length")
    eq(string.find(S.data[1].tip,"coordinate distance",1,true),nil,"and no longer says the straight line decides")
    press(sendb(1))
    eq(REQ[#REQ],LOCAL.."|route_new|reg_b|reg_a|coal|100|100","Create button requests explicit recurring terms")
    dump("route_offer")
    f.factions_trading_with=function() return list({faction("fac_p",{B})}) end
    NEXT_CART=1483
    S.refresh()
    eq(S.data[1][4],"Your own","an own-faction offer needs no gold")
    eq(S.data[2][4],"14.83","a partner's offer shows what a cart costs")
    eq(CART_ARGS[1]:name(),"fac_p","priced for the partner selling"); eq(CART_ARGS[2]:name(),"reg_b","from its store")
    eq(CART_ARGS[3]:name(),LOCAL,"for the buyer"); eq(CART_ARGS[4]:name(),"reg_a","into the buyer's store"); eq(CART_ARGS[5],"coal","in that good")
    eq(string.find(S.data[2].tip,"You pay the selling price plus 10% or your own store price if that is higher.",1,true)~=nil,true,"and says what that is")
    eq(string.find(S.data[2].tip,"fixed price",1,true),nil,"and no longer calls it fixed")
    NEXT_CART=nil; S.refresh()
    eq(S.data[2][4],"-","a cart with no price shows no price")
    while #REQ>n do table.remove(REQ) end
    f.factions_trading_with=partners
    f.region_list=regions
    LOCAL=prior_local
    DERPY_MR_FLOWS,S.view,S.focus=fl,view,focus
    S.refresh()
end
do
    local fl, selected, old7 = DERPY_MR_FLOWS, cm.get_campaign_ui_manager, CHARS[7]
    local f = FACTIONS[LOCAL]
    local pick, allowed, enabled = 7, true, true
    ARMY_AT = { x = 0, y = 0 }     -- where the selected army stands, and its number when a test changes it
    local force = { command_queue_index=function() return ARMY_AT.id or 801 end,
        general_character=function() return {command_queue_index=function() return 7 end,
            logical_position_x=function() return ARMY_AT.x end, logical_position_y=function() return ARMY_AT.y end} end }
    CHARS[7] = {is_null_interface=function() return false end, faction=function() return f end,
        has_military_force=function() return true end, military_force=function() return force end}
    cm.get_campaign_ui_manager=function() return {get_char_selected_cqi=function() return pick end} end
    DERPY_MR_FLOWS = {rates=function() return {army_provisions=enabled,actions=true} end,
        provision_force=function() return allowed end,
        provision_rows=function() return {{id="801",held=25,cap=50,need=5,short=0,auto=true,reason="It refills from this settlement."}} end}
    local army = new("button_group_army",UI_ROOT);army.x,army.y,army.w,army.h=500,800,169,55
    local template = new("button_recruitment",army);template.w,template.h=55,55
    S.show(false); S.army_button_poll()
    local widget=find("derpy_mr_army_open")
    eq(widget.visible,true,"owned selected lord shows provisions")
    eq(widget.images[0],"ui/skins/default/derpy_mr_provisions.png","provisions use a padded native army-bar icon")
    eq(widget.text,"5","icon badge shows food needed per turn")
    eq(widget.parent,army,"provisions belongs to native army bar")
    eq(string.find(widget.tip,"carries 25 of 50")~=nil,true,"tooltip shows carried provisions")
    -- THE SUPPLY LINE (Task 3): its sentence in the same tooltip, asked of the local faction's army by its number, and
    -- only of an army that stood on the same hex at the previous poll
    ;(function()   -- a function of its own: the main chunk is at Lua's 200-local limit
    local NOTE,ASKED,CALLS=nil,nil,0
    DERPY_MR_FLOWS.supply_note=function(f,id) CALLS=CALLS+1; ASKED=f:name().."|"..id; return NOTE end
    local function tip_has(text) return string.find(widget.tip,text,1,true)~=nil end
    local function settle() S.army_button_poll(); S.army_button_poll() end   -- two polls on one hex: the second asks
    S.supply_poll={}; ARMY_AT.x=1
    settle(); eq(tip_has("Upkeep"),false,"no note: no sentence")
    NOTE={state="none"}; settle(); eq(tip_has("Upkeep"),false,"an army with no line: no sentence")
    NOTE={state="stretched",source="reg_a",turns=5,upkeep=20}; settle()
    eq(tip_has("Stretched: 5 turns from Alpha. Upkeep +20%."),true,"a stretched army's tooltip reads the line")
    eq(ASKED,LOCAL.."|801","asked of the local faction, for this army")
    eq(tip_has("carries 25 of 50"),true,"beside the meals")
    NOTE={state="supplied",source="reg_a",turns=3,upkeep=10}; settle()
    eq(tip_has("Supplied from Alpha, 3 turns away. Upkeep +10%."),true,"a supplied army")
    NOTE={state="supplied",source="reg_a",turns=1,upkeep=0}; settle()
    eq(tip_has("Supplied from Alpha, 1 turn away. Upkeep +0%."),true,"one turn away is singular")
    NOTE={state="cut",upkeep=25}; settle()
    eq(tip_has("Cut off. Upkeep +25%.\nForaging and buying from the locals costs the most."),true,"a cut army, and why it costs the most")
    eq(tip_has("blocks the road"),false,"with nobody on the road")
    NOTE={state="cut",upkeep=25,by="fac_x"}; settle()
    eq(tip_has("Cut off. Upkeep +25%.\nForaging and buying from the locals costs the most.\nAn enemy army blocks the road."),true,"and with an enemy on it")
    NOTE={state="home",source="reg_a",turns=0,upkeep=0}; settle()
    eq(tip_has("In your own lands."),true,"an army at home")
    -- WALKING: an army that moves every poll is never asked (a search a poll), and its last sentence stays
    NOTE={state="stretched",source="reg_a",turns=5,upkeep=20}; settle(); CALLS=0
    NOTE={state="cut",upkeep=25}
    for _=1,3 do ARMY_AT.x=ARMY_AT.x+1; S.army_button_poll() end
    eq(CALLS,0,"an army that moves every poll is not asked")
    eq(tip_has("Cut off"),false,"and still shows its last sentence"); eq(tip_has("Stretched: 5 turns from Alpha. Upkeep +20%."),true,"as it was")
    S.army_button_poll()
    eq(CALLS,1,"standing still, it is asked"); eq(tip_has("Cut off. Upkeep +25%."),true,"and the new sentence shows")
    -- ANOTHER ARMY never shows this one's sentence, and with provisions switched off the sentence still shows
    ARMY_AT.id=802; enabled=false; CALLS=0
    S.army_button_poll()
    eq(CALLS,0,"the first poll of another army asks nothing"); eq(tip_has("Cut off"),false,"and it does not show the other army's sentence")
    S.army_button_poll()
    eq(CALLS,1,"the next one asks"); eq(ASKED,LOCAL.."|802","for that army")
    eq(tip_has("switched off in this campaign"),true,"provisions are switched off"); eq(tip_has("Cut off. Upkeep +25%."),true,"and its supply sentence still shows")
    ARMY_AT.id=nil; enabled=true; NOTE=nil; S.supply_poll={}
    end)()
    local n=#REQ
    click("derpy_mr_army_open")
    eq(S.focus,"army:801","button opens selected force")
    eq(S.view,"spending","button uses existing detail view")
    eq(S.is_open(),true,"button opens the Vault")
    eq(#REQ,n,"opening details never mutates the model")
    S.show(false);pick=nil;S.army_button_poll();eq(widget.visible,false,"deselection hides indicator")
    pick=7;allowed=false;S.army_button_poll();eq(widget.visible,false,"ineligible army hides indicator")
    allowed=true;enabled=false;S.army_button_poll()
    eq(widget.visible,true,"saved-off campaign explains disabled feature")
    eq(find("derpy_mr_army_open").disabled,true,"saved-off campaign cannot open provisions")
    local focus=S.focus;click("derpy_mr_army_open");eq(S.focus,focus,"disabled click changes nothing")
    enabled=true;pick=8;CHARS[8]=CHARS[7];S.army_button_poll()
    eq(widget.visible,false,"embedded hero cannot use the lord button")
    CHARS[8]=nil;CHARS[7]=old7;cm.get_campaign_ui_manager=selected;DERPY_MR_FLOWS=fl
    army:Destroy()
end
-- LOCAL PRICES: a Price column on both drill-downs, its sentence on the row's tooltip, the full
-- mark moved into Held / Space, and the Sell tooltip listing each store's lot
;(function()   -- a function of its own: the main chunk is at Lua's 200-local limit
    local fl, view, focus = DERPY_MR_FLOWS, S.view, S.focus
    local f, regions = FACTIONS[LOCAL], FACTIONS[LOCAL].region_list
    f.region_list = function() return list({ C, B, A }) end
    local CHEAP = { price = 75, mult = 25, base = 300, buy = 82, sell = 68, cover = 20 }
    local DEAR = { price = 525, mult = 175, base = 300, buy = 577, sell = 477, fullness = 25 }
    local FAIR = { price = 300, mult = 100, base = 300, buy = 330, sell = 272, cover = 1 }
    local lots = { { region = "reg_b", from = B, n = 150, price = 68 }, { region = "reg_a", from = A, n = 30, price = 40 } }
    local BAD = false   -- Iron's quote with neither cover nor fullness, which no real quote lacks
    DERPY_MR_FLOWS = {
        rates = function() return { actions = true } end, request = function() end,
        owned = function(_, key) return ({ reg_a = A, reg_b = B })[key] end,
        quote = function(f, r, stem)
            eq(f:name(), LOCAL, "the local faction's quote")
            if stem == "coal" then return r:name() == "reg_b" and CHEAP or DEAR end
            if stem == "iron" and BAD then return { price = 75, mult = 25, base = 300, buy = 82, sell = 68 } end
        end,
        sale = function() return { n = 180, gold = 114, price = 63, lots = lots } end,
        series = function() return { 3, 4, 5 }, { 0, 50, 100 } end, last = function() return { made = 12 } end,
    }
    local function has(text, part) return string.find(text, part, 1, true) ~= nil end
    local PRICE = "The price is 0.75 instead of 3.00.\nIt is cheap because the stores hold 20 turns of war materials.\nYou buy for 0.82 and sell for 0.68."
    eq(S.price_tip(CHEAP, "war"), PRICE, "stock cover, below 100, counted over the category")
    eq(S.price_tip(DEAR, "war"), "The price is 5.25 instead of 3.00.\nIt is expensive because the store is 25% full.\nYou buy for 5.77 and sell for 4.77.", "fullness, above 100")
    eq(S.price_tip(FAIR, "war"), "The price is the normal 3.00.\nYou buy for 3.30 and sell for 2.72.", "at 100")
    eq(S.price_tip(CHEAP, "provisions"), "The price is 0.75 instead of 3.00.\nIt is cheap because the stores hold 20 turns of provisions.\nYou buy for 0.82 and sell for 0.68.", "each category by its own word")
    eq(S.use_of("coal"), "war", "a good's use comes from the goods list")
    -- a settlement's stores: Bravo's coal is full and cheap, its iron has no price
    S.view = "settlements"; S.show(true, "reg_b")
    eq(find("hdr_4").text, "Price", "the settlement view's fourth header")
    local coal, iron
    for _, r in ipairs(S.data) do if r.stem == "coal" then coal = r elseif r.stem == "iron" then iron = r end end
    eq(coal[2], "200 / 200 [[col:red]]Full[[/col]]", "a full store keeps its mark in Held / Space")
    eq(coal[4], "0.75", "the price in gold to the hundredth"); eq(cell(1, 4).text, "0.75", "drawn in the fourth cell")
    eq(has(coal.tip, PRICE), true, "the tooltip carries the price sentence"); eq(has(coal.tip, "cheap because"), true, "cheap")
    eq(has(coal.tip, S.FULL_TIP), true, "and still says the store is full")
    eq(iron[2], "50 / 200", "not full: no mark"); eq(iron[4], "-", "a good with no quote shows a dash")
    eq(has(iron.tip, "The price is"), false, "and no price sentence")
    eq(find("hdr_4").halign, "right", "the Price head is right-aligned like the figures before it")
    eq(cell(1, 4).halign, "right", "and so is its cell"); eq(cell(1, 3).halign, "right", "as Per turn is")
    dump("settlement_focus")   -- the preview draws Bravo with its prices (overwrites Alpha's plain dump)
    -- a quote the sentence cannot be built from: the price still shows, with no sentence, and no error
    BAD = true; S.refresh()
    for _, r in ipairs(S.data) do if r.stem == "iron" then iron = r end end
    eq(iron[4], "0.75", "a malformed quote still gives its price"); eq(has(iron.tip, "The price is"), false, "and no sentence")
    eq(#ERRORS, 0, "and raises nothing"); BAD = false
    -- a good's drill-down: a row a settlement, each with its own price
    S.view = "goods"; S.show(true, "coal")
    eq(find("hdr_4").text, "Price", "the good drill-down's fourth header")
    eq(S.data[1][1], "Bravo", "most held first"); eq(S.data[1][2], "200 / 200 [[col:red]]Full[[/col]]", "the full mark in Held / Space")
    eq(S.data[1][4], "0.75", "Bravo's price"); eq(S.data[2][4], "5.25", "Alpha's price")
    eq(has(S.data[1].tip, S.FULL_TIP), true, "Bravo's tooltip still says full"); eq(has(S.data[1].tip, "cheap because"), true, "and cheap")
    eq(has(S.data[2].tip, "expensive because the store is 25% full"), true, "Alpha's says dear")
    eq(find("derpy_mr_sell").tip, "Sell the 180 Coal your stores hold over half full for 114 gold (0.63 each)."
        .. "\n150 from Bravo at 0.68\n30 from Alpha at 0.40", "the Sell tooltip lists each store's lot")
    eq(find("hdr_4").halign, "right", "the drill-down's Price head too"); eq(cell(1, 4).halign, "right", "and its cell")
    -- THE SELL TOOLTIP names at most 8 stores and counts the rest
    local many, want = {}, "Sell the 55 Coal your stores hold over half full for 100 gold (1.81 each)."
    for i = 1, 10 do many[i] = { region = "reg_" .. i, n = i, price = i } end
    for i = 1, 8 do want = want .. string.format("\n%d from reg_%d at 0.%02d", i, i, i) end
    eq(S.sell_tip({ n = 55, gold = 100, price = 181, lots = many }, "Coal"), want .. "\nand 2 more stores", "ten lots: eight lines and a count")
    many[10] = nil
    eq(S.sell_tip({ n = 55, gold = 100, price = 181, lots = many }, "Coal"), want .. "\nand 1 more store", "nine lots: the count is singular")
    many[9] = nil
    eq(S.sell_tip({ n = 55, gold = 100, price = 181, lots = many }, "Coal"), want, "eight lots: all named, no count")
    dump("goods_focus")   -- the preview draws the drill-down with prices and the chart (overwrites the plain dump)
    DERPY_MR_FLOWS, S.view, S.focus, f.region_list = fl, view, focus, regions
    S.show(false)
end)()
-- ---- PANEL SIZE (author, 2026-11-02: "UI size options, same as the derpy great guilds mod") -----
-- MCT's Small / Medium / Large, each its own set of .twui.xml with real fonts. The screen factor is
-- spent on the same choice, so 1440p's Medium draws Large's files (GGUI.pick_size).
eq(S.pick_size("medium", 1920, 1080, 1), "medium", "1080p: Medium is Medium")
eq(S.pick_size("small", 1920, 1080, 1), "small", "1080p: Small")
eq(S.pick_size("large", 1920, 1080, 1), "large", "1080p: Large")
eq(S.pick_size("huge", 1920, 1080, 1), "medium", "an unknown size opens at Medium")
eq(S.scale_for(2560, 1440), 1.33, "1440p is a third larger than the design screen")
eq(S.scale_for(1600, 900), 1, "never below the design size")
eq(S.pick_size("medium", 2560, 1440, 1.33), "large", "1440p: Medium draws Large's files")
eq(S.pick_size("small", 2560, 1440, 1.33), "medium", "and Small draws Medium's")
eq(S.pick_size("large", 1100, 800, 1), "medium", "a Large panel that does not fit the screen opens at Medium")
;(function()   -- a function, not a do block: the main chunk is at its 200 locals
    local want
    get_mct = function() return { get_mod_by_key = function(_, k)
        eq(k, "derpy_more_resources", "the size is this mod's own option")
        return { get_option_by_key = function(_, o)
            eq(o, "ui_size", "the Panel size option")
            return { get_finalized_setting = function() return want end } end } end } end
    local opener = find("derpy_mr_stores_button")
    REPEATS.derpy_mr_follow_bar()
    local ox, oy, ow = opener.x, opener.y, opener.w
    local campaign = CAMPAIGN
    S.view, S.focus = "goods", nil
    -- the size previews draw the Edicts section too
    local base_flows = DERPY_MR_FLOWS
    DERPY_MR_FLOWS = EDICT_FLOWS(base_flows)
    -- {size, file suffix, panel w, h, row pitch, a cell's drop into its row}
    for _, t in ipairs({ { "large", "_lg", 1147, 853, 37, 5 }, { "small", "_sm", 737, 549, 24, 3 },
                         { "medium", "", 860, 640, 28, 4 } }) do
        want = t[1]
        S.show(false); S.show(true)
        local pn = find("derpy_mr_stores_panel")
        eq(pn.file, "derpy_mr_stores_panel" .. t[2], t[1] .. ": the panel is built from its own files")
        eq(pn.w .. "x" .. pn.h, t[3] .. "x" .. t[4], t[1] .. ": the panel's size")
        eq(pn.x .. "," .. pn.y, math.floor((1920 - t[3]) / 2) .. "," .. math.floor((1080 - t[4]) / 2), t[1] .. ": centred")
        local n = 0
        for _, k in ipairs(UI_ROOT.kids) do if k.name == "derpy_mr_stores_panel" then n = n + 1 end end
        eq(n, 1, t[1] .. ": the panel at the old size is gone")
        eq(find("derpy_mr_row_1").file, "derpy_mr_stores_row" .. t[2], t[1] .. ": rows from its own file")
        eq(find("derpy_mr_row_2").y - find("derpy_mr_row_1").y, t[5], t[1] .. ": row pitch")
        eq(cell(1, 1).y - find("derpy_mr_row_1").y, t[6], t[1] .. ": a cell's place in its row scales too")
        eq(find("list_clip").h, DERPY_MR_STORES_L.ROWS * t[5], t[1] .. ": the list shows as many rows")
        REPEATS.derpy_mr_follow_bar()
        eq(opener.x .. "," .. opener.y .. "," .. opener.w, ox .. "," .. oy .. "," .. ow,
           t[1] .. ": the HUD opener keeps its size and place")
        if t[1] ~= "medium" then
            dump("size_" .. t[1])
            CAMPAIGN = "wh3_main_combi"; click("derpy_mr_tab_map")
            dump("size_" .. t[1] .. "_map")
            CAMPAIGN = campaign; click("derpy_mr_tab_goods")
        end
    end
    DERPY_MR_FLOWS = base_flows
    -- the same size again keeps the panel it has
    local before = find("derpy_mr_stores_panel")
    S.show(false); S.show(true)
    eq(find("derpy_mr_stores_panel") == before, true, "the same size reopens the same panel")
    S.show(false)
    get_mct = nil
end)()
eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))
-- NOTHING KEPT, the whole module (the 1.0 live pass, 2026-11-02): once every test above has run, no engine interface
-- is reachable from S through its tables or its functions' upvalues. A stub interface stands in for the engine's
-- userdata: a table with its own is_null_interface.
do
    local found, seen = {}, {}
    local function walk(v, path)
        if seen[v] then return end
        if type(v) == "table" then
            seen[v] = true
            if type(rawget(v, "is_null_interface")) == "function" then found[#found + 1] = path; return end
            for k, x in pairs(v) do walk(x, path .. "." .. tostring(k)) end
        elseif type(v) == "function" then
            seen[v] = true
            local i = 1
            while true do
                local name, x = debug.getupvalue(v, i)
                if not name then break end
                walk(x, path .. "<" .. name .. ">")
                i = i + 1
            end
        end
    end
    walk(S, "S")
    table.sort(found)
    assert(#found == 0, "engine interfaces kept in the stores module: " .. table.concat(found, " "))
end

-- the Trade tab's cut-off tip at the lowest reach said "more than 1 turns" (Workshop report, 2026-11-07)
do
    local one, six = S.cut_tip({}, 1), S.cut_tip({}, 6)
    eq(one:find("more than 1 turn,", 1, true) ~= nil, true, "a reach of one turn is singular")
    eq(six:find("more than 6 turns,", 1, true) ~= nil, true, "a longer reach is plural")
end

print("harness ok")
