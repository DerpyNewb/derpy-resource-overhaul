-- Derpy Resource Overhaul: the Stores panel. It shows what every settlement of the local
-- faction holds of each good, what its buildings add each turn, and how much space it has.
-- Read-only and local: nothing here writes the model, so it cannot desync multiplayer.
-- Spec: docs/superpowers/specs/2026-10-02-resource-overhaul-stores-design.md, section 5.
--
-- THE SHIPPED FILE IS GENERATED. tools/gen_mr_ui.py puts DERPY_MR_STORES_L (the layout) and
-- DERPY_MR_STORES_GOODS (the 54 goods) in front of this source. Edit this file, then run
-- py tools/gen_mr_ui.py.

DERPY_MR_STORES = DERPY_MR_STORES or {}
local S = DERPY_MR_STORES
local L = DERPY_MR_STORES_L

S.PREFIX = "derpy_mr_store_"
-- The measured route (docs/TRADE_RESOURCES.md section 19): it lists only the rows whose lore
-- condition holds, at their real value. The capacity effect has no "_stocked" and is skipped.
S.CCO = 'BuildingSlotList.JoinString(BuildingContext.EffectList.Filter(EffectKey.StartsWith("derpy_mr_store_")).JoinString(EffectKey + "=" + Value, ","), ",")'
S.NOTHING = "Nothing is stored yet. Stores fill each turn with what your buildings make."
S.NO_REALM = "You hold no settlements, so you have no stores."
S.FULL_TIP = "This store is full. Anything produced here beyond its space is lost."
S.NO_HISTORY = "No history yet - check back next turn."
S.view, S.focus = "goods", nil

function S.say(msg)
    pcall(out, "[derpy_mr_stores] " .. tostring(msg))
end

function S.num(n)
    if n == math.floor(n) then return string.format("%d", n) end
    return string.format("%.1f", n)
end

local function loc(key, fallback)
    local s = common.get_localised_string(key)
    if s == nil or s == "" then return fallback end
    return s
end

function S.name(stem) return loc("pooled_resources_display_name_" .. S.PREFIX .. stem, stem) end
function S.good_tip(g) return loc("resources_description_" .. g.res, "") end

-- "derpy_mr_store_<stem>_stocked=<n>,..." -> {stem = n}, summed over every building.
function S.parse_made(str)
    local out = {}
    for stem, v in string.gmatch(str or "", "derpy_mr_store_([%w_]-)_stocked=([%-%d%.]+)") do
        out[stem] = (out[stem] or 0) + (tonumber(v) or 0)
    end
    return out
end

