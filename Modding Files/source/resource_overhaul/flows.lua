-- Derpy Resource Overhaul: stores flows. Raids, sacks and razes carry stock out of a settlement's
-- stores into the taker's; trade agreements carry it between partners; a ledger and a 20-turn
-- history feed the Stores panel's chart.
-- Spec: docs/superpowers/specs/2026-10-02-resource-overhaul-stores-flows-design.md
--
-- THE SHIPPED FILE IS GENERATED. tools/gen_mr_ui.py puts DERPY_MR_FLOWS_DEFAULTS (the rates),
-- DERPY_MR_FLOWS_KIND (the factor each move books to) and DERPY_MR_FLOWS_GOODS (the 54 goods) in
-- front of this source. Edit this file, then run py tools/gen_mr_ui.py.
--
-- MULTIPLAYER: every change here happens inside a model event (turn start, occupation decision),
-- none from a click, so every machine runs the same moves.

DERPY_MR_FLOWS = DERPY_MR_FLOWS or {}
local F = DERPY_MR_FLOWS
local KIND = DERPY_MR_FLOWS_KIND

F.PREFIX = "derpy_mr_store_"
F.MCT = "derpy_more_resources"
F.RAIDING = "MILITARY_FORCE_ACTIVE_STANCE_TYPE_LAND_RAID"   -- CA's own test, wh2_twa03_rakarth.lua
F.DECISION = { occupation_decision_sack = "sack", occupation_decision_raze_without_occupy = "raze" }
F.state = F.state or { factions = {} }
F.cost = { raid = 0, turn = 0 }       -- seconds this round, for the in-game measurement only
F.SAVE = "derpy_mr_flows"
F.HISTORY = 20
-- WHICH PARTNERS LACK A GOOD (Task 1's measurement): "exists" asks the engine's
-- trade_resource_exists, "capital" asks whether the partner's capital store holds none.
F.LACK_TEST = "capital"

function F.say(msg)
    pcall(out, "[derpy_mr_flows] " .. tostring(msg))
end

function F.share(held, pct)
    return math.floor(held * pct / 100)
end

function F.pool(region, stem)
    local ok, p = pcall(function()
        return region:pooled_resource_manager():resource(F.PREFIX .. stem)
    end)
    if ok and p and not p:is_null_interface() then return p end
    return nil
end

function F.held(region, stem)
    local p = F.pool(region, stem)
    if not p then return 0 end
    return p:value()
end

function F.free(region, stem)
    local p = F.pool(region, stem)
    if not p then return 0 end
    return math.max(0, p:maximum_value() - p:value())
end

-- ---- rates --------------------------------------------------------------------------------
-- FROZEN INTO THE SAVE the first time they are read, which is the first turn start. MCT's own
-- campaign gating is dead code (the Zharr Exchange's finding), so the save is the lock.
function F.mct(key)
    if not get_mct then return nil end
    local ok, v = pcall(function()
        local m = get_mct():get_mod_by_key(F.MCT)
        if not m then return nil end
        local o = m:get_option_by_key(key)
        if not o then return nil end
        return o:get_finalized_setting()
    end)
    if ok then return v end
    return nil
end

-- MULTIPLAYER TAKES THE DEFAULTS: two machines' MCT settings can differ and a move must not.
function F.read_rates()
    local mp = false
    pcall(function() mp = cm:is_multiplayer() end)
    local r = {}
    for k, d in pairs(DERPY_MR_FLOWS_DEFAULTS) do
        local v = nil
        if not mp then v = F.mct(k) end   -- NOT `not mp and F.mct(k) or nil`: an unticked box is false
        if type(v) ~= type(d) then v = d end
        if type(v) == "number" then v = math.floor(v + 0.5) end
        r[k] = v
    end
    return r
end

function F.rates()
    if not F.state.rates then F.state.rates = F.read_rates() end
    return F.state.rates
end

function F.is_human(fkey)
    if not fkey or fkey == "" then return false end
    local ok, h = pcall(function() return cm:get_faction(fkey):is_human() end)
    return ok and h == true
end

-- With "goods move between other factions" off, a move runs only with a player on one side.
function F.allowed(a, b)
    if F.rates().ai then return true end
    return F.is_human(a) or F.is_human(b)
end

-- ---- the ledger: human factions only, since only they see the panel ------------------------
function F.book(fkey)
    local b = F.state.factions[fkey]
    if not b then
        b = { turns = {}, total = {}, last = {}, now = {} }
        F.state.factions[fkey] = b
    end
    return b
end

function F.log(fkey, stem, field, n)
    if n <= 0 or not F.is_human(fkey) then return end
    local now = F.book(fkey).now
    now[stem] = now[stem] or {}
    now[stem][field] = (now[stem][field] or 0) + n
end

-- ---- moving stock ---------------------------------------------------------------------------
-- TWO TRANSACTIONS, NOT entity_transfer_pooled_resource: the receiver's share is clamped to its
-- free space here, so what does not fit is lost by rule (spec section 2) rather than by whatever
-- the engine does at the brim. The junction is two-way (gen_resource_overhaul.py FLOW_FACTORS),
-- so one id books both ends. `to` nil (a taker with no settlements) destroys the stock.
function F.move(from, to, stem, n, kind, from_key, to_key)
    n = math.min(n, F.held(from, stem))
    if n <= 0 then return 0 end
    local j = F.PREFIX .. stem .. "_" .. kind
    cm:entity_add_pooled_resource_transaction(from, j, -n)
    local got = 0
    if to then
        got = math.min(n, F.free(to, stem))
        if got > 0 then cm:entity_add_pooled_resource_transaction(to, j, got) end
    end
    F.log(from_key, stem, kind .. "_out", n)
    F.log(to_key, stem, kind .. "_in", got)
    return got
end

-- The faction's settlement nearest (x, y); nil when it holds none.
function F.nearest(faction, x, y)
    local best, bd = nil, nil
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        local st = r:settlement()
        if not st:is_null_interface() then
            local dx, dy = st:logical_position_x() - x, st:logical_position_y() - y
            local d = dx * dx + dy * dy
            if bd == nil or d < bd then best, bd = r, d end
        end
    end
    return best
end

-- Every good in `region` with stock: pct of it to the taker's settlement nearest (x, y), the
-- taking army's position (plan deviation 3: the settlement may already be null at a raze).
function F.take(region, victim_key, taker, pct, kind, x, y)
    if pct <= 0 then return 0 end
    local to = F.nearest(taker, x, y)
    local taken = 0
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        local n = F.share(F.held(region, g.stem), pct)
        if n > 0 then
            F.move(region, to, g.stem, n, kind, victim_key, taker:name())
            taken = taken + n
        end
    end
    return taken
end

-- The owner stock may be taken from, or nil: no region, no owner, a rebel, or the taker itself.
function F.victim(region, taker)
    if not region or region:is_null_interface() or region:is_abandoned() then return nil end
    local v = region:owning_faction()
    if v:is_null_interface() or v:is_rebel() or v:name() == taker:name() then return nil end
    return v
end

function F.on_character_turn_start(character)
    if not character:has_military_force() then return end
    if character:military_force():active_stance() ~= F.RAIDING then return end
    local taker = character:faction()
    local region = character:region()
    local v = F.victim(region, taker)
    if not v or not taker:at_war_with(v) then return end
    if not F.allowed(taker:name(), v:name()) then return end
    F.take(region, v:name(), taker, F.rates().raid, KIND.raid,
           character:logical_position_x(), character:logical_position_y())
end

function F.on_occupation(context)
    local what = F.DECISION[context:occupation_decision_type()]
    if not what then return end
    local character = context:character()
    local taker = character:faction()
    local victim = context:previous_owner()        -- empty for rebels
    if victim == nil or victim == "" or victim == taker:name() then return end
    if not F.allowed(taker:name(), victim) then return end
    local region = context:garrison_residence():region()
    if not F.pool(region, DERPY_MR_FLOWS_GOODS[1].stem) then
        F.say("the stores of " .. region:name() .. " could not be read at the " .. what
              .. " - nothing taken")
        return
    end
    F.take(region, victim, taker, F.rates()[what], KIND[what],
           character:logical_position_x(), character:logical_position_y())
end

-- ---- trade --------------------------------------------------------------------------------
function F.capital(faction)
    if faction:has_home_region() then return faction:home_region() end
    local rl = faction:region_list()
    if rl:num_items() > 0 then return rl:item_at(0) end
    return nil
end

-- One pass over the exporter's settlements finds every good's fullest store, so the cost does
-- not grow with the number of partners.
function F.fullest(faction)
    local best = {}
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
            local h = F.held(r, g.stem)
            if h > 0 and (not best[g.stem] or h > best[g.stem].held) then
                best[g.stem] = { region = r, held = h }
            end
        end
    end
    return best
end

function F.lacks(partner, g)
    if F.LACK_TEST == "exists" then return not partner:trade_resource_exists(g.res) end
    local cap = F.capital(partner)
    return cap ~= nil and F.held(cap, g.stem) == 0
end

-- Each faction sends its own exports at its own turn start, so each direction of an agreement
-- runs once a round. A partner with no settlements gets nothing and nothing leaves.
function F.trade(exporter)
    local pct = F.rates().trade
    if pct <= 0 then return end
    local partners = exporter:factions_trading_with()
    local best = nil
    for i = 0, partners:num_items() - 1 do
        local partner = partners:item_at(i)
        local to = F.capital(partner)
        if to and F.allowed(exporter:name(), partner:name()) then
            best = best or F.fullest(exporter)
            for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
                local b = best[g.stem]
                if b and F.lacks(partner, g) then
                    -- ONLY WHAT FITS LEAVES: trade never destroys stock (spec section 3)
                    local n = math.min(F.share(b.held, pct), F.free(to, g.stem))
                    if n > 0 then
                        F.move(b.region, to, g.stem, n, KIND.trade, exporter:name(), partner:name())
                        b.held = b.held - n
                    end
                end
            end
        end
    end
end

-- ---- history ------------------------------------------------------------------------------
-- WHOLE NUMBERS ONLY: a fraction crosses CA's table save as "1,1" under a decimal-comma locale.
function F.push(b, turn, totals, made)
    b.turns[#b.turns + 1] = turn
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        local t = b.total[g.stem] or {}
        b.total[g.stem] = t
        while #t < #b.turns - 1 do t[#t + 1] = 0 end      -- a good added by an update lines up
        t[#t + 1] = math.floor((totals[g.stem] or 0) + 0.5)
    end
    while #b.turns > F.HISTORY do
        table.remove(b.turns, 1)
        for _, t in pairs(b.total) do table.remove(t, 1) end
    end
    b.last = b.now
    for stem, m in pairs(made) do
        b.last[stem] = b.last[stem] or {}
        b.last[stem].made = math.floor(m + 0.5)
    end
    b.now = {}
end

-- At a human faction's turn start, after the engine has filled the stores.
function F.snapshot(faction)
    local S = DERPY_MR_STORES
    if not (S and S.read_realm) then return end
    local totals, made = {}, {}
    for _, s in ipairs(S.read_realm(faction)) do
        for stem, v in pairs(s.held) do totals[stem] = (totals[stem] or 0) + v end
        for stem, v in pairs(s.made) do made[stem] = (made[stem] or 0) + v end
    end
    F.push(F.book(faction:name()), cm:model():turn_number(), totals, made)
end

function F.series(fkey, stem)
    local b = F.state.factions and F.state.factions[fkey]
    if not b then return {}, {} end
    return b.turns, b.total[stem] or {}
end

function F.last(fkey, stem)
    local b = F.state.factions and F.state.factions[fkey]
    return (b and b.last[stem]) or {}
end

function F.on_faction_turn_start(faction)
    F.rates()                                     -- frozen at the first turn start
    if faction:is_human() then
        -- ITS OWN GUARD: the snapshot reads through the UI-side CCO and loc, and a throw there must
        -- not skip the trade below, which is model state every machine has to run alike
        F.guard(F.snapshot, faction)
        F.round_cost, F.cost = F.cost, { raid = 0, turn = 0 }
    end
    F.trade(faction)
end

function F.guard(fn, a, slot)
    local t0 = os.clock()
    local ok, e = pcall(fn, a)
    if slot then F.cost[slot] = (F.cost[slot] or 0) + os.clock() - t0 end
    if not ok then F.say(e) end
end

function F.init()
    if F.started then return end
    F.started = true
    core:add_listener("derpy_mr_flows_raid", "CharacterTurnStart", true,
        function(context) F.guard(F.on_character_turn_start, context:character(), "raid") end, true)
    core:add_listener("derpy_mr_flows_occupation", "CharacterPerformsSettlementOccupationDecision", true,
        function(context) F.guard(F.on_occupation, context) end, true)
    core:add_listener("derpy_mr_flows_turn", "FactionTurnStart", true,
        function(context) F.guard(F.on_faction_turn_start, context:faction(), "turn") end, true)
end

cm:add_first_tick_callback(function() F.init() end)

-- FIRST IN CA'S LISTS, NOT APPENDED: cm:saving_game and cm:loading_game call every mod's
-- callback in one unprotected loop, so a mod that throws ahead of this one would stop it and the
-- save would go out without the history (the Zharr Exchange's 2026-10-02 lesson).
local function first(kind, fn)
    local list = cm[kind .. "_game_callbacks"]
    if type(list) == "table" then
        table.insert(list, 1, fn)
    elseif kind == "saving" then
        cm:add_saving_game_callback(fn)
    else
        cm:add_loading_game_callback(fn)
    end
end

first("loading", function(context)
    local ok, t = pcall(function() return cm:load_named_value(F.SAVE, {}, context) end)
    if ok and type(t) == "table" then
        F.state = t
    else
        F.state = {}
        F.say("could not load the stores history: " .. tostring(t))
    end
    F.state.factions = F.state.factions or {}
end)

first("saving", function(context)
    local ok, e = pcall(function() cm:save_named_value(F.SAVE, F.state, context) end)
    if not ok then F.say("could not save the stores history: " .. tostring(e)) end
end)
