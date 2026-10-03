-- Derpy Resource Overhaul: stores flows. Raids, sacks and razes carry stock out of a settlement's
-- stores into the taker's; trade agreements carry it between partners; a ledger and a 20-turn
-- history feed the Stores panel's chart.
-- Spec: docs/superpowers/specs/2026-10-02-resource-overhaul-stores-flows-design.md
--
-- THE SHIPPED FILE IS GENERATED. tools/gen_mr_ui.py puts DERPY_MR_FLOWS_DEFAULTS (the rates),
-- DERPY_MR_FLOWS_KIND (the factor each move books to) and DERPY_MR_FLOWS_GOODS (the 54 goods) in
-- front of this source. Edit this file, then run py tools/gen_mr_ui.py.
--
-- MULTIPLAYER: every change here happens inside a model event (turn start, occupation decision,
-- an army walking into a shipment's marker) or comes from a click through F.request, a UITrigger
-- every machine runs alike.

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

-- AT LEAST 1 WHEN ANY IS HELD: floored alone, a store under 100/pct never loses anything.
function F.share(held, pct)
    if held <= 0 or pct <= 0 then return 0 end
    return math.max(1, math.floor(held * pct / 100))
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

-- A SAVE FROM BEFORE A SWITCH EXISTED has no key for it, and nil read as "off": phases 4 and 7
-- never ran in such a save (measured live 2026-10-02). A missing key takes its value now and
-- is frozen with the rest; the keys already frozen do not move.
function F.rates()
    local r = F.state.rates
    if not r then
        r = F.read_rates()
        F.state.rates = r
    end
    for k in pairs(DERPY_MR_FLOWS_DEFAULTS) do
        if r[k] == nil then
            local fresh = F.read_rates()
            for k2, v in pairs(fresh) do
                if r[k2] == nil then r[k2] = v end
            end
            break
        end
    end
    return r
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
-- `from` nil is a source whose pools are already gone (a raze): nothing to book against it.
function F.move(from, to, stem, n, kind, from_key, to_key)
    if from then n = math.min(n, F.held(from, stem)) end
    if n <= 0 then return 0 end
    local j = F.PREFIX .. stem .. "_" .. kind
    if from then cm:entity_add_pooled_resource_transaction(from, j, -n) end
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
-- `held` (stem -> n) is the battle's reading when the region's pools are gone.
function F.take(region, victim_key, taker, pct, kind, x, y, held)
    if pct <= 0 then return 0 end
    local to = F.nearest(taker, x, y)
    local from = not held and region or nil
    local taken = 0
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        local n = F.share(held and held[g.stem] or F.held(region, g.stem), pct)
        if n > 0 then
            F.move(from, to, g.stem, n, kind, victim_key, taker:name())
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

-- The raid this character makes: region, victim, taker; nil when it takes from nobody.
function F.raid_target(character)
    if not character:has_military_force() then return nil end
    if character:military_force():active_stance() ~= F.RAIDING then return nil end
    local taker = character:faction()
    local region = character:region()
    local v = F.victim(region, taker)
    if not v then return nil end      -- NO WAR TEST: CA pays raid gold from any owner's land
    if not F.allowed(taker:name(), v:name()) then return nil end
    return region, v, taker
end

function F.on_character_turn_start(character)
    local region, v, taker = F.raid_target(character)
    if not region then return end
    F.take(region, v:name(), taker, F.rates().raid, KIND.raid,
           character:logical_position_x(), character:logical_position_y())
end

-- WHAT F.take WOULD TAKE from `region` at `pct`: {total, parts = {{stem, n}}}, most first, or nil
-- when nothing. Read only - the plates' number, by the same F.share the move uses.
function F.preview(region, pct)
    local parts, total = {}, 0
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        local n = F.share(F.held(region, g.stem), pct)
        if n > 0 then
            parts[#parts + 1] = { stem = g.stem, n = n }
            total = total + n
        end
    end
    if total == 0 then return nil end
    table.sort(parts, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.stem < b.stem
    end)
    return { total = total, parts = parts }
end

-- WHAT THE RAID TAKES NEXT TURN, for the army's plate: F.preview plus `to`, the region key it
-- lands in (nil for a horde). Nothing before the rates are frozen: a UI read must not freeze
-- them on one machine ahead of the turn start that does it everywhere.
function F.raid_preview(character)
    local rates = F.state.rates
    if not rates or (rates.raid or 0) <= 0 then return nil end
    local region, _, taker = F.raid_target(character)
    if not region then return nil end
    local pv = F.preview(region, rates.raid)
    if not pv then return nil end
    local to = F.nearest(taker, character:logical_position_x(), character:logical_position_y())
    pv.to = to and to:name() or nil
    return pv
end

-- WHAT A CAPTURE CHOICE DOES TO `region`'s STORES, for the capture panel: F.preview plus `lost`,
-- true when the taker holds no settlement to carry it to. "sack" and "raze" take their share
-- (nil for the cases F.on_occupation skips: rebels, its own settlement); "occupy" keeps the
-- whole store, which stays with the settlement, rebels' included. nil for any other kind.
function F.capture_preview(region, taker, kind)
    local rates = F.state.rates
    if not rates then return nil end
    local pct
    if kind == "occupy" then
        if region:is_abandoned() or region:owning_faction():name() == taker:name() then return nil end
        local pv = F.preview(region, 100)
        if pv then pv.lost = false end
        return pv
    elseif kind == "sack" or kind == "raze" then
        pct = rates[kind] or 0
    end
    if not pct or pct <= 0 then return nil end
    if not F.victim(region, taker) then return nil end
    local pv = F.preview(region, pct)
    if pv then pv.lost = taker:region_list():num_items() == 0 end
    return pv
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
    local at_battle = F.at_battle[region:name()]
    F.at_battle[region:name()] = nil
    if F.pool(region, DERPY_MR_FLOWS_GOODS[1].stem) then
        at_battle = nil                            -- live stores win over the battle's reading
    elseif not at_battle then
        F.say("the stores of " .. region:name() .. " could not be read at the " .. what
              .. " - nothing taken")
        return
    end
    F.take(region, victim, taker, F.rates()[what], KIND[what],
           character:logical_position_x(), character:logical_position_y(), at_battle)
end

-- THE STORES AS THEY WERE AT THE BATTLE: the engine drops a razed region's pools before the
-- occupation decision fires (measured 2026-10-02, Venom Glade). CA's Bloodgrounds caches the
-- settlement the same way, on the same event. Not saved: the decision follows in the same session.
F.at_battle = {}
function F.on_battle(context)
    local pb = context:pending_battle()
    if not pb:has_contested_garrison() then return end
    local region = pb:contested_garrison():region()
    local t = {}
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        local h = F.held(region, g.stem)
        if h > 0 then t[g.stem] = h end
    end
    F.at_battle[region:name()] = t
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
    if type(partners) == "boolean" then return end   -- measured 2026-10-02 for some faction
    local best = nil
    for i = 0, partners:num_items() - 1 do
        local partner = partners:item_at(i)
        local to = F.capital(partner)
        if to and F.allowed(exporter:name(), partner:name()) then
            best = best or F.fullest(exporter)
            for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
                local b = best[g.stem]
                if b and not F.stopped(exporter:name(), "export", g.stem)
                        and not F.stopped(partner:name(), "import", g.stem) and F.lacks(partner, g) then
                    -- ONLY WHAT FITS LEAVES: trade never destroys stock (spec section 3).
                    -- SURPLUS ONLY, NOT F.share's at-least-1: with it a raided single unit left
                    -- the same turn (measured 2026-10-02) and singles bounced between partners.
                    local n = math.min(math.floor(b.held * pct / 100), F.free(to, g.stem))
                    if n > 0 then
                        F.move(b.region, to, g.stem, n, KIND.trade, exporter:name(), partner:name())
                        b.held = b.held - n
                    end
                end
            end
        end
    end
end

-- ---- the player's trade switches (the Stores panel's Trade tab) ---------------------------
-- Saved in the faction's book as stop[dir][stem] = true; everything allowed by default.
-- Humans only: a computer-run faction has no panel to set them from.
F.DIRS = { export = true, import = true }
F.TAG = "dmr1"
-- in place of a resource's key: every resource one way at once (the panel's four buttons)
F.ALL_STOP, F.ALL_ALLOW = "all_stop", "all_allow"