-- One settlement. A save from before the stores has no derpy_mr_store_ pools: space 0,
-- nothing held, and the panel says so rather than failing.
function S.read_settlement(region)
    local key = region:name()
    local s = { key = key, name = loc("regions_onscreen_" .. key, key), level = 0, cap = 0,
                held = {}, made = {} }
    local list = region:pooled_resource_manager():resources()
    for i = 0, list:num_items() - 1 do
        local p = list:item_at(i)
        if not p:is_null_interface() then
            local k = p:key()
            if string.sub(k, 1, #S.PREFIX) == S.PREFIX then
                s.held[string.sub(k, #S.PREFIX + 1)] = p:value()
                if p:maximum_value() > s.cap then s.cap = p:maximum_value() end
            end
        end
    end
    local st = region:settlement()
    if not st:is_null_interface() then
        pcall(function() s.level = st:primary_slot():building():building_level() end)
        local ok, str = pcall(common.get_context_value, "CcoCampaignSettlement",
                              tostring(st:cqi()), S.CCO)
        if ok and type(str) == "string" then s.made = S.parse_made(str) end
    end
    return s
end

function S.read_realm(faction)
    local out = {}
    if not faction or faction:is_null_interface() then return out end
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        if not r:is_null_interface() then out[#out + 1] = S.read_settlement(r) end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- A settlement keeps a good when it holds some or its buildings add some.
local function keeps(s, stem)
    return (s.held[stem] or 0) > 0 or (s.made[stem] or 0) > 0
end

function S.full(held, cap) return cap > 0 and held >= cap end

local function by_held(a, b)
    if a.held ~= b.held then return a.held > b.held end
    return a.name < b.name
end

function S.goods_rows(realm)
    local out = {}
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do
        local r = { stem = g.stem, name = S.name(g.stem), icon = g.icon, res = g.res,
                    held = 0, made = 0, cap = 0, n = 0, of = #realm }
        for _, s in ipairs(realm) do
            if keeps(s, g.stem) then
                r.held = r.held + (s.held[g.stem] or 0)
                r.made = r.made + (s.made[g.stem] or 0)
                r.cap = r.cap + s.cap
                r.n = r.n + 1
            end
        end
        if r.n > 0 then out[#out + 1] = r end
    end
    table.sort(out, by_held)
    return out
end

function S.good_detail(realm, stem)
    local out = {}
    for _, s in ipairs(realm) do
        if keeps(s, stem) then
            local held = s.held[stem] or 0
            out[#out + 1] = { key = s.key, name = s.name, held = held, cap = s.cap,
                              made = s.made[stem] or 0, full = S.full(held, s.cap) }
        end
    end
    table.sort(out, by_held)
    return out
end

function S.settlement_detail(s)
    local out = {}
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do
        if keeps(s, g.stem) then
            local held = s.held[g.stem] or 0
            out[#out + 1] = { stem = g.stem, name = S.name(g.stem), icon = g.icon, res = g.res,
                              held = held, cap = s.cap, made = s.made[g.stem] or 0,
                              full = S.full(held, s.cap) }
        end
    end
    table.sort(out, by_held)
    return out
end

function S.settlement_rows(realm)
    local out = {}
    for _, s in ipairs(realm) do
        local r = { key = s.key, name = s.name, level = s.level, cap = s.cap, goods = 0,
                    fullest = nil, pct = 0, icons = {} }
        local kept = {}
        for _, g in ipairs(DERPY_MR_STORES_GOODS) do
            local held = s.held[g.stem] or 0
            if held > 0 then
                r.goods = r.goods + 1
                local pct = 0
                if s.cap > 0 then pct = math.floor(held * 100 / s.cap) end
                if r.fullest == nil or pct > r.pct then r.fullest, r.pct = g.stem, pct end
            end
            if keeps(s, g.stem) then
                kept[#kept + 1] = { icon = g.icon, made = s.made[g.stem] or 0, held = held }
            end
        end
        -- most made first, then most held: what the settlement is FOR comes first
        table.sort(kept, function(a, b)
            if a.made ~= b.made then return a.made > b.made end
            return a.held > b.held
        end)
        for i = 1, math.min(#kept, L.ICONS) do r.icons[i] = kept[i].icon end
        out[#out + 1] = r
    end
    return out                      -- the realm is already in name order
end

function S.find_settlement(realm, key)
    for _, s in ipairs(realm) do
        if s.key == key then return s end
    end
    return nil
end

local function per_turn(n)
    if n > 0 then return "+" .. S.num(n) end
    return S.num(n)
end

local function full_mark(full)
    if full then return "[[col:red]]Full[[/col]]" end
    return ""
end

-- THE HISTORY (flows spec section 7), read from the flows script. Without it: none, no error.
function S.history(stem)
    local F = DERPY_MR_FLOWS
    if not (F and F.series and F.last) then return {}, {}, {} end
    local fk = cm:get_local_faction_name(true)
    local turns, totals = F.series(fk, stem)
    return turns, totals, F.last(fk, stem)
end

-- "Last turn: made +12, raided -30, traded in +5" - only the parts that are not zero. Raids and
-- plunder are netted; trade in and out are shown apart, since both happen every turn.
function S.last_line(l)
    local parts = {}
    local function add(label, n)
        if n ~= 0 then parts[#parts + 1] = label .. " " .. per_turn(n) end
    end
    add("made", l.made or 0)
    add("raided", (l.raided_in or 0) - (l.raided_out or 0))
    add("plundered", (l.plundered_in or 0) - (l.plundered_out or 0))
    add("traded in", l.traded_in or 0)
    add("traded out", -(l.traded_out or 0))
    if #parts == 0 then return "Last turn: no change" end
    return "Last turn: " .. table.concat(parts, ", ")
end

-- One bar a turn, oldest left, on one scale whose top is the series' highest total. A turn
-- with nothing keeps a BAR_MIN sliver so its tooltip can still be found.
function S.chart_model(turns, totals, last)
    turns, totals = turns or {}, totals or {}
    if #turns < 2 then return { chart_line = S.NO_HISTORY } end
    local top = 0
    for i = 1, #turns do
        if (totals[i] or 0) > top then top = totals[i] end
    end
    local c = { bars = {}, chart_top = S.num(top), chart_from = "Turn " .. turns[1],
                chart_to = "Turn " .. turns[#turns], chart_line = S.last_line(last or {}) }
    for i, t in ipairs(turns) do
        local v = totals[i] or 0
        local h = L.BAR_MIN
        if top > 0 then h = math.max(L.BAR_MIN, math.floor(v * L.bars[4] / top)) end
        c.bars[i] = { h = h, tip = "Turn " .. t .. ": " .. S.num(v) .. " held" }
    end
    return c
end

-- ---- the Trade tab ----------------------------------------------------------------------
S.STOPPED = "[[col:red]]Stopped[[/col]]"
S.ALLOWED = "Allowed"
S.DIRS = { "export", "import" }
S.GREY = "ui_font_inactive_grey"       -- CA's own, out of db/ui_colours_tables (102,102,102)

function S.grey(s) return "[[col:" .. S.GREY .. "]]" .. s .. "[[/col]]" end

-- The flows script's function `name`, or nil without it: the panel must not need it to open.
function S.flows(name)
    local F = DERPY_MR_FLOWS
    return F and F[name]
end

-- EVERY GOOD, held or not: refusing an import matters most for a good you have none of. The
-- realm's own - held or made somewhere - come first; the rest are greyed below them.
function S.trade_rows(realm)
    local out = {}
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do
        local r = { stem = g.stem, name = S.name(g.stem), icon = g.icon, res = g.res, held = 0,
                    own = false }
        for _, s in ipairs(realm) do
            r.held = r.held + (s.held[g.stem] or 0)
            if keeps(s, g.stem) then r.own = true end
        end
        out[#out + 1] = r
    end
    table.sort(out, function(a, b)
        if a.own ~= b.own then return a.own end
        return by_held(a, b)
    end)
    return out
end

function S.trade_line(l)
    local o, i = l.traded_out or 0, l.traded_in or 0
    if o == 0 and i == 0 then return "-" end
    return "sent " .. S.num(o) .. ", received " .. S.num(i)
end

function S.switch_tip(dir, stopped, name)
    if dir == "export" then
        if stopped then return name .. " stays in your stores. Click to allow it to leave by trade again." end
        return name .. " may leave your stores by trade. Click to stop it leaving."
    end
    if stopped then return "Your trade partners send you no " .. name .. ". Click to allow it again." end
    return "Your trade partners may send you " .. name .. ". Click to refuse it."
end

function S.rows_shown()
    if S.view == "goods" and S.focus then return L.CHART_ROWS end
    return L.ROWS
end

-- WHAT THE PANEL SHOWS NOW: a sub-title, five headers, and one table per row (its five cells,
-- an icon, a tooltip, and what a click on it opens). Pure, so the harness reads it directly.
function S.view_model(realm)
    local v = { rows = {}, empty = S.NOTHING }
    if S.view == "goods" and S.focus then
        v.title = "Where " .. S.name(S.focus) .. " is kept"
        v.heads = { "Settlement", "Held / Space", "Per turn", "", "" }
        for _, d in ipairs(S.good_detail(realm, S.focus)) do
            local tip = ""
            if d.full then tip = S.FULL_TIP end
            v.rows[#v.rows + 1] = { d.name, S.num(d.held) .. " / " .. S.num(d.cap),
                                    per_turn(d.made), full_mark(d.full), "", tip = tip }
        end
        v.chart = S.chart_model(S.history(S.focus))
    elseif S.view == "goods" then
        v.title = "Every good your settlements keep"
        v.heads = { "Good", "Held", "Per turn", "Space", "Stored in" }
        v.hint = "Click a good to see where it is kept."
        for _, g in ipairs(S.goods_rows(realm)) do
            v.rows[#v.rows + 1] = { g.name, S.num(g.held), per_turn(g.made),
                                    S.num(g.held) .. " / " .. S.num(g.cap), g.n .. " of " .. g.of,
                                    icon = g.icon, tip = S.good_tip(g), open = g.stem }
        end
        if #realm == 0 then v.empty = S.NO_REALM end
    elseif S.view == "trade" then
        v.title = "What your settlements trade"
        v.heads = { "Good", "Held", "Exports", "Imports", "Last turn" }
        local stopped, last = S.flows("stopped"), S.flows("last")
        local fk = cm:get_local_faction_name(true)
        local switches = stopped ~= nil and S.flows("send") ~= nil
        if switches then v.hint = "Click Exports or Imports to stop a good, or to allow it again." end
        for _, g in ipairs(S.trade_rows(realm)) do
            local row = { g.name, S.num(g.held), "", "", S.trade_line(last and last(fk, g.stem) or {}),
                          icon = g.icon, tip = S.good_tip(g), stem = g.stem }
            if not g.own then
                for j = 1, 5 do row[j] = row[j] ~= "" and S.grey(row[j]) or "" end
            end
            if switches then
                -- nothing to send of a good you neither hold nor make: no export switch
                if g.own then row.export = stopped(fk, "export", g.stem) end
                row.import = stopped(fk, "import", g.stem)
            end
            v.rows[#v.rows + 1] = row
        end
    elseif S.focus then
        local s = S.find_settlement(realm, S.focus)
        if not s then
            S.focus = nil
            return S.view_model(realm)
        end
        v.title = "Stores of " .. s.name
        v.heads = { "Good", "Held / Space", "Per turn", "", "" }
        for _, d in ipairs(S.settlement_detail(s)) do
            local tip = S.good_tip(d)
            if d.full then tip = S.FULL_TIP end
            v.rows[#v.rows + 1] = { d.name, S.num(d.held) .. " / " .. S.num(d.cap),
                                    per_turn(d.made), full_mark(d.full), "", icon = d.icon,
                                    tip = tip }
        end
    else
        v.title = "Every settlement you hold"
        v.heads = { "Settlement", "Level", "Space per good", "Goods held", "Fullest store" }
        v.hint = "Click a settlement to see its stores."
        for _, r in ipairs(S.settlement_rows(realm)) do
            local fullest = "-"
            if r.fullest then fullest = S.name(r.fullest) .. " " .. r.pct .. "%" end
            v.rows[#v.rows + 1] = { r.name, tostring(r.level), S.num(r.cap), tostring(r.goods),
                                    fullest, open = r.key, icons = r.icons }
        end
        v.empty = S.NO_REALM
    end
    return v
end

-- ==========================================================================================
-- THE UI. Built at runtime from ui/campaign ui/derpy_mr_stores_*.twui.xml (tools/gen_mr_ui.py).
-- Runtime components ignore XML offsets, so every part is placed here from DERPY_MR_STORES_L.
-- ==========================================================================================
S.PATH = "ui/campaign ui/"
S.BUTTON = "derpy_mr_stores_button"
S.PANEL = "derpy_mr_stores_panel"
S.CLOSE = "derpy_mr_close"
S.BACK = "derpy_mr_back"
S.TAB = { goods = "derpy_mr_tab_goods", settlements = "derpy_mr_tab_settlements",
          trade = "derpy_mr_tab_trade" }
S.SW = "derpy_mr_sw_"
S.ROW = "derpy_mr_row_"
S.LIST = "derpy_mr_stores_list"
S.SP = "derpy_mr_stores_sp"
S.BAR = "derpy_mr_bar_"
S.CHART_CELLS = { "chart_top", "chart_from", "chart_to", "chart_line" }
S.HUB_KEY = "mr"
S.SCROLL_MS = 16            -- every frame: the rows trail the bar by up to one tick
S.FOLLOW_MS = 300           -- the opener follows the strip's end a few times a second
S.PLACE_TRIES = 150         -- x2.0s: the HUD is not built at first tick
S.data = {}                 -- what each row shows, for the click handler
-- THE OPEN TAB IS LIT: CA's selected art on image 0 (standard) and 1 (hover), the order
-- tools/gen_mr_ui.py emits them in.
S.TAB_ART = {
    [true] = { "ui/skins/default/button_square_large_text_selected.png",
               "ui/skins/default/button_square_large_text_selected_hover.png" },
    [false] = { "ui/skins/default/button_square_large_text_active.png",
                "ui/skins/default/button_square_large_text_hover.png" },
}

function S.root() return core:get_ui_root() end
function S.panel() return find_uicomponent(S.root(), S.PANEL) end

local function sized(c, w, h)
    c:SetCanResizeWidth(true)
    c:SetCanResizeHeight(true)
    c:Resize(w, h, false)    -- false: without its children
end

-- box = {x, y, w, h} relative to the panel's (px, py)
local function put(c, px, py, box)
    if not is_uicomponent(c) then return end
    c:MoveTo(px + box[1], py + box[2])
    if box[3] then sized(c, box[3], box[4]) end
end

local function set(c, s)
    if is_uicomponent(c) then c:SetStateText(s or "") end
end

-- A BUTTON'S LABEL GOES IN BOTH STATES. SetStateText writes the current state only, so a label
-- set once vanished the moment the mouse arrived (seen in game 2026-10-02; EX's row buttons).
local function label(c, s)
    if not is_uicomponent(c) then return end
    c:SetState("hover")
    c:SetStateText(s)
    c:SetState("standard")
    c:SetStateText(s)
end

function S.build()
    local root = S.root()
    pcall(function() root:CreateComponent(S.PANEL, S.PATH .. "derpy_mr_stores_panel") end)
    local p = S.panel()
    if not is_uicomponent(p) then return nil end
    p:SetVisible(false)
    p:SetInteractive(false)
    set(find_uicomponent(p, "title_text"), "Stores")
    label(find_uicomponent(p, S.TAB.goods), "Goods")
    label(find_uicomponent(p, S.TAB.settlements), "Settlements")
    label(find_uicomponent(p, S.TAB.trade), "Trade")
    label(find_uicomponent(p, S.BACK), "Back")
    -- the chart's twenty bars, made once and kept; draw_chart sizes, shows and hides them
    for i = 1, L.BARS do
        pcall(function() p:CreateComponent(S.BAR .. i, S.PATH .. "derpy_mr_stores_bar") end)
        local b = find_uicomponent(p, S.BAR .. i)
        if is_uicomponent(b) then b:SetVisible(false) end
    end
    return p
end

-- Centred on the screen, computed and never read back (the Exchange's lesson).
function S.layout(p)
    local sw, sh = core:get_screen_resolution()
    sized(p, L.W, L.H)
    p:MoveTo(math.floor((sw - L.W) / 2), math.floor((sh - L.H) / 2))
    local px, py = p:Position()
    local boxes = { title_text = L.title, sub_title = L.sub_title, empty_text = L.empty,
                    hint_text = L.hint }
    boxes[S.CLOSE], boxes[S.BACK] = L.close, L.back
    boxes[S.TAB.goods], boxes[S.TAB.settlements] = L.tab_goods, L.tab_settlements
    boxes[S.TAB.trade] = L.tab_trade
    for name, box in pairs(boxes) do put(find_uicomponent(p, name), px, py, box) end
    for j, col in ipairs(L.cols) do
        put(find_uicomponent(p, "hdr_" .. j), px, py, { L.list[1] + col[1], L.head_y, col[2], 22 })
    end
end

-- ---- the list, drawn whole (docs/CUSTOM_UI.md, Scrolling lists; EX.ensure_list) -----------
-- THE HOLDER GOES HOME BEFORE ANY DESTROY: Destroy takes the children, and rows_holder's are
-- every row. If it cannot be got out, the list stays unscrolled rather than losing the rows.
function S.drop_list(p)
    S.list_key = nil
    local list = find_uicomponent(p, S.LIST)
    if not is_uicomponent(list) then return end
    local holder = find_uicomponent(p, "rows_holder")
    if is_uicomponent(holder) and is_uicomponent(find_uicomponent(list, "rows_holder")) then
        local hx, hy = holder:Position()
        pcall(function()
            p:Adopt(holder:Address())
            holder:MoveTo(hx, hy)
        end)
    end
    if not is_uicomponent(find_uicomponent(list, "rows_holder")) then
        pcall(function() list:Destroy() end)
    else
        local slider = find_uicomponent(list, "vslider")
        if is_uicomponent(slider) then slider:SetVisible(false) end
        S.list_broken = true
        S.say("the list could not hand its rows back - it draws unscrolled")
    end
end

function S.ensure_list(p, n)
    if S.list_broken then return end
    local key = S.view .. "|" .. tostring(S.focus) .. "|" .. n
    if key == S.list_key and is_uicomponent(find_uicomponent(p, S.LIST)) then
        S.follow_list(p)
        return
    end
    S.drop_list(p)
    if S.list_broken then return end
    local holder = find_uicomponent(p, "rows_holder")
    if not is_uicomponent(holder) then return end
    pcall(function() p:CreateComponent(S.LIST, S.PATH .. "derpy_mr_stores_list") end)
    local list = find_uicomponent(p, S.LIST)
    if not is_uicomponent(list) then return end
    local x, y = holder:Position()
    local w, h = L.list[3], S.rows_shown() * L.PITCH
    list:MoveTo(x, y)
    sized(list, w, h)
    local clip = find_uicomponent(list, "list_clip")
    local box = find_uicomponent(list, "list_box")
    local slider = find_uicomponent(list, "vslider")
    if not (is_uicomponent(clip) and is_uicomponent(box)) then return end
    clip:MoveTo(x, y)
    sized(clip, w, h)
    if is_uicomponent(slider) then
        slider:MoveTo(x + w - L.SLIDER_W, y)
        sized(slider, L.SLIDER_W, h)
        pcall(function() slider:SetProperty("maxValue", h - L.HANDLE_H) end)
        local handle = find_uicomponent(slider, "handle")
        if is_uicomponent(handle) then
            pcall(function() handle:SetProperty("max_height", h - L.HANDLE_H) end)
        end
        slider:SetVisible(n > S.rows_shown())
    end
    for i = 1, n do
        local name = S.SP .. "_" .. i
        pcall(function() box:CreateComponent(name, S.PATH .. "derpy_mr_stores_sp") end)
        local sp = find_uicomponent(box, name)
        if is_uicomponent(sp) then sized(sp, w, L.PITCH) end
    end
    pcall(function() box:Layout() end)
    if not pcall(function()
        clip:Adopt(holder:Address())
        holder:MoveTo(x, y)
    end) then
        S.drop_list(p)
        S.list_broken = true
        S.say("the list could not take its rows - it draws unscrolled")
        return
    end
    S.list_key = key
end

-- The engine scrolls list_box; rows_holder follows it, and its one MoveTo carries every row.
function S.follow_list(p)
    local list = find_uicomponent(p, S.LIST)
    if not is_uicomponent(list) then return end
    local clip = find_uicomponent(list, "list_clip")
    if not is_uicomponent(clip) then return end
    local box, holder = find_uicomponent(clip, "list_box"), find_uicomponent(clip, "rows_holder")
    if not (is_uicomponent(box) and is_uicomponent(holder)) then return end
    local hx, hy = holder:Position()
    local _, by = box:Position()
    if hy ~= by then holder:MoveTo(hx, by) end
end

function S.scroll_poll()
    if not S.list_key then return end
    local p = S.panel()
    if not is_uicomponent(p) or not p:Visible() then return end
    S.follow_list(p)
end

-- ---- rows ---------------------------------------------------------------------------------
function S.row(holder, i)
    local name = S.ROW .. i
    local r = find_uicomponent(holder, name)
    if is_uicomponent(r) then return r end
    pcall(function() holder:CreateComponent(name, S.PATH .. "derpy_mr_stores_row") end)
    return find_uicomponent(holder, name)
end

-- The Trade tab's two switches: shown where the row carries their state, which only a Trade row
-- does, and only with the flows script loaded.
local function draw_switches(r, rc, rx, ry)
    for j, d in ipairs(S.DIRS) do
        local sw = find_uicomponent(r, S.SW .. d)
        if is_uicomponent(sw) then
            local show = rc[d] ~= nil
            sw:SetVisible(show)
            if show then
                sw:MoveTo(rx + L.cols[2 + j][1], ry + 2)
                label(sw, rc[d] and S.STOPPED or S.ALLOWED)
                sw:SetTooltipText(S.switch_tip(d, rc[d], rc[1]), true)
            end
        end
    end
end

-- Rows are made once and kept; the ones past the end go hidden.
function S.draw_rows(p, rows)
    local holder = find_uicomponent(p, "rows_holder")
    if not is_uicomponent(holder) then return end
    local hx, hy = holder:Position()
    -- EVERY NAME STARTS AFTER THE WIDEST ROW'S ICONS: shifted per row, they ran ragged in game
    local widest = 0
    for _, rc in ipairs(rows) do widest = math.max(widest, #(rc.icons or { rc.icon })) end
    local shift = math.max(0, widest - 1) * L.ICON_PITCH
    local n = 0
    for i, rc in ipairs(rows) do
        local r = S.row(holder, i)
        if is_uicomponent(r) then
            n = i
            local rx, ry = hx, hy + (i - 1) * L.PITCH
            r:MoveTo(rx, ry)
            sized(r, L.list[3] - L.SLIDER_W, L.PITCH)
            local icons = rc.icons or { rc.icon }
            for k = 1, L.ICONS do
                local ic = find_uicomponent(r, k == 1 and "icon" or "icon" .. k)
                if is_uicomponent(ic) then
                    ic:MoveTo(rx + L.icon[1] + (k - 1) * L.ICON_PITCH, ry + L.icon[2])
                    ic:SetVisible(icons[k] ~= nil)
                    if icons[k] then ic:SetImagePath(icons[k], 0) end
                end
            end
            for j, col in ipairs(L.cols) do
                local c = find_uicomponent(r, "c" .. j)
                if is_uicomponent(c) then
                    c:MoveTo(rx + col[1] + (j == 1 and shift or 0), ry + 4)
                    set(c, rc[j])
                end
            end
            draw_switches(r, rc, rx, ry)
            local div = find_uicomponent(r, "divider")
            if is_uicomponent(div) then div:MoveTo(rx, ry + L.PITCH - 2) end
            r:SetTooltipText(rc.tip or "", true)
            r:SetVisible(true)
        end
    end
    local i = n + 1
    while true do
        local r = find_uicomponent(holder, S.ROW .. i)
        if not is_uicomponent(r) then break end
        r:SetVisible(false)
        i = i + 1
    end
end

-- c nil: every chart part hidden. c without bars: the one line saying why.
function S.draw_chart(p, c)
    local px, py = p:Position()
    for _, name in ipairs(S.CHART_CELLS) do
        local e = find_uicomponent(p, name)
        if is_uicomponent(e) then
            put(e, px, py, L[name])
            set(e, c and c[name] or "")
            e:SetVisible(c ~= nil)
        end
    end
    local bars = (c and c.bars) or {}
    local bx, by, bh = L.bars[1], L.bars[2], L.bars[4]
    for i = 1, L.BARS do
        local b = find_uicomponent(p, S.BAR .. i)
        if is_uicomponent(b) then
            local d = bars[i]
            if d then
                sized(b, L.BAR_W, d.h)
                b:MoveTo(px + bx + (i - 1) * L.BAR_PITCH, py + by + bh - d.h)
                b:SetTooltipText(d.tip, true)
            end
            b:SetVisible(d ~= nil)
        end
    end
end

function S.refresh()
    local p = S.panel()
    if not is_uicomponent(p) or not p:Visible() then return end
    local ok, f = pcall(function() return cm:get_faction(cm:get_local_faction_name(true)) end)
    local realm = S.read_realm(ok and f or nil)
    local v = S.view_model(realm)
    S.data = v.rows
    set(find_uicomponent(p, "sub_title"), v.title)
    for j = 1, 5 do set(find_uicomponent(p, "hdr_" .. j), v.heads[j]) end
    set(find_uicomponent(p, "hint_text"), v.hint or "")
    local back = find_uicomponent(p, S.BACK)
    if is_uicomponent(back) then back:SetVisible(S.focus ~= nil) end
    for view, name in pairs(S.TAB) do
        local t = find_uicomponent(p, name)
        if is_uicomponent(t) then
            local art = S.TAB_ART[view == S.view]
            t:SetImagePath(art[1], 0)
            t:SetImagePath(art[2], 1)
        end
    end
    local empty = find_uicomponent(p, "empty_text")
    if is_uicomponent(empty) then
        set(empty, v.empty)
        empty:SetVisible(#v.rows == 0)
    end
    -- THE HOLDER STARTS AT THE TOP; a kept list's poll puts it back where the bar is.
    local px, py = p:Position()
    put(find_uicomponent(p, "rows_holder"), px, py, L.list)
    -- AS TALL AS WHAT IT HOLDS (docs/CUSTOM_UI.md, drawn whole, step 5): a row outside its
    -- parent's box is not known to take clicks or the wheel.
    local holder = find_uicomponent(p, "rows_holder")
    if is_uicomponent(holder) then sized(holder, L.list[3], math.max(S.rows_shown(), #v.rows) * L.PITCH) end
    S.ensure_list(p, #v.rows)
    S.draw_rows(p, v.rows)
    S.draw_chart(p, v.chart)
end

function S.is_open()
    local p = S.panel()
    return is_uicomponent(p) and p:Visible()
end

-- Reopening keeps the tab and drops the drill-down. Interactive only while visible: a hidden
-- panel that still takes the mouse is a dead zone in the middle of the map.
function S.show(on)
    local p = S.panel()
    if not is_uicomponent(p) then p = S.build() end
    if not is_uicomponent(p) then return end
    S.list_key = nil
    if on then
        S.focus = nil
        p:SetVisible(true)
        S.layout(p)
        if not S.polling then
            S.polling = true
            cm:repeat_real_callback(function() pcall(S.scroll_poll) end, S.SCROLL_MS,
                                    "derpy_mr_stores_scroll")
        end
        S.refresh()
    else
        p:SetVisible(false)
    end
    p:SetInteractive(on and true or false)
end

function S.is_mine(name)
    return type(name) == "string" and (name == S.BUTTON or name == S.CLOSE or name == S.BACK
        or name == S.TAB.goods or name == S.TAB.settlements or name == S.TAB.trade
        or string.sub(name, 1, #S.ROW) == S.ROW or string.sub(name, 1, #S.SW) == S.SW)
end

-- A SWITCH NAMES NO GOOD: its row does, so the row is read off the clicked component's parent.
function S.click_switch(dir, component)
    if not component then return end
    local row = UIComponent(UIComponent(component):Parent())
    local i = tonumber(string.match(row:Id() or "", "^derpy_mr_row_(%d+)$"))
    local rc = i and S.data[i]
    local send = S.flows("send")
    if not (rc and rc.stem and send) then return end
    send(cm:get_local_faction_name(true), dir, rc.stem)
    return S.refresh()
end

function S.click(name, component)
    local dir = string.match(name, "^derpy_mr_sw_(%a+)$")
    if dir then return S.click_switch(dir, component) end
    if name == S.BUTTON then return S.show(not S.is_open()) end
    if name == S.CLOSE then return S.show(false) end
    if name == S.BACK then
        S.focus = nil
        return S.refresh()
    end
    for view, tab in pairs(S.TAB) do
        if name == tab then
            S.view, S.focus = view, nil
            return S.refresh()
        end
    end
    local i = tonumber(string.match(name, "^derpy_mr_row_(%d+)$"))
    local row = i and S.data[i]
    if row and row.open then
        S.focus = row.open
        return S.refresh()
    end
end

-- ---- the opener ---------------------------------------------------------------------------
function S.hubbed()
    return DERPY_HUB ~= nil and DERPY_HUB.manages ~= nil and DERPY_HUB.manages(S.HUB_KEY) == true
end

-- Right of resources_bar (the art, read with Dimensions), centred on it. Nil while the strip
-- is absent, or so far off screen that it is sliding in or away.
function S.anchor()
    local bar = find_uicomponent(S.root(), "resources_bar")
    if not is_uicomponent(bar) then return nil end
    local bx, by = bar:Position()
    local bw, bh = bar:Dimensions()
    local x, y = bx + bw + L.GAP, by + math.floor((bh - L.BUTTON) / 2)
    local sw, sh = core:get_screen_resolution()
    if x < -L.BUTTON or y < -L.BUTTON or x > sw or y > sh then return nil end
    return math.max(0, math.min(x, sw - L.BUTTON)), math.max(0, math.min(y, sh - L.BUTTON))
end

-- Created hidden, shown once placed. While the hub manages it, the hub places and shows it.
function S.place_button(attempt)
    local root = S.root()
    local b = find_uicomponent(root, S.BUTTON)
    if not is_uicomponent(b) then
        pcall(function() root:CreateComponent(S.BUTTON, S.PATH .. "derpy_mr_stores_button") end)
        b = find_uicomponent(root, S.BUTTON)
        if is_uicomponent(b) then b:SetVisible(false) end
    end
    if is_uicomponent(b) then
        if S.hubbed() then
            S.placed = true
            return
        end
        local x, y = S.anchor()
        if x then
            b:MoveTo(x, y)
            b:SetVisible(true)
            S.placed = true
            return
        end
    end
    if attempt < S.PLACE_TRIES then
        cm:callback(function() S.place_button(attempt + 1) end, 2.0, "derpy_mr_place_" .. attempt)
    end
end

-- The strip sizes to its content mid-turn, with no event for it, so the button follows.
function S.follow_bar()
    if not S.placed or S.hubbed() then return end
    local b = find_uicomponent(S.root(), S.BUTTON)
    if not is_uicomponent(b) then return end
    local x, y = S.anchor()
    if not x then return end
    local ax, ay = b:Position()
    if ax ~= x or ay ~= y then b:MoveTo(x, y) end
    if not b:Visible() then b:SetVisible(true) end
end

-- ---- the raid plate: the goods a raid takes, beside CA's raid values above the army --------
-- 3d_ui_parent > label_<character cqi> > list_parent > stance_holder > icon_stance > raid_holder,
-- read in game 2026-10-02. A copy of CA's own plate keeps the look; its text persists (measured).
S.PLATE = "raid_value_derpy_goods_"     -- .. k, one per good
S.PLATES = 3                            -- values shown per army or choice; the tooltip has every good
S.PLATE_MS = 500
S.ICON = {}
for _, g in ipairs(DERPY_MR_STORES_GOODS) do S.ICON[g.stem] = g.icon end
S.PLATE_LINES = 10
S.RAID_PATH = { "list_parent", "stance_holder", "icon_stance", "raid_holder" }

-- SHORT LINES: CA's tooltip wraps at about 50 characters, which split "Zharr-" from "Naggrund"
-- (seen in game 2026-10-02). The harness holds every line to TIP_CHARS.
S.TIP_CHARS = 44

-- head, one line a good (cut at PLATE_LINES), foot
local function tip_lines(head, parts, foot)
    local lines = { head }
    for i, part in ipairs(parts) do
        if i > S.PLATE_LINES then
            lines[#lines + 1] = "and " .. (#parts - S.PLATE_LINES) .. " more"
            break
        end
        lines[#lines + 1] = S.name(part.stem) .. " " .. S.num(part.n)
    end
    lines[#lines + 1] = foot
    return table.concat(lines, "\n")
end

function S.plate_tip(pv)
    local foot = "Lost: this army has no settlement"
    if pv.to then foot = "Into " .. loc("regions_onscreen_" .. pv.to, pv.to) end
    return tip_lines("Raiding takes, each turn:", pv.parts, foot)
end

-- ONE VALUE PER GOOD, each with that good's icon, most first, up to PLATES: copies of the first of
-- CA's `sources` found under `holder`, named prefix .. k. set_icon(plate, icon, tip) puts the icon
-- where that kind of plate keeps it. Values past the list, or all of them when parts is nil, hide.
local function draw_values(holder, sources, prefix, parts, tip, set_icon)
    for k = 1, S.PLATES do
        local part = parts and parts[k]
        local plate = find_uicomponent(holder, prefix .. k)
        if part then
            if not is_uicomponent(plate) then
                local src = false
                for _, name in ipairs(sources) do
                    src = find_uicomponent(holder, name)
                    if is_uicomponent(src) then break end
                end
                if not is_uicomponent(src) then return end
                plate = UIComponent(src:CopyComponent(prefix .. k))
            end
            set(plate, S.num(part.n))
            plate:SetTooltipText(tip, true)
            set_icon(plate, S.ICON[part.stem], tip)
            plate:SetVisible(true)
        elseif is_uicomponent(plate) then
            plate:SetVisible(false)
        end
    end
end

function S.plate(lab, cqi)
    local holder = find_uicomponent(lab, unpack(S.RAID_PATH))
    if not is_uicomponent(holder) then return end
    local preview, pv = S.flows("raid_preview"), nil
    if preview and holder:Visible() then
        local ch = cm:get_character_by_cqi(cqi)
        if ch and not ch:is_null_interface() then pv = preview(ch) end
    end
    -- Labour's plate first: the one measured. Gold's is every race's, if Labour is absent.
    -- A raid plate's icon is its image 1 (image 0 is the plate).
    draw_values(holder, { "raid_value_labour", "raid_value" }, S.PLATE, pv and pv.parts,
                pv and S.plate_tip(pv), function(plate, icon) plate:SetImagePath(icon, 1) end)
end

-- ---- the capture panel: Sack and Raze show the goods they take ---------------------------
-- settlement_captured > button_parent > <option id> > frame > icon_parent, read in game
-- 2026-10-02. A copy of CA's gold value (dy_income) wraps under CA's row; its text, tooltip and
-- icon persist (measured). The option id says which decision it is: DERPY_MR_CAPTURE_KIND.
S.CAPTURE = "derpy_mr_capture_goods_"   -- .. k, one per good
S.CAPTURE_VERB = { sack = "Sacking", raze = "Razing", occupy = "Occupying" }

function S.capture_tip(pv, kind)
    if kind == "occupy" then
        return tip_lines("Occupying keeps its stores:", pv.parts, "They stay in this settlement")
    end
    local foot = "Into your nearest settlement"
    if pv.lost then foot = "Lost: you hold no settlement" end
    return tip_lines(S.CAPTURE_VERB[kind] .. " takes:", pv.parts, foot)
end

-- dy_income's icon is its child `icon`, which carries its own tooltip.
local function capture_icon(plate, icon, tip)
    local ic = find_uicomponent(plate, "icon")
    if not is_uicomponent(ic) then return end
    ic:SetImagePath(icon, 0)
    ic:SetTooltipText(tip, true)
end

function S.capture_plate(opt, pv, kind)
    local holder = find_uicomponent(opt, "frame", "icon_parent")
    if not is_uicomponent(holder) then return end
    draw_values(holder, { "dy_income" }, S.CAPTURE, pv and pv.parts,
                pv and S.capture_tip(pv, kind), capture_icon)
end

function S.capture_poll()
    local sc = find_uicomponent(S.root(), "settlement_captured")
    if not is_uicomponent(sc) or not sc:Visible() then return end
    local preview = S.flows("capture_preview")
    if not preview then return end
    local key = sc:GetContextObjectId("CcoCampaignSettlement")
    if not key or key == "" then return end
    local region = cm:get_region(key)
    local taker = cm:get_faction(cm:get_local_faction_name(true))
    if not region or not taker then return end
    local bp = find_uicomponent(sc, "button_parent")
    if not is_uicomponent(bp) then return end
    for i = 0, bp:ChildCount() - 1 do
        local opt = UIComponent(bp:Find(i))
        local kind = DERPY_MR_CAPTURE_KIND[tonumber(opt:Id())]
        if kind then S.capture_plate(opt, preview(region, taker, kind), kind) end
    end
end

-- One poll for both: the army plates and the capture panel.
function S.plate_poll()
    S.capture_poll()
    local p3d = find_uicomponent(S.root(), "3d_ui_parent")
    if not is_uicomponent(p3d) then return end
    for i = 0, p3d:ChildCount() - 1 do
        local lab = UIComponent(p3d:Find(i))
        local cqi = tonumber(string.match(lab:Id() or "", "^label_(%d+)$"))
        if cqi then S.plate(lab, cqi) end
    end
end

function S.init()
    if S.started then return end
    S.started = true
    local ok, err = pcall(S.place_button, 1)
    if not ok then S.say(err) end
    cm:repeat_real_callback(function() pcall(S.follow_bar) end, S.FOLLOW_MS, "derpy_mr_follow_bar")
    -- SAID ONCE: a fault here would otherwise fill the log twice a second
    cm:repeat_real_callback(function()
        local done, e = pcall(S.plate_poll)
        if not done and not S.plate_said then
            S.plate_said = true
            S.say(e)
        end
    end, S.PLATE_MS, "derpy_mr_raid_plate")
    core:add_listener("derpy_mr_stores_click", "ComponentLClickUp",
        function(context) return S.is_mine(context.string) end,
        function(context)
            local done, e = pcall(S.click, context.string, context.component)
            if not done then S.say(e) end
        end, true)
    core:add_listener("derpy_mr_stores_turn", "FactionTurnStart",
        function(context) return context:faction():name() == cm:get_local_faction_name(true) end,
        function()
            local done, e = pcall(S.refresh)
            if not done then S.say(e) end
        end, true)
end

cm:add_first_tick_callback(function() S.init() end)

-- THE HUB'S REGISTRATION: a plain table, so load order against the hub copies does not matter.
DERPY_HUB_QUEUE = DERPY_HUB_QUEUE or {}
table.insert(DERPY_HUB_QUEUE, {
    key = S.HUB_KEY, button = S.BUTTON, order = 4,
    label = function() return "Stores" end,
    live = function() return true end,
})
