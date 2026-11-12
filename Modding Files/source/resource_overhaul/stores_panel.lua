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

-- TRANSLATABLE TEXT (asked 2026-11-05 by a translator): every sentence the panel writes goes through
-- S.T(english, ...). DERPY_MR_LOC_KEYS (generated) gives its key in text/db/derpy_mr_ui.loc, so a
-- translation pack overrides that loc and nothing here. {1}, {2}... are the arguments, in any order the
-- translation needs. Not a string, no key, or no loc row: the English, unchanged.
S.T_CACHE = S.T_CACHE or {}
function S.T(text, ...)
    if type(text) ~= "string" then return text end
    local out = S.T_CACHE[text]
    if out == nil then
        out = text
        local key = DERPY_MR_LOC_KEYS and DERPY_MR_LOC_KEYS[text]
        if key and common and common.get_localised_string then
            local ok, s = pcall(common.get_localised_string, key)
            -- the loc arrives through RPFM's TSV import, which cannot hold a line break: \n is kept as two characters
            if ok and type(s) == "string" and s ~= "" and s ~= key then out = (string.gsub(s, "\\n", "\n")) end
            -- the game trims a loc string's leading spaces: " provisions" came back "provisions" (2026-11-10)
            local lead = string.match(text, "^%s+")
            if lead and not string.match(out, "^%s") then out = lead .. out end
        end
        S.T_CACHE[text] = out
    end
    if select("#", ...) == 0 then return out end
    local args = { ... }
    return (string.gsub(out, "{(%d+)}", function(i)
        local v = args[tonumber(i)]
        if v == nil then return "" end
        return tostring(v)
    end))
end

-- THE GENERATED LISTS' TEXT, put through S.T once: only the named fields, never a key or a use
function S.localise(list, fields)
    for _, row in ipairs(list or {}) do
        for _, f in ipairs(fields) do
            if type(row[f]) == "string" then row[f] = S.T(row[f]) end
        end
        for _, o in ipairs(row.options or {}) do
            for _, f in ipairs(fields) do
                if type(o[f]) == "string" then o[f] = S.T(o[f]) end
            end
        end
    end
end
S.localise(DERPY_MR_STORES_ORDERS, { "label", "what" })
S.localise(DERPY_MR_STORES_SUPPLY, { "label", "what" })
S.localise(DERPY_MR_STORES_WORKS, { "name", "gives", "detail" })
S.localise(DERPY_MR_STORES_EDICTS, { "name", "tip", "label", "tip_chd" })
for _, names in pairs(DERPY_MR_STORES_FOUND or {}) do
    for i = 1, #names do names[i] = S.T(names[i]) end
end

S.PREFIX = "derpy_mr_store_"
-- The measured route (docs/TRADE_RESOURCES.md section 19): it lists only the rows whose lore
-- condition holds, at their real value. The capacity effect has no "_stocked" and is skipped.
S.CCO = 'BuildingSlotList.JoinString(BuildingContext.EffectList.Filter(EffectKey.StartsWith("derpy_mr_store_")).JoinString(EffectKey + "=" + Value, ","), ",")'
S.NOTHING = S.T("Nothing is stored here yet.")
S.NO_REALM = S.T("You hold no settlements and so have no stores.")
-- a settlement whose main building makes none of our goods (flows.lua F.charted, 2026-11-11)
S.UNCHARTED = S.T("Its buildings make no goods yet. It grows its own food, and other goods come by trade.")
S.FULL_TIP = S.T("This store is full and anything more made here is lost.")
S.NO_HISTORY = S.T("The history starts next turn.")
S.view, S.focus = "goods", nil

function S.say(msg)
    pcall(out, "[derpy_mr_stores] " .. tostring(msg))
end

function S.num(n)
    if n == math.floor(n) then return string.format("%d", n) end
    return string.format("%.1f", n)
end