function F.stopped(fkey, dir, stem)
    local b = F.state.factions[fkey]
    return b ~= nil and b.stop ~= nil and b.stop[dir] ~= nil and b.stop[dir][stem] == true
end

function F.toggle(fkey, dir, stem)
    if not F.DIRS[dir] or not F.is_human(fkey) then return end
    local known = false
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        if g.stem == stem then known = true end
    end
    if not known then return end
    local b = F.book(fkey)
    b.stop = b.stop or {}
    b.stop[dir] = b.stop[dir] or {}
    if F.stopped(fkey, dir, stem) then b.stop[dir][stem] = nil else b.stop[dir][stem] = true end
end

-- `what` is a resource's key (toggle it) or ALL_STOP / ALL_ALLOW (set every one, not a toggle)
function F.apply(fkey, dir, what)
    if what ~= F.ALL_STOP and what ~= F.ALL_ALLOW then return F.toggle(fkey, dir, what) end
    if not F.DIRS[dir] or not F.is_human(fkey) then return end
    local b = F.book(fkey)
    b.stop = b.stop or {}
    b.stop[dir] = {}
    if what == F.ALL_STOP then
        for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do b.stop[dir][g.stem] = true end
    end
end

-- A trade switch: one resource's key, or ALL_STOP / ALL_ALLOW (F.request, below).
function F.send(fkey, dir, stem) return F.request(fkey, dir, stem) end

function F.on_ui_trigger(context)
    local parts = F.parse(context:trigger())
    if not parts then return end
    local cqi = context:faction_cqi()
    for _, k in ipairs(cm:get_human_factions()) do
        local f = cm:get_faction(k)
        if f and not f:is_null_interface() and f:command_queue_index() == cqi then
            F.dispatch(k, parts)
            local S = DERPY_MR_STORES
            if S and S.refresh then pcall(S.refresh) end
            return
        end
    end
end

-- ---- using the stores (spending spec section 2, phase 4) ----------------------------------
-- Every settlement eats provisions at its owner's turn start, and well-stocked stores give a
-- region bundle each: Well fed, Garrison stocked, Comforts (gen_resource_overhaul.USE_BUNDLES).
F.NEED = 2               -- provisions a turn per settlement level
F.FED_TURNS = 5          -- Well fed: this many turns' need still held after eating
F.STOCKED_PCT = 25       -- Garrison stocked and Comforts: this share of one store's space
-- RENEWED EACH TURN, REMOVED THE TURN ITS CONDITION FAILS: 2, not 1, so a bundle cannot lapse
-- before growth is counted, and one the pass no longer reaches (the mod removed) still lapses.
F.BUNDLE_TURNS = 2

-- Daemons, the undead and Beastmen: their buildings make nothing, so they keep nothing to use.
function F.uses_stores(faction)
    local sc = faction:subculture()
    for _, t in ipairs(DERPY_MR_FLOWS_NO_STORES) do
        -- no plain flag: it corrupts the game's string library; the tokens are letters only
        if string.find(sc, "_" .. t .. "_") then return false end
    end
    return true
end

