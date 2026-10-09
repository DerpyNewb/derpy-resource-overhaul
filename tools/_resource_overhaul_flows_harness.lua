-- Derpy Resource Overhaul: the flows script (derpy_more_resources_flows.lua) run against a stub
-- world. tools/gen_mr_ui.py --selftest writes the scripts into a temp folder and fills in
-- __FLOWS__, __STORES__ (whose read_realm the history uses) and __MCT__.
local ERRORS = {}
out = function(m) ERRORS[#ERRORS + 1] = tostring(m) end
local function eq(a, b, what)
    if a ~= b then error(what .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local NULL = { is_null_interface = function() return true end }
local function list(items)
    return { num_items = function() return #items end,
             item_at = function(_, i) return items[i + 1] end,
             is_empty = function() return #items == 0 end }
end

-- ---- the world --------------------------------------------------------------------------
-- A region's stores are r.held (stem -> n), every store r.cap big. r.readable = false is a
-- region whose pools the engine no longer hands out (a raze, Task 1).
local FACTIONS, REGIONS, LOG = {}, {}, {}
BUNDLES = {}                 -- region key -> {bundle = turns}, as cm applies and removes them
FBUNDLES, TREASURY = {}, {}  -- faction key -> {bundle = turns}; faction key -> gold added
FPOOL, FPOOL_FACTOR = {}, {}  -- faction key -> {CA pool = value}; the factor of each pool change
CHARS, FORCE_BUNDLES = {}, {}  -- cqi -> character (named recipes, section 4b/4c); {bundle, force cqi, turns}
local CCO_MADE = ""
local function pool(r, stem)
    local key = "derpy_mr_store_" .. stem
    return { is_null_interface = function() return false end, key = function() return key end,
             value = function() return r.held[stem] or 0 end,
             maximum_value = function() return r.cap end,
             -- this turn's transactions: r.made is the production twin rows' "stocked" factor
             factors = function()
                 local fs = {}
                 if (r.made or {})[stem] then
                     fs[1] = { key = function() return "derpy_mr_stocked" end, value = function() return r.made[stem] end }
                 end
                 return list(fs)
             end }
end
local function region(key, x, y, cap, held)
    local r = { key = key, x = x, y = y, cap = cap, held = held or {}, owner = nil, readable = true, level = 1,
                adj = {}, siege = false, prov = "prov_" .. key }
    r.capital = r
    local settlement = {
        is_null_interface = function() return false end,
        cqi = function() return 0 end,
        logical_position_x = function() return r.x end,
        logical_position_y = function() return r.y end,
        primary_slot = function() return { building = function()
            return { building_level = function() return r.level end } end } end,
        slot_list = function() return list(r.slots or {}) end,
    }
    r.iface = {
        __r = r,
        is_null_interface = function() return false end,
        name = function() return key end,
        cqi = function() return 900 + #key end,
        province_name = function() return r.prov end,
        province = function() return { capital_region = function() return r.capital.iface end } end,
        garrison_residence = function() return { is_under_siege = function() return r.siege end } end,
        adjacent_region_list = function()
            local t = {}
            for _, o in ipairs(r.adj) do t[#t + 1] = o.iface end
            return list(t)
        end,
        is_abandoned = function() return r.owner == nil end,
        has_effect_bundle = function(_, b) return BUNDLES[key] ~= nil and BUNDLES[key][b] ~= nil end,
        owning_faction = function() return r.owner and r.owner.iface or NULL end,
        settlement = function() return settlement end,
        pooled_resource_manager = function()
            return {
                resource = function(_, k)
                    local stem = string.match(k, "^derpy_mr_store_(.+)$")
                    if not r.readable or not stem then return NULL end
                    return pool(r, stem)
                end,
                resources = function()
                    local items = {}
                    if r.readable then
                        for stem in pairs(r.held) do items[#items + 1] = pool(r, stem) end
                    end
                    return list(items)
                end,
            }
        end,
    }
    REGIONS[key] = r
    return r
end
local NEXT_CQI = 0
local function faction(name, opts)
    opts = opts or {}
    NEXT_CQI = NEXT_CQI + 1
    local f = { name = name, human = opts.human or false, rebel = opts.rebel or false,
                regions = {}, war = {}, partners = {}, has = opts.has or {}, home = nil, cqi = NEXT_CQI,
                armies = {}, pool = {} }
    FPOOL[name] = opts.pools
    f.iface = {
        is_null_interface = function() return false end,
        name = function() return name end,
        command_queue_index = function() return f.cqi end,
        is_human = function() return f.human end,
        has_effect_bundle = function(_, b) return FBUNDLES[name] ~= nil and FBUNDLES[name][b] ~= nil end,
        treasury = function() return (opts.gold or 100000) + (TREASURY[name] or 0) end,
        subculture = function() return opts.sc or "wh_main_sc_emp_empire" end,
        pooled_resource_manager = function()
            return { resource = function(_, k)
                if not (FPOOL[name] and FPOOL[name][k]) then return NULL end
                return { is_null_interface = function() return false end, value = function() return FPOOL[name][k] end,
                         maximum_value = function() return (opts.pool_max and opts.pool_max[k]) or 2147483647 end }
            end }
        end,
        is_rebel = function() return f.rebel end,
        is_dead = function() return f.dead == true end,
        factions_at_war_with = function()
            local ks, t = {}, {}
            for k in pairs(f.war) do ks[#ks + 1] = k end
            table.sort(ks)
            for _, k in ipairs(ks) do t[#t + 1] = FACTIONS[k].iface end
            return list(t)
        end,
        at_war_with = function(_, o) return f.war[o:name()] == true end,
        region_list = function()
            local t = {}
            for _, r in ipairs(f.regions) do t[#t + 1] = r.iface end
            return list(t)
        end,
        has_home_region = function() return f.home ~= nil end,
        home_region = function() return f.home and f.home.iface or NULL end,
        factions_trading_with = function()
            local t = {}
            for _, o in ipairs(f.partners) do t[#t + 1] = o.iface end
            return list(t)
        end,
        trade_resource_exists = function(_, res) return f.has[res] == true end,
        military_force_list = function() return list(f.armies) end,
        mercenary_pool = function()
            if f.pool_broken then error("no pool here") end
            return { mercenary_pool_units = function()
                local t = {}
                for unit, n in pairs(f.pool) do
                    t[#t + 1] = { unit_record = function() return { key = function() return unit end } end,
                                  unit_count = function() return n end }
                end
                return list(t)
            end }
        end,
    }
    FACTIONS[name] = f
    return f
end
local function own(f, r, home)
    r.owner = f
    f.regions[#f.regions + 1] = r
    if home then f.home = r end
end
local function war(a, b) a.war[b.name] = true; b.war[a.name] = true end
local function lose(f, r)
    for i, x in ipairs(f.regions) do if x == r then table.remove(f.regions, i) break end end
    r.owner = nil
end
local function army(f, r, x, y, stance)
    return {
        has_military_force = function() return true end,
        military_force = function() return { active_stance = function()
            return stance or "MILITARY_FORCE_ACTIVE_STANCE_TYPE_LAND_RAID" end } end,
        region = function() return r and r.iface or NULL end,
        faction = function() return f.iface end,
        logical_position_x = function() return x end,
        logical_position_y = function() return y end,
    }
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end
local SAVED, MP, TURN = {}, false, 1
DILEMMAS, DIPLO, RANKS, ROLLS, ROLL = {}, {}, {}, {}, 100   -- ROLL 100: no computer-run event fires
MARKERS, SPAWN_FAIL = {}, false
ITEMS, POOL, RESEARCH, GRANTED = {}, {}, {}, {}   -- the Workshop's grants
REPAIRED = {}                     -- Restore: the slots cm repaired   -- phase 5: the shipment markers on the map; a spot CA cannot find
local FIRST, LISTENERS = {}, {}
cm = {
    saving_game_callbacks = {}, loading_game_callbacks = {},
    add_saving_game_callback = function() error("the save callback must go first in CA's list") end,
    add_loading_game_callback = function() error("the load callback must go first in CA's list") end,
    add_first_tick_callback = function(_, fn) FIRST[#FIRST + 1] = fn end,
    callback = function() end,
    repeat_real_callback = function() end,
    get_local_faction_name = function() return LOCAL_FK or "hum" end,
    get_faction = function(_, k) return FACTIONS[k] and FACTIONS[k].iface or false end,
    get_region = function(_, k) return REGIONS[k] and REGIONS[k].iface or false end,
    get_human_factions = function()
        local t = {}
        for k, f in pairs(FACTIONS) do if f.human then t[#t + 1] = k end end
        table.sort(t)
        return t
    end,
    is_multiplayer = function() return MP end,
    model = function() return { turn_number = function() return TURN end } end,
    -- the engine clamps a pool to [0, its maximum]; this stub does the same
    entity_add_pooled_resource_transaction = function(_, e, j, n)
        local r = e.__r
        LOG[#LOG + 1] = { r.key, j, n }
        local stem = string.match(j, "^derpy_mr_store_(.+)_%a+$")
        r.held[stem] = math.max(0, math.min(r.cap, (r.held[stem] or 0) + n))
    end,
    apply_effect_bundle_to_region = function(_, b, rk, turns)
        BUNDLES[rk] = BUNDLES[rk] or {}
        BUNDLES[rk][b] = turns
    end,
    remove_effect_bundle_from_region = function(_, b, rk) if BUNDLES[rk] then BUNDLES[rk][b] = nil end end,
    remove_effect_bundle = function(_, k, fk) if FBUNDLES[fk] then FBUNDLES[fk][k] = nil end end,
    apply_effect_bundle = function(_, b, fk, turns)
        FBUNDLES[fk] = FBUNDLES[fk] or {}
        -- whether a DB bundle applied over a CUSTOM one of the same key replaces it is unmeasured:
        -- assume not, so only a removal clears it
        if type(FBUNDLES[fk][b]) ~= "table" then FBUNDLES[fk][b] = turns end
    end,
    -- CA's docs say positive only; CA's own scripts pass negatives (import duty, spec section 2)
    treasury_mod = function(_, fk, n)
        if n == 0 then error("treasury_mod of nothing") end
        TREASURY[fk] = (TREASURY[fk] or 0) + n
    end,
    faction_add_pooled_resource = function(_, fk, pool, factor, n)
        FPOOL[fk] = FPOOL[fk] or {}
        FPOOL[fk][pool] = (FPOOL[fk][pool] or 0) + n
        FPOOL_FACTOR[#FPOOL_FACTOR + 1] = factor
    end,
    -- phase 6: what the events hand the engine, recorded
    trigger_dilemma_with_targets = function(_, fcqi, key, tf, _sf, ch, mf, rg, st, cb)
        if type(cb) ~= "function" then error("trigger_dilemma_with_targets takes its callback") end
        if DILEMMA_FAILS then return false end    -- CA's wrapper: false in multiplayer when not issued
        DILEMMAS[#DILEMMAS + 1] = { fcqi = fcqi, key = key, faction = tf, character = ch, force = mf, region = rg }
        return true
    end,
    apply_dilemma_diplomatic_bonus = function(_, a, b, n) DIPLO[#DIPLO + 1] = { a, b, n } end,
    add_experience_to_units_commanded_by_character = function(_, lookup, n) RANKS[#RANKS + 1] = { lookup, n } end,
    -- CA's wrapper answers false for a cqi it cannot find
    get_character_by_cqi = function(_, cqi) local c = CHARS[cqi]; return c and c.iface or false end,
    apply_effect_bundle_to_force = function(_, b, fcqi, turns)
        if type(b) ~= "string" or type(fcqi) ~= "number" then error("apply_effect_bundle_to_force: bad arguments") end
        FORCE_BUNDLES[#FORCE_BUNDLES + 1] = { b, fcqi, turns }
    end,
    force_add_trait = function(_, lookup, trait, show, points)
        local cqi = tonumber(string.match(lookup, "^character_cqi:(%d+)$"))
        if not (cqi and CHARS[cqi]) or type(trait) ~= "string" then error("force_add_trait: bad arguments") end
        CHARS[cqi].traits[trait] = true
    end,
    random_number = function(_, hi, lo) ROLLS[#ROLLS + 1] = { hi, lo }; return ROLL end,
    -- phase 5: CA's spot beside a settlement is one step off it; -1, -1 when it finds none
    find_valid_spawn_location_for_character_from_settlement = function(_, fk, rk, sea, same, dist)
        if type(fk) ~= "string" or sea ~= false or same ~= true or type(dist) ~= "number" then
            error("find_valid_spawn_location_for_character_from_settlement: bad arguments")
        end
        if SPAWN_FAIL then return -1, -1 end
        return REGIONS[rk].x + 1, REGIONS[rk].y + 1
    end,
    add_interactable_campaign_marker = function(_, id, info, x, y, r, fk, sc)
        if MARKERS[id] then error("a marker id used twice: " .. id) end
        if r > 20 then error("a marker radius over 20") end
        MARKERS[id] = { info = info, x = x, y = y, r = r, f = fk, sc = sc }
    end,
    remove_interactable_campaign_marker = function(_, id) MARKERS[id] = nil end,
    region_slot_instantly_repair_building = function(_, slot)
        if type(slot) ~= "table" or not slot.has_building then error("repair takes a slot interface") end
        REPAIRED[#REPAIRED + 1] = slot
    end,
    -- the Workshop: what it hands the engine, recorded
    add_ancillary_to_faction = function(_, f, key, quiet)
        if type(f) ~= "table" or type(key) ~= "string" or quiet ~= false then error("add_ancillary_to_faction: bad arguments") end
        ITEMS[#ITEMS + 1] = { f = f:name(), key = key }
    end,
    add_unit_to_faction_mercenary_pool = function(_, f, unit, src, n, rc, max, mpt, fr, sr, tr, partial, group)
        if type(f) ~= "table" or type(unit) ~= "string" or type(group) ~= "string" or type(n) ~= "number" or n < 1
                or type(max) ~= "number" then
            error("add_unit_to_faction_mercenary_pool: bad arguments")
        end
        POOL[#POOL + 1] = { f = f:name(), unit = unit, src = src, max = max, group = group }
        local fp = FACTIONS[f:name()].pool
        -- THE COUNT IS SET, NOT ADDED (measured 2026-10-07: 1 on a pool of 1 stays 1, 2 makes it 2)
        fp[unit] = math.min(max, n)
    end,
    grant_research_points = function(_, fk, n)
        if type(fk) ~= "string" or type(n) ~= "number" then error("grant_research_points: bad arguments") end
        RESEARCH[#RESEARCH + 1] = { f = fk, n = n }
    end,
    grant_unit_to_character = function(_, lookup, unit)
        if type(lookup) ~= "string" or type(unit) ~= "string" then error("grant_unit_to_character: bad arguments") end
        GRANTED[#GRANTED + 1] = { lookup = lookup, unit = unit }
        if GRANT_HOOK then GRANT_HOOK(unit) end   -- an engine that fires UnitTrained inside the call
    end,
    save_named_value = function(_, k, v) SAVED[k] = copy(v) end,
    load_named_value = function(_, k, d) if SAVED[k] == nil then return d end return copy(SAVED[k]) end,
}
core = {
    add_listener = function(_, _name, event, cond, fn)
        LISTENERS[#LISTENERS + 1] = { event = event, cond = cond, fn = fn }
    end,
}
local SENT = {}
CampaignUI = { TriggerCampaignScriptEvent = function(cqi, id) SENT[#SENT + 1] = { cqi, id } end }
SOUNDS = {}                   -- the Workshop: every sound event played, in order
common = {
    trigger_soundevent = function(ev) SOUNDS[#SOUNDS + 1] = ev end,
    get_localised_string = function() LOC_CALLS = (LOC_CALLS or 0) + 1; return "" end,
    get_context_value = function() return CCO_MADE end,
}
local function fire(event, context)
    for _, l in ipairs(LISTENERS) do
        if l.event == event and (l.cond == true or (type(l.cond) == "function" and l.cond(context))) then
            l.fn(context)
        end
    end
end
local function raid(ch) fire("CharacterTurnStart", { character = function() return ch end }) end
local function decide(kind, r, taker, prev, ch)
    fire("CharacterPerformsSettlementOccupationDecision", {
        occupation_decision_type = function() return kind end,
        previous_owner = function() return prev end,
        garrison_residence = function() return { region = function() return r.iface end } end,
        character = function() return ch or army(taker, r, r.x, r.y) end,
    })
end

-- ANOTHER MOD'S CALLBACKS, ALREADY IN CA'S LISTS AND THROWING: CA calls the lists in one
-- unprotected loop, so ours only runs if it went in ahead of them.
local function thrower() error("another mod's callback threw") end
cm.saving_game_callbacks[1], cm.loading_game_callbacks[1] = thrower, thrower
dofile("__STORES__")
dofile("__FLOWS__")
local F = DERPY_MR_FLOWS
F.init()                     -- not FIRST: the stores script's first tick wants a UI
-- THE MOVES ARE MEASURED ALONE: settlements eating provisions (phase 4) has its own section below
F.rates(); F.state.rates.upkeep = false; F.state.rates.events = false; F.state.rates.supply = false

-- ---- the world for taking ---------------------------------------------------------------
local hum = faction("hum", { human = true })
local h1, h2 = region("h1", 0, 0, 200), region("h2", 100, 0, 200)
own(hum, h1, true); own(hum, h2)
local ai1 = faction("ai1")
local a1 = region("a1", 10, 0, 400, { coal = 95, iron = 9 })
own(ai1, a1, true)
local ally = faction("ally")
local b1 = region("b1", 50, 50, 200, { coal = 50 }); own(ally, b1, true)
local horde = faction("horde")                   -- no settlements
local reb = faction("reb", { rebel = true })
local rb1 = region("rb1", 20, 20, 200, { coal = 50 }); own(reb, rb1, true)
local ruin = region("ruin", 30, 30, 200, { coal = 50 })   -- no owner
war(hum, ai1); war(horde, ai1); war(hum, reb)

-- ---- raids ------------------------------------------------------------------------------
eq(F.share(95, 10), 9, "a share is floored"); eq(F.share(9, 10), 1, "a small store still yields 1")
eq(F.share(0, 10), 0, "an empty store yields nothing"); eq(F.share(9, 0), 0, "a zero share takes nothing")
raid(army(hum, a1, 12, 0))
eq(a1.held.coal, 86, "a raid takes 10% of the victim's coal")
eq(h1.held.coal, 9, "into the raider's nearest settlement")
eq(h2.held.coal, nil, "not the far one")
eq(a1.held.iron, 8, "a store too small for a whole share still gives 1")
eq(LOG[1][2], "derpy_mr_store_coal_raided", "booked to the raided junction")
h1.held.coal = 195
raid(army(hum, a1, 12, 0))
eq(a1.held.coal, 78, "the victim loses the whole share"); eq(h1.held.coal, 200, "the raider keeps what fits")
eq(F.book("hum").now.coal.raided_in, 14, "the human raider's ledger counts what arrived")
eq(F.state.factions.ai1, nil, "a computer-run victim keeps no ledger")
local n = #LOG
raid(army(horde, a1, 12, 0))
eq(a1.held.coal, 71, "a horde's raid still costs the victim"); eq(#LOG, n + 2, "and lands nowhere (coal and iron, one transaction each)")
h2.held.coal = 40                                -- ally and hum are not at war
raid(army(ally, h2, 100, 0))
eq(h2.held.coal, 36, "raiding a faction it is not at war with still takes, as CA's raid gold does")
eq(b1.held.coal, 54, "into that raider's nearest")
local before = {}
for k, r in pairs(REGIONS) do before[k] = copy(r.held) end
local function untouched(what)
    for k, r in pairs(REGIONS) do
        for stem, v in pairs(before[k]) do eq(r.held[stem], v, what .. " (" .. k .. " " .. stem .. ")") end
        for stem, v in pairs(r.held) do eq(v, before[k][stem], what .. " (" .. k .. " " .. stem .. ")") end
    end
end
raid(army(hum, h1, 0, 0)); untouched("raiding its own land takes nothing")
raid(army(hum, rb1, 20, 20)); untouched("a rebel-held settlement gives nothing")
raid(army(hum, ruin, 30, 30)); untouched("an abandoned region gives nothing")
raid(army(hum, nil, 5, 5)); untouched("raiding at sea takes nothing")
raid(army(hum, a1, 12, 0, "MILITARY_FORCE_ACTIVE_STANCE_TYPE_DEFAULT")); untouched("marching through takes nothing")

-- a raid between two humans books both
local hum2 = faction("hum2", { human = true })
local g1 = region("g1", 0, 50, 200, { coal = 100 }); own(hum2, g1, true); war(hum, hum2)
h1.held = {}                                   -- room to receive, so the raider's side is measured
raid(army(hum, g1, 0, 50))
eq(F.book("hum2").now.coal.raided_out, 10, "the human victim's ledger counts the loss")
eq(F.book("hum").now.coal.raided_in, 24, "and the human raider's counts what arrived (14 + 10)")

-- the army's plate: what its raid would take next turn, read only
a1.held, h1.held, h2.held = { coal = 95, iron = 9 }, {}, {}
n = #LOG
local pv = F.raid_preview(army(hum, a1, 12, 0))
eq(#LOG, n, "the preview moves nothing")
eq(pv.total, 10, "the plate counts 9 coal and 1 iron"); eq(pv.parts[1].stem, "coal", "most first")
eq(pv.parts[1].n, 9, "coal's share"); eq(pv.to, "h1", "into the raider's nearest")
raid(army(hum, a1, 12, 0))
eq(h1.held.coal + h1.held.iron, pv.total, "and the raid takes what the plate said")
eq(F.raid_preview(army(hum, h1, 0, 0)), nil, "no plate on its own land")
eq(F.raid_preview(army(hum, a1, 12, 0, "MILITARY_FORCE_ACTIVE_STANCE_TYPE_DEFAULT")), nil, "no plate when not raiding")
eq(F.raid_preview(army(horde, a1, 12, 0)).to, nil, "a horde's plate names nowhere")
eq(F.raid_preview(army(hum, ruin, 30, 30)), nil, "no plate over an abandoned region")
local frozen = F.state.rates; F.state.rates = nil
eq(F.raid_preview(army(hum, a1, 12, 0)), nil, "no plate before the rates are frozen")
eq(F.state.rates, nil, "and the plate does not freeze them: that is the turn start's job")
F.state.rates = frozen

-- ---- sack and raze ----------------------------------------------------------------------
a1.held, h1.held, h2.held = { coal = 100 }, {}, {}
decide("occupation_decision_sack", a1, hum, "ai1")
eq(a1.held.coal, 50, "a sack takes half"); eq(h1.held.coal, 50, "into the sacker's nearest")
eq(LOG[#LOG][2], "derpy_mr_store_coal_plundered", "booked to plunder")
-- the capture panel's preview: what each choice takes, read only, before it is chosen
a1.held, h1.held = { coal = 50, iron = 1 }, { coal = 50 }
n = #LOG
local cp = F.capture_preview(a1.iface, hum.iface, "raze")
eq(#LOG, n, "the capture preview moves nothing")
eq(cp.total, 26, "half the coal and the one iron"); eq(cp.parts[1].stem, "coal", "most first")
eq(cp.lost, false, "a taker with settlements keeps it")
eq(F.capture_preview(a1.iface, horde.iface, "sack").lost, true, "a horde's sack is lost")
eq(F.capture_preview(rb1.iface, hum.iface, "sack"), nil, "a rebel settlement shows nothing")
eq(F.capture_preview(h1.iface, hum.iface, "sack"), nil, "nor its own")
local oc = F.capture_preview(a1.iface, hum.iface, "occupy")
eq(oc.total, 51, "an occupation keeps the whole store"); eq(oc.lost, false, "and loses none of it")
eq(F.capture_preview(a1.iface, hum.iface, "gift"), nil, "nor any other choice")
eq(F.capture_preview(h1.iface, hum.iface, "occupy"), nil, "nor occupying its own")
eq(F.capture_preview(ruin.iface, hum.iface, "occupy"), nil, "nor a ruin")
eq(F.capture_preview(rb1.iface, hum.iface, "occupy").total, 50, "an occupied rebel settlement keeps its store too")
frozen = F.state.rates; F.state.rates = nil
eq(F.capture_preview(a1.iface, hum.iface, "sack"), nil, "nothing before the rates are frozen")
F.state.rates = frozen
a1.held.iron = nil
decide("occupation_decision_raze_without_occupy", a1, hum, "ai1")
eq(a1.held.coal, 25, "a raze takes half"); eq(h1.held.coal, 75, "into the razer's nearest")
n = #LOG
decide("occupation_decision_occupy", a1, hum, "ai1"); eq(#LOG, n, "occupying moves nothing")
decide("occupation_decision_loot", a1, hum, "ai1"); eq(#LOG, n, "loot-and-occupy moves nothing")
decide("occupation_decision_sack", rb1, hum, ""); eq(#LOG, n, "rebels (no previous owner) give nothing")
a1.readable = false
decide("occupation_decision_raze_without_occupy", a1, hum, "ai1")
eq(#LOG, n, "a raze of unreadable stores moves nothing")
eq(#ERRORS, 1, "and says so once"); ERRORS = {}
a1.readable = true
-- A RAZE READS THE STORES AS THEY WERE AT THE BATTLE: measured 2026-10-02, the engine drops a razed
-- region's pools before the decision fires (Venom Glade). CA's Bloodgrounds caches the same way.
local function battle_at(r)
    fire("CharacterCompletedBattle", { pending_battle = function() return {
        has_contested_garrison = function() return r ~= nil end,
        contested_garrison = function() return r and { region = function() return r.iface end } or NULL end,
    } end })
end
a1.held, h1.held = { coal = 100 }, {}
battle_at(a1); battle_at(nil)                     -- a field battle beside it caches nothing
a1.readable = false
decide("occupation_decision_raze_without_occupy", a1, hum, "ai1")
eq(h1.held.coal, 50, "a raze takes half of what the stores held at the battle")
eq(a1.held.coal, 100, "and books nothing against the pools that are gone")
eq(#ERRORS, 0, "without saying it could not read them")
decide("occupation_decision_raze_without_occupy", a1, hum, "ai1")
eq(h1.held.coal, 50, "the battle's reading is used once"); ERRORS = {}
a1.readable = true
-- ANY DECISION SPENDS IT, and a reading from another turn is a failed siege's, not this capture's
battle_at(a1); decide("occupation_decision_occupy", a1, hum, "ai1"); a1.readable = false
decide("occupation_decision_raze_without_occupy", a1, hum, "ai1")
eq(h1.held.coal, 50, "an occupy spends the battle's reading: a later raze takes nothing"); ERRORS = {}
a1.readable = true; battle_at(a1); TURN = TURN + 1; a1.readable = false
decide("occupation_decision_raze_without_occupy", a1, hum, "ai1")
eq(h1.held.coal, 50, "a reading from an earlier turn is not used"); ERRORS = {}
TURN = TURN - 1; a1.readable = true

-- ---- trade ------------------------------------------------------------------------------
local tA = faction("tA", { has = { res_derpy_coal = true } })
local tA1, tA2 = region("tA1", 500, 0, 600, { coal = 100 }), region("tA2", 520, 0, 600, { coal = 300 })
own(tA, tA1, true); own(tA, tA2)
local tB = faction("tB", { has = { res_rom_iron = true } })
local tB1 = region("tB1", 600, 0, 600, { iron = 200 }); own(tB, tB1, true)
local tC = faction("tC")                                   -- a partner with no settlements
tA.partners = { tB, tC }; tB.partners = { tA }; tC.partners = { tA }
local function turn_start(f) fire("FactionTurnStart", { faction = function() return f.iface end }) end
F.LACK_TEST = "exists"
n = #LOG
turn_start(tA)
eq(tA2.held.coal, 285, "the fullest store sends 5%"); eq(tA1.held.coal, 100, "the other is untouched")
eq(tB1.held.coal, 15, "into the partner's capital")
eq(#LOG, n + 2, "one move, two transactions - nothing to the partner with no settlements")
eq(LOG[n + 1][2], "derpy_mr_store_coal_traded", "booked to traded")
turn_start(tB)
eq(tB1.held.iron, 190, "the partner exports what the sender lacks"); eq(tA1.held.iron, 10, "to its capital")
eq(tB1.held.coal, 15, "coal is not sent back: tA has coal by the rule")
tB.has.res_derpy_coal = true; n = #LOG
turn_start(tA); eq(#LOG, n, "a partner that has the good gets none of it")
tB.has.res_derpy_coal = nil
-- the capital rule: a partner whose capital holds the good gets none
F.LACK_TEST = "capital"; n = #LOG
turn_start(tA); eq(#LOG, n, "capital rule: tB's capital already holds coal")
tB1.held.coal = 0; turn_start(tA); eq(tB1.held.coal > 0, true, "capital rule: an empty capital store receives")
-- a partner with no settlements leaves the exporter untouched
tA.partners = { tC }; local c2 = tA2.held.coal
turn_start(tA); eq(tA2.held.coal, c2, "a partner with no settlements leaves the exporter untouched")
tA.partners = { tB, tC }
-- trade sends surplus only: measured in game, a raided single wyvern scale left the same turn
local tD, tE = faction("tD"), faction("tE")
local tD1, tE1 = region("tD1", 900, 0, 600, { coal = 19 }), region("tE1", 950, 0, 600)
own(tD, tD1, true); own(tE, tE1, true); tD.partners = { tE }
turn_start(tD); eq(tD1.held.coal, 19, "a store under 20 at 5% trades nothing")
tD1.held.coal = 20; turn_start(tD); eq(tD1.held.coal, 19, "at 20 it sends 1")
-- measured 2026-10-02: for some faction factions_trading_with() hands back a boolean, not a list
tD.iface.factions_trading_with = function() return false end
ERRORS = {}; turn_start(tD); eq(#ERRORS, 0, "a trade list that comes back a boolean is skipped, not an error")

-- ---- the switch: goods move between other factions -------------------------------------
F.state.rates.ai = false
n = #LOG; tB1.held.coal = 0
turn_start(tA); eq(#LOG, n, "switch off: two computer-run factions trade nothing")
hum.partners = { tA }; tA.partners = { hum }; h1.held = {}; h2.held = {}
turn_start(tA); eq(h1.held.coal > 0, true, "switch off: a player's partner still receives")
F.state.rates.ai = true; tA.partners = { tB, tC }; hum.partners = {}

-- trade never destroys stock: a partner with little room gets what fits and the sender keeps the rest
local tD = faction("tD"); local tD1 = region("tD1", 700, 0, 2000, { salt = 1000 }); own(tD, tD1, true)
local tE = faction("tE"); local tE1 = region("tE1", 710, 0, 20, {}); own(tE, tE1, true)
tD.partners = { tE }
turn_start(tD)
eq(tE1.held.salt, 20, "a partner with little room gets what fits")
eq(tD1.held.salt, 980, "and the sender loses only that - trade never destroys stock")
F.LACK_TEST = "exists"           -- tE has no salt by the engine's word, so only space stops it
turn_start(tD)
eq(tD1.held.salt, 980, "a full partner store takes nothing and costs the sender nothing")
F.LACK_TEST = "capital"; tD.partners = {}

-- a history snapshot that throws must not stop a human's exports (they are model state)
hum.partners = { tB }; h1.held = { salt = 100 }; tB1.held.salt = 0
local real_read = DERPY_MR_STORES.read_realm
DERPY_MR_STORES.read_realm = function() error("a UI-side read threw") end
turn_start(hum)
DERPY_MR_STORES.read_realm = real_read
eq(tB1.held.salt, 5, "the human's exports still went out")
eq(#ERRORS, 1, "and the snapshot's failure was logged"); ERRORS = {}
hum.partners = {}

-- ---- the player's trade switches (the Stores panel's Trade tab) ------------------------
local tP = faction("tP", { human = true })
local tP1 = region("tP1", 1200, 0, 600, { coal = 100 }); own(tP, tP1, true)
local tQ = faction("tQ"); local tQ1 = region("tQ1", 1300, 0, 600, { iron = 100 }); own(tQ, tQ1, true)
tP.partners = { tQ }; tQ.partners = { tP }
F.toggle("tP", "export", "coal"); eq(F.stopped("tP", "export", "coal"), true, "a click stops a good's exports")
turn_start(tP); eq(tP1.held.coal, 100, "a stopped export stays home"); eq(tQ1.held.coal, nil, "and never arrives")
F.toggle("tP", "export", "coal"); eq(F.stopped("tP", "export", "coal"), false, "a second click allows it again")
turn_start(tP); eq(tP1.held.coal, 95, "an allowed export leaves")
F.toggle("tP", "import", "iron")
turn_start(tQ); eq(tP1.held.iron, nil, "a refused import is not sent"); eq(tQ1.held.iron, 100, "and the partner keeps it")
F.toggle("tP", "import", "iron"); turn_start(tQ); eq(tP1.held.iron, 5, "an accepted import arrives")
F.toggle("tQ", "export", "iron"); eq(F.stopped("tQ", "export", "iron"), false, "a computer-run faction has no switches")
F.toggle("tP", "sideways", "coal"); eq(F.stopped("tP", "sideways", "coal"), false, "an unknown direction is ignored")
F.toggle("tP", "export", "no_such_good"); eq(F.stopped("tP", "export", "no_such_good"), false, "an unknown good is ignored")
do
    -- A STOPPED EXPORT LEAVES CA'S TRADE TOO (TRADE_RESOURCES.md 28): a hidden faction marker per
    -- stopped good, which the DB's hold rows read, and the visible "Exports held" record
    local function held(fk)
        local n = 0
        for k in pairs(FBUNDLES[fk] or {}) do if string.find(k, "^derpy_mr_hold_") then n = n + 1 end end
        return n
    end
    local function rec(fk) return FBUNDLES[fk] and FBUNDLES[fk].derpy_mr_exports_held end
    F.apply("tP", "export", "coal")
    eq(FBUNDLES.tP.derpy_mr_hold_coal, 0, "a stopped export puts the good's marker on, until allowed again")
    eq(held("tP"), 1, "and no other good's"); eq(rec("tP"), 0, "with the record")
    F.apply("tP", "import", "iron"); eq(held("tP"), 1, "an import switch holds nothing back")
    F.apply("tP", "import", "iron")
    F.apply("tP", "export", "coal"); eq(held("tP"), 0, "allowed again: the marker comes off")
    eq(rec("tP"), nil, "and the record with the last one")
    F.apply("tP", "export", F.ALL_STOP); eq(held("tP"), #DERPY_MR_FLOWS_GOODS, "stop all holds every good")
    F.apply("tP", "export", F.ALL_ALLOW); eq(held("tP") + (rec("tP") or 0), 0, "allow all lifts every one")
    F.apply("tQ", "export", "coal"); eq(held("tQ"), 0, "a computer-run faction never gets one")
    FBUNDLES.tP.derpy_mr_exports_held = { custom = true }   -- a save from before 2026-10-08: -1000 on every good
    turn_start(tP); eq(rec("tP"), nil, "the old custom bundle comes off with nothing held")
    FBUNDLES.tP.derpy_mr_exports_held = { custom = true }; F.apply("tP", "export", "coal")
    eq(rec("tP"), 0, "and with something held, the plain record replaces it")
    F.apply("tP", "export", "coal")
    F.apply("tP", "export", "coal"); FBUNDLES.tP = nil   -- a save from before the markers existed
    turn_start(tP); eq(FBUNDLES.tP and FBUNDLES.tP.derpy_mr_hold_coal, 0, "the player's turn start puts it back")
    F.apply("tP", "export", "coal"); eq(held("tP"), 0, "and leaves no switch stopped for what follows")
end
do
    -- IMPORT DUTY: each turn a faction pays each trade partner 10% of what the partner made, at
    -- what CA's trade pays a unit (g.value), never the Exchange's market price; gold to the partner
    local dA = faction("dA", { human = true }); local dA1 = region("dA1", 5000, 0, 600, {}); own(dA, dA1, true)
    local dB = faction("dB"); local dB1 = region("dB1", 5100, 0, 600, { coal = 50, salt = 50 }); own(dB, dB1, true)
    dA.partners = { dB }; dB.partners = { dA }
    dB1.made = { coal = 30, salt = 20 }
    local t0, a0, b0 = TURN, TREASURY.dA or 0, TREASURY.dB or 0
    local ex0 = EX; EX = { sell_price = function() return 818 end }   -- the Exchange's market price
    F.made_cache = nil; turn_start(dA)
    EX = ex0
    local due = math.floor((30 * F.GOOD.coal.value + 20 * F.GOOD.salt.value) * 10 / 100)
    eq(F.GOOD.salt.value > 5 and F.GOOD.salt.value < 20, true, "a unit is worth what CA's trade pays (9), not 818")
    eq((TREASURY.dA or 0) - a0, -due, "the importer pays 10% of its partner's output at CA's trade value")
    eq((TREASURY.dB or 0) - b0, due, "and the exporter receives exactly that")
    TURN = t0 + 1
    local last = F.duty_last("dA")
    eq(last and last.paid, due, "the player's ledger shows it the next turn")
    eq(last.by.dB.paid, due, "partner by partner"); eq(F.duty_last("dB"), nil, "a computer faction keeps no ledger")
    -- the computer pays too, under its switch, and the player's ledger shows what came in
    dA1.made = { salt = 40 }
    a0 = TREASURY.dA or 0
    F.made_cache = nil; turn_start(dB)
    local got = math.floor(40 * F.GOOD.salt.value * 10 / 100)
    eq((TREASURY.dA or 0) - a0, got, "a computer faction pays the player for its imports")
    TURN = t0 + 2; eq(F.duty_last("dA").got, got, "and the player's ledger shows what came in")
    -- A HELD GOOD CARRIES NO DUTY: it leaves no trade agreement (TRADE_RESOURCES.md 28)
    F.toggle("dA", "export", "salt"); a0 = TREASURY.dA or 0
    F.made_cache = nil; turn_start(dB); eq((TREASURY.dA or 0) - a0, 0, "nothing paid on a good the player holds back")
    F.toggle("dA", "export", "salt")
    -- TWO PARTNERS, TWO TURNS, NO RESET: the made cache is per faction and per turn
    local dD = faction("dD"); local dD1 = region("dD1", 5300, 0, 600, { coal = 1 }); own(dD, dD1, true)
    dA.partners, dB1.made, dD1.made = { dB, dD }, { coal = 10 }, { coal = 100 }
    local function due_on(n) return math.floor(n * F.GOOD.coal.value * 10 / 100) end
    a0 = TREASURY.dA or 0; TURN = t0 + 3; turn_start(dA)
    eq((TREASURY.dA or 0) - a0, -(due_on(10) + due_on(100)), "each partner on its own output")
    dD1.made = { coal = 50 }; a0 = TREASURY.dA or 0; TURN = t0 + 4; turn_start(dA)
    eq((TREASURY.dA or 0) - a0, -(due_on(10) + due_on(50)), "and on this turn's, not the first turn's")
    dA.partners, dD.partners = { dB }, {}
    -- OTHER FACTIONS' STORES OFF: both ways where a player is one side, as trade runs; none between computers
    F.state.rates.ai = false; dB.partners, dD.partners = { dA, dD }, { dB }
    a0, b0 = TREASURY.dA or 0, TREASURY.dB or 0; local d0 = TREASURY.dD or 0
    F.made_cache = nil; TURN = t0 + 5; turn_start(dB)
    eq((TREASURY.dA or 0) - a0, got, "a computer partner still pays the player with the switch off")
    eq((TREASURY.dD or 0) - d0, 0, "but not another computer faction")
    b0 = TREASURY.dB or 0; turn_start(dD); eq((TREASURY.dB or 0) - b0, 0, "nor the other way round")
    F.state.rates.ai = true; dB.partners, dD.partners = { dA }, {}; TURN = t0 + 2
    -- never more than the payer holds; 0 turns it off; nothing made, nothing due
    local dC = faction("dC", { human = true, gold = 5 }); local dC1 = region("dC1", 5200, 0, 600, {}); own(dC, dC1, true)
    dC.partners = { dB }; b0 = TREASURY.dB or 0
    F.made_cache = nil; turn_start(dC)
    eq((TREASURY.dB or 0) - b0, 5, "a faction with 5 gold pays 5"); eq(dC.iface:treasury(), 0, "and runs no debt")
    F.state.rates.duty = 0; b0 = TREASURY.dB or 0; a0 = TREASURY.dA or 0
    F.made_cache = nil; turn_start(dA); eq((TREASURY.dB or 0) - b0, 0, "a rate of 0 is off")
    F.state.rates.duty = 10; dB1.made = nil
    F.made_cache = nil; turn_start(dA); eq((TREASURY.dB or 0) - b0, 0, "nothing made, nothing due")
    dA.partners, dB.partners, dC.partners = {}, {}, {}
    TURN = t0
end
-- a click reaches the model through the network in multiplayer, never straight from the UI
local function ui_trigger(cqi, id)
    fire("UITrigger", { trigger = function() return id end, faction_cqi = function() return cqi end })
end
F.send("tP", "export", "coal"); eq(F.stopped("tP", "export", "coal"), true, "singleplayer: a click applies at once")
eq(#SENT, 0, "and sends nothing"); F.toggle("tP", "export", "coal")
MP = true
F.send("tP", "export", "coal")
eq(F.stopped("tP", "export", "coal"), false, "multiplayer: the click changes nothing on its own")
eq(SENT[1][1], tP.cqi, "it goes out under the clicker's faction"); eq(SENT[1][2], "dmr1|export|coal", "as one short id")
eq(#SENT[1][2] <= 100, true, "under the 100-character trigger limit")
ui_trigger(SENT[1][1], SENT[1][2]); eq(F.stopped("tP", "export", "coal"), true, "the trigger applies it")
ui_trigger(999, "dmr1|export|coal"); eq(F.stopped("tP", "export", "coal"), true, "a trigger from no human does nothing")
ui_trigger(tP.cqi, "zx1|buy|coal"); eq(F.stopped("tP", "export", "coal"), true, "another mod's trigger is not ours")
MP = false; F.toggle("tP", "export", "coal"); SENT = {}
-- ALL AT ONCE: one click stops or allows every resource one way, and leaves the other way alone
local function count(fk, dir)
    local n = 0
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do if F.stopped(fk, dir, g.stem) then n = n + 1 end end
    return n
end
F.toggle("tP", "import", "iron")
F.apply("tP", "export", F.ALL_STOP)
eq(count("tP", "export"), #DERPY_MR_FLOWS_GOODS, "stop all: every resource's exports stopped")
eq(count("tP", "import"), 1, "and the imports untouched")
F.apply("tP", "export", F.ALL_STOP); eq(count("tP", "export"), #DERPY_MR_FLOWS_GOODS, "a second stop-all is not a toggle")
F.apply("tP", "export", F.ALL_ALLOW); eq(count("tP", "export"), 0, "allow all: none stopped")
eq(F.stopped("tP", "import", "iron"), true, "and the imports still untouched")
F.apply("tQ", "export", F.ALL_STOP); eq(count("tQ", "export"), 0, "a computer-run faction has no switches")
F.apply("tP", "sideways", F.ALL_STOP); eq(count("tP", "sideways"), 0, "an unknown direction is ignored")
F.apply("tP", "export", "coal"); eq(F.stopped("tP", "export", "coal"), true, "a resource's key still toggles it")
F.apply("tP", "export", "coal")
F.send("tP", "export", F.ALL_STOP); eq(count("tP", "export"), #DERPY_MR_FLOWS_GOODS, "singleplayer: stop-all applies at once")
F.send("tP", "export", F.ALL_ALLOW); eq(count("tP", "export"), 0, "and allow-all")
MP = true
F.send("tP", "import", F.ALL_ALLOW); eq(SENT[1][2], "dmr1|import|" .. F.ALL_ALLOW, "multiplayer: sent like one switch")
eq(F.stopped("tP", "import", "iron"), true, "and changes nothing on its own")
ui_trigger(SENT[1][1], SENT[1][2]); eq(count("tP", "import"), 0, "the trigger applies it")
MP = false; SENT = {}
tP.partners, tQ.partners = {}, {}

-- ---- history ----------------------------------------------------------------------------
CCO_MADE = "derpy_mr_store_coal_stocked=6"
F.state.factions.hum = nil
h1.held, h2.held = { coal = 40 }, { coal = 2 }
raid(army(hum, a1, 12, 0))                                  -- something in the ledger
local raided = F.book("hum").now.coal.raided_in
LOC_CALLS = 0; TURN = 7; turn_start(hum)
-- a loc read from a turn handler CTD'd turn 1 of a fresh campaign; the snapshot reads no name
eq(LOC_CALLS, 0, "a human's turn start reads no localised text")
local bk = F.book("hum")
eq(bk.turns[1], 7, "the snapshot's turn"); eq(bk.total.coal[1], h1.held.coal + h2.held.coal, "realm total")
eq(bk.last.coal.raided_in, raided, "the ledger becomes last turn's"); eq(bk.last.coal.made, 12, "made, both settlements")
eq(next(bk.now), nil, "and a new ledger starts")
eq(#bk.total.salted_fish, 1, "every good gets a value each turn, so every series lines up")
local t, s = F.series("hum", "coal"); eq(t[1], 7, "series turns"); eq(s[1], bk.total.coal[1], "series totals")
eq(F.last("hum", "coal").made, 12, "last"); eq(next(F.last("nobody", "coal")), nil, "no book, no last")
local nobody = F.series("nobody", "coal"); eq(#nobody, 0, "no book, no series")
for i = 1, 25 do F.push(bk, 100 + i, { coal = i }, {}) end
eq(#bk.turns, 20, "twenty turns kept"); eq(bk.turns[1], 106, "the oldest dropped first")
eq(#bk.total.coal, 20, "the series trimmed with them"); eq(bk.total.coal[20], 25, "newest last")
eq(F.state.factions.tA, nil, "no history for a computer-run faction")

-- ---- save and load ----------------------------------------------------------------------
eq(cm.saving_game_callbacks[2], thrower, "our save callback went in ahead of another mod's")
eq(cm.loading_game_callbacks[2], thrower, "and so did our load callback")
SAVED = {}
pcall(function() for _, fn in ipairs(cm.saving_game_callbacks) do fn({}) end end)   -- CA's loop
eq(SAVED.derpy_mr_flows ~= nil, true, "a mod that throws after us cannot stop our save")
F.push(bk, 200, { coal = 7.6 }, { coal = 2.5 })   -- fractions in; none may reach the save
F.toggle("tP", "import", "salt")
local function whole(v, path)
    if type(v) == "number" then eq(math.floor(v), v, "every number saved is whole: " .. path)
    elseif type(v) == "table" then for k, x in pairs(v) do whole(x, path .. "." .. tostring(k)) end end
end
local ok_walk = pcall(whole, { 1.5 }, "planted"); eq(ok_walk, false, "the whole-number walk catches a fraction")
cm.saving_game_callbacks[1]({}); whole(SAVED.derpy_mr_flows, "state")
eq(SAVED.derpy_mr_flows.factions.hum.total.coal[20], 8, "7.6 is saved as 8")
F.state = { factions = {} }
cm.loading_game_callbacks[1]({})
eq(F.state.factions.hum.turns[#F.state.factions.hum.turns], 200, "history survives a save and load")
eq(F.state.rates.raid, 10, "and so do the rates")
eq(F.stopped("tP", "import", "salt"), true, "and so do the trade switches")
SAVED = {}
cm.loading_game_callbacks[1]({})
eq(next(F.state.factions), nil, "an old save starts an empty history"); eq(#ERRORS, 0, "without an error")

-- ---- rates: MCT, frozen, multiplayer ----------------------------------------------------
local MCT = {}
local function option()
    local o = {}
    function o:set_text() end
    function o:set_tooltip_text() end
    function o:slider_set_precision() end
    function o:slider_set_min_max() end
    function o:slider_set_step_size() end
    function o:set_assigned_section() end
    function o:set_default_value(v) self.value = v end
    function o:set_locked(v, why) self.locked, self.why = v, why end
    function o:get_finalized_setting() return self.value end
    return o
end
local MCT_API = {
    register_mod = function(_, k)
        local m = { options = {} }
        function m:set_title() end
        function m:set_author() end
        function m:set_description() end
        function m:add_new_section() end
        function m:add_new_option(key) local o = option(); self.options[key] = o; return o end
        function m:get_option_by_key(key) return self.options[key] end
        MCT[k] = m
        return m
    end,
    get_mod_by_key = function(_, k) return MCT[k] end,
}
get_mct = function() return MCT_API end
-- GREYED IN A CAMPAIGN, as the Guilds' and the Exchange's pages are: the values are frozen there
__lib_type_campaign, __game_mode = "campaign", "frontend"
dofile("__MCT__")
for k, o in pairs(MCT.derpy_more_resources.options) do eq(o.locked, nil, "the main menu leaves " .. k .. " open") end
__game_mode = "campaign"
dofile("__MCT__")
local opt = MCT.derpy_more_resources.options
for k, o in pairs(opt) do
    eq(o.locked, true, "a campaign greys " .. k); eq(type(o.why) == "string" and #o.why > 0, true, "and says why")
end
for k, d in pairs(DERPY_MR_FLOWS_DEFAULTS) do
    eq(opt[k] ~= nil, true, "the MCT file has an option for " .. k)
    eq(opt[k].value, d, "the MCT default for " .. k .. " is the script's")
end
F.state = { factions = {} }
opt.raid.value, opt.ai.value = 30, false
eq(F.rates().raid, 30, "a new campaign takes MCT's raid share")
eq(F.rates().ai, false, "an unticked box stays unticked")
-- A READ NEVER FREEZES: the panel reads the rates, and opening it before the freeze froze them there
eq(F.state.rates, nil, "reading the rates freezes nothing")
opt.raid.value = 35; eq(F.rates().raid, 35, "so an MCT change before the freeze still counts")
F.freeze_rates(); eq(F.state.rates and F.state.rates.raid, 35, "the freeze keeps what MCT says then")
opt.raid.value = 40; eq(F.rates().raid, 35, "frozen: a later MCT change does not reach a running campaign")
F.freeze_rates(); eq(F.rates().raid, 35, "and a second freeze does not move it")
F.state = { factions = {} }; F.on_faction_turn_start(faction("fz").iface)
eq(F.state.rates and F.state.rates.raid, 40, "a turn start freezes too (a save from before first tick froze)")
-- AT FIRST TICK: a new campaign fires no FactionTurnStart until turn 1 ends. F.init again, its
-- listeners dropped after, so nothing below fires twice
do local n_listeners = #LISTENERS
F.state = { factions = {} }; F.started = false; F.init()
for i = #LISTENERS, n_listeners + 1, -1 do LISTENERS[i] = nil end end
eq(F.state.rates and F.state.rates.raid, 40, "the first tick freezes the rates")
F.state = { factions = {} }; MP = true
eq(F.rates().raid, 10, "multiplayer takes the defaults"); eq(F.rates().ai, true, "all of them")
MP = false
-- A SAVE FROM BEFORE A SWITCH EXISTED: its frozen rates lack the key, and nil read as "off"
-- (measured live 2026-10-02: upkeep=nil, actions=nil, so phases 4 and 7 never ran in that save).
-- The missing key takes its value now and is frozen; the keys already there do not move.
opt.raid.value, opt.upkeep.value = 40, true
F.state = { factions = {}, rates = { raid = 25, sack = 50, raze = 50, trade = 5, ai = true } }
eq(F.rates().upkeep, true, "a switch added after the freeze takes its value")
eq(F.rates().actions, true, "every one of them")
eq(F.rates().raid, 25, "the frozen rates stay frozen")
F.freeze_rates()
opt.upkeep.value = false; eq(F.rates().upkeep, true, "and the new one is frozen too")
get_mct = nil; F.state.rates = nil; F.freeze_rates()
-- THE EVENTS ARE MEASURED ALONE, in their own section below, as the moves are
eq(F.rates().events, true, "events on by default"); F.state.rates.events = false
eq(F.rates().supply, true, "province supplies on by default"); F.state.rates.supply = false

-- ---- phase 4: settlements eat provisions; well-stocked stores give bonuses --------------
eq(F.rates().upkeep, true, "on by default")
local WF, GS, CF = "derpy_mr_well_fed", "derpy_mr_garrison_stocked", "derpy_mr_comforts"
local function has(r, b) return BUNDLES[r.key] ~= nil and BUNDLES[r.key][b] ~= nil end
local uF = faction("uF", { human = true })
local u1 = region("u1", 5000, 0, 200, { grain = 30, salt = 10, coal = 60, silk = 49 }); u1.level = 3
own(uF, u1, true)
turn_start(uF)
eq(u1.held.grain, 24, "a level-3 settlement eats 6, from its fullest provisions store first")
eq(u1.held.salt, 10, "and leaves the next one alone when the first covers it")
eq(F.book("uF").now.grain.eaten_out, 6, "booked as eaten, for the panel's last-turn line")
eq(has(u1, WF), true, "Well fed: 34 left, five turns' need is 30")
eq(BUNDLES.u1[WF], F.BUNDLE_TURNS, "for a short spell, renewed each turn, so a leftover lapses")
eq(has(u1, GS), true, "Garrison stocked: 60 war materials, a quarter of one store is 50")
eq(has(u1, CF), false, "no Comforts: 49 luxuries is under a quarter")
eq(u1.held.coal, 60, "war materials are not eaten"); eq(u1.held.silk, 49, "nor luxuries")
u1.held.coal, u1.held.silk = 10, 50; turn_start(uF)
eq(has(u1, GS), false, "Garrison stocked ends the turn the stock falls under a quarter")
eq(has(u1, CF), true, "Comforts at exactly a quarter")
-- the drawing rule: fullest first, then the next, until the need is met
local u2 = region("u2", 5100, 0, 200, { grain = 3, salt = 2, wine = 1 }); u2.level = 2; own(uF, u2)
turn_start(uF)
eq(u2.held.grain, 0, "fullest first, emptied"); eq(u2.held.salt, 1, "then the next, for what is left of the 4")
eq(u2.held.wine, 1, "and no further"); eq(has(u2, WF), false, "2 left is not five turns of 4")
-- a tie goes by the resource's key, so every machine eats the same
local u3 = region("u3", 5200, 0, 200, { mead = 5, beer = 5 }); u3.level = 3; own(uF, u3)
turn_start(uF)
eq(u3.held.beer, 0, "a tie: beer before mead"); eq(u3.held.mead, 4, "then mead for the rest")
-- the fullest store, not the first by name
local u6 = region("u6", 5250, 0, 200, { beer = 1, wine = 9 }); u6.level = 2; own(uF, u6)
-- Well fed is judged on what is left AFTER eating: 11 before, 9 after, five turns of 2 is 10
local u7 = region("u7", 5260, 0, 200, { grain = 11 }); u7.level = 1; own(uF, u7)
-- exactly a quarter of war materials is enough
local u8 = region("u8", 5270, 0, 200, { coal = 50 }); u8.level = 1; own(uF, u8)
turn_start(uF)
eq(u6.held.wine, 5, "wine, the fullest, is eaten first"); eq(u6.held.beer, 1, "beer is left alone")
eq(u7.held.grain, 9, "eaten"); eq(has(u7, WF), false, "and not Well fed on what it held before eating")
eq(has(u8, GS), true, "Garrison stocked at exactly a quarter")
-- short: everything eaten, no Well fed, nothing worse
local u4 = region("u4", 5300, 0, 200, { grain = 4 }); u4.level = 5; own(uF, u4)
BUNDLES.u4 = { [WF] = 2 }
turn_start(uF)
eq(u4.held.grain, 0, "a short store is eaten to nothing"); eq(has(u4, WF), false, "and Well fed is withdrawn at once")
local n4 = 0; for _ in pairs(BUNDLES.u4) do n4 = n4 + 1 end; eq(n4, 0, "being short brings no other bundle")
local u5 = region("u5", 5400, 0, 200, { grain = 40 }); u5.level = 0; own(uF, u5)
turn_start(uF); eq(u5.held.grain, 40, "no settlement level, nothing eaten"); eq(has(u5, WF), false, "and no Well fed")
-- daemons, the undead and Beastmen neither eat nor gain, and a bundle left from a former owner goes
local dF = faction("dF", { human = true, sc = "wh3_main_sc_kho_khorne" })
local d1 = region("d1", 5500, 0, 200, { grain = 50, coal = 100 }); d1.level = 2; own(dF, d1, true)
BUNDLES.d1 = { [WF] = 2, [GS] = 2 }
turn_start(dF)
eq(d1.held.grain, 50, "Khorne eats nothing"); eq(has(d1, WF), false, "and keeps no Well fed")
eq(has(d1, GS), false, "nor Garrison stocked")
local bF = faction("bF", { human = true, sc = "wh_dlc03_sc_bst_beastmen" })
local e1 = region("e1", 5600, 0, 200, { grain = 50 }); e1.level = 2; own(bF, e1, true)
turn_start(bF); eq(e1.held.grain, 50, "nor do the Beastmen")
-- other factions, under the switch
local aF = faction("aF")
local f1 = region("f1", 5700, 0, 200, { grain = 50 }); f1.level = 1; own(aF, f1, true)
F.state.rates.ai = false; turn_start(aF)
eq(f1.held.grain, 50, "switched off, other factions eat nothing"); eq(has(f1, WF), false, "and gain nothing")
F.state.rates.ai = true; turn_start(aF)
eq(f1.held.grain, 48, "switched on, they eat"); eq(has(f1, WF), true, "and are Well fed")
eq(F.state.factions.aF, nil, "with no ledger: only a player's panel reads it")
local before = u1.held.grain + u1.held.salt
F.state.rates.upkeep = false; turn_start(uF)
eq(u1.held.grain + u1.held.salt, before, "upkeep off: nothing eaten")
F.state.rates.upkeep = true
eq(#ERRORS, 0, "no script errors in the upkeep pass")

-- ---- phase 7: the panel's actions ------------------------------------------------------
eq(F.rates().actions, true, "on by default")
-- SEND HERE: from the fullest OTHER store, as much as arrives into the free space, 10% lost
local sP = faction("sP", { human = true })
local s1 = region("s1", 6000, 0, 200, { coal = 50 }); own(sP, s1, true)
local s2 = region("s2", 6100, 0, 200, { coal = 10 }); own(sP, s2)
local s3 = region("s3", 6200, 0, 200, { coal = 190 }); own(sP, s3)
local p = F.send_plan(sP.iface, "s3", "coal")
eq(p.from:name(), "s1", "from the fullest other store, never the target's own fuller one")
eq(p.n, 12, "the most whose arrival fits: 12 sent")
eq(p.got, 10, "12 less 2 lost (10% rounded up) = 10, the free space")
TURN = 20
F.request("sP", "send", "coal", "s3")
eq(s1.held.coal, 38, "the source loses what was sent at once"); eq(s3.held.coal, 190, "and nothing arrives yet")
eq(F.book("sP").now.coal.moved_out, 12, "booked out")
eq(F.send_plan(sP.iface, "s3", "coal"), nil, "what is on the road fills the free space: nothing more to send")
TURN = 21; turn_start(sP); eq(s3.held.coal, 190, "a turn on the road")
TURN = 22; turn_start(sP); eq(s3.held.coal, 200, "it arrives at the second turn start")
eq(F.book("sP").now.coal.moved_in, 10, "booked in")
eq(F.send_plan(sP.iface, "s3", "coal"), nil, "a full store: nothing to send")
local s4 = region("s4", 6300, 0, 200, {}); own(sP, s4)
s2.held.brass = 38
p = F.send_plan(sP.iface, "s4", "brass"); eq(p.n, 38, "an empty target: everything the source holds")
eq(p.got, 34, "38 less 4 (3.8 rounded up)")
local s5 = region("s5", 6400, 0, 200, { iron = 1 }); own(sP, s5)
eq(F.send_plan(sP.iface, "s4", "iron"), nil, "one unit would all be lost: no send")
eq(F.send_plan(sP.iface, "s4", "salt"), nil, "nobody holds it: no send")
eq(F.send_plan(sP.iface, "h1", "coal"), nil, "a settlement that is not yours: no send")
local s1_before = s1.held.coal
F.request("sP", "send", "coal", "h1"); eq(s1.held.coal, s1_before, "and the request moves nothing")
-- two equally full sources: the one whose key comes first, so every machine picks alike
local tP2 = faction("tP2", { human = true })
local t1 = region("t1", 6500, 0, 200, {}); own(tP2, t1, true)
local t2b = region("t2b", 6600, 0, 200, { coal = 20 }); own(tP2, t2b)
local t2a = region("t2a", 6700, 0, 200, { coal = 20 }); own(tP2, t2a)
eq(F.send_plan(tP2.iface, "t1", "coal").from:name(), "t2a", "a tie: the first key sends")
-- and a draw from two equally full stores takes the first key's first
F.draw_realm({ { region = t2b.iface, held = { coal = 20 } }, { region = t2a.iface, held = { coal = 20 } } },
             function(g) return g.stem == "coal" end, 20, "sold", nil)
eq(t2a.held.coal, 0, "a tie in a draw: the first key's store first"); eq(t2b.held.coal, 20, "the other untouched")
-- ORDERS: the cost drawn from the fullest stores realm-wide; then a 10-turn wait, kept in the save
local oP = faction("oP", { human = true })
local o1 = region("o1", 7000, 0, 400, { silk = 150 }); own(oP, o1, true)
local o2 = region("o2", 7100, 0, 400, { jade = 100, coal = 30 }); own(oP, o2)
local st = F.order_state(oP.iface, "festival")
eq(st.ok, true, "250 luxuries: Festival can be bought"); eq(st.have, 250, "and says how many are held")
TURN = 40
F.request("oP", "order", "festival")
eq(o1.held.silk, 0, "silk, the fullest, paid first"); eq(o2.held.jade, 50, "jade the rest of 200")
eq(FBUNDLES.oP.derpy_mr_order_festival, 5, "Festival for 5 turns")
eq(F.book("oP").now.silk.spent_out, 150, "booked as spent")
o1.held.silk = 300
st = F.order_state(oP.iface, "festival"); eq(st.ok, false, "bought this turn: not again")
eq(st.active, 5, "and running for 5 turns")
eq(st.wait, 10, "ready in 10 turns")
F.request("oP", "order", "festival"); eq(o1.held.silk, 300, "and a request does nothing")
local bought = TURN
TURN = bought + 4; eq(F.order_state(oP.iface, "festival").active, 1, "its last turn running")
TURN = bought + 5; eq(F.order_state(oP.iface, "festival").active, nil, "over after 5 turns")
TURN = 49; eq(F.order_state(oP.iface, "festival").wait, 1, "a turn to go")
TURN = 50; eq(F.order_state(oP.iface, "festival").ok, true, "ready after 10 turns")
st = F.order_state(oP.iface, "muster"); eq(st.ok, false, "30 war materials is short of 200"); eq(st.have, 30, "says so")
F.request("oP", "order", "muster"); eq(o2.held.coal, 30, "a short order takes nothing")
eq(FBUNDLES.oP.derpy_mr_order_muster, nil, "and gives nothing")
F.request("oP", "order", "no_such_order"); eq(#ERRORS, 0, "an unknown order is ignored")
cm.saving_game_callbacks[1]({})
eq(SAVED.derpy_mr_flows.factions.oP.orders.festival, 40, "the last purchase is kept in the save")
-- SELL: the surplus above half the realm's space, fullest store first
local lP = faction("lP", { human = true })
local l1 = region("l1", 8000, 0, 200, { coal = 180 }); own(lP, l1, true)
local l2 = region("l2", 8100, 0, 200, { coal = 20 }); own(lP, l2)
eq(F.sale(lP.iface, "coal"), nil, "200 held in 400 space: exactly half, nothing to sell")
l1.held.coal = 190
local sale = F.sale(lP.iface, "coal")
eq(sale.n, 10, "10 above half"); eq(sale.price, 3, "war materials at 3 gold without the Exchange")
eq(sale.gold, 30, "30 gold")
F.request("lP", "sell", "coal")
eq(l1.held.coal, 180, "taken from the fullest store"); eq(l2.held.coal, 20, "not the other")
eq(TREASURY.lP, 30, "and paid"); eq(F.book("lP").now.coal.sold_out, 10, "booked as sold")
F.request("lP", "sell", "coal"); eq(TREASURY.lP, 30, "nothing left to sell, nothing paid")
l1.held.coal = 190
-- THE EXCHANGE AS IT IS: sell_price is a LOT's price (EX.lot units), and it reads the houses' stance
-- toward EX.who() - the local player unless EX.with_player binds another (zzz_derpy_chd_exchange.lua)
do
local function ex_stub(price_for)
    local X = { subject = nil }
    function X.lot() return 10 end
    function X.with_player(f, fn)
        local prev = X.subject; X.subject = f
        local ok = pcall(fn); X.subject = prev
        return ok
    end
    function X.sell_price(res) return price_for(res, X.subject) end
    return X
end
EX = ex_stub(function(res, who) eq(res, "res_derpy_coal", "asked by resource key"); return who == "lP" and 510 or 99999 end)
local xs = F.sale(lP.iface, "coal")
eq(xs.price, 51, "a lot of 10 at 510 is 51 a unit, not 510 (paid 10x before)")
eq(xs.gold, 510, "the Exchange's price for the SELLER, whoever's machine runs it")
EX = ex_stub(function() error("the Exchange broke") end)
eq(F.sale(lP.iface, "coal").price, 3, "the fixed rate when it errors")
EX = ex_stub(function() return 0 end); eq(F.sale(lP.iface, "coal").price, 3, "or prices at nothing")
EX = nil
end
-- EVERY ACTION GOES THROUGH UITrigger in multiplayer; computer factions and the switch refuse
MP = true; SENT = {}
F.request("lP", "sell", "coal")
eq(SENT[1][2], "dmr1|sell|coal", "multiplayer: sent, not run"); eq(TREASURY.lP, 30, "nothing paid yet")
ui_trigger(SENT[1][1], SENT[1][2]); eq(TREASURY.lP, 60, "the trigger runs it")
F.request("sP", "send", "brass", "s4"); eq(SENT[2][2], "dmr1|send|brass|s4", "a send carries the settlement")
ui_trigger(lP.cqi, SENT[2][2]); eq(s4.held.brass or 0, 0, "another player's trigger cannot move my resources")
ui_trigger(sP.cqi, SENT[2][2]); eq(s2.held.brass, 0, "my own does: it leaves for the road")
s2.held.brass = 20
ui_trigger(sP.cqi, "dmr1|send|brass|s4|extra|parts"); eq(s2.held.brass, 20, "a trigger with extra parts is ignored")
ui_trigger(sP.cqi, "dmr1|send|brass"); eq(s2.held.brass, 20, "and one with too few")
eq(F.parse("dmr1|sell|co al"), nil, "a part that is not a key is refused whole")
eq(F.parse("dmr1|sell|coal")[2], "coal", "a good one parses"); eq(#ERRORS, 0, "no errors from malformed triggers")
MP = false; SENT = {}
a1.held.coal = 300
F.dispatch("ai1", { "sell", "coal" }); eq(TREASURY.ai1, nil, "a computer-run faction has no panel")
eq(a1.held.coal, 300, "and sells nothing")
F.state.rates.actions = false
l1.held.coal = 190; F.request("lP", "sell", "coal"); eq(TREASURY.lP, 60, "switched off: no sale")
F.request("lP", "export", "coal"); eq(F.stopped("lP", "export", "coal"), true, "but trade switches still work")
F.state.rates.actions = true
eq(#ERRORS, 0, "no script errors in the actions")

-- ---- phase 6: store events --------------------------------------------------------------
-- A full store offers a choice at its owner's turn start: a player gets a dilemma and the spend
-- and reward happen when it is answered; a computer-run faction takes the same deal on a roll.
-- At most one per faction every EVENT_GAP turns.
F.state.rates.events = true
local EV = DERPY_MR_FLOWS_EVENTS
local function answer(f, key, choice)
    fire("DilemmaChoiceMadeEvent", { dilemma = function() return key end, choice_key = function() return choice end,
                                     faction = function() return f.iface end })
end
local function only(key)
    eq(#DILEMMAS, 1, "one dilemma"); eq(DILEMMAS[1].key, EV[key].dilemma, "the " .. key .. " dilemma")
end
-- FEAST: a settlement holding the cost in provisions
TURN = 100; DILEMMAS = {}
local vP = faction("vP", { human = true })
local v1 = region("v1", 9000, 0, 400, { grain = 70, salt = 40 }); v1.level = 0; own(vP, v1, true)
turn_start(vP)
only("feast"); eq(DILEMMAS[1].fcqi, vP.cqi, "offered to its owner"); eq(DILEMMAS[1].region, v1.iface:cqi(), "naming the settlement")
eq(v1.held.grain, 70, "nothing is spent before the answer")
answer(vP, EV.feast.dilemma, "FIRST")
eq(v1.held.grain + v1.held.salt, 110 - EV.feast.cost, "accepting spends the cost in provisions there")
eq(v1.held.grain, 0, "fullest first")
eq(BUNDLES.v1[EV.feast.bundle], EV.feast.turns, "and the feast's bundle for its turns")
eq(F.book("vP").now.grain.spent_out, 70, "booked as spent")
answer(vP, EV.feast.dilemma, "FIRST"); eq(v1.held.salt, 10, "an answer with nothing pending does nothing")
-- the gap: conditions hold again, but not for EVENT_GAP turns
v1.held.grain = 150; DILEMMAS = {}
TURN = 100 + DERPY_MR_FLOWS_EVENT[1] - 1; turn_start(vP); eq(#DILEMMAS, 0, "no second event inside the gap")
TURN = 100 + DERPY_MR_FLOWS_EVENT[1]; turn_start(vP); only("feast")
answer(vP, EV.feast.dilemma, "SECOND")
eq(v1.held.grain, 150, "declining spends nothing"); eq(BUNDLES.v1[EV.feast.bundle], EV.feast.turns, "and adds nothing new")
-- the gap counts from the offer, answered or not
DILEMMAS = {}; TURN = TURN + 1; turn_start(vP); eq(#DILEMMAS, 0, "a declined offer still starts the gap")
-- SHORT AT THE ANSWER: whatever was spent meanwhile, a short store pays nothing and gets nothing
TURN = 300; DILEMMAS = {}; turn_start(vP); only("feast")
v1.held.grain, v1.held.salt = 30, 0; BUNDLES.v1 = {}
answer(vP, EV.feast.dilemma, "FIRST")
eq(v1.held.grain, 30, "short at the answer: nothing taken"); eq(BUNDLES.v1[EV.feast.bundle], nil, "nothing given")
-- SIEGE STORES before anything else, for a settlement under siege
TURN = 500; DILEMMAS = {}
local v2 = region("v2", 9100, 0, 400, { grain = 200 }); v2.level = 0; own(vP, v2)
v1.held.grain = 60; v1.siege = true
turn_start(vP); only("siege"); eq(DILEMMAS[1].region, v1.iface:cqi(), "the besieged settlement, not the fuller one")
answer(vP, EV.siege.dilemma, "FIRST")
eq(v1.held.grain, 60 - EV.siege.cost, "its own provisions pay"); eq(BUNDLES.v1[EV.siege.bundle], EV.siege.turns, "for its turns")
eq(v2.held.grain, 200, "the other settlement is untouched")
v1.siege = false
-- TRIBUTE: luxuries across the realm and a neighbour at peace, named in the dilemma
local wP = faction("wP", { human = true })
local nA = faction("nA"); local nB = faction("nB")
local w1 = region("w1", 9500, 0, 400, { silk = 30 }); w1.level = 0; own(wP, w1, true)
local w2 = region("w2", 9600, 0, 400, { jade = 30 }); w2.level = 0; own(wP, w2)
local wa = region("wa", 9700, 0, 400, {}); own(nA, wa, true)
local wb = region("wb", 9800, 0, 400, {}); own(nB, wb, true)
w1.adj = { wb, w2 }; w2.adj = { wa, w1 }; war(wP, nA)
TURN = 600; DILEMMAS = {}; turn_start(wP)
only("tribute"); eq(DILEMMAS[1].faction, nB.cqi, "the neighbour at peace, not the one at war")
answer(wP, EV.tribute.dilemma, "FIRST")
eq(w1.held.silk + w2.held.jade, 60 - EV.tribute.cost, "spent from the realm's luxuries")
eq(DIPLO[1][1], "wP", "the giver acts"); eq(DIPLO[1][2], "nB", "the neighbour's regard moves")
eq(DIPLO[1][3] > 0, true, "upwards")
w1.adj, w2.adj = {}, {}
-- ARSENAL: war materials across the realm, for the largest army, by its general
-- a character: a lord with an army (mf) or a hero without one (named recipes, section 4b/4c)
local function character(cqi, f, mf)
    local c = { traits = {} }
    local agent = mf and "general" or "champion"   -- a lord leads an army; a hero does not
    c.iface = {
        is_null_interface = function() return false end,
        command_queue_index = function() return cqi end,
        faction = function() return f.iface end,
        has_military_force = function() return mf ~= nil end,
        -- CA's scripts ask has_military_force first: the stub refuses an unguarded read
        military_force = function() if not mf then error("military_force of a character with none") end return mf end,
        has_trait = function(_, t) return c.traits[t] == true end,
        character_type = function(_, t) return t == agent end,
    }
    CHARS[cqi] = c
    return c
end
local function host(cqi, units, kind)
    local mf = { is_null_interface = function() return false end, is_armed_citizenry = function() return kind == "garrison" end,
                 has_general = function() return true end,
                 force_type = function() return { key = function() return kind or "ARMY" end } end,
                 command_queue_index = function() return cqi + 1000 end,
                 unit_list = function() return list(units) end,
                 general_character = function() return { command_queue_index = function() return cqi end } end }
    return mf
end
local xP = faction("xP", { human = true })
local x1 = region("x1", 10000, 0, 400, { coal = 30, iron = 30 }); x1.level = 0; own(xP, x1, true)
xP.armies = { host(71, { 1, 2, 3 }), host(72, { 1, 2, 3, 4, 5, 6, 7, 8 }, "garrison"),
              host(73, { 1, 2, 3, 4, 5 }), host(74, { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, "CONVOY") }
TURN = 700; DILEMMAS = {}; turn_start(xP)
only("arsenal"); eq(DILEMMAS[1].character, 73, "the largest army, never a garrison or a convoy")
eq(DILEMMAS[1].force, 1073, "with its force")
answer(xP, EV.arsenal.dilemma, "FIRST")
eq(x1.held.coal + x1.held.iron, 60 - EV.arsenal.cost, "spent from war materials")
eq(RANKS[1][1], "character_cqi:73", "its units gain"); eq(RANKS[1][2], 1, "one rank")
-- NOTHING QUALIFIES: no dilemma, and no gap started
local yP = faction("yP", { human = true })
local y1 = region("y1", 11000, 0, 400, { grain = 99, coal = 49 }); y1.level = 0; own(yP, y1, true)
TURN = 800; DILEMMAS = {}; turn_start(yP); eq(#DILEMMAS, 0, "99 provisions and 49 war materials: nothing")
y1.held.grain = 100; turn_start(yP); only("feast")
-- NEVER ISSUED (CA's wrapper returns false in multiplayer): no offer waits and no gap starts
TURN = 1500; DILEMMA_FAILS = true; F.state.pending = nil; DILEMMAS = {}; turn_start(yP)
eq(F.pending("yP", "feast"), nil, "an event never issued leaves no offer")
DILEMMA_FAILS = nil; turn_start(yP); only("feast")
-- COMPUTER-RUN FACTIONS: no dilemma; the same deal on a roll of EVENT_AI_PCT or under
local zA = faction("zA")
local z1 = region("z1", 12000, 0, 400, { grain = 150 }); z1.level = 0; own(zA, z1, true)
TURN = 900; DILEMMAS = {}; ROLL = DERPY_MR_FLOWS_EVENT[2] + 1; turn_start(zA)
eq(#DILEMMAS, 0, "no dilemma for a computer"); eq(z1.held.grain, 150, "and a failed roll takes nothing")
ROLL = DERPY_MR_FLOWS_EVENT[2]; turn_start(zA)
eq(#DILEMMAS, 0, "still no dilemma"); eq(z1.held.grain, 150 - EV.feast.cost, "a winning roll spends")
eq(BUNDLES.z1[EV.feast.bundle], EV.feast.turns, "and rewards")
z1.held.grain = 150; turn_start(zA); eq(z1.held.grain, 150, "and starts the gap")
eq(F.state.factions.zA, nil, "with no ledger: only a player's panel reads it")
F.state.rates.ai = false; TURN = 2000; turn_start(zA); eq(z1.held.grain, 150, "the AI switch stops it")
F.state.rates.ai = true
-- THE SWITCH, and the save
F.state.rates.events = false; TURN = 3000; DILEMMAS = {}; turn_start(yP); eq(#DILEMMAS, 0, "switched off: no events")
F.state.rates.events = true; turn_start(yP); only("feast")
cm.saving_game_callbacks[1]({})
eq(SAVED.derpy_mr_flows.pending.yP.feast.key, "feast", "an unanswered offer is kept in the save")
-- another mod's dilemma is not ours
answer(yP, "someone_elses_dilemma", "FIRST"); eq(y1.held.grain, 100, "another dilemma's answer moves nothing")
ROLL = 100
F.state.rates.events = false
eq(#ERRORS, 0, "no script errors in the events: " .. table.concat(ERRORS, "; "))

-- ---- phase 5: province supplies and shipments -------------------------------------------
-- Three switches per province, paid each turn from the province capital's store; Supply the
-- capital ships the short use there; Send here is a two-turn shipment drawn as a map marker that
-- an army at war with its owner can seize.
F.state.rates.supply = true
local SP, SH = DERPY_MR_FLOWS_SUPPLY, DERPY_MR_FLOWS_SHIP
eq(F.rates().ships, 3, "three shipments on the road by default")
local function inprov(pk, cap, ...)
    for _, r in ipairs({ cap, ... }) do r.prov, r.capital = pk, cap end
end
local function ships_of(k)
    local n = 0
    for _, s in ipairs(F.state.ships or {}) do if s.f == k then n = n + 1 end end
    return n
end
local function last_ship() return F.state.ships[#F.state.ships] end
local function field(f, x, y, cqi, garrison)
    return { is_armed_citizenry = function() return garrison == true end,
             has_general = function() return true end,
             force_type = function() return { key = function() return "ARMY" end } end,
             command_queue_index = function() return cqi + 1000 end,
             unit_list = function() return list({ 1 }) end,
             general_character = function() return {
                 command_queue_index = function() return cqi end,
                 logical_position_x = function() return x end,
                 logical_position_y = function() return y end } end }
end
local function enter(id, ch)
    fire("AreaEntered", { area_key = function() return id end,
                          family_member = function() return { character = function() return ch end } end })
end
local function walker(f, armed)
    return { is_null_interface = function() return false end, faction = function() return f.iface end,
             has_military_force = function() return armed end }
end
local function bundled(r, k) return BUNDLES[r.key] ~= nil and BUNDLES[r.key][SP[k].bundle] ~= nil end

-- THE SWITCHES: 2 a turn for each settlement you hold in the province, from the capital only
TURN = 4000
local pP = faction("pP", { human = true })
local pc = region("pc", 20000, 0, 400, { timber = 30, marble = 4 }); pc.level = 0
local po = region("po", 20010, 0, 400, { timber = 100 }); po.level = 0
local px = region("px", 20020, 0, 400, {}); px.level = 0
local eP = faction("eP")
own(pP, pc, true); own(pP, po); own(eP, px, true)
inprov("prov_p", pc, po, px)
eq(F.supply_state(pP.iface, "po"), nil, "only the province capital carries the switches")
eq(table.concat(F.capitals(pP.iface), ","), "pc", "the Spending tab lists the capital, not the other settlement")
local st5 = F.supply_state(pP.iface, "pc")
eq(st5.cost, SH.per * 2, "2 for each of the 2 settlements you hold there, not the one you do not")
eq(st5.on.materials, nil, "every switch starts off"); eq(st5.on.standing, nil, "and so does Supply the capital")
-- WHAT EACH SUPPLY PAYS WITH (asked 2026-10-03): the good the payment takes first - the fullest,
-- a tie by stem, as F.draw_realm takes them - for the Spending tab's icon
eq(st5.pay.building.stem, "timber", "Materials pays with the fullest building material")
eq(st5.pay.building.n, 30, "and says how much of it there is")
eq(st5.pay.mounts.n, 0, "a use the capital holds none of still names a good")
eq(type(st5.pay.mounts.stem), "string", "so the tab has an icon to grey")
-- iron and whale oil sort apart by stem and by resource key (res_rom_iron / res_derpy_whale_oil):
-- the icon named whale oil while the payment took iron
pc.held.marble = 30
eq(F.supply_state(pP.iface, "pc").pay.building.stem, "marble", "a tie goes by stem")
do local iron0, oil0 = pc.held.iron, pc.held.whale_oil
pc.held.iron, pc.held.whale_oil = 300, 300
eq(F.supply_state(pP.iface, "pc").pay.war.stem, "iron", "a tie goes by stem, as the payment takes it")
F.draw(pc.iface, F.stock(pc.iface), "war", 1, DERPY_MR_FLOWS_KIND.spend, "pP")
eq(pc.held.iron, 299, "and the payment does take that one"); eq(pc.held.whale_oil, 300, "not the other")
pc.held.iron, pc.held.whale_oil, pc.held.marble = iron0, oil0, 4 end
F.request("pP", "supply", "pc", "materials")
eq(F.supply_state(pP.iface, "pc").on.materials, true, "a click turns it on")
eq(pc.held.timber, 30, "and takes nothing before turn start")
turn_start(pP)
eq(pc.held.timber, 26, "paid from the capital's fullest building material")
eq(pc.held.marble, 4, "only as far as needed"); eq(po.held.timber, 100, "never from another settlement")
eq(bundled(pc, "materials"), true, "the capital gets Materials on hand")
eq(BUNDLES.pc[SP.materials.bundle], F.BUNDLE_TURNS, "renewed each turn, like the stores' other bonuses")
eq(bundled(po, "materials"), true, "so does every settlement you hold in the province")
eq(bundled(px, "materials"), false, "not one you do not hold")
eq(bundled(pc, "stable"), false, "and no switch that is off")
eq(F.book("pP").now.timber.spent_out, 4, "booked as spent")
-- SHORT: nothing taken, the switch turns itself off, and the turn is kept for the tooltip
pc.held.timber, pc.held.marble = 3, 0
TURN = 4001; turn_start(pP)
eq(pc.held.timber, 3, "short: nothing taken")
st5 = F.supply_state(pP.iface, "pc")
eq(st5.on.materials, nil, "the switch turns itself off"); eq(st5.short.materials, 4001, "and says when")
eq(bundled(pc, "materials"), false, "the bundle goes at once"); eq(bundled(po, "materials"), false, "everywhere")
F.request("pP", "supply", "pc", "materials")
eq(F.supply_state(pP.iface, "pc").short.materials, nil, "switching it on again clears the note")
F.request("pP", "supply", "pc", "materials")
eq(F.supply_state(pP.iface, "pc").on.materials, nil, "a second click turns it off")
-- each switch pays its own use
pc.held = { timber = 10, warhorses = 10, iron = 10 }
for _, k in ipairs({ "materials", "stable", "arms" }) do F.request("pP", "supply", "pc", k) end
TURN = 4002; turn_start(pP)
eq(pc.held.timber, 6, "Materials on hand from building materials")
eq(pc.held.warhorses, 6, "Stable stocked from mounts"); eq(pc.held.iron, 6, "Arms stocked from war materials")
eq(bundled(po, "stable") and bundled(po, "arms"), true, "all three on every settlement")
-- refusals
F.request("pP", "supply", "po", "arms"); eq(F.state.supply.pP.prov_p.arms, true, "not a capital: changes nothing")
F.request("pP", "supply", "pc", "nonsense"); eq(#ERRORS, 0, "an unknown switch is ignored")
F.request("pP", "supply", "px", "arms"); eq(F.state.supply.pP.prov_p.arms, true, "a capital that is not yours: nothing")
local ex = region("ex", 20030, 0, 400, { iron = 50 }); own(eP, ex)
eq(F.supply_state(eP.iface, "ex") ~= nil, true, "the computer's own capital has switches")
F.dispatch("eP", { "supply", "ex", "arms" }); eq(F.state.supply.eP, nil, "but a computer-run faction has no panel")
-- no stores to use (daemons, the undead, Beastmen): no switches at all
local kP = faction("kP", { human = true, sc = "wh3_main_sc_kho_khorne" })
local k1 = region("k1", 20040, 0, 400, { timber = 100 }); own(kP, k1, true)
eq(F.supply_state(kP.iface, "k1"), nil, "Khorne keeps no stores to supply from: no switches")
eq(#F.capitals(kP.iface), 0, "and no Spending tab rows")
F.request("kP", "supply", "k1", "materials"); eq(F.state.supply.kP, nil, "and a click changes nothing")
-- the capital lost: nothing paid, the bundles go
lose(pP, pc); own(eP, pc)
po.held.iron = 50
TURN = 4003; turn_start(pP)
eq(bundled(po, "arms"), false, "the capital lost: no bundle left in the province")
eq(po.held.iron, 50, "and nothing paid from elsewhere")
lose(eP, pc); own(pP, pc)
F.request("pP", "supply", "pc", "stable"); F.request("pP", "supply", "pc", "arms")

-- SUPPLY THE CAPITAL: under five turns of a switched-on cost, the fullest other settlement in the
-- province ships enough for ten
pc.held = { timber = 15 }; po.held = { timber = 100, marble = 50 }
F.request("pP", "supply", "pc", "standing")
TURN = 4010; turn_start(pP)
local s5 = last_ship()
eq(ships_of("pP"), 1, "a shipment leaves"); eq(s5.from, "po", "from the other settlement")
eq(s5.to, "pc", "to the capital"); eq(s5.stem, "timber", "its fullest building material")
eq(s5.due, 4010 + SH.turns, "due two turns on, for the panel")
eq(po.held.timber, 75, "25 sent at once: ten turns of 4, less the 15 held")
eq(s5.n, 22, "22 on the road: a tenth of 25, rounded up, is lost")
eq(pc.held.timber, 11, "the capital still pays this turn")
eq(MARKERS[s5.id].info, SH.info, "drawn as a shipment marker"); eq(MARKERS[s5.id].r, SH.radius, "of its radius")
eq(MARKERS[s5.id].x, po.x + 1, "beside the sender, where CA finds a spot")
eq(MARKERS[s5.id].f, "", "any faction can walk into it")
TURN = 4011; turn_start(pP)
eq(ships_of("pP"), 1, "one already on the road for it: no second")
eq(MARKERS[s5.id].x, pc.x + 1, "the second turn: beside the capital")
eq(s5.x, pc.x + 1, "and the shipment is where its marker is"); eq(pc.held.timber, 7, "paid")
pc.held.timber = 2
TURN = 4012; turn_start(pP)
eq(ships_of("pP"), 0, "arrived"); eq(MARKERS[s5.id], nil, "its marker gone")
eq(pc.held.timber, 2 + 22 - 4, "it arrives before the turn's payment, which 2 alone could not make")
eq(F.supply_state(pP.iface, "pc").on.materials, true, "so the supply stays on")
eq(F.book("pP").now.timber.moved_in, 22, "booked as moved in")
-- the order is the player's: off, nothing ships
pc.held.timber = 15; F.request("pP", "supply", "pc", "standing")
TURN = 4020; turn_start(pP); eq(ships_of("pP"), 0, "Supply the capital off: nothing ships")
-- the fullest of the OTHER settlements, never the capital's own store however full it is
pc.held = { timber = 15 }; po.held = { marble = 10 }
F.request("pP", "supply", "pc", "standing")
TURN = 4030; turn_start(pP)
eq(last_ship().from, "po", "never from the capital itself"); eq(last_ship().stem, "marble", "the other's marble")
F.request("pP", "supply", "pc", "standing")

-- THE CAP: at most F.rates().ships on the road for a player
local cP = faction("cP", { human = true })
local c1 = region("c1", 21000, 0, 400, { coal = 10, iron = 10, brass = 10 }); own(cP, c1, true)
local c2 = region("c2", 21010, 0, 400, {}); own(cP, c2)
F.state.rates.ships = 2
TURN = 4100
F.request("cP", "send", "coal", "c2"); F.request("cP", "send", "iron", "c2")
eq(ships_of("cP"), 2, "two on the road")
eq(F.send_plan(cP.iface, "c2", "brass").busy, true, "the third is refused, and the plan says why")
F.request("cP", "send", "brass", "c2"); eq(c1.held.brass, 10, "and nothing leaves")
eq(#F.ships_to("cP", "c2", "coal"), 1, "the store can list what is coming to it")
F.state.rates.ships = 3

-- SEIZED AT TURN START: an army of a faction at war with the owner, within reach of the marker
local gP = faction("gP", { human = true })
local g1 = region("g1", 22000, 0, 400, { coal = 50 }); own(gP, g1, true)
local g2 = region("g2", 22100, 0, 400, {}); own(gP, g2)
local rA = faction("rA"); local rr = region("rr", 22200, 0, 400, {}); own(rA, rr, true)
local fA = faction("fA")
war(gP, rA)
TURN = 5000; F.request("gP", "send", "coal", "g2")
local gs = last_ship()
fA.armies = { field(fA, gs.x, gs.y, 501) }
rA.armies = { field(rA, gs.x + SH.near + 1, gs.y, 502), field(rA, gs.x, gs.y, 503, true) }
TURN = 5001; turn_start(gP)
eq(ships_of("gP"), 1, "nobody at war in reach, and a garrison does not ride out: on its way")
rA.armies = { field(rA, gs.x, gs.y + SH.near, 504) }
TURN = 5002; turn_start(gP)
eq(ships_of("gP"), 0, "seized"); eq(g2.held.coal or 0, 0, "it never arrives")
eq(rr.held.coal, 45, "the captor's nearest settlement gets the cargo")
eq(MARKERS[gs.id], nil, "the marker goes"); eq(F.state.factions.rA, nil, "a computer keeps no ledger")
rA.armies = {}
-- SEIZED BY WALKING IN: AreaEntered, an army only, at war only
g1.held.coal = 50; TURN = 5100; F.request("gP", "send", "coal", "g2"); gs = last_ship()
enter(gs.id, walker(gP, true)); eq(ships_of("gP"), 1, "its owner's own army passes")
enter(gs.id, walker(fA, true)); eq(ships_of("gP"), 1, "a faction at peace passes")
enter(gs.id, walker(rA, false)); eq(ships_of("gP"), 1, "a hero alone does not seize")
enter("someone_elses_marker", walker(rA, true)); eq(ships_of("gP"), 1, "another marker is not ours")
enter(gs.id, walker(rA, true)); eq(ships_of("gP"), 0, "an army at war seizes it")
eq(rr.held.coal, 90, "into the captor's settlement"); eq(MARKERS[gs.id], nil, "and the marker goes")
-- a captor with no settlement destroys it
local hB = faction("hB"); war(gP, hB)
g1.held.coal = 50; F.request("gP", "send", "coal", "g2"); gs = last_ship()
local coal_before = g1.held.coal + (g2.held.coal or 0) + rr.held.coal
enter(gs.id, walker(hB, true)); eq(ships_of("gP"), 0, "a horde seizes it")
eq(g1.held.coal + (g2.held.coal or 0) + rr.held.coal, coal_before, "and it is lost: no refund, nobody else gets it")
eq(#ERRORS, 0, "no error from a captor with no settlement")
-- THE DESTINATION LOST: the owner's settlement nearest it takes the cargo
g1.held.coal = 50; TURN = 5200; F.request("gP", "send", "coal", "g2")
lose(gP, g2)
TURN = 5202; turn_start(gP)
eq(g1.held.coal, 45, "back to the nearest settlement still held"); own(gP, g2)
-- CA FINDS NO SPOT: the settlement's own position
SPAWN_FAIL = true; g1.held.coal = 50; TURN = 5300; F.request("gP", "send", "coal", "g2"); gs = last_ship()
eq(MARKERS[gs.id].x, g1.x, "on the settlement itself"); SPAWN_FAIL = false
-- A DEAD OWNER: its shipment is cleared at a player's turn start
local dP = faction("dP", { human = true })
local d5 = region("d5", 24000, 0, 400, { coal = 50 }); own(dP, d5, true)
local d6 = region("d6", 24010, 0, 400, {}); own(dP, d6)
F.request("dP", "send", "coal", "d6"); local ds = last_ship()
dP.dead = true; dP.human = false
TURN = 5302; turn_start(gP)
eq(ships_of("dP"), 0, "a dead faction's shipment is cleared"); eq(MARKERS[ds.id], nil, "with its marker")

-- COMPUTER-RUN FACTIONS: a switch goes on with ten turns of its cost in the capital, Supply the
-- capital always runs, and at most 1 shipment is on the road
local qA = faction("qA")
local q1 = region("q1", 23000, 0, 400, { timber = 39 }); q1.level = 0
local q2 = region("q2", 23010, 0, 400, { timber = 200, warhorses = 200 }); q2.level = 0
own(qA, q1, true); own(qA, q2); inprov("prov_q", q1, q2)
TURN = 6000; turn_start(qA)
eq(q1.held.timber, 39, "under ten turns of 4: not switched on")
q1.held.timber, q1.held.warhorses = SH.ai_on * 4, SH.ai_on * 4
TURN = 6001; turn_start(qA)
eq(q1.held.timber, SH.ai_on * 4 - 4, "ten turns of it: switched on and paid")
eq(bundled(q2, "materials"), true, "on every settlement it holds there")
q1.held.timber, q1.held.warhorses = 15, 15
TURN = 6002; turn_start(qA)
eq(ships_of("qA"), 1, "short of five turns: one shipment, and only one on the road")
eq(last_ship().stem, "timber", "the first short use in switch order")
F.state.rates.ai = false; q1.held.timber = 100
TURN = 6003; turn_start(qA); eq(q1.held.timber, 100, "the switch for other factions stops it")
F.state.rates.ai = true

-- MULTIPLAYER: a switch is a UITrigger like every other action
MP = true; SENT = {}
F.request("pP", "supply", "pc", "arms")
eq(SENT[1][2], "dmr1|supply|pc|arms", "sent, not run")
MP = false; SENT = {}
-- THE MCT SWITCH: off, nothing toggles and nothing is paid
F.state.rates.supply = false
local before5 = F.supply_state(pP.iface, "pc").on.arms
F.request("pP", "supply", "pc", "arms"); eq(F.supply_state(pP.iface, "pc").on.arms, before5, "off: no toggle")
pc.held.iron = 50; TURN = 7000; turn_start(pP); eq(pc.held.iron, 50, "and nothing paid")
F.state.rates.supply = true
-- THE SAVE
g1.held.coal = 50; F.request("gP", "send", "coal", "g2")
cm.saving_game_callbacks[1]({})
eq(SAVED.derpy_mr_flows.supply.pP.prov_p.materials, true, "the switches are kept in the save")
eq(SAVED.derpy_mr_flows.ships[#SAVED.derpy_mr_flows.ships].f, "gP", "and the shipments on the road")
F.state.rates.supply = false
eq(#ERRORS, 0, "no script errors in phase 5: " .. table.concat(ERRORS, "; "))

-- ---- phase 6, part 2: Restore on capture ------------------------------------------------
-- Occupying a settlement whose captured stores hold the cost in building materials offers a
-- choice: spend them to repair every building there, with a spell of public order. A dilemma,
-- not an occupation option (TRADE_RESOURCES.md 27).
F.state.rates.events = true
local RS = DERPY_MR_FLOWS_EVENTS.restore
local function slot() return { has_building = function() return true end } end
local oP = faction("oPr", { human = true })
local o0 = region("o0", 30000, 0, 400, {}); own(oP, o0, true)
local oV = faction("oVr")
local ot = region("ot", 30010, 0, 400, { timber = 70, marble = 40, coal = 50 }); own(oV, ot, true)
ot.slots = { slot(), slot(), slot() }
war(oP, oV)
TURN = 8000; DILEMMAS = {}; REPAIRED = {}
lose(oV, ot); own(oP, ot)                             -- the engine hands it over, then the event fires
decide("occupation_decision_occupy", ot, oP, "oVr")
eq(#DILEMMAS, 1, "occupying a settlement with the cost in building materials offers Restore")
eq(DILEMMAS[1].key, RS.dilemma, "the Restore dilemma"); eq(DILEMMAS[1].region, ot.iface:cqi(), "naming the settlement")
eq(DILEMMAS[1].fcqi, oP.cqi, "to the one who took it"); eq(ot.held.timber, 70, "nothing spent before the answer")
answer(oP, RS.dilemma, "FIRST")
eq(ot.held.timber + ot.held.marble, 110 - RS.cost, "accepting spends the cost from that settlement's building materials")
eq(ot.held.coal, 50, "and nothing else")
eq(#REPAIRED, 3, "every building there is repaired")
eq(BUNDLES.ot[RS.bundle], RS.turns, "and its public order rises for a spell")
-- declined: nothing
ot.held.timber, ot.held.marble = 100, 0; REPAIRED = {}; BUNDLES.ot = {}; DILEMMAS = {}
decide("occupation_decision_occupy", ot, oP, "oVr"); answer(oP, RS.dilemma, "SECOND")
eq(ot.held.timber, 100, "declining spends nothing"); eq(#REPAIRED, 0, "and repairs nothing")
-- short: no offer
ot.held.timber = RS.cost - 1; DILEMMAS = {}
decide("occupation_decision_occupy", ot, oP, "oVr"); eq(#DILEMMAS, 0, "short of the cost: no offer")
-- only an occupation: a sack or a raze takes its share and offers nothing
ot.held.timber = 200; DILEMMAS = {}
decide("occupation_decision_sack", ot, oP, "oVr"); eq(#DILEMMAS, 0, "a sack offers no Restore")
-- a pending store event is not lost to a Restore offered over it
ot.held.timber = 200; DILEMMAS = {}
F.state.pending = { oPr = { feast = { key = "feast", region = "o0" } } }
o0.held.grain = 150
decide("occupation_decision_occupy", ot, oP, "oVr")
answer(oP, EV.feast.dilemma, "FIRST"); eq(o0.held.grain, 150 - EV.feast.cost, "the feast offered before still pays out")
answer(oP, RS.dilemma, "FIRST"); eq(ot.held.timber, 200 - RS.cost, "and so does the Restore")
-- TWO OCCUPATIONS IN ONE TURN: one Restore at a time, as the answer cannot say which settlement;
-- the second offer replaced the first, and the first answer paid for and repaired the second
do local ou = region("ou", 30030, 0, 400, { timber = 200 }); own(oP, ou)
ot.held.timber = 200; DILEMMAS = {}; REPAIRED = {}
decide("occupation_decision_occupy", ot, oP, "oVr"); decide("occupation_decision_occupy", ou, oP, "oVr")
eq(#DILEMMAS, 1, "a second occupation that turn offers no second Restore")
answer(oP, RS.dilemma, "FIRST")
eq(ot.held.timber, 200 - RS.cost, "the answer pays from the settlement it named"); eq(ou.held.timber, 200, "not the other")
F.state.pending = { oPr = { restore = { key = "restore", region = "ou", turn = TURN - 1 } } }; DILEMMAS = {}
decide("occupation_decision_occupy", ou, oP, "oVr"); eq(#DILEMMAS, 1, "an offer left from an earlier turn blocks nothing")
answer(oP, RS.dilemma, "SECOND")
-- NEVER ISSUED (CA's wrapper returns false in multiplayer): no offer is left waiting
DILEMMA_FAILS = true; DILEMMAS = {}
decide("occupation_decision_occupy", ou, oP, "oVr"); eq(F.pending("oPr", "restore"), nil, "a Restore never issued leaves no offer")
DILEMMA_FAILS = nil
lose(oP, ou) end
-- A SAVE FROM BEFORE: one pending offer per faction, not one per event
F.state.pending = { oPr = { key = "feast", region = "o0" } }; o0.held.grain = 150
answer(oP, EV.feast.dilemma, "FIRST"); eq(o0.held.grain, 150 - EV.feast.cost, "an old save's offer still pays out")
-- computer-run factions: the same deal on the events' roll, under the switch
local oA = faction("oAr"); local oa = region("oa", 30020, 0, 400, {}); own(oA, oa, true)
lose(oP, ot); own(oA, ot); ot.held.timber = 200; DILEMMAS = {}; REPAIRED = {}
ROLL = DERPY_MR_FLOWS_EVENT[2] + 1; decide("occupation_decision_occupy", ot, oA, "oPr")
eq(ot.held.timber, 200, "a computer's failed roll spends nothing")
ROLL = DERPY_MR_FLOWS_EVENT[2]; decide("occupation_decision_occupy", ot, oA, "oPr")
eq(#DILEMMAS, 0, "no dilemma for a computer"); eq(ot.held.timber, 200 - RS.cost, "a winning roll spends")
eq(#REPAIRED, 3, "and repairs")
F.state.rates.ai = false; ot.held.timber = 200
decide("occupation_decision_occupy", ot, oA, "oPr"); eq(ot.held.timber, 200, "the switch for other factions stops it")
F.state.rates.ai = true; ROLL = 100
-- the events switch
lose(oA, ot); own(oP, ot); F.state.rates.events = false; DILEMMAS = {}
decide("occupation_decision_occupy", ot, oP, "oVr"); eq(#DILEMMAS, 0, "store events off: no Restore")
eq(#ERRORS, 0, "no script errors in Restore: " .. table.concat(ERRORS, "; "))

-- ---- THE WORKSHOP (spec 2026-10-07): a rare good plus a bulk of its use buys a lasting thing ----
-- a function, not a do-block: its locals are its own, and the main chunk is at Lua 5.1's 200
;(function()
    local W = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do W[w.key] = w end
    local armour, axe = W.item_gromril_armour, W.unit_wh_main_dwf_inf_ironbreakers
    LOCAL_FK = "dP"
    local dP = faction("dP", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local d1 = region("d1", 20000, 0, 1000, { gromril = 200, coal = 0 }); own(dP, d1, true)
    local d2 = region("d2", 20100, 0, 1000, { iron = 100 }); own(dP, d2)
    TURN = 60
    -- REVIEW FOCUS 1: gromril is a war material, but the bulk never counts it
    local st = F.work_state(dP.iface, "item_gromril_armour")
    eq(st.rare.have, 200, "the rare part counts the gromril"); eq(st.bulk.have, 100, "the bulk counts only the iron")
    eq(st.ok, false, "100 of 150 war materials: short"); eq(st.why, "short", "and says why")
    F.request("dP", "work", "item_gromril_armour")
    eq(d1.held.gromril, 200, "short: no gromril taken"); eq(d2.held.iron, 100, "and no iron"); eq(#ITEMS, 0, "nothing given")
    d2.held.iron = 300
    F.request("dP", "work", "item_gromril_armour")
    eq(d1.held.gromril, 200 - armour.rare_n, "the rare part taken"); eq(d2.held.iron, 300 - armour.use_n, "the bulk from iron only")
    eq(ITEMS[1].key, armour.grant, "the item goes to the pool"); eq(ITEMS[1].f, "dP", "of the buyer")
    eq(F.book("dP").now.gromril.spent_out, armour.rare_n, "booked as spent")
    eq(SOUNDS[#SOUNDS], DERPY_MR_FLOWS_WORK_SOUND.item, "a purchase sounds, by its kind")
    local heard = #SOUNDS
    F.request("dP", "work", "item_gromril_armour"); eq(#SOUNDS, heard, "a refused one is silent")
    -- REVIEW FOCUS 3: the same click again
    st = F.work_state(dP.iface, "item_gromril_armour"); eq(st.why, "done", "an item is forged once")
    F.request("dP", "work", "item_gromril_armour"); eq(#ITEMS, 1, "a second click gives nothing")
    eq(d1.held.gromril, 200 - armour.rare_n, "and takes nothing")
    -- the rare part short with the bulk there: refused, and says which
    local g0 = d1.held.gromril
    d1.held.gromril = 10
    st = F.work_state(dP.iface, "item_gromril_greataxe")
    eq(st.bulk.have >= st.bulk.cost, true, "the bulk is there"); eq(st.why, "short", "10 gromril of 40: short")
    F.request("dP", "work", "item_gromril_greataxe"); eq(#ITEMS, 1, "and nothing forged"); eq(d1.held.gromril, 10, "nothing taken")
    d1.held.gromril = g0
    -- race lock: a Dwarf sees no High Elf row; a key not in the catalogue is refused
    eq(F.work_state(dP.iface, "item_ithilmar_breastplate"), nil, "a High Elf item is not open to Dwarfs")
    F.request("dP", "work", "no_such_work"); eq(#ERRORS, 0, "an unknown key is ignored")
    -- a unit, for a faction that owns its race's pool: into that pool, with its group and the cap
    DERPY_MR_FLOWS_POOL_HAS[axe.pool] = DERPY_MR_FLOWS_POOL_HAS[axe.pool] or {}
    DERPY_MR_FLOWS_POOL_HAS[axe.pool].dP = true
    eq(F.work_state(dP.iface, axe.key).route, "pool", "it owns the pool: the pool route")
    F.request("dP", "work", axe.key)
    eq(POOL[1].unit, axe.grant, "the unit goes to the mercenary pool"); eq(POOL[1].group, axe.group, "with its group")
    eq(POOL[1].max, DERPY_MR_FLOWS_WORK.unit_max, "capped at 2"); eq(POOL[1].src, axe.pool, "into its race's pool")
    d1.held.gromril, d2.held.iron = 200, 400
    F.request("dP", "work", axe.key); eq(#POOL, 2, "a second goes in")
    eq(F.work_state(dP.iface, axe.key).why, "full", "two in the pool: full")
    F.request("dP", "work", axe.key)
    eq(#POOL, 2, "a third is refused"); eq(d1.held.gromril, 200 - axe.rare_n, "and takes nothing")
    -- THE POOL IS READ, NOT REMEMBERED: one recruited, one may be bought again
    dP.pool[axe.grant] = 1
    eq(F.work_state(dP.iface, axe.key).why ~= "full", true, "one recruited: room for one more")
    -- an engine that will not say: the Workshop's own count of what it put there
    dP.pool_broken = true
    eq(F.work_state(dP.iface, axe.key).why, "full", "the pool unreadable: its own count of 2")
    dP.pool_broken = nil
    -- A FACTION WITHOUT ITS RACE'S POOL (a minor faction has no renown pool): straight into an army
    local gP = faction("gP", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local g1 = region("g1", 20500, 0, 1000, { gromril = 100, iron = 300 }); own(gP, g1, true)
    st = F.work_state(gP.iface, axe.key)
    eq(st.route, "army", "no pool: the army route"); eq(st.why, "no_army", "and no army with room says so")
    gP.armies = { host(91, { 1, 2, 3 }) }
    eq(F.work_state(gP.iface, axe.key).ok, true, "an army with room: it can be bought")
    local granted, pooled, heard_gp = #GRANTED, #POOL, #SOUNDS
    F.request("gP", "work", axe.key)
    eq(#SOUNDS, heard_gp, "another player's purchase is silent on this machine")
    eq(GRANTED[granted + 1].lookup, "character_cqi:91", "into that army"); eq(#POOL, pooled, "not into a pool")
    eq(g1.held.gromril, 100 - axe.rare_n, "paid for")
    eq(F.work_state(dP.iface, "unit_wh_main_dwf_inf_hammerers").why ~= "full", true, "another unit is not full")
    -- an upgrade needs a settlement, and the buyer's own
    eq(F.work_state(dP.iface, "up_gromril").why, "where", "an upgrade row alone is not a purchase")
    F.request("dP", "work", "up_gromril"); eq(BUNDLES.d1 and BUNDLES.d1.derpy_mr_up_gromril, nil, "work refuses an upgrade key")
    local enemy = faction("eE", { sc = "wh_main_sc_grn_greenskins" })
    local e1 = region("e1", 20200, 0, 1000, {}); own(enemy, e1)
    eq(F.work_state(dP.iface, "up_gromril", "e1").why, "not_yours", "REVIEW FOCUS 2: not on a settlement you do not hold")
    F.request("dP", "upgrade", "up_gromril", "e1"); eq(BUNDLES.e1, nil, "and a request there does nothing")
    d1.held.gromril, d2.held.iron = 300, 500
    F.request("dP", "upgrade", "up_gromril", "d1")
    eq(BUNDLES.d1.derpy_mr_up_gromril, 0, "the bundle never expires (0 turns)")
    eq(d1.held.gromril, 300 - W.up_gromril.rare_n, "the upgrade's rare part taken")
    eq(F.upgrades_of("d1").up_gromril, "dP", "kept with its buyer")
    eq(F.work_state(dP.iface, "up_gromril", "d1").why, "built", "once per settlement")
    eq(F.work_state(dP.iface, "up_gromril", "d2").ok, true, "the same upgrade elsewhere is allowed")
    F.request("dP", "upgrade", "item_gromril_greataxe", "d2"); eq(#ITEMS, 1, "upgrade refuses an item key")
    -- research: luxuries only, then a 10-turn wait
    local lux
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do if g.use == "luxuries" and not g.rare then lux = lux or g.stem end end
    d2.held[lux] = 400
    F.request("dP", "work", "research")
    eq(RESEARCH[1].n, DERPY_MR_FLOWS_WORK.research_points, "research points granted"); eq(d2.held[lux], 100, "300 luxuries")
    eq(SOUNDS[#SOUNDS], DERPY_MR_FLOWS_WORK_SOUND.research, "research has its own sound")
    TURN = 65; st = F.work_state(dP.iface, "research"); eq(st.why, "wait", "then a wait"); eq(st.wait, 5, "of 10 turns")
    TURN = 70; eq(F.work_state(dP.iface, "research").why, "short", "the wait is over after 10; only the goods are short")
    -- the switch and the computer
    F.state.rates.actions = false; d2.held[lux] = 400; F.request("dP", "work", "research"); eq(#RESEARCH, 1, "off with the switch")
    F.state.rates.actions = true
    local cA = faction("cA", { sc = "wh_main_sc_dwf_dwarfs" })
    F.dispatch("cA", { "work", "research" }); eq(#RESEARCH, 1, "a computer faction cannot use the door")
    cm.saving_game_callbacks[1]({})
    eq(SAVED.derpy_mr_flows.factions.dP.works.items.item_gromril_armour, 60, "the forged item is kept in the save")
    eq(SAVED.derpy_mr_flows.upgrades.d1.up_gromril, "dP", "and the upgrade")
    -- REVIEW FOCUS 5, A SETTLEMENT CHANGES HANDS: its upgrade works only for its buyer
    local function changed(r) fire("RegionFactionChangeEvent", { region = function() return r.iface end }) end
    lose(dP, d1); own(enemy, d1); changed(d1)
    eq(BUNDLES.d1.derpy_mr_up_gromril, nil, "captured: the upgrade stops")
    local third = faction("tT", { sc = "wh_main_sc_emp_empire" })
    lose(enemy, d1); own(third, d1); changed(d1)
    eq(BUNDLES.d1.derpy_mr_up_gromril, nil, "a third party never gets it")
    lose(third, d1); own(dP, d1); changed(d1)
    eq(BUNDLES.d1.derpy_mr_up_gromril, 0, "back for its buyer, for good")
    changed(e1); eq(BUNDLES.e1, nil, "a settlement with no upgrade: nothing")
    -- ANOTHER FACTION BOUGHT IT, AND IS ALIVE: the new owner may build its own, and is not told "built"
    local fP = faction("fP", { sc = "wh_main_sc_dwf_dwarfs" })
    lose(dP, d1); own(fP, d1); changed(d1)
    d1.held.gromril, d1.held.iron = 300, 300
    st = F.work_state(fP.iface, "up_gromril", "d1")
    eq(st.why, nil, "someone else's upgrade is not built for the new owner"); eq(st.ok, true, "it can build its own")
    eq(F.work(fP.iface, "up_gromril", "d1"), true, "and does")
    eq(F.upgrades_of("d1").up_gromril, "fP", "now its"); eq(BUNDLES.d1.derpy_mr_up_gromril, 0, "and working")
    lose(fP, d1); own(dP, d1); changed(d1)
    eq(BUNDLES.d1.derpy_mr_up_gromril, nil, "the old buyer retakes it: the new buyer's, not its, so off")
    eq(F.work_state(dP.iface, "up_gromril", "d1").why ~= "built", true, "and it may build again")
    -- asking about a settlement never writes the save
    F.work_state(dP.iface, "up_gromril", "d2")
    eq(F.state.upgrades.d2, nil, "a state read leaves no entry behind")
    -- a dead buyer's upgrades are cleared at a player's turn start
    F.upgrades_of("e1").up_gromril = "gone"
    faction("gone", {}).dead = true
    turn_start(dP)
    eq(F.upgrades_of("e1").up_gromril, nil, "a dead buyer's entries cleared")
    eq(F.upgrades_of("d1").up_gromril, "fP", "a living buyer's kept")
    -- REVIEW FOCUS 4, COMPUTER FACTIONS: one purchase on a 20% roll; units straight into the largest
    -- army with room; a reserve keeps their upkeep stock. Called directly: turn start also runs
    -- upkeep and events, which draw goods and use rolls.
    local aC = faction("aC", { sc = "wh_main_sc_dwf_dwarfs" })
    local a1 = region("a1", 21000, 0, 1000, { gromril = 100, iron = 150 }); own(aC, a1, true)
    local items0, granted0, pool0 = #ITEMS, #GRANTED, #POOL
    F.state.rates.ai = true
    ROLL = 1
    F.work_ai(aC.iface)
    eq(#GRANTED + #ITEMS, granted0 + items0, "150 iron: paying 150 leaves less than 150 - the reserve stops it")
    a1.held.iron = 400
    aC.armies = { host(81, { 1, 2, 3 }), host(82, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }) }
    ROLL = DERPY_MR_FLOWS_WORK.ai_pct + 1; F.work_ai(aC.iface)
    eq(#GRANTED + #ITEMS, granted0 + items0, "a roll over the chance buys nothing, though it could afford it")
    local heard_ai = #SOUNDS
    ROLL = DERPY_MR_FLOWS_WORK.ai_pct; F.work_ai(aC.iface)
    eq(#SOUNDS, heard_ai, "a computer's purchase is silent")
    eq(GRANTED[granted0 + 1].lookup, "character_cqi:81", "into the largest army with room - the full one is skipped")
    eq(#POOL, pool0, "not into the pool")
    eq(a1.held.gromril, 100 - W.unit_wh_main_dwf_inf_hammerers.rare_n, "and paid for")
    aC.armies = { host(83, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }) }
    F.work_ai(aC.iface)
    eq(#GRANTED, granted0 + 1, "no army with room: no unit")
    eq(#ITEMS, items0 + 1, "it buys the next row, an item"); eq(ITEMS[#ITEMS].f, "aC", "for itself")
    F.state.rates.ai = false; a1.held.gromril, a1.held.iron = 300, 900
    F.work_ai(aC.iface); eq(#ITEMS, items0 + 1, "the switch off: nothing")
    F.state.rates.ai = true
    turn_start(aC); eq(#ITEMS, items0 + 2, "turn start runs the purchase")
    eq(F.work_state(aC.iface, "up_gromril", "a1").ok, true, "it could afford the capital's upgrade")
    aC.human = true; turn_start(aC); eq(#ITEMS, items0 + 2, "a player's faction never buys by itself")
    eq(BUNDLES.a1 and BUNDLES.a1.derpy_mr_up_gromril, nil, "not even the upgrade")
    aC.human = false
    -- an upgrade: the capital, else the settlement holding the most of the bulk's use
    local bC = faction("bC", { sc = "wh_main_sc_dwf_dwarfs" })
    local b1 = region("b1", 22000, 0, 1000, { gromril = 200, iron = 50 }); own(bC, b1, true)
    local b2 = region("b2", 22100, 0, 1000, { iron = 300 }); own(bC, b2)
    local b3 = region("b3", 22200, 0, 1000, { iron = 200 }); own(bC, b3)
    local wb = F.works_book("bC")
    -- every item open to it forged already, so the upgrade is next (the catalogue grows: spec 2026-10-08 section 5)
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do
        if w.kind == "item" and F.work_open(bC.iface, w) then wb.items[w.key] = 1 end
    end
    F.upgrades_of("b1").up_gromril = "bC"
    F.work_ai(bC.iface)
    eq(BUNDLES.b2 and BUNDLES.b2.derpy_mr_up_gromril, 0, "the capital has it: the fullest settlement gets it")
    eq(BUNDLES.b3, nil, "not the other")
    ROLL = 100
    LOCAL_FK = nil
    eq(#ERRORS, 0, "no script errors in the Workshop: " .. table.concat(ERRORS, "; "))
end)()

-- ---- A RARE GOOD IS NEVER BULK (author, 2026-10-08): only the Workshop's own works take it ----
do
    local rP = faction("rP", { human = true })
    local r1 = region("r1", 40000, 0, 2000, { gromril = 900, grain = 0 }); r1.level = 3; own(rP, r1, true)
    eq(F.use_total(F.stock(r1.iface), "war"), 0, "900 gromril count as no war materials")
    eq(F.order_state(rP.iface, "muster").ok, false, "so Muster cannot be bought with them")
    F.draw(r1.iface, F.stock(r1.iface), "war", 50, DERPY_MR_FLOWS_KIND.spend, "rP")
    eq(r1.held.gromril, 900, "and a draw of war materials leaves them")
    r1.held.coal = 300
    F.request("rP", "order", "muster")
    eq(r1.held.gromril, 900, "Muster pays with coal, never gromril"); eq(r1.held.coal, 300 - F.ORDER_COST, "all of it")
    r1.held.black_lotus = 500; turn_start(rP)
    eq(r1.held.black_lotus, 500, "upkeep eats no rare good")
    eq(BUNDLES.r1 and BUNDLES.r1.derpy_mr_comforts, nil, "nor does one count toward Comforts")
    lose(rP, r1)
end
-- RESTORE ON LOOT-AND-OCCUPY TOO (author, 2026-10-08)
do
    local lP2 = faction("lP2", { human = true }); local lv = faction("lV2")
    local l0 = region("l0", 41000, 0, 400, {}); own(lP2, l0, true)
    local lt = region("lt", 41010, 0, 400, { timber = 200 }); own(lP2, lt)
    lt.slots = { { has_building = function() return true end } }
    F.state.rates.events = true; F.state.pending = nil; DILEMMAS = {}
    decide("occupation_decision_loot", lt, lP2, "lV2")
    eq(#DILEMMAS, 1, "loot-and-occupy offers Restore"); eq(DILEMMAS[1].key, DERPY_MR_FLOWS_EVENTS.restore.dilemma, "the Restore one")
    answer(lP2, DERPY_MR_FLOWS_EVENTS.restore.dilemma, "SECOND")
    F.state.rates.events = false
end

-- ---- THE RECRUITMENT DRAW (spec 2026-10-08 workshop expansion, section 3) ----
;(function()
    local function train(f, key, caste, value)
        fire("UnitTrained", { unit = function() return {
            faction = function() return f.iface end, unit_key = function() return key end,
            unit_caste = function() return caste end, get_unit_custom_battle_cost = function() return value end } end })
    end
    -- the gold price of a missing good, from the data: CA's trade value of the cheapest of its kind
    local function worth(pick)
        local w
        for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do if pick(g) and (not w or g.value < w) then w = g.value end end
        return w
    end
    local war = worth(F.bulk("war"))
    local R = DERPY_MR_FLOWS_RECRUIT
    local rates0, turn0 = F.state.rates, TURN
    TURN = 9000
    F.state.rates = nil; F.freeze_rates()
    F.state.rates.recruit, F.state.rates.recruit_per, F.state.rates.ai = true, 1, true
    local rcP = faction("rcP", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local rc1 = region("rc1", 42000, 0, 2000, { coal = 50, gromril = 10, warhorses = 50 }); own(rcP, rc1, true)
    train(rcP, "modded_inf", "melee_infantry", 650)
    eq(rc1.held.coal, 50 - 7, "650 gold of infantry takes 7 war materials, any mod's unit")
    train(rcP, "modded_cav", "melee_cavalry", 900); eq(rc1.held.warhorses, 50 - 9, "cavalry takes mounts")
    train(rcP, "modded_mon", "monster", 1000); eq(rc1.held.warhorses, 41 - 15, "a monster 1.5x")
    train(rcP, "modded_gun", "warmachine", 800)
    eq(rc1.held.coal, 43 - 4, "a war machine: half its draw in war materials")
    local split = 0
    for _, b in ipairs(F.recruit_bill(rcP.iface, "warmachine", 700)) do split = split + b.n end
    eq(split, 7, "an odd draw splits 4 and 3, not rounded up in both halves")
    train(rcP, "wh_main_dwf_inf_ironbreakers", "melee_infantry", R.elite + 100)
    eq(rc1.held.gromril, 10 - math.ceil((R.elite + 100) / R.elite_per), "an elite Dwarf unit also takes gromril")
    eq(rc1.held.coal, 39 - math.ceil((R.elite + 100) / R.per), "and its war materials, never the gromril")
    train(rcP, "almost", "melee_infantry", R.elite - 1)
    eq(rc1.held.gromril, 10 - math.ceil((R.elite + 100) / R.elite_per), "one gold short of elite: no gromril")
    rc1.held.gromril = 10; train(rcP, "at_line", "melee_infantry", R.elite)
    eq(rc1.held.gromril, 10 - math.ceil(R.elite / R.elite_per), "exactly the elite line: it takes gromril")
    -- a race with no rare good draws none, gromril held or not; Dark Elves: lotus for foot, hide for the rest
    local ksP = faction("ksP", { human = true, sc = "wh3_main_sc_ksl_kislev" })
    local ks1 = region("ks1", 42050, 0, 2000, { coal = 50, gromril = 10, feathers = 10 }); own(ksP, ks1, true)
    train(ksP, "modded_elite", "melee_infantry", 2000)
    eq(ks1.held.gromril + ks1.held.feathers, 20, "Kislev has no rare good: none taken")
    local dfP = faction("dfP", { human = true, sc = "wh2_main_sc_def_dark_elves" })
    local df1 = region("df1", 42060, 0, 2000, { coal = 50, warhorses = 50, black_lotus = 20, sea_dragon_hide = 20 })
    own(dfP, df1, true)
    train(dfP, "modded_elite", "melee_infantry", 1600)
    eq(df1.held.black_lotus, 16, "Dark Elf foot takes black lotus"); eq(df1.held.sea_dragon_hide, 20, "not hide")
    train(dfP, "modded_elite", "melee_cavalry", 1600); eq(df1.held.sea_dragon_hide, 16, "their riders take hide")
    lose(ksP, ks1); lose(dfP, df1)
    local c0 = rc1.held.coal
    train(rcP, "lord", "lord", 2000); train(rcP, "odd", nil, 800); train(rcP, "free", "melee_infantry", 0)
    eq(rc1.held.coal, c0, "REVIEW FOCUS 1: a lord, an unreadable caste and a unit worth nothing take nothing")
    eq(#ERRORS, 0, "and throw nothing: " .. table.concat(ERRORS, "; "))
    -- the slider: 2 per 100 gold doubles it, 0 turns it off
    rc1.held.coal = 50; F.state.rates.recruit_per = 2; train(rcP, "modded_inf", "melee_infantry", 650)
    eq(rc1.held.coal, 50 - 13, "2 per 100 gold: 650 takes 13"); F.state.rates.recruit_per = 0
    train(rcP, "modded_inf", "melee_infantry", 650); eq(rc1.held.coal, 37, "0: nothing"); F.state.rates.recruit_per = 1
    -- SHORTFALL, no race currency (Dwarfs): gold at gold_x times CA's trade value
    rc1.held.coal = 3; local t0 = rcP.iface:treasury()
    train(rcP, "modded_inf", "melee_infantry", 650)
    eq(rc1.held.coal, 0, "the stores give what they hold")
    eq(rcP.iface:treasury() - t0, -math.ceil(4 * war * R.gold_x), "the 4 missing are paid in gold")
    -- CHAOS DWARFS pay the shortfall in Armaments first
    local cdP = faction("cdP", { human = true, sc = "wh3_dlc23_sc_chd_chaos_dwarfs", pools = { wh3_dlc23_chd_armaments = 10 } })
    local cd1 = region("cd1", 42100, 0, 2000, {}); own(cdP, cd1, true)
    local cur = DERPY_MR_FLOWS_CURRENCY.chd
    local g0 = cdP.iface:treasury()
    train(cdP, "modded_inf", "melee_infantry", 650)
    eq(FPOOL.cdP.wh3_dlc23_chd_armaments, 10 - math.ceil(7 / cur.per), "7 missing, paid in Armaments, rounded up")
    eq(FPOOL_FACTOR[#FPOOL_FACTOR], R.factor, "under our factor")
    eq(cdP.iface:treasury(), g0, "and no gold while the Armaments cover it")
    FPOOL.cdP.wh3_dlc23_chd_armaments = 1
    train(cdP, "modded_inf", "melee_infantry", 650)
    eq(FPOOL.cdP.wh3_dlc23_chd_armaments, 0, "the last Armament goes")
    eq(cdP.iface:treasury() - g0, -math.ceil((7 - cur.per) * war * R.gold_x), "what it did not cover, in gold")
    -- REVIEW FOCUS 2 and 3: no settlements and no pool; a faction with 5 gold pays 5 and no more
    local hzP = faction("hzP", { human = true, sc = "wh3_dlc23_sc_chd_chaos_dwarfs", gold = 5 })
    train(hzP, "modded_inf", "melee_infantry", 650); eq(hzP.iface:treasury(), 0, "no settlements, no pool: 5 gold, no debt")
    -- THE LEDGER: last turn's, humans only, in the race's words
    TURN = 9001
    local l = F.recruit_last("cdP")
    eq(l and l.paid[cur.word], math.ceil(7 / cur.per) + 1, "the panel reads last turn's Armaments")
    eq(l and l.line, cur.line, "with the race's sentence")
    eq(F.recruit_last("rcP").goods > 0, true, "a Dwarf's line counts the goods")
    eq(F.recruit_last("rcP").line, nil, "and has no currency sentence")
    -- SWITCHES: off takes nothing; a computer faction only under "Other factions use their stores"
    F.state.rates.recruit = false; rc1.held.coal = 50; train(rcP, "modded_inf", "melee_infantry", 650)
    eq(rc1.held.coal, 50, "switched off: nothing taken"); F.state.rates.recruit = true
    local aiF = faction("aiF", { sc = "wh_main_sc_emp_empire" })
    local ai1 = region("ai1", 42200, 0, 2000, { coal = 50 }); own(aiF, ai1, true)
    F.state.rates.ai = false; train(aiF, "modded_inf", "melee_infantry", 650)
    eq(ai1.held.coal, 50, "a computer faction is spared with the switch off")
    F.state.rates.ai = true; train(aiF, "modded_inf", "melee_infantry", 650); eq(ai1.held.coal, 43, "and charged with it on")
    TURN = 9002; eq(F.recruit_last("aiF"), nil, "no ledger for a computer faction")
    local dmP = faction("dmP", { human = true, sc = "wh3_main_sc_kho_khorne" })
    local dm1 = region("dm1", 42300, 0, 2000, { coal = 50 }); own(dmP, dm1, true)
    train(dmP, "modded_inf", "melee_infantry", 650); eq(dm1.held.coal, 50, "a race that keeps no stores pays nothing")
    eq(F.cost.recruit ~= nil, true, "REVIEW FOCUS 5: the handler counts its time")
    lose(rcP, rc1); lose(cdP, cd1); lose(aiF, ai1); lose(dmP, dm1)
    F.state.rates, TURN = rates0, turn0
end)()
;(function()
    -- REVIEW FOCUS 4: a unit bought in the Workshop arrives without a second charge; only that one
    local W = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do W[w.key] = w end
    local axe = W.unit_wh_main_dwf_inf_ironbreakers
    local function train(f)
        fire("UnitTrained", { unit = function() return {
            faction = function() return f.iface end, unit_key = function() return axe.grant end,
            unit_caste = function() return "melee_infantry" end, get_unit_custom_battle_cost = function() return 1300 end } end })
    end
    local rates0, turn0 = F.state.rates, TURN
    TURN = 9100
    F.state.rates = nil; F.freeze_rates(); F.state.rates.recruit, F.state.rates.recruit_per = true, 1
    local wkP = faction("wkP", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local wk1 = region("wk1", 42400, 0, 2000, { coal = 100, gromril = 100 }); own(wkP, wk1, true)
    DERPY_MR_FLOWS_POOL_HAS[axe.pool] = DERPY_MR_FLOWS_POOL_HAS[axe.pool] or {}
    DERPY_MR_FLOWS_POOL_HAS[axe.pool].wkP = true
    F.work_grant(wkP.iface, axe, nil)
    train(wkP); eq(wk1.held.coal, 100, "the Workshop's unit arrives without a second charge")
    eq(wk1.held.gromril, 100, "nor its gromril")
    train(wkP); eq(wk1.held.coal < 100, true, "a second, recruited the usual way, is charged")
    -- THE ARMY ROUTE, with UnitTrained fired INSIDE grant_unit_to_character (final review, 2026-10-08):
    -- the free recruit must be on the book before the call, or the unit is charged and a later one is free
    local waP = faction("waP", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local wa1 = region("wa1", 42500, 0, 2000, { coal = 100, gromril = 100 }); own(waP, wa1, true)
    waP.armies = { host(71, { 1, 2, 3 }) }
    GRANT_HOOK = function() train(waP) end
    F.work_grant(waP.iface, axe, nil)
    GRANT_HOOK = nil
    eq(#GRANTED > 0 and GRANTED[#GRANTED].lookup, "character_cqi:71", "the army route")
    eq(wa1.held.coal, 100, "fired inside the grant: not charged")
    train(waP); eq(wa1.held.coal < 100, true, "and the next ordinary recruit is charged, not free")
    lose(waP, wa1)
    eq(#ERRORS, 0, "no script errors: " .. table.concat(ERRORS, "; "))
    lose(wkP, wk1)
    F.state.rates, TURN = rates0, turn0
end)()

-- ---- THE NAMED RECIPES (workshop expansion spec section 4): convert, lasting, computers ----
;(function()
    local W = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do W[w.key] = w end
    local conv, gran = W.conv_armaments, W.last_granary
    local rates0, turn0 = F.state.rates, TURN
    F.state.rates = nil; F.freeze_rates(); F.state.rates.actions, F.state.rates.recruit = true, true
    TURN = 9200
    -- a common good of coal's use that no part of the recipe names: a draw by use would take it
    local by
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        if g.use == F.GOOD.coal.use and not g.rare and g.stem ~= "coal" and g.stem ~= "brimstone" and g.stem ~= "iron" then
            by = by or g.stem
        end
    end
    local cvP = faction("cvP", { human = true, sc = "wh3_dlc23_sc_chd_chaos_dwarfs", pools = { wh3_dlc23_chd_armaments = 0 } })
    local cv1 = region("cv1", 42600, 0, 2000, { coal = 50, brimstone = 50, iron = 50, [by] = 500 }); own(cvP, cv1, true)
    F.request("cvP", "work", conv.key)
    eq(cv1.held.coal, 50 - 20, "the Armaments recipe takes its coal"); eq(cv1.held.brimstone, 30, "its brimstone")
    eq(cv1.held.iron, 30, "and its iron"); eq(cv1.held[by], 500, "named goods only, never another of their use")
    eq(FPOOL.cvP.wh3_dlc23_chd_armaments, conv.amount, "and pays the Armaments")
    eq(FPOOL_FACTOR[#FPOOL_FACTOR], "derpy_mr_workshop", "under the Workshop's factor")
    eq(F.work_state(cvP.iface, conv.key).why, "wait", "once a turn")
    F.request("cvP", "work", conv.key); eq(cv1.held.coal, 30, "a second click this turn takes nothing")
    TURN = 9201; eq(F.work_state(cvP.iface, conv.key).ok, true, "the next turn it is open again")
    cv1.held.brimstone = 5
    eq(F.work_state(cvP.iface, conv.key).why, "short", "short in one good: short")
    F.request("cvP", "work", conv.key); eq(cv1.held.coal, 30, "and nothing taken, not even the goods it has")
    eq(F.work_state(faction("cvD", { human = true, sc = "wh_main_sc_dwf_dwarfs" }).iface, conv.key), nil,
       "a Dwarf has no Armaments recipe")
    -- LASTING: a faction bundle for good, once a campaign
    local lsP = faction("lsP", { human = true, sc = "wh_main_sc_emp_empire" })
    local ls1 = region("ls1", 42700, 0, 4000, { grain = 300, salt = 300, salted_meat = 300, pottery = 300 }); own(lsP, ls1, true)
    F.request("lsP", "work", gran.key)
    eq(ls1.held.pottery, 300 - 120, "the Granary takes its four goods")
    eq(FBUNDLES.lsP and FBUNDLES.lsP[gran.bundle], 0, "and its bundle goes on for good")
    eq(F.work_state(lsP.iface, gran.key).why, "done", "once a campaign")
    FBUNDLES.lsP[gran.bundle] = nil
    eq(F.work_state(lsP.iface, gran.key).why, "done", "REVIEW FOCUS 3: still bought after the bundle goes")
    -- REVIEW FOCUS 5: a computer buys a lasting work with every good held twice over, never an army work
    local aiW = faction("aiW", { sc = "wh_main_sc_emp_empire" })
    local aw1 = region("aw1", 42800, 0, 4000, { grain = 200, salt = 200, salted_meat = 200, pottery = 200,
                                                 blackpowder = 900, brass = 900 }); own(aiW, aw1, true)
    aiW.armies = { host(61, { 1, 2 }) }
    F.state.rates.ai = true; ROLL = 1
    F.work_ai(aiW.iface)
    eq(aw1.held.grain, 200, "200 grain is not twice 120: no Granary"); eq(aw1.held.brass, 900, "and never an army work")
    aw1.held.grain, aw1.held.salt, aw1.held.salted_meat, aw1.held.pottery = 240, 240, 240, 240
    F.work_ai(aiW.iface)
    eq(aw1.held.grain, 120, "every good held twice over: the Granary is bought")
    eq(FBUNDLES.aiW and FBUNDLES.aiW[gran.bundle], 0, "with its bundle")
    -- A COMPUTER'S UNIT PURCHASE is not charged again by the recruit draw (stage 1 final review)
    local axe = W.unit_wh_main_dwf_inf_ironbreakers
    local aiD = faction("aiD", { sc = "wh_main_sc_dwf_dwarfs" })
    local ad1 = region("ad1", 42900, 0, 4000, { gromril = 100, iron = 400 }); own(aiD, ad1, true)
    aiD.armies = { host(62, { 1, 2 }) }
    GRANT_HOOK = function(unit)
        fire("UnitTrained", { unit = function() return {
            faction = function() return aiD.iface end, unit_key = function() return unit end,
            unit_caste = function() return "melee_infantry" end, get_unit_custom_battle_cost = function() return 1300 end } end })
    end
    F.work_ai(aiD.iface)
    GRANT_HOOK = nil
    eq(ad1.held.gromril, 100 - axe.rare_n, "a computer pays the Workshop's gromril")
    eq(ad1.held.iron, 400 - axe.use_n, "and its iron, and nothing for the recruit it hands itself")
    eq(#ERRORS, 0, "no script errors: " .. table.concat(ERRORS, "; "))
    lose(cvP, cv1); lose(lsP, ls1); lose(aiW, aw1); lose(aiD, ad1)
    F.state.rates, TURN, ROLL = rates0, turn0, 100
end)()

-- ---- ARMY AND CHARACTER WORKS on the selected character (spec section 4b, 4c) ----
;(function()
    local W = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do W[w.key] = w end
    local ammo, rations, forge, steel = W.army_ammo, W.army_rations, W.army_forge, W.trait_steel
    local rates0, turn0 = F.state.rates, TURN
    F.state.rates = nil; F.freeze_rates(); F.state.rates.actions = true
    TURN = 9300
    local tgP = faction("tgP", { human = true, sc = "wh_main_sc_emp_empire" })
    local tg1 = region("tg1", 43000, 0, 4000, { blackpowder = 500, brass = 500, grain = 500, salt = 500, beer = 500,
                                                 iron = 500, coal = 500, books = 500, glassware = 500, silver = 500 }); own(tgP, tg1, true)
    local mfA, mfB = host(71, { 1 }), host(72, { 1 })
    character(71, tgP, mfA); character(72, tgP, mfB); character(73, faction("tgF"), host(73, { 1 }))
    character(74, tgP, nil)
    F.request("tgP", "aim", ammo.key, "71")
    local fb = FORCE_BUNDLES[#FORCE_BUNDLES]
    eq(fb and fb[1], ammo.bundle, "the Ammunition Train's bundle"); eq(fb and fb[2], mfA:command_queue_index(), "on that army")
    eq(fb and fb[3], ammo.turns, "for its turns"); eq(tg1.held.brass, 450, "paid for")
    eq(F.work_state(tgP.iface, ammo.key, nil, 71).why, "wait", "REVIEW FOCUS 2: once per army")
    F.request("tgP", "aim", ammo.key, "71"); eq(tg1.held.brass, 450, "a second on the same army takes nothing")
    F.request("tgP", "aim", ammo.key, "72"); eq(tg1.held.brass, 400, "another army can take it")
    eq(FORCE_BUNDLES[#FORCE_BUNDLES][2], mfB:command_queue_index(), "on the other army")
    TURN = 9300 + ammo.wait; eq(F.work_state(tgP.iface, ammo.key, nil, 71).ok, true, "its wait over, open again")
    F.request("tgP", "aim", rations.key, "71")
    eq(RANKS[#RANKS] and RANKS[#RANKS][1], "character_cqi:71", "Rations: the army's units gain a rank")
    eq(RANKS[#RANKS] and RANKS[#RANKS][2], rations.rank, "one rank")
    -- REVIEW FOCUS 1: a target that is not the player's, is gone, or has no army
    F.request("tgP", "aim", forge.key, "73"); eq(tg1.held.iron, 500, "another faction's army: refused, nothing taken")
    eq(F.work_state(tgP.iface, forge.key, nil, 73).why, "not_yours", "and says why")
    F.request("tgP", "aim", forge.key, "74"); eq(tg1.held.iron, 500, "a hero with no army: refused")
    eq(F.work_state(tgP.iface, forge.key, nil, 74).why, "no_army", "and says why")
    local gone = CHARS[72]; CHARS[72] = nil
    F.request("tgP", "aim", forge.key, "72"); eq(tg1.held.iron, 500, "a character gone by the dispatch: refused")
    CHARS[72] = gone
    F.request("tgP", "work", forge.key); eq(tg1.held.iron, 500, "an army work with no target is refused")
    F.request("tgP", "aim", forge.key, "x71"); eq(tg1.held.iron, 500, "a target that is not a number is ignored")
    eq(F.work_state(tgP.iface, forge.key).why, "aim", "nothing selected: says so")
    local rec = W.last_records
    F.request("tgP", "aim", rec.key, "71"); eq(FBUNDLES.tgP and FBUNDLES.tgP[rec.bundle], nil,
       "a work that takes no target is not bought through a target")
    -- REVIEW FOCUS 4: a trait once per character
    F.request("tgP", "aim", steel.key, "74")
    eq(CHARS[74].traits[steel.trait], true, "a hero takes Steel-shod"); eq(tg1.held.iron, 500 - 80, "paid for")
    eq(F.work_state(tgP.iface, steel.key, nil, 74).why, "done", "once")
    F.request("tgP", "aim", steel.key, "74"); eq(tg1.held.iron, 420, "a second takes nothing")
    F.request("tgP", "aim", steel.key, "71"); eq(CHARS[71].traits[steel.trait], true, "another character can take it")
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do
        eq(DERPY_MR_FLOWS_WORK_SOUND[w.kind] ~= nil, true, w.key .. ": every kind has its purchase sound")
    end
    eq(#ERRORS, 0, "no script errors: " .. table.concat(ERRORS, "; "))
    lose(tgP, tg1)
    F.state.rates, TURN = rates0, turn0
end)()

-- ---- RARE WORKS DEEPENED (workshop expansion spec section 5): a race new to the Workshop ----
;(function()
    local W = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do W[w.key] = w end
    local zd = W.unit_wh3_dlc29_vmp_mon_zombie_dragon
    eq(zd ~= nil, true, "the Zombie Dragon is in the catalogue")
    if not zd then return end
    local rates0, turn0 = F.state.rates, TURN
    F.state.rates = nil; F.freeze_rates(); F.state.rates.actions = true
    TURN = 9400
    local bulk
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        if g.use == zd.use and not g.rare then bulk = bulk or g.stem end
    end
    local vzP = faction("vzP", { human = true, sc = "wh_main_sc_vmp_vampire_counts" })
    local vz1 = region("vz1", 43100, 0, 4000, { dragon_bone = 100, [bulk] = 400 }); own(vzP, vz1, true)
    DERPY_MR_FLOWS_POOL_HAS[zd.pool] = DERPY_MR_FLOWS_POOL_HAS[zd.pool] or {}
    DERPY_MR_FLOWS_POOL_HAS[zd.pool].vzP = true
    local p0 = #POOL
    F.request("vzP", "work", zd.key)
    eq(POOL[p0 + 1] and POOL[p0 + 1].unit, zd.grant, "a Vampire Counts faction buys its Zombie Dragon")
    eq(POOL[p0 + 1] and POOL[p0 + 1].src, zd.pool, "into its own Regiments of Renown pool")
    eq(vz1.held.dragon_bone, 100 - zd.rare_n, "paid in dragon bone")
    local czP = faction("czP", { human = true, sc = "wh3_main_sc_cth_cathay" })
    eq(F.work_state(czP.iface, "unit_wh3_main_cth_inf_dragon_guard_0") ~= nil, true, "Cathay sees its Dragon Guard")
    eq(F.work_state(czP.iface, "unit_wh_main_brt_cav_pegasus_knights"), nil, "and not Bretonnia's Pegasus Knights")
    -- stage 3 review: Kislev makes no feathers and trade stops at one shipment, so no feather works
    local kzP = faction("kzP", { human = true, sc = "wh3_main_sc_ksl_kislev" })
    eq(F.work_state(kzP.iface, "item_phoenix_pinion"), nil, "Kislev is offered no feather work")
    eq(#ERRORS, 0, "no script errors: " .. table.concat(ERRORS, "; "))
    lose(vzP, vz1)
    F.state.rates, TURN = rates0, turn0
end)()

-- ---- STAGE 2 FINAL REVIEW (2026-10-08): a pool at its cap, a lord's trait on a hero ----
;(function()
    local W = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do W[w.key] = w end
    local food, spice = W.conv_food, W.trait_spice
    local rates0, turn0 = F.state.rates, TURN
    F.state.rates = nil; F.freeze_rates(); F.state.rates.actions = true
    TURN = 9500
    local skP = faction("skP", { human = true, sc = "wh2_main_sc_skv_skaven", pools = { skaven_food = 98 },
                                 pool_max = { skaven_food = 100 } })
    local sk1 = region("sk1", 43200, 0, 2000, { grain = 100, salted_fish = 100 }); own(skP, sk1, true)
    eq(F.work_state(skP.iface, food.key).why, "full", "98 of 100 Food: the 4 would not fit")
    F.request("skP", "work", food.key); eq(sk1.held.grain, 100, "so nothing is taken")
    FPOOL.skP.skaven_food = 100 - food.amount
    eq(F.work_state(skP.iface, food.key).ok, true, "room for exactly the 4: open")
    local npP = faction("npP", { human = true, sc = "wh2_main_sc_skv_skaven" })
    local np1 = region("np1", 43300, 0, 2000, { grain = 100, salted_fish = 100 }); own(npP, np1, true)
    eq(F.work_state(npP.iface, food.key).why, "no_pool", "a faction without the pool cannot buy into it")
    F.request("npP", "work", food.key); eq(np1.held.grain, 100, "and pays nothing")
    -- a lord's trait (general_to_force_own): a hero would hold it for nothing
    local lhP = faction("lhP", { human = true, sc = "wh_main_sc_emp_empire" })
    local lh1 = region("lh1", 43400, 0, 2000, { spices = 500, incense = 500 }); own(lhP, lh1, true)
    character(81, lhP, host(81, { 1 })); character(82, lhP, nil)
    F.request("lhP", "aim", spice.key, "82")
    eq(CHARS[82].traits[spice.trait], nil, "a hero cannot take a lord's trait"); eq(lh1.held.spices, 500, "nothing taken")
    eq(F.work_state(lhP.iface, spice.key, nil, 82).why, "not_lord", "and says why")
    F.request("lhP", "aim", spice.key, "81"); eq(CHARS[81].traits[spice.trait], true, "a lord can")
    eq(#ERRORS, 0, "no script errors: " .. table.concat(ERRORS, "; "))
    lose(skP, sk1); lose(npP, np1); lose(lhP, lh1)
    F.state.rates, TURN = rates0, turn0
end)()

-- ---- the run-cost counter (Task 7 reads it) --------------------------------------------
local counters = F.cost
turn_start(tA); eq(F.cost, counters, "a computer-run turn start keeps counting into the same round")
turn_start(hum); eq(F.round_cost, counters, "a human's turn start hands the round's counters over")
eq(F.cost.raid, 0, "and starts new ones")

eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))
print("harness ok")