-- Hundredths of a gold as "0.75"; whole numbers only, so no float format can round it.
function S.money(c)
    local pct = 100
    return math.floor(c / pct) .. "." .. string.format("%02d", c % pct)
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
-- nothing held, and the panel says so rather than failing. `bare`: no display name, for the
-- flows' turn-start snapshot - a loc read from a turn handler CTD'd turn 1 of a fresh campaign.
function S.read_settlement(region, bare)
    local key = region:name()
    local s = { key = key, name = bare and key or loc("regions_onscreen_" .. key, key), level = 0, cap = 0,
                held = {}, made = {}, using = {} }
    -- what its stores give it (phase 4), in DERPY_MR_STORES_BUNDLES order
    for _, b in ipairs(DERPY_MR_STORES_BUNDLES) do
        local ok, on = pcall(function() return region:has_effect_bundle(b.key) end)
        if ok and on then s.using[#s.using + 1] = b end
    end
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
        if ok and type(str) == "string" then s.made = S.parse_made(str); s.made_known = true end
    end
    return s
end

function S.read_realm(faction, bare)
    local out = {}
    if not faction or faction:is_null_interface() then return out end
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        if not r:is_null_interface() then out[#out + 1] = S.read_settlement(r, bare) end
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

-- `also` (stem -> true): goods listed even when none is held or made - a recipe's inputs.
function S.settlement_detail(s, also)
    local out = {}
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do
        if keeps(s, g.stem) or (also and also[g.stem]) then
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
                    fullest = nil, pct = 0, icons = {}, using = s.using or {} }
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

-- The Held / Space cell, with the red Full mark after it when the store is at the brim.
local function held_space(d)
    local text = S.num(d.held) .. " / " .. S.num(d.cap)
    if d.full then return S.T("{1} [[col:red]]Full[[/col]]", text) end
    return text
end

-- A tooltip with one more line, the first line when it has none yet.
local function add_line(tip, line)
    if not line or line == "" then return tip end
    if tip == "" then return line end
    return tip .. "\n" .. line
end

-- The Price cell and its tooltip sentence for one store; "-" and no sentence when nothing quotes it.
-- A quote the sentence cannot be built from still gives its price, with no sentence.
function S.price_of(f, region, stem)
    local q = f and region and S.ask("quote", f, region, stem)
    if not q then return "-", nil end
    local ok, sentence = pcall(S.price_tip, q, S.use_of(stem))
    return S.money(q.price), ok and sentence or nil
end

-- The use a good is counted under ("war"): its price counts the stock of that whole category.
function S.use_of(stem)
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do if g.stem == stem then return g.use end end
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
    add(S.T("made"), l.made or 0)
    add(S.T("raided"), (l.raided_in or 0) - (l.raided_out or 0))
    add(S.T("plundered"), (l.plundered_in or 0) - (l.plundered_out or 0))
    add(S.T("traded in"), l.traded_in or 0)
    add(S.T("traded out"), -(l.traded_out or 0))
    add(S.T("eaten"), -(l.eaten_out or 0))
    add(S.T("spoiled"), -(l.spoiled_out or 0))
    add(S.T("moved"), (l.moved_in or 0) - (l.moved_out or 0))      -- netted: what the road lost
    add(S.T("spent"), -(l.spent_out or 0))
    add(S.T("sold"), -(l.sold_out or 0))
    if #parts == 0 then return S.T("Last turn: no change") end
    local line = S.T("Last turn: {1}", table.concat(parts, ", "))
    -- a busy turn drops its last parts rather than run past the chart line
    while #line * L.CHAR_W > L.chart_line[3] and #parts > 1 do
        parts[#parts] = nil
        line = S.T("Last turn: {1}, ...", table.concat(parts, ", "))
    end
    return line
end

-- "Grain over 250 spoils at 4% a turn, about 6 next turn." nil for a good that keeps.
function S.spoil_sentence(info, name)
    if not info then return nil end
    local s = S.T("{1} over {2} spoils at {3}% a turn", name, S.num(info.keep), S.num(info.rate))
    if info.due > 0 then return S.T("{1} and about {2} will spoil next turn.", s, S.num(info.due)) end
    return s .. "."
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
    local c = { bars = {}, chart_top = S.num(top), chart_from = S.T("Turn {1}", turns[1]),
                chart_to = S.T("Turn {1}", turns[#turns]), chart_line = S.last_line(last or {}) }
    for i, t in ipairs(turns) do
        local v = totals[i] or 0
        local h = L.BAR_MIN
        if top > 0 then h = math.max(L.BAR_MIN, math.floor(v * L.bars[4] / top)) end
        -- taken at the turn's start, before its eating and trade: the Held column is live
        c.bars[i] = { h = h, tip = S.T("Start of turn {1}: {2} held", t, S.num(v)) }
    end
    return c
end

-- ---- the Trade tab ----------------------------------------------------------------------
S.DIRS = { "export", "import" }
S.GREY = "ui_font_inactive_grey"       -- CA's own, out of db/ui_colours_tables (102,102,102)
S.BEIGE = "ui_font_faded_grey_beige"   -- likewise (169,159,137): the section row's label
S.DIM = 115                            -- a greyed row's icon and checkbox
-- CA's checkbox art on image 0 (standard) and 1 (hover): ticked is allowed, empty is stopped
S.CHECK = {
    [true] = { "ui/skins/default/checkbox_selected.png", "ui/skins/default/checkbox_selected_hover.png" },
    [false] = { "ui/skins/default/checkbox_active.png", "ui/skins/default/checkbox_hover.png" },
}

function S.grey(s) return S.T("[[col:{1}]]{2}[[/col]]", S.GREY, s) end
function S.section(s) return S.T("[[col:{1}]]{2}[[/col]]", S.BEIGE, s) end

-- THE SECTION ROW FOLDS: a click hides the resources you do not have. Kept while the campaign
-- runs, not saved.
S.folded = false
S.FOLD_TIP = { [false] = S.T("Click to hide the resources you do not have."),
               [true] = S.T("Click to show the resources you do not have.") }

-- ALL AT ONCE: one button per direction and mode, under the list on the Trade tab
S.BULK = "derpy_mr_all_"
S.BULK_ORDER = { { "export", "allow" }, { "export", "stop" }, { "import", "allow" }, { "import", "stop" } }
-- one whole sentence a label, so a translation can put the words in its own order
S.BULK_LABEL = { export = { allow = S.T("Allow all exports"), stop = S.T("Stop all exports") },
                 import = { allow = S.T("Allow all imports"), stop = S.T("Stop all imports") } }
S.BULK_TIP = {
    export = { allow = S.T("From next turn every resource can be traded again and earn trade income."),
               stop = S.T("From next turn no resource can be traded or earn trade income.\nYour own carts stop carrying them at once.") },
    import = { allow = S.T("Take every resource your trade partners send to your stores."),
               stop = S.T("Refuse every resource your trade partners send.\nYour own carts stop carrying them at once.\nYou and your partners still pay import duty.") },
}

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
    return S.T("sent {1} and received {2}", S.num(o), S.num(i))
end

S.DUTY_ICON = "ui/campaign ui/effect_bundles/income.png"
S.RECRUIT_HEAD = S.T("Recruits last turn")
S.CUT_ICON = "ui/campaign ui/effect_bundles/trade_agreement.png"
-- ROAD GUARDS (Part D 7.4): a sword, for armed men riding with the cargo (CA's shield icon draws as a blank disc)
S.GUARD_ICON = "ui/campaign ui/effect_bundles/attribute_unyielding_assault.png"
S.GUARDS_TIP = S.T("Guards ride with every cart and convoy you send.\nThey cost 5% of the cargo's value when it leaves.\nThey make trouble on the road half as likely.")
function S.cut_tip(cut, turns)
    local lines = { S.T("Nothing moves between you and these partners."),
        S.T("The road takes more than {1}, crosses hostile lands or has an enemy army on it.", (turns == 1 and S.T("1 turn") or S.T("{1} turns", turns))) }
    for _, c in ipairs(cut) do
        -- BLOCKADED (Part C): an enemy army on the road this turn, named
        local why = S.T(c.why) or (S.T("Blockaded by {1}", loc("factions_screen_name_" .. tostring(c.by), tostring(c.by))))
        lines[#lines + 1] = loc("factions_screen_name_" .. c.key, c.key) .. ": " .. why
    end
    return table.concat(lines, "\n")
end

-- "Tolls: 30 to Name, 12 to Name.": a cargo's tolls, the most first, equal amounts by key (Part C)
function S.tolls_text(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if t[a] ~= t[b] then return t[a] > t[b] end
        return a < b
    end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = S.T("{1} to {2}", S.num(t[k]), loc("factions_screen_name_" .. k, k)) end
    return S.T("Tolls: {1}.", table.concat(parts, ", "))
end

-- Last turn's tolls one way: a line per faction that paid or was paid.
function S.toll_tip(d, way)
    local lines = { way == "paid" and S.T("Last turn you paid these factions to cross their lands.")
                    or S.T("Last turn these factions paid you to cross your lands.") }
    local keys = {}
    for k, b in pairs(d.by) do if (b[way] or 0) > 0 then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = loc("factions_screen_name_" .. k, k) .. ": " .. S.num(d.by[k][way]) end
    if #keys == 0 then lines[#lines + 1] = S.T("Nothing last turn.") end
    return table.concat(lines, "\n")
end

-- AGREEMENT CONVOYS (flows.lua F.convoy_cargo lists every faction's): the viewer's own, going out or coming in.
function S.convoys_of(fk)
    local out = {}
    for _, c in ipairs(S.ask("convoy_cargo") or {}) do
        if c.f == fk or c.buyer == fk then out[#out + 1] = c end
    end
    return out
end

-- "40 Coal, 12 Iron": a basket, the most first, equal amounts by name
function S.basket_text(basket)
    local stems = {}
    for stem in pairs(basket or {}) do stems[#stems + 1] = stem end
    table.sort(stems, function(a, b)
        if basket[a] ~= basket[b] then return basket[a] > basket[b] end
        return a < b
    end)
    local parts = {}
    for _, stem in ipairs(stems) do parts[#parts + 1] = S.num(basket[stem]) .. " " .. S.name(stem) end
    return table.concat(parts, ", ")
end

S.CONVOY_LINES = 8   -- convoys a Cargo on the road tooltip names, soonest first; any more are counted

function S.convoy_tip(convoys)
    local sh = S.flows("SHIP")
    local lines = { S.T("An army at war with the sender can seize these goods from within {1} hexes when the sender begins its turn.", ((sh and sh.near) or 3)) }
    local soon = {}
    for i, c in ipairs(convoys) do soon[i] = c end
    -- equal turns in the order the convoys left: by the number in the id, since "10" sorts before "9" as text
    local function seq(c) return tonumber(string.match(c.id, "%d+$")) or 0 end
    table.sort(soon, function(a, b)
        if a.due ~= b.due then return a.due < b.due end
        if seq(a) ~= seq(b) then return seq(a) < seq(b) end
        return a.id < b.id
    end)
    for i = 1, math.min(#soon, S.CONVOY_LINES) do
        local c = soon[i]
        lines[#lines + 1] = S.T("From {1} to {2} by turn {3}: {4}", S.place(c.from), S.place(c.to), tostring(c.due), S.basket_text(c.basket))
        if type(c.tolls) == "table" and next(c.tolls) then lines[#lines + 1] = S.tolls_text(c.tolls) end
    end
    local more = #soon - S.CONVOY_LINES
    if more > 0 then lines[#lines + 1] = S.T("and {1} more {2}", more, (more == 1 and S.T("convoy") or S.T("convoys"))) end
    return table.concat(lines, "\n")
end

function S.duty_tip(d, pct)
    local lines = { S.T("Each turn you and each trade partner you can reach pay {1}% of the value of what the other makes.", pct),
        S.T("Last turn:") }
    local keys = {}
    for k in pairs(d.by) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        lines[#lines + 1] = S.T("{1}: paid {2} and received {3}", loc("factions_screen_name_" .. k, k), S.num(d.by[k].paid), S.num(d.by[k].got))
    end
    if #keys == 0 then lines[#lines + 1] = S.T("Nothing paid or received.") end
    return table.concat(lines, "\n")
end

-- Says how partners pick a good, that it is free, and that a switch also stops your own carts (F.ship checks both).
function S.switch_tip(dir, stopped, name)
    if dir == "export" then
        if stopped then
            return S.T("{1} is kept out of trade and earns no trade income.\nYour own carts do not carry it either.\nClick to trade it again from next turn.", name)
        end
        return S.T("{1} can be traded and earns trade income.\nClick to keep it out of trade from next turn. Your own carts stop carrying it at once.", name)
    end
    if stopped then
        return S.T("Your trade partners send you no {1}, and your own carts do not carry it.\nYou and your partners still pay import duty.\nClick to take it again.", name)
    end
    return S.T("Your trade partners can send {1} to your capital.\nA partner sends it until your capital holds the wanted amount. It comes from the partner's cheapest store, and only while it sells for at least 10% more in your capital.\nThe goods cost you nothing. You and your partners pay import duty whether they come or not.\nClick to refuse it. Your own carts stop carrying it at once.", name)
end

-- which of DERPY_MR_STORES_L.VIEWS the panel shows: both drill-downs share "focus"; the
-- Workshop's upgrade drill-down has its own
function S.view_key()
    if S.view == "trade" and S.focus then return "trade_focus" end
    if S.view == "workshop" then return S.focus and "workshop_focus" or "workshop" end
    if S.view == "spending" and S.focus and string.sub(S.focus, 1, 5) == "army:" then return "spending" end
    if S.focus and (string.sub(S.focus, 1, 6) == "route:" or string.sub(S.focus, 1, 7) == "routes:") then return "trade_focus" end
    if S.focus then return "focus" end
    return S.view
end

-- ---- the actions (spending spec section 5, phase 7) ------------------------------------
S.SEND = "derpy_mr_sendhere"
S.POLICY = "derpy_mr_policy_"
S.ORDER = "derpy_mr_order_"
S.SELL = "derpy_mr_sell"
S.NO_SHIPS = S.T("Use Send here in a settlement to put goods on the road.")
S.SUPPLY_KEY = {}
for _, sp in ipairs(DERPY_MR_STORES_SUPPLY) do S.SUPPLY_KEY[sp.key] = true end
S.USE_WORD = { provisions = S.T("provisions"), building = S.T("building materials"), war = S.T("war materials"),
               mounts = "mounts", luxuries = "luxuries" }
S.act = { orders = {} }      -- what the shown action buttons do, for the click handler

-- Only with the flows script loaded and its MCT switch on.
function S.actions_on()
    local rates = S.flows("rates")
    if not (rates and S.flows("request")) then return false end
    local ok, r = pcall(rates)
    return ok and type(r) == "table" and r.actions == true
end

-- The flows script's `name`, called safely: a throw is logged and reads as "cannot".
function S.ask(name, ...)
    local fn = S.flows(name)
    if not fn then return nil end
    local ok, r = pcall(fn, ...)
    if ok then return r end
    S.say(r)
    return nil
end

function S.local_faction()
    local ok, f = pcall(function() return cm:get_faction(cm:get_local_faction_name(true)) end)
    if ok and f and not f:is_null_interface() then return f end
    return nil
end

local function turns(n)
    if n == 1 then return S.T("1 turn") end
    return S.T("{1} turns", n)
end

function S.coming_total(coming)
    local n = 0
    for _, s in ipairs(coming or {}) do n = n + s.n end
    return n
end

-- A SHIPMENT since phase 5: it says how long, what is lost and the risk, and lists what is
-- already on the road to this store (`coming`, the flows script's ships_to).
-- Either trade switch of the local faction stops `stem`'s carts (flows.lua F.ship and F.send_plan).
function S.switched_off(stem)
    local stopped = S.flows("stopped")
    if not (stopped and stem) then return false end
    local fk = cm:get_local_faction_name(true)
    return stopped(fk, "export", stem) == true or stopped(fk, "import", stem) == true
end

function S.send_tip(plan, d, coming)
    local out
    if plan and plan.busy then
        local f = S.local_faction()
        out = S.T("You already have {1} shipments on the road and cannot send more.", S.num((f and S.ask("ship_cap", f)) or 0))
    elseif plan then
        local from = loc("regions_onscreen_" .. plan.from:name(), plan.from:name())
        local sh = S.flows("SHIP")
        out = S.T("Send {1} {2} from {3}.\n{4} are lost on the way and the rest arrive in {5} or more.\nAn army at war with you can seize it.", S.num(plan.n), d.name, from, S.num(plan.n - plan.got), turns(plan.turns or (sh and sh.turns) or 2))
    elseif S.switched_off(d.stem) then
        out = S.T("Your trade switches stop carts carrying {1}.\nTick its boxes on the Trade tab again to send it.", d.name)
    elseif d.full then
        out = S.T("This store of {1} is full.", d.name)
    elseif d.cap > 0 and d.held + S.coming_total(coming) >= d.cap then
        out = S.T("What is already on the road will fill this store of {1}.", d.name)
    else
        out = S.T("No other settlement of yours can send {1}.", d.name)
    end
    for _, s in ipairs(coming or {}) do
        out = S.T("{1}\n{2} more arrive here on turn {3}.", out, S.num(s.n), tostring(S.ask("ship_due", s) or s.due))
    end
    return out
end

-- Province supplies (phase 5): only with the flows script loaded and its MCT switch on.
function S.supply_on()
    local rates = S.flows("rates")
    if not (rates and S.flows("request")) then return false end
    local ok, r = pcall(rates)
    return ok and type(r) == "table" and r.supply == true
end

-- WHICH GOODS PAY: every good of the use, each after its icon (author, 2026-10-07: "no icon for
-- materials on what resource that is"). "War materials" alone does not say that Coal is one.
-- A rare good never pays as its use (flows.lua F.bulk): only the Workshop's own works take it
function S.use_goods(use)
    local out = {}
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do
        if g.use == use and not g.rare then out[#out + 1] =S.T("[[img:{1}]][[/img]] {2}", g.icon, S.name(g.stem)) end
    end
    local word = S.USE_WORD[use] or use
    return string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2) .. ": " .. table.concat(out, ", ") .. ".\n"
end

function S.supply_tip(sp, st, name)
    local stores = S.T("the stores of {1}", name)
    local out = sp.label .. "\n"
    if sp.use == "" then
        out = S.T("{1}Your other settlements in this province send more when {2} run low.\n", out, stores)
    else
        out = S.T("{1}Pay {2} {3} a turn from {4}: {5} in every settlement you hold in this province.\n{6}The stores of {7} hold {8}.\n", out, S.num(st.cost), (S.USE_WORD[sp.use] or sp.use), stores, sp.what, S.use_goods(sp.use), name, S.num(st.have[sp.use] or 0))
        if st.short[sp.key] then
            out = S.T("{1}Turned off on turn {2} because {3} ran short.\n", out, st.short[sp.key], stores)
        end
    end
    if st.on[sp.key] then return S.T("{1}Click to stop it.", out) end
    return S.T("{1}Click to start it.", out)
end

function S.order_tip(o, st)
    local word = S.USE_WORD[st.use] or st.use
    local out = S.T("{1}\nSpend {2} {3}: {4} for {5}.\n{6}", o.label, S.num(st.cost), word, o.what, turns(o.turns), S.use_goods(st.use))
    if st.active then return S.T("{1}Running for {2} more and ready again in {3}.", out, turns(st.active), turns(st.wait)) end
    if st.wait then return S.T("{1}Ready again in {2}.", out, turns(st.wait)) end
    if not st.ok then return S.T("{1}You have {2} {3}.", out, S.num(st.have), word) end
    return S.T("{1}You have {2}.\nClick to buy it.", out, S.num(st.have))
end

-- Cover is turns of the good's use in store (bulk goods), counted over the whole category; fullness is the store's percent (the rest).
-- "The price is 2.85 instead of 3.00." then "It is cheap because the store is 53% full." A full store is
-- cheap and an empty one expensive (flows.lua F.quote), so the reason is the store. One sentence a line (author).
function S.price_tip(q, use)
    local out
    if q.mult == 100 then
        out = S.T("The price is the normal {1}.", S.money(q.price))
    else
        local why = q.cover and (S.T("the stores hold {1}{2} of {3}", (q.mult > 100 and S.T("only ") or ""), turns(q.cover), (S.USE_WORD[use] or use))) or (S.T("the store is {1}% full", S.num(q.fullness)))
        out = S.T("The price is {1} instead of {2}.\nIt is {3} because {4}.", S.money(q.price), S.money(q.base), (q.mult < 100 and S.T("cheap") or S.T("expensive")), why)
    end
    return S.T("{1}\nYou buy for {2} and sell for {3}.", out, S.money(q.buy), S.money(q.sell))
end

S.SELL_LOTS = 8   -- lots a Sell tooltip names; any more are counted

function S.sell_tip(sale, name)
    if sale then
        local out = S.T("Sell the {1} {2} your stores hold over half full for {3} gold ({4} each).", S.num(sale.n), name, S.num(sale.gold), S.money(sale.price))
        local lots = sale.lots or {}
        for i = 1, math.min(#lots, S.SELL_LOTS) do
            out = S.T("{1}\n{2} from {3} at {4}", out, S.num(lots[i].n), S.place(lots[i].region), S.money(lots[i].price))
        end
        local more = #lots - S.SELL_LOTS
        if more > 0 then out = S.T("{1}\nand {2} more {3}", out, more, (more == 1 and S.T("store") or S.T("stores"))) end
        return out
    end
    return S.T("There is nothing worth selling.\nOnly what your stores of {1} hold over half full can be sold.", name)
end

-- THE PANEL'S SHADERS, CA's own, at the values CA's ui packs use most for that meaning (counted
-- 2026-10-04): glow_pulse_t0 1/2/3 (low, high, seconds) on "active" and "glow" states, red_pulse_t0
-- 0/0.25/1 on "insufficient", set_greyscale_t0 on "inactive" (alpha 0.6, the Exchange's, seen in game).
S.FX = {
    live = { "normal_t0" },
    off = { "set_greyscale_t0", 1, 0.6, 0, 0 },
    glow = { "glow_pulse_t0", 1, 2, 3, 0 },
    short = { "red_pulse_t0", 0, 0.25, 1, 0 },
}
function S.fx(c, kind)
    local f = S.FX[kind] or S.FX.live
    if not is_uicomponent(c) then return end
    pcall(function()
        c:ShaderTechniqueSet(f[1], true, true)
        if f[2] then c:ShaderVarsSet(f[2], f[3], f[4], f[5], true, true) end
    end)
end

-- GREYED, NOT JUST DISABLED: SetDisabled alone draws a live button (memory
-- wh3-setdisabled-draws-nothing).
function S.set_off(c, off)
    if not is_uicomponent(c) then return end
    off = off and true or false
    c:SetDisabled(off)
    S.fx(c, off and "off" or "live")
end

function S.rows_shown()
    if S.view == "goods" and S.focus then return L.CHART_ROWS end
    return L.ROWS
end

-- WHAT THE PANEL SHOWS NOW: a sub-title, five headers, and one table per row (its five cells,
-- an icon, a tooltip, and what a click on it opens). Pure, so the harness reads it directly.
-- FOUNDING A RARE BUILDING (spec 2026-10-09): a lore region no building slot offers it in gets one
-- row above its goods. The flows script decides; this only words it.
function S.found_row(fs, rkey)
    local names, price = DERPY_MR_STORES_FOUND[fs.good], S.T("{1} gold", S.num(fs.cost))
    local tip
    if fs.level == 0 then
        tip = S.T("Build {1} here at once for {2} even though no building slot here normally takes it.", names[1], price)
    else
        tip = S.T("Upgrade to {1} at once for {2}.", names[fs.next], price)
    end
    -- {1}, not string.format: a "%" in a translation would raise (2026-11-11)
    if fs.why == "gold" then tip = S.T("It needs {1} gold.", S.num(fs.cost))
    elseif fs.why == "tier" then tip = S.T("It needs a level {1} settlement.", fs.tier_need)
    elseif fs.why == "slot" then tip = S.T("It needs an empty building slot.") end
    -- the price in the fourth column, beside its button: under "Per turn" it read as income
    return { fs.level == 0 and names[1] or names[fs.level],
             fs.level == 0 and S.T("Not built") or (S.T("Level {1} of 3", fs.level)), "", price, "",
             icon = S.icon_of(fs.good), tip = tip, found = rkey,
             send = { label = fs.level == 0 and S.T("Found") or S.T("Upgrade"), tip = tip, off = fs.why ~= nil } }
end

function S.policy_context(stem)
    local f = S.local_faction()
    local cap = f and S.ask("capital", f)
    local v = cap and S.ask("stock_view", f, cap)
    if not v then return nil end
    local g
    for _, good in ipairs(DERPY_MR_STORES_GOODS) do if good.stem == stem then g = good; break end end
    if not g then return nil end
    local p = v.policy[stem] or {}
    local keep = g.rare and 0 or (v.auto_keep[g.use] or 0)
    local target = g.rare and (v.work_target[stem] or 0) or (v.auto_target[g.use] or 0)
    target = math.min(v.capacity[stem] or 0, math.max(target, p.keep or 0))
    return { view = v, good = g, policy = p, keep = keep, target = target, capital = cap:name() }
end

function S.trade_focus(v)
    v.title = S.T("Stock rules: {1}", S.name(S.focus))
    v.heads = { S.T("Rule"), S.T("Amount"), S.T("Less"), S.T("Default"), S.T("More") }
    v.empty = S.T("You need to hold a capital to set these.")
    local c = S.policy_context(S.focus)
    if not c then return end
    local shared = not c.good.rare
    local word = S.USE_WORD[c.good.use] or c.good.use
    for _, item in ipairs({ { "keep", S.T("Keep in each store") }, { "target", S.T("Wanted at your capital") } }) do
        local field, label = item[1], item[2]
        local n = c.policy[field]
        local value = n ~= nil and S.num(n) or (S.T("Auto: {1}", S.num(c[field])))
        local tip = field == "keep" and S.T("Every settlement keeps at least this much out of trade and sales.\nYour own spending and enemy raids can still take it.")
            or (S.T("Your trade partners send it to {1} until you have this much.\nSet it to 0 to stop them.", S.place(c.capital)))
        if n == nil and shared then tip = S.T("{1}\nOn Auto this amount covers all common {2} together.", tip, word) end
        v.rows[#v.rows + 1] = { label, value, "", "", "", policy = field, stem = S.focus, tip = tip }
    end
    v.hint = S.T("Less and More change it by 10 and Default sets it back to Auto.")
    local x, stem = c.view, S.focus
    v.rows[#v.rows + 1] = { S.T("Capital: {1}", S.place(c.capital)), "", "", "", "" }
    v.rows[#v.rows + 1] = { S.T("Held / on the way"), S.num(x.held[stem] or 0) .. " / " .. S.num(x.incoming[stem] or 0), "", "", "" }
    v.rows[#v.rows + 1] = { S.T("Still wanted"), S.num(S.ask("import_need", x, stem) or 0), "", "", "" }
    local q = S.ask("quote", x.faction, x.region, stem)
    v.rows[#v.rows + 1] = { S.T("Price at capital"), q and S.money(q.price) or "-", "", "", "",
        tip = S.T("Partners only send it while it sells for at least 10% more here than at home.") }
    local stopped = S.flows("stopped")
    if stopped then
        local fk = x.faction:name()
        v.rows[#v.rows + 1] = { S.T("Trade switches"), (stopped(fk, "export", stem) and S.T("Exports stopped") or S.T("Exports allowed")), "", "", "",
            tip = stopped(fk, "import", stem) and S.T("Nothing is asked for because imports are stopped.") or S.T("Imports are allowed up to the wanted amount and the free space.") }
    end
    if shared then
        v.rows[#v.rows + 1] = { S.T("All {1}", word), S.T("{1} held", S.num(x.totals[c.good.use] or 0)), "", "", "",
            tip = S.T("On Auto all common {1} share one reserve and one wanted amount.\nRare resources are not counted.", word) }
    else
        local names = {}
        local f = x.faction
        for _, w in ipairs(DERPY_MR_STORES_WORKS or {}) do
            local catalog = S.flows("WORK")
            local work = catalog and catalog[w.key]
            if work and work.rare == stem and S.ask("work_open", f, work) then names[#names + 1] = w.name end
        end
        v.rows[#v.rows + 1] = { S.T("Auto: enough for one Workshop purchase"), S.num(c.target), "", "", "",
            tip = #names > 0 and (S.T("Used by: {1}.", table.concat(names, ", "))) or "" }
    end
    for _, ship in ipairs(x.due or {}) do
        if ship.stem == stem then v.rows[#v.rows + 1] = { S.T("Arriving on turn {1}", tostring(ship.due)), S.num(ship.n), "", "", "" } end
    end
    if S.actions_on() then v.rows[#v.rows + 1] = { S.T("Set up a regular supply"), "", "", "", "",
        open = "routes:" .. c.capital .. ":" .. stem, tip = S.T("Pick one of your settlements or a trade partner to keep sending it here.") } end
end

S.ROUTE_TIP = S.T("Each cart carries up to 100 and loses a tenth as it sets out.\nA cart takes 1 to 6 turns depending on the road.")
S.CART_PRICE = S.T("You pay the selling price plus 10% or your own store price if that is higher.\nYou get your gold back if the cart is lost.")

function S.route_offers(v)
    v.title, v.heads = S.T("Set up a regular supply"), { S.T("From"), S.T("Spare"), S.T("Takes"), S.T("Price each"), "" }
    v.hint, v.empty = S.T("Press Create to start it and change it later under Spending."), S.T("Nobody has any to spare.")
    local rkey, stem = string.match(S.focus, "^routes:([%w_]+):([%w_]+)$")
    local f = S.local_faction()
    local to = f and rkey and S.ask("owned", f, rkey)
    if not to or not stem then return end
    local sources = { f }
    local ps = f:factions_trading_with()
    if type(ps) ~= "boolean" then for i = 0, ps:num_items() - 1 do sources[#sources + 1] = ps:item_at(i) end end
    table.sort(sources, function(a,b) return a:name() < b:name() end)
    local good = (S.flows("GOOD") or {})[stem]
    if not good then return end
    for _, seller in ipairs(sources) do
        local rl = seller:region_list()
        local ordered = {}
        for i = 0, rl:num_items() - 1 do ordered[#ordered + 1] = rl:item_at(i) end
        table.sort(ordered, function(a,b) return a:name() < b:name() end)
        for _, from in ipairs(ordered) do
            local x = S.ask("stock_view", seller, from)
            local available = x and S.ask("available_stock", x, stem) or 0
            if from:name() ~= rkey and available > 1 then
                local partner = seller:name() ~= f:name()
                local price = partner and S.ask("cart_price", seller, from, f, to, stem)
                local target = math.min(100, S.ask("free", to, stem) or 100)
                if target < 1 then target = 100 end
                local test = {seller=seller:name(),from=from:name(),to=rkey,stem=stem}
                local valid = S.ask("route_status", f, test, "show")
                for _, o in ipairs(S.ask("routes", f) or {}) do
                    if o.from == from:name() and o.to == rkey and o.stem == stem then valid = nil end
                end
                local tip = S.T("Sends {1} to {2} until you hold {3}.\n{4}", S.name(stem), S.place(rkey), target, S.ROUTE_TIP)
                if partner then tip = tip .. "\n" .. S.CART_PRICE end
                v.rows[#v.rows + 1] = { S.place(from:name()), S.num(available), S.T("at least {1}", turns(S.ask("route_turns", from, to) or 2)), partner and (price and S.money(price) or "-") or S.T("Your own"),
                    "", tip = tip, route_request = { "route_new", from:name(), rkey, stem, tostring(target), "100" },
                    send = { label = S.T("Create"), tip = tip, off = not valid } }
            end
        end
    end
end

function S.route_view(v)
    v.title, v.heads = S.T("Regular supply"), { S.T("Rule"), S.T("Amount"), S.T("Less"), S.T("Default"), S.T("More") }
    v.hint = S.T("Less and More change it by 10 and Default sets it to 100.")
    local id = string.sub(S.focus, 7)
    local f, order = S.local_faction(), nil
    for _, o in ipairs(f and S.ask("routes", f) or {}) do if o.id == id then order = o end end
    if not order then v.empty = S.T("This supply has ended."); return end
    local o = order
    local summary = S.T("{1} to {2}: {3}", S.place(o.from), S.place(o.to), S.name(o.stem))
    v.rows[#v.rows + 1] = { summary, S.T(o.status) or S.T("No cart sent yet"), "", "", "", tip = S.ROUTE_TIP }
    for _, field in ipairs({"target", "batch"}) do
        v.rows[#v.rows + 1] = { field == "target" and S.T("Stop at") or S.T("Cart size"), S.num(o[field]), "", "", "",
            policy = field, route = id, tip = field == "target" and S.T("Carts stop once you hold this much including what is on the way.")
                or S.T("Each cart carries this much (2 to 100).") }
    end
    if o.seller ~= f:name() then
        local terms = S.ask("route_status", f, o, "show")
        local now = terms and S.ask("cart_price", terms.seller, terms.from, f, terms.to, o.stem)
        v.rows[#v.rows + 1] = { S.T("Price each"), o.last_price_c and S.money(o.last_price_c) or S.T("Set per cart"), "", "", "",
            tip = S.T("The last cart cost this and the next one costs {1}.", (now and (S.T("{1} each", S.money(now))) or S.T("an unknown amount"))) }
    else
        v.rows[#v.rows + 1] = { S.T("Your own goods: free"), "", "", "", "" }
    end
    local escrow = 0
    for _, s in ipairs(S.ask("ships") or {}) do
        if s.f == f:name() and s.route == id then escrow = escrow + (s.escrow or 0) end
    end
    v.rows[#v.rows + 1] = { S.T("Gold set aside"), S.num(escrow), "", "", "" }
    v.rows[#v.rows + 1] = { o.enabled and S.T("Sending") or S.T("Paused"), "", "", "", "", route_request={"route_ctl",id,"toggle"},
        send={label=o.enabled and S.T("Pause") or S.T("Resume"),tip=S.T("Pause stops new carts but carts on the road still arrive.")} }
    v.rows[#v.rows + 1] = { S.T("End this supply"), "", "", "", "", route_request={"route_ctl",id,"cancel"},
        send={label=S.T("Cancel"),tip=S.T("End this supply and get back any gold set aside.\nYour own carts on the road still arrive.")} }
end

-- "a, b and c"
function S.join(parts)
    if #parts < 2 then return parts[1] or "" end
    return S.T("{1} and {2}", table.concat(parts, ", ", 1, #parts - 1), parts[#parts])
end

-- WHAT ONE CATEGORY DOES HERE EACH TURN, a sentence a line, for the category the tooltip is about and
-- the shipments of `stem` (or of the whole category without one). It was five categories of
-- "4 used/turn; net 2; stable" on every good, which the author called garbled (2026-11-01).
function S.forecast_tip(f, region, settlement, use, stem)
    local v = S.ask("stock_view", f, region)
    if not v then return "" end
    local made
    if settlement and settlement.made_known then
        made = {}
        for _, g in ipairs(DERPY_MR_STORES_GOODS) do
            if not g.rare then made[g.use] = (made[g.use] or 0) + (settlement.made[g.stem] or 0) end
        end
    end
    local fc = (S.ask("stock_forecast", v, made) or {})[use]
    if not fc then return "" end
    local lines = { S.T("{1} holds {2} {3}.", S.place(region:name()), S.num(fc.held), (S.USE_WORD[use] or use)) }
    local parts = {}
    if (fc.production or 0) > 0 then parts[#parts + 1] = S.T("makes {1}", S.num(fc.production)) end
    if fc.use_per_turn > 0 then parts[#parts + 1] = S.T("uses {1}", S.num(fc.use_per_turn)) end
    if #parts > 0 then lines[#lines + 1] = S.T("It {1} each turn.", table.concat(parts, S.T(" and "))) end
    if (fc.spoil or 0) > 0 then lines[#lines + 1] = S.T("It loses {1} to spoiling each turn.", S.num(fc.spoil)) end
    if fc.mode == "declining" then lines[#lines + 1] = S.T("At this rate it runs out in {1}.", turns(fc.cover))
    elseif fc.mode == "stored" then lines[#lines + 1] = S.T("That is enough for {1}.", turns(fc.cover)) end
    -- The parts of the "uses" figure above, from F.recurring_use; they add up to it.
    local rec = v.recurring or {}
    local named, production = rec.named or {}, 0
    for s, n in pairs(named) do if S.use_of(s) == use then production = production + n end end
    if fc.use_per_turn > 0 then
        if use == "provisions" and (rec.meals or 0) > 0 then
            lines[#lines + 1] = S.T("The settlement itself eats {1} of that each turn, {2} for each settlement level.", S.num(rec.meals), S.num(S.ask("need", f:name()) or 0))
        end
        if use == "provisions" and (rec.army_need or 0) > 0 then
            lines[#lines + 1] = S.T("Armies refilling here take {1} of that each turn.", S.num(rec.army_need))
        end
        local supplied = (rec.supplied or {})[use] or 0
        if supplied > 0 then lines[#lines + 1] = S.T("Province supplies take {1} of that each turn.", S.num(supplied)) end
        if production > 0 then lines[#lines + 1] = S.T("Production here takes {1} of that each turn.", S.num(production)) end
    end
    if stem and named[stem] then
        lines[#lines + 1] = S.T("Your production here uses {1} {2} a turn.", S.num(named[stem]), S.name(stem))
    end
    local due = {}
    for _, ship in ipairs(v.due or {}) do
        if ship.stem == stem or (not stem and S.use_of(ship.stem) == use) then
            local k = ship.stem .. "," .. ship.due
            if not due[k] then due[k] = { stem = ship.stem, due = ship.due, n = 0 }; due[#due + 1] = due[k] end
            due[k].n = due[k].n + ship.n
        end
    end
    table.sort(due, function(a, b) return a.due < b.due or (a.due == b.due and a.stem < b.stem) end)
    for _, d in ipairs(due) do
        lines[#lines + 1] = S.T("{1} {2} arrive on turn {3}.", S.num(d.n), S.name(d.stem), tostring(d.due))
    end
    return table.concat(lines, "\n")
end

function S.view_model(realm)
    local v = { rows = {}, empty = S.NOTHING }
    if S.focus and string.sub(S.focus, 1, 7) == "routes:" then S.route_offers(v)
    elseif S.focus and string.sub(S.focus, 1, 6) == "route:" then S.route_view(v)
    elseif S.view == "goods" and S.focus then
        v.title = S.T("Where {1} is kept", S.name(S.focus))
        v.heads = { S.T("Settlement"), S.T("Held / Space"), S.T("Per turn"), S.T("Price"), "" }
        local f = S.local_faction()
        for _, d in ipairs(S.good_detail(realm, S.focus)) do
            local tip = ""
            if d.full then tip = S.FULL_TIP end
            local price, sentence = S.price_of(f, f and S.ask("owned", f, d.key), S.focus)
            v.rows[#v.rows + 1] = { d.name, held_space(d), per_turn(d.made), price, "", tip = add_line(tip, sentence) }
        end
        v.chart = S.chart_model(S.history(S.focus))
        if S.actions_on() then
            local sale = f and S.ask("sale", f, S.focus)
            v.sell = { tip = S.sell_tip(sale, S.name(S.focus)), off = sale == nil }
        end
    elseif S.view == "goods" then
        v.title = S.T("Every resource your settlements keep")
        v.heads = { S.T("Resource"), S.T("Held"), S.T("Per turn"), S.T("Space"), S.T("Stored in") }
        v.hint = S.T("Click a resource to see where it is kept.")
        if #realm > 0 then S.edict_rows(v) end
        for _, g in ipairs(S.goods_rows(realm)) do
            v.rows[#v.rows + 1] = { g.name, S.num(g.held), per_turn(g.made),
                                    S.num(g.held) .. " / " .. S.num(g.cap), S.T("{1} of {2}", g.n, g.of),
                                    icon = g.icon, tip = S.good_tip(g), open = g.stem }
        end
        if #realm == 0 then v.empty = S.NO_REALM end
    elseif S.view == "spending" then
        if S.focus and string.sub(S.focus, 1, 5) == "army:" then S.army_view(v)
        elseif S.focus then S.escort_view(v) else S.spending(v) end
    elseif S.view == "workshop" then
        S.workshop(v, realm)
    elseif S.view == "production" then
        S.production(v, realm)
    elseif S.view == "map" then
        v.title = S.T("Where your settlements and convoys are")
        v.heads = { "", "", "", "", "" }
        v.hint = S.T("Click a convoy or a settlement to fly there.")
        local f = S.local_faction()
        if f then v.map = S.map_model(f, S.map_view) end
    elseif S.view == "trade" and S.focus then
        S.trade_focus(v)
    elseif S.view == "trade" then
        v.title = S.T("What your settlements trade")
        v.heads = { S.T("Resource"), S.T("Held"), S.T("Exports"), S.T("Imports"), S.T("Last turn") }
        local stopped, last = S.flows("stopped"), S.flows("last")
        local fk = cm:get_local_faction_name(true)
        local switches = stopped ~= nil and S.flows("send") ~= nil
        if switches then
            v.hint = S.T("Tick a box to allow trade or click a resource for its rules.")
            v.bulk = true
        end
        -- IMPORT DUTY, first: last turn's gold each way (flows.lua F.duty), while the rate is on
        local rates, duty, f = S.flows("rates"), S.flows("duty_last"), S.local_faction()
        if rates and duty and (rates().duty or 0) > 0 and f and S.ask("uses_stores", f) then
            local d = duty(fk) or { paid = 0, got = 0, by = {} }
            v.rows[#v.rows + 1] = { S.T("Import duty"), "", "", "", S.T("paid {1} and received {2}", S.num(d.paid), S.num(d.got)),
                                    icon = S.DUTY_ICON, tip = S.duty_tip(d, rates().duty) }
        end
        -- TOLLS (flows.lua F.tolls_last, Part C): last turn's gold each way. A row shows when it is above 0, and both
        -- at 0 while tolls are on and the player has a partner
        local tolls = S.flows("tolls_last")
        if rates and tolls and f and S.ask("uses_stores", f) then
            local t = tolls(fk) or { paid = 0, got = 0, by = {} }
            local r, ps = rates(), f:factions_trading_with()
            local on = r.tolls and (r.toll or 0) > 0 and type(ps) ~= "boolean" and ps:num_items() > 0
            for _, w in ipairs({ { "paid", S.T("Tolls paid") }, { "got", S.T("Tolls received") } }) do
                if t[w[1]] > 0 or on then
                    v.rows[#v.rows + 1] = { w[2], "", "", "", S.T("{1} gold", S.num(t[w[1]])), icon = S.DUTY_ICON,
                                            tip = S.toll_tip(t, w[1]) }
                end
            end
        end
        -- TRADE REACH: agreements moving nothing because the road is too long or blocked (flows.lua F.cut_off)
        local cut = rates and f and S.ask("cut_off", f)
        if cut and #cut > 0 then
            v.rows[#v.rows + 1] = { S.T("Trade cut off"), "", "", "", #cut .. (#cut == 1 and S.T(" partner") or S.T(" partners")),
                                    icon = S.CUT_ICON, tip = S.cut_tip(cut, rates().reach) }
        end
        -- CARGO ON THE ROAD: how many of your agreements' convoys are leaving and arriving (flows.lua F.convoy_cargo)
        local convoys = S.convoys_of(fk)
        if #convoys > 0 then
            local out = 0
            for _, c in ipairs(convoys) do if c.f == fk then out = out + 1 end end
            v.rows[#v.rows + 1] = { S.T("Cargo on the road"), "", "", "", S.T("{1} out and {2} in", S.num(out), S.num(#convoys - out)),
                                    icon = L.MAP_CART, tip = S.convoy_tip(convoys) }
        end
        -- ROAD GUARDS (flows.lua F.guards_on, Part D): the player's switch, while the bandits are on
        if rates and f and rates().bandits and S.ask("uses_stores", f) then
            local on = S.ask("guards_on", fk) == true
            v.rows[#v.rows + 1] = { S.T("Road guards"), on and S.T("On") or S.T("Off"), "", "", "", icon = S.GUARD_ICON, tip = S.GUARDS_TIP,
                                    guards = on and "off" or "on", send = { label = on and S.T("Dismiss") or S.T("Hire"), tip = S.GUARDS_TIP } }
        end
        local rows = S.trade_rows(realm)
        local others = 0
        for _, g in ipairs(rows) do if not g.own then others = others + 1 end end
        for _, g in ipairs(rows) do
            -- A SECTION ROW before the goods you neither hold nor make, which are all last
            if not g.own and others > 0 then
                local text = S.T("Resources you do not have ({1})", others)
                v.rows[#v.rows + 1] = { S.section(text), "", "", "", "", section = true, fold = true,
                                        folded = S.folded, tip = S.FOLD_TIP[S.folded] }
                others = 0
            end
            if not g.own and S.folded then break end
            local row = { g.name, S.num(g.held), "", "", S.trade_line(last and last(fk, g.stem) or {}),
                          icon = g.icon, tip = S.good_tip(g), stem = g.stem, name = g.name, open = g.stem }
            if not g.own then
                for j = 1, 5 do row[j] = row[j] ~= "" and S.grey(row[j]) or "" end
                row.dim = true
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
        v.title = S.T("Stores of {1}", s.name)
        v.heads = { S.T("Resource"), S.T("Held / Space"), S.T("Per turn"), S.T("Price"), "" }
        local model_faction = S.local_faction()
        local region = model_faction and S.ask("owned", model_faction, s.key)
        local f = S.actions_on() and model_faction
        local fs = f and S.ask("found_state", f, s.key)
        if fs then v.rows[#v.rows + 1] = S.found_row(fs, s.key) end
        -- A RECIPE'S INPUTS GET A ROW (Bilbo Bagins, 2026-11-12): Vitevo's biscuits needed salt it
        -- had none of, and a good with no row has no Send here and no regular supply.
        local inputs = f and region and S.economy_rows(v, f, region)
        for _, d in ipairs(S.settlement_detail(s, inputs)) do
            local tip = S.good_tip(d)
            if d.full then tip = S.FULL_TIP end
            local price, sentence = S.price_of(model_faction, region, d.stem)
            tip = add_line(tip, sentence)
            if region then tip = add_line(tip, S.spoil_sentence(S.ask("spoil_info", model_faction, region, d.stem), d.name)) end
            if region then tip = add_line(tip, S.forecast_tip(model_faction, region, s, S.use_of(d.stem), d.stem)) end
            local row = { d.name, held_space(d), per_turn(d.made), price, "", icon = d.icon,
                          tip = tip, stem = d.stem,
                          open = f and ("routes:" .. s.key .. ":" .. d.stem) or nil }
            if f then
                row.tip = S.T("{1}\nClick to set up a regular supply.", row.tip)
                local plan = S.ask("send_plan", f, s.key, d.stem)
                row.send = { tip = S.send_tip(plan, d, S.ask("ships_to", f:name(), s.key, d.stem)),
                             off = plan == nil or plan.busy == true }
            end
            v.rows[#v.rows + 1] = row
        end
    else
        v.title = S.T("Every settlement you hold")
        v.heads = { S.T("Settlement"), S.T("Level"), S.T("Using"), S.T("Resources"), S.T("Fullest store") }
        v.hint = S.T("Click a settlement to see its stores.")
        local f = S.local_faction()
        for _, r in ipairs(S.settlement_rows(realm)) do
            local fullest = "-"
            if r.fullest then fullest = S.name(r.fullest) .. " " .. r.pct .. "%" end
            local icons, names = {}, {}
            for _, b in ipairs(r.using) do
                icons[#icons + 1] = b.icon
                names[#names + 1] = loc("effect_bundles_localised_title_" .. b.key, b.key)
            end
            local tip = ""
            if #names > 0 then tip = S.T("Using: {1}", table.concat(names, ", ")) end
            -- The settlement's own meals; armies and supplies show in its stores' tooltips.
            local meals = f and S.ask("settlement_meals", f, r.level) or 0
            if meals > 0 then
                tip = add_line(tip, S.T("It eats {1}{2} a turn, {3} for each settlement level.", S.num(meals),
                    (meals == 1 and S.T(" provision") or S.T(" provisions")), S.num(S.ask("need", f:name()) or 0)))
            end
            if S.ask("charted", r.key) == false then tip = add_line(tip, S.UNCHARTED) end
            v.rows[#v.rows + 1] = { r.name, tostring(r.level), #icons > 0 and "" or "-", tostring(r.goods),
                                    fullest, open = r.key, icons = r.icons, using = icons, tip = tip }
        end
        v.empty = S.NO_REALM
    end
    v.cols = L.VIEWS[S.view_key()]
    return v
end

-- THE SPENDING TAB (asked for 2026-10-03): every province capital you hold with its four supply
-- boxes, then the shipments on the road with a Show button each, then the orders on the bottom line.
function S.place(key) return loc("regions_onscreen_" .. key, key) end

function S.icon_of(stem)
    for _, g in ipairs(DERPY_MR_STORES_GOODS) do
        if g.stem == stem then return g.icon end
    end
end

S.BUNDLE_ICONS = "ui/campaign ui/effect_bundles/"
S.SERVICE_UNITS = {
    wh_main_effect_public_order_events = S.T(" control"),
    wh_main_effect_province_growth_events = S.T(" growth"),
    wh_main_effect_building_construction_cost_mod_all = S.T("% cost"),
    wh_main_effect_force_all_campaign_replenishment_rate = S.T("% healing"),
}
-- WHY A RECIPE CANNOT RUN, by flows.lua F.economy_open's reason: a word for the State column, and
-- the sentence a recipe no settlement can run says it with
S.ECON_CLOSED = { ["Needs an undamaged workshop"] = S.T("No workshop"), ["Province capital only"] = S.T("Capital only"),
                  ["Disabled for this campaign"] = S.T("Switched off") }
S.ECON_WHY = { ["Needs an undamaged workshop"] = S.T("None of your settlements has an undamaged building that runs this."),
               ["Province capital only"] = S.T("It runs only in a province capital and you hold none."),
               ["Disabled for this campaign"] = S.T("Switched off in the mod settings for this campaign.") }

-- A RECIPE'S STATE in a word: the economy's own admission check (flows.lua F.economy_state)
function S.economy_status(st)
    if st.on and st.paid then return S.T("Paid") end
    if not st.open then return S.ECON_CLOSED[st.reason] or (st.on and S.T("Paused") or S.T("Off")) end
    if not st.on then return S.T("Off") end
    if st.ready then return S.T("Next turn") end
    return st.short == "Output store full" and S.T("Store full") or S.T("Short")
end

-- One recipe as the settlement's stores and the Production tab both show it.
function S.economy_cells(st)
    local d, parts, stems, amounts = st.definition, {}, {}, {}
    for stem in pairs(d.cost) do stems[#stems + 1] = stem end
    table.sort(stems)
    for _, stem in ipairs(stems) do
        parts[#parts + 1] = S.num(d.cost[stem]) .. " " .. S.name(stem)
        amounts[#amounts + 1] = S.num(d.cost[stem])
    end
    -- WHAT A BATCH MAKES NOW: the War economy edict makes half as much again of a war material (F.output_n)
    local made = d.output and (st.made or d.output[2])
    local result = d.output and (S.num(made) .. " " .. S.name(d.output[1])) or d.benefit
    local raw = st.reason or st.short or ""
    local reason = S.T(raw)
    for _, stem in ipairs(stems) do
        if raw == "Short of " .. stem then reason = S.T("Short of {1}", S.name(stem)) end
    end
    local unit = S.SERVICE_UNITS[d.effect]
    return {
        stems = stems, reason = reason, shortage = string.sub(raw, 1, 9) == "Short of ",
        amount = table.concat(amounts, " + ") .. (d.output and S.T(" / batch") or S.T(" / turn")),
        head = d.label .. "\n" .. (d.output and (S.T("Turns {1} into {2}.", S.join(parts), result))
            or (S.T("Uses {1} a turn for {2}{3}.", S.join(parts), string.lower(string.sub(result, 1, 1)), string.sub(result, 2)))),
        note = d.output and S.T("\nYour buildings still make their usual goods.\nThis only runs when it has everything it needs.")
            or S.T("\nIt is paid from this settlement after upkeep.\nIt gives nothing in a turn it cannot be paid."),
        benefit = d.output and (S.T("{1} made", S.num(made))) or
            (unit and ((d.value > 0 and "+" or "") .. S.num(d.value) .. unit) or d.benefit),
        -- realm-wide the good has to be named: the Production tab's Gives, after the good's icon or
        -- the one the service's own bonus carries (gen_resource_overhaul.SERVICES)
        gives = d.output and result or (unit and ((d.value > 0 and "+" or "") .. S.num(d.value) .. unit) or d.benefit),
        gives_icon = d.output and S.icon_of(d.output[1]) or (d.icon and S.BUNDLE_ICONS .. d.icon) or nil,
    }
end

-- Returns the inputs of every recipe this settlement can run or is running, stem -> true.
function S.economy_rows(v, faction, region)
    local rows = S.ask("economy_rows", faction, region) or {}
    local inputs = {}
    if #rows == 0 then return inputs end
    v.rows[#v.rows + 1] = { S.section(S.T("Processing and services")), S.section(S.T("Inputs")), S.section(S.T("State")), S.section(S.T("Benefit")), "", section = true }
    for _, st in ipairs(rows) do
        if st.open or st.on then
            for stem in pairs(st.definition.cost or {}) do inputs[stem] = true end
        end
        local c = S.economy_cells(st)
        local tip = c.head .. "\n" .. c.reason .. c.note
        v.rows[#v.rows + 1] = { st.definition.label, c.amount, S.economy_status(st), c.benefit, "", economy = st.key,
            region = region:name(), tip = tip,
            send = { label = st.on and S.T("Pause") or S.T("Enable"), off = not st.open and not st.on, tip = tip } }
    end
    v.rows[#v.rows + 1] = { S.section(S.T("Stored resources")), "", "", "", "", section = true }
    return inputs
end

-- THE PRODUCTION TAB (asked 2026-10-30): every recipe your race has, a section each, and under it
-- the settlements that can run it. State and Enable/Pause are the settlement view's own; an input
-- is red where that settlement cannot spend a batch's worth of it, by the view the economy's
-- admission check reads (flows.lua F.economy_view and F.available_stock).
S.PROD_FOLD = "prod_"
S.NO_RECIPES = S.T("Your race has no processing or services.")

-- the buildings that run a recipe for a race, by CA's name: the first level of each chain it names.
-- ponytail: the race is read off the level's key ("_chd_"); a chain keyed without it goes unnamed.
-- No plain-flag string.find: in game it corrupts the string library (check_lua_api.py). A race code
-- is letters only, so it is its own pattern.
function S.economy_buildings(d, race)
    local names = {}
    if not (race and d.levels and string.match(race, "^%a+$")) then return names end
    for lk in pairs(d.levels) do
        if string.match(lk, "_" .. race .. "_") and string.match(lk, "_1$") then
            local n = loc("building_culture_variants_name_" .. lk, nil)
            if n then names[#names + 1] = n end
        end
    end
    table.sort(names)
    return names
end

function S.production_row(f, r, actions)
    local st, d = r.st, r.st.definition
    local c = S.economy_cells(st)
    local view = S.ask("economy_view", f, r.region, d)
    local row = { r.s.name, c.gives, "", S.economy_status(st), "", economy = st.key, region = r.s.key, price = {},
                  lead = { [2] = c.gives_icon } }
    local lines = {}
    for k, stem in ipairs(c.stems) do
        local need = d.cost[stem]
        local have = view and S.ask("available_stock", view, stem)
        local short = (type(have) == "number" and have < need) or st.short == "Short of " .. stem
        row.price[k] = { icon = S.icon_of(stem), short = short,
                         text = short and ("[[col:red]]" .. S.num(need) .. "[[/col]]") or S.num(need) }
        if type(have) == "number" then
            lines[#lines + 1] = S.T("It needs {1} {2}{3} and {4} has {5} to spare.", S.num(need), S.name(stem), (d.output and "" or S.T(" a turn")), r.s.name, S.num(have))
        end
    end
    -- the reason first, unless it is a shortage the lines already show
    local body = table.concat(lines, "\n")
    if c.reason ~= "" and (body == "" or not c.shortage) then
        body = c.reason .. (body ~= "" and "\n" .. body or "")
    end
    row.tip = c.head .. "\n" .. body .. c.note
    row.send = { label = st.on and S.T("Pause") or S.T("Enable"), off = not actions or (not st.open and not st.on),
                 tip = actions and row.tip or S.WORK_OFF }
    return row
end

-- a recipe none of your settlements can run: one grey row saying why, and what would run it
function S.production_none(f, st)
    local d, c = st.definition, S.economy_cells(st)
    local row = { S.grey(S.T("None of your settlements")), S.grey(c.gives), "", S.grey(S.economy_status(st)), "",
                  dim = true, price = {}, lead = { [2] = c.gives_icon } }
    for k, stem in ipairs(c.stems) do
        row.price[k] = { icon = S.icon_of(stem), short = true, text = S.grey(S.num(d.cost[stem])) }
    end
    local why = S.ECON_WHY[st.reason] or c.reason
    if d.kind == "processing" then
        local names = S.economy_buildings(d, S.ask("race", f))
        if #names > 0 then why = S.T("{1}\nBuildings that run it: {2}.", why, table.concat(names, ", ")) end
    end
    row.tip = c.head .. "\n" .. why .. c.note
    return row
end

function S.production(v, realm)
    v.title = S.T("What your settlements can make")
    v.hint = S.T("Workshops make new resources and services spend them for a bonus.")
    v.heads = { S.T("Settlement"), S.T("Gives"), S.T("Inputs"), S.T("State"), "" }
    v.empty = #realm == 0 and S.NO_REALM or S.NO_RECIPES
    local f = S.local_faction()
    if not f then return end
    local actions = S.actions_on()
    local by, order = {}, {}
    for _, s in ipairs(realm) do
        local region = S.ask("owned", f, s.key)
        for _, st in ipairs(region and S.ask("economy_rows", f, region) or {}) do
            local e = by[st.key]
            if not e then
                e = { st = st, rows = {} }
                by[st.key], order[#order + 1] = e, st.key
            end
            if st.open or st.on then e.rows[#e.rows + 1] = { s = s, region = region, st = st } end
        end
    end
    -- processing first, then services, each by name
    table.sort(order, function(a, b)
        local da, db = by[a].st.definition, by[b].st.definition
        if da.kind ~= db.kind then return da.kind == "processing" end
        return da.label < db.label
    end)
    for _, key in ipairs(order) do
        local e = by[key]
        local fold = S.PROD_FOLD .. key
        local folded = S.work_fold[fold] == true
        v.rows[#v.rows + 1] = { S.section(e.st.definition.label), "", "", "", "", section = true, fold = fold,
                                folded = folded, tip = folded and S.T("Click to show these.") or S.T("Click to hide these.") }
        if not folded then
            if #e.rows == 0 then v.rows[#v.rows + 1] = S.production_none(f, e.st) end
            for _, r in ipairs(e.rows) do v.rows[#v.rows + 1] = S.production_row(f, r, actions) end
        end
    end
end

-- A SHIPMENT'S ESCORT (escort battles, spec 2026-10-09): a shipment row opens it, one CA unit card a
-- unit, as CA's army strip draws an army. The cards are 60x130 and cannot fit a 28px row.
S.CARD = "derpy_mr_card_"
S.ESCORT_FOCUS = "ship:"
S.NO_ESCORT = S.T("An army at war with you can take this unguarded shipment without a fight.")
S.ESCORT_LINE = S.T("An army has to beat these soldiers to take the shipment.")

function S.unit_name(unit)
    local c = DERPY_MR_STORES_CARDS[unit]
    return c and loc("land_units_onscreen_name_" .. c.lu, unit) or unit
end

-- the escort's units in the order they were rolled, from the shipment's saved list
function S.escort_units(s)
    local out = {}
    for u in string.gmatch(s.escort or "", "[^,]+") do out[#out + 1] = u end
    return out
end

function S.escort_view(v)
    local id, ship = string.sub(S.focus, #S.ESCORT_FOCUS + 1), nil
    for _, s in ipairs(S.ask("ships") or {}) do
        if s.id == id then ship = s end
    end
    if not ship then                                  -- arrived or taken since: back to the list
        S.focus = nil
        return S.spending(v)
    end
    v.title = S.T("Escort of {1} {2}, {3} to {4}", S.num(ship.n), S.name(ship.stem), S.place(ship.from), S.place(ship.to))
    v.heads = { "", "", "", "", "" }
    v.cards = {}
    for _, u in ipairs(S.escort_units(ship)) do
        local c = DERPY_MR_STORES_CARDS[u]
        if c then v.cards[#v.cards + 1] = { card = c.card, tip = S.unit_name(u) } end
    end
    v.empty = #v.cards > 0 and S.ESCORT_LINE or S.NO_ESCORT
end

-- CA's greyscale (the Exchange's EX.set_off shader): greyed and faded, or back in colour
S.PAYIC = "derpy_mr_supic_"   -- a Spending row's icon of the good a supply pays with

-- ONE SENTENCE A LINE (author, 2026-11-01): the rules were one paragraph of fragments on every row.
-- Each row now says only its own rule.
S.ARMY_TIP = S.T("An army eats 1 provision a turn for every 4 units and refills in your own settlements.")
S.ARMY_AUTO = S.T("On Auto the army refills to 5 turns of provisions after eating.\nIt carries at most 10 turns and never buys rations.")
S.ARMY_BUY = S.T("Buy up to two meals of rations once a turn at 10 gold each.")
S.ARMY_HUNGER = S.T("After two missed meals the army moves 5% slower.\nAfter three it moves and recovers 10% slower.\nOne full meal ends this.")

-- Shared wording for the army-bar tooltip and Vault row; omit armies with no line.
S.SUPPLY_STATE = { home = S.T("At home"), supplied = S.T("Supplied"), stretched = S.T("Stretched"), cut = S.T("Cut off") }

function S.supply_text(note)
    local state, source, pct = note.state, note.source and S.place(note.source) or "", S.num(note.upkeep or 0)
    if state == "home" then return S.T("In your own lands.") end
    if state == "supplied" then
        if note.turns == 1 then return S.T("Supplied from {1}, 1 turn away. Upkeep +{2}%.", source, pct) end
        return S.T("Supplied from {1}, {2} turns away. Upkeep +{3}%.", source, note.turns, pct)
    end
    if state == "stretched" then return S.T("Stretched: {1} turns from {2}. Upkeep +{3}%.", note.turns, source, pct) end
    if state == "cut" then
        local text = S.T("Cut off. Upkeep +{1}%.\nForaging and buying from the locals costs the most.", pct)
        if note.by then text = text .. "\n" .. S.T("An enemy army blocks the road.") end
        return text
    end
    return nil
end

function S.army_name(row)
    if row.force then
        return S.char_name(row.force:general_character():command_queue_index()) or (S.T("Army {1}", row.id))
    end
    return S.T("Army {1}", row.id)
end

function S.army_view(v)
    local f = S.local_faction()
    local id = string.sub(S.focus, 6)
    local row
    for _, r in ipairs(f and S.ask("provision_rows", f) or {}) do if r.id == id then row = r end end
    if not row then S.focus = nil; return S.spending(v) end
    v.title = S.T("{1}: provisions", S.army_name(row))
    v.heads = { S.T("Action"), S.T("Held"), S.T("Per turn"), S.T("Lasts"), "" }
    v.hint = S.T("Unload before you merge this army or its provisions are lost.")
    local here = row.source and S.place(row.source:name())
    local auto = S.ARMY_AUTO .. "\n" .. row.reason
    local load = (row.mobile and S.ARMY_BUY or (here and (S.T("Fill the army to 10 turns of provisions from {1}.\nIts reserve is not touched.", here))
        or S.T("This army cannot load here."))) .. "\n" .. row.reason
    local unload = here and (S.T("Put the provisions back into {1} and pause Auto.", here))
        or S.T("This army can only unload in one of your settlements.")
    local source = row.source and S.T("Local stores") or (row.mobile and S.T("Rations") or S.T("Unavailable"))
    v.rows[#v.rows + 1] = { S.T("Auto-refill"), S.num(row.held) .. " / " .. S.num(row.cap),
        S.num(row.need), turns(math.floor(row.held / row.need)), provisions = "auto", army = id, tip = auto,
        icon = S.icon_of("grain"),
        send = { label = row.auto and S.T("Pause") or S.T("Enable"), off = not S.actions_on(), tip = auto } }
    v.rows[#v.rows + 1] = { row.mobile and S.T("Buy rations") or S.T("Load here"), source, row.mobile and (S.T("{1} gold", S.num(row.price))) or "", "", provisions = "load", army = id, tip = load,
        send = { label = row.mobile and S.T("Buy") or S.T("Load"), off = (not row.source and (row.buy or 0) == 0) or not S.actions_on(), tip = load } }
    local note = S.ask("supply_note", f, id)
    local cart, state = S.ask("supply_cart_of", id), note and note.state
    local why
    if cart then why = S.T("A cart is already on its way.\nIt arrives on turn {1}.", tostring(cart.due))
    elseif state == "cut" then why = S.T("Cut off. Supplies cannot reach this army.")
    elseif state == "home" then why = S.T("This army is in your own lands.\nLoad it here instead.")
    elseif state ~= "supplied" and state ~= "stretched" then why = S.T("This army has no supply road.")
    elseif row.held >= row.need * 5 then why = S.T("This army already carries 5 turns of provisions.")
    elseif (S.ask("provision_spare", f, note.source) or 0) <= 0 then
        -- and why: a store below its own reserve looks full to a player who sees it making grain (Gidwelion, 2026-11-11)
        why = S.T("{1} has no food to spare.\nA settlement keeps {2} turns of the food it eats and uses before it feeds an army.",
            S.place(note.source), (DERPY_MR_FLOWS and DERPY_MR_FLOWS.FED_TURNS) or 5)
    end
    local supply = why or S.T("Send a cart of provisions from {1}.\nIt arrives in {2}.\nAn army at war with you can seize it.",
        S.place(note.source), turns(note.turns))
    v.rows[#v.rows + 1] = { S.T("Supply cart"), note and note.source and S.place(note.source) or "-", "", "", provisions = "send",
        army = id, tip = supply, send = { label = S.T("Send supplies"), off = why ~= nil or not S.actions_on(), tip = supply } }
    v.rows[#v.rows + 1] = { S.T("Unload here"), S.T("Pauses refill"), "", "", provisions = "unload", army = id, tip = unload,
        send = { label = S.T("Unload"), off = not row.source or row.held == 0 or not S.actions_on(), tip = unload } }
    v.rows[#v.rows + 1] = { S.T("Missed meals"), S.num(row.short), "", "", "", tip = S.ARMY_HUNGER }
    if note and S.SUPPLY_STATE[note.state] then
        v.rows[#v.rows + 1] = { S.section(S.T("Supply road")), S.section(S.T("From")), S.section(S.T("Distance")),
                                S.section(S.T("Upkeep")), "", section = true }
        v.rows[#v.rows + 1] = { S.SUPPLY_STATE[note.state], note.source and S.place(note.source) or "-",
                                (note.turns or 0) > 0 and turns(note.turns) or "-", S.T("+{1}%", S.num(note.upkeep or 0)), "",
                                tip = S.supply_text(note) }
    end
end

function S.spending(v)
    v.title = S.T("What your stores pay for")
    v.heads = { S.T("Province capital"), S.T("Materials"), S.T("Stables"), S.T("Arms"), S.T("Supply capital") }
    v.hint = S.T("Tick a supply to pay for it each turn.")
    local f = S.local_faction()
    if not f then return end
    local routes = S.ask("routes", f) or {}
    if #routes > 0 then
        v.rows[#v.rows + 1] = { S.section(S.T("Regular supplies")), "", "", "", "", section=true }
        for _, o in ipairs(routes) do
            v.rows[#v.rows + 1] = { S.name(o.stem), S.place(o.from), S.place(o.to), o.enabled and S.T("Sending") or S.T("Paused"), "",
                open="route:" .. o.id, tip=S.T("Sends carts of {1} until you hold {2}.\n{3}.\nClick to change it.", o.batch, o.target, (S.T(o.status) or S.T("No cart sent yet"))) }
        end
    end
    if S.supply_on() then
        local caps = {}
        for _, k in ipairs(S.ask("capitals", f) or {}) do
            local st = S.ask("supply_state", f, k)
            if st then caps[#caps + 1] = { key = k, name = S.place(k), st = st } end
        end
        table.sort(caps, function(a, b) return a.name < b.name end)
        for _, c in ipairs(caps) do
            local row = { c.name, "", "", "", "", capital = c.key, supply = {},
                          tip = S.T("Each supply costs {1} a turn from the stores of {2}.\nThat is 2 for each settlement you hold in its province.", S.num(c.st.cost), c.name) }
            local region = S.ask("owned", f, c.key)
            local settlement = region and S.read_settlement(region)
            for _, sp in ipairs(DERPY_MR_STORES_SUPPLY) do
                local forecast = region and sp.use ~= "" and S.forecast_tip(f, region, settlement, sp.use) or ""
                row.supply[sp.key] = { on = c.st.on[sp.key] == true, tip = add_line(S.supply_tip(sp, c.st, c.name), forecast) }
                local pay = sp.use ~= "" and c.st.pay and c.st.pay[sp.use]
                if pay then
                    row.supply[sp.key].pay = {
                        -- short on the use's total, as F.supply decides: it pays across every good
                        icon = S.icon_of(pay.stem), short = (c.st.have[sp.use] or 0) < c.st.cost,
                        tip = sp.label .. "\n" .. (pay.n > 0 and (S.T("It pays with {1} first because that store is the fullest.", S.name(pay.stem)))
                            or (S.T("The stores of {1} have nothing to pay with.", c.name))) }
                end
            end
            v.rows[#v.rows + 1] = row
        end
    end
    local ships = S.ask("ships")
    if ships then
        local mine = {}
        for _, s in ipairs(ships) do
            if s.f == f:name() then mine[#mine + 1] = s end
        end
        -- the road's own headings, on its section row: the panel's are the supplies'
        v.rows[#v.rows + 1] = { S.section(S.T("On the road ({1} of {2})", #mine, S.num(S.ask("ship_cap", f) or 0))),
                                S.section(S.T("From")), S.section(S.T("To")), S.section(S.T("Arrives")), "", section = true }
        if #mine == 0 then v.rows[#v.rows + 1] = { S.NO_SHIPS, "", "", "", "" } end
        for _, s in ipairs(mine) do
            local from, to = S.place(s.from), S.place(s.to)
            local icon
            for _, g in ipairs(DERPY_MR_STORES_GOODS) do
                if g.stem == s.stem then icon = g.icon end
            end
            local due = S.ask("ship_due", s) or s.due
            v.rows[#v.rows + 1] = { S.num(s.n) .. " " .. S.name(s.stem), from, to, S.T("turn {1}", due), "", icon = icon,
                                    open = S.ESCORT_FOCUS .. s.id, tip = S.T("Click to see its escort."),
                                    send = { label = S.T("Show"), look = { s.x, s.y },
                                             tip = S.T("{1} and reaches {2} on turn {3}.\nClick to see it on the map.", (s.road and S.T("It is travelling from {1}", from)
                                                 or S.T("It is now beside {1}", (s.leg == 2 and to or from))), to, due) } }
        end
    end
    local armies = S.ask("provision_rows", f) or {}
    if #armies > 0 or (S.ask("rates") or {}).army_provisions then
    v.rows[#v.rows + 1] = { S.section(S.T("Army provisions")), S.section(S.T("Held")), S.section(S.T("Per turn")), S.section(S.T("Lasts")), "", section = true }
    if #armies == 0 then
        v.rows[#v.rows + 1] = { S.T("No armies carry provisions"), "", "", "", "", tip = S.ARMY_TIP }
    end
    for _, a in ipairs(armies) do
        v.rows[#v.rows + 1] = { S.army_name(a), S.num(a.held) .. " / " .. S.num(a.cap), S.num(a.need),
            turns(math.floor(a.held / a.need)), "", open = "army:" .. a.id,
            icon = S.icon_of("grain"),
            tip = S.T("This army eats {1}{2} a turn.\n{3}{4}\nClick to manage its provisions.", a.need, (a.need == 1 and S.T(" provision") or S.T(" provisions")), a.reason, (a.short > 0 and (S.T("\nMissed meals: {1}.", a.short)) or "")) }
    end
    end
    -- RECRUITS (workshop expansion spec section 3): what last turn's recruits took (flows.lua F.on_unit_trained)
    local rl = S.flows("recruit_last")
    local r = rl and rl(f:name())
    if r and (r.goods > 0 or r.gold > 0 or next(r.paid)) then
        local parts, lines, words = { S.T("{1} resources", S.num(r.goods)) }, {}, {}
        for w in pairs(r.paid) do words[#words + 1] = w end
        table.sort(words)
        for _, w in ipairs(words) do
            parts[#parts + 1] = S.num(r.paid[w]) .. " " .. w
            if r.line then lines[#lines + 1] = string.format(r.line, r.paid[w], w) end
        end
        if r.gold > 0 then parts[#parts + 1] = S.T("{1} gold", S.num(r.gold)) end
        v.rows[#v.rows + 1] = { S.section(S.RECRUIT_HEAD), "", "", "", "", section = true }
        v.rows[#v.rows + 1] = { table.concat(parts, ", "), "", "", "", "", icon = S.DUTY_ICON,
            tip = S.T("Each recruit takes resources from your stores by its type and cost.\nAnything missing is paid {1}in gold.{2}", (r.line and S.T("in your own currency and then ") or ""), (#lines > 0 and ("\n" .. table.concat(lines, "\n")) or "")) }
    end
    if #v.rows == 0 or v.rows[1].section then v.heads = { "", "", "", "", "" } end
    if S.actions_on() then
        v.orders = {}
        for i, o in ipairs(DERPY_MR_STORES_ORDERS) do
            local st = S.ask("order_state", f, o.key)
            if st then v.orders[i] = { key = o.key, tip = S.order_tip(o, st), off = not st.ok, active = st.active } end
        end
    end
end

-- ---- THE WORKSHOP (spec 2026-10-07): a rare good and a bulk of its use buy something lasting --
S.WORK_SECTION = { item = S.T("Items"), unit = S.T("Units"), upgrade = S.T("Settlement upgrades"), convert = S.T("Race resources"),
                   army = S.T("Army works"), trait = S.T("Lord and hero works"), lasting = S.T("Permanent works"), research = S.T("Research") }
S.WORK_ORDER = { "item", "unit", "upgrade", "convert", "army", "trait", "lasting", "research" }
S.WORK_DONE = { item = S.T("Forged"), upgrade = S.T("Built"), lasting = S.T("Built"), trait = S.T("Has it") }
-- A FOLDED KIND shows its section row only (the spec's filter by kind). Kept while the campaign
-- runs, not saved.
S.work_fold = {}
-- by the work's target: an army, any character, or a lord only (a general_to_force_own trait)
S.AIM = { army = S.T("Select one of your armies on the map first."),
          character = S.T("Select one of your lords or heroes on the map first."),
          lord = S.T("Select one of your lords on the map first.") }

-- The character selected on the campaign map, by cqi, or nil (CA's UI manager keeps it: -1 or
-- nil when none). Local to this machine: a purchase carries it through F.request.
function S.selected()
    local ok, cqi = pcall(function() return cm:get_campaign_ui_manager():get_char_selected_cqi() end)
    if ok and type(cqi) == "number" and cqi > 0 then return cqi end
    return nil
end

-- "Karl Franz", or nil when the engine will not say
function S.char_name(cqi)
    local ok, n = pcall(function()
        local c = cm:get_character_by_cqi(cqi)
        local name = common.get_localised_string(c:get_forename())
        local sur = common.get_localised_string(c:get_surname())
        if sur ~= "" then name = name .. " " .. sur end
        return name
    end)
    if ok and type(n) == "string" and n ~= "" then return n end
    return nil
end
S.WORK_OFF = S.T("Resource Vault actions are switched off in the mod settings.")

-- a price part's figure, red where the stores are short of it
function S.price_part(have, cost)
    local n = S.num(cost)
    if have < cost then return "[[col:red]]" .. n .. "[[/col]]" end
    return n
end

-- "It needs 120 Grain, and you have 165."
function S.need_line(cost, what, have)
    return S.T("It needs {1} {2} and you have {3}.", S.num(cost), what, S.num(have))
end

-- why a row cannot be bought, in one line
function S.work_why(w, st)
    if st.why == "short" and st.goods then
        for _, g in ipairs(st.goods) do
            if g.have < g.cost then return S.need_line(g.cost, S.name(g.stem), g.have) end
        end
    end
    if st.why == "aim" then return S.AIM[w.target] or "" end
    if st.why == "not_lord" then return S.T("Only a lord can take this.") end
    if st.why == "no_pool" then return S.T("Your faction cannot hold this.") end
    if st.why == "full" and w.kind == "convert" then return S.T("You hold as much of it as you can.") end
    if st.why == "done" and w.kind == "trait" then return S.T("They have this already.") end
    if st.why == "done" and w.kind == "lasting" then return S.T("Built already.") end
    if st.why == "no_army" and w.kind == "army" then return S.T("The selected character leads no army.") end
    if st.why == "not_yours" and w.target ~= "" then return S.T("Not one of your characters.") end
    if st.why == "short" then
        if st.rare and st.rare.have < st.rare.cost then
            return S.need_line(st.rare.cost, S.name(w.rare), st.rare.have)
        end
        return S.need_line(st.bulk.cost, S.T("common {1}", (S.USE_WORD[w.use] or w.use)), st.bulk.have)
    end
    if st.why == "wait" then return S.T("Ready again in {1}.", turns(st.wait)) end
    if st.why == "done" then return S.T("Already forged.") end
    if st.why == "built" then return S.T("Built here already.") end
    if st.why == "full" then return S.T("Your mercenary pool holds as many as it can.") end
    if st.why == "not_yours" then return S.T("Not your settlement.") end
    if st.why == "no_army" then return S.T("No army of yours has room for it.") end
    return ""
end

-- the panel a pool's units are recruited from, by the pool's own key
function S.pool_name(pool)
    if string.match(pool or "", "grudges") then return S.T("Book of Grudges") end
    return S.T("Regiments of Renown")
end

function S.work_tip(w, st)
    local out = w.name .. "\n" .. w.detail .. ".\n"
    if st.route == "pool" then
        out = S.T("{1}It goes into your {2}.\nRecruiting it there still costs its gold.\n", out, S.pool_name(w.pool))
    elseif st.route == "army" then
        out = S.T("{1}It goes straight into your largest army with room.\n", out)
    end
    if st.goods then
        for _, g in ipairs(st.goods) do out = out .. S.need_line(g.cost, S.name(g.stem), g.have) .. "\n" end
        return out
    end
    if st.rare then out = out .. S.need_line(st.rare.cost, S.name(w.rare), st.rare.have) .. "\n" end
    out = out .. S.need_line(st.bulk.cost, S.T("common {1}", (S.USE_WORD[w.use] or w.use)), st.bulk.have) .. "\n"
    return out .. S.use_goods(w.use)
end

-- the Buy button: live when it can be bought and the actions are on, else greyed saying why
function S.work_send(w, st, label)
    local on = S.actions_on()
    return { label = S.WORK_DONE[w.kind] and (st.why == "done" or st.why == "built") and S.WORK_DONE[w.kind] or label,
             off = not (st.ok and on),
             tip = not on and S.WORK_OFF or (st.ok and S.T("Click to buy it.") or S.work_why(w, st)) }
end

function S.workshop(v, realm)
    local f = S.local_faction()
    if not f then return end
    if S.focus then                                   -- an upgrade's drill-down: where to build it
        local w
        for _, x in ipairs(DERPY_MR_STORES_WORKS) do if x.key == S.focus then w = x end end
        if not w then
            S.focus = nil
            return S.workshop(v, realm)
        end
        v.title = S.T("Where to build {1}", w.name)
        v.heads = { S.T("Settlement"), "", "", "", "" }
        local any
        for _, s in ipairs(realm) do
            local st = S.ask("work_state", f, w.key, s.key)
            if st then
                v.rows[#v.rows + 1] = { s.name, "", "", "", "", work = w.key, region = s.key,
                                        tip = S.work_tip(w, st), send = S.work_send(w, st, S.T("Buy here")) }
                any = any or st
            end
        end
        -- THE PRICE, on the hint's line: it is the same wherever it is built
        if any then
            v.hint = S.T("It is paid from all your stores: {1} {2} and {3} {4}.", S.num(any.rare.cost), S.name(w.rare), S.num(any.bulk.cost), (S.USE_WORD[w.use] or w.use))
        end
        return
    end
    v.title = S.T("What your stores can buy")
    v.hint = S.T("Rare resources are made only in their own buildings.")
    v.heads = { "", S.T("Gives"), S.T("Price"), "", "" }   -- one header over both price parts
    local aim = S.selected()
    for _, kind in ipairs(S.WORK_ORDER) do
        local rows = {}
        for _, w in ipairs(DERPY_MR_STORES_WORKS) do
            local target = w.target ~= "" and aim or nil
            local st = w.kind == kind and S.ask("work_state", f, w.key, nil, target)
            if st and st.goods then
                -- A NAMED RECIPE: up to four goods, each its icon and amount, from column 3
                local r = { w.name, w.gives, "", "", "", icon = w.icon, tip = S.work_tip(w, st), work = w.key,
                            price = {}, send = S.work_send(w, st, S.T("Buy")) }
                for k, g in ipairs(st.goods) do
                    r.price[k] = { icon = S.icon_of(g.stem), text = S.price_part(g.have, g.cost), short = g.have < g.cost }
                end
                if w.target ~= "" then
                    r.aim = target
                    r.tip = r.tip .. (target and (S.T("Applies to: {1}.", (S.char_name(target) or S.T("the selected character"))))
                                      or S.AIM[w.target])
                end
                rows[#rows + 1] = r
            elseif st then
                -- THE PRICE, two parts, each after its icon: the rare good in 3, the bulk's use in 4
                local r = { w.name, w.gives, st.rare and S.price_part(st.rare.have, st.rare.cost) or "",
                            S.price_part(st.bulk.have, st.bulk.cost), "", icon = w.icon, tip = S.work_tip(w, st),
                            work = w.key, lead = { [3] = st.rare and S.icon_of(w.rare) or nil,
                                                   [4] = DERPY_MR_STORES_USE_ICON[w.use] } }
                if kind == "upgrade" then
                    -- no Buy of its own: Choose opens the list of settlements it can be built in
                    r.open, r.tip = w.key, S.T("{1}Click to choose a settlement.", r.tip)
                    r.send = { label = S.T("Choose"), off = false, tip = S.T("Choose the settlement to build it in.") }
                else
                    r.send = S.work_send(w, st, S.T("Buy"))
                end
                rows[#rows + 1] = r
            end
        end
        if #rows > 0 then
            local folded = S.work_fold[kind] == true
            v.rows[#v.rows + 1] = { S.section(S.WORK_SECTION[kind]), "", "", "", "",
                                    section = true, fold = kind, folded = folded,
                                    tip = folded and S.T("Click to show these.") or S.T("Click to hide these.") }
            if not folded then
                for _, r in ipairs(rows) do v.rows[#v.rows + 1] = r end
            end
        end
    end
end

-- THE MAP TAB: where each settlement and convoy is, in panel pixels relative to the map's box.
-- One scale for both axes and north up (logical y grows northward: Kislev 789, Middenheim 720,
-- Karak Eight Peaks 359 in CA's own scripts). Pure, so the harness reads it.
-- CA'S MINIMAP for each campaign, by cm:model():campaign_name_key() (the campaigns table's key,
-- which CA's own scripts compare). The folders are campaigns_tables' map_name (IEE's and the Old
-- World's from their own packs); CA's save-game panel draws campaign_maps/wh3_main_combi_map_2's the same way. w and h are
-- the pictures' own sizes. Any other map draws the plain one.
S.MAP_ART = {
    wh3_main_combi = { path = "campaign_maps/wh3_main_combi_map_7/wh3_main_combi_map_minimap.png", w = 1440, h = 1120 },
    cr_combi_expanded = { path = "campaign_maps/cr_combi_expanded_map_1/cr_combi_expanded_map_minimap.png",
                          w = 1600, h = 1120 },
    cr_oldworld = { path = "campaign_maps/cr_oldworld_map_1/cr_oldworld_map_minimap.png", w = 2048, h = 2048 },
    wh3_main_chaos = { path = "campaign_maps/wh3_main_chaos_map_4/wh3_main_chaos_map_minimap.png", w = 1108, h = 834 },
}
S.NO_ART = "ui/skins/default/1x1_transparent_white.png"   -- the plain map's surface: CA's clear pixel
function S.map_art()
    local ok, key = pcall(function() return cm:model():campaign_name_key() end)
    return ok and S.MAP_ART[key] or nil
end

-- WHERE A POINT FALLS ON THE PICTURE. Measured in game 2026-10-03 (IEE): CA's minimap is drawn in
-- DISPLAY space, so a logical frame put Zharr-Naggrund visibly south of its place. The engine's
-- own CampaignRadarPosition answers exactly, on any map: the 0-1 fraction of the picture, from the
-- left and from the top, that CA's map panels place icons with (ContextRadarIcon). A world
-- position is (display x, height, display y), built from numbers with ToVector. It is linear, so
-- two reads give the frame: the world's westmost and eastmost settlements, its southmost and
-- northmost (points on the picture: off it the answer clamps). Read once a session; false when
-- the engine will not answer, and the plain map is drawn instead.
S.frame = nil
function S.radar(dx, dy)
    local ok, x, y = pcall(function()
        local e = "CampaignRadarPosition(ToVector(" .. dx .. ", 0, " .. dy .. ", 0))"
        return common.get_context_value(e .. ".x"), common.get_context_value(e .. ".y")
    end)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
end
function S.map_frame()
    if S.frame == nil then
        S.frame = false
        local ok, f = pcall(function()
            local rl = cm:model():world():region_manager():region_list()
            local w, e, s, n
            for i = 0, rl:num_items() - 1 do
                local st = rl:item_at(i):settlement()
                if st and not st:is_null_interface() then
                    local x, y = st:display_position_x(), st:display_position_y()
                    if not w or x < w[1] then w = { x, y } end
                    if not e or x > e[1] then e = { x, y } end
                    if not s or y < s[2] then s = { x, y } end
                    if not n or y > n[2] then n = { x, y } end
                end
            end
            if not w or e[1] - w[1] < 1 or n[2] - s[2] < 1 then return nil end
            local wx = S.radar(w[1], w[2])
            local ex = S.radar(e[1], e[2])
            local _, sy = S.radar(s[1], s[2])
            local _, ny = S.radar(n[1], n[2])
            if not (wx and ex and sy and ny) or ex == wx or ny == sy then return nil end
            local bx, by = (ex - wx) / (e[1] - w[1]), (ny - sy) / (n[2] - s[2])
            return { bx = bx, ax = wx - bx * w[1], by = by, ay = sy - by * s[2] }
        end)
        if ok and f then S.frame = f end
    end
    return S.frame or nil
end

-- A name's width on the map, near enough to keep two from overlapping
function S.label_w(s) return math.ceil(string.len(s or "") * L.MAP_CHAR_W) end

-- THE MAP TAB'S MODEL. Every point in map units: the picture's own pixels (y down) when there is
-- a picture and a frame, else display units with north up - display, not logical, so the plain
-- map keeps the real map's proportions too. Framed on what is drawn, in the map's box, one scale.
function S.map_model(faction, view)
    local m = { dots = {}, carts = {}, path = {}, art = S.map_art() }
    local fr = m.art and S.map_frame()
    if not fr then m.art = nil end
    local function u(dx, dy)
        if fr then return m.art.w * (fr.ax + fr.bx * dx), m.art.h * (fr.ay + fr.by * dy) end
        return dx, -dy
    end
    local caps, at = {}, {}
    for _, k in ipairs(S.ask("capitals", faction) or {}) do caps[k] = true end
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        local st = not r:is_null_interface() and r:settlement()
        if st and not st:is_null_interface() then
            local k = r:name()
            local d = { lx = st:logical_position_x(), ly = st:logical_position_y(), name = S.place(k), cap = caps[k] == true }
            d.ux, d.uy = u(st:display_position_x(), st:display_position_y())
            m.dots[#m.dots + 1] = d
            at[k] = d
        end
    end
    table.sort(m.dots, function(a, b) return a.name < b.name end)
    local routes=DERPY_MR_TERRAIN_ROUTES
    local function cart(s)
        -- framed: a convoy can start at a partner's capital far from the realm, so it stays on the surface, off the frame
        local c = { lx = s.x, ly = s.y, s = s, framed = not s.convoy }
        c.ux, c.uy = u(cm:log_to_dis(s.x, s.y))
        m.carts[#m.carts + 1] = c
        return c
    end
    for _, s in ipairs((not routes or routes.shown('shipments')) and S.ask("ships") or {}) do
        if s.f == faction:name() then
            -- Contract sources can belong to a partner; draw only their referenced endpoint.
            if not at[s.from] then
                local ok, r = pcall(function() return cm:get_region(s.from) end)
                if ok and r and r.settlement and not r:is_null_interface() then
                    local st = r:settlement()
                    if not st:is_null_interface() then
                        local d = { lx=st:logical_position_x(),ly=st:logical_position_y(),name=S.place(s.from),cap=false }
                        d.ux,d.uy=u(st:display_position_x(),st:display_position_y())
                        at[s.from]=d; m.dots[#m.dots+1]=d
                    end
                end
            end
            cart(s)
        end
    end
    -- the viewer's agreement convoys, out and in, ride the same road under the same switch, after the shipments' carts;
    -- one with no position is on the road but has no place to draw (the Trade tab still counts it); convoys on one
    -- spot (a one-turn convoy waits at its exporter's capital) share the first one's cart, which lists them all
    local stacked = {}
    for _, s in ipairs((not routes or routes.shown('shipments')) and S.convoys_of(faction:name()) or {}) do
        if s.x and s.y then
            local c = cart(s)
            local spot = math.floor(c.ux + 0.5) .. ":" .. math.floor(c.uy + 0.5)
            if stacked[spot] then
                table.insert(stacked[spot].stack, s)
                m.carts[#m.carts] = nil
            else
                c.stack, stacked[spot] = { s }, c
            end
        end
    end
    -- THE ROADS ARE THE 3D MAP'S (terrain_routes.lua): its links, its solved paths, its colours,
    -- every third point as it draws them. No path yet, or none, draws nothing: never a straight line.
    -- An agreement's own trade road first, as the 3D map draws it: the display search can take another
    -- way and, never asked for that pair before, left the first open empty (seen in game 2026-10-22).
    local R, roads, shared = DERPY_MR_TERRAIN_ROUTES, {}, {}
    for _, link in ipairs(R and R.links(faction) or {}) do
        local road = { colour = R.ink(link.owner), own = link.own }
        local path = link.path or R.path(link.from, link.to) or {}
        local visible = R.unshared(path, shared)
        for i, point in ipairs(path) do
            if visible[i] and i % 3 == 1 then road[#road + 1] = { u(R.sample(path,i)) } end
        end
        roads[#roads + 1] = road
    end
    -- the frame: this realm's points and roads, its centre, and one scale that fits the padded box.
    -- all: everything drawn, which the plain map's surface carries so a drag reaches a foreign road.
    local x0, y0, x1, y1
    local all = {}
    local function grow(x, y, framed)
        all[1], all[2] = math.min(all[1] or x, x), math.min(all[2] or y, y)
        all[3], all[4] = math.max(all[3] or x, x), math.max(all[4] or y, y)
        if framed then
            x0, y0 = math.min(x0 or x, x), math.min(y0 or y, y)
            x1, y1 = math.max(x1 or x, x), math.max(y1 or y, y)
        end
    end
    for _, d in ipairs(m.dots) do grow(d.ux, d.uy, true) end
    for _, c in ipairs(m.carts) do grow(c.ux, c.uy, c.framed) end
    for _, r in ipairs(roads) do
        for _, point in ipairs(r) do grow(point[1], point[2], r.own) end
    end
    if not x0 then x0, y0, x1, y1 = all[1], all[2], all[3], all[4] end
    if not x0 then return m end
    local W, H = L.map[3], L.map[4]
    local fit = math.min((W - 2 * L.MAP_PAD) / math.max(x1 - x0, L.MAP_MIN_SPAN),
                         (H - 2 * L.MAP_PAD) / math.max(y1 - y0, L.MAP_MIN_SPAN))
    local a = m.art
    -- ZOOM: view.zoom times the first framing, between the farthest and the closest it allows
    local lo, hi
    if a then
        -- first framed no closer than the picture has detail for; zoomed out to the whole picture
        fit = math.min(fit, L.MAP_ART_ZOOM)
        lo, hi = math.min(fit, math.max(W / a.w, H / a.h)), L.MAP_ZOOM_MAX
    else
        lo, hi = fit, fit * L.MAP_ZOOM_MAX
    end
    local scale = math.max(lo, math.min(hi, fit * (view and view.zoom or 1)))
    m.scale, m.zoom = scale, scale / fit
    m.can_in, m.can_out = scale < hi * 0.999, scale > lo * 1.001
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if view and view.cx then cx, cy = view.cx, view.cy end
    if a then
        -- kept on the picture: no blank past its edge
        local hw, hh = W / 2 / scale, H / 2 / scale
        if a.w >= 2 * hw then cx = math.max(hw, math.min(a.w - hw, cx)) end
        if a.h >= 2 * hh then cy = math.max(hh, math.min(a.h - hh, cy)) end
    end
    local function px(x, y)
        return math.floor(L.map[3] / 2 + (x - cx) * scale + 0.5), math.floor(L.map[4] / 2 + (y - cy) * scale + 0.5)
    end
    for _, d in ipairs(m.dots) do d.x, d.y = px(d.ux, d.uy) end
    -- THE SURFACE everything rides on, in the map's box: the picture, or the box grown to carry
    -- every point drawn, so a drag carries them all. su: its top-left corner in map units.
    if a then
        local ax, ay = px(0, 0)
        m.surface = { ax, ay, math.floor(a.w * scale + 0.5), math.floor(a.h * scale + 0.5) }
        m.su = { 0, 0 }
    else
        local sx0, sy0 = px(all[1], all[2])
        local sx1, sy1 = px(all[3], all[4])
        sx0, sy0 = math.min(0, sx0 - L.MAP_PAD), math.min(0, sy0 - L.MAP_PAD)
        sx1, sy1 = math.max(W, sx1 + L.MAP_PAD), math.max(H, sy1 + L.MAP_PAD)
        m.surface = { sx0, sy0, sx1 - sx0, sy1 - sy0 }
        m.su = { cx + (sx0 - W / 2) / scale, cy + (sy0 - H / 2) / scale }
    end
    for _, c in ipairs(m.carts) do c.x, c.y = px(c.ux, c.uy) end
    -- ponytail: the first MAP_PATH_MAX dots in R.links' order, this realm's roads first; space them
    -- by on-screen distance instead if a crowded late game reaches the cap.
    for _, r in ipairs(roads) do
        for _, point in ipairs(r) do
            if #m.path >= L.MAP_PATH_MAX then break end
            local x, y = px(point[1], point[2])
            m.path[#m.path + 1] = { x = x, y = y, colour = r.colour }
        end
    end
    return m
end

function S.ship_tip(s)
    local what = s.convoy and S.basket_text(s.basket) or (S.num(s.n) .. " " .. S.name(s.stem))
    return S.T("{1} from {2} to {3}.\nIt arrives on turn {4}.\nClick to fly there.", what, S.place(s.from), S.place(s.to), tostring(S.ask("ship_due", s) or s.due))
end

-- SHOW: the camera flies to a shipment's cart, CA's way (wh3_dlc29_middenland_narrative), keeping
-- its distance and height; the panel closes so the map can be seen. A camera move, not the model.
function S.look_at(x, y)
    local dx, dy = cm:log_to_dis(x, y)
    local _cx, _cy, d, _b, h = cm:get_camera_position()
    cm:scroll_camera_from_current(false, 1, { dx, dy, d, 0, h })
    S.show(false)
end

-- ==========================================================================================
-- THE UI. Built at runtime from ui/campaign ui/derpy_mr_stores_*.twui.xml (tools/gen_mr_ui.py).
-- Runtime components ignore XML offsets, so every part is placed here from DERPY_MR_STORES_L.
-- ==========================================================================================
S.PATH = "ui/campaign ui/"
S.BUTTON = "derpy_mr_stores_button"
S.ARMY_BUTTON = "derpy_mr_army_open"
S.PANEL = "derpy_mr_stores_panel"
S.CLOSE = "derpy_mr_close"
S.BACK = "derpy_mr_back"
S.TAB = { goods = "derpy_mr_tab_goods", settlements = "derpy_mr_tab_settlements",
          trade = "derpy_mr_tab_trade", spending = "derpy_mr_tab_spending", map = "derpy_mr_tab_map",
          workshop = "derpy_mr_tab_workshop", production = "derpy_mr_tab_production" }
S.MAP = { dot = "derpy_mr_mapdot_", cart = "derpy_mr_mapcart_", label = "derpy_mr_maplabel_" }
S.MAP_FILE = { dot = "derpy_mr_stores_mapdot", cart = "derpy_mr_stores_mapcart", label = "derpy_mr_stores_maplabel" }
S.map_made = { dot = 0, cart = 0, label = 0 }   -- how many of each the panel holds
-- a road's dots: one template per colour terrain_routes.lua's R.colour hands out
for n = 0, L.MAP_PATH_COLOURS - 1 do
    S.MAP["path" .. n], S.MAP_FILE["path" .. n] = "derpy_mr_mappath" .. n .. "_", "derpy_mr_stores_mappath_" .. n
    S.map_made["path" .. n] = 0
end
S.map_hits = {}                                           -- a map component's name -> where a click flies
S.map_view = nil       -- after a zoom: {zoom, cx, cy} in map units; nil frames the map as it first was
S.map_last = nil       -- the model last drawn, which a zoom reads its scale and surface off
S.ZOOM_IN, S.ZOOM_OUT = "derpy_mr_zoom_in", "derpy_mr_zoom_out"
S.map_drag = nil       -- {x, y}: where the picture was when the grab layer's drag began
S.MAP_GRAB = "derpy_mr_map_grab"
-- THE MAP'S KEY: the layout's entry, the icon the map draws for it, and its name
S.MAP_KEY = { { "cap", L.MAP_CAP_ICON, S.T("Province capital") }, { "town", L.MAP_TOWN_ICON, S.T("Settlement") },
              { "cart", L.MAP_CART, S.T("Convoy") } }
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

-- ---- PANEL SIZE (author, 2026-11-02: "UI size options, same as the derpy great guilds mod") ------
-- MCT's Small / Medium / Large, the Great Guilds' (GGUI.SIZES). No call changes a font, and
-- font_scale stretches the glyphs it already drew (soft text, Great Guilds 2026-10-08), so each size
-- is its own set of .twui.xml with real fonts. DERPY_MR_STORES_SIZES carries each size's layout, and
-- L is pointed at it before the panel is built, so every MoveTo here draws at that size. The HUD
-- opener stays CA's HUD size at every size and reads DERPY_MR_STORES_L.
S.SIZE, S.F, S.SUFFIX = "medium", 1, ""

-- Read on every open and never frozen into the save. MCT keeps it each player's own in multiplayer.
function S.want_size()
    local ok, v = pcall(function()
        local mct = get_mct and get_mct()
        local mod = mct and mct:get_mod_by_key("derpy_more_resources")
        local opt = mod and mod:get_option_by_key("ui_size")
        return opt and opt:get_finalized_setting()
    end)
    if ok and DERPY_MR_STORES_SIZES[v] then return v end
    return "medium"
end

-- How far the screen is past the 1920x1080 the panel was laid out for. core:get_screen_resolution()
-- is already the window over the player's UI Scale, so a 4K screen at 200% is 1 here. Never below 1,
-- led by height and capped by width, in hundredths.
function S.scale_for(sw, sh)
    if type(sw) ~= "number" or type(sh) ~= "number" or sw <= 0 or sh <= 0 then return 1 end
    local s = math.min(sw / 1920, sh / 1080)
    if s <= 1 then return 1 end
    return math.floor(s * 100 + 0.5) / 100
end

-- THE SIZE THAT IS DRAWN: the file set nearest the size asked for times the screen factor, among the
-- ones that fit the screen. The screen factor is spent here on a real font and never on font_scale, so
-- 1440p's Medium draws Large's files, and past Large the panel stays Large.
function S.pick_size(want, sw, sh, sa)
    local z = DERPY_MR_STORES_SIZES[want] and want or "medium"
    local target = DERPY_MR_STORES_SIZES[z].f * (sa or 1)
    local any = type(sw) ~= "number" or type(sh) ~= "number"
    local best, gap = "medium", 1e30          -- not math.huge: the game's math library has none
    for _, k in ipairs({ "small", "medium", "large" }) do
        local s = DERPY_MR_STORES_SIZES[k]
        local d = math.abs(s.f - target)
        if (any or (s.layout.W <= sw and s.layout.H <= sh)) and d < gap then best, gap = k, d end
    end
    return best
end

-- A length the layout does not carry, at the size drawn
function S.px(v) return math.floor(v * S.F + 0.5) end

-- Point L at a size. The panel built at another size goes, and everything kept about its parts: its
-- rows, list and map parts are that size's files.
function S.use_size(k)
    if k == S.SIZE then return end
    local p = S.panel()
    if is_uicomponent(p) then pcall(function() p:Destroy() end) end
    local z = DERPY_MR_STORES_SIZES[k]
    S.SIZE, S.F, S.SUFFIX, L = k, z.f, z.suffix, z.layout
    S.list_key, S.list_broken, S.map_drag, S.map_last = nil, nil, nil, nil
    for kind in pairs(S.map_made) do S.map_made[kind] = 0 end
end

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
    pcall(function() root:CreateComponent(S.PANEL, S.PATH .. "derpy_mr_stores_panel" .. S.SUFFIX) end)
    local p = S.panel()
    if not is_uicomponent(p) then return nil end
    p:SetVisible(false)
    p:SetInteractive(false)
    set(find_uicomponent(p, "title_text"), S.T("Resource Vault"))
    label(find_uicomponent(p, S.TAB.goods), S.T("Resources"))
    for _, dm in ipairs(S.BULK_ORDER) do
        local bt = find_uicomponent(p, S.BULK .. dm[1] .. "_" .. dm[2])
        label(bt, S.BULK_LABEL[dm[1]][dm[2]])
        if is_uicomponent(bt) then bt:SetTooltipText(S.BULK_TIP[dm[1]][dm[2]], true) end
    end
    label(find_uicomponent(p, S.TAB.settlements), S.T("Settlements"))
    label(find_uicomponent(p, S.TAB.trade), S.T("Trade"))
    label(find_uicomponent(p, S.TAB.spending), S.T("Spending"))
    label(find_uicomponent(p, S.TAB.map), S.T("Map"))
    label(find_uicomponent(p, S.TAB.workshop), S.T("Workshop"))
    label(find_uicomponent(p, S.TAB.production), S.T("Production"))
    label(find_uicomponent(p, S.BACK), S.T("Back"))
    -- the chart's twenty bars, made once and kept; draw_chart sizes, shows and hides them
    for i = 1, L.BARS do
        pcall(function() p:CreateComponent(S.BAR .. i, S.PATH .. "derpy_mr_stores_bar" .. S.SUFFIX) end)
        local b = find_uicomponent(p, S.BAR .. i)
        if is_uicomponent(b) then b:SetVisible(false) end
    end
    -- an escort's cards, made once and kept; draw_cards shows, places and hides them
    for i = 1, L.CARDS do
        pcall(function() p:CreateComponent(S.CARD .. i, S.PATH .. "derpy_mr_stores_card" .. S.SUFFIX) end)
        local c = find_uicomponent(p, S.CARD .. i)
        if is_uicomponent(c) then c:SetVisible(false) end
    end
    -- the box for CA's map, made before any map dot so the engine draws it beneath them
    local clip = S.map_clip(p)
    if clip then clip:SetVisible(false) end
    return p
end

-- Centred on the screen, computed and never read back (the Exchange's lesson).
function S.layout(p)
    local sw, sh = core:get_screen_resolution()
    sized(p, L.W, L.H)
    p:MoveTo(math.floor((sw - L.W) / 2), math.floor((sh - L.H) / 2))
    local px, py = p:Position()
    local boxes = { title_text = L.title, title_rule = L.title_rule, sub_title = L.sub_title,
                    empty_text = L.empty, hint_text = L.hint }
    boxes[S.CLOSE], boxes[S.BACK] = L.close, L.back
    for view, name in pairs(S.TAB) do boxes[name] = L["tab_" .. view] end
    for name, box in pairs(boxes) do put(find_uicomponent(p, name), px, py, box) end
    -- the hint sits at the right end of the sub-title's line
    local hint = find_uicomponent(p, "hint_text")
    if is_uicomponent(hint) then hint:SetTextHAlign("right") end
    for i, dm in ipairs(S.BULK_ORDER) do
        local x = L.bulk[1] + (i - 1) * (L.bulk[3] + L.BULK_GAP)
        put(find_uicomponent(p, S.BULK .. dm[1] .. "_" .. dm[2]), px, py, { x, L.bulk[2], L.bulk[3], L.bulk[4] })
    end
end

-- A COLUMN LINE in the middle of the gap before column j (j >= 2)
function S.line_x(cols, j)
    local prev = cols[j - 1]
    return math.floor((prev[1] + prev[2] + cols[j][1]) / 2)
end

local function align(c, a)
    if is_uicomponent(c) then c:SetTextHAlign(a) end
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
    pcall(function() p:CreateComponent(S.LIST, S.PATH .. "derpy_mr_stores_list" .. S.SUFFIX) end)
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
        -- THE EXCHANGE'S SLIDER: the track between a cap at each end, the four end parts placed
        -- after it, since a parent's MoveTo carries its children
        local sx, ty, th = x + w - L.SLIDER_W, y + L.SLIDER_CAP, h - 2 * L.SLIDER_CAP
        slider:MoveTo(sx, ty)
        sized(slider, L.SLIDER_W, th)
        for _, part in ipairs(L.SLIDER_PARTS) do
            local c = find_uicomponent(slider, part[1])
            local base = (part[1] == "frame_bottom" or part[1] == "bottom") and ty + th or ty
            if is_uicomponent(c) then c:MoveTo(sx + part[2], base + part[3]) end
        end
        -- THE TRAVEL IS A NUMBER, not a size: Resize never reaches it
        pcall(function() slider:SetProperty("maxValue", th - L.HANDLE_H) end)
        local handle = find_uicomponent(slider, "handle")
        if is_uicomponent(handle) then
            pcall(function() handle:SetProperty("max_height", th - L.HANDLE_H) end)
        end
        slider:SetVisible(n > S.rows_shown())
    end
    for i = 1, n do
        local name = S.SP .. "_" .. i
        pcall(function() box:CreateComponent(name, S.PATH .. "derpy_mr_stores_sp" .. S.SUFFIX) end)
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
    local p = S.panel()
    if not is_uicomponent(p) or not p:Visible() then return end
    if S.view == "map" then S.map_hold(p) end
    if not S.list_key then return end
    S.follow_list(p)
end

-- A DRAGGED MAP STAYS ON THE PICTURE: wherever the mouse leaves it, it is put back so it still
-- covers the map's box (a picture smaller than the box stays where it was drawn). Everything on
-- it is its child and comes along.
function S.map_hold(p)
    local clip = find_uicomponent(p, S.MAP_CLIP)
    local art = S.map_surface(p)
    if not (is_uicomponent(clip) and clip:Visible() and art) then return end
    local cx, cy = clip:Position()
    local cw, ch = clip:Dimensions()
    local ax, ay = art:Position()
    local aw, ah = art:Dimensions()
    local function hold(a, c, aw_, cw_)
        if aw_ < cw_ then return a end
        return math.max(c + cw_ - aw_, math.min(c, a))
    end
    -- THE ENGINE DRAGS THE GRAB LAYER, NEVER THE PICTURE. A "Movable XP" component goes back where
    -- its drag began when let go, as a dropped unit card does; holding the picture there after the
    -- put-back still showed it back home for one frame (seen in game 2026-10-04). So the picture
    -- follows the grab layer's offset from its rest (the box's corner) while IsDragged, and the
    -- put-back happens to a layer nobody can see.
    local nx, ny = ax, ay
    local grab = find_uicomponent(clip, S.MAP_GRAB)
    local okd, dragged = false, false
    if is_uicomponent(grab) then okd, dragged = pcall(function() return grab:IsDragged() end) end
    if okd and dragged then
        local gx, gy = grab:Position()
        S.map_drag = S.map_drag or { ax, ay }
        nx, ny = S.map_drag[1] + gx - cx, S.map_drag[2] + gy - cy
    else
        S.map_drag = nil
        if is_uicomponent(grab) then
            local gx, gy = grab:Position()
            if gx ~= cx or gy ~= cy then grab:MoveTo(cx, cy) end
        end
    end
    nx, ny = hold(nx, cx, aw, cw), hold(ny, cy, ah, ch)
    if nx ~= ax or ny ~= ay then art:MoveTo(nx, ny) end
end

-- ---- rows ---------------------------------------------------------------------------------
function S.row(holder, i)
    local name = S.ROW .. i
    local r = find_uicomponent(holder, name)
    if is_uicomponent(r) then return r end
    pcall(function() holder:CreateComponent(name, S.PATH .. "derpy_mr_stores_row" .. S.SUFFIX) end)
    return find_uicomponent(holder, name)
end

-- The Trade tab's two checkboxes: shown where the row carries their state, which only a Trade
-- row does, and only with the flows script loaded. Centred under their centred headers.
local function draw_switches(r, rc, rx, ry, cols)
    for j, d in ipairs(S.DIRS) do
        local sw = find_uicomponent(r, S.SW .. d)
        if is_uicomponent(sw) then
            local show = rc[d] ~= nil
            sw:SetVisible(show)
            if show then
                local col = cols[2 + j]
                sw:MoveTo(rx + col[1] + math.floor((col[2] - L.CHECK) / 2),
                          ry + math.floor((L.PITCH - L.CHECK) / 2))
                local art = S.CHECK[not rc[d]]
                sw:SetImagePath(art[1], 0)
                sw:SetImagePath(art[2], 1)
                sw:SetOpacity(rc.dim and S.DIM or 255, true)
                sw:SetTooltipText(S.switch_tip(d, rc[d], rc.name or rc[1]), true)   -- rc[1] is greyed markup
            end
        end
    end
end

-- Rows are made once and kept; the ones past the end go hidden.
-- THE EDICTS (design 2026-11-01 Part B), above the goods as CA's Commandments list: one option of
-- three in force and glowing, the others live while the edict is ready and greyed while it waits.
-- A faction that does not eat has no Rations row (flows.lua F.edict_set refuses it).
function S.edict_rows(v)
    local f = S.local_faction()
    if not (f and S.ask("edicts_on") and S.ask("uses_stores", f)) then return end
    local fk, chd, eats = f:name(), S.ask("race", f) == "chd", S.ask("eats", f)
    v.rows[#v.rows + 1] = { S.section(S.T("Edicts")), "", "", "", "", section = true }
    for _, e in ipairs(DERPY_MR_STORES_EDICTS) do
        if e.key ~= "rations" or eats then
            local now, wait = S.ask("edict", fk, e.key), S.ask("edict_wait", fk, e.key) or 0
            local row = { e.name, wait > 0 and (S.T("Wait {1}", turns(wait))) or S.T("Ready"), "", "", "",
                          edict = e.key, tip = e.tip, choices = {} }
            for j, o in ipairs(e.options) do
                local tip = (chd and o.tip_chd) or o.tip
                if wait > 0 then tip = S.T("{1}\nThis edict can change again in {2}.", tip, turns(wait)) end
                row.choices[j] = { key = o.key, label = o.label, tip = tip, on = o.key == now, off = o.key ~= now and wait > 0 }
            end
            v.rows[#v.rows + 1] = row
        end
    end
    v.rows[#v.rows + 1] = { S.section(S.T("Resources")), "", "", "", "", section = true }
end

function S.draw_rows(p, rows, heads, cols)
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
            -- every other row banded; the section row has its own band
            local band, sband = find_uicomponent(r, "band"), find_uicomponent(r, "section_band")
            if is_uicomponent(band) then
                band:MoveTo(rx, ry)
                band:SetVisible(i % 2 == 0 and not rc.section)
            end
            if is_uicomponent(sband) then
                sband:MoveTo(rx, ry)
                sband:SetVisible(rc.section == true)
            end
            local icons = rc.icons or { rc.icon }
            for k = 1, L.ICONS do
                local ic = find_uicomponent(r, k == 1 and "icon" or "icon" .. k)
                if is_uicomponent(ic) then
                    ic:MoveTo(rx + L.icon[1] + (k - 1) * L.ICON_PITCH, ry + L.icon[2])
                    ic:SetVisible(icons[k] ~= nil)
                    if icons[k] then
                        ic:SetImagePath(icons[k], 0)
                        ic:SetOpacity(rc.dim and S.DIM or 255, true)
                    end
                end
            end
            for j, col in ipairs(cols) do
                local c = find_uicomponent(r, "c" .. j)
                if is_uicomponent(c) then
                    -- a lead icon (the Workshop's price) puts the text after it
                    local dx = j == 1 and shift or (rc.lead and rc.lead[j] and L.ICON_PITCH) or 0
                    c:MoveTo(rx + col[1] + dx, ry + S.px(4))
                    sized(c, col[2] - dx, S.px(20))
                    align(c, col[3])
                    set(c, rc[j])
                end
            end
            draw_switches(r, rc, rx, ry, cols)
            -- the Spending tab's supply boxes, in columns 2-5
            for k, sp in ipairs(DERPY_MR_STORES_SUPPLY) do
                local sw, b = find_uicomponent(r, S.SW .. sp.key), rc.supply and rc.supply[sp.key]
                -- every row has the pay icons: hidden unless this row's supply pays with something
                local pic = find_uicomponent(r, S.PAYIC .. sp.key)
                if is_uicomponent(pic) then pic:SetVisible(b ~= nil and b.pay ~= nil) end
                if is_uicomponent(sw) then
                    sw:SetVisible(b ~= nil)
                    if b then
                        local col = cols[1 + k]
                        -- the box alone, or the box and its good's icon as a centred pair
                        local wide = b.pay and (L.CHECK + L.PAY_GAP + L.icon[3]) or L.CHECK
                        local bx = rx + col[1] + math.floor((col[2] - wide) / 2)
                        sw:MoveTo(bx, ry + math.floor((L.PITCH - L.CHECK) / 2))
                        local ic = find_uicomponent(r, S.PAYIC .. sp.key)
                        if is_uicomponent(ic) then
                            if b.pay then
                                ic:MoveTo(bx + L.CHECK + L.PAY_GAP, ry + math.floor((L.PITCH - L.icon[4]) / 2))
                                ic:SetImagePath(b.pay.icon, 0)
                                ic:SetTooltipText(b.pay.tip, true)
                                -- on: glowing while it pays, red (CA's "insufficient") when the
                                -- next turn's price is more than it holds; off: grey when short
                                S.fx(ic, b.on and (b.pay.short and "short" or "glow") or (b.pay.short and "off" or "live"))
                            end
                        end
                        local art = S.CHECK[b.on]
                        sw:SetImagePath(art[1], 0)
                        sw:SetImagePath(art[2], 1)
                        sw:SetTooltipText(b.tip, true)
                    end
                end
            end
            -- the stock rules' -10 / Auto / +10, or an edict's three options
            for j, action in ipairs({ "minus", "auto", "plus" }) do
                local button = find_uicomponent(r, S.POLICY .. action)
                local ch = rc.choices and rc.choices[j]
                if is_uicomponent(button) then
                    button:SetVisible(rc.policy ~= nil or ch ~= nil)
                    if rc.policy or ch then
                        -- ROWS ARE POOLED: a width an edict row set stays on the row unless set every draw
                        sized(button, ch and L.EDICT_W or L.POLICY_W[j], L.send[2])
                        button:MoveTo(rx + cols[j + 2][1], ry + math.floor((L.PITCH - L.send[2]) / 2))
                        label(button, ch and ch.label or ({ "-10", rc.route and "100" or S.T("Auto"), "+10" })[j])
                        button:SetTooltipText(ch and ch.tip or rc.tip, true)
                        S.set_off(button, ch ~= nil and ch.off)
                        if ch and ch.on then S.fx(button, "glow") end
                    end
                end
            end
            -- Send here on a settlement's resources; Show on a Spending tab shipment
            local sb = find_uicomponent(r, S.SEND)
            if is_uicomponent(sb) then
                sb:SetVisible(rc.send ~= nil)
                if rc.send then
                    sb:MoveTo(rx + cols[5][1], ry + math.floor((L.PITCH - L.send[2]) / 2))
                    label(sb, rc.send.label or S.T("Send here"))
                    sb:SetTooltipText(rc.send.tip, true)
                    S.set_off(sb, rc.send.off)
                end
            end
            -- the Using column's icons: a Settlements row's bundles, in the third column; or a
            -- row's lead icons, one at the start of each column that has one
            local leads = {}
            for j = 1, #cols do
                if rc.lead and rc.lead[j] then leads[#leads + 1] = { rx + cols[j][1], rc.lead[j] } end
            end
            -- A ROW WITH A PRICE AND LEAD ICONS (the Production tab's inputs and Gives): the price takes the
            -- first slots, the leads the ones after it
            local np = rc.price and #rc.price or 0
            for k = 1, L.USING do
                local u = find_uicomponent(r, "use" .. k)
                local pk = rc.price and rc.price[k]
                if is_uicomponent(u) then
                    local path, x = rc.using and rc.using[k], rx + cols[3][1] + (k - 1) * L.ICON_PITCH
                    if rc.lead then path, x = leads[k] and leads[k][2], leads[k] and leads[k][1] end
                    -- A NAMED RECIPE'S PRICE: each good's icon, PRICE_PITCH apart from column 3, grey when short
                    if pk then path, x = pk.icon, rx + cols[3][1] + (k - 1) * L.PRICE_PITCH
                    elseif rc.price then
                        local ld = leads[k - np]
                        path, x = ld and ld[2], ld and ld[1]
                    end
                    u:SetVisible(path ~= nil)
                    if path then
                        u:MoveTo(x, ry + L.icon[2])
                        u:SetImagePath(path, 0)
                        S.fx(u, (pk and pk.short or rc.dim) and "off" or "live")
                    end
                end
                -- and its amount after it
                local n = find_uicomponent(r, "pn" .. k)
                if is_uicomponent(n) then
                    n:SetVisible(pk ~= nil)
                    if pk then
                        n:MoveTo(rx + cols[3][1] + (k - 1) * L.PRICE_PITCH + L.ICON_PITCH, ry + S.px(4))
                        set(n, pk.text)
                    end
                end
            end
            -- a column line in each gap before a column that has a header; none on a section row
            for j = 2, #cols do
                local vl = find_uicomponent(r, "vline" .. j)
                if is_uicomponent(vl) then
                    vl:MoveTo(rx + S.line_x(cols, j), ry)
                    vl:SetVisible((heads[j] or "") ~= "" and not rc.section)
                end
            end
            local div = find_uicomponent(r, "divider")
            if is_uicomponent(div) then div:MoveTo(rx, ry + L.PITCH - S.px(2)) end
            -- A FOLDABLE SECTION'S ARROW, in the icon slot: drawn pointing down (open), turned
            -- clockwise by three quarters to point right (folded), as CA's lib_text_pointers turns its own
            local ar = find_uicomponent(r, "fold")
            if is_uicomponent(ar) then
                ar:SetVisible(rc.fold ~= nil)
                if rc.fold ~= nil then
                    ar:MoveTo(rx + L.icon[1] + math.floor((L.icon[3] - L.FOLD) / 2), ry + math.floor((L.PITCH - L.FOLD) / 2))
                    ar:SetImageRotation(0, rc.folded and math.pi * 3 / 2 or 0)
                end
            end
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
-- The pool's i-th component of a kind, made the first time it is wanted and kept.
-- The box that cuts CA's map to the Map tab's, and the picture in it: made once, on first need.
S.MAP_CLIP = "derpy_mr_map_clip"
function S.map_clip(p)
    local c = find_uicomponent(p, S.MAP_CLIP)
    if is_uicomponent(c) then return c end
    pcall(function() p:CreateComponent(S.MAP_CLIP, S.PATH .. "derpy_mr_stores_mapart" .. S.SUFFIX) end)
    c = find_uicomponent(p, S.MAP_CLIP)
    return is_uicomponent(c) and c or nil
end

-- EVERY SETTLEMENT NAMED, the province capitals first; a name that would overlap one already
-- placed is left off (its dot and tooltip stay), and one that would run past the map's right
-- edge goes on its dot's left, set against it.
-- THE BOX IS THE NAME'S OWN WIDTH, measured in the label's font, so its left-aligned text ends
-- where the box does on either side. Seen in game 2026-10-07: a name on its dot's left in a 160
-- box with SetTextHAlign("right") still drew from the box's left edge, ~75px short of the dot.
function S.map_names(p, m, bx, by, shown)
    local order = {}
    for _, d in ipairs(m.dots) do if d.cap then order[#order + 1] = d end end
    for _, d in ipairs(m.dots) do if not d.cap then order[#order + 1] = d end end
    local lh, taken = L.map_label[2], {}
    local ruler = S.map_part(p, "label", 1)
    for _, d in ipairs(order) do
        local gap = math.floor((d.cap and L.MAP_CAP or L.MAP_DOT) / 2) + S.px(4)
        local ok, w = false, nil
        if ruler then ok, w = pcall(function() return ruler:WidthOfTextLine(d.name) end) end
        local tw = (ok and type(w) == "number" and w > 0) and math.ceil(w) or S.label_w(d.name)
        local right = d.x + gap + tw <= L.map[3]
        local tx, ly = right and d.x + gap or d.x - gap - tw, d.y - math.floor(lh / 2)
        local free = true
        for _, b in ipairs(taken) do
            if tx < b[1] + b[3] and b[1] < tx + tw and ly < b[2] + lh and b[2] < ly + lh then
                free = false
                break
            end
        end
        if free then
            taken[#taken + 1] = { tx, ly, tw }
            shown.label = shown.label + 1
            local lab = S.map_part(p, "label", shown.label)
            if lab then
                put(lab, bx, by, { tx, ly, tw + 2, lh })   -- 2 spare, so a rounding never clips a letter
                set(lab, d.name)
                lab:SetVisible(true)
            end
        end
    end
end

-- The picture every dot, name, road and cart is made on: drawn over it, cut with it, dragged with it.
function S.map_surface(p)
    local clip = find_uicomponent(p, S.MAP_CLIP)
    local art = is_uicomponent(clip) and find_uicomponent(clip, "derpy_mr_map_art")
    return is_uicomponent(art) and art or nil
end

function S.map_part(p, kind, i)
    local name = S.MAP[kind] .. i
    local c = find_uicomponent(p, name)
    if is_uicomponent(c) then return c end
    local on = S.map_surface(p) or p
    pcall(function() on:CreateComponent(name, S.PATH .. S.MAP_FILE[kind] .. S.SUFFIX) end)
    c = find_uicomponent(p, name)
    if is_uicomponent(c) and i > S.map_made[kind] then S.map_made[kind] = i end
    return is_uicomponent(c) and c or nil
end

-- Centred on (x, y) in the map's box; every part past the ones shown goes hidden.
function S.draw_map(p, m)
    local px, py = p:Position()
    local bx, by = px + L.map[1], py + L.map[2]
    local shown = {}
    for kind in pairs(S.MAP) do shown[kind] = 0 end
    S.map_hits = {}
    S.map_last = m
    -- the bottom line: the key, then Zoom out and Zoom in in slots 3 and 4
    for _, k in ipairs(S.MAP_KEY) do
        local ic, tx = find_uicomponent(p, "derpy_mr_mapkey_" .. k[1]), find_uicomponent(p, "derpy_mr_mapkey_" .. k[1] .. "_text")
        for j, c in ipairs({ ic, tx }) do
            if is_uicomponent(c) then
                c:SetVisible(m ~= nil)
                if m then put(c, px, py, L.map_key[k[1]][j]) end
            end
        end
        if m and is_uicomponent(ic) then ic:SetImagePath(k[2], 0) end
        if m then set(tx, k[3]) end
    end
    local function place(kind, x, y, size)
        shown[kind] = shown[kind] + 1
        local c = S.map_part(p, kind, shown[kind])
        if not c then return nil end
        sized(c, size, size)
        c:MoveTo(bx + x - math.floor(size / 2), by + y - math.floor(size / 2))
        c:SetVisible(true)
        return c
    end
    -- the surface first: CA's picture, or a clear one on a map with no picture
    local clip = find_uicomponent(p, S.MAP_CLIP)
    local on = m ~= nil and m.surface ~= nil
    if is_uicomponent(clip) then
        clip:SetVisible(on)
        if on then
            put(clip, px, py, L.map)
            local art = S.map_surface(p)
            if art then
                art:SetImagePath(m.art and m.art.path or S.NO_ART, 0)
                put(art, bx, by, m.surface)
            end
            local o = L.MAP_FRAME_OUT
            put(find_uicomponent(clip, "derpy_mr_map_frame"), px, py,
                { L.map[1] - o, L.map[2] - o, L.map[3] + 2 * o, L.map[4] + 2 * o })
            put(find_uicomponent(clip, S.MAP_GRAB), px, py, L.map)
        end
    end
    -- + AND - ARE THE BOX'S CHILDREN, so they are placed after it: placed first, the box's own
    -- MoveTo carried them off by however far it moved (seen in game 2026-10-04: no + and - on a
    -- session's first draw)
    local zoom = m ~= nil and m.scale ~= nil
    for _, z in ipairs({ { S.ZOOM_OUT, "-", zoom and m.can_out, S.T("Zoom out"), S.T("Draw more of the map."), L.zoom_out },
                         { S.ZOOM_IN, "+", zoom and m.can_in, S.T("Zoom in"), S.T("Draw the map closer."), L.zoom_in } }) do
        local bt = find_uicomponent(p, z[1])
        if is_uicomponent(bt) then
            bt:SetVisible(zoom)
            if zoom then
                put(bt, px, py, z[6])
                label(bt, z[2])
                bt:SetTooltipText(z[4] .. "||" .. (z[3] and z[5] or S.T("As far as it goes.")), true)
                S.set_off(bt, not z[3])
            end
        end
    end
    if m then
        -- the road first, then the settlements, then the carts: each drawn over the one before
        for _, d in ipairs(m.path) do place("path" .. d.colour, d.x, d.y, L.MAP_PATH) end
        for _, d in ipairs(m.dots) do
            local c = place("dot", d.x, d.y, d.cap and L.MAP_CAP or L.MAP_DOT)
            if c then
                c:SetImagePath(d.cap and L.MAP_CAP_ICON or L.MAP_TOWN_ICON, 0)
                c:SetImagePath(d.cap and L.MAP_CAP_ICON or L.MAP_TOWN_ICON, 1)   -- its hover: brightened
                c:SetTooltipText(S.T("{1}{2}\nClick to fly there.", d.name, (d.cap and S.T(" (province capital)") or "")), true)
                S.map_hits[c:Id()] = { d.lx, d.ly }
            end
        end
        S.map_names(p, m, bx, by, shown)
        for _, c in ipairs(m.carts) do
            local k = place("cart", c.x, c.y, L.MAP_CART_SIZE)
            if k then
                k:SetTooltipText(c.stack and #c.stack > 1 and S.convoy_tip(c.stack) or S.ship_tip(c.s), true)
                S.fx(k, "glow")     -- a convoy on the road pulses, as CA's active markers do
                S.map_hits[k:Id()] = { c.lx, c.ly }
            end
        end
    end
    for kind, made in pairs(S.map_made) do
        for i = shown[kind] + 1, made do
            local c = find_uicomponent(p, S.MAP[kind] .. i)
            if is_uicomponent(c) then c:SetVisible(false) end
        end
    end
end

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
    local bx, by, bh, n = L.bars[1], L.bars[2], L.bars[4], #bars
    -- AT THE RIGHT, newest last: the latest turn stands over "Turn N" however many turns there are
    local function bar_x(i) return bx + L.bars[3] - L.BAR_W - (n - i) * L.BAR_PITCH end
    for _, name in ipairs({ "chart_base", "chart_grid" }) do
        local rule = find_uicomponent(p, name)
        if is_uicomponent(rule) then
            put(rule, px, py, L[name])
            rule:SetVisible(n > 0)
        end
    end
    -- the first turn's name under the first bar, dropped where it would meet the last turn's
    local from = find_uicomponent(p, "chart_from")
    if is_uicomponent(from) and n > 0 then
        local right = L.chart_to[1] + L.chart_to[3] - string.len(c.chart_to) * L.HEAD_CHAR_W - L.GAP
        local w = math.min(L.chart_from[3], right - bar_x(1))
        put(from, px, py, { bar_x(1), L.chart_from[2], math.max(w, 1), L.chart_from[4] })
        from:SetVisible(bar_x(1) + string.len(c.chart_from) * L.HEAD_CHAR_W <= right)
    end
    for i = 1, L.BARS do
        local b = find_uicomponent(p, S.BAR .. i)
        if is_uicomponent(b) then
            local d = bars[i]
            if d then
                sized(b, L.BAR_W, d.h)
                b:MoveTo(px + bar_x(i), py + by + bh - d.h)
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
    local px, py = p:Position()
    for j, col in ipairs(v.cols) do
        local h = find_uicomponent(p, "hdr_" .. j)
        put(h, px, py, { L.list[1] + col[1], L.head_y, col[2], S.px(22) })
        align(h, col[3])
        set(h, v.heads[j])
        local hl = find_uicomponent(p, "hdr_line_" .. j)
        if is_uicomponent(hl) then
            hl:MoveTo(px + L.list[1] + S.line_x(v.cols, j), py + L.head_y)
            hl:SetVisible((v.heads[j] or "") ~= "")
        end
    end
    -- THE TABLE'S BORDER round the header and the list, and a rule between them; none on the map
    local F, top, bottom = L.FRAME, L.head_y - L.FRAME - S.px(2), L.list[2] + L.list[4]
    local edges = {
        t = { L.list[1] - F, top, L.list[3] + F * 2, F },
        b = { L.list[1] - F, bottom, L.list[3] + F * 2, F },
        l = { L.list[1] - F, top, F, bottom - top + F },
        r = { L.list[1] + L.list[3], top, F, bottom - top + F },
        head = { L.list[1], L.list[2] - F - 1, L.list[3], F },
    }
    for k, box in pairs(edges) do
        local e = find_uicomponent(p, "derpy_mr_frame_" .. k)
        if is_uicomponent(e) then
            put(e, px, py, box)
            e:SetVisible(v.map == nil)
        end
    end
    set(find_uicomponent(p, "hint_text"), v.hint or "")
    -- THE ACTIONS on the bottom line: orders in slots 2-4 on the Resources tab, Sell in slot 4
    -- on a resource's drill-down
    S.act = { orders = {}, sell = v.sell }
    local slot_w = L.bulk[3] + L.BULK_GAP
    for i, o in ipairs(DERPY_MR_STORES_ORDERS) do
        local bt, a = find_uicomponent(p, S.ORDER .. o.key), v.orders and v.orders[i]
        if a then S.act.orders[o.key] = a end
        if is_uicomponent(bt) then
            bt:SetVisible(a ~= nil)
            if a then
                put(bt, px, py, { L.bulk[1] + i * slot_w, L.bulk[2], L.bulk[3], L.bulk[4] })
                label(bt, o.label)
                bt:SetTooltipText(a.tip, true)
                if a.active then
                    -- RUNNING, as CA's active states glow: still not clickable
                    bt:SetDisabled(true)
                    S.fx(bt, "glow")
                else
                    S.set_off(bt, a.off)
                end
            end
        end
    end
    local sell = find_uicomponent(p, S.SELL)
    if is_uicomponent(sell) then
        sell:SetVisible(v.sell ~= nil)
        if v.sell then
            put(sell, px, py, { L.bulk[1] + 3 * slot_w, L.bulk[2], L.bulk[3], L.bulk[4] })
            label(sell, S.T("Sell surplus"))
            sell:SetTooltipText(v.sell.tip, true)
            S.set_off(sell, v.sell.off)
        end
    end
    for _, dm in ipairs(S.BULK_ORDER) do
        local bt = find_uicomponent(p, S.BULK .. dm[1] .. "_" .. dm[2])
        if is_uicomponent(bt) then bt:SetVisible(v.bulk == true) end
    end
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
        empty:SetVisible(#v.rows == 0 and v.map == nil)
        put(empty, px, py, v.cards and L.escort_line or L.empty)   -- over an escort's cards, not on them
    end
    -- THE HOLDER STARTS AT THE TOP; a kept list's poll puts it back where the bar is.
    put(find_uicomponent(p, "rows_holder"), px, py, L.list)
    -- AS TALL AS WHAT IT HOLDS (docs/CUSTOM_UI.md, drawn whole, step 5): a row outside its
    -- parent's box is not known to take clicks or the wheel.
    local holder = find_uicomponent(p, "rows_holder")
    if is_uicomponent(holder) then sized(holder, L.list[3], math.max(S.rows_shown(), #v.rows) * L.PITCH) end
    -- NO LIST ON THE MAP: an empty one still covers the map's box and, made after it, takes the grab
    if v.map then S.drop_list(p) else S.ensure_list(p, #v.rows) end
    S.draw_rows(p, v.rows, v.heads, v.cols)
    S.draw_chart(p, v.chart)
    S.draw_map(p, v.map)
    S.draw_cards(p, v.cards)
end

-- THE ESCORT'S CARDS in one row, CARD_GAP apart as CA's army strip; the ones past it go hidden.
function S.draw_cards(p, cards)
    local px, py = p:Position()
    cards = cards or {}
    for i = 1, L.CARDS do
        local c = find_uicomponent(p, S.CARD .. i)
        if is_uicomponent(c) then
            c:SetVisible(cards[i] ~= nil)
            if cards[i] then
                c:MoveTo(px + L.cards[1] + (i - 1) * (L.CARD_W + L.CARD_GAP), py + L.cards[2])
                sized(c, L.CARD_W, L.CARD_H)
                c:SetImagePath(cards[i].card, 0)
                c:SetTooltipText(cards[i].tip, true)
            end
        end
    end
end

function S.is_open()
    local p = S.panel()
    return is_uicomponent(p) and p:Visible()
end

-- Reopening keeps the tab and drops the drill-down. Interactive only while visible: a hidden
-- panel that still takes the mouse is a dead zone in the middle of the map.
function S.show(on, focus)
    if on then
        local sw, sh = core:get_screen_resolution()
        S.use_size(S.pick_size(S.want_size(), sw, sh, S.scale_for(sw, sh)))
    end
    local p = S.panel()
    if not is_uicomponent(p) then p = S.build() end
    if not is_uicomponent(p) then return end
    S.list_key = nil
    if on then
        S.focus, S.map_view = focus, nil
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

-- ZOOM AROUND THE MIDDLE OF THE BOX: the spot there now, after any drag, read off where the
-- surface is, stays there at the new scale. A UI change only, so it needs no UITrigger.
function S.zoom(step)
    local p, m = S.panel(), S.map_last
    local art = is_uicomponent(p) and S.map_surface(p)
    if not (m and m.scale and art) then return end
    local px, py = p:Position()
    local ax, ay = art:Position()
    S.map_view = { zoom = m.zoom * step,
                   cx = m.su[1] + (L.map[3] / 2 - (ax - px - L.map[1])) / m.scale,
                   cy = m.su[2] + (L.map[4] / 2 - (ay - py - L.map[2])) / m.scale }
    return S.refresh()
end

function S.is_mine(name)
    return type(name) == "string" and (name == S.BUTTON or name == S.ARMY_BUTTON or name == S.CLOSE or name == S.BACK
        or name == S.TAB.goods or name == S.TAB.settlements or name == S.TAB.trade or name == S.TAB.spending
        or name == S.TAB.map or name == S.TAB.workshop or name == S.TAB.production or S.map_hits[name] ~= nil
        or string.sub(name, 1, #S.ROW) == S.ROW or string.sub(name, 1, #S.SW) == S.SW
        or string.sub(name, 1, #S.BULK) == S.BULK or string.sub(name, 1, #S.ORDER) == S.ORDER
        or string.sub(name, 1, #S.POLICY) == S.POLICY or name == S.SEND or name == S.SELL or name == S.ZOOM_IN or name == S.ZOOM_OUT)
end

-- A SWITCH NAMES NO GOOD: its row does, so the row is read off the clicked component's parent.
function S.click_switch(dir, component)
    if not component then return end
    local row = UIComponent(UIComponent(component):Parent())
    local i = tonumber(string.match(row:Id() or "", "^derpy_mr_row_(%d+)$"))
    local rc = i and S.data[i]
    if rc and rc.capital and rc.supply and rc.supply[dir] then return S.request("supply", rc.capital, dir) end
    local send = S.flows("send")
    if not (rc and rc.stem and send) then return end
    send(cm:get_local_faction_name(true), dir, rc.stem)
    return S.refresh()
end

function S.click_bulk(dir, mode)
    local send, what = S.flows("send"), S.flows(mode == "stop" and "ALL_STOP" or "ALL_ALLOW")
    if not (send and what) then return end
    send(cm:get_local_faction_name(true), dir, what)
    return S.refresh()
end

-- An action goes to the flows script's one door, F.request, which runs it now in singleplayer
-- and sends it as a UITrigger in multiplayer.
function S.request(...)
    local req = S.flows("request")
    if not req then return end
    req(cm:get_local_faction_name(true), ...)
    return S.refresh()
end

-- Send here names no resource: its row does, read off the clicked component's parent.
function S.click_send(component)
    if not component then return end
    local row = UIComponent(UIComponent(component):Parent())
    local i = tonumber(string.match(row:Id() or "", "^derpy_mr_row_(%d+)$"))
    local rc = i and S.data[i]
    if rc and rc.route_request and rc.send and not rc.send.off then return S.request(unpack(rc.route_request)) end
    if rc and rc.send and rc.send.look then return S.look_at(rc.send.look[1], rc.send.look[2]) end
    -- the state wanted, never a toggle; and a click within half a second of the last one is the second half of a double
    -- click on the row redrawn under the cursor (seen 2026-11-03: Hire then Dismiss), so it is dropped
    if rc and rc.guards then
        local t = os.clock()
        if S.guards_at and t - S.guards_at < 0.5 then return end
        S.guards_at = t
        return S.request("guards", rc.guards)
    end
    if rc and rc.provisions and rc.send and not rc.send.off then
        return S.request("provisions", rc.army, rc.provisions)
    end
    if rc and rc.economy and rc.send and not rc.send.off then
        return S.request("economy", rc.region, rc.economy)
    end
    -- the Workshop: Buy names its row, Buy here its row and settlement
    if rc and rc.work then
        if rc.open then
            S.focus = rc.open
            return S.refresh()
        end
        if rc.send and not rc.send.off then
            if rc.region then return S.request("upgrade", rc.work, rc.region) end
            -- THE SELECTION MOVED since the rows were drawn (stage 2 final review): draw them again
            -- rather than buy for the army the row was drawn for
            if rc.aim then
                if S.selected() ~= rc.aim then return S.refresh() end
                return S.request("aim", rc.work, tostring(rc.aim))
            end
            return S.request("work", rc.work)
        end
        return
    end
    if rc and rc.found then
        if not rc.send.off then return S.request("found", rc.found) end
        return
    end
    if rc and rc.send and not rc.send.off then return S.request("send", rc.stem, S.focus) end
end

function S.click_policy(action, component)
    if not component then return end
    local row = UIComponent(UIComponent(component):Parent())
    local i = tonumber(string.match(row:Id() or "", "^derpy_mr_row_(%d+)$"))
    local rc = i and S.data[i]
    -- AN EDICT ROW: the button's place names its option; the one in force and a waiting edict do nothing
    local ch = rc and rc.choices and rc.choices[({ minus = 1, auto = 2, plus = 3 })[action]]
    if ch then
        if not ch.on and not ch.off then return S.request("edict", rc.edict, ch.key) end
        return
    end
    if not S.focus then return end
    if rc and rc.route and rc.policy then
        local f = S.local_faction()
        for _, o in ipairs(f and S.ask("routes", f) or {}) do
            if o.id == rc.route then
                local n = action == "auto" and 100 or o[rc.policy] + (action == "plus" and 10 or -10)
                return S.request("route_edit",o.id,rc.policy,tostring(math.max(rc.policy == "batch" and 2 or 1,math.min(rc.policy == "batch" and 100 or 1000000,n))))
            end
        end
        return
    end
    if S.view ~= "trade" then return end
    if not rc or not rc.policy or rc.stem ~= S.focus then return end
    local c = S.policy_context(rc.stem)
    if not c then return end
    local value = "auto"
    if action ~= "auto" then
        local n = c.policy[rc.policy]
        if n == nil then
            n = c[rc.policy]
            n = action == "plus" and (math.floor(n / 10) * 10 + 10) or (math.ceil(n / 10) * 10 - 10)
        else n = n + (action == "plus" and 10 or -10) end
        value = tostring(math.max(0, math.min(1000000, n)))
    end
    return S.request("stock", rc.stem, rc.policy, value)
end

function S.click(name, component)
    local policy_action = string.match(name, "^derpy_mr_policy_(%a+)$")
    if policy_action == "minus" or policy_action == "auto" or policy_action == "plus" then return S.click_policy(policy_action, component) end
    if name == S.SEND then return S.click_send(component) end
    if S.map_hits[name] then return S.look_at(S.map_hits[name][1], S.map_hits[name][2]) end
    -- the model clamps the zoom, so a greyed button's click changes nothing
    if name == S.ZOOM_IN then return S.zoom(L.MAP_ZOOM_STEP) end
    if name == S.ZOOM_OUT then return S.zoom(1 / L.MAP_ZOOM_STEP) end
    if name == S.SELL then
        if S.act.sell and not S.act.sell.off then return S.request("sell", S.focus) end
        return
    end
    local okey = string.match(name, "^derpy_mr_order_([%w_]+)$")
    if okey then
        local a = S.act.orders[okey]
        if a and not a.off then return S.request("order", okey) end
        return
    end
    local dir = string.match(name, "^derpy_mr_sw_(%a+)$")
    if dir then return S.click_switch(dir, component) end
    local bdir, mode = string.match(name, "^derpy_mr_all_(%a+)_(%a+)$")
    if bdir then return S.click_bulk(bdir, mode) end
    if name == S.ARMY_BUTTON then
        local row = S.selected_army()
        if row and not row.off then
            S.view = "spending"
            return S.show(true, "army:" .. row.id)
        end
        return
    end
    if name == S.BUTTON then return S.show(not S.is_open()) end
    if name == S.CLOSE then return S.show(false) end
    if name == S.BACK then
        S.focus = nil
        return S.refresh()
    end
    for view, tab in pairs(S.TAB) do
        if name == tab then
            S.view, S.focus, S.map_view = view, nil, nil
            return S.refresh()
        end
    end
    local i = tonumber(string.match(name, "^derpy_mr_row_(%d+)$"))
    local row = i and S.data[i]
    if row and row.open then
        S.focus = row.open
        return S.refresh()
    end
    if row and row.fold then
        if type(row.fold) == "string" then
            S.work_fold[row.fold] = not S.work_fold[row.fold]
        else
            S.folded = not S.folded
        end
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
    local H = DERPY_MR_STORES_L          -- not L: the opener is CA's HUD's size whatever the panel's
    local x, y = bx + bw + H.GAP, by + math.floor((bh - H.BUTTON) / 2)
    local sw, sh = core:get_screen_resolution()
    if x < -H.BUTTON or y < -H.BUTTON or x > sw or y > sh then return nil end
    return math.max(0, math.min(x, sw - H.BUTTON)), math.max(0, math.min(y, sh - H.BUTTON))
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

-- The strip sizes to its content mid-turn, with no event for it, so the button follows. It
-- only MOVES: the hub hides it off the main screen and gives it back, and a re-show here would
-- fight that hide three times a second.
function S.selected_army()
    local cqi, f = S.selected(), S.local_faction()
    if not cqi or not f then return nil end
    local ch = cm:get_character_by_cqi(cqi)
    if not ch or ch:is_null_interface() or ch:faction():name() ~= f:name() or not ch:has_military_force() then return nil end
    local force = ch:military_force()
    if not S.ask("provision_force", f, force) or force:general_character():command_queue_index() ~= cqi then return nil end
    local id = tostring(force:command_queue_index())
    if not (S.ask("rates") or {}).army_provisions then return {id=id,off=true}, force end
    for _, row in ipairs(S.ask("provision_rows", f) or {}) do if row.id == id then return row, force end end
end

-- Wait for the army to stop before refreshing: each new hex can trigger a route search.
-- Keep its last tooltip while moving, but discard it when the selected army changes.
S.supply_poll = {}
function S.supply_sentence(f, id, x, y)
    local p = S.supply_poll
    if p.id == id and p.x == x and p.y == y then
        local note = S.ask("supply_note", f, id)
        p.text = note and S.supply_text(note) or nil
    elseif p.id ~= id then
        p.text = nil
    end
    p.id, p.x, p.y = id, x, y
    return p.text
end

function S.army_button_poll()
    local root = S.root()
    local button = find_uicomponent(root, S.ARMY_BUTTON)
    local row, force
    if not S.is_open() then row, force = S.selected_army() end
    local group = find_uicomponent(root, "button_group_army")
    if not row or not is_uicomponent(group) or not group:Visible(true) then
        if S.supply_poll.id then S.supply_poll = {} end       -- a sentence from before is not shown again
        if is_uicomponent(button) and button:Visible() then
            button:SetVisible(false)
            if is_uicomponent(group) then group:Layout() end
        end
        return
    end
    local changed = not is_uicomponent(button) or not button:Visible()
    if not is_uicomponent(button) then
        local template = find_uicomponent(group, "button_recruitment")
        if not is_uicomponent(template) then return end
        button = UIComponent(template:CopyComponent(S.ARMY_BUTTON))
        button:SetImagePath("ui/skins/default/derpy_mr_provisions.png", 0)
    end
    button:SetVisible(true)
    S.set_off(button,row.off==true)
    -- THE SUPPLY LINE, in the tooltip of its own right: it shows with provisions switched off too (the upkeep is not
    -- theirs)
    local f, gen = S.local_faction(), force:general_character()
    local line = f and S.supply_sentence(f, row.id, gen:logical_position_x(), gen:logical_position_y())
    local tip = row.off and add_line(S.T("Provisions\nArmy provisions are switched off in this campaign."), line)
        or (S.T("Provisions\nThis army eats {1} a turn and carries {2} of {3}.\n{4}{5}\n{6}", row.need, row.held, row.cap, row.reason, (row.short > 0 and (S.T("\nMissed meals: {1}.", row.short)) or ""), (line and (line .. "\n") or "") .. S.ARMY_TIP))
    local count = row.off and "-" or S.num(row.need)
    if button:GetStateText() ~= count then
        local state = button:CurrentState()
        for i = 0, button:NumStates() - 1 do
            button:SetState(button:GetStateByIndex(i))
            button:SetStateText(count)
            button:SetTextHAlign("right");button:SetTextVAlign("bottom")
        end
        button:SetState(state)
    end
    button:SetTooltipText(tip,true)
    if changed then group:Layout() end
end

function S.follow_bar()
    S.army_button_poll()
    -- THE RETRIES CAN RUN OUT under a long opening screen (2026-11-04), so the follow places it too
    if not S.placed then S.place_button(S.PLACE_TRIES) return end
    if S.hubbed() then return end
    local b = find_uicomponent(S.root(), S.BUTTON)
    if not is_uicomponent(b) then return end
    local x, y = S.anchor()
    if not x then return end
    local ax, ay = b:Position()
    if ax ~= x or ay ~= y then b:MoveTo(x, y) end
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
            lines[#lines + 1] = S.T("and {1} more", (#parts - S.PLATE_LINES))
            break
        end
        lines[#lines + 1] = S.name(part.stem) .. " " .. S.num(part.n)
    end
    lines[#lines + 1] = foot
    return table.concat(lines, "\n")
end

function S.plate_tip(pv)
    local foot = S.T("Lost: this army has no settlement")
    if pv.to then foot = S.T("Into {1}", loc("regions_onscreen_" .. pv.to, pv.to)) end
    if (pv.raiders or 1) > 1 then
        foot = foot .. "\n" .. S.T("{1} armies are raiding here.\nEach one takes from what the others leave.", S.num(pv.raiders))
    end
    return tip_lines(S.T("Raiding takes each turn:"), pv.parts, foot)
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
S.CAPTURE_VERB = { sack = S.T("Sacking"), raze = S.T("Razing"), occupy = S.T("Occupying") }

function S.capture_tip(pv, kind)
    if kind == "occupy" then
        return tip_lines(S.T("Occupying keeps its stores:"), pv.parts, S.T("They stay in this settlement"))
    end
    local foot = S.T("Into your nearest settlement")
    if pv.lost then foot = S.T("Lost: you hold no settlement") end
    return tip_lines(S.T("{1} takes:", S.CAPTURE_VERB[kind]), pv.parts, foot)
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

-- OUT OF CORE'S QUEUE ALTOGETHER (Great Guilds player report, 2026-10-09: "click sound,
-- nothing opens", and again after the first fix). Since 9.0 lib_core calls listeners
-- unprotected, and core:event_callback tests EVERY listener's condition before it calls any
-- callback (lib_core.lua 1978-1990): one mod's condition that throws drops the whole click,
-- so index 1 of core.event_listeners was not first enough. This lifts the listener into
-- events.ComponentLClickUp, the engine's own list that core's dispatcher is one entry of -
-- CA's wh2_campaign_traits.lua writes to events.* the same way. Inserted there BEFORE it
-- leaves core's, so a missing events table leaves it where core put it; the wrapper never
-- throws into the engine.
function S.click_first(name)
    pcall(function()
        local list = core.event_listeners.ComponentLClickUp
        for i = #list, 1, -1 do
            local l = list[i]
            if l.name == name then
                table.insert(events.ComponentLClickUp, 1, function(context)
                    pcall(function()
                        if l.condition == true or l.condition(context) then l.callback(context) end
                    end)
                end)
                table.remove(list, i)
                return
            end
        end
    end)
end

function S.init()
    if S.started then return end
    S.started = true
    core:add_listener('derpy_mr_stores_roads', 'DerpyMRTerrainRoutesUpdated',
        function() return S.view == 'map' and S.is_open() end,
        function() local ok, err = pcall(S.refresh); if not ok then S.say(err) end end, true)
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
    S.click_first("derpy_mr_stores_click")
    -- the Workshop's army and character rows follow the map's selection while it is open
    for _, ev in ipairs({ "CharacterSelected", "CharacterDeselected" }) do
        core:add_listener("derpy_mr_stores_" .. ev, ev,
            function() return S.view == "workshop" and S.is_open() end,
            function()
                local done, e = pcall(S.refresh)
                if not done then S.say(e) end
            end, true)
    end
    core:add_listener("derpy_mr_stores_turn", "FactionTurnStart",
        function(context) return context:faction():name() == cm:get_local_faction_name(true) end,
        function()
            local done, e = pcall(S.refresh)
            if not done then S.say(e) end
        end, true)
    -- ENDING THE TURN CLOSES IT (author, 2026-11-01): a UI change, on the ender's own machine only
    core:add_listener("derpy_mr_stores_turn_end", "FactionTurnEnd",
        function(context) return context:faction():name() == cm:get_local_faction_name(true) and S.is_open() end,
        function()
            local done, e = pcall(S.show, false)
            if not done then S.say(e) end
        end, true)
end

cm:add_first_tick_callback(function() S.init() end)

-- THE HUB'S REGISTRATION: a plain table, so load order against the hub copies does not matter.
DERPY_HUB_QUEUE = DERPY_HUB_QUEUE or {}
table.insert(DERPY_HUB_QUEUE, {
    key = S.HUB_KEY, button = S.BUTTON, order = 4,
    label = function() return S.T("Resource Vault") end,
    live = function() return true end,
})