-- One read of a settlement's stores: {stem = held}, and one store's space.
function F.stock(region)
    local held, cap = {}, 0
    local list = region:pooled_resource_manager():resources()
    for i = 0, list:num_items() - 1 do
        local p = list:item_at(i)
        if not p:is_null_interface() then
            local k = p:key()
            if string.sub(k, 1, #F.PREFIX) == F.PREFIX then
                held[string.sub(k, #F.PREFIX + 1)] = p:value()
                if p:maximum_value() > cap then cap = p:maximum_value() end
            end
        end
    end
    return held, cap
end

function F.use_total(held, use)
    local n = 0
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        if g.use == use then n = n + (held[g.stem] or 0) end
    end
    return n
end

-- THE DRAWING RULE (spec section 1): take n from the stores `pick(good)` names, the fullest
-- store first, then the next, until n is taken or they are empty. stocks = {{region, held}};
-- each `held` is updated as it goes. A tie goes by region key, then by resource key, so every
-- machine takes alike. Returns what was taken.
function F.draw_realm(stocks, pick, n, kind, fkey)
    local cands = {}
    for _, s in ipairs(stocks) do
        local rk = s.region:name()
        for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
            if pick(g) and (s.held[g.stem] or 0) > 0 then cands[#cands + 1] = { s = s, stem = g.stem, rk = rk } end
        end
    end
    table.sort(cands, function(a, b)
        local ha, hb = a.s.held[a.stem], b.s.held[b.stem]
        if ha ~= hb then return ha > hb end
        if a.rk ~= b.rk then return a.rk < b.rk end
        return a.stem < b.stem
    end)
    local taken = 0
    for _, c in ipairs(cands) do
        if taken >= n then break end
        local k = math.min(n - taken, c.s.held[c.stem])
        F.move(c.s.region, nil, c.stem, k, kind, fkey, nil)
        c.s.held[c.stem] = c.s.held[c.stem] - k
        taken = taken + k
    end
    return taken
end

-- One settlement's stores of one use.
function F.draw(region, held, use, n, kind, fkey)
    return F.draw_realm({ { region = region, held = held } }, function(g) return g.use == use end, n, kind, fkey)
end

function F.bundle(rkey, region, use, on)
    local b = DERPY_MR_FLOWS_BUNDLES[use]
    if on then
        cm:apply_effect_bundle_to_region(b, rkey, F.BUNDLE_TURNS)
    elseif region:has_effect_bundle(b) then
        cm:remove_effect_bundle_from_region(b, rkey)
    end
end

function F.upkeep_region(region, fkey, uses)
    local fed, war, lux = false, false, false
    if uses then
        local held, cap = F.stock(region)
        local level = 0
        pcall(function() level = region:settlement():primary_slot():building():building_level() end)
        local need = F.NEED * level
        if need > 0 then
            F.draw(region, held, "provisions", need, KIND.eat, fkey)
            fed = F.use_total(held, "provisions") >= F.FED_TURNS * need
        end
        local quarter = cap * F.STOCKED_PCT / 100
        war = cap > 0 and F.use_total(held, "war") >= quarter
        lux = cap > 0 and F.use_total(held, "luxuries") >= quarter
    end
    local rkey = region:name()
    F.bundle(rkey, region, "provisions", fed)
    F.bundle(rkey, region, "war", war)
    F.bundle(rkey, region, "luxuries", lux)
end

function F.upkeep(faction)
    local r = F.rates()
    if not r.upkeep or not (r.ai or faction:is_human()) then return end
    local fkey, uses = faction:name(), F.uses_stores(faction)
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local region = rl:item_at(i)
        if not region:is_null_interface() then F.upkeep_region(region, fkey, uses) end
    end
end

-- ---- the Stores panel's actions (spending spec section 5, phase 7) -------------------------
-- Player only, and only through F.request: in multiplayer every action is a UITrigger.
F.GOOD = {}
for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do F.GOOD[g.stem] = g end
F.SEND_LOSS_PCT = 10
F.ORDER_COST, F.ORDER_TURNS, F.ORDER_COOLDOWN = DERPY_MR_FLOWS_ORDER[1], DERPY_MR_FLOWS_ORDER[2], DERPY_MR_FLOWS_ORDER[3]

function F.stocks(faction)
    local out = {}
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        if not r:is_null_interface() then out[#out + 1] = { region = r, held = (F.stock(r)) } end
    end
    return out
end

function F.owned(faction, rkey)
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        if not r:is_null_interface() and r:name() == rkey then return r end
    end
    return nil
end

function F.lost(n) return math.ceil(n * F.SEND_LOSS_PCT / 100) end

-- SEND HERE: the fullest OTHER store of the resource sends the most whose arrival, after the
-- loss on the road, still fits here beside what is already on the road to it. nil when nothing
-- would arrive; busy = true when the faction has its full number of shipments on the road.
function F.send_plan(faction, rkey, stem)
    if not F.GOOD[stem] then return nil end
    local to = F.owned(faction, rkey)
    if not to then return nil end
    local free = F.free(to, stem) - F.incoming(faction:name(), rkey, stem)
    if free <= 0 then return nil end
    local from, fh, fk = nil, 0, nil
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        local k = r:name()
        if not r:is_null_interface() and k ~= rkey then
            local h = F.held(r, stem)
            if h > fh or (h == fh and h > 0 and k < fk) then from, fh, fk = r, h, k end
        end
    end
    if not from then return nil end
    -- an upper bound on what can fit, walked down: arrival is n less a tenth rounded up
    local n = math.min(fh, free + math.ceil(free / 9) + 2)
    while n > 0 and n - F.lost(n) > free do n = n - 1 end
    local got = n - F.lost(n)
    if got <= 0 then return nil end
    return { from = from, to = to, n = n, got = got,
             busy = F.ship_count(faction:name()) >= F.ship_cap(faction) or nil }
end

-- A SHIPMENT, since phase 5: it leaves now and arrives in two turns, if nobody seizes it.
function F.send_here(faction, stem, rkey)
    local p = F.send_plan(faction, rkey, stem)
    if not p then return end
    F.ship(faction, p.from, p.to, stem, p.n)       -- F.ship refuses past the number on the road
end

-- ORDERS: a faction bundle bought with ORDER_COST of one use, drawn realm-wide; then a wait,
-- kept in the faction's book (and so in the save) as the turn it was bought.
function F.order_state(faction, key)
    local o = DERPY_MR_FLOWS_ORDERS[key]
    if not o then return nil end
    local have = 0
    for _, s in ipairs(F.stocks(faction)) do have = have + F.use_total(s.held, o.use) end
    local st = { have = have, cost = F.ORDER_COST, use = o.use }
    local b = F.state.factions[faction:name()]
    local last = b and b.orders and b.orders[key]
    local turn = cm:model():turn_number()
    if last and turn - last < F.ORDER_COOLDOWN then st.wait = last + F.ORDER_COOLDOWN - turn end
    st.ok = st.wait == nil and have >= F.ORDER_COST
    return st
end

function F.order(faction, key)
    local st = F.order_state(faction, key)
    if not (st and st.ok) then return end
    local o, fkey = DERPY_MR_FLOWS_ORDERS[key], faction:name()
    F.draw_realm(F.stocks(faction), function(g) return g.use == o.use end, F.ORDER_COST, KIND.spend, fkey)
    cm:apply_effect_bundle(o.bundle, fkey, F.ORDER_TURNS)
    local b = F.book(fkey)
    b.orders = b.orders or {}
    b.orders[key] = cm:model():turn_number()
end

-- SELL: the Zharr Exchange's price a unit when it is loaded and answers, the fixed rate of the
-- resource's use otherwise. The surplus is what the realm holds above half its space for it.
function F.price(g)
    if type(EX) == "table" and type(EX.sell_price) == "function" then
        local ok, p = pcall(EX.sell_price, g.res)
        if ok and type(p) == "number" and p > 0 then return p end
    end
    return DERPY_MR_FLOWS_SELL_RATE[g.use] or 0
end

function F.sale(faction, stem)
    local g = F.GOOD[stem]
    if not g then return nil end
    local total, space = 0, 0
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local p = F.pool(rl:item_at(i), stem)
        if p then total, space = total + p:value(), space + p:maximum_value() end
    end
    local n = total - math.floor(space / 2)
    if n <= 0 then return nil end
    local price = F.price(g)
    local gold = math.floor(n * price)
    if gold <= 0 then return nil end
    return { n = n, price = price, gold = gold }
end

function F.sell(faction, stem)
    local s = F.sale(faction, stem)
    if not s then return end
    local fkey = faction:name()
    F.draw_realm(F.stocks(faction), function(g) return g.stem == stem end, s.n, KIND.sell, fkey)
    cm:treasury_mod(fkey, s.gold)
end

-- THE ONE DOOR. parts = {action, args...}: a trade switch (export|import, stem), or an action
-- with exactly its own count of parts. Humans only; the actions only with the MCT switch on.
F.ACTIONS = { send = 3, order = 2, sell = 2, supply = 3 }
function F.dispatch(fkey, parts)
    if not F.is_human(fkey) then return end
    local a = parts[1]
    if F.DIRS[a] then
        if #parts == 2 then F.apply(fkey, a, parts[2]) end
        return
    end
    if F.ACTIONS[a] ~= #parts then return end
    if not F.rates()[a == "supply" and "supply" or "actions"] then return end
    local f = cm:get_faction(fkey)
    if a == "send" then F.send_here(f, parts[2], parts[3])
    elseif a == "supply" then F.toggle_supply(f, parts[2], parts[3])
    elseif a == "order" then F.order(f, parts[2])
    else F.sell(f, parts[2]) end
end

-- A CLICK NEVER WRITES THE MODEL ITSELF IN MULTIPLAYER: it goes out as a UITrigger, which CA
-- delivers to every machine in one order, and the listener runs it everywhere at once.
function F.request(fkey, ...)
    local parts = { ... }
    local mp = false
    pcall(function() mp = cm:is_multiplayer() end)
    if not mp then return F.dispatch(fkey, parts) end
    local f = cm:get_faction(fkey)
    if not f or f:is_null_interface() then return end
    CampaignUI.TriggerCampaignScriptEvent(f:command_queue_index(), F.TAG .. "|" .. table.concat(parts, "|"))
end

-- "dmr1|a|b|c" -> {a, b, c}; nil for another mod's id or a part that is not [%w_]+.
function F.parse(id)
    if type(id) ~= "string" or string.sub(id, 1, #F.TAG + 1) ~= F.TAG .. "|" then return nil end
    local parts = {}
    for p in string.gmatch(string.sub(id, #F.TAG + 2), "[^|]+") do
        if not string.match(p, "^[%w_]+$") then return nil end
        parts[#parts + 1] = p
    end
    return parts
end

-- ---- store events (spending spec section 4, phase 6) --------------------------------------
-- A full store offers a choice at its owner's turn start. A player gets the event's DB dilemma
-- (FIRST spends and rewards, SECOND declines) and the spend happens here when it is answered: a
-- dilemma payload cannot charge a REGION pool. A computer-run faction takes the same deal on a
-- roll. At most one event per faction every EVENT_GAP turns, counted from the offer.
F.EVENT_GAP, F.EVENT_AI_PCT = DERPY_MR_FLOWS_EVENT[1], DERPY_MR_FLOWS_EVENT[2]
F.EVENT_ORDER = { "siege", "feast", "arsenal", "tribute" }   -- a siege cannot wait; the rest take turns
F.DIPLO_BONUS = 3                                            -- CA's change type, -6..+6
F.EVENT_BY_DILEMMA = {}
for k, e in pairs(DERPY_MR_FLOWS_EVENTS) do F.EVENT_BY_DILEMMA[e.dilemma] = k end

-- The settlement holding the most of a use, at least `cost`; ties by key. `siege`: only a
-- settlement under siege counts.
function F.event_region(stocks, use, cost, siege)
    local best, bh = nil, nil
    for _, s in ipairs(stocks) do
        local h = F.use_total(s.held, use)
        if h >= cost and (not siege or s.region:garrison_residence():is_under_siege())
                and (bh == nil or h > bh or (h == bh and s.region:name() < best:name())) then
            best, bh = s.region, h
        end
    end
    return best
end

-- A neighbour at peace: the owner of a region next to one of ours, not us, not rebels, not at
-- war with us. The first by key, so every machine names the same one.
function F.event_neighbour(faction)
    local best = nil
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local adj = rl:item_at(i):adjacent_region_list()
        for j = 0, adj:num_items() - 1 do
            local o = adj:item_at(j):owning_faction()
            if not o:is_null_interface() and o:name() ~= faction:name() and not o:is_rebel()
                    and not faction:at_war_with(o) and (best == nil or o:name() < best:name()) then
                best = o
            end
        end
    end
    return best
end

-- The largest army in the field: never a garrison or a convoy; ties by the general's cqi.
function F.event_army(faction)
    local best, bn, bc = nil, nil, nil
    local list = faction:military_force_list()
    for i = 0, list:num_items() - 1 do
        local mf = list:item_at(i)
        if not mf:is_armed_citizenry() and mf:has_general() and mf:force_type():key() ~= "CONVOY" then
            local n, c = mf:unit_list():num_items(), mf:general_character():command_queue_index()
            if bn == nil or n > bn or (n == bn and c < bc) then best, bn, bc = mf, n, c end
        end
    end
    return best
end

-- What `key` would be offered now: {key, region, target, char, force}, or nil.
function F.event_offer(faction, key, stocks)
    local e = DERPY_MR_FLOWS_EVENTS[key]
    if e.where == "region" then
        local r = F.event_region(stocks, e.use, e.cost, key == "siege")
        return r and { key = key, region = r:name() } or nil
    end
    local have = 0
    for _, s in ipairs(stocks) do have = have + F.use_total(s.held, e.use) end
    if have < e.cost then return nil end
    if key == "tribute" then
        local n = F.event_neighbour(faction)
        return n and { key = key, target = n:name() } or nil
    elseif key == "arsenal" then
        local mf = F.event_army(faction)
        return mf and { key = key, char = mf:general_character():command_queue_index(),
                        force = mf:command_queue_index() } or nil
    end
    return { key = key }
end

function F.event_book(fkey)
    F.state.events = F.state.events or {}
    local b = F.state.events[fkey]
    if not b then b = { at = -1000000, seen = {} }; F.state.events[fkey] = b end
    return b
end

-- A siege first; otherwise the qualifying event offered longest ago, ties in EVENT_ORDER.
function F.event_pick(faction, b)
    local stocks, best, bt = F.stocks(faction), nil, nil
    for _, key in ipairs(F.EVENT_ORDER) do
        local o = F.event_offer(faction, key, stocks)
        if o and key == "siege" then return o end
        local t = b.seen[key] or -1000000
        if o and (bt == nil or t < bt) then best, bt = o, t end
    end
    return best
end

-- The spend and the reward. A store short of the cost when this runs pays nothing and gets nothing.
function F.event_apply(faction, p)
    local e, fkey = DERPY_MR_FLOWS_EVENTS[p.key], faction:name()
    local pick = function(g) return g.use == e.use end
    if e.where == "region" then
        local r = F.owned(faction, p.region)
        if not r then return end
        local held = F.stock(r)
        if F.use_total(held, e.use) < e.cost then return end
        F.draw(r, held, e.use, e.cost, KIND.spend, fkey)
        cm:apply_effect_bundle_to_region(e.bundle, p.region, e.turns)
        if p.key == "restore" then F.repair(r) end
        return
    end
    local stocks, have = F.stocks(faction), 0
    for _, s in ipairs(stocks) do have = have + F.use_total(s.held, e.use) end
    if have < e.cost then return end
    F.draw_realm(stocks, pick, e.cost, KIND.spend, fkey)
    if p.key == "tribute" then
        cm:apply_dilemma_diplomatic_bonus(fkey, p.target, F.DIPLO_BONUS)   -- the giver acts, the neighbour's regard moves
    elseif p.key == "arsenal" then
        cm:add_experience_to_units_commanded_by_character("character_cqi:" .. p.char, 1)
    end
end

function F.events(faction)
    local r = F.rates()
    if not r.events or not F.uses_stores(faction) then return end
    local human = faction:is_human()
    if not (human or r.ai) then return end
    local fkey, turn = faction:name(), cm:model():turn_number()
    local b = F.event_book(fkey)
    if turn - b.at < F.EVENT_GAP then return end
    local o = F.event_pick(faction, b)
    if not o then return end
    if human then
        local e = DERPY_MR_FLOWS_EVENTS[o.key]
        local tf = o.target and cm:get_faction(o.target):command_queue_index() or 0
        local rg = o.region and cm:get_region(o.region):cqi() or 0
        F.set_pending(fkey, o)
        cm:trigger_dilemma_with_targets(faction:command_queue_index(), e.dilemma, tf, 0, o.char or 0,
                                        o.force or 0, rg, 0, function() end)
    else
        if cm:random_number(100, 1) > F.EVENT_AI_PCT then return end   -- a failed roll starts no gap
        F.event_apply(faction, o)
    end
    b.at, b.seen[o.key] = turn, turn
end

function F.on_dilemma(context)
    local faction = context:faction()
    local fkey, key = faction:name(), F.EVENT_BY_DILEMMA[context:dilemma()]
    local p = key and F.pending(fkey, key)
    if not p then return end
    F.clear_pending(fkey, key)
    if context:choice_key() == "FIRST" then F.event_apply(faction, p) end
end

-- AN UNANSWERED OFFER, one per faction and event: a Restore offered on capture must not wipe a
-- store event still waiting for its answer. A save from before kept one per faction, {key = ...}.
function F.pending(fkey, key)
    local p = F.state.pending and F.state.pending[fkey]
    if not p then return nil end
    if p.key then return p.key == key and p or nil end
    return p[key]
end

function F.set_pending(fkey, o)
    F.state.pending = F.state.pending or {}
    local p = F.state.pending[fkey]
    if not p or p.key then
        p = {}
        F.state.pending[fkey] = p
    end
    p[o.key] = o
end

function F.clear_pending(fkey, key)
    local p = F.state.pending and F.state.pending[fkey]
    if not p then return end
    if p.key then F.state.pending[fkey] = nil else p[key] = nil end
end

-- Every building in the settlement mended.
function F.repair(region)
    local sl = region:settlement():slot_list()
    for i = 0, sl:num_items() - 1 do
        local slot = sl:item_at(i)
        if slot:has_building() then cm:region_slot_instantly_repair_building(slot) end
    end
end

-- RESTORE ON CAPTURE (spending spec section 4, part 2): occupying a settlement whose captured
-- stores hold the cost in building materials offers Restore, a store event's dilemma; a
-- computer-run faction takes it on the events' roll. Under the store events switch.
F.RESTORE_ON = { occupation_decision_occupy = true }
function F.on_restore(context)
    if not F.RESTORE_ON[context:occupation_decision_type()] then return end
    local r, faction = F.rates(), context:character():faction()
    if not r.events or not F.uses_stores(faction) then return end
    local human = faction:is_human()
    if not (human or r.ai) then return end
    local region = context:garrison_residence():region()
    local e = DERPY_MR_FLOWS_EVENTS.restore
    if F.use_total(F.stock(region), e.use) < e.cost then return end
    local o = { key = "restore", region = region:name() }
    if human then
        F.set_pending(faction:name(), o)
        cm:trigger_dilemma_with_targets(faction:command_queue_index(), e.dilemma, 0, 0, 0, 0, region:cqi(), 0,
                                        function() end)
    elseif cm:random_number(100, 1) <= F.EVENT_AI_PCT then
        F.event_apply(faction, o)
    end
end

-- ---- province supplies and shipments (spending spec section 3, phase 5) -------------------
-- Three switches per province, paid each turn from the province capital's store, each put a
-- region bundle on every settlement the faction holds in the province. Goods reach a store by
-- shipment: SHIP.turns on the road, drawn as a map marker, seized by an army of a faction at war
-- with the owner that walks in (AreaEntered) or stands within SHIP.near of it at the owner's
-- turn start. CA's own caravans cannot be sent anywhere by script (docs/TRADE_RESOURCES.md 24).
F.SHIP = DERPY_MR_FLOWS_SHIP
F.SHIP_PREFIX = "derpy_mr_ship_"
F.SUPPLY_KEYS = { standing = true }       -- the three supplies, and Supply the capital
for k in pairs(DERPY_MR_FLOWS_SUPPLY) do F.SUPPLY_KEYS[k] = true end

-- The settlements a faction holds, by province: {pk = {regions, capital}}, capital nil unless the
-- faction holds it; and the province keys in order, so every machine walks them alike.
function F.provinces(faction)
    local out, keys = {}, {}
    local rl = faction:region_list()
    for i = 0, rl:num_items() - 1 do
        local r = rl:item_at(i)
        if not r:is_null_interface() then
            local pk = r:province_name()
            if not out[pk] then
                out[pk] = { regions = {} }
                keys[#keys + 1] = pk
            end
            out[pk].regions[#out[pk].regions + 1] = r
        end
    end
    for _, pk in ipairs(keys) do
        local p = out[pk]
        local cap = p.regions[1]:province():capital_region()
        if cap and not cap:is_null_interface() then
            local o = cap:owning_faction()
            if not o:is_null_interface() and o:name() == faction:name() then p.capital = cap end
        end
    end
    table.sort(keys)
    return out, keys
end

-- One province's switches, kept in the save: {materials, stable, arms, standing = true, short =
-- {key = the turn it ran short}}. Made only when asked to.
function F.supply_book(fkey, pk, make)
    F.state.supply = F.state.supply or {}
    local f = F.state.supply[fkey]
    if not f and make then f = {}; F.state.supply[fkey] = f end
    local b = f and f[pk]
    if not b and make then b = { short = {} }; f[pk] = b end
    return b
end

-- WHAT A PROVINCE CAPITAL'S DRILL-DOWN SHOWS: nil unless rkey is the faction's own capital of a
-- province. {cost a turn of each supply, on = {key = true}, short = {key = turn}, have = {use = n}}
function F.supply_state(faction, rkey)
    if not F.uses_stores(faction) then return nil end   -- F.supply would never pay: offer nothing
    local r = F.owned(faction, rkey)
    if not r then return nil end
    local p = (F.provinces(faction))[r:province_name()]
    if not (p and p.capital and p.capital:name() == rkey) then return nil end
    local b = F.supply_book(faction:name(), r:province_name(), false) or {}
    local st = { cost = F.SHIP.per * #p.regions, on = {}, short = {}, have = {} }
    for k in pairs(F.SUPPLY_KEYS) do
        if b[k] then st.on[k] = true end
        if b.short and b.short[k] then st.short[k] = b.short[k] end
    end
    local held = F.stock(p.capital)
    st.pay = {}
    for _, s in pairs(DERPY_MR_FLOWS_SUPPLY) do
        st.have[s.use] = F.use_total(held, s.use)
        -- what the payment takes first: the fullest, a tie by resource key (F.draw_realm's order)
        local best
        for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
            if g.use == s.use then
                local n = held[g.stem] or 0
                if not best or n > best.n or (n == best.n and g.res < best.res) then
                    best = { stem = g.stem, n = n, res = g.res }
                end
            end
        end
        if best then st.pay[s.use] = { stem = best.stem, n = best.n } end
    end
    return st
end

-- The capitals of the provinces a faction can supply, by province key: the Spending tab's rows.
function F.capitals(faction)
    local out = {}
    if not F.uses_stores(faction) then return out end
    local provs, keys = F.provinces(faction)
    for _, pk in ipairs(keys) do
        if provs[pk].capital then out[#out + 1] = provs[pk].capital:name() end
    end
    return out
end

function F.toggle_supply(faction, rkey, k)
    if not F.SUPPLY_KEYS[k] or not F.supply_state(faction, rkey) then return end
    local b = F.supply_book(faction:name(), F.owned(faction, rkey):province_name(), true)
    if b[k] then
        b[k] = nil
    else
        b[k], b.short[k] = true, nil
    end
end

-- ---- shipments ----
function F.ships()
    F.state.ships = F.state.ships or {}
    return F.state.ships
end

function F.ship_count(fkey)
    local n = 0
    for _, s in ipairs(F.ships()) do
        if s.f == fkey then n = n + 1 end
    end
    return n
end

function F.ship_cap(faction)
    if faction:is_human() then return F.rates().ships end
    return F.SHIP.ai_cap
end

-- What is on the road to a store, in the order it left; every good when stem is nil.
function F.ships_to(fkey, rkey, stem)
    local out = {}
    for _, s in ipairs(F.ships()) do
        if s.f == fkey and s.to == rkey and (stem == nil or s.stem == stem) then out[#out + 1] = s end
    end
    return out
end

function F.incoming(fkey, rkey, stem)
    local n = 0
    for _, s in ipairs(F.ships_to(fkey, rkey, stem)) do n = n + s.n end
    return n
end

-- CA'S OWN SPOT BESIDE A SETTLEMENT, passable land, the way its marker manager places markers; the
-- settlement itself when it finds none (-1, -1). Whole numbers: a fraction does not cross the save.
function F.spot(fkey, region)
    local x, y = cm:find_valid_spawn_location_for_character_from_settlement(fkey, region:name(), false, true,
                                                                            F.SHIP.spot)
    if not x or x < 0 then
        local st = region:settlement()
        x, y = st:logical_position_x(), st:logical_position_y()
    end
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

-- NO FACTION FILTER: any army may walk in; F.on_area decides who seizes.
function F.mark(s)
    cm:add_interactable_campaign_marker(s.id, F.SHIP.info, s.x, s.y, F.SHIP.radius, "", "")
end

-- Send n of a good from one of the faction's settlements to another: taken at once, a tenth lost
-- on the road, the rest arriving SHIP.turns later. nil when the faction has its full number of
-- shipments on the road, or nothing would arrive.
function F.ship(faction, from, to, stem, n)
    local fkey = faction:name()
    if F.ship_count(fkey) >= F.ship_cap(faction) then return nil end
    n = math.min(n, F.held(from, stem))
    local got = n - F.lost(n)
    if got <= 0 then return nil end
    F.move(from, nil, stem, n, KIND.move, fkey, nil)
    F.state.ship_seq = (F.state.ship_seq or 0) + 1
    local s = { id = F.SHIP_PREFIX .. F.state.ship_seq, f = fkey, stem = stem, n = got, from = from:name(),
                to = to:name(), at = cm:model():turn_number(), leg = 1 }
    s.due = s.at + F.SHIP.turns
    s.x, s.y = F.spot(fkey, from)
    local list = F.ships()
    list[#list + 1] = s
    F.mark(s)
    return s
end

function F.drop(s)
    local list = F.ships()
    for i, x in ipairs(list) do
        if x == s then table.remove(list, i) break end
    end
    cm:remove_interactable_campaign_marker(s.id)
end

-- SEIZED: the cargo goes to the captor's settlement nearest the shipment, as far as it has room;
-- a captor with no settlement destroys it.
function F.seize(s, captor)
    F.drop(s)
    F.move(nil, F.nearest(captor, s.x, s.y), s.stem, s.n, KIND.raid, nil, captor:name())
end

-- An army in the field (no garrison) of a faction at war with the owner, within SHIP.near.
function F.captor(owner, s)
    local wars = owner:factions_at_war_with()
    if type(wars) ~= "table" and type(wars) ~= "userdata" then return nil end
    local r2 = F.SHIP.near * F.SHIP.near
    for i = 0, wars:num_items() - 1 do
        local o = wars:item_at(i)
        local mfl = o:military_force_list()
        for j = 0, mfl:num_items() - 1 do
            local mf = mfl:item_at(j)
            if not mf:is_armed_citizenry() and mf:has_general() then
                local ch = mf:general_character()
                local dx, dy = ch:logical_position_x() - s.x, ch:logical_position_y() - s.y
                if dx * dx + dy * dy <= r2 then return o end
            end
        end
    end
    return nil
end

-- ARRIVED: into the destination as far as it has room; a destination lost meanwhile sends it to
-- the owner's settlement nearest it, and an owner with none loses it.
function F.arrive(owner, s)
    F.drop(s)
    local to = F.owned(owner, s.to)
    if not to then
        local r = cm:get_region(s.to)
        local st = r and r:settlement()
        if st and not st:is_null_interface() then
            to = F.nearest(owner, st:logical_position_x(), st:logical_position_y())
        end
    end
    F.move(nil, to, s.stem, s.n, KIND.move, nil, owner:name())
end

-- At its owner's turn start each shipment is seized, arrives, or moves to its second spot.
function F.ships_turn(faction)
    local fkey, turn = faction:name(), cm:model():turn_number()
    local mine = {}
    for _, s in ipairs(F.ships()) do
        if s.f == fkey then mine[#mine + 1] = s end
    end
    for _, s in ipairs(mine) do
        local captor = F.captor(faction, s)
        if captor then
            F.seize(s, captor)
        elseif turn - s.at >= F.SHIP.turns then
            F.arrive(faction, s)
        elseif turn - s.at >= 1 and s.leg == 1 then
            cm:remove_interactable_campaign_marker(s.id)
            local to = F.owned(faction, s.to) or cm:get_region(s.to)
            if to then s.x, s.y = F.spot(fkey, to) end
            s.leg = 2
            F.mark(s)
        end
    end
end

-- A dead faction's turn never starts: its shipments are cleared at a player's.
function F.sweep()
    local list = F.ships()
    for i = #list, 1, -1 do
        local f = cm:get_faction(list[i].f)
        if not f or f:is_null_interface() or f:is_dead() then
            cm:remove_interactable_campaign_marker(list[i].id)
            table.remove(list, i)
        end
    end
end

-- WALKED IN: only an army, and only of a faction at war with the owner. Its own armies and its
-- friends pass by, as does a hero alone.
function F.on_area(context)
    local id, s = context:area_key(), nil
    for _, x in ipairs(F.ships()) do
        if x.id == id then s = x end
    end
    if not s then return end
    local ch = context:family_member():character()
    if ch:is_null_interface() or not ch:has_military_force() then return end
    local owner, captor = cm:get_faction(s.f), ch:faction()
    if not owner or owner:is_null_interface() or not captor:at_war_with(owner) then return end
    F.seize(s, captor)
end

-- SUPPLY THE CAPITAL: a switched-on use the capital holds under SHIP.stand turns of gets one
-- shipment, enough for SHIP.ai_on turns, of the fullest good of that use in the province's other
-- settlements; none while one is already on the road for that use.
function F.standing(faction, p, b, cost)
    local fkey, cap = faction:name(), p.capital
    for _, k in ipairs(DERPY_MR_FLOWS_SUPPLY_ORDER) do
        local use = DERPY_MR_FLOWS_SUPPLY[k].use
        local have = b[k] and F.use_total(F.stock(cap), use) or 0
        local coming = false
        for _, s in ipairs(F.ships_to(fkey, cap:name())) do
            if F.GOOD[s.stem].use == use then coming = true end
        end
        if b[k] and have < F.SHIP.stand * cost and not coming then
            local from, stem, fh = nil, nil, 0
            for _, r in ipairs(p.regions) do
                if r:name() ~= cap:name() then
                    local held = F.stock(r)
                    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
                        local h = held[g.stem] or 0
                        if g.use == use and h > fh then from, stem, fh = r, g.stem, h end
                    end
                end
            end
            if from then F.ship(faction, from, cap, stem, F.SHIP.ai_on * cost - have) end
        end
    end
end

-- A computer-run faction switches a supply on at SHIP.ai_on turns of it, and always supplies its
-- capitals; it is switched off again by running short, as a player's is.
function F.ai_supply(b, capital, cost)
    b.standing = true
    local held = F.stock(capital)
    for _, k in ipairs(DERPY_MR_FLOWS_SUPPLY_ORDER) do
        if not b[k] and F.use_total(held, DERPY_MR_FLOWS_SUPPLY[k].use) >= F.SHIP.ai_on * cost then
            b[k] = true
        end
    end
end

-- PAID FROM THE CAPITAL, OR OFF: a capital short of a whole turn's cost pays nothing, and the
-- switch turns itself off and keeps the turn for its tooltip. Every settlement held in the
-- province gets the bundles paid for, and loses the others at once.
function F.supply(faction)
    local r = F.rates()
    if not r.supply or not F.uses_stores(faction) then return end
    local human = faction:is_human()
    if not (human or r.ai) then return end
    local fkey, turn = faction:name(), cm:model():turn_number()
    local provs, keys = F.provinces(faction)
    for _, pk in ipairs(keys) do
        local p, paid = provs[pk], {}
        local b = F.supply_book(fkey, pk, not human and p.capital ~= nil)
        if b and p.capital then
            local cost = F.SHIP.per * #p.regions
            if not human then F.ai_supply(b, p.capital, cost) end
            if b.standing then F.standing(faction, p, b, cost) end
            for _, k in ipairs(DERPY_MR_FLOWS_SUPPLY_ORDER) do
                if b[k] then
                    local use, held = DERPY_MR_FLOWS_SUPPLY[k].use, F.stock(p.capital)
                    if F.use_total(held, use) < cost then
                        b[k], b.short[k] = nil, turn
                    else
                        F.draw(p.capital, held, use, cost, KIND.spend, fkey)
                        paid[k] = true
                    end
                end
            end
        end
        for _, region in ipairs(p.regions) do
            for _, k in ipairs(DERPY_MR_FLOWS_SUPPLY_ORDER) do
                local bk, rk = DERPY_MR_FLOWS_SUPPLY[k].bundle, region:name()
                if paid[k] then
                    cm:apply_effect_bundle_to_region(bk, rk, F.BUNDLE_TURNS)
                elseif region:has_effect_bundle(bk) then
                    cm:remove_effect_bundle_from_region(bk, rk)
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
        F.guard(F.sweep)
    end
    -- eat before trading, so a partner is sent what is left; its own guard, so a throw in one
    -- settlement cannot stop the trade every machine must run alike
    F.guard(F.upkeep, faction)
    F.trade(faction)
    -- shipments before supplies, so an arrival is in the capital before the turn's payment
    F.guard(F.ships_turn, faction)
    F.guard(F.supply, faction)
    -- last, on what eating and trading left; its own guard, as an offer is model state too
    F.guard(F.events, faction)
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
        function(context) F.guard(F.on_occupation, context); F.guard(F.on_restore, context) end, true)
    core:add_listener("derpy_mr_flows_battle", "CharacterCompletedBattle", true,
        function(context) F.guard(F.on_battle, context) end, true)
    core:add_listener("derpy_mr_flows_ui", "UITrigger", true,
        function(context) F.guard(F.on_ui_trigger, context) end, true)
    -- a DB dilemma, not a scripted one: matching a scripted dilemma here crashes the game
    core:add_listener("derpy_mr_flows_dilemma", "DilemmaChoiceMadeEvent",
        function(context) return F.EVENT_BY_DILEMMA[context:dilemma()] ~= nil end,
        function(context) F.guard(F.on_dilemma, context) end, true)
    core:add_listener("derpy_mr_flows_ship", "AreaEntered",
        function(context) return string.sub(context:area_key(), 1, #F.SHIP_PREFIX) == F.SHIP_PREFIX end,
        function(context) F.guard(F.on_area, context) end, true)
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
