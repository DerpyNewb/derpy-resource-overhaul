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
        public_order = function() return r.po or 0 end,   -- Part D: the wild-land rule
        has_effect_bundle = function(_, b) return BUNDLES[key] ~= nil and BUNDLES[key][b] ~= nil end,
        effect_bundles = function()
            local t = {}
            for b, turns in pairs(BUNDLES[key] or {}) do
                t[#t + 1] = { key = function() return b end, duration = function() return turns end }
            end
            return list(t)
        end,
        owning_faction = function() return r.owner and r.owner.iface or NULL end,
        settlement = function() return settlement end,
        slot_list = settlement.slot_list,
        pooled_resource_manager = function()
            return {
                resource = function(_, k)
                    r.pool_reads = (r.pool_reads or 0) + 1
                    local stem = string.match(k, "^derpy_mr_store_(.+)$")
                    if not r.readable or not stem or (r.absent or {})[stem] then return NULL end
                    return pool(r, stem)
                end,
                resources = function()
                    r.pool_walks = (r.pool_walks or 0) + 1
                    local items = {}
                    if r.readable then
                        for _, g in ipairs(DERPY_MR_FLOWS_GOODS or {}) do
                            if not r.missing_pools and not (r.absent or {})[g.stem] then items[#items + 1] = pool(r, g.stem) end
                        end
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
        culture = function() return opts.culture or "wh_main_emp_empire" end,
        pooled_resource_manager = function()
            return { resource = function(_, k)
                if not (FPOOL[name] and FPOOL[name][k]) then return NULL end
                return { is_null_interface = function() return false end, value = function() return FPOOL[name][k] end,
                         maximum_value = function() return (opts.pool_max and opts.pool_max[k]) or 2147483647 end }
            end }
        end,
        is_rebel = function() return f.rebel end,
        -- CA's: an ally, vassal or client state of the other; f.allies names whom (Part C, tolls)
        is_ally_vassal_or_client_state_of = function(_, o) return (f.allies or {})[o:name()] == true end,
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
SCENES = {}
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
    -- a force by its number, from every faction's armies (F.captor looks its force up again)
    get_military_force_by_cqi = function(_, n)
        for _, f in pairs(FACTIONS) do
            for _, mf in ipairs(f.armies) do
                if type(mf) == "table" and mf.command_queue_index and mf.command_queue_index() == n then return mf end
            end
        end
        return false
    end,
    get_human_factions = function()
        local t = {}
        for k, f in pairs(FACTIONS) do if f.human then t[#t + 1] = k end end
        table.sort(t)
        return t
    end,
    is_multiplayer = function() return MP end,
    model = function() return { turn_number = function() return TURN end,
        -- the region nearest a hex, within 5 (Part C, a road's regions); every call counted
        get_region_at_logical_position = function(_, x, y)
            GRLP_CALLS = (GRLP_CALLS or 0) + 1
            local keys, best, bd = {}, nil, 26
            for k in pairs(REGIONS) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local r = REGIONS[k]
                local d = (r.x - x) * (r.x - x) + (r.y - y) * (r.y - y)
                if d < bd then best, bd = r, d end
            end
            return best and best.iface or NULL
        end,
        -- CA's caravan banditry (Part D): BANDITRY(keys) when a test sets it, else 0
        world = function() return { caravans_system = function() return { total_banditry_for_regions_by_key =
            function(_, keys) return BANDITRY and BANDITRY(keys) or 0 end } end, faction_list=function()
            local items,keys={},{};for key in pairs(FACTIONS) do keys[#keys+1]=key end;table.sort(keys)
            for _,key in ipairs(keys) do items[#items+1]=FACTIONS[key].iface end
            return list(items)
        end } end } end,
    -- the engine clamps a pool to [0, its maximum]; this stub does the same
    entity_add_pooled_resource_transaction = function(_, e, j, n)
        local r = e.__r
        LOG[#LOG + 1] = { r.key, j, n }
        local stem, factor = string.match(j, "^derpy_mr_store_(.+)_(%a+)$")
        local valid = false
        for _, key in pairs(DERPY_MR_FLOWS_KIND) do if key == factor then valid = true end end
        assert(valid, "unknown native store transaction: " .. tostring(j))
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
        assert(n == math.floor(n), "treasury_mod of a fraction")
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
    -- ROLLQ: the next answers in order, when a test queues them (Part D's roll, then its pick)
    random_number = function(_, hi, lo)
        ROLLS[#ROLLS + 1] = { hi, lo }
        if ROLLQ and #ROLLQ > 0 then return table.remove(ROLLQ, 1) end
        return ROLL
    end,
    get_total_corruption_value_in_region = function(_, r) return r.__r.corruption or 0 end,
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
    -- the wagon circle drawn over the shipment's marker, which draws nothing itself (2026-10-11)
    add_scripted_composite_scene_to_logical_position = function(_, name, key, x, y, fx, fy, one_shot, seen, unseen)
        if SCENES[name] then error("a scene name used twice: " .. name) end
        if fx == x and fy == y then error("a scene facing its own spot") end
        SCENES[name] = { key = key, x = x, y = y, one_shot = one_shot, seen = seen, unseen = unseen }
    end,
    remove_scripted_composite_scene = function(_, name) SCENES[name] = nil end,
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
        -- fires no UnitTrained (measured 2026-10-11)
        GRANTED[#GRANTED + 1] = { lookup = lookup, unit = unit }
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
    set_context_value = function(id, v) CONTEXT_VALUES[id] = v end,
}
CONTEXT_VALUES = {}
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
-- SPOILAGE (2026-11-01) is off for every block written before it, whose stock figures predate it;
-- the spoilage block at the end puts the real rule back.
local SPOILS = F.spoils
F.spoils = function() return false end
-- TOLLS (Part C) are off for every block written before them, whose gold and stock figures predate them;
-- the toll blocks at the end put the real takers back. A global: the main chunk is at its 200 locals.
TOLL_TAKERS = F.toll_takers
F.toll_takers = function() return {} end
-- BANDITS (Part D) likewise: no road encounter in any block written before them.
ROAD_EVENT = F.road_event
F.road_event = function() end
local distance_turns = F.route_turns
-- Prior lifecycle fixtures test the legacy two-turn schedule; Stage 6 tests the real calculator below.
F.route_turns = function() return 2 end
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

-- ---- agreement cargo helpers (spec 2026-10-23): an agreement's goods leave as a convoy and land later ----
-- Cargo on the road to `buyer` (a faction key): the `stem` in every convoy's basket.
function cargo_to(buyer, stem)
    local n = 0
    for _, c in ipairs(F.convoys()) do
        if c.buyer == buyer then n = n + (c.basket[stem] or 0) end
    end
    return n
end
-- The exporter's next turn, convoys only (no trade, so nothing new leaves): what an agreement's cargo on a one-turn road
-- lands as. TURN moves on and stays there; a case that sets TURN itself goes on from that.
function advance_convoys(exporter)
    TURN = TURN + 1
    F.convoys_turn(exporter.iface)
end
-- road_82: 82 points, 81 steps, (0,0) to (81,0), three turns at 40 steps a turn. The later cargo cases reuse it.
function road_82()
    local path = {}
    for x = 0, 81 do path[#path + 1] = { x, 0 } end
    return path
end

-- ---- trade targets ----------------------------------------------------------------------
local function turn_start(f) fire("FactionTurnStart", { faction = function() return f.iface end }) end
local tA = faction("tA", { human = true })
local tB = faction("tB", { human = true })
local tA1 = region("tA1", 500, 0, 600, { coal = 100 })
local tA2 = region("tA2", 520, 0, 600, { coal = 300 })
local tB1 = region("tB1", 600, 0, 600, { coal = 1, iron = 200 })
own(tA, tA1, true); own(tA, tA2); own(tB, tB1, true)
local tC = faction("tC")
tA.partners = { tC, tB }; tB.partners = { tA }
F.set_stock_policy("tB", "coal", "target", "25")
F.set_stock_policy("tA", "iron", "target", "30")
F.trade(tA.iface)
eq(tA2.held.coal, 285, "fullest removable store exports 5%")
eq(cargo_to("tB", "coal"), 15, "nonzero capital stock still receives: a convoy carries it")
eq(tB1.held.coal, 1, "and nothing lands the turn it leaves")
advance_convoys(tA); eq(tB1.held.coal, 16, "it lands on its due turn")
F.trade(tA.iface)
eq(cargo_to("tB", "coal"), 9, "next export stops at target")
advance_convoys(tA); eq(tB1.held.coal, 25, "and the target is met")
local c2 = tA2.held.coal
F.trade(tA.iface); eq(tA2.held.coal, c2, "target reached: no more exports")
F.set_stock_policy("tB", "coal", "target", "0")
tB1.held.coal = 0; F.trade(tA.iface)
eq(cargo_to("tB", "coal"), 0, "zero refuses scripted requests")
F.trade(tB.iface); eq(cargo_to("tA", "iron"), 10, "reverse direction has its own target")
F.set_stock_policy("tA", "coal", "keep", "290")
F.set_stock_policy("tB", "coal", "target", "100")
F.trade(tA.iface)
eq(cargo_to("tB", "coal"), 0, "both sources below manual Keep")
F.set_stock_policy("tA", "coal", "keep", "90")
tA2.held.coal, tA1.held.coal = 80, 140
F.trade(tA.iface)
eq(tA1.held.coal, 138, "smaller raw store with removable stock wins")
eq(tA2.held.coal, 80, "protected store left alone")
F.set_stock_policy("tA", "coal", "keep", "130")
F.trade(tA.iface); eq(tA1.held.coal, 137, "8 spare: 5% floors to none, and at least 1 goes")
-- Snapshot failures cannot suppress model exports.
hum.partners = { tB }; h1.held = { salt = 100 }; tB1.held.salt = 0
F.set_stock_policy("tB", "salt", "target", "20")
local real_read = DERPY_MR_STORES.read_realm
DERPY_MR_STORES.read_realm = function() error("a UI-side read threw") end
turn_start(hum)
DERPY_MR_STORES.read_realm = real_read
eq(cargo_to("tB", "salt"), 5, "exports survive snapshot failure")
advance_convoys(hum)
eq(#ERRORS, 1, "snapshot failure logged"); ERRORS = {}
hum.partners = {}; tA.partners = {}; tB.partners = {}
do
    -- PRICE GRADIENT: an agreement moves goods only to a store whose price clears the source's price plus the spread
    local rates = F.state.rates; local upkeep_was = rates.upkeep; rates.upkeep = false   -- the fullness branch
    local gS = faction("gradS", { human = true }); local gS1 = region("gradS1", 8000, 0, 200, { coal = 160 }); own(gS, gS1, true)
    local gD = faction("gradD", { human = true }); local gD1 = region("gradD1", 8100, 0, 200, { coal = 20 }); own(gD, gD1, true)
    gS.partners, gD.partners = { gD }, { gS }
    F.set_stock_policy("gradD", "coal", "target", "200")
    local function price(f, r) return F.local_price(F.stock_view(f.iface, r.iface), "coal", f.name) end
    eq(price(gS, gS1), 165, "160 of 200: cheap"); eq(F.buy_price(165), 181, "and 181 to buy")
    eq(price(gD, gD1), 480, "20 of 200: dear")
    eq((F.trade(gS.iface, true).gradD or {})[1], "coal", "the preview shows the cargo going uphill")
    F.trade(gS.iface); eq(cargo_to("gradD", "coal"), 8, "uphill: 5% of 160 is sent"); eq(gS1.held.coal, 152, "and leaves the source")
    advance_convoys(gS)
    gS1.held.coal, gD1.held.coal = 110, 90
    eq(price(gS, gS1), 276, "110 of 200: 276"); eq(F.buy_price(276), 303, "and 303 to buy"); eq(price(gD, gD1), 321, "90 of 200: 321")
    F.trade(gS.iface); eq(cargo_to("gradD", "coal"), 5, "a small gap still clears the spread"); eq(gS1.held.coal, 105, "and the source gives")
    advance_convoys(gS)
    gS1.held.coal, gD1.held.coal = 100, 100
    eq(F.import_need(F.stock_view(gD.iface, gD1.iface), "coal") > 0, true, "though the target still wants more")
    F.trade(gS.iface); eq(cargo_to("gradD", "coal"), 0, "two comfortable stores trade nothing"); eq(gS1.held.coal, 100, "the source keeps its own")
    eq(F.trade(gS.iface, true).gradD, nil, "the preview shows no cargo either")
    -- the boundary: a destination price exactly the source's buy price still takes goods
    gS1.held.coal, gD1.held.coal = 100, 86
    eq(price(gD, gD1), F.buy_price(price(gS, gS1)), "86 of 200 sells at exactly 330, the source's buy price")
    F.trade(gS.iface); eq(cargo_to("gradD", "coal"), 5, "an equal price moves goods"); eq(gS1.held.coal, 95, "5% of 100 left the source")
    advance_convoys(gS)
    gS1.held.coal, gD1.held.coal = 20, 160
    F.trade(gS.iface); eq(cargo_to("gradD", "coal"), 0, "goods never move downhill"); eq(gS1.held.coal, 20, "whatever the target says")
    eq(F.trade(gS.iface, true).gradD, nil, "and the preview agrees")
    -- each store is priced for its own faction: the Exchange prices gradS's coal at 1 gold and gradD's at 9
    local ex_was = EX
    EX = { lot = function() return 1 end, subject = nil,
           with_player = function(f, fn) EX.subject = f; local ok = pcall(fn); EX.subject = nil; return ok end,
           sell_price = function() return EX.subject == "gradS" and 1 or 9 end }
    gS1.held.coal, gD1.held.coal = 160, 20
    eq(price(gS, gS1), 55, "gradS's store at its own 1 gold"); eq(price(gD, gD1), 1440, "gradD's at its own 9 gold")
    eq((F.trade(gS.iface, true).gradD or {})[1], "coal", "the preview prices each side for its own faction")
    F.trade(gS.iface); eq(cargo_to("gradD", "coal"), 8, "so the dear store takes from the cheap one"); eq(gS1.held.coal, 152, "and the cheap one gave")
    advance_convoys(gS)
    EX = ex_was
    -- before the first turn start the rates are not frozen: the same rule runs on the defaults
    F.state.rates = nil
    local gU = faction("gradU", { human = true }); local gU1 = region("gradU1", 8200, 0, 200, { coal = 160 }); own(gU, gU1, true)
    local gV = faction("gradV", { human = true }); local gV1 = region("gradV1", 8300, 0, 200, {}); own(gV, gV1, true)
    gU.partners, gV.partners = { gV }, { gU }
    F.set_stock_policy("gradV", "coal", "target", "200")
    F.trade(gU.iface); eq(cargo_to("gradV", "coal") > 0, true, "an empty partner draws goods before the rates are frozen")
    gS.partners, gD.partners, gU.partners, gV.partners = {}, {}, {}, {}
    F.state.rates = rates; rates.upkeep = upkeep_was
end
do
    -- AN AGREEMENT SELLS FROM THE EXPORTER'S CHEAPEST STORE: a full small store feeds a short partner while the
    -- big capital sits at half (3.30 to buy, dearer than the partner's 3.21) and would be refused by the price gate
    local rates = F.state.rates; local upkeep_was = rates.upkeep; rates.upkeep = false
    local cX = faction("cheapX", { human = true })
    local cX1 = region("cheapX1", 8400, 0, 1000, { coal = 500 }); own(cX, cX1, true)
    local cX2 = region("cheapX2", 8450, 0, 200, { coal = 200 }); own(cX, cX2)
    local cY = faction("cheapY", { human = true }); local cY1 = region("cheapY1", 8500, 0, 1000, { coal = 450 }); own(cY, cY1, true)
    cX.partners, cY.partners = { cY }, { cX }
    F.set_stock_policy("cheapY", "coal", "target", "1000")
    local function price(f, r) return F.local_price(F.stock_view(f.iface, r.iface), "coal", f.name) end
    eq(F.buy_price(price(cX, cX1)), 330, "the capital at 500 of 1,000 costs 3.30 to buy"); eq(F.buy_price(price(cX, cX2)), 82, "the full minor 0.82")
    eq(price(cY, cY1), 321, "the partner's capital at 450 of 1,000 is worth 3.21")
    eq(F.import_need(F.stock_view(cY.iface, cY1.iface), "coal") > 0, true, "and it still wants more")
    eq((F.trade(cX.iface, true).cheapY or {})[1], "coal", "the preview names the good")
    F.trade(cX.iface)
    eq(cX2.held.coal, 190, "the minor gave 5% of its 200"); eq(cX1.held.coal, 500, "the capital kept its stock")
    eq(cargo_to("cheapY", "coal"), 10, "and its convoy carries the 5% to the partner")
    eq(cY1.held.coal, 450, "nothing has landed yet")
    local cX3 = region("cheapX3", 8460, 0, 400, { coal = 380 }); own(cX, cX3)
    eq(F.price_mult(F.stock_view(cX.iface, cX3.iface), "coal"), F.price_mult(F.stock_view(cX.iface, cX2.iface), "coal"), "190 of 200 and 380 of 400 price alike")
    eq(F.cheapest_store(F.stock_views(cX.iface), "coal").region:name(), "cheapX3", "on a tie the store with more to spare gives")
    cX.partners, cY.partners = {}, {}
    rates.upkeep = upkeep_was
end

-- ---- the player's trade switches (the Stores panel's Trade tab) ------------------------
local tP = faction("tP", { human = true })
local tP1 = region("tP1", 1200, 0, 600, { coal = 100 }); own(tP, tP1, true)
local tQ = faction("tQ"); local tQ1 = region("tQ1", 1300, 0, 600, { iron = 250 }); own(tQ, tQ1, true)
tP.partners = { tQ }; tQ.partners = { tP }
F.state.rates.upkeep = true
F.set_stock_policy("tP", "iron", "target", "100")
F.set_stock_policy("tP", "coal", "keep", "0")
F.toggle("tP", "export", "coal"); eq(F.stopped("tP", "export", "coal"), true, "a click stops a good's exports")
F.trade(tP.iface); eq(tP1.held.coal, 100, "a stopped export stays home"); eq(cargo_to("tQ", "coal"), 0, "and no convoy carries it")
F.toggle("tP", "export", "coal"); eq(F.stopped("tP", "export", "coal"), false, "a second click allows it again")
F.trade(tP.iface); eq(tP1.held.coal, 100, "an allowed export still needs partner demand")
F.toggle("tP", "import", "iron")
F.trade(tQ.iface); eq(cargo_to("tP", "iron"), 0, "a refused import is not sent"); eq(tQ1.held.iron, 250, "and the partner keeps it")
F.toggle("tP", "import", "iron"); F.trade(tQ.iface); eq(cargo_to("tP", "iron"), 5, "an accepted import is sent")
F.toggle("tQ", "export", "iron"); eq(F.stopped("tQ", "export", "iron"), false, "a computer-run faction has no switches")
F.toggle("tP", "sideways", "coal"); eq(F.stopped("tP", "sideways", "coal"), false, "an unknown direction is ignored")
F.toggle("tP", "export", "no_such_good"); eq(F.stopped("tP", "export", "no_such_good"), false, "an unknown good is ignored")
F.state.rates.upkeep = false

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
do
    -- TRADE REACH (author, 2026-10-22): an agreement whose road is too long, or runs through enemy or
    -- aggressive land, moves no resources and no duty; terrain_routes.lua R.reach answers, stubbed here
    local rA = faction("rA", { human = true }); local rA1 = region("rA1", 7000, 0, 600, { coal = 300 }); own(rA, rA1, true)
    -- as the first trade test's partner: a human whose capital holds 1, so a target of 50 is a real need
    local rB = faction("rB", { human = true }); local rB1 = region("rB1", 7100, 0, 600, { coal = 1 }); own(rB, rB1, true)
    local rB2 = region("rB2", 7150, 0, 600, {}); own(rB, rB2)
    rA.partners, rB.partners = { rB }, { rA }
    F.set_stock_policy("rB", "coal", "target", "50")
    local asked, open, why = {}, false, "far"
    DERPY_MR_TERRAIN_ROUTES = { reach = function(a, b, max)
        asked[#asked + 1] = a:name() .. ">" .. b:name() .. "@" .. tostring(max)
        return open, why
    end }
    local t0 = TURN; TURN = 900
    F.trade(rA.iface); eq(cargo_to("rB", "coal"), 0, "a partner out of reach gets no resources")
    eq(table.concat(asked, " "), "rA1>rB1@" .. F.rates().reach * 40, "asked capital to capital, the reach in hexes")
    eq(F.rates().reach, 6, "six turns unless the settings say otherwise")
    F.trade(rB.iface); F.trade(rA.iface); eq(#asked, 1, "one answer per pair per turn, whichever side asks")
    local cut = F.cut_off(rA.iface)
    eq(#cut == 1 and cut[1].key .. ": " .. cut[1].why, "rB: Too far for trade", "the Trade tab lists who and why")
    rB1.made = { coal = 30 }; local a0 = TREASURY.rA or 0
    F.made_cache = nil; F.duty(rA.iface); eq((TREASURY.rA or 0) - a0, 0, "no trade, no duty")
    why = "enemy"
    local st, said = F.route_status(rA.iface, { seller = "rB", from = "rB2", to = "rA1", stem = "coal" })
    eq(st == nil and said, "Cut off by enemy lands", "a partner contract between two settlements is judged on its own road")
    open, why = true, nil; TURN = 901
    F.trade(rA.iface); eq(cargo_to("rB", "coal"), 15, "back in reach, the same trade runs")
    eq(#asked, 3, "and a new turn asks again")   -- the capitals twice, and the contract's own pair once
    F.made_cache = nil; a0 = TREASURY.rA or 0; F.duty(rA.iface)
    eq((TREASURY.rA or 0) - a0 < 0, true, "and duty is paid again"); eq(#F.cut_off(rA.iface), 0, "nobody listed")
    -- the map and the panel read old answers; they never work one out in multiplayer, where only the
    -- economy's turn-start answers are the same on every machine
    TURN = 902; MP = true
    eq(F.trade_reach(rA.iface, rB.iface, "peek"), true, "an answer from an earlier turn still serves the map")
    local rC = faction("rC"); local rC1 = region("rC1", 7200, 0, 600, {}); own(rC, rC1, true)
    eq(F.trade_reach(rA.iface, rC.iface, "show"), nil, "unknown in multiplayer: nothing worked out")
    eq(#asked, 3, "and nothing asked")
    MP = false
    eq(F.trade_reach(rA.iface, rC.iface, "show"), true, "single player works it out for the map")
    for _,event in ipairs({'FactionLeaderDeclaresWar','PositiveDiplomaticEvent','NegativeDiplomaticEvent','RegionFactionChangeEvent'}) do
        open=false; why='enemy'
        DERPY_MR_TERRAIN_ROUTES.queue={{key='stale'}}
        DERPY_MR_TERRAIN_ROUTES.cache={stale=true}
        local epoch = DERPY_MR_TERRAIN_ROUTES.epoch or 0
        fire(event,{region=function() return rA1.iface end})
        eq(#DERPY_MR_TERRAIN_ROUTES.queue,0,'discard obsolete queued paths')
        -- the map checks its roads again (R.path) and keeps the old line up until then (2026-10-29)
        eq(DERPY_MR_TERRAIN_ROUTES.cache.stale,true,'the old line stays up until its road is checked')
        eq(DERPY_MR_TERRAIN_ROUTES.epoch,epoch+1,event..' has the map check its roads again')
        eq(F.trade_reach(rA.iface,rB.iface,'peek'),nil,event..' invalidates the displayed road')
        eq(F.trade_reach(rA.iface,rB.iface),false,event..' recomputes reach within this turn')
        open=true;why=nil
        F.invalidate_reach()
        eq(F.trade_reach(rA.iface,rB.iface),true,'a reopened road trades again')
    end
    DERPY_MR_TERRAIN_ROUTES = nil; rA.partners, rB.partners = {}, {}; TURN = t0
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
eq(F.state.factions.tC, nil, "no history for a computer-run faction")

-- the six convoys the trade cases above left on the road: none of what follows is about them
F.state.convoys = {}
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

-- ---- saved convoys: the load keeps the well-formed ones (agreement cargo, Task 4) ----------------------
-- Its own block with its own F.state: every case goes through the real save callback and the real load
-- callback, and the global it changes (F.state, SAVED) is put back at the end.
;(function()
    local state, saved = F.state, SAVED
    local P, NONE = F.CONVOY_PREFIX, {}
    -- a good convoy; over = { field = value }, NONE takes the field out
    local function cv(n, over)
        local c = { id = P .. n, f = "svE", buyer = "svB", from = "svE1", to = "svB1", basket = { coal = 5 },
                    at = 10, due = 12, road = "0:0;1:0;2:0", x = 0, y = 0 }
        for k, v in pairs(over or {}) do if v == NONE then c[k] = nil else c[k] = v end end
        return c
    end
    -- save a state holding these convoys, forget it, load it; the convoy list the load leaves
    local function reload(convoys, seq)
        F.state = { factions = {}, convoys = convoys, convoy_seq = seq }
        SAVED = {}; cm.saving_game_callbacks[1]({})
        F.state = {}; cm.loading_game_callbacks[1]({})
        return F.convoys()
    end

    -- THE BRIEF: one good, one with no due, one with a negative amount; the sequence is not pulled down by the ones that went
    local list = reload({ cv(3), cv(4, { due = NONE }), cv(5, { basket = { coal = -3 } }) }, 5)
    whole(SAVED.derpy_mr_flows, "state")
    eq(#list, 1, "malformed convoys dropped"); eq(list[1].id, P .. "3", "the good one is the one kept")
    eq(list[1].basket.coal, 5, "with its basket"); eq(list[1].road, "0:0;1:0;2:0", "and its road")
    eq(F.state.convoy_seq, 5, "a saved sequence above the kept ids stays: a delivered convoy's number is not reused")
    -- the sequence otherwise follows the kept ones
    reload({ cv(3) }, nil); eq(F.state.convoy_seq, 3, "no saved sequence: the sequence continues from the kept id")
    reload({ cv(3) }, 1); eq(F.state.convoy_seq, 3, "a saved sequence below a kept id is raised to it")
    reload({ cv(3) }, 2.5); eq(F.state.convoy_seq, 3, "a fraction is no sequence")
    reload({ cv(3) }, "9"); eq(F.state.convoy_seq, 3, "nor is a string")
    -- a save from before convoys, or one whose list is no list
    eq(reload(nil, nil)[1], nil, "old save: empty list"); eq(#F.convoys(), 0, "old save: empty list, counted")
    eq(F.state.convoys, nil, "and loading made no list")
    reload(nil, 7); eq(F.state.convoy_seq, 7, "a saved sequence with no list is kept")
    eq(#reload("junk", nil), 0, "a list that is no list: nothing on the road"); eq(F.state.convoys, nil, "and none made")
    list = reload({ 7, "x", true, cv(1), cv(2) }, nil)
    eq(#list, 2, "entries that are no tables are dropped"); eq(list[1].id, P .. "1", "the convoys among them are kept"); eq(list[2].id, P .. "2", "in order")
    eq(#reload({ cv(1, { due = NONE }) }, nil), 0, "an existing list that loses every record loads empty")

    -- ONE RULE AT A TIME: the bad one sits between two good ones, so a load that stopped at it or dropped all of them fails too
    local drops = {
        { "id from another prefix", { id = "cv_3" } }, { "id of no digits", { id = P } },
        { "id with a tail", { id = P .. "3x" } }, { "id with a head", { id = "x" .. P .. "3" } },
        { "id that is a number", { id = 3 } }, { "id past the whole-number limit", { id = P .. "99999999999" } },
        { "no id", { id = NONE } },
        { "exporter not a string", { f = 5 } }, { "buyer missing", { buyer = NONE } },
        { "from not a string", { from = {} } }, { "to not a string", { to = false } },
        { "no basket", { basket = NONE } }, { "basket a string", { basket = "coal" } }, { "empty basket", { basket = {} } },
        { "amount zero", { basket = { coal = 0 } } }, { "amount negative", { basket = { coal = -3 } } },
        { "amount a fraction", { basket = { coal = 2.5 } } }, { "amount a string", { basket = { coal = "5" } } },
        { "amount past the limit", { basket = { coal = 2000000 } } },
        { "a good that does not exist", { basket = { nothing_here = 3 } } },
        { "one bad good among good ones", { basket = { coal = 5, nothing_here = 3 } } },
        { "no turn it left", { at = NONE } }, { "turn it left a fraction", { at = 1.5 } },
        { "no due", { due = NONE } }, { "due a string", { due = "12" } }, { "due a fraction", { due = 12.5 } },
        { "due before it left", { due = 9 } },
        { "x a fraction", { x = 1.5 } }, { "y a string", { y = "0" } },
        { "x without y", { y = NONE } }, { "y without x", { x = NONE } },
        { "road a number", { road = 5 } }, { "road of no points", { road = "" } }, { "road that is not one", { road = "nothing" } },
    }
    for _, d in ipairs(drops) do
        list = reload({ cv(1), cv(3, d[2]), cv(2) }, nil)
        eq(#list, 2, "dropped: " .. d[1]); eq(list[1].id, P .. "1", "the one before it is kept: " .. d[1])
        eq(list[2].id, P .. "2", "and the one after it: " .. d[1])
        eq(F.state.convoy_seq, 2, "a dropped record does not move the sequence: " .. d[1])
    end
    -- the edges of those rules that stay in
    local keeps = {
        { "due the turn it left", { due = 10 } }, { "no road", { road = NONE } },
        { "a road and no position", { x = NONE, y = NONE } }, { "no road and no position", { road = NONE, x = NONE, y = NONE } },
        { "several goods", { basket = { coal = 5, iron = 2 } } },
    }
    for _, k in ipairs(keeps) do
        list = reload({ cv(1), cv(3, k[2]), cv(2) }, nil)
        eq(#list, 3, "kept: " .. k[1]); eq(F.state.convoy_seq, 3, "and its number counts: " .. k[1])
    end

    -- WHAT A KEPT CONVOY IS FOR: the next convoy takes the next number, and a record with no due never reaches F.ship_due
    local e, b = faction("svE", { human = true }), faction("svB", { human = true })
    local er, br = region("svE1", 0, 0, 600, {}), region("svB1", 5, 0, 600, {})
    own(e, er, true); own(b, br, true)
    reload({ cv(3) }, nil)
    eq(F.incoming("svB", "svB1", "coal"), 5, "a convoy that survived the load counts as incoming")
    eq(F.stock_view(b.iface, br.iface).due[1].due, 12, "with its arrival turn in the buyer's store view")
    eq(F.convoy_new(e.iface, b.iface, { coal = 1 }).id, P .. "4", "and the next convoy is numbered after it")
    reload({ cv(3, { due = NONE }) }, nil)
    eq(F.incoming("svB", "svB1"), 0, "a convoy with no due is not on the road")
    eq(#F.stock_view(b.iface, br.iface).due, 0, "and its store view reads no arrival turn from it")
    eq(#ERRORS, 0, "no script errors loading convoys: " .. table.concat(ERRORS, "; "))
    F.state, SAVED = state, saved
end)()

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
    function o:add_dropdown_value(key, _text, _tip, default)
        self.values = self.values or {}; self.values[#self.values + 1] = key
        if default then self.flagged = key end
    end
    function o:set_locked(v, why) self.locked, self.why = v, why end
    function o:set_is_global(v) self.global = v end
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
eq(DERPY_MR_FLOWS_DEFAULTS.army_provisions, true, "new campaigns enable provisions")
-- THE ROUTE LINES move no goods, so a campaign leaves them open; their values are terrain_routes.lua's R.SIZES
-- and R.SETS, in that order (build_mr_terrain_routes --selftest compares the Lua to the scenes)
local LINES = { route_size = { "small", "normal", "large", default = "small" },
                route_colours = { "default", "bright", "pale", "colourblind", default = "default" } }
for k, o in pairs(opt) do
    if LINES[k] then
        eq(o.locked, nil, "a campaign leaves " .. k .. " open")
        eq(table.concat(o.values, ","), table.concat(LINES[k], ","), k .. "'s choices, in the scenes' order")
        eq(o.value, LINES[k].default, k .. "'s default"); eq(o.flagged, LINES[k].default, "and the list marks it")
        eq(F.mct(k), LINES[k].default, "F.mct reads " .. k)
    elseif k == "ui_size" then
        -- THE PANEL SIZE changes this screen alone: open in a campaign, and each player's own
        eq(o.locked, nil, "a campaign leaves the panel size open")
        eq(o.global, true, "the panel size is each player's own in multiplayer")
        eq(table.concat(o.values, ","), "small,medium,large", "the panel size's choices")
        eq(o.value, "medium", "Medium by default"); eq(o.flagged, "medium", "and the list marks it")
    elseif k:match('^route_') then
        eq(o.locked,nil,'visibility stays editable in a campaign')
        eq(o.value,true,'route visuals default on')
    else
        eq(o.locked, true, "a campaign greys " .. k); eq(type(o.why) == "string" and #o.why > 0, true, "and says why")
    end
end
eq(opt.route_size ~= nil and opt.route_colours ~= nil, true, "both line options are on the page")
eq(opt.ui_size ~= nil, true, "the panel size is on the page")
opt.route_colours.value = "pale"; eq(F.mct("route_colours"), "pale", "a change reaches the map's next redraw")
opt.route_colours.value = "default"
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
F.state.rates.army_provisions = false
F.freeze_rates(); eq(F.rates().army_provisions, false, "existing campaign provisions stay off")
F.state = { factions = {} }; F.on_faction_turn_start(faction("fz").iface)
eq(F.state.rates and F.state.rates.raid, 40, "a turn start freezes too (a save from before first tick froze)")
-- AT FIRST TICK: a new campaign fires no FactionTurnStart until turn 1 ends. F.init again, its
-- listeners dropped after, so nothing below fires twice
do local n_listeners = #LISTENERS
F.state = { factions = {} }; F.started = false; F.init()
for i = #LISTENERS, n_listeners + 1, -1 do LISTENERS[i] = nil end end
eq(F.state.rates and F.state.rates.raid, 40, "the first tick freezes the rates")
-- TURN OFF RANDOM DILEMMAS: unticked, the game's own generation is never touched (a Tides of Lore
-- start turns it off itself); ticked, every load turns it off; frozen, so never back on
do local n_listeners, GEN = #LISTENERS, {}
local function tick() F.started = false; F.init() end
cm.toggle_dilemma_generation = function(_, on) GEN[#GEN + 1] = on end
eq(DERPY_MR_FLOWS_DEFAULTS.random_off, false, "random dilemmas stay on by default")
F.state = { factions = {} }; tick(); eq(#GEN, 0, "unticked: the first tick leaves them alone")
opt.random_off.value = true; F.state = { factions = {} }; tick()
eq(#GEN, 1, "ticked: the first tick turns them off"); eq(GEN[1], false, "off, not on")
tick(); eq(#GEN, 2, "and again at every load"); eq(GEN[2], false, "off again")
opt.random_off.value = false; tick()
eq(GEN[3], false, "frozen: unticking it in a running campaign does not turn them back on")
MP = true; opt.random_off.value = true; F.state = { factions = {} }; tick()
eq(#GEN, 3, "multiplayer takes the default and leaves them alone")
MP = false; opt.random_off.value = false; cm.toggle_dilemma_generation = nil
for i = #LISTENERS, n_listeners + 1, -1 do LISTENERS[i] = nil end end
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
eq(F.rates().army_provisions, false, "pre-provisions saved settings retain the old default")
F.freeze_rates()
opt.upkeep.value = false; eq(F.rates().upkeep, true, "and the new one is frozen too")
get_mct = nil; F.state.rates = nil; F.freeze_rates()
eq(F.rates().army_provisions, true, "fresh no-MCT campaign provisions default on")
F.state.rates.army_provisions = false -- Legacy event fixtures do not model provision-capable forces.
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
eq(BUNDLES.u1[WF], 0, "kept on for good, not renewed each turn (2026-11-08)")
eq(has(u1, GS), true, "Garrison stocked: 60 war materials, a quarter of one store is 50")
eq(has(u1, CF), false, "no Comforts: 49 luxuries is under a quarter")
eq(u1.held.coal, 60, "war materials are not eaten"); eq(u1.held.silk, 49, "nor luxuries")
u1.held.coal, u1.held.silk = 10, 50; turn_start(uF)
eq(has(u1, GS), false, "Garrison stocked ends the turn the stock falls under a quarter")
eq(has(u1, CF), true, "Comforts at exactly a quarter")
-- KEPT, NOT RENEWED (2026-11-08: about 19,000 region bundle calls a computer round on the Old World map, which
-- ran about 85 s longer than with computer stores off)
do
    local kF = faction("kF", { human = true })
    local k1 = region("k1", 5300, 0, 1000, { grain = 600, coal = 600, silk = 600 }); k1.level = 1
    own(kF, k1, true)
    turn_start(kF)
    eq(has(k1, WF) and has(k1, GS) and has(k1, CF), true, "all three bonuses on")
    local calls, apply = 0, cm.apply_effect_bundle_to_region
    cm.apply_effect_bundle_to_region = function(self, b, rk, turns)
        if rk == "k1" and (b == WF or b == GS or b == CF) then calls = calls + 1 end
        return apply(self, b, rk, turns)
    end
    turn_start(kF)
    eq(calls, 0, "a settlement whose bonuses hold gets no bundle call the next turn")
    BUNDLES.k1[CF] = 2   -- put on by an older build, which renewed it each turn
    turn_start(kF)
    eq(calls, 1, "an older build's bundle is put on again"); eq(BUNDLES.k1[CF], 0, "for good")
    turn_start(kF)
    eq(calls, 1, "and only once")
    cm.apply_effect_bundle_to_region = apply
    F.on_region_change(k1.iface)
    eq(has(k1, WF) or has(k1, GS) or has(k1, CF), false, "a settlement changing hands loses them: they no longer lapse")
end
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
-- 50 grain is 25 turns of food: the computer's Rations edict (Part B) is Plenty before the meal, so 3
eq(f1.held.grain, 47, "switched on, they eat, at Plenty"); eq(has(f1, WF), true, "and are Well fed")
eq(F.state.factions.aF, nil, "with no ledger: only a player's panel reads it")
local before = u1.held.grain + u1.held.salt
F.state.rates.upkeep = false; turn_start(uF)
eq(u1.held.grain + u1.held.salt, before, "upkeep off: nothing eaten")
F.state.rates.upkeep = true
eq(#ERRORS, 0, "no script errors in the upkeep pass")

-- Lifecycle fixtures below disable upkeep bonuses; reserve-on cases are tested separately.
F.state.rates.upkeep = false
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
eq(sale.n, 10, "10 above half")
eq(sale.price, 87, "l1 at 190 of 200 sells at 0.87 a unit (war 3 gold, mult 32, less the spread), hundredths")
eq(sale.gold, 8, "10 units at l1's own sell price 0.87, floored")
eq(#sale.lots, 1, "one lot"); eq(sale.lots[1].region, "l1", "which store"); eq(sale.lots[1].n, 10, "how many from it")
eq(F.quote(lP.iface, sale.lots[1].from, "coal").sell, sale.lots[1].price, "the price the panel shows a seller is the lot's price")
F.request("lP", "sell", "coal")
eq(l1.held.coal, 180, "taken from the fullest store"); eq(l2.held.coal, 20, "not the other")
eq(TREASURY.lP, 8, "and paid the floored lot"); eq(F.book("lP").now.coal.sold_out, 10, "booked as sold")
F.request("lP", "sell", "coal"); eq(TREASURY.lP, 8, "nothing left to sell, nothing paid")
-- Two lots: the fuller store first, each at its own price; a Keep applies to every store
l1.held.coal = 200; l2.held.coal = 160; F.set_stock_policy("lP", "coal", "keep", 50)
sale = F.sale(lP.iface, "coal")
eq(sale.n, 160, "160 above half of 400, stock above Keep 150 + 110")
eq(#sale.lots, 2, "two lots"); eq(sale.lots[1].region, "l1", "the store with more to give first")
eq(sale.lots[1].n, 150, "all it can give above Keep"); eq(sale.lots[1].price, 68, "full store: mult 25, sell 0.68")
eq(sale.lots[2].region, "l2", "then the other"); eq(sale.lots[2].n, 10, "the rest"); eq(sale.lots[2].price, 150, "at 160 of 200: mult 55, sell 1.50")
eq(sale.gold, 102 + 15, "floor(150 * 0.68) + floor(10 * 1.50)")
eq(sale.price, 73, "weighted average of the lots' prices, hundredths")
F.request("lP", "sell", "coal")
eq(l1.held.coal, 50, "l1 down to Keep"); eq(l2.held.coal, 150, "l2 gave its 10")
eq(TREASURY.lP, 8 + 117, "paid the sum of the lots")
F.set_stock_policy("lP", "coal", "keep", "auto")
l1.held.coal = 190; l2.held.coal = 20
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
eq(xs.price, 1483, "a lot of 10 at 510 is 51 a unit, l1 (mult 32) sells at 16.32 less the spread")
eq(xs.gold, 148, "the Exchange's price for the SELLER, whoever's machine runs it, floored")
EX = ex_stub(function() error("the Exchange broke") end)
eq(F.sale(lP.iface, "coal").price, 87, "the store's own price on the fixed rate when the Exchange errors")
EX = ex_stub(function() return 0 end); eq(F.sale(lP.iface, "coal").price, 87, "or prices at nothing")
EX = nil
end
-- A store with no price (no room in its pool) gives no lot and is not drawn, though its stock counts
do
local uP = faction("uP", { human = true })
local u0 = region("u0", 8200, 0, 0, { coal = 300 }); own(uP, u0, true)
local u1 = region("u1", 8300, 0, 400, { coal = 100 }); own(uP, u1)
local us = F.sale(uP.iface, "coal")
eq(#us.lots, 1, "only the store with a price is a lot"); eq(us.lots[1].region, "u1", "the priced one, though the other holds more")
eq(us.n, 100, "all u1 has, short of the 200 the realm is over half by")
eq(us.price, 373, "u1 at 100 of 400: mult 137, price 4.11, sell 3.73"); eq(us.gold, 373, "paid for its lot only")
F.sell(uP.iface, "coal")
eq(u0.held.coal, 300, "the unpriced store is not drawn"); eq(u1.held.coal, 0, "the priced one is")
eq(TREASURY.uP, 373, "and paid")
end
-- A lot that would pay nothing once floored is not a lot: its unit stays in the store
do
local zP = faction("zP", { human = true })
local z1 = region("zs1", 8400, 0, 200, { coal = 200 }); own(zP, z1, true)
local z2 = region("zs2", 8500, 0, 200, { coal = 191 }); own(zP, z2)
F.set_stock_policy("zP", "coal", "keep", 190)
local zs = F.sale(zP.iface, "coal")
eq(zs.n, 10, "z2's unit is above Keep but sells at 0.84 and floors to 0 gold: not counted")
eq(#zs.lots, 1, "one lot"); eq(zs.lots[1].region, "zs1", "the full store"); eq(zs.gold, 6, "floor(10 * 0.68)")
F.request("zP", "sell", "coal")
eq(z1.held.coal, 190, "z1 down to Keep"); eq(z2.held.coal, 191, "z2 keeps its unit"); eq(TREASURY.zP, 6, "paid for the one lot")
end

-- ---- local prices ----
do
local upkeep_was = F.state.rates.upkeep
F.state.rates.upkeep = true
local pP = faction("pP", { human = true })
local p1 = region("p1", 9000, 0, 200, { coal = 0, grain = 0 }); own(pP, p1, true); p1.level = 1; p1.absent = { silk = true }
local v = F.stock_view(pP.iface, p1.iface)
eq(v.capacity.silk, nil, "an absent pool has no capacity")
eq(F.price_mult(v, "grain"), 175, "no cover: 175")                 -- eats 2 a turn, holds 0
p1.held.grain = 20; v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "grain"), 100, "ten turns of cover: 100")
p1.held.grain = 40; v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "grain"), 25, "twenty turns: 25, and never below")
p1.held.grain = 30; v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "grain"), 62, "fifteen turns: 100 + floor(75 * -50 / 100), rounded down")
p1.held.grain = 10; v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "grain"), 137, "five turns: 100 + floor(75 * 50 / 100)")
p1.held.salt = 10; v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "grain"), 100, "cover counts the whole category, salt too"); p1.held.salt = 0
v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "coal"), 175, "a good not eaten here: fullness, empty is 175")
p1.held.coal = 100; v = F.stock_view(pP.iface, p1.iface); eq(F.price_mult(v, "coal"), 100, "half full: 100")
p1.held.coal = 200; v = F.stock_view(pP.iface, p1.iface); eq(F.price_mult(v, "coal"), 25, "full: 25")
eq(F.price_mult(v, "silk"), nil, "no pool here: no price")
eq(F.local_price(v, "coal", "pP"), 75, "war materials at 300 hundredths times 25%")
eq(F.buy_price(75), 82, "buyer pays 110%, floored"); eq(F.sell_price(75), 68, "seller gets 100/110")
eq(F.gold(10, 75), 7, "ten units at 0.75 is 7 gold")
local q = F.quote(pP.iface, p1.iface, "grain")
eq(q.mult, 137, "quote carries the multiplier"); eq(q.cover, 5, "and the cover in turns"); eq(q.base, 100, "and the base in hundredths")
eq(F.quote(pP.iface, p1.iface, "silk"), nil, "no pool, no quote")
p1.held.grain = 100; v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "grain"), 25, "fifty turns of cover: still 25")
p1.held.coal = 300; v = F.stock_view(pP.iface, p1.iface)
eq(F.price_mult(v, "coal"), 25, "overfull: still 25")
local pZ = faction("pZ", { human = true })
local p0 = region("p0", 9500, 0, 0, {}); own(pZ, p0, true)
eq(F.price_mult(F.stock_view(pZ.iface, p0.iface), "coal"), nil, "a pool with no room has no price")
F.state.rates.upkeep = upkeep_was
end

-- EVERY ACTION GOES THROUGH UITrigger in multiplayer; computer factions and the switch refuse
MP = true; SENT = {}
F.request("lP", "sell", "coal")
eq(SENT[1][2], "dmr1|sell|coal", "multiplayer: sent, not run"); eq(TREASURY.lP, 125, "nothing paid yet")
ui_trigger(SENT[1][1], SENT[1][2]); eq(TREASURY.lP, 133, "the trigger runs it, l1's 10 at 0.87 paying 8")
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
l1.held.coal = 190; F.request("lP", "sell", "coal"); eq(TREASURY.lP, 133, "switched off: no sale")
F.request("lP", "export", "coal"); eq(F.stopped("lP", "export", "coal"), true, "but trade switches still work")
-- THE MAP'S CART GOODS come from kept trade previews (terrain_routes.lua R.plans): a player's action has them
-- worked out again on the map's next tick, not when that seller's renewal comes round (2026-10-30)
local routes = DERPY_MR_TERRAIN_ROUTES
DERPY_MR_TERRAIN_ROUTES = { plans = { lP = {} }, dirty = false }
F.request("lP", "import", "iron")
eq(next(DERPY_MR_TERRAIN_ROUTES.plans), nil, "a trade switch left the map's cart goods as they were")
eq(DERPY_MR_TERRAIN_ROUTES.dirty, true, "a trade switch waited for the map's timer")
F.request("lP", "import", "iron")
DERPY_MR_TERRAIN_ROUTES.plans, DERPY_MR_TERRAIN_ROUTES.dirty = { ai1 = {} }, false
F.dispatch("ai1", { "sell", "coal" })
eq(DERPY_MR_TERRAIN_ROUTES.dirty, false, "a computer-run faction's request redrew the map")
DERPY_MR_TERRAIN_ROUTES = routes
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
             is_null_interface = function() return false end,   -- F.captor skips a force a battle has destroyed
             has_general = function() return true end,
             force_type = function() return { key = function() return "ARMY" end } end,
             command_queue_index = function() return cqi + 1000 end,
             has_garrison_residence = function() return false end,
             active_stance = function() return (STANCES or {})[cqi + 1000] or "MILITARY_FORCE_ACTIVE_STANCE_TYPE_DEFAULT" end,
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
eq(BUNDLES.pc[SP.materials.bundle], 0, "kept on for good, like the stores' other bonuses")
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
eq(po.held.timber, 72, "28 sent to deliver the missing 25")
eq(s5.n, 25, "25 net cargo after rounded loss")
eq(pc.held.timber, 11, "the capital still pays this turn")
eq(MARKERS[s5.id].info, SH.info, "drawn as a shipment marker"); eq(MARKERS[s5.id].r, SH.radius, "of its radius")
eq(MARKERS[s5.id].x, po.x + 1, "beside the sender, where CA finds a spot")
eq(MARKERS[s5.id].f, "", "any faction can walk into it")
eq(SCENES[s5.id] ~= nil, true, "a scene drawn over the marker")
eq(SCENES[s5.id].key, SH.scene, "the wagon circle"); eq(type(SH.scene), "string", "named by the generator")
eq(SCENES[s5.id].x, MARKERS[s5.id].x, "on the marker's spot"); eq(SCENES[s5.id].one_shot, false, "and removable")
eq(SCENES[s5.id].seen, true, "seen through thin shroud"); eq(SCENES[s5.id].unseen, false, "not through thick")
TURN = 4011; turn_start(pP)
eq(ships_of("pP"), 1, "one already on the road for it: no second")
eq(MARKERS[s5.id].x, pc.x + 1, "the second turn: beside the capital")
eq(SCENES[s5.id] and SCENES[s5.id].x, pc.x + 1, "and its wagons with it")
eq(s5.x, pc.x + 1, "and the shipment is where its marker is"); eq(pc.held.timber, 7, "paid")
pc.held.timber = 2
TURN = 4012; turn_start(pP)
eq(ships_of("pP"), 0, "arrived"); eq(MARKERS[s5.id], nil, "its marker gone")
eq(SCENES[s5.id], nil, "and its wagons")
eq(pc.held.timber, 2 + 25 - 4, "it arrives before the turn's payment, which 2 alone could not make")
eq(F.supply_state(pP.iface, "pc").on.materials, true, "so the supply stays on")
eq(F.book("pP").now.timber.moved_in, 25, "booked as moved in")
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
eq(MARKERS[gs.id], nil, "the marker goes"); eq(SCENES[gs.id], nil, "and its wagons")
eq(F.state.factions.rA, nil, "a computer keeps no ledger")
-- SEEN WHERE IT STANDS NOW (final review, 2026-11-02): the enemy list is keyed by the turn number, which spans a
-- round. Made earlier in the round (the map's plan refresh, another faction's turn start), it kept the armies where
-- they stood then, and the owner's own turn start seized by those places.
g1.held.coal = 50; TURN = 5003; F.request("gP", "send", "coal", "g2")
local gs2 = last_ship()
TURN = 5004
rA.armies = { field(rA, gs2.x + SH.near + 5, gs2.y, 505) }
F.enemy_armies(gP.iface)   -- asked earlier in the round, with the army out of reach
rA.armies = { field(rA, gs2.x, gs2.y + SH.near, 505) }   -- it marches up before gP's turn starts
turn_start(gP)
eq(ships_of("gP"), 0, "an army that marched up this round seizes it: the turn start reads where it stands now")
rr.held.coal = 45
rA.armies = {}
-- SEIZED BY WALKING IN: AreaEntered, an army only, at war only
g1.held.coal = 50; TURN = 5100; F.request("gP", "send", "coal", "g2"); gs = last_ship()
enter(gs.id, walker(gP, true)); eq(ships_of("gP"), 1, "its owner's own army passes")
enter(gs.id, walker(fA, true)); eq(ships_of("gP"), 1, "a faction at peace passes")
enter(gs.id, walker(rA, false)); eq(ships_of("gP"), 1, "a hero alone does not seize")
enter("someone_elses_marker", walker(rA, true)); eq(ships_of("gP"), 1, "another marker is not ours")
enter(gs.id, walker(rA, true)); eq(ships_of("gP"), 0, "an army at war seizes it")
eq(rr.held.coal, 90, "into the captor's settlement"); eq(MARKERS[gs.id], nil, "and the marker goes")
eq(SCENES[gs.id], nil, "seized: its wagons go")
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
eq(SCENES[ds.id], nil, "and its wagons")
-- ...and its event and supply records leave the save; a live faction's stay
F.event_book("dP").at = 5300; F.supply_book("dP", "prov_d", true).materials = true
F.event_book("gP").at = 5300; F.supply_book("gP", "prov_g", true).materials = true
TURN = 5303; turn_start(gP)
eq(F.state.events.dP, nil, "a dead faction's event record goes"); eq(F.state.supply.dP, nil, "and its supply switches")
eq(F.state.events.gP.at, 5300, "a live faction's event record stays"); eq(F.state.supply.gP.prov_g.materials, true, "and its switches")
F.state.supply.gP = nil

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

-- ---- agreement convoys (spec 2026-10-23, section 5.1): goods leave as a convoy, nothing lands that turn ----
;(function()
    local saved, turn, routes, known = F.state, TURN, DERPY_MR_TERRAIN_ROUTES, F.reach_known
    eq(routes, nil, "no terrain stub is standing")
    F.state = { factions = {}, rates = F.read_rates() }
    for _, k in ipairs({ "upkeep", "supply", "events", "army_provisions", "escort" }) do F.state.rates[k] = false end
    F.reach_known, TURN = {}, 310000
    local made = {}
    -- a human exporter and a human buyer (a target is a human's setting), one settlement each, a target of 5
    local function pair(tag, ex, bx, held, targets)
        local e, b = faction("cv" .. tag .. "E", { human = true }), faction("cv" .. tag .. "B", { human = true })
        local er, br = region("cv" .. tag .. "E1", ex, 0, 600, held), region("cv" .. tag .. "B1", bx, 0, 600, {})
        own(e, er, true); own(b, br, true)
        e.partners, b.partners = { b }, { e }
        made[#made + 1] = e; made[#made + 1] = b
        for _, stem in ipairs(targets) do F.set_stock_policy(b.name, stem, "target", "5") end
        return e, b, er, br
    end
    local function newest() local l = F.convoys(); return l[#l] end

    -- THE GOODS LEAVE: debited at dispatch, nothing arrives, one convoy carries them
    local e, b, er, br = pair("1", 0, 400, { coal = 100 }, { "coal" })
    local c0 = er.held.coal
    F.trade(e.iface)
    eq(er.held.coal, c0 - 5, "debited at dispatch")
    eq(LOG[#LOG][1] .. " " .. LOG[#LOG][2] .. " " .. LOG[#LOG][3], "cv1E1 derpy_mr_store_coal_traded -5",
       "the departure is booked on the traded factor, not the moved one a cart books")
    eq(br.held.coal or 0, 0, "nothing arrives the turn it leaves")
    eq(#F.convoys(), 1, "one convoy for the one partner")
    local c = F.convoys()[1]
    eq(c.f, "cv1E", "the exporter owns it"); eq(c.buyer, "cv1B", "bound for the buyer")
    eq(c.from, "cv1E1", "from the exporter's capital"); eq(c.to, "cv1B1", "to the buyer's capital")
    eq(c.basket.coal, 5, "carrying the share the partner needs"); eq(c.at, TURN, "it left this turn")
    eq(c.due, c.at + 1, "no grid in the stub: one turn")
    eq(c.road, nil, "no road to pack"); eq(c.x, 0, "it waits at the exporter's capital"); eq(c.y, 0, "on its row")
    eq(c.id, F.CONVOY_PREFIX .. "1", "named by the sequence"); eq(F.state.convoy_seq, 1, "which the save keeps")
    eq((F.book("cv1E").now.coal or {}).traded_out, 5, "the exporter's ledger books the departure")
    eq((F.book("cv1B").now.coal or {}).traded_in, nil, "and the buyer's books nothing yet")
    F.trade(e.iface, true)
    eq(#F.convoys(), 1, "a preview writes no convoy"); eq(er.held.coal, c0 - 5, "and debits nothing")

    -- THE ROAD: the reach path, packed, starting at the exporter, three turns for 81 steps
    local road = road_82()
    DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, road end }
    local e2, b2, er2, br2 = pair("2", 81, 0, { coal = 100 }, { "coal" })
    F.reach_known = {}       -- no answer standing: the road comes from the call that just made it
    F.trade(e2.iface)
    local c2 = newest()
    eq(c2.f, "cv2E", "the second pair's convoy"); eq(er2.held.coal, 95, "debited")
    eq(c2.id, F.CONVOY_PREFIX .. "2", "the next convoy takes the next number"); eq(F.state.convoy_seq, 2, "and the sequence moves on")
    eq(c2.due, c2.at + 3, "81 steps at 40 a turn: three turns")
    eq(type(c2.road), "string", "the road is one packed string")
    eq(#F.unpack_road(c2.road), 82, "with every point"); eq(F.unpack_road(c2.road)[1][1], 81, "the road starts at the exporter")
    eq(F.unpack_road(c2.road)[82][1], 0, "and ends at the buyer"); eq(c2.x, 81, "the convoy waits at the exporter's capital"); eq(c2.y, 0, "on its row")
    eq(road[1][1], 0, "the path F.reach keeps is not turned round in place")
    local e3, b3, er3 = pair("3", 0, 81, { coal = 100 }, { "coal" })
    F.trade(e3.iface)
    local c3 = newest()
    eq(c3.f, "cv3E", "the third pair's convoy")
    eq(F.unpack_road(c3.road)[1][1], 0, "a road that already leaves the exporter is kept as it is"); eq(c3.x, 0, "and the convoy starts there")
    eq(F.unpack_road(c3.road)[82][1], 81, "ending at the buyer")
    -- CARGO ON THE ROAD COUNTS AS INCOMING (Task 2): the buyer's targets, reserves, forecasts and next trade all see it
    eq(F.incoming("cv2B", "cv2B1", "coal"), 5, "cargo on the road counts")
    local v2 = F.stock_view(b2.iface, br2.iface)
    eq(v2.incoming.coal, 5, "the buyer's store view counts it")
    eq(v2.due[1].due, c2.due, "with its arrival turn"); eq(v2.due[1].due, c2.at + 3, "the road's three turns, not the cart pace")
    eq(v2.due[1].stem, "coal", "naming its good"); eq(v2.due[1].n, 5, "and its amount")
    eq(F.stock_forecast(v2)[F.GOOD.coal.use].incoming, 5, "the forecast counts it as incoming")
    eq(F.incoming("cv2E", "cv2B1", "coal"), 0, "the exporter is owed nothing"); eq(F.incoming("cv2B", "cv2E1", "coal"), 0, "nor is another store")
    eq(F.incoming("cv2B", "cv2B1", "iron"), 0, "and no other good is on the road")
    -- only F.convoy_new creates the list, so a save with no convoys stays without one
    local list = F.state.convoys; F.state.convoys = nil
    eq(#F.ships_to("cv2B", "cv2B1"), 0, "no convoys, nothing on the road"); eq(F.state.convoys, nil, "and reading made no list")
    F.state.convoys = list
    c2.basket.iron = 0
    eq(#F.ships_to("cv2B", "cv2B1"), 1, "an emptied basket entry is not on the road"); c2.basket.iron = nil
    -- THE NEXT TRADE SEES THE ROAD: a target of 8 is first 5, then what the road leaves of the need, then nothing
    local e10, b10, er10, br10 = pair("10", 0, 81, { coal = 100 }, { "coal" })
    F.set_stock_policy(b10.name, "coal", "target", "8")
    local need0 = F.import_need(F.stock_view(b10.iface, br10.iface), "coal")
    eq(need0, 8, "the buyer's need is its target")
    F.trade(e10.iface)
    eq(newest().basket.coal, 5, "the first convoy carries 5")
    eq(F.import_need(F.stock_view(b10.iface, br10.iface), "coal"), need0 - 5, "the cargo on the road comes off the need")
    local sent10 = #F.convoys()
    TURN = TURN + 1; F.trade(e10.iface)
    eq(#F.convoys(), sent10 + 1, "the next turn's trade sends a second convoy")
    eq(newest().basket.coal, 3, "carrying only what the first left of the need (min of 4 and 3)")
    eq(er10.held.coal, 92, "debited for both")
    eq(F.import_need(F.stock_view(b10.iface, br10.iface), "coal"), 0, "the target is now covered by cargo")
    TURN = TURN + 1; F.trade(e10.iface)
    eq(#F.convoys(), sent10 + 1, "a third turn with the target covered sends none"); eq(er10.held.coal, 92, "and takes nothing")
    -- the duration: steps, not points; never more than the reach, never under one
    local function steps(n) local p = {}; for i = 0, n do p[#p + 1] = { i, 0 } end return p end
    eq(F.convoy_turns(nil), 1, "no road: one turn"); eq(F.convoy_turns({ { 0, 0 } }), 1, "a road of one point is still a turn")
    eq(F.convoy_turns(steps(40)), 1, "40 steps is a turn"); eq(F.convoy_turns(steps(41)), 2, "41 steps is two")
    eq(F.convoy_turns(steps(81)), 3, "81 steps is three"); eq(F.convoy_turns(steps(400)), 6, "never past the trade reach")
    F.state.rates.reach = 2; eq(F.convoy_turns(steps(400)), 2, "the reach setting is the limit"); F.state.rates.reach = 6
    -- a road is its HEXES, not its points: a bridge is one point and as many hexes as the reach search charged it
    eq(F.road_steps({}), 0, "no points, no hexes"); eq(F.road_steps({ { 4, 4 } }), 0, "one point, no hexes")
    eq(F.road_steps(steps(40)), 40, "unit steps count one each"); eq(F.road_steps({ { 0, 0 }, { 3, -5 } }), 5, "a jump is its longer span")
    eq(F.road_steps({ { 7, 7 }, { 7, 7 } }), 1, "and no move is still a hex")
    eq(F.road_steps({ { 0, 0 }, { 40, 0 }, { 80, 0 }, { 81, 0 } }), 81, "two bridges of 40 and a step: 81 hexes in four points")
    eq(F.convoy_turns({ { 0, 0 }, { 40, 0 }, { 80, 0 }, { 81, 0 } }), 3, "81 hexes are three turns, not the one that four points would be")
    eq(F.pack_road({ { 1, 2 }, { 30, 4 } }), "1:2;30:4", "x:y points joined by semicolons")
    local back = F.unpack_road("1:2;30:4")
    eq(#back, 2, "two points back"); eq(back[2][1], 30, "in order"); eq(back[2][2], 4, "with both coordinates")
    eq(type(back[1][1]), "number", "numbers, not strings")
    eq(F.pack_road(nil), nil, "no road packs to nothing"); eq(F.pack_road({}), nil, "and an empty one too")
    eq(F.unpack_road(nil), nil, "nothing unpacks to nothing"); eq(F.unpack_road(""), nil, "and so does an empty string")

    -- TWO GOODS, ONE PARTNER: one convoy; and a throw at the second good leaves the first on the road
    local function index(stem) for i, g in ipairs(DERPY_MR_FLOWS_GOODS) do if g.stem == stem then return i end end end
    local first, second = "coal", "iron"
    if index(first) > index(second) then first, second = second, first end
    local e4, b4, er4 = pair("4", 0, 400, { coal = 100, iron = 100 }, { "coal", "iron" })
    local count = #F.convoys()
    F.trade(e4.iface)
    eq(#F.convoys(), count + 1, "two goods to one partner ride in one convoy")
    eq(newest().basket.coal, 5, "the coal"); eq(newest().basket.iron, 5, "and the iron")
    -- each good of a basket counts alone, and the entries come in goods order
    eq(F.incoming(b4.name, "cv4B1", "coal"), 5, "a stem asks for its own good: the coal"); eq(F.incoming(b4.name, "cv4B1", "iron"), 5, "the iron")
    eq(F.incoming(b4.name, "cv4B1"), 10, "and every good when none is named")
    eq(#F.ships_to(b4.name, "cv4B1", "coal"), 1, "one entry for a named good")
    local both = F.ships_to(b4.name, "cv4B1")
    eq(#both, 2, "one entry a good"); eq(both[1].stem, first, "in goods order"); eq(both[2].stem, second, "whichever the goods list puts first")
    eq(both[1].convoy, newest().id, "each entry names its convoy"); eq(both[2].due, newest().due, "and carries its arrival turn")
    local e11, b11 = pair("11", 0, 400, {}, {})
    local everything = {}
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do everything[g.stem] = 1 end
    F.convoy_new(e11.iface, b11.iface, everything, nil)
    local walk = F.ships_to(b11.name, "cv11B1")
    eq(#walk, #DERPY_MR_FLOWS_GOODS, "a basket of every good gives an entry for each")
    local ordered = true
    for i, g in ipairs(DERPY_MR_FLOWS_GOODS) do if walk[i].stem ~= g.stem then ordered = false end end
    eq(ordered, true, "walked in goods order, not the order a table happens to hold them")
    local e5, b5, er5 = pair("5", 0, 400, { coal = 100, iron = 100 }, { "coal", "iron" })
    local real = F.route_goods
    F.route_goods = function(r, stem, d) if stem == second then error("boom at the second good") end return real(r, stem, d) end
    ERRORS = {}
    F.guard(F.trade, e5.iface)
    F.route_goods = real
    local c5 = newest()
    eq(c5.f, "cv5E", "a convoy left although the second good threw")
    eq(c5.basket[first], 5, "carrying the good already taken"); eq(c5.basket[second], nil, "and not the one that threw")
    eq(er5.held[first], 95, "the first good is debited"); eq(er5.held[second], 100, "the one that threw never was")
    eq(#ERRORS, 1, "the throw is logged once"); eq(string.find(ERRORS[1], "boom at the second good", 1, true) ~= nil, true, "with its message")
    ERRORS = {}
    -- a debit the engine refuses sends nothing at all
    local e6, b6, er6 = pair("6", 0, 400, { coal = 100 }, { "coal" })
    count = #F.convoys()
    F.route_goods = function() return false end
    F.trade(e6.iface)
    F.route_goods = real
    eq(#F.convoys(), count, "a refused debit starts no convoy"); eq(er6.held.coal, 100, "and takes nothing")

    -- A CAPITAL WITH NO SETTLEMENT: no position to give, but the goods already taken still ride in a convoy
    local e8, b8, er8 = pair("8", 0, 400, { coal = 100 }, { "coal" })
    er8.iface.settlement = function() return NULL end
    count = #F.convoys()
    F.trade(e8.iface)
    eq(#F.convoys(), count + 1, "a capital with no settlement still sends its convoy")
    local c8 = newest()
    eq(c8.f, "cv8E", "the eighth pair's convoy"); eq(c8.basket.coal, 5, "carrying the goods taken"); eq(er8.held.coal, 95, "debited")
    eq(F.unpack_road(c8.road)[1][1], 0, "the road, which cannot be turned without a position, is kept as given")
    DERPY_MR_TERRAIN_ROUTES = nil
    local e9, b9, er9 = pair("9", 0, 400, { coal = 100 }, { "coal" })
    er9.iface.settlement = function() return NULL end
    F.trade(e9.iface)
    local c9 = newest()
    eq(c9.f, "cv9E", "the ninth pair's convoy"); eq(c9.basket.coal, 5, "carries the goods taken with no road either")
    eq(c9.x, nil, "and no position"); eq(c9.road, nil, "no road"); eq(c9.due, c9.at + 1, "one turn")

    -- THE GUARD: a trade that throws does not stop the turn start's duty
    local e7, b7, er7, br7 = pair("7", 0, 400, { coal = 100 }, { "coal" })
    br7.made = { coal = 30 }
    F.made_cache = nil
    local gold0, armed = TREASURY.cv7E or 0, true
    F.route_goods = function(r, stem, d) if armed then armed = false; error("boom in the trade") end return real(r, stem, d) end
    TURN = TURN + 1; turn_start(e7)
    F.route_goods = real
    eq((TREASURY.cv7E or 0) < gold0, true, "the duty still ran after the trade threw")
    local logged = false
    for _, m in ipairs(ERRORS) do if string.find(m, "boom in the trade", 1, true) then logged = true end end
    eq(logged, true, "and the message is in the log")
    ERRORS = {}

    -- A CONTRACT CART ON THE ROAD IS COMMITTED TOO. This replaces the contract block's "free trade cannot duplicate
    -- committed deficit", which could not fail: that buyer's capital held 500 grain against a target of 70, so F.trade
    -- never sent. Here the capital is short by D, a contract cart of n grain already comes, and free trade sends D - n.
    F.state.ship_seq = 97000
    local e12, b12, er12, br12 = pair("12", 0, 400, { grain = 400 }, {})
    F.set_stock_policy(b12.name, "grain", "target", "22")
    local D = F.import_need(F.stock_view(b12.iface, br12.iface), "grain")
    eq(D, 22, "the capital is short by its target")
    local contract = F.route_create(b12.iface, er12.key, br12.key, "grain", 10, 10)
    eq(contract ~= nil, true, "a contract for the capital")
    F.routes_turn(b12.iface)
    local cart = F.ships()[#F.ships()]
    eq(cart ~= nil and cart.recipient, b12.name, "its cart is bound to the buyer"); eq(cart.to, br12.key, "and to the capital")
    local n = cart.n
    eq(F.incoming(b12.name, br12.key, "grain"), n, "the cart counts as incoming")
    eq(F.import_need(F.stock_view(b12.iface, br12.iface), "grain"), D - n, "and comes off the need")
    eq(D - n > 0, true, "the capital is still short, so the case is not empty")
    count = #F.convoys()
    F.trade(e12.iface)
    eq(#F.convoys(), count + 1, "free trade sends a convoy for what is left")
    eq(newest().f, "cv12E", "from the seller of the contract"); eq(newest().buyer, "cv12B", "to the same buyer")
    eq(newest().basket.grain, D - n, "carrying the need less the contract cart, never the whole need")
    TURN = TURN + 1; F.trade(e12.iface)
    eq(#F.convoys(), count + 1, "and with the cart and the convoy both counted nothing more goes")

    -- STEPPING, ARRIVAL, SEIZURE, RETURN (Task 3). The stub road runs (0,0) to (81,0): three turns, 27 hexes in after the
    -- first turn on it and 54 after the second. A case that must not trade calls F.convoys_turn through advance_convoys.
    local function listed(c) for _, x in ipairs(F.convoys()) do if x == c then return true end end return false end
    local function the_road() DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, road end }; F.reach_known = {} end
    do
        the_road()
        local o, ob = pair("19", 0, 81, { coal = 100 }, { "coal" })
        F.trade(o.iface); local other = newest()
        local e, b, er, br = pair("20", 0, 81, { coal = 100 }, { "coal" })
        F.trade(e.iface)
        local c = newest()
        eq(c.f, "cv20E", "the exporter's convoy"); eq(c.due, c.at + 3, "three turns on the road"); eq(c.x, 0, "it starts at the exporter")
        TURN = TURN + 1; turn_start(e)
        eq(c.x, 27, "a turn on: a third of the way"); eq(c.y, 0, "along the road")
        eq(br.held.coal or 0, 0, "nothing has landed"); eq(listed(c), true, "and it is still on the road")
        eq(other.x, 0, "another exporter's convoy is not moved by this one's turn start"); eq(listed(other), true, "nor taken off the list")
        TURN = TURN + 1; turn_start(e)
        eq(c.x, 54, "two turns on: two thirds of the way"); eq(br.held.coal or 0, 0, "still nothing landed")
        TURN = TURN + 1; turn_start(e)
        eq(br.held.coal, 5, "arrives on its due turn"); eq(listed(c), false, "and is gone")
        eq((F.book("cv20B").now.coal or {}).traded_in, 5, "the buyer's ledger books the arrival")
        eq(listed(other) and other.x == 0, true, "the other exporter's convoy goes on waiting for its own turn start")

    end
    do
        -- ONTO TODAY'S ROAD (live check 2026-10-24: a convoy that left on a 171-hex road sat 17 hexes off the 142-hex
        -- one the map drew next turn). A third of the way along the stub road, (27,0), when the pair's road becomes
        -- `bent`, seven points: the turn start puts it a third of the way along that, (20,10), then steps it to two
        -- thirds, (60,10). The army check comes between, so an army at (20,10) and out of reach of (27,0) seizes it.
        local bent = { { 0, 0 }, { 0, 10 }, { 20, 10 }, { 40, 10 }, { 60, 10 }, { 81, 10 }, { 81, 0 } }
        local function roads(ok, path) DERPY_MR_TERRAIN_ROUTES = { reach = function() return ok, nil, path end } end
        local function at(c) return c.x .. "," .. c.y end
        the_road()
        local e, b, er, br = pair("62", 0, 81, { coal = 100 }, { "coal" })
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e); eq(at(c), "27,0", "a third of the way on the road it left on")
        roads(true, bent)
        advance_convoys(e)
        eq(c.road, F.pack_road(bent), "it takes the pair's road of the day"); eq(at(c), "60,10", "and is two thirds along it")
        local listed_road
        for _, x in ipairs(F.convoy_cargo()) do if x.id == c.id then listed_road = x.road end end
        eq(listed_road, c.road, "the maps are given the road it is on")
        advance_convoys(e)
        eq(br.held.coal, 5, "it lands on the day it was given when it left")
        -- from the other end: today's road is turned to leave the exporter, and F.reach's own copy is not
        the_road()
        local e, b = pair("63", 81, 0, { coal = 100 }, { "coal" })
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e); eq(at(c), "54,0", "a third of the way from the exporter at 81")
        roads(true, bent)
        advance_convoys(e)
        eq(at(c), "20,10", "two thirds along today's road, from the exporter's end")
        eq(F.unpack_road(c.road)[1][1], 81, "the road it keeps leaves the exporter"); eq(bent[1][1], 0, "F.reach's path is not turned round in place")
        -- the army check reads the spot on today's road
        the_road()
        local e, b = pair("64", 0, 81, { coal = 100 }, { "coal" })
        local cap = faction("cv64C", { human = true }); local capr = region("cv64C1", 500, 500, 600, {}); own(cap, capr, true)
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e); eq(at(c), "27,0", "on the old road")
        war(e, cap); cap.armies = { field(cap, 20, 10, 6401) }
        eq(7 * 7 + 10 * 10 > F.SHIP.near * F.SHIP.near, true, "the army is out of reach of where the convoy stood")
        roads(true, bent)
        advance_convoys(e)
        eq(listed(c), false, "seized where it stands on today's road"); eq(capr.held.coal, 5, "by the army there")
        -- kept on its own road: today's does not leave where it left, or the pair's trade is cut off
        for _, case in ipairs({ { "65", true, { { 5, 5 }, { 81, 0 } } }, { "66", false, bent } }) do
            local tag = case[1]
            the_road()
            local e, b = pair(tag, 0, 81, { coal = 100 }, { "coal" })
            F.trade(e.iface)
            local c = newest()
            local own_road = c.road
            advance_convoys(e)
            roads(case[2], case[3])
            advance_convoys(e)
            eq(c.road, own_road, "convoy " .. tag .. " keeps the road it left on"); eq(at(c), "54,0", "and goes on along it")
        end
        the_road()   -- the stub road, as the cases below expect it

    end
    do
        -- WHAT DOES NOT FIT IS LOST: a capital of 200 holding 198 takes 2 of the 5
        local e, b, er, br = pair("21", 0, 81, { coal = 100 }, { "coal" })
        F.trade(e.iface)
        local c = newest()
        br.cap, br.held.coal = 200, 198
        advance_convoys(e); advance_convoys(e)
        eq(listed(c), true, "two turns on a three turn road: still travelling")
        advance_convoys(e)
        eq(br.held.coal, 200, "the capital takes what it has room for"); eq(listed(c), false, "and the convoy is gone")
        eq((F.book("cv21B").now.coal or {}).traded_in, 2, "the ledger books the 2 that landed, not the 5")
        eq((F.book("cv21E").now.coal or {}).traded_out, 5, "and the exporter's departure stays all 5")

    end
    do
        -- THE BUYER'S CAPITAL AS IT STANDS ON THE DAY: a new home before the convoy lands takes the goods
        local e, b, er, br = pair("22", 0, 81, { coal = 100 }, { "coal" })
        F.trade(e.iface)
        local c = newest()
        eq(c.to, "cv22B1", "bound for the capital of the day it left")
        local home2 = region("cv22B2", 300, 0, 600, {}); own(b, home2, true)
        -- one step later the cargo is counted at the NEW capital, none at the old one, so the exporter's next trade sees
        -- the buyer's need as met and sends no second convoy against it
        advance_convoys(e)
        eq(c.to, "cv22B2", "the convoy follows the buyer's capital while it travels")
        eq(F.incoming(b.name, "cv22B2", "coal"), 5, "the new capital counts the cargo as incoming"); eq(F.incoming(b.name, "cv22B1", "coal"), 0, "the old one none")
        local sent = #F.convoys()
        F.trade(e.iface)
        eq(#F.convoys(), sent, "no second convoy against a need the road already covers")
        advance_convoys(e)
        eq(c.to, "cv22B2", "a second step keeps it there")
        -- the capital moves AGAIN after the last step, so the goods go to the one the arrival day finds, not the last one seen
        local home3 = region("cv22B3", 350, 0, 600, {}); own(b, home3, true)
        advance_convoys(e)
        eq(listed(c), false, "arrived")
        eq(home3.held.coal, 5, "the capital of the arrival day receives it"); eq(home2.held.coal or 0, 0, "not the one the last step saw")
        eq(br.held.coal or 0, 0, "and the first one nothing")

    end
    do
        -- A CONVOY WITH NO POSITION (a capital with no settlement and no road): it stays put, no army can be near it,
        -- and it lands on its day
        DERPY_MR_TERRAIN_ROUTES = nil
        local e, b, er, br = pair("23", 0, 400, { coal = 100 }, { "coal" })
        er.iface.settlement = function() return NULL end
        local cap = faction("cv23C"); local capr = region("cv23C1", 0, 0, 600, {}); own(cap, capr, true)
        war(e, cap); cap.armies = { field(cap, 0, 0, 641) }
        F.trade(e.iface)
        local c = newest()
        eq(c.x, nil, "it has no position"); eq(c.due, c.at + 1, "and one turn to go")
        F.convoys_turn(e.iface)
        eq(listed(c), true, "on the day it left it is on its way"); eq(c.x, nil, "still with no position")
        advance_convoys(e)
        eq(br.held.coal, 5, "no army can be near it, so it arrives on time"); eq(capr.held.coal or 0, 0, "and the army at its capital took nothing")
        -- ... and with no position a convoy still goes home when the treaty ends: to the exporter's capital
        local e, b, er, br = pair("34", 0, 400, { coal = 100 }, { "coal" })
        er.iface.settlement = function() return NULL end
        F.trade(e.iface)
        local c = newest()
        eq(c.x, nil, "no position again"); war(e, b)
        advance_convoys(e)
        eq(listed(c), false, "gone"); eq(er.held.coal, 100, "back in the capital, the debit undone"); eq(br.held.coal or 0, 0, "and not delivered")

    end
    do
        -- SEIZED: an army at war with the exporter, within reach of the convoy, takes the basket to the captor's nearest
        -- settlement; a garrison and an army out of reach do not. Each look is a new turn: the list is kept per turn.
        the_road()
        local e, b, er, br = pair("24", 0, 81, { coal = 100 }, { "coal" })
        local cap = faction("cv24C", { human = true })
        local far, near = region("cv24C1", 500, 500, 600, {}), region("cv24C2", 40, 0, 600, {})
        own(cap, far, true); own(cap, near)
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e); eq(c.x, 27, "a turn on the road")
        war(e, cap)
        cap.armies = { field(cap, c.x + F.SHIP.near + 1, c.y, 601), field(cap, c.x, c.y, 602, true) }
        advance_convoys(e)
        eq(listed(c), true, "an army out of reach and a garrison seize nothing"); eq(c.x, 54, "so it goes on")
        cap.armies = { field(cap, c.x, c.y, 603) }
        advance_convoys(e)
        eq(listed(c), false, "an army at war with its exporter, near it, seizes it")
        eq(near.held.coal, 5, "the captor's nearest settlement gets the basket"); eq(far.held.coal or 0, 0, "not its other one")
        eq(br.held.coal or 0, 0, "the buyer gets nothing")
        eq((F.book("cv24C").now.coal or {}).raided_in, 5, "the captor's ledger books it as raided in")
        eq((F.book("cv24E").now.coal or {}).raided_out, nil, "the exporter's loss was booked at dispatch: no second line")

    end
    do
        -- ... and on its due day the army still gets there first: seizure is asked before arrival
        DERPY_MR_TERRAIN_ROUTES = nil
        local e, b, er, br = pair("25", 0, 400, { coal = 100 }, { "coal" })
        local cap = faction("cv25C", { human = true }); local capr = region("cv25C1", 700, 0, 600, {}); own(cap, capr, true)
        war(e, cap)
        F.trade(e.iface)
        local c = newest()
        cap.armies = { field(cap, c.x, c.y, 604) }
        advance_convoys(e)
        eq(listed(c), false, "gone"); eq(capr.held.coal, 5, "seized on the day it was due"); eq(br.held.coal or 0, 0, "and not delivered")

    end
    do
        -- THE TREATY GONE, THE BUYER DEAD OR LANDLESS: the basket goes home to the exporter's settlement nearest the convoy
        -- (here the second one, 40 along, not the capital at 0), a convoy at x = 27 after its first turn
        the_road()
        local e, b, er, br = pair("26", 0, 81, { coal = 100 }, { "coal" })
        local er2 = region("cv26E2", 40, 0, 600, {}); own(e, er2)
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e); eq(c.x, 27, "a turn on the road")
        war(e, b)
        advance_convoys(e)
        eq(listed(c), false, "war between the two ends the convoy")
        eq(er2.held.coal, 5, "the basket is back in the exporter's settlement nearest it"); eq(er.held.coal, 95, "the capital got nothing back")
        eq(br.held.coal or 0, 0, "and the buyer none")
        eq((F.book("cv26E").now.coal or {}).moved_in, 5, "the exporter's ledger books it as moved in")

    end
    do
        local e, b, er, br = pair("27", 0, 81, { coal = 100 }, { "coal" })
        local er2 = region("cv27E2", 40, 0, 600, {}); own(e, er2)
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e)
        b.dead = true
        advance_convoys(e)
        eq(listed(c), false, "a dead buyer ends it"); eq(er2.held.coal, 5, "returned, not lost"); eq(br.held.coal or 0, 0, "and not delivered")

    end
    do
        local e, b, er, br = pair("28", 0, 81, { coal = 100 }, { "coal" })
        local er2 = region("cv28E2", 40, 0, 600, {}); own(e, er2)
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e)
        lose(b, br); b.home = nil
        eq(F.capital(b.iface), nil, "the buyer has no settlement left, as a horde")
        advance_convoys(e)
        eq(listed(c), false, "a buyer with no settlement ends it"); eq(er2.held.coal, 5, "returned, not lost")

    end
    do
        -- A THROW WHILE THE GOODS MOVE leaves the convoy off the list: it is taken off first, so it cannot deliver twice
        local e, b, er, br = pair("35", 0, 81, { coal = 100, iron = 100 }, { "coal", "iron" })
        F.trade(e.iface)
        local c = newest()
        eq(c.basket.coal, 5, "two goods in one convoy"); eq(c.basket.iron, 5, "the iron too")
        advance_convoys(e); advance_convoys(e)
        local real_move, moves = F.move, 0
        F.move = function(...) moves = moves + 1; if moves == 2 then error("boom while moving") end return real_move(...) end
        ERRORS = {}
        TURN = TURN + 1; F.guard(F.convoys_turn, e.iface)
        F.move = real_move
        eq(listed(c), false, "the convoy is gone although a move threw")
        eq((br.held.coal or 0) + (br.held.iron or 0), 5, "the good moved before the throw landed once")
        eq(#ERRORS, 1, "the throw is logged once"); ERRORS = {}
        advance_convoys(e)
        eq((br.held.coal or 0) + (br.held.iron or 0), 5, "and a later turn delivers nothing again")

        -- ... the same for a SEIZED convoy and a RETURNED one: off the list first, the one good that moved landed once
        local function turn_with_a_throw(exporter)   -- its next turn, the second F.move of it raising
            local real_move, moves = F.move, 0
            F.move = function(...) moves = moves + 1; if moves == 2 then error("boom while moving") end return real_move(...) end
            ERRORS = {}
            TURN = TURN + 1; F.guard(F.convoys_turn, exporter.iface)
            F.move = real_move
        end
        DERPY_MR_TERRAIN_ROUTES = nil
        local e, b, er, br = pair("37", 0, 400, { coal = 100, iron = 100 }, { "coal", "iron" })
        local cap = faction("cv37C", { human = true }); local capr = region("cv37C1", 700, 0, 600, {}); own(cap, capr, true)
        F.trade(e.iface)
        local c = newest()
        eq(c.basket.coal, 5, "two goods in one convoy"); eq(c.basket.iron, 5, "the iron too")
        war(e, cap); cap.armies = { field(cap, c.x, c.y, 671) }
        turn_with_a_throw(e)
        eq(listed(c), false, "a seized convoy is gone although a move threw")
        eq((capr.held.coal or 0) + (capr.held.iron or 0), 5, "the good moved before the throw landed once, at the captor")
        eq(#ERRORS, 1, "the throw is logged once"); ERRORS = {}
        advance_convoys(e)
        eq((capr.held.coal or 0) + (capr.held.iron or 0), 5, "and a later turn seizes nothing again")
        local e, b, er, br = pair("38", 0, 400, { coal = 100, iron = 100 }, { "coal", "iron" })
        F.trade(e.iface)
        local c = newest()
        eq(c.basket.coal, 5, "two goods in one convoy"); eq(c.basket.iron, 5, "the iron too")
        war(e, b)
        turn_with_a_throw(e)
        eq(listed(c), false, "a returned convoy is gone although a move threw")
        eq((er.held.coal or 0) + (er.held.iron or 0), 195, "of the 190 left at the debit, the good moved before the throw is back once")
        eq(#ERRORS, 1, "the throw is logged once"); ERRORS = {}
        advance_convoys(e)
        eq((er.held.coal or 0) + (er.held.iron or 0), 195, "and a later turn returns nothing again")
        eq(br.held.coal or 0, 0, "nothing was delivered")

        -- A RECORD ALREADY GONE MOVES NOTHING: a second arrival of the same convoy lands the basket once
        local e, b, er, br = pair("39", 0, 400, {}, {})
        local twice = F.convoy_new(e.iface, b.iface, { coal = 4 }, nil)
        F.convoy_arrive(twice); F.convoy_arrive(twice)
        eq(br.held.coal, 4, "the basket landed once")
    end
    do
        -- IN ID ORDER: two convoys land the same turn on a capital with room for 5; the older takes its 4 and the younger
        -- gets the 1 left (walked the other way round it would be 3 and 2)
        DERPY_MR_TERRAIN_ROUTES = nil
        local e, b, er, br = pair("36", 0, 400, {}, {})
        local older = F.convoy_new(e.iface, b.iface, { coal = 4 }, nil)
        local younger = F.convoy_new(e.iface, b.iface, { coal = 3 }, nil)
        br.cap = 5
        advance_convoys(e)
        eq(listed(older) or listed(younger), false, "both landed")
        eq(LOG[#LOG - 1][3], 4, "the older convoy landed first, all its 4"); eq(LOG[#LOG][3], 1, "the younger got the 1 that was left")
        eq(br.held.coal, 5, "the capital is full")
    end
    do
        -- AN EXPORTER WITH NO SETTLEMENT LOSES THE BASKET (on the road: a one-turn convoy would already have landed)
        the_road()
        local e, b, er, br = pair("29", 0, 81, { coal = 100 }, { "coal" })
        F.trade(e.iface)
        local c = newest()
        advance_convoys(e)
        eq(listed(c), true, "a turn on the road: still travelling")
        lose(e, er); e.home = nil
        war(e, b)
        advance_convoys(e)
        eq(listed(c), false, "gone"); eq(er.held.coal, 95, "an exporter with no settlement has nowhere to put it back")
        eq(br.held.coal or 0, 0, "and the buyer got none of it")

    end
    do
        -- A DEAD EXPORTER'S CONVOYS ARE SWEPT at a player's turn start: nowhere to return to, so the basket is destroyed
        local e, b, er, br = pair("30", 0, 81, { coal = 100 }, { "coal" })
        local alive, ab = pair("31", 0, 81, { coal = 100 }, { "coal" })
        F.trade(e.iface); local c = newest()
        F.trade(alive.iface); local survivor = newest()
        local ghost = { id = F.CONVOY_PREFIX .. "9999", f = "cv_no_such_faction", buyer = b.name, from = "x", to = br.key,
                        basket = { coal = 1 }, at = TURN, due = TURN + 1 }
        F.state.convoys[#F.state.convoys + 1] = ghost
        e.dead = true; ERRORS = {}
        turn_start(b)
        eq(listed(c), false, "the dead exporter's convoy is swept"); eq(listed(ghost), false, "and one whose exporter does not exist")
        eq(listed(survivor), true, "a living exporter's convoy is not")
        eq(er.held.coal, 95, "the basket is not returned"); eq(br.held.coal or 0, 0, "nor delivered")
        eq(#ERRORS, 0, "no error in the sweep: " .. table.concat(ERRORS, "; "))

    end
    do
        -- THE ONE LOOK: three convoys, one question to the engine for the enemy armies; a new turn asks again
        DERPY_MR_TERRAIN_ROUTES = nil
        local e = faction("cv32E", { human = true }); local er = region("cv32E1", 0, 0, 600, {}); own(e, er, true)
        local buyers = {}
        for i = 1, 3 do
            local bf = faction("cv32B" .. i, { human = true })
            own(bf, region("cv32B" .. i .. "1", 400 + i, 0, 600, {}), true)
            bf.partners = { e }; buyers[i] = bf; made[#made + 1] = bf
        end
        e.partners = buyers; made[#made + 1] = e
        for _, bf in ipairs(buyers) do F.convoy_new(e.iface, bf.iface, { coal = 1 }, nil) end
        local looks, real_looks = 0, e.iface.factions_at_war_with
        e.iface.factions_at_war_with = function(...) looks = looks + 1; return real_looks(...) end
        advance_convoys(e)
        eq(looks, 1, "three convoys, one look for enemy armies")
        local foe = faction("cv32X"); own(foe, region("cv32X1", 900, 0, 600, {}), true)
        war(e, foe)
        local live = field(foe, 0, 0, 650)
        foe.armies = { live, field(foe, 0, 0, 651, true) }
        TURN = TURN + 1; looks = 0
        local armies = F.enemy_armies(e.iface)
        eq(looks, 1, "a new turn looks again")
        eq(#armies, 1, "a garrison is not an army in the field"); eq(armies[1].fkey, "cv32X", "the faction at war"); eq(armies[1].cqi, 1650, "its force")
        eq(armies[1].x, 0, "where it stands"); eq(armies[1].y, 0, "on both axes")
        eq(F.captor(e.iface, { x = 0, y = 0 }) ~= nil, true, "it is near a convoy at the same spot"); eq(looks, 1, "and the same turn asks nobody again")
        live.is_null_interface = function() return true end
        eq(F.captor(e.iface, { x = 0, y = 0 }), nil, "a force destroyed since the list was made is skipped")
        e.iface.factions_at_war_with = real_looks

    end
    do
        -- SHIPMENTS SEIZE AS THEY DID: F.captor over the cached list against the walk it replaced (copied here as it stood),
        -- for a computer owner and a human one, with and without an escort, from a spot beside each army and beside none
        local function old_captor(owner, s)
            local wars = owner:factions_at_war_with()
            local skip_human = F.escorts_on() and not owner:is_human() and (s.escort or "") ~= ""
            local r2 = F.SHIP.near * F.SHIP.near
            for i = 0, wars:num_items() - 1 do
                local o = wars:item_at(i)
                if not (skip_human and o:is_human()) then
                    local mfl = o:military_force_list()
                    for j = 0, mfl:num_items() - 1 do
                        local mf = mfl:item_at(j)
                        if not mf:is_armed_citizenry() and mf:has_general() then
                            local ch = mf:general_character()
                            local dx, dy = ch:logical_position_x() - s.x, ch:logical_position_y() - s.y
                            if dx * dx + dy * dy <= r2 then return o, mf end
                        end
                    end
                end
            end
            return nil
        end
        local nr = F.SHIP.near
        local ow_ai, ow_hu = faction("cv33O"), faction("cv33H", { human = true })
        local en_hu, en_ai = faction("cv33EH", { human = true }), faction("cv33EA")
        for _, ow in ipairs({ ow_ai, ow_hu }) do war(ow, en_hu); war(ow, en_ai) end
        en_hu.armies = { field(en_hu, 0, 0, 660), field(en_hu, 10 * nr, 0, 661, true) }
        en_ai.armies = { field(en_ai, 4 * nr, 0, 662) }
        local rates, seen, hits = F.state.rates, 0, 0
        rates.escort = true
        for _, ow in ipairs({ ow_ai, ow_hu }) do
            TURN = TURN + 1
            for _, x in ipairs({ 0, nr, nr + 1, 4 * nr, 5 * nr, 5 * nr + 1, 10 * nr, 20 * nr }) do
                for _, esc in ipairs({ "", "a,b" }) do
                    local s = { x = x, y = 0, escort = esc }
                    local o1, m1 = old_captor(ow.iface, s)
                    local o2, m2 = F.captor(ow.iface, s)
                    eq(o2 == o1 and m2 == m1, true, ow.name .. " at " .. x .. " escort '" .. esc .. "': the same captor as the walk")
                    seen = seen + 1; if o1 then hits = hits + 1 end
                end
            end
        end
        eq(seen, 32, "every spot was asked for both owners"); eq(hits > 8 and hits < seen - 8, true, "some seize and some do not")
        eq(old_captor(ow_ai.iface, { x = 0, y = 0, escort = "" }) ~= nil and old_captor(ow_ai.iface, { x = 0, y = 0, escort = "a" }) == nil, true,
           "an escorted computer cart is passed over by a human army: the case is not empty")
        rates.escort = false
    end
    DERPY_MR_TERRAIN_ROUTES = nil

    -- A CONVOY THE REAL TRADE WRITES SURVIVES A SAVE AND LOAD: a field the load check rejects would drop it and its goods
    do
        local road = road_82()
        DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, road end }
        local e, b, er = pair("40", 81, 0, { coal = 100 }, { "coal" })
        F.reach_known = {}; F.trade(e.iface)
        DERPY_MR_TERRAIN_ROUTES = nil
        local function keys()
            local out = {}
            for _, c in ipairs(F.convoys()) do
                out[#out + 1] = table.concat({ c.id, c.f, c.buyer, c.from, c.to, c.basket.coal or 0, c.at, c.due,
                                                tostring(c.road), tostring(c.x), tostring(c.y) }, "|")
            end
            return table.concat(out, ",")
        end
        local before = keys()
        eq(string.find(before, "cv40E|", 1, true) ~= nil and string.find(before, "|81|0", 1, true) ~= nil, true,
           "the trade wrote a convoy with a road and a position")
        SAVED = {}; cm.saving_game_callbacks[1]({}); F.state = {}; cm.loading_game_callbacks[1]({})
        eq(keys(), before, "every convoy the trade wrote is kept by the load, field for field")
    end

    -- A BRIDGED ROAD THROUGH THE REAL TRADE: four points, 81 hexes (two bridges of 40 and a step), three turns; by points it is one
    do
        local bridged = { { 0, 0 }, { 40, 0 }, { 80, 0 }, { 81, 0 } }
        DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, bridged end }
        local e, b = pair("41", 0, 81, { coal = 100 }, { "coal" })
        F.reach_known = {}; F.trade(e.iface)
        DERPY_MR_TERRAIN_ROUTES = nil
        local c = newest()
        eq(c.f, "cv41E", "the bridged pair's convoy"); eq(#F.unpack_road(c.road), 4, "carrying the four points")
        eq(c.due, c.at + 3, "81 hexes at 40 a turn: three turns")
    end

    -- WHAT THE VAULT AND THE MAPS READ (Task 6, F.convoy_cargo): an entry for every convoy with a live exporter, with or
    -- without a position, naming its largest good
    do
        DERPY_MR_TERRAIN_ROUTES = nil
        F.state.convoys = nil
        eq(#F.convoy_cargo(), 0, "no convoys, nothing to draw"); eq(F.state.convoys, nil, "and asking made no list")
        F.state.convoys = {}
        local function entry_of(c) for _, x in ipairs(F.convoy_cargo()) do if x.id == c.id then return x end end end
        local e, b = pair("50", 0, 81, {}, {})
        local c = F.convoy_new(e.iface, b.iface, { coal = 40, iron = 12 }, road_82())
        local m = entry_of(c)
        eq(m ~= nil, true, "a convoy on the road is listed")
        eq(m.id, c.id, "named by its id"); eq(m.f, "cv50E", "its exporter"); eq(m.buyer, "cv50B", "its buyer")
        eq(m.from, "cv50E1", "from the exporter's capital"); eq(m.to, "cv50B1", "to the buyer's")
        eq(m.at, c.at, "the turn it left"); eq(m.due, c.due, "and the turn it is due")
        eq(m.x, 0, "where it is"); eq(m.y, 0, "on both axes"); eq(m.convoy, true, "marked as a convoy, as a shipment is not")
        eq(m.stem, "coal", "named by its largest good"); eq(m.n, 40, "and that good's amount")
        eq(m.basket.coal, 40, "the whole basket rides along"); eq(m.basket.iron, 12, "every good in it")
        -- THE LARGEST GOOD, equal amounts to the lower stem: three baskets of stems that tie
        c.basket = { coal = 12, iron = 40 }
        eq(entry_of(c).stem, "iron", "the larger of two, whatever their names"); eq(entry_of(c).n, 40, "with its amount")
        -- (the stems are chosen so that Lua's own walk of a basket meets a higher stem before the lowest in some of them)
        for i, tie in ipairs({ { "coal", { "iron", "coal" } }, { "grain", { "grain", "iron" } }, { "brimstone", { "coal", "brimstone" } },
                               { "brimstone", { "iron", "coal", "brimstone", "grain" } } }) do
            c.basket = {}
            for _, stem in ipairs(tie[2]) do c.basket[stem] = 7 end
            eq(entry_of(c).stem, tie[1], "equal amounts go to the lower stem, basket " .. i)
            eq(entry_of(c).n, 7, "with the amount they share")
        end
        c.basket = { coal = 40, iron = 12 }
        -- NO POSITION IS STILL LISTED (a capital with no settlement and no road): the Vault counts it, and only what
        -- places a marker leaves it out, so F.convoy_cargo must keep it, whole
        local e2, b2, er2 = pair("52", 0, 400, {}, {})
        er2.iface.settlement = function() return NULL end
        local nopos = F.convoy_new(e2.iface, b2.iface, { coal = 1, iron = 3 }, nil)
        eq(nopos.x, nil, "the fixture has no position")
        local lost = entry_of(nopos)
        eq(lost ~= nil, true, "a convoy with no position is listed all the same"); eq(lost.x, nil, "with no x"); eq(lost.y, nil, "and no y")
        eq(lost.f, "cv52E", "its exporter"); eq(lost.buyer, "cv52B", "its buyer"); eq(lost.due, nopos.due, "its due turn")
        eq(lost.stem, "iron", "and its largest good"); eq(lost.basket.coal, 1, "with its whole basket")
        eq(listed(nopos), true, "and it is still on the road")
        -- A DEAD EXPORTER'S CONVOY IS NOT ON THE ROAD: its record waits for a player's turn start to sweep it
        local e3, b3 = pair("53", 0, 81, {}, {})
        local gone = F.convoy_new(e3.iface, b3.iface, { coal = 3 }, road_82())
        eq(entry_of(gone) ~= nil, true, "a live exporter's convoy is listed")
        e3.dead = true
        eq(entry_of(gone), nil, "a dead exporter's convoy is not listed"); eq(listed(gone), true, "though its record is still in the list")
        e3.dead = false
        eq(entry_of(gone) ~= nil, true, "the check reads the exporter as it is now")
        -- IN THE ORDER IT LEFT, and a read leaves the list as it found it
        local all = F.convoy_cargo()
        local pos = {}
        for i, x in ipairs(all) do pos[x.id] = i end
        eq(pos[c.id] < pos[nopos.id] and pos[nopos.id] < pos[gone.id], true, "in the order the convoys left")
        eq(#all, 3, "all three, each with a live exporter")
    end

    -- THE TURN A HUMAN BUYER IS TOLD (F.convoy_due): a convoy lands at its exporter's turn start, and a round starts with the
    -- human, so goods a computer sends land after the human's turn on the due turn and are first usable on the one after.
    -- Every round from the one after departure: the buyer's turn first, or the exporter's start first, as the round runs.
    do
        DERPY_MR_TERRAIN_ROUTES = nil
        local function first_use(exporter, br, c, buyer_first)
            local first
            for round = c.at + 1, c.at + 4 do
                TURN = round
                if buyer_first and not first and (br.held.coal or 0) > 0 then first = round end
                F.convoys_turn(exporter.iface)
                if not buyer_first and not first and (br.held.coal or 0) > 0 then first = round end
            end
            return first
        end
        local function told(c)
            local from_cargo
            for _, x in ipairs(F.convoy_cargo()) do if x.id == c.id then from_cargo = x.due end end
            return F.ships_to(c.buyer, c.to, "coal")[1].due, from_cargo
        end
        -- a computer exporter and a human buyer: told the turn the buyer first holds the goods, the one after the landing
        local e, b, er, br = pair("60", 0, 400, { coal = 100 }, {})
        e.human = false
        TURN = TURN + 1
        local c = F.convoy_new(e.iface, b.iface, { coal = 5 }, nil)
        eq(c.due, c.at + 1, "a one-turn road")
        local shown, listed_due = told(c)
        local first = first_use(e, br, c, true)
        eq(first, c.due + 1, "the human's turn on the due turn comes before the landing, so the goods are there a turn later")
        eq(shown, first, "the Trade tab is told that turn"); eq(listed_due, first, "and so is the Cargo on the road listing")
        eq(c.due, c.at + 1, "the record's own due turn is the landing, unchanged")
        -- a human exporter and a computer buyer: the goods land at the human's start and the computer plays after it
        local e2, b2, er2, br2 = pair("61", 0, 400, { coal = 100 }, {})
        b2.human = false
        TURN = TURN + 1
        local c2 = F.convoy_new(e2.iface, b2.iface, { coal = 5 }, nil)
        local shown2, listed_due2 = told(c2)
        local first2 = first_use(e2, br2, c2, false)
        eq(first2, c2.due, "the buyer holds the goods on the due turn")
        eq(shown2, first2, "told that turn"); eq(listed_due2, first2, "in the listing too")
    end

    for _, f in ipairs(made) do f.partners = {} end
    eq(#ERRORS, 0, "no script errors in the convoy cases: " .. table.concat(ERRORS, "; "))
    F.state, TURN, F.reach_known = saved, turn, known
    DERPY_MR_TERRAIN_ROUTES = nil
end)()

-- ---- escort battles: the escort rolled at departure (spec 2026-10-09) ---------------------
-- random_army_manager as CA's: a force is a flat list, one entry per weight point, kept by key
RAM = { forces = {}, made = {}, calls = 0 }
random_army_manager = {
    get_force_by_key = function(_, k) return RAM.forces[k] or false end,
    new_force = function(_, k) if RAM.forces[k] then return false end; RAM.forces[k] = { units = {} }; return true end,
    add_unit = function(_, k, u, w)
        if not RAM.forces[k] then RAM.forces[k] = { units = {} } end
        for _ = 1, w do table.insert(RAM.forces[k].units, u) end
    end,
    generate_force = function(_, k, n, as_table)
        local f = RAM.forces[k]
        if not f then error("attempt to index local 'force_data' (a boolean value)") end   -- as CA's does
        if #f.units == 0 then return false end
        local t = {}
        for i = 1, n do t[i] = f.units[1 + (i - 1) % #f.units] end
        RAM.made[#RAM.made + 1] = { key = k, n = n }
        return as_table and t or table.concat(t, ",")
    end,
}
-- CA's generator: it ADDS to a force it already holds, on every call, and names a stale unit
WH_Random_Army_Generator = {
    generate_random_army = function(_, key, tpl, n, power, thresholds, as_table)
        random_army_manager:new_force(key)
        random_army_manager:add_unit(key, "wh_main_emp_veh_steam_tank", 1)
        random_army_manager:add_unit(key, tpl .. "_unit", 2)
        RAM.calls = RAM.calls + 1
        return random_army_manager:generate_force(key, n, as_table)
    end,
}
F.state.rates.escort = true
;(function()
    local function units_in(s) return select(2, string.gsub(s, ",", ",")) + 1 end
    local eP = faction("eP", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local e1 = region("e1", 30000, 0, 400, { coal = 200 }); own(eP, e1, true)
    local e2 = region("e2", 30100, 0, 400, {}); own(eP, e2)
    TURN = 8000; F.request("eP", "send", "coal", "e2"); local es = last_ship()
    eq(es.escort ~= nil and es.escort ~= "", true, "a cart leaves with its escort")
    eq(units_in(es.escort), F.escort_size(es), "as many units as the cargo's value buys")
    eq(F.escort_size({ stem = "coal", n = 1 }), DERPY_MR_FLOWS_ESCORT.min, "never fewer than the least")
    eq(F.escort_size({ stem = "coal", n = 100000 }), DERPY_MR_FLOWS_ESCORT.max, "never more than the most")
    eq(F.escort_size({ stem = "no_such_good", n = 80 }), DERPY_MR_FLOWS_ESCORT.min + 2, "a good with no rate counts 1")
    eq(F.escort_size({ stem = "coal", n = 80 }), DERPY_MR_FLOWS_ESCORT.min + 6, "war materials count 3 a unit")
    eq(F.escort_power(1), 1, "turn 1: the weakest"); eq(F.escort_power(200), 10, "and never past 10")
    eq(F.escort_power(25), 3, "turn 25: CA's turn / 10, rounded")
    eq(RAM.made[#RAM.made].key, "derpy_mr_esc_wh_main_sc_dwf_dwarfs_10", "the key carries the template and the power")
    eq(string.find(es.escort, "steam_tank"), nil, "a stale unit in CA's template is never rolled")
    local calls = RAM.calls
    e1.held.coal = 200; F.request("eP", "send", "coal", "e2")
    eq(RAM.calls, calls, "a second roll of one key does not run CA's generator again")
    eq(#RAM.forces["derpy_mr_esc_wh_main_sc_dwf_dwarfs_10"].units, 2, "so the force does not grow with every cart")
    -- the escort is rolled once: a turn start does not roll it again
    local esc0 = es.escort; TURN = 8001; turn_start(eP); eq(es.escort, esc0, "the same escort the next turn")
    -- no template: no escort
    local nP = faction("nP", { human = true, sc = "wh_main_sc_none_here" })
    local n1 = region("n1", 31000, 0, 400, { coal = 50 }); own(nP, n1, true)
    local n2 = region("n2", 31010, 0, 400, {}); own(nP, n2)
    F.request("nP", "send", "coal", "n2"); eq(last_ship().escort, "", "a race with no template has no escort")
    -- Cathay: our own template, CA's tiers
    local cP = faction("cP", { human = true, sc = "wh3_main_sc_cth_cathay" })
    local c1 = region("c1", 32000, 0, 400, { coal = 200 }); own(cP, c1, true)
    local c2 = region("c2", 32010, 0, 400, {}); own(cP, c2)
    TURN = 30; F.request("cP", "send", "coal", "c2"); local cs = last_ship()
    eq(string.find(cs.escort, "wh3_main_cth_") ~= nil, true, "Cathay rolls its own roster")
    eq(string.find(cs.escort, "dragon_guard"), nil, "at power 3 no top-tier unit")
    local mids = #RAM.forces["derpy_mr_escort_cth_3"].units
    eq(mids, 40 + 3 * 15, "low at 1 and mid at the power, CA's weights")
    TURN = 80; c1.held.coal = 200; F.state.ships = {}; F.request("cP", "send", "coal", "c2")
    eq(string.find(last_ship().escort, "peasant"), nil, "at power 8 no low-tier unit")
    -- a save from before escorts: rolled at the next turn start
    F.state.ships = { es }; es.escort = nil; TURN = 8002; turn_start(eP); eq(es.escort ~= nil, true, "an old shipment gets its escort")
    -- CA's generator absent (a campaign root that does not load it): no escort
    local wg = WH_Random_Army_Generator; WH_Random_Army_Generator = nil
    local xP = faction("xP", { human = true, sc = "wh_main_sc_emp_empire" })
    local x1 = region("x1", 33500, 0, 400, { coal = 200 }); own(xP, x1, true)
    local x2 = region("x2", 33510, 0, 400, {}); own(xP, x2)
    F.state.ships = {}; TURN = 8100; F.request("xP", "send", "coal", "x2")
    eq(last_ship().escort, "", "no generator, no escort")
    lose(xP, x1); lose(xP, x2)
    WH_Random_Army_Generator = wg
    F.state.ships = {}
    eq(#ERRORS, 0, "no script errors in the escort roll: " .. table.concat(ERRORS, "; "))
end)()

-- ---- escort battles: raid, defence, the outcome (spec 2026-10-09) -----------------------
FBM_LOG, KILLED, CA_LOST, CA_ARMED = {}, {}, 0, false
-- CA's Forced_Battle_Manager as it behaves: trigger_battle spawns the escort (stage 2 gives it a cqi)
-- and ARMS a one-shot BattleCompleted handler that is added AFTER ours, so in the same session ours
-- runs first; after a battle fought in 3D the campaign reloads and CA's (load_listeners) runs first.
-- The handler unlocks the retreat, then get_battle(active_battle): a key no longer in the list is a
-- script error and NO clear-up - the escort stays and the slot stays taken.
Forced_Battle_Manager = { active_battle = "", forced_battles_list = {} }
function Forced_Battle_Manager:setup_new_battle(key)
    if self.forced_battles_list[key] then return false end    -- CA's: a key it holds is refused
    local fb = { key = key, forces = {}, attacker = {}, target = {} }
    function fb:add_new_force(k, units, fk, destroy) self.forces[k] = { units = units, f = fk, destroy = destroy } end
    function fb:trigger_battle(att, target, x, y, ambush)
        self.target = { cqi = 5000 + #FBM_LOG }
        FBM_LOG[#FBM_LOG + 1] = { key = self.key, att = att, target = target, x = x, y = y, ambush = ambush,
                                  force = self.forces[target], escort = self.target.cqi }
        Forced_Battle_Manager.active_battle = self.key
        CA_ARMED = true
    end
    self.forced_battles_list[key] = fb
    return fb
end
local function ca_handler()
    CA_ARMED = false
    RETREAT_LOCKED = false
    local b = Forced_Battle_Manager.forced_battles_list[Forced_Battle_Manager.active_battle]
    if not b then CA_LOST = CA_LOST + 1 return end
    KILLED[b.key] = true                                     -- destroy_after_battle
    Forced_Battle_Manager.active_battle = ""
    b.attacker, b.target = {}, {}
end
invasion_manager = { kill_invasion_by_key = function(_, k) KILLED[k] = true end, remove_invasion = function() end }
RETREAT_LOCKED, FEED_OFF, BATTLE = false, {}, { fought = true, attacker_won = true, involved = {} }
cm.get_campaign_ui_manager = function() return { override = function(_, k)
    return { lock = function() if k == "retreat" then RETREAT_LOCKED = true end end,
             unlock = function() if k == "retreat" then RETREAT_LOCKED = false end end } end } end
cm.disable_event_feed_events = function(_, on, cat) FEED_OFF[#FEED_OFF + 1] = { on, cat } end
cm.pending_battle_cache_attacker_victory = function() return BATTLE.attacker_won end
cm.pending_battle_cache_mf_is_involved = function(_, cqi) return BATTLE.involved[cqi] == true end
FORCES, STANCES, GARRISON = {}, {}, {}   -- cqi -> a live force; force cqi -> its stance; -> in a settlement
local real_model = cm.model
cm.model = function()
    local m = real_model()
    m.pending_battle = function() return { has_been_fought = function() return BATTLE.fought end } end
    m.military_force_for_command_queue_index = function(_, cqi) return FORCES[cqi] or NULL end
    return m
end
;(function()
    -- opts.reload: CA's handler first (a battle fought in 3D); opts.not_ours: the escort was not in it
    local function battle_done(attacker_won, fought, involved, opts)
        opts = opts or {}
        local last = FBM_LOG[#FBM_LOG]
        if last and not opts.not_ours then involved[last.escort] = true end
        fire("PendingBattle", {})
        BATTLE = { attacker_won = attacker_won, fought = fought, involved = involved }
        if opts.reload and CA_ARMED then ca_handler() end
        fire("BattleCompleted", {})
        if CA_ARMED then ca_handler() end
    end
    local function raider(f, cqi)
        FORCES[cqi] = { is_null_interface = function() return false end, command_queue_index = function() return cqi end,
                        has_garrison_residence = function() return GARRISON[cqi] == true end,
                        active_stance = function() return STANCES[cqi] or "MILITARY_FORCE_ACTIVE_STANCE_TYPE_DEFAULT" end }
        return { is_null_interface = function() return false end, faction = function() return f.iface end,
                 has_military_force = function() return true end,
                 military_force = function() return FORCES[cqi] end }
    end
    local RD = DERPY_MR_FLOWS_EVENTS.raid.dilemma
    -- RAID: a player's army walks onto a computer's cart; the dilemma first
    local rP = faction("rP", { human = true, sc = "wh_main_sc_emp_empire" })
    local rp1 = region("rp1", 33000, 0, 4000, {}); own(rP, rp1, true)
    local oA = faction("oA", { sc = "wh_main_sc_dwf_dwarfs" })
    local oa1 = region("oa1", 33100, 0, 4000, { coal = 2000 }); own(oA, oa1, true)
    local oa2 = region("oa2", 33200, 0, 4000, {}); own(oA, oa2)
    war(rP, oA); DILEMMAS = {}; F.state.ships = {}
    TURN = 9000; local os1 = F.ship(oA.iface, oa1.iface, oa2.iface, "coal", 60)
    eq(os1.escort ~= "", true, "the computer's cart has its escort")
    enter(os1.id, raider(rP, 777))
    eq(ships_of("oA"), 1, "a player's army does not take an escorted cart by walking in")
    eq(DILEMMAS[#DILEMMAS].key, RD, "it is asked first"); eq(DILEMMAS[#DILEMMAS].fcqi, rP.cqi, "the player is asked")
    eq(DILEMMAS[#DILEMMAS].faction, oA.cqi, "naming the cart's owner")
    enter(os1.id, raider(rP, 777)); eq(#DILEMMAS, 1, "one raid offer at a time")
    answer(rP, RD, "SECOND")
    eq(#FBM_LOG, 0, "Let it pass: no battle"); eq(ships_of("oA"), 1, "and the cart goes on")
    TURN = 9001; enter(os1.id, raider(rP, 777)); eq(#DILEMMAS, 2, "asked again on a later turn")
    answer(rP, RD, "FIRST")
    local b = FBM_LOG[#FBM_LOG]
    eq(b.att, 777, "the player's army attacks"); eq(b.target, b.key, "the escort it spawns")
    eq(b.force.f, "oA", "the escort is the owner's"); eq(b.force.units, os1.escort, "the escort rolled at departure")
    eq(b.force.destroy, true, "and it goes after the battle"); eq(b.x, os1.x, "at the cart"); eq(b.y, os1.y, "at the cart")
    eq(b.ambush, false, "a pitched battle, not an ambush")
    eq(RETREAT_LOCKED, false, "a raider may retreat")
    battle_done(true, true, { [777] = true })
    eq(ships_of("oA"), 0, "won: the cargo is taken"); eq(rp1.held.coal, os1.n, "into the raider's settlement")
    eq(Forced_Battle_Manager.active_battle, "", "CA's own handler finds its battle and frees its slot")
    eq(KILLED[b.key], true, "and removes the escort"); eq(CA_LOST, 0, "CA's handler never loses our battle")
    eq(F.state.fight, nil, "the record is cleared")
    -- raid lost, and a raid retreated from
    TURN = 9002; local os2 = F.ship(oA.iface, oa1.iface, oa2.iface, "coal", 60)
    enter(os2.id, raider(rP, 777)); answer(rP, RD, "FIRST")
    battle_done(false, true, { [777] = true }); eq(ships_of("oA"), 1, "lost: the cart stays")
    TURN = 9003; enter(os2.id, raider(rP, 777)); answer(rP, RD, "FIRST")
    battle_done(true, false, { [777] = true }); eq(ships_of("oA"), 1, "retreated before the fight: nothing taken")
    -- a raid that cannot start: the cart goes on, nothing taken
    Forced_Battle_Manager.active_battle = "wh3_someone_elses_battle"; local nlog = #FBM_LOG
    TURN = 9004; enter(os2.id, raider(rP, 777)); answer(rP, RD, "FIRST")
    eq(#FBM_LOG, nlog, "CA's manager busy: no battle"); eq(ships_of("oA"), 1, "and the raid is never free")
    Forced_Battle_Manager.active_battle = ""
    -- a raider in a stance CA's manager cannot attack from (raiding, ambush, encamped): no battle, nothing taken
    STANCES[782] = "MILITARY_FORCE_ACTIVE_STANCE_TYPE_LAND_RAID"; nlog = #FBM_LOG
    TURN = 9008; enter(os2.id, raider(rP, 782)); answer(rP, RD, "FIRST")
    eq(#FBM_LOG, nlog, "a raider that cannot attack starts no battle"); eq(ships_of("oA"), 1, "and takes nothing")
    GARRISON[784] = true
    TURN = 9011; enter(os2.id, raider(rP, 784)); answer(rP, RD, "FIRST")
    eq(#FBM_LOG, nlog, "a garrisoned raider starts no battle")
    STANCES[785] = "MILITARY_FORCE_ACTIVE_STANCE_TYPE_MARCH"
    TURN = 9012; enter(os2.id, raider(rP, 785)); answer(rP, RD, "FIRST")
    eq(#FBM_LOG, nlog + 1, "a marching raider attacks: CA's manager locks its retreat itself")
    battle_done(false, true, { [785] = true }); nlog = #FBM_LOG
    -- the raiding army gone by the answer
    TURN = 9005; enter(os2.id, raider(rP, 778)); FORCES[778] = nil; answer(rP, RD, "FIRST")
    eq(#FBM_LOG, nlog, "the army is gone: no battle")
    -- a human army standing by a computer's cart at the computer's turn start does not take it
    F.state.ships = {}; TURN = 9006; local os3 = F.ship(oA.iface, oa1.iface, oa2.iface, "coal", 60)
    rP.armies = { field(rP, os3.x, os3.y, 779) }
    TURN = 9007; turn_start(oA); eq(F.ship_by_id(os3.id) ~= nil, true, "a player takes a computer's cart only by walking in")
    eq(os3.leg, 2, "and it moves on")
    rP.armies = {}
    -- a computer army still walks in and takes it
    local kA = faction("kA", { sc = "wh_main_sc_grn_greenskins" }); local ka1 = region("ka1", 33300, 0, 4000, {}); own(kA, ka1, true)
    war(kA, oA); enter(os3.id, raider(kA, 780)); eq(F.ship_by_id(os3.id), nil, "a computer army takes it without a fight")
    eq(ka1.held.coal, os3.n, "into its settlement")

    -- DEFENCE: a computer army by the player's cart at the player's turn start
    local dPl = faction("dPl", { human = true, sc = "wh_main_sc_emp_empire" })
    local dp1 = region("dp1", 34000, 0, 4000, { coal = 2000 }); own(dPl, dp1, true)
    local dp2 = region("dp2", 34100, 0, 4000, {}); own(dPl, dp2)
    local aE = faction("aE", { sc = "wh_main_sc_grn_greenskins" }); local ae1 = region("ae1", 34500, 0, 4000, {}); own(aE, ae1, true)
    war(dPl, aE)
    TURN = 9100; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local ds1 = last_ship()
    aE.armies = { field(aE, ds1.x, ds1.y, 600) }; FEED_OFF = {}
    TURN = 9101; turn_start(dPl)
    local d = FBM_LOG[#FBM_LOG]
    eq(d.att, 1600, "the enemy army attacks"); eq(d.force.f, "dPl", "the player's escort defends")
    eq(d.force.units, ds1.escort, "the escort rolled at departure")
    eq(RETREAT_LOCKED, true, "retreat is locked: a retreat would read as a win")
    eq(FEED_OFF[1][1], true, "the escort's own messages are held back"); eq(FEED_OFF[1][2], "wh_event_category_character", "the character ones")
    eq(ships_of("dPl"), 1, "the cart waits for the battle"); eq(ds1.leg, 1, "and does not move yet")
    battle_done(false, true, { [1600] = true })
    eq(ships_of("dPl"), 1, "defended: the cart goes on"); eq(ds1.leg, 2, "it moves as it would have")
    TURN = 9102; aE.armies = { field(aE, ds1.x, ds1.y, 601) }; turn_start(dPl)
    battle_done(true, true, { [1601] = true })
    eq(ships_of("dPl"), 0, "lost: the enemy takes it"); eq(ae1.held.coal, ds1.n, "into its settlement")
    -- A BATTLE FOUGHT IN 3D: the campaign reloads and CA's handler runs first; still ours
    aE.armies = {}
    TURN = 9103; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local dr = last_ship()
    aE.armies = { field(aE, dr.x, dr.y, 608) }
    TURN = 9104; turn_start(dPl)
    battle_done(false, true, { [1608] = true }, { reload = true })
    eq(F.state.fight, nil, "CA's handler first: our record still read"); eq(dr.leg, 2, "and the defended cart moves on")
    -- the same attacker's OTHER battle (the escort not in it) is not ours
    aE.armies = {}
    TURN = 9105; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local du = last_ship()
    aE.armies = { field(aE, du.x, du.y, 609) }
    TURN = 9106; turn_start(dPl)
    battle_done(true, true, { [1609] = true }, { not_ours = true, reload = true })
    eq(F.ship_by_id(du.id) ~= nil, true, "the attacker's other battle takes nothing")
    eq(F.state.fight, nil, "and CA's manager has dropped ours, so the record goes now")
    eq(RETREAT_LOCKED, false, "retreat unlocked"); eq(FEED_OFF[#FEED_OFF][1], false, "the messages back on")
    -- A COMPUTER ARMY WALKING ONTO THE PLAYER'S ESCORTED CART: it waits for the turn-start battle
    aE.armies = {}; F.state.ships = {}
    TURN = 9107; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local dw = last_ship()
    enter(dw.id, raider(aE, 783)); eq(F.ship_by_id(dw.id) ~= nil, true, "a computer army does not take an escorted cart by walking in")
    aE.armies = { field(aE, dw.x, dw.y, 610) }; local nw = #FBM_LOG
    TURN = 9108; turn_start(dPl); eq(#FBM_LOG, nw + 1, "it fights the escort at the player's turn start")
    battle_done(true, true, { [1610] = true }); eq(F.ship_by_id(dw.id), nil, "and takes it only by winning")
    -- AN ATTACKER IN A STANCE THAT CANNOT ATTACK: the cart is taken as before, no battle hangs
    aE.armies = {}
    TURN = 9109; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local ds = last_ship()
    STANCES[1611] = "MILITARY_FORCE_ACTIVE_STANCE_TYPE_LAND_RAID"; aE.armies = { field(aE, ds.x, ds.y, 611) }; nw = #FBM_LOG
    TURN = 9110; turn_start(dPl); eq(#FBM_LOG, nw, "no battle"); eq(F.ship_by_id(ds.id), nil, "taken as before")
    aE.armies = {}
    -- a defence won on the arrival turn: it arrives
    aE.armies = {}
    TURN = 9120; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local da = last_ship()
    TURN = 9122; aE.armies = { field(aE, da.x, da.y, 602) }; local held2 = dp2.held.coal or 0; turn_start(dPl)
    battle_done(false, true, { [1602] = true })
    eq(ships_of("dPl"), 0, "defended on its last turn: it arrives"); eq(dp2.held.coal, held2 + da.n, "in full")
    -- two carts threatened in one turn start: the first fights, the second is taken
    aE.armies = {}
    TURN = 9200; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local t1 = last_ship()
    dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local t2 = last_ship()
    aE.armies = { field(aE, t1.x, t1.y, 603) }; local nb = #FBM_LOG
    TURN = 9201; turn_start(dPl)
    eq(#FBM_LOG, nb + 1, "one battle"); eq(ships_of("dPl"), 1, "the other cart is taken as before")
    -- a battle that is not ours leaves the record alone
    battle_done(true, true, { [99999] = true }); eq(F.state.fight ~= nil, true, "another battle: our record kept")
    eq(ships_of("dPl"), 1, "and the cart is not touched")
    aE.armies = {}
    TURN = 9202; turn_start(dPl); eq(F.state.fight, nil, "a record whose battle went elsewhere goes next turn")
    -- A BATTLE THAT NEVER FIRES: the next turn start undoes what F.fight set up
    F.state.ships = {}; TURN = 9203; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local sv = last_ship()
    aE.armies = { field(aE, sv.x, sv.y, 612) }
    TURN = 9204; turn_start(dPl); local sk = F.state.fight.key
    eq(RETREAT_LOCKED, true, "set up: retreat locked"); eq(KILLED[sk], nil, "and the escort out")
    CA_ARMED = false; aE.armies = {}
    Forced_Battle_Manager.forced_battles_list.wh3_ca_own_battle = {}
    turn_start(dPl)
    eq(F.state.fight ~= nil, true, "the turn it was set up, the record is kept")
    eq(Forced_Battle_Manager.forced_battles_list[sk] ~= nil, true, "and so is CA's entry for the battle to come")
    TURN = 9205; turn_start(dPl)
    eq(F.state.fight, nil, "stale record cleared"); eq(Forced_Battle_Manager.active_battle, "", "and CA's slot freed")
    eq(KILLED[sk], true, "the escort it spawned removed")
    eq(RETREAT_LOCKED, false, "the retreat unlocked"); eq(FEED_OFF[#FEED_OFF][1], false, "the messages back on")
    local ours = 0
    for k in pairs(Forced_Battle_Manager.forced_battles_list) do if string.sub(k, 1, 16) == "derpy_mr_escort_" then ours = ours + 1 end end
    eq(ours, 0, "our finished battles leave CA's saved list at the next turn start")
    eq(Forced_Battle_Manager.forced_battles_list.wh3_ca_own_battle ~= nil, true, "and CA's own are left alone")
    Forced_Battle_Manager.forced_battles_list.wh3_ca_own_battle = nil
    -- a cart with no escort is taken as before
    F.state.ships = {}
    TURN = 9300; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local ne = last_ship(); ne.escort = ""
    aE.armies = { field(aE, ne.x, ne.y, 604) }; nb = #FBM_LOG
    TURN = 9301; turn_start(dPl); eq(#FBM_LOG, nb, "no escort: no battle"); eq(ships_of("dPl"), 0, "taken as before")
    -- the switch off: today's rule
    F.state.rates.escort = false; aE.armies = {}
    TURN = 9400; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local o1 = last_ship()
    aE.armies = { field(aE, o1.x, o1.y, 605) }; nb = #FBM_LOG
    TURN = 9401; turn_start(dPl); eq(#FBM_LOG, nb, "off: no battle"); eq(ships_of("dPl"), 0, "taken as before")
    TURN = 9402; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local o2 = last_ship(); DILEMMAS = {}
    war(rP, dPl); enter(o2.id, raider(rP, 781)); eq(#DILEMMAS, 0, "off: no raid offer"); eq(ships_of("dPl"), 0, "walked in and taken")
    F.state.rates.escort = true; aE.armies = {}
    -- CA's manager absent (a campaign root that does not load it): taken as before
    local fbm = Forced_Battle_Manager; Forced_Battle_Manager = nil
    TURN = 9500; dp1.held.coal = 100; F.request("dPl", "send", "coal", "dp2"); local o3 = last_ship()
    aE.armies = { field(aE, o3.x, o3.y, 606) }
    TURN = 9501; turn_start(dPl); eq(ships_of("dPl"), 0, "no battle manager: taken as before")
    Forced_Battle_Manager = fbm; aE.armies = {}
    -- CA's override list without "retreat" (its override() returns nil): the battle still starts
    local uim = cm.get_campaign_ui_manager
    cm.get_campaign_ui_manager = function() return { override = function() return nil end } end
    F.state.ships = {}; dp1.held.coal = 100; TURN = 9600; F.request("dPl", "send", "coal", "dp2"); local o4 = last_ship()
    aE.armies = { field(aE, o4.x, o4.y, 607) }; nb = #FBM_LOG
    TURN = 9601; turn_start(dPl); eq(#FBM_LOG, nb + 1, "no retreat override: the battle still starts")
    battle_done(false, true, { [1607] = true }); cm.get_campaign_ui_manager = uim; aE.armies = {}
    -- spawning the escort is not a recruit
    F.state.fight = { id = "x", side = "defend", key = "k", taker = "aE", force = 1, turn = TURN }
    F.state.fight.owner = "aE"
    eq(F.recruit_paused("aE"), true, "the escort's owner is not charged while it spawns")
    eq(F.recruit_paused("dPl"), false, "every other faction still is")
    F.state.fight = nil
    F.state.ships = {}
    eq(#ERRORS, 0, "no script errors in escort battles: " .. table.concat(ERRORS, "; "))
end)()

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
    -- THE ARMY ROUTE: grant_unit_to_character fires no UnitTrained (measured 2026-10-11), so no free
    -- recruit may be booked, or the next ordinary recruit of the unit goes free
    local waP = faction("waP", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local wa1 = region("wa1", 42500, 0, 2000, { coal = 100, gromril = 100 }); own(waP, wa1, true)
    waP.armies = { host(71, { 1, 2, 3 }) }
    F.work_grant(waP.iface, axe, nil)
    eq(#GRANTED > 0 and GRANTED[#GRANTED].lookup, "character_cqi:71", "the army route")
    eq(next(F.state.factions.waP.works.free or {}), nil, "no free recruit booked")
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
    -- A COMPUTER'S UNIT PURCHASE goes straight into its army: no recruit, so no free recruit booked
    local axe = W.unit_wh_main_dwf_inf_ironbreakers
    local aiD = faction("aiD", { sc = "wh_main_sc_dwf_dwarfs" })
    local ad1 = region("ad1", 42900, 0, 4000, { gromril = 100, iron = 400 }); own(aiD, ad1, true)
    aiD.armies = { host(62, { 1, 2 }) }
    F.work_ai(aiD.iface)
    eq(ad1.held.gromril, 100 - axe.rare_n, "a computer pays the Workshop's gromril")
    eq(ad1.held.iron, 400 - axe.use_n, "and its iron")
    local adb = F.state.factions.aiD
    eq(next(adb and adb.works and adb.works.free or {}), nil, "and books no free recruit")
    local bought = GRANTED[#GRANTED].unit
    fire("UnitTrained", { unit = function() return {
        faction = function() return aiD.iface end, unit_key = function() return bought end,
        unit_caste = function() return "melee_infantry" end, get_unit_custom_battle_cost = function() return 1300 end } end })
    eq(ad1.held.iron < 400 - axe.use_n, true, "so its next ordinary recruit of the unit is charged")
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
turn_start(tC); eq(F.cost, counters, "a computer-run turn start keeps counting into the same round")
turn_start(hum); eq(F.round_cost, counters, "a human's turn start hands the round's counters over")
eq(F.cost.raid, 0, "and starts new ones")

eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))

-- ---- founding a rare building where no slot offers it (spec 2026-10-09) -------------------
;(function()
    local BUILT, PLACE_FAILS = {}, false
    local function fslot(kind, b)
        local s = { b = b, kind = kind }
        local i = { __s = s }
        i.has_building = function() return s.b ~= nil end
        i.building = function() return { name = function() return s.b end } end
        i.active = function() return not s.off end
        i.is_working = function() return s.busy == true end
        i.type = function() return s.kind end
        return i
    end
    local SEC = "secondary"
    -- the engine as measured on these regions (TRADE_RESOURCES.md 35a): the slot template does not
    -- offer the chain, so add_building_to_settlement places nothing, while
    -- instantly_upgrade_building_in_region puts it into the slot it is handed
    cm.add_building_to_settlement = function(_, rk, b) BUILT[#BUILT + 1] = rk .. "|" .. b end
    cm.instantly_upgrade_building_in_region = function(_, slot, b)
        BUILT[#BUILT + 1] = "up|" .. b
        if not PLACE_FAILS then slot.__s.b = b end
    end
    local DH = "wh3_main_combi_region_darkhold"
    local fP = faction("fP", { human = true, culture = "wh_main_emp_empire" })
    local dh = region(DH, 40000, 0, 400, {}); own(fP, dh, true)
    dh.slots = { fslot("primary", "wh_main_emp_settlement_minor_1"), fslot(SEC), fslot(SEC) }
    eq(DERPY_MR_FLOWS_FOUND[DH], "dragon_bone", "Darkhold founds dragon bone")
    local st = F.found_state(fP.iface, DH)
    eq(st and st.good, "dragon_bone", "a held listed region has something to found")
    eq(st.level, 0, "nothing built yet"); eq(st.next, 1, "level 1 next"); eq(st.cost, 1000, "at CA's price")
    eq(st.tier_need, 1, "and CA's tier"); eq(st.why, nil, "and can be done")
    -- no row: off the list, a culture with no chain, a region not held
    local xr = region("x_not_listed", 40100, 0, 400, {}); own(fP, xr)
    eq(F.found_state(fP.iface, "x_not_listed"), nil, "a region off the list: nothing")
    local BL = next(DERPY_MR_FLOWS_FOUND, nil)
    while BL and DERPY_MR_FLOWS_FOUND[BL] ~= "black_lotus" do BL = next(DERPY_MR_FLOWS_FOUND, BL) end
    local bl = region(BL, 40200, 0, 400, {}); own(fP, bl)
    eq(F.found_state(fP.iface, BL), nil, "the Empire has no black lotus chain: nothing")
    local fO = faction("fO", { human = true, culture = "wh_main_emp_empire" })
    eq(F.found_state(fO.iface, DH), nil, "a region it does not hold: nothing")
    -- FOUND: placed into the empty secondary slot, then charged
    TREASURY.fP = 0; BUILT = {}
    F.request("fP", "found", DH)
    eq(BUILT[1], "up|derpy_mr_bld_dragon_bone_emp_1", "the player's own race's level 1")
    eq(dh.slots[2].__s.b, "derpy_mr_bld_dragon_bone_emp_1", "into the first empty secondary slot")
    eq(dh.slots[3].__s.b, nil, "and only that one")
    eq(TREASURY.fP, -1000, "charged once it is there")
    -- UPGRADE: CA's browser will not offer it on this template (35a, M2), so the row does
    st = F.found_state(fP.iface, DH)
    eq(st.level, 1, "level 1 there"); eq(st.next, 2, "level 2 next"); eq(st.cost, 2000, "its price")
    eq(st.why, "tier", "a level 1 settlement cannot take it")
    F.request("fP", "found", DH); eq(#BUILT, 1, "refused: nothing built"); eq(TREASURY.fP, -1000, "nothing charged")
    dh.level = 2
    F.request("fP", "found", DH)
    eq(BUILT[2], "up|derpy_mr_bld_dragon_bone_emp_2", "upgraded in its slot"); eq(TREASURY.fP, -3000, "charged")
    dh.level = 3; F.request("fP", "found", DH)
    eq(F.found_state(fP.iface, DH), nil, "level 3: nothing more")
    -- NOT PLACED: nothing charged, a log line, still offered
    local dr = region("wh3_dlc20_combi_region_dragons_death", 40300, 0, 400, {}); own(fP, dr)
    dr.slots = { fslot("primary", "wh_main_emp_settlement_minor_1"), fslot(SEC) }
    eq(DERPY_MR_FLOWS_FOUND[dr.key], "dragon_bone", "Dragon's Death founds dragon bone")
    PLACE_FAILS = true; TREASURY.fP = 0; local nerr = #ERRORS
    F.request("fP", "found", dr.key)
    eq(TREASURY.fP, 0, "not placed: nothing charged"); eq(#ERRORS, nerr + 1, "and a log line")
    eq(F.found_state(fP.iface, dr.key) ~= nil, true, "still offered")
    PLACE_FAILS = false; ERRORS[#ERRORS] = nil
    -- REFUSED: short of gold, no empty slot
    local fG = faction("fG", { human = true, culture = "wh_main_emp_empire", gold = 500 })
    local dd = region("wh3_main_chaos_region_dragons_death", 40400, 0, 400, {}); own(fG, dd)
    dd.slots = { fslot("primary", "wh_main_emp_settlement_minor_1"), fslot(SEC) }
    eq(F.found_state(fG.iface, dd.key).why, "gold", "short of gold")
    BUILT = {}; F.request("fG", "found", dd.key); eq(#BUILT, 0, "short of gold: refused")
    dr.slots = { fslot("primary", "wh_main_emp_settlement_minor_1"), fslot(SEC, "wh_main_emp_tavern_1") }
    eq(F.found_state(fP.iface, dr.key).why, "slot", "no empty slot")
    dr.slots = { fslot("primary"), fslot(SEC), fslot(SEC) }
    dr.slots[2].__s.off, dr.slots[3].__s.busy = true, true
    eq(F.found_state(fP.iface, dr.key).why, "slot", "an empty primary, a locked slot and one being built in do not count")
    -- ANOTHER RACE'S BUILDING OF THE SAME GOOD: the captor is offered no second one
    local fK = faction("fK", { human = true, culture = "wh_main_grn_greenskins" })
    lose(fP, dh); own(fK, dh)
    -- at level 1, so the level-3 rule cannot answer for the guard
    dh.slots[2].__s.b = "derpy_mr_bld_dragon_bone_emp_1"
    eq(F.found_state(fK.iface, DH), nil, "another race's building there: nothing to found")
    -- the faction's own race's chain, whatever its race
    local WY = next(DERPY_MR_FLOWS_FOUND, nil)
    while WY and DERPY_MR_FLOWS_FOUND[WY] ~= "wyvern_scales" do WY = next(DERPY_MR_FLOWS_FOUND, WY) end
    local wy = region(WY, 40600, 0, 400, {}); own(fK, wy)
    wy.slots = { fslot("primary", "wh_main_grn_settlement_minor_1"), fslot(SEC) }
    BUILT = {}; F.request("fK", "found", WY)
    eq(BUILT[1], "up|derpy_mr_bld_wyvern_scales_grn_1", "a Greenskin founds the Greenskin chain")
    -- LOST BEFORE THE REQUEST RUNS, a computer faction, the actions switch off
    -- Darkhold emptied first, so the other-race guard cannot answer for the ownership check
    dh.slots[2].__s.b = nil
    eq(F.found_state(fK.iface, DH) ~= nil, true, "held and empty: Darkhold could be founded")
    lose(fK, dh); BUILT = {}
    F.request("fK", "found", DH); eq(#BUILT, 0, "lost before the request: nothing")
    local fC = faction("fC", { culture = "wh_main_emp_empire" })
    local dk = region("wh3_main_combi_region_tor_sethai", 40500, 0, 400, {}); own(fC, dk)
    dk.slots = { fslot("primary", "wh_main_emp_settlement_minor_1"), fslot(SEC) }
    eq(F.found_state(fC.iface, dk.key).why, nil, "a computer faction could build there")
    F.request("fC", "found", dk.key); eq(#BUILT, 0, "a computer faction's request: nothing")
    dr.slots = { fslot("primary", "wh_main_emp_settlement_minor_1"), fslot(SEC) }
    eq(F.found_state(fP.iface, dr.key).why, nil, "Dragon's Death could be founded")
    F.state.rates.actions = false
    F.request("fP", "found", dr.key); eq(#BUILT, 0, "actions off: refused")
    F.state.rates.actions = true
    cm.add_building_to_settlement, cm.instantly_upgrade_building_in_region = nil, nil
    eq(#ERRORS, 0, "no script errors in founding: " .. table.concat(ERRORS, "; "))
end)()
-- Stock targets: shared quantities, explicit zero and rounded shipment loss.
;(function()
    local v = { held = { grain = 20, salted_fish = 15 }, totals = { provisions = 35 },
        auto_keep = { provisions = 30 }, auto_target = {}, incoming = {}, incoming_use = {},
        capacity = { grain = 400, salted_fish = 400 }, recurring = {}, work_target = {}, policy = {} }
    eq(F.available_stock(v, "grain"), 5, "shared food reserve")
    v.held.grain, v.totals.provisions = 15, 30
    eq(F.available_stock(v, "salted_fish"), 0, "food reserve is not spent twice")
    v.policy.salted_fish = { keep = 0 }
    eq(F.available_stock(v, "salted_fish"), 15, "zero overrides Auto")
    v.held.grain, v.totals.provisions = 12, 12
    v.incoming.grain, v.incoming_use.provisions = 18, 18
    v.auto_target.provisions = 80
    eq(F.import_need(v, "grain"), 50, "subtract held and incoming")
    v.policy.grain = { target = 40 }
    eq(F.import_need(v, "grain"), 10, "per-good target")
    v.policy.grain.target = 0
    eq(F.import_need(v, "grain"), 0, "zero disables requests")
    local fit = F.fit_delivery(30, 10)
    eq(fit.n, 12, "rounded dispatch"); eq(fit.got, 10, "net arrival")
    fit = F.fit_delivery(11, 10)
    eq(fit.n, 10, "avoid loss plateau"); eq(fit.got, 9, "partial arrival")
    eq(F.fit_delivery(1, 10), nil, "one unit all lost")
    v.recurring.provisions = 8
    local fc = F.stock_forecast(v, { provisions = 6 }).provisions
    eq(fc.net, -2, "net production"); eq(fc.cover, 6, "net cover")
    eq(F.stock_forecast(v).provisions.cover, 1, "stored cover when production unknown")
    eq(F.stock_forecast(v, { provisions = 8 }).provisions.mode, "stable", "production covers demand")
    v.recurring.provisions = 0
    eq(F.stock_forecast(v, {}).provisions.mode, "none", "no recurring use")
    eq(F.stock_forecast(v, {}).provisions.production, 0, "confirmed zero is known production")
end)()
;(function()
    local old_state, old_turn = F.state, TURN
    F.state = { factions = {}, rates = F.read_rates(), ship_seq = 50000 }; TURN = 50000
    local f = faction("policy_test", { human = true })
    local a = region("policy_a", 80000, 0, 400, { grain = 20, salted_fish = 15, iron = 390, gromril = 900 })
    local b = region("policy_b", 80010, 0, 400, { grain = 50, timber = 100 })
    own(f, a, true); own(f, b); inprov("policy_province", a, b)
    a.level = 3; b.level = 1
    local v = F.stock_view(f.iface, a.iface)
    eq(v.recurring.provisions, 6, "settlement level drives recurring food")
    eq(v.auto_keep.provisions, 30, "five turns kept")
    eq(v.auto_target.provisions, 60, "ten turns requested")
    eq(v.totals.war, 390, "rare stock excluded from totals")
    eq(v.auto_keep.war, 100, "quarter of one store kept for bonus")
    eq(F.state.factions.policy_test, nil, "view creates no book")
    eq(F.state.supply, nil, "view creates no supply book")
    eq(F.state.ships, nil, "view creates no shipment list")
    local supply = F.supply_book(f.name, a.prov, true); supply.materials = true
    eq(F.stock_view(f.iface, a.iface).recurring.building, 4, "owned province supply cost")
    eq(F.stock_view(f.iface, b.iface).recurring.building, nil, "only capital pays supply")
    b.missing_pools = true
    eq(F.stock_view(f.iface, b.iface).recurring.provisions, nil, "missing pools have no demand")
    b.missing_pools = false
    F.state.rates.upkeep, F.state.rates.supply = false, false
    v = F.stock_view(f.iface, a.iface)
    eq(v.auto_keep.war, 0, "disabled bonuses have no holding floor")
    eq(next(v.recurring), nil, "disabled phases create no recurring demand")
    F.state.rates.upkeep, F.state.rates.supply = true, true
    local computer = faction("policy_ai")
    local cr = region("policy_ai_r", 80100, 0, 400, { grain = 20 }); own(computer, cr, true)
    F.state.rates.ai = false
    eq(next(F.recurring_use(computer.iface, cr.iface)), nil, "AI demand obeys other factions switch")
    F.state.rates.ai = true
    local dead = faction("policy_dead", { human = true, sc = "wh2_dlc09_sc_tmb_tomb_kings" })
    local dr = region("policy_dead_r", 80200, 0, 400, { grain = 20 }); own(dead, dr, true)
    eq(next(F.recurring_use(dead.iface, dr.iface)), nil, "excluded faction has no recurring demand")
    -- The existing synchronized request door remains editable with actions off.
    F.state.rates.actions = false
    MP = true; SENT = {}
    F.request(f.name, "stock", "iron", "keep", "380")
    eq(F.stock_policy(f.name, "iron").keep, nil, "MP click cannot write locally")
    eq(SENT[1][2], "dmr1|stock|iron|keep|380", "compact stock request")
    ui_trigger(f.cqi, SENT[1][2])
    eq(F.stock_policy(f.name, "iron").keep, 380, "trigger writes with actions off")
    for _, payload in ipairs({ "dmr1|stock|iron|keep|-1", "dmr1|stock|iron|keep|1.5",
        "dmr1|stock|iron|keep|1000001", "dmr1|stock|iron|keep|nan", "dmr1|stock|iron|other|10",
        "dmr1|stock|unknown|keep|10", "dmr1|stock|iron|keep|10|extra" }) do ui_trigger(f.cqi, payload) end
    eq(F.stock_policy(f.name, "iron").keep, 380, "invalid requests cannot change policy")
    eq(F.set_stock_policy(computer.name, "iron", "keep", "10"), false, "AI cannot edit")
    eq(F.set_stock_policy(f.name, "iron", "keep", math.huge), false, "infinite policy refused")
    eq(F.set_stock_policy(f.name, "iron", "keep", 0/0), false, "NaN policy refused")
    MP = false
    b.missing_pools = true
    local sale = F.sale(f.iface, "iron")
    eq(sale.n, 10, "sale respects protected amount below half-cap surplus")
    F.sell(f.iface, "iron"); eq(a.held.iron, 380, "sale leaves exact Keep")
    eq(F.ship(f.iface, a.iface, b.iface, "iron", 60), nil, "direct dispatch protects Keep")
    b.missing_pools = false
    F.set_stock_policy(f.name, "iron", "keep", "300")
    local plan = F.send_plan(f.iface, b.key, "iron")
    F.set_stock_policy(f.name, "iron", "keep", "370")
    local ship = F.ship(f.iface, a.iface, b.iface, "iron", plan.n)
    eq(a.held.iron, 370, "stale preview revalidated at dispatch")
    eq(ship.n, 9, "net cargo after clamped dispatch")
    eq(F.ship(f.iface, a.iface, cr.iface, "iron", 10), nil, "foreign destination refused")
    eq(F.ship(f.iface, a.iface, a.iface, "iron", 10), nil, "same store refused")
    eq(F.ship(f.iface, a.iface, b.iface, "iron", 1.5), nil, "fractional dispatch refused")
    -- Ordinary consumption is deliberately able to spend a reserve.
    F.draw(a.iface, F.stock(a.iface), "war", 20, DERPY_MR_FLOWS_KIND.spend, f.name)
    eq(a.held.iron, 350, "deliberate spending ignores Keep")
    F.set_stock_policy(f.name, "grain", "keep", "100")
    eq(F.import_need(F.stock_view(f.iface, a.iface), "grain"), 80, "manual Keep raises Auto goal for that good")
    F.set_stock_policy(f.name, "grain", "target", "0")
    eq(F.import_need(F.stock_view(f.iface, a.iface), "grain"), 0, "target zero remains independent of Keep")
    local rare = F.stock_view(f.iface, a.iface)
    local max_work = 0
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do
        if w.rare == "gromril" and F.work_open(f.iface, w) then max_work = math.max(max_work, w.rare_n) end
    end
    eq(rare.work_target.gromril or 0, max_work, "rare goal is largest race-open catalogued batch")
    rare.held.gromril, rare.capacity.gromril = 0, 2
    eq(F.import_need(rare, "gromril"), math.min(2, max_work), "rare goal clamped by actual capacity")
    rare.policy.gromril = { target = 1 }
    eq(F.import_need(rare, "gromril"), 1, "manual rare target")
    -- Sanitation touches only policy fields, preserving unrelated state.
    F.book(f.name).stock.bad = { keep = 4 }
    F.book(f.name).stock.iron.target = -2
    F.book(f.name).stock.grain.extra = true
    F.book(f.name).orders = { festival = 20 }
    SAVED = {}; cm.saving_game_callbacks[1]({}); cm.loading_game_callbacks[1]({})
    eq(F.stock_policy(f.name, "grain").target, 0, "zero survives save/load")
    eq(F.stock_policy(f.name, "iron").target, nil, "invalid loaded number discarded")
    eq(F.book(f.name).stock.bad, nil, "unknown loaded good discarded")
    eq(F.book(f.name).orders.festival, 20, "other saved fields retained")
    F.request(f.name, "stock", "iron", "keep", "auto")
    eq(F.book(f.name).stock.iron, nil, "Auto removes empty per-good record")
    local policy = F.stock_policy(f.name, "grain"); policy.keep = 99
    eq(F.stock_policy(f.name, "grain").keep, 100, "policy reads return copies")
    whole(F.state, "stock_target_state")
    -- Different foods and partners must share the same removable category surplus.
    F.state.rates.trade = 25
    local p1, p2 = faction("policy_partner_a", { human = true }), faction("policy_partner_b", { human = true })
    local r1, r2 = region("policy_pa", 80300, 0, 400, {}), region("policy_pb", 80400, 0, 400, {})
    own(p1, r1, true); own(p2, r2, true)
    f.partners = { p2, p1 }
    a.held, b.held = { grain = 35, salted_fish = 15 }, {}
    F.set_stock_policy(f.name, "grain", "keep", "auto")
    F.set_stock_policy(f.name, "grain", "target", "auto")
    F.trade(f.iface)
    eq(F.use_total(F.stock(a.iface), "provisions") >= 30, true, "foods and partners cannot double-spend shared reserve")
    local first = cargo_to(p1.name, "grain") + cargo_to(p1.name, "salted_fish")
    local second = cargo_to(p2.name, "grain") + cargo_to(p2.name, "salted_fish")
    eq(first > 0, true, "the first partner by key is sent something")
    eq(first >= second, true, "partners allocated by faction key")
    -- Partial incoming quantities permit another cart, enough incoming suppresses one.
    F.state.ships = {}
    a.held, b.held = { timber = 0 }, { timber = 100 }
    supply.materials, supply.standing = true, true
    F.state.ships = { { id = "partial", f = f.name, stem = "marble", n = 5, to = a.key, due = TURN + 2 } }
    F.standing(f.iface, { capital = a.iface, regions = { a.iface, b.iface } }, supply, 4)
    eq(#F.state.ships, 2, "partial cart does not block further demand")
    eq(F.state.ships[2].n, 35, "standing target subtracts net incoming across goods")
    local debit = 100 - b.held.timber
    eq(debit, F.state.ships[2].n + F.lost(debit), "dispatch debit equals cargo plus loss")
    F.standing(f.iface, { capital = a.iface, regions = { a.iface, b.iface } }, supply, 4)
    eq(#F.state.ships, 2, "enough incoming prevents duplicate")
    -- One source pool walk regardless of the number of goods and partners.
    local big = faction("policy_large")
    for i = 1, 100 do
        local r = region("policy_large_" .. i, 81000 + i, 0, 600, { coal = 500, grain = 500 })
        own(big, r, i == 1)
    end
    local q1, q2 = faction("policy_large_p1"), faction("policy_large_p2")
    local qr1, qr2 = region("policy_large_p1r", 82000, 0, 600, {}), region("policy_large_p2r", 82100, 0, 600, {})
    own(q1, qr1, true); own(q2, qr2, true)
    big.partners = { q1, q2 }
    local clock = os.clock(); F.trade(big.iface); local elapsed = os.clock() - clock
    local walks = 0
    for _, r in ipairs(big.regions) do walks = walks + (r.pool_walks or 0) end
    eq(walks, 100, "source pools scanned once, not per good or partner")
    local reads = 0
    for _, r in ipairs(big.regions) do reads = reads + (r.pool_reads or 0); r.pool_walks = 0 end
    print(string.format("stock allocation: 100 sources / 2 partners, %d source walks + %d direct reads, %.6fs", walks, reads, elapsed))
    local q3 = faction("policy_large_p3"); own(q3, region("policy_large_p3r", 82200, 0, 600, {}), true)
    big.partners[#big.partners + 1] = q3
    F.state.rates.ai = false
    F.trade(big.iface); walks = 0
    for _, r in ipairs(big.regions) do walks = walks + r.pool_walks end
    eq(walks, 0, "other factions off skips AI-to-AI allocation")
    F.state.rates.ai = true
    F.trade(big.iface); walks = 0
    for _, r in ipairs(big.regions) do walks = walks + r.pool_walks end
    eq(walks, 100, "adding partner does not rescan source pools per good")
    F.state, TURN = old_state, old_turn
end)()
-- ONE READ A TURN START (2026-11-03: 7,500 store reads in one computer round, 2.35 s): inside a turn start a
-- settlement's stores are read whole once until something is written to them; a write is seen by the next read,
-- a reader may change what it was given, and the kept copy ends with the turn start
;(function()
    local f = faction("once_reader")
    local a = region("once_a", 83000, 0, 1000, { grain = 400, coal = 300 })
    own(f, a, true)
    local trade, guard, got = F.trade, F.guard, nil
    F.trade = function(fa)
        local held = F.stock(a.iface)
        local w = a.pool_walks or 0
        held.coal = -1
        local again = F.stock(a.iface)
        local walked = (a.pool_walks or 0) - w
        F.move(a.iface, nil, "coal", 50, DERPY_MR_FLOWS_KIND.move, f.name, nil)
        local fresh = F.stock(a.iface)
        fresh.coal = -5
        got = walked .. "," .. again.coal .. "," .. fresh.coal .. "," .. F.stock(a.iface).coal
        return trade(fa)
    end
    local ok, e = pcall(F.on_faction_turn_start, f.iface)
    F.trade = trade
    eq(ok and got, "0,300,-5,250", "a second read walks nothing, a reader's change is its own, a write is seen: "
       .. tostring(e))
    local w = a.pool_walks
    F.stock(a.iface)
    eq(a.pool_walks - w, 1, "the kept copy ends with the turn start")
    -- a turn start that throws past its guards still ends it
    local edict_turn = F.edict_turn
    F.guard = function(fn, ...) if fn == F.edict_turn then error("boom") end; return guard(fn, ...) end
    local thrown = not pcall(F.on_faction_turn_start, f.iface)
    F.guard = guard
    w = a.pool_walks; F.stock(a.iface); F.stock(a.iface)
    eq(tostring(thrown) .. "," .. (a.pool_walks - w), "true,2", "a turn start that threw left its copy behind")
end)()
-- Local paid production and sustained services: no passive output is replaced.
;(function()
    local previous, turn = F.state, TURN
    F.state = { factions = {}, rates = F.read_rates() }; TURN = 60000
    local f = faction("economy_dwarf", { human = true, sc = "wh_main_sc_dwf_dwarfs" })
    local r = region("economy_hold", 90000, 0, 400, { grain = 200, beer = 20, pipeweed = 20 })
    own(f, r, true)
    local building = { name = function() return "wh_main_dwf_tavern_1" end,
        percent_health = function() return r.health or 100 end }
    r.iface.slot_list = function() return list({ { has_building = function() return true end,
        building = function() return building end } }) end
    eq(type(F.economy_toggle), "function", "economy model exists")
    eq(F.economy_book(r.key, false), nil, "preview does not create orders")
    F.economy_toggle(f.iface, r.key, "brew")
    eq(F.economy_book(r.key, false).orders.brew, true, "processing enabled without producing")
    eq(r.held.beer, 20, "toggle produces nothing")
    F.economy_turn(f.iface)
    eq(r.held.grain, 188, "batch takes local grain")
    eq(r.held.beer, 28, "batch gives local beer")
    F.economy_turn(f.iface)
    eq(r.held.beer, 28, "repeated turn cannot duplicate output")
    TURN = TURN + 1; r.health = 90; F.economy_turn(f.iface)
    eq(r.held.grain, 188, "damaged brewery pauses")
    TURN = TURN + 1; r.health = 100; r.held.beer = 397
    local writes = #LOG; F.economy_turn(f.iface)
    eq(r.held.grain, 188, "full output refuses all inputs")
    eq(#LOG, writes, "full output performs no transactions")
    TURN = TURN + 1; r.held.beer = 10; r.held.grain = 0
    writes = #LOG; F.economy_turn(f.iface)
    eq(r.held.beer, 10, "missing inputs give no output")
    eq(#LOG, writes, "missing inputs perform no transactions")
    F.economy_toggle(f.iface, r.key, "brew")
    F.economy_toggle(f.iface, r.key, "halls")
    TURN = TURN + 1; r.held = { grain = 100, beer = 8, pipeweed = 2 }
    F.economy_turn(f.iface)
    eq(r.held.beer, 4, "service takes named beer")
    eq(r.held.pipeweed, 1, "service takes complete second input")
    eq(r.iface:has_effect_bundle("derpy_mr_service_halls"), true, "paid service applies benefit")
    F.economy_turn(f.iface); eq(r.held.beer, 4, "service cannot charge twice")
    TURN = TURN + 1; r.held.pipeweed = 0; F.economy_turn(f.iface)
    eq(r.held.beer, 4, "missing basket member charges nothing")
    eq(r.iface:has_effect_bundle("derpy_mr_service_halls"), false, "unpaid service loses benefit")
    eq(F.economy_book(r.key, false).orders.halls, true, "unpaid service remains enabled")
    local view = F.stock_view(f.iface, r.iface)
    eq(view.recurring.named.beer, 4, "named demand is forecast")
    eq(F.import_need(view, "beer") >= 36, true, "named target cannot be satisfied with grain")
    F.set_stock_policy(f.name, "beer", "target", 0)
    eq(F.import_need(F.stock_view(f.iface, r.iface), "beer"), 0, "explicit target still wins")
    F.economy_toggle(f.iface, r.key, "halls")
    eq(r.iface:has_effect_bundle("derpy_mr_service_halls"), false, "disable removes service immediately")
    -- Failed second transaction must restore the first input and produce no output.
    F.economy_toggle(f.iface, r.key, "brew"); TURN = TURN + 1
    r.held = { grain = 200, beer = 20 }
    local transaction = cm.entity_add_pooled_resource_transaction
    cm.entity_add_pooled_resource_transaction = function(self, e, key, n)
        if n > 0 and string.find(key, "beer") then error("injected output failure") end
        return transaction(self, e, key, n)
    end
    F.economy_turn(f.iface)
    cm.entity_add_pooled_resource_transaction = transaction
    eq(r.held.grain, 200, "transaction failure restores inputs")
    eq(r.held.beer, 20, "transaction failure gives no output")
    local foreign = faction("economy_invader", { human = true })
    own(foreign, r, true); F.on_region_change(r.iface)
    eq(F.economy_book(r.key, false), nil, "capture clears former orders")
    -- Every definition runs against its real generated building keys and named basket.
    for _, key in ipairs({ "brew", "powder", "preserve", "print", "weave", "halls", "records", "tea", "feasts", "archives", "mess", "bake", "tan", "cloth", "toolmaking", "builders", "hospital" }) do
        TURN = TURN + 1
        local d = DERPY_MR_FLOWS_ECONOMY[key]
        assert(d, "missing economy content: " .. key)
        local race = ({ brew = "dwf", powder = "dwf", preserve = "ogr", print = "emp", weave = "cth",
            halls = "dwf", records = "emp", tea = "cth", feasts = "brt", archives = "hef", mess = "chd", bake="dwf", tan="ogr", cloth="emp", toolmaking="dwf", builders="dwf", hospital="emp" })[key]
        local who = faction("recipe_" .. key, { human = true, sc = "wh_main_sc_" .. race .. "_test" })
        local rr = region("recipe_region_" .. key, 90100, 0, 1000, { grain = 600, timber = 600 })
        own(who, rr, true)
        for stem in pairs(d.cost) do rr.held[stem] = 600 end
        if d.output then rr.held[d.output[1]] = 0 end
        local bk = d.levels and next(d.levels)
        rr.iface.slot_list = function() return list(bk and { {
            has_building = function() return true end,
            building = function() return { name = function() return bk end,
                percent_health = function() return 100 end } end } } or {}) end
        local before = {}; for stem, n in pairs(rr.held) do before[stem] = n end
        F.request(who.name, "economy", rr.key, key)
        eq(F.economy_book(rr.key, false).orders[key], true, key .. " synchronized door enables")
        local snap = F.economy_book(rr.key, false)
        F.economy_rows(who.iface, rr.iface)
        eq(F.economy_book(rr.key, false), snap, key .. " preview preserves book identity")
        F.economy_turn(who.iface)
        for stem, n in pairs(d.cost) do eq(rr.held[stem], before[stem] - n, key .. " exact input " .. stem) end
        if d.output then eq(rr.held[d.output[1]], d.output[2], key .. " exact output")
        else eq(rr.iface:has_effect_bundle(d.bundle), true, key .. " actual bundle") end
        -- Real save callbacks round-trip the order and duplicate-turn stamp.
        SAVED = {}; cm.saving_game_callbacks[1]({}); F.state = {}; cm.loading_game_callbacks[1]({})
        local paid = {}; for stem, n in pairs(rr.held) do paid[stem] = n end
        F.economy_turn(who.iface)
        for stem, n in pairs(paid) do eq(rr.held[stem], n, key .. " save/reload cannot charge again") end
        for missing in pairs(d.cost) do
            TURN = TURN + 1
            rr.held[missing] = 0
            local writes = #LOG
            F.economy_turn(who.iface)
            eq(#LOG, writes, key .. " missing " .. missing .. " refuses before any debit")
            for stem, n in pairs(paid) do
                if stem ~= missing then eq(rr.held[stem], n, key .. " other inputs untouched") end
                rr.held[stem] = n
            end
        end
        local other = faction("recipe_other_" .. key, { human = true })
        F.request(other.name, "economy", rr.key, key)
        eq(F.economy_book(rr.key, false).orders[key], true, key .. " foreign request refused")
        F.state.rates.actions = false
        F.request(who.name, "economy", rr.key, key)
        eq(F.economy_book(rr.key, false).orders[key], true, key .. " actions off blocks toggle")
        F.state.rates.actions = true
        F.request(who.name, "economy", rr.key, "not_a_recipe")
        eq(F.economy_book(rr.key, false).orders.not_a_recipe, nil, "unknown recipe refused")
        TURN = TURN + 1; F.state.rates[d.kind] = false
        F.economy_turn(who.iface)
        for stem, n in pairs(paid) do eq(rr.held[stem], n, key .. " campaign switch prevents payment") end
        if d.bundle then eq(rr.iface:has_effect_bundle(d.bundle), false, key .. " switch removes benefit") end
        F.state.rates[d.kind] = true
    end
    for race, level in pairs({ emp = "wh_main_emp_industry_basic_1", brt = "wh_main_brt_farm_extra_1" }) do
        TURN = TURN + 1
        local who = faction("brewer_" .. race, { human = true, sc = "wh_main_sc_" .. race .. "_test" })
        local rr = region("brewery_" .. race, 90150, 0, 1000, { grain = 600, beer = 0 })
        own(who, rr, true)
        rr.iface.slot_list = function() return list({ { has_building = function() return true end,
            building = function() return { name = function() return level end,
                percent_health = function() return 100 end } end } }) end
        F.request(who.name, "economy", rr.key, "brew")
        assert(F.economy_book(rr.key, false), race .. " brewery must be eligible")
        F.economy_turn(who.iface)
        eq(rr.held.grain, 588, race .. " brewing charges grain")
        eq(rr.held.beer, 8, race .. " brewing produces beer")
    end
    -- Services preserve survival stock and never run in a minor settlement.
    TURN = TURN + 1; own(f, r, true); r.held = { beer = 4, pipeweed = 1 }
    F.economy_toggle(f.iface, r.key, "halls"); F.economy_turn(f.iface)
    eq(r.held.beer, 4, "service cannot consume essential food reserve")
    F.economy_clear(r.iface)
    local minor = region("economy_minor", 90200, 0, 400, { grain = 100, beer = 20, pipeweed = 20 })
    own(f, minor, false); minor.capital = r
    F.economy_toggle(f.iface, minor.key, "halls")
    eq(F.economy_book(minor.key, false), nil, "minor cannot enable province service")
    -- Auto Keep protects named inputs even when substitutes fill the category.
    r.held = { grain = 200, beer = 3, pipeweed = 20 }
    F.economy_toggle(f.iface, r.key, "halls")
    eq(F.available_stock(F.stock_view(f.iface, r.iface), "beer"), 0, "named beer kept despite abundant grain")
    F.set_stock_policy(f.name, "beer", "keep", 0)
    eq(F.available_stock(F.stock_view(f.iface, r.iface), "beer"), 3, "explicit Keep overrides named reserve")
    -- Both machines receive a request; a UI click alone cannot mutate multiplayer orders.
    F.economy_clear(r.iface); MP = true
    F.request(f.name, "economy", r.key, "halls")
    eq(F.economy_book(r.key, false), nil, "multiplayer request waits for synchronized dispatch")
    MP = false
    -- AI buys the same service only with two baskets above survival reserves.
    local ai = faction("economy_ai", { sc = "wh_main_sc_dwf_dwarfs" })
    local ar = region("economy_ai_capital", 90300, 0, 400, { grain = 100, beer = 8, pipeweed = 2 })
    own(ai, ar, true); TURN = TURN + 1; F.economy_turn(ai.iface)
    eq(ar.held.beer, 4, "AI pays same service bill")
    eq(ar.held.pipeweed, 1, "AI pays named second input")
    TURN = TURN + 1; F.economy_turn(ai.iface)
    eq(ar.held.beer, 4, "AI pauses below two-basket budget")
    local brewer = faction("economy_ai_brewer", { sc = "wh_main_sc_dwf_dwarfs" })
    local br = region("economy_ai_brewery", 90400, 0, 400, { grain = 250, beer = 0 })
    own(brewer, br, true); br.iface.slot_list = r.iface.slot_list
    TURN = TURN + 1; F.economy_turn(brewer.iface)
    eq(br.held.beer, 8, "AI processes a missing named output despite category substitutes")
    eq(br.held.grain, 238, "AI production has no free inputs")
    F.book(brewer.name).stock = { beer = { target = 0 } } -- retained policy if a human faction becomes AI
    TURN = TURN + 1; F.economy_turn(brewer.iface)
    eq(br.held.grain, 238, "zero output target pauses AI processing")
    -- WORKSHOP INPUTS: a computer brewery without grain gets a cart from its farm, and then brews.
    F.state.ship_seq = 20000
    local miller = faction("economy_ai_miller", { sc = "wh_main_sc_dwf_dwarfs" })
    local mb = region("economy_ai_mill_brewery", 90500, 0, 400, { beer = 0 })
    local mf = region("economy_ai_mill_farm", 90510, 0, 400, { grain = 300 })
    own(miller, mb, true); own(miller, mf); mb.iface.slot_list = r.iface.slot_list
    TURN = TURN + 1; F.economy_turn(miller.iface)
    eq(mb.held.beer, 0, "a brewery without grain brews nothing")
    F.book(miller.name).stock = { beer = { target = 0 } }
    F.economy_supply(miller.iface); eq(#F.ships(), 0, "no cart for an output nobody wants")
    F.book(miller.name).stock = nil
    F.state.rates.processing = false
    F.economy_supply(miller.iface); eq(#F.ships(), 0, "no cart with processing off")
    F.state.rates.processing = true
    miller.human = true
    F.economy_supply(miller.iface); eq(#F.ships(), 0, "a player's workshop gets no cart")
    miller.human = false
    -- two batches are 24 grain past the brewery's own 10 food reserve; 44 at the farm delivers 30
    mf.held.grain = 44
    F.economy_supply(miller.iface); eq(#F.ships(), 0, "a store that cannot cover two batches sends nothing")
    mf.held.grain = 300
    F.economy_supply(miller.iface)
    local cart = F.ships()[1]
    eq(cart and cart.to .. "/" .. cart.stem, mb.key .. "/grain", "the short grain gets a cart to the brewery")
    eq(cart.n, 90, "a full cart, filled past two batches")
    F.economy_supply(miller.iface); eq(#F.ships(), 1, "one cart at a time")
    TURN = cart.due; F.ships_turn(miller.iface); F.economy_turn(miller.iface)
    eq(mb.held.beer, 8, "the delivered grain brews")
    -- A recipe whose second input no store can spare gets no cart for the first.
    F.state.ships = {}
    local baker = faction("economy_ai_baker", { sc = "wh_main_sc_dwf_dwarfs" })
    local bb = region("economy_ai_bakery", 90600, 0, 400, {})
    local bf = region("economy_ai_bake_farm", 90610, 0, 400, { grain = 300 })
    own(baker, bb, true); own(baker, bf)
    bb.iface.slot_list = function() return list({ { has_building = function() return true end,
        building = function() return { name = function() return "wh_main_dwf_farm_1" end,
            percent_health = function() return 100 end } end } }) end
    F.economy_supply(baker.iface); eq(#F.ships(), 0, "no salt anywhere: no grain cart either")
    bf.held.salt = 50
    F.economy_supply(baker.iface)
    eq(#F.ships() == 1 and F.ships()[1].stem, "grain", "with salt to spare, the grain goes first")
    -- and it runs at every computer turn start
    F.state.ships = {}; mb.held = { beer = 0 }; TURN = TURN + 1
    turn_start(miller)
    eq(#F.ships() == 1 and F.ships()[1].to, mb.key, "a computer's turn start sends the cart")
    F.state.rates.ai = false; TURN = TURN + 1; ar.held.beer = 20; ar.held.pipeweed = 10
    F.economy_turn(ai.iface); eq(ar.held.beer, 20, "AI master switch honored")
    print("economy: 9 recipes, 8 services, refusal/rollback, reserves, save/reload, requests and AI budgets pass")
    F.state, TURN = previous, turn
end)()

;(function()
    local old, turn, lookup = F.state, TURN, cm.get_military_force_by_cqi
    local f = faction("army_food", {human=true})
    local r = region("army_food_home", 0, 0, 1000, {grain=100})
    own(f,r,true)
    local forces = {}
    local function force(id,n)
        F.state.army_issued=F.state.army_issued or {};F.state.army_issued[tostring(id)]=true
        local a = {n=n, r=r, sea=false, owner=f}
        local ch = {is_at_sea=function() return a.sea end, has_region=function() return a.r~=nil end,
            region=function() return a.r and a.r.iface or NULL end}
        a.iface = {is_null_interface=function() return false end, command_queue_index=function() return id end,
            faction=function() return a.owner.iface end, has_general=function() return true end,
            is_armed_citizenry=function() return a.garrison==true end, general_character=function() return ch end,
            force_type=function() return {key=function() return a.type or "ARMY" end} end,
            unit_list=function() local t={} for i=1,a.n do t[i]={} end return list(t) end}
        forces[id]=a; f.armies[#f.armies+1]=a.iface
        return a
    end
    cm.get_military_force_by_cqi=function(_,id) return forces[id] and forces[id].iface or false end
    local message = cm.show_message_event
    cm.show_message_event=function() end
    local remove = cm.remove_effect_bundle_from_force
    cm.remove_effect_bundle_from_force=function() end
    F.state={factions={},rates=F.read_rates()}; F.state.rates.army_provisions=true
    local a=force(801,20)
    local sc=f.iface.subculture
    for _, subculture in ipairs({"wh_main_sc_vmp_vampire_counts","wh2_dlc11_sc_cst_vampire_coast"}) do
        f.iface.subculture=function() return subculture end
        eq(F.uses_stores(f.iface),true,"undead keep trading stores")
        eq(#F.provision_rows(f.iface),0,"undead do not eat army meals")
        eq(F.recurring_use(f.iface,r.iface).provisions,nil,"undead forecast has no meals")
        local held=r.held.grain
        F.upkeep(f.iface);eq(r.held.grain,held,"undead settlement keeps provisions")
        F.state.armies={["801"]={f=f.name,goods={},short=3,auto=true}}
        F.provisions_turn(f.iface);eq(F.state.armies["801"],nil,"undead legacy penalty retires")
    end
    f.iface.subculture=sc; F.state.armies=nil
    TURN=301
    local demand=F.stock_view(f.iface,r.iface)
    eq(demand.recurring.provisions,7,"local army meal enters forecast")
    eq(demand.auto_keep.provisions,35,"exports retain settlement and army meals")
    eq(demand.auto_target.provisions,70,"imports target settlement and army meals")
    eq(F.available_stock(demand,"grain"),65,"army reserve protects exports")
    eq(F.state.armies,nil,"demand preview creates no cargo record")
    local extra=force(804,4)
    eq(F.recurring_use(f.iface,r.iface).provisions,8,"two local armies contribute independently")
    extra.garrison=true
    eq(F.recurring_use(f.iface,r.iface).provisions,7,"garrison does not solicit relief")
    a.sea=true
    eq(F.recurring_use(f.iface,r.iface).provisions,2,"sea army creates no fictitious local demand")
    a.sea=false
    eq(#F.provision_rows(f.iface),1,"army preview finds force")
    eq(F.state.armies,nil,"army preview does not migrate")
    r.held.grain=35
    F.provision_action(f.iface,"801","load")
    eq(F.provision_total(F.state.armies["801"]),25,"loading releases army reserve but retains essential ten")
    eq(r.held.grain,10,"loading retains essential reserve")
    r.held.grain=100; F.state.armies=nil
    F.set_stock_policy(f.name,"grain","keep",90)
    F.provision_action(f.iface,"801","load")
    eq(F.provision_total(F.state.armies["801"]),10,"army reserve release still honors explicit Keep")
    eq(r.held.grain,90,"explicit Keep remains in settlement")
    F.set_stock_policy(f.name,"grain","keep","auto")
    r.held.grain=100; F.state.armies=nil
    local economy_named=F.economy_named
    F.economy_named=function() return {grain=12} end
    r.held.grain=90
    F.provision_action(f.iface,"801","load")
    eq(F.provision_total(F.state.armies["801"]),20,"loading retains enabled named-input reserve")
    eq(r.held.grain,70,"settlement and named demand remain protected")
    F.economy_named=economy_named
    r.held.grain=100; F.state.armies=nil
    F.provisions_turn(f.iface)
    local b=F.state.armies["801"]
    eq(F.provision_total(b),25,"five turns after meal")
    eq(r.held.grain,70,"only loaded goods leave settlement")
    eq(b.short,0,"meal covered")
    F.provisions_turn(f.iface)
    eq(r.held.grain,70,"duplicate turn no debit")
    F.provision_action(f.iface,"801","unload")
    eq(r.held.grain,95,"unload returns exact unconsumed goods")
    eq(F.provision_total(b),0,"unload empties cargo")
    eq(b.auto,false,"unload pauses refill")
    a.sea=true
    F.provision_action(f.iface,"801","load")
    eq(F.provision_total(b),10,"sea Load buys capped field supplies")
    eq(r.held.grain,95,"sea purchase never accesses settlement stores")
    b.goods={} -- Exhaust the purchased batch to exercise shortage stages.
    TURN=302; F.provisions_turn(f.iface); eq(b.short,1,"first shortage")
    TURN=303; F.provisions_turn(f.iface); eq(b.short,2,"second shortage")
    eq(FORCE_BUNDLES[#FORCE_BUNDLES][1],"derpy_mr_army_hungry","second shortage movement penalty")
    TURN=304; F.provisions_turn(f.iface); eq(b.short,3,"third shortage")
    eq(FORCE_BUNDLES[#FORCE_BUNDLES][1],"derpy_mr_army_starved","third shortage full penalty")
    eq(r.held.grain,95,"sea cannot load")
    a.sea=false; a.n=4
    -- LOAD FILLS TO WHAT IT CAN CARRY (Workshop report, 2026-11-05): 10 turns, not Auto's 5
    F.provision_action(f.iface,"801","load"); eq(F.provision_total(b),10,"manual load fills to capacity")
    F.provision_action(f.iface,"801","load"); eq(F.provision_total(b),10,"a second load at capacity takes nothing")
    TURN=305; F.provisions_turn(f.iface); eq(b.short,0,"full meal recovers")
    eq(F.provision_total(b),9,"manual load does not enable auto")
    b.auto=true; TURN=TURN+1; F.provisions_turn(f.iface)
    eq(F.provision_total(b),8,"Auto above its 5 turns takes nothing back and adds nothing")
    b.auto=false
    a.n=1; b.goods.grain=50
    F.provision_action(f.iface,"801","load"); eq(F.provision_total(b),50,"downsizing preserves excess")
    a.r=nil; F.provision_action(f.iface,"801","unload"); eq(F.provision_total(b),50,"no region no unload")
    a.r=r; r.siege=true; F.provision_action(f.iface,"801","unload"); eq(F.provision_total(b),50,"siege no unload")
    r.siege=false
    local other=faction("army_food_other")
    a.owner=other; TURN=306; F.provisions_turn(other.iface)
    eq(F.state.armies["801"],nil,"owner change retires cargo")
    a.owner=f; forces[801]=nil; f.armies={}; F.provisions_turn(f.iface)
    eq(F.state.armies["801"],nil,"destroyed force stays retired")
    f.armies={}; local c=force(802,4)
    r.held={grain=100,beer=20}; F.state.armies={}; F.state.stock=nil
    F.state.stock = nil
    local original_available=F.available_stock
    F.available_stock=function(v,stem) if stem=="grain" then return math.max(0,(v.held.grain or 0)-99) end return 0 end
    TURN=307; F.provisions_turn(f.iface)
    eq(r.held.grain,99,"refill respects reserve")
    eq(F.provision_total(F.state.armies["802"]),0,"partial meal consumed only paid stock")
    eq(F.state.armies["802"].short,0,"one-unit meal succeeds")
    F.available_stock=original_available
    local saved_before=SAVED
    SAVED={}; cm.saving_game_callbacks[1]({}); F.state={}; cm.loading_game_callbacks[1]({})
    local held=r.held.grain
    F.provisions_turn(f.iface); eq(r.held.grain,held,"reload prevents second meal")
    SAVED=saved_before
    local cb=F.state.armies["802"]
    cb.auto=false; cb.goods={beer=7}; c.n=40
    eq(F.provision_rows(f.iface)[1].need,10,"unit transfers change need")
    eq(F.provision_total(cb),7,"unit transfers mint no cargo")
    F.provision_action(f.iface,"802","unload")
    eq(r.held.beer,27,"unload preserves original good")
    r.held.grain=200; r.held.beer=0
    local transaction=cm.entity_add_pooled_resource_transaction
    cm.entity_add_pooled_resource_transaction=function() end
    F.provision_action(f.iface,"802","load")
    eq(F.provision_total(cb),0,"failed native debit creates no cargo")
    cm.entity_add_pooled_resource_transaction=transaction
    local balance=r.held.grain
    F.state.rates.actions=false
    F.dispatch(f.name,{"provisions","802","load"})
    eq(r.held.grain,balance,"action switch protects army requests")
    F.state.rates.actions=true
    F.dispatch(f.name,{"provisions","802","load","extra"})
    eq(r.held.grain,balance,"invalid army request arity")
    F.dispatch(f.name,{"provisions","999","load"})
    eq(F.state.armies["999"],nil,"request cannot invent force")
    f.human=false; cb.auto=true; TURN=308
    F.provisions_turn(f.iface)
    eq(F.provision_total(cb),50,"AI pays same target")
    eq(r.held.grain,140,"AI pays native pools")
    F.state.rates.ai=false
    eq(#F.provision_rows(f.iface),0,"AI switch hides disabled army logistics")
    TURN=309; F.provisions_turn(f.iface)
    eq(r.held.grain,140,"AI switch prevents debit")
    eq(F.state.armies["802"],nil,"AI switch removes penalties and cargo book")
    F.state.rates.ai=true
    -- OTHER FACTIONS' ARMY MEALS (MCT, 2026-11-08): the campaign AI knows nothing of provisions
    local R0 = F.state.rates
    R0.ai_home_fed, R0.ai_field_rations, R0.ai_half_rations, R0.ai_food = true, false, false, false
    r.held={}; F.state.armies={["802"]={f=f.name,goods={},short=0,auto=false}}; cb=F.state.armies["802"]
    TURN=310; F.provisions_turn(f.iface); eq(cb.short,0,"fed at home: no meal missed in its own settlement")
    R0.ai_home_fed=false
    TURN=311; F.provisions_turn(f.iface); eq(cb.short,1,"fed at home off: an empty store is a missed meal")
    r.siege=true; R0.ai_home_fed=true
    TURN=312; F.provisions_turn(f.iface); eq(cb.short,2,"fed at home: not in a besieged settlement")
    r.siege=false; cb.short=0
    f.human=true; TURN=313; F.provisions_turn(f.iface); eq(cb.short,1,"fed at home: never a player's army")
    f.human=false; cb.short=0
    cb.goods={grain=100}; R0.ai_half_rations=true
    TURN=314; F.provisions_turn(f.iface); eq(F.provision_total(cb),95,"half rations: 5 of a 10 meal")
    f.human=true; TURN=315; F.provisions_turn(f.iface); eq(F.provision_total(cb),85,"half rations: never a player's army")
    f.human=false; R0.ai_half_rations=false
    TURN=316; F.provisions_turn(f.iface); eq(F.provision_total(cb),75,"half rations off: the whole meal")
    c.r=nil; cb.goods={}; cb.auto=true; cb.short=0
    TURN=317; F.provisions_turn(f.iface)
    eq(F.provision_total(cb)..","..cb.short,"0,1","rations abroad off: nothing to buy away from home")
    R0.ai_field_rations=true
    TURN=318; F.provisions_turn(f.iface)
    eq(F.provision_total(cb)..","..cb.short,"10,0","rations abroad: two meals bought, one eaten")
    f.human=true; cb.goods={}; TURN=319; F.provisions_turn(f.iface)
    eq(F.provision_total(cb),0,"rations abroad: a player's army still buys only at sea")
    f.human=false; c.r=r
    local made, tx = {}, cm.entity_add_pooled_resource_transaction
    cm.entity_add_pooled_resource_transaction=function(s,reg,key,n)
        if string.find(key,"_processed",1,true) then made[#made+1]=key..":"..n end
        return tx(s,reg,key,n)
    end
    r.held={}
    F.upkeep_region(r.iface,f.name,true); eq(#made,0,"more food off: nothing made")
    R0.ai_food=true
    F.upkeep_region(r.iface,f.name,true)
    eq(made[1],"derpy_mr_store_hardtack_processed:"..(F.NEED*1),"more food: a level's meals in the Empire's hardtack")
    local sc0=f.iface.subculture; f.iface.subculture=function() return "wh3_dlc23_sc_chd_chaos_dwarfs" end; made={}
    F.upkeep_region(r.iface,f.name,true)
    eq(made[1],"derpy_mr_store_salted_meat_processed:"..(F.NEED*1),"more food: the Chaos Dwarfs' salted meat")
    f.iface.subculture=sc0
    f.human=true; made={}
    F.upkeep_region(r.iface,f.name,true); eq(#made,0,"more food: never a player's settlement")
    f.human=false; cm.entity_add_pooled_resource_transaction=tx
    R0.ai_home_fed, R0.ai_field_rations, R0.ai_half_rations, R0.ai_food = true, true, false, false
    local d=force(803,4); d.garrison=true
    eq(#F.provision_rows(f.iface),1,"garrison excluded")
    d.garrison=false; F.state.fight={escort=803}
    eq(#F.provision_rows(f.iface),1,"temporary escort excluded")
    F.state.fight=nil
    eq(#F.provision_rows(f.iface),2,"a field army eats")
    local fed=F.provision_need(f.iface,r.iface)
    -- CARAVANS AND CONVOYS CARRY NO RATIONS (Workshop report, 2026-11-06): they live on foreign roads
    for _, kind in ipairs({"CARAVAN","CONVOY"}) do
        d.type=kind
        eq(#F.provision_rows(f.iface),1,kind.." excluded")
        eq(F.provision_need(f.iface,r.iface),fed-1,kind.." asks its settlement for no meal")
        F.provision_seed_force(d.iface); eq((F.state.armies or {})["803"],nil,kind.." is issued no rations")
    end
    -- a caravan already hungry in a save from before this: its record and its penalty go at its owner's turn
    local removed=cm.remove_effect_bundle_from_force; local cleared={}
    cm.remove_effect_bundle_from_force=function(_,key,id) if id==803 then cleared[#cleared+1]=key..":"..id end end
    F.state.armies=F.state.armies or {}
    F.state.armies["803"]={f=f.name,goods={},short=3,auto=true,done=TURN}
    F.provisions_turn(f.iface)
    cm.remove_effect_bundle_from_force=removed
    eq(tostring(F.state.armies["803"])..","..table.concat(cleared,";"),
        "nil,derpy_mr_army_hungry:803;derpy_mr_army_starved:803","a saved caravan's record and penalties are cleared")
    d.type=nil
    F.state.rates.army_provisions=false; TURN=309
    F.provisions_turn(f.iface)
    eq(F.state.armies["802"],nil,"disabled mechanic clears records and penalties")
    -- A remote owned store can recover through paid deliveries, without cargo gifts.
    F.state.rates.army_provisions=true; F.state.rates.ai=true
    d.garrison=true; c.n=20; r.held={}
    local donor=region("army_food_donor",10,0,1000,{grain=200})
    own(f,donor,false)
    F.state.armies={ ["802"]={f=f.name,goods={},auto=true,short=3,done=TURN} }
    F.state.ships={}; F.state.ship_seq=10000
    F.provision_supply(f.iface)
    eq(#F.ships(),1,"AI dispatches food to army region")
    local cart=F.ships()[1]
    eq(cart.to,r.key,"army relief destination is local store")
    eq(cart.n,70,"delivery fills ten-meal combined target")
    eq(donor.held.grain,122,"relief pays gross goods including loss")
    eq(F.provision_total(F.state.armies["802"]),0,"dispatch grants no immediate army food")
    F.provision_supply(f.iface)
    eq(#F.ships(),1,"repeated planning counts committed cargo")
    TURN=TURN+2; F.ships_turn(f.iface)
    eq(r.held.grain,70,"paid relief arrives in settlement")
    F.provisions_turn(f.iface)
    eq(F.state.armies["802"].short,0,"AI recovers through paid local loading")
    eq(F.provision_total(F.state.armies["802"]),25,"recovery retains five carried meals")
    eq(r.held.grain,40,"army consumes reserve intended for itself")
    local function food_total()
        local n=(r.held.grain or 0)+(donor.held.grain or 0)+F.provision_total(F.state.armies["802"])
        for _, s in ipairs(F.ships()) do n=n+s.n end
        return n
    end
    for cycle=1,12 do
        local before=food_total()
        donor.held.grain=donor.held.grain+12
        TURN=TURN+1; F.ships_turn(f.iface); F.upkeep(f.iface); F.provisions_turn(f.iface)
        local paid=donor.held.grain
        F.provision_supply(f.iface)
        local gross=paid-donor.held.grain
        eq(food_total(),before+12-4-5-F.lost(gross),"relief conservation cycle "..cycle)
        eq(F.state.armies["802"].short,0,"sustained paid recovery cycle "..cycle)
    end
    F.state.armies["802"].auto=false
    eq(F.recurring_use(f.iface,r.iface).provisions,2,"paused Auto does not solicit deliveries")
    F.state.armies["802"].auto=true
    while #F.ships()>0 do F.drop(F.ships()[1]) end
    r.held={}; donor.held.grain=200
    F.book(f.name).stop={export={grain=true}}
    F.provision_supply(f.iface)
    eq(#F.ships(),0,"relief respects export hold")
    F.book(f.name).stop={import={grain=true}}
    F.provision_supply(f.iface)
    eq(#F.ships(),0,"relief respects import hold")
    F.book(f.name).stop={}
    F.state.rates.ai=false
    F.provision_supply(f.iface)
    eq(#F.ships(),0,"AI switch blocks relief dispatch")
    -- Field purchases cannot bypass ordinary land supply or mint unpaid cargo.
    F.state.rates.ai=true;f.human=true;c.n=20;c.sea=false;c.r=r
    F.state.armies={};TURN=900
    eq(F.provision_rows(f.iface)[1].mobile,false,"settled land army has no field vendor")
    c.r=donor;local owner=donor.owner;donor.owner=other
    eq(F.provision_rows(f.iface)[1].mobile,false,"foreign land does not offer field vendor to settled faction")
    donor.owner=owner;c.r=r
    c.sea=true
    local row=F.provision_rows(f.iface)[1]
    eq(row.buy,10,"field purchase quote is two meals")
    eq(row.price,100,"field quote exposes actual price")
    local gold=f.iface:treasury()
    F.provisions_turn(f.iface)
    eq(f.iface:treasury(),gold,"human Auto never buys field rations")
    F.provision_action(f.iface,"802","load")
    local mobile=F.state.armies["802"]
    eq(F.provision_total(mobile),10,"manual field purchase fills only two meals")
    eq(mobile.goods.salted_fish,10,"sea purchase records actual provision good")
    eq(f.iface:treasury(),gold-100,"field cargo has verified gold payment")
    F.provision_action(f.iface,"802","load")
    eq(f.iface:treasury(),gold-100,"duplicate field request charges once")
    mobile.goods={};F.provision_action(f.iface,"802","load")
    eq(F.provision_total(mobile),0,"same-turn spent cargo cannot reset purchase limit")
    local save=SAVED;SAVED={};cm.saving_game_callbacks[1]({});F.state={};cm.loading_game_callbacks[1]({})
    mobile=F.state.armies["802"];F.provision_action(f.iface,"802","load")
    eq(F.provision_total(mobile),0,"saved purchase limit survives reload");SAVED=save
    TURN=901
    local goldwrite=cm.treasury_mod;cm.treasury_mod=function() end
    F.provision_action(f.iface,"802","load")
    eq(F.provision_total(mobile),0,"failed gold debit creates no field rations")
    cm.treasury_mod=goldwrite
    local treasury=TREASURY[f.name];TREASURY[f.name]=-99995
    F.provision_action(f.iface,"802","load")
    eq(F.provision_total(mobile),0,"insufficient gold cannot buy fractional rations")
    TREASURY[f.name]=treasury
    c.sea=false;local regions=f.regions;f.regions={};c.r=nil
    eq(F.provision_rows(f.iface)[1].mobile,true,"homeless horde can buy supplies on land")
    F.provision_action(f.iface,"802","load")
    eq(mobile.goods.salted_meat,10,"land purchase records meat")
    f.regions=regions;c.r=r;c.sea=true;f.human=false;TURN=902;mobile.goods={};mobile.auto=true
    gold=f.iface:treasury();F.provisions_turn(f.iface)
    eq(F.provision_total(mobile),5,"AI buys same two meals then eats one")
    eq(f.iface:treasury(),gold-100,"AI pays identical field price")
    F.provisions_turn(f.iface);eq(f.iface:treasury(),gold-100,"AI duplicate owner turn is safe")
    f.human=true;c.garrison=true
    local fresh=force(805,20);F.state.army_issued["805"]=nil
    local stock,gold=r.held.grain,f.iface:treasury()
    F.provision_seed_force(fresh.iface)
    local issued=F.state.armies["805"]
    eq(F.provision_total(issued),25,"new army starts exactly half full")
    eq(issued.goods.hardtack,25,"human starter uses campaign biscuits")
    eq(issued.done,TURN,"starter army first eats next owner turn")
    F.provisions_turn(f.iface)
    eq(F.provision_total(issued),25,"creation turn does not eat or top up starter cargo")
    eq(r.held.grain,stock,"starter grant does not debit protected stores")
    eq(f.iface:treasury(),gold,"starter grant is not a surprise purchase")
    issued.goods={};F.provision_seed_force(fresh.iface)
    eq(F.provision_total(issued),0,"exhausted cargo never gets another starter grant")
    local prior_save=SAVED;SAVED={};cm.saving_game_callbacks[1]({});F.state={};cm.loading_game_callbacks[1]({})
    F.provision_seed_force(fresh.iface)
    eq(F.provision_total(F.state.armies["805"]),0,"reload never refills starter cargo");SAVED=prior_save
    F.provision_clear("805");F.provision_seed_force(fresh.iface)
    eq(F.provision_total(F.state.armies["805"]),0,"retired ledger cannot repeat starter grant")
    F.state.army_issued=nil
    prior_save=SAVED;SAVED={};cm.saving_game_callbacks[1]({});F.state={};cm.loading_game_callbacks[1]({})
    F.provision_clear("805");F.provision_seed_force(fresh.iface)
    eq(F.provision_total(F.state.armies["805"]),0,"legacy ledgers migrate before retirement");SAVED=prior_save
    local cb=cm.callback;cm.callback=function(_,fn) fn() end
    local created=force(808,12);F.state.army_issued["808"]=nil
    fire("MilitaryForceCreated",{military_force_created=function() return created.iface end})
    eq(F.provision_total(F.state.armies["808"]),15,"force-created event seeds half cargo")
    F.state.armies["808"].goods={}
    fire("MilitaryForceCreated",{military_force_created=function() return created.iface end})
    eq(F.provision_total(F.state.armies["808"]),0,"duplicate creation event cannot refill")
    cm.callback=cb
    local living=f.iface.subculture
    f.iface.subculture=function() return "wh3_dlc23_sc_chd_chaos_dwarfs" end
    local hungry=force(806,8);F.state.army_issued["806"]=nil
    F.provision_seed_force(hungry.iface)
    eq(F.state.armies["806"].goods.salted_meat,10,"Chaos Dwarf starter uses preserved meat")
    f.iface.subculture=function() return "wh_main_sc_vmp_vampire_counts" end
    local dead=force(807,20);F.state.army_issued["807"]=nil
    F.provision_seed_force(dead.iface);eq(F.state.armies["807"],nil,"undead get no starter rations")
    f.iface.subculture=living
    cm.show_message_event=message
    F.state,TURN,cm.get_military_force_by_cqi,cm.remove_effect_bundle_from_force=old,turn,lookup,remove
end)()
;(function()
    F.route_turns = distance_turns
    local saved, turn = F.state, TURN
    F.state = { factions = {}, rates = F.read_rates(), ship_seq = 90000 }
    F.state.rates.supply, F.state.rates.army_provisions = false, false
    F.state.rates.escort = false
    -- Upkeep on: the buyer eats and holds 60 salt at b, so b's provisions cover is 30 turns and its price sits at the floor, and a
    -- partner cart's destination floor never binds in this block (its own case is below). The seller eats nothing, so its price is by fullness.
    F.state.rates.upkeep = true
    TURN = 100000
    local buyer = faction("route_buyer", { human = true, gold = 10000 })
    local seller = faction("route_seller", { gold = 10000, sc = "wh_main_sc_vmp_vampire_counts" })
    local a = region("route_a",0,0,1000,{grain=500})
    local b = region("route_b",80,0,1000,{salt=60})
    local c = region("route_c",400,0,1000,{grain=500})
    own(buyer,a,true); own(buyer,b); own(seller,c,true)
    buyer.partners={seller}; seller.partners={buyer}
    eq(F.route_turns(a.iface,b.iface),2,"coordinate duration")
    b.x=1; eq(F.route_turns(a.iface,b.iface),1,"minimum travel")
    b.x=0; eq(F.route_turns(a.iface,b.iface),1,"one cell apart: still a turn")
    eq(F.route_turns(a.iface,c.iface),6,"maximum travel")
    b.x=80
    -- THE ROAD'S LENGTH (agreement cargo, task 5): a shipment with a saved road takes its STEPS at F.ROAD_PER_TURN, as a convoy
    -- does but never past six turns; with no road it is the straight line as before. Each case drops its cart and gives the grain back.
    do
        local grain, journey = a.held.grain, DERPY_MR_TERRAIN_ROUTES
        local function line(points) local p = {} for i = 1, points do p[i] = { i - 1, 0 } end return p end
        local function sent(road)
            DERPY_MR_TERRAIN_ROUTES = { journey = function() return road end }
            local s = F.ship(buyer.iface, a.iface, b.iface, "grain", 100)
            DERPY_MR_TERRAIN_ROUTES = journey
            assert(s, "the shipment was refused")
            return s
        end
        b.x = 30
        local winding = sent(line(100))
        eq(winding.duration, 3, "a winding road of 99 hexes is 3 turns"); eq(winding.due, winding.at + 3, "and it is due then")
        F.drop(winding)
        local plain = sent(nil)
        eq(plain.duration, 1, "no road: straight line"); F.drop(plain)
        b.x = 80
        local long = sent(line(80))
        eq(long.duration, 2, "80 points are 79 hexes: 2 turns"); F.drop(long)
        eq(F.route_turns(a.iface, b.iface, line(41)), 1, "40 steps are one turn")
        eq(F.route_turns(a.iface, b.iface, line(42)), 2, "41 steps are two: the road counts steps, not points")
        eq(F.route_turns(a.iface, b.iface, line(1)), 1, "a road of one point is never under one turn")
        eq(F.route_turns(a.iface, b.iface, line(500)), 6, "a very long road is six turns, whatever the reach")
        eq(F.route_turns(a.iface, b.iface, {}), 2, "an empty road is no road: the straight line")
        -- a bridge is one point but as many hexes as the reach search charged for it: four points here, 81 hexes
        local over = sent({ { 0, 0 }, { 40, 0 }, { 80, 0 }, { 81, 0 } })
        eq(over.duration, 3, "a bridged road of four points and 81 hexes is 3 turns, not 1"); F.drop(over)
        eq(F.route_turns(a.iface, b.iface, { { 0, 0 }, { 40, 0 }, { 80, 0 } }), 2, "80 hexes over three points are 2 turns")
        -- with no road the figure is a lower bound: the longer span, not the Euclidean distance (30 by 30 is 42, which would be 2)
        b.x, b.y = 30, 30
        eq(F.route_turns(a.iface, b.iface), 1, "30 by 30 with no road: the longer span of 30 is one turn")
        b.x, b.y = 0, 80
        eq(F.route_turns(a.iface, b.iface), 2, "80 along y with no road: two turns, the y span counts")
        b.x, b.y = 80, 0
        a.held.grain = grain
    end
    local runtime = DERPY_MR_TERRAIN_ROUTES
    local road = {{0,0},{0,20},{40,20},{80,20},{80,0}}
    DERPY_MR_TERRAIN_ROUTES = {journey=function() return road end}
    local s=F.ship(buyer.iface,a.iface,b.iface,"grain",400)
    eq(s.duration, 3, "the detour is 120 hexes: 3 turns")
    eq(s.road,road,"new shipment saves its solved road")
    eq(s.x,0,"cargo starts on the road"); eq(s.y,0,"cargo starts at its first point")
    DERPY_MR_TERRAIN_ROUTES = runtime
    eq(s.gross,100,"gross cart cap"); eq(s.n,90,"net capped cargo")
    eq(a.held.grain,400,"actual capped source debit")
    F.state=copy(F.state); s=F.ships()[1]
    eq(s.road[3][2],20,"saved road survives reload")
    TURN=s.due-1; F.ship_step(buyer.iface,s,TURN); eq(b.held.grain or 0,0,"not before saved due")
    eq(s.x,40,"cargo advances to the road midpoint"); eq(s.y,20,"cargo stays on its detour")
    eq(MARKERS[s.id].x,s.x,"interception trigger follows cargo x")
    eq(MARKERS[s.id].y,s.y,"interception trigger follows cargo y")
    eq(SCENES[s.id].x,s.x,"caravan scene follows cargo")
    F.ship_step(buyer.iface,s,TURN); eq(s.x,40,"same-turn step does not advance twice")
    s.due=TURN+3; TURN=TURN+1; F.ship_step(buyer.iface,s,TURN)
    eq(F.ship_by_id(s.id),s,"saved due wins over elapsed legacy time")
    TURN=s.due; F.ship_step(buyer.iface,s,TURN); eq(b.held.grain,90,"arrival on stored due")
    F.ship_step(buyer.iface,s,TURN); eq(b.held.grain,90,"duplicate arrival cannot mint goods")
    local old={id="legacy_route",f=buyer.name,stem="grain",n=9,from=a.key,to=b.key,at=TURN,leg=1,x=0,y=0}
    F.state.ships={old}; TURN=TURN+1; F.ship_step(buyer.iface,old,TURN)
    eq(F.ship_by_id(old.id),old,"legacy fallback waits two turns")
    TURN=TURN+1; F.ship_step(buyer.iface,old,TURN); eq(b.held.grain,99,"legacy arrival retained")
    b.held.grain=0
    F.set_stock_policy(buyer.name,"grain","keep","390")
    s=F.ship(buyer.iface,a.iface,b.iface,"grain",100)
    eq(s.gross,10,"new carts preserve source Keep")
    F.drop(s); F.set_stock_policy(buyer.name,"grain","keep","auto")
    local o=F.route_create(buyer.iface,a.key,b.key,"grain",150,50)
    eq(o~=nil,true,"internal named order created")
    a.absent={grain=true}; local _,ready=F.route_status(buyer.iface,o); a.absent=nil
    eq(ready,"Ready","an own-faction order needs no price, so no pool at the source")
    local own_gold=buyer.iface:treasury()
    F.routes_turn(buyer.iface); eq(#F.ships(),1,"recurring internal dispatch")
    local mine=F.ships()[1]
    eq(mine.sender,nil,"an own-faction cart is no contract"); eq(mine.escrow,nil,"and reserves no gold")
    eq(mine.price_c,nil,"and carries no price"); eq(o.last_price_c,nil,"and the order shows no last price")
    eq(buyer.iface:treasury(),own_gold,"and the buyer pays nothing")
    eq(F.ships()[1].gross,50,"order batch cap")
    F.routes_turn(buyer.iface); eq(#F.ships(),1,"once per order per turn")
    TURN=TURN+1; F.routes_turn(buyer.iface); eq(#F.ships(),2,"next turn sends toward net target")
    F.route_control(buyer.iface,o.id,"cancel"); eq(#F.routes(buyer.iface),0,"cancel removes order")
    while #F.ships()>0 do F.drop(F.ships()[1]) end
    b.held.grain=0
    local contract=F.route_create(buyer.iface,c.key,b.key,"grain",70,100)
    eq(contract.price,nil,"no price locked at creation")
    local bg,sg=buyer.iface:treasury(),seller.iface:treasury()
    local quoted=F.buy_price(F.local_price(F.stock_view(seller.iface,c.iface),"grain",seller.name))
    local shown=F.quote(seller.iface,c.iface,"grain").buy
    TURN=TURN+1; F.routes_turn(buyer.iface); local cart=F.ships()[1]
    local first=cart
    eq(cart.n,70,"net target after loss")
    eq(cart.price_c,quoted,"origin's buy price at dispatch")
    eq(cart.price_c,110,"one gold base at a half-full store, plus the 10% spread")
    eq(shown,cart.price_c,"the price the panel offers is the price the cart is charged")
    eq(contract.last_price_c,cart.price_c,"shown as the last price paid")
    eq(cart.escrow,F.gold(70,cart.price_c),"escrow is whole gold for the delivered-unit maximum")
    eq(buyer.iface:treasury(),bg-cart.escrow,"buyer charged once")
    eq(seller.iface:treasury(),sg,"seller unpaid before arrival")
    eq(F.incoming(buyer.name,b.key,"grain"),70,"recipient reservation")
    eq(F.incoming(seller.name,b.key,"grain"),0,"sender has no recipient reservation")
    local snapshot=copy(F.state); F.state=copy(snapshot)
    contract=F.routes(buyer.iface)[1]
    F.routes_turn(buyer.iface); eq(#F.ships(),1,"reload cannot redispatch same turn")
    cart=F.ships()[1]; b.held.grain=983; TURN=cart.due
    F.arrive(buyer.iface,cart)
    eq(b.held.grain,1000,"partial arrival fits actual free space")
    local pay=F.gold(17,cart.price_c)
    eq(pay,18,"17 units at 1.10 pay 18 whole gold")
    eq(seller.iface:treasury(),sg+pay,"pay only credited cargo")
    eq(buyer.iface:treasury(),bg-pay,"refund undelivered units")
    eq(pay+(buyer.iface:treasury()-(bg-cart.escrow)),cart.escrow,"pay and refund account for the whole escrow")
    F.arrive(buyer.iface,cart); F.drop(cart)
    F.route_settle(cart,17)
    eq(seller.iface:treasury(),sg+pay,"settlement idempotent")
    local keep=c.held.grain; c.held.grain=1000; b.held.grain=0; TURN=TURN+1; F.routes_turn(buyer.iface)
    local full=F.ships()[1]
    eq(full.price_c<first.price_c,true,"a full origin store charges less than a half-full one")
    F.route_return(full); c.held.grain=keep
    c.absent={grain=true}
    local st,why=F.route_status(buyer.iface,contract)
    eq(st,nil,"a settlement with no pool cannot be bought from"); eq(why,"The seller cannot store it","and the panel is told why")
    local held=buyer.iface:treasury(); TURN=TURN+1; F.routes_turn(buyer.iface)
    eq(#F.ships(),0,"no cart leaves without a pool"); eq(buyer.iface:treasury(),held,"and the buyer pays nothing")
    c.absent=nil
    local space=c.cap; c.cap=0; TURN=TURN+1; F.routes_turn(buyer.iface)
    eq(#F.ships(),0,"a store of no capacity quotes no price, so no cart leaves")
    eq(buyer.iface:treasury(),held,"and nothing is charged"); eq(c.held.grain,keep,"and no goods move")
    c.cap=space
    local purse=buyer.iface:treasury(); TREASURY[buyer.name]=(TREASURY[buyer.name] or 0)-purse+10
    b.held.grain=0; TURN=TURN+1; F.routes_turn(buyer.iface)
    eq(#F.ships(),0,"a cart the buyer cannot afford does not leave"); eq(buyer.iface:treasury(),10,"and no gold moves")
    eq(c.held.grain,keep,"and no goods move"); TREASURY[buyer.name]=TREASURY[buyer.name]+purse-10
    -- a cart worth under one gold never leaves: the seller would lose its goods for nothing
    c.held.grain=1000; F.route_edit(buyer.iface,contract.id,"batch","2")
    local book=F.state.contracts; local ledger={book.paid,book.refunded,book.lost}
    local s0,b0=seller.iface:treasury(),buyer.iface:treasury()
    TURN=TURN+1; F.routes_turn(buyer.iface)
    eq(#F.ships(),0,"a cart worth under one gold does not leave"); eq(contract.status,"Waiting for goods or gold or road space","and the order says it waits")
    eq(buyer.iface:treasury(),b0,"the buyer pays nothing"); eq(c.held.grain,1000,"and no goods move")
    -- a cart saved before that rule, with no escrow, still goes home whole in a war and books nothing
    F.route_edit(buyer.iface,contract.id,"batch","100"); TURN=TURN+1; F.routes_turn(buyer.iface)
    local tiny=F.ships()[1]; TREASURY[buyer.name]=TREASURY[buyer.name]+tiny.escrow; tiny.escrow=0
    local stock=c.held.grain; war(buyer,seller); TURN=TURN+1; F.ships_turn(buyer.iface)
    eq(#F.ships(),0,"war returns the old cart"); eq(c.held.grain,stock+tiny.n,"and its net cargo reaches the seller")
    buyer.war={}; seller.war={}; buyer.partners={seller}; seller.partners={buyer}
    eq(seller.iface:treasury(),s0,"no gold reaches the seller"); eq(buyer.iface:treasury(),b0,"and none leaves the buyer")
    eq(F.state.contracts.paid,ledger[1],"nothing is booked paid"); eq(F.state.contracts.refunded,ledger[2],"or refunded")
    eq(F.state.contracts.lost,ledger[3],"or lost")
    F.route_edit(buyer.iface,contract.id,"batch","100"); c.held.grain=keep
    b.held.grain=0; TURN=TURN+1; F.routes_turn(buyer.iface); cart=F.ships()[1]
    local charged=buyer.iface:treasury(); local source=c.held.grain
    war(buyer,seller); TURN=TURN+1; F.ships_turn(buyer.iface)
    eq(#F.ships(),0,"war returns cargo")
    eq(c.held.grain,source+cart.n,"return net cargo to seller")
    eq(buyer.iface:treasury(),charged+cart.escrow,"war refunds escrow")
    F.routes_turn(buyer.iface); eq(#F.ships(),0,"war stops future dispatch")
    buyer.war={}; seller.war={}; buyer.partners={seller}; seller.partners={buyer}
    TURN=TURN+1; F.routes_turn(buyer.iface); cart=F.ships()[1]
    seller.dead=true; F.sweep()
    eq(#F.ships(),0,"dead seller settles cargo")
    eq(buyer.iface:treasury(),bg-pay,"dead seller refunds live buyer")
    seller.dead=false
    -- a save from before local prices: one whole gold per unit, no price_c
    b.held.grain=0; TURN=TURN+1; s0,b0=seller.iface:treasury(),buyer.iface:treasury()
    F.routes_turn(buyer.iface); local aged=F.ships()[1]
    aged.price_c,aged.price=nil,1
    SAVED={}; cm.saving_game_callbacks[1]({}); F.state={}; cm.loading_game_callbacks[1]({})
    whole(F.state,"contracts")
    contract=F.routes(buyer.iface)[1]; aged=F.ships()[1]
    eq(aged.price_c,100,"a saved cart gains its price in hundredths"); eq(aged.price,nil,"and loses the whole-gold field")
    b.held.grain=983; TURN=aged.due; F.arrive(buyer.iface,aged)
    eq(seller.iface:treasury(),s0+17,"a migrated cart pays whole gold for what arrived")
    eq(buyer.iface:treasury(),b0-17,"and refunds the rest"); b.held.grain=0
    local ships=F.state.ships; F.state.ships={{id="odd",f=buyer.name,sender=seller.name,recipient=buyer.name,escrow=5}}
    F.sanitize_ships(); eq(F.state.ships[1].price_c,0,"a cart with escrow and no price at all pays nothing and refunds it all")
    F.state.ships=ships
    local ex=EX; EX={sell_price=function() return 9999 end,lot=function() return 1 end,with_player=function(_,fn) fn();return true end}
    TREASURY[buyer.name]=(TREASURY[buyer.name] or 0)+100000000
    local before=buyer.iface:treasury()
    b.held.grain=0; TURN=TURN+1
    F.set_stock_policy(buyer.name,"grain","target","70")
    local follow=F.buy_price(F.local_price(F.stock_view(seller.iface,c.iface),"grain",seller.name))
    F.routes_turn(buyer.iface); cart=F.ships()[1]
    eq(cart.price_c,follow,"the origin's price follows the Exchange base")
    eq(cart.price_c>first.price_c*1000,true,"the Exchange base replaces the fixed rate")
    -- (the old "free trade cannot duplicate committed deficit" stood here and could not fail: this buyer's capital `a` holds
    -- grain well over its target of 70, so F.trade never sent. The measuring case is "A CONTRACT CART ON THE ROAD IS COMMITTED
    -- TOO" in the agreement convoys section.)
    F.route_control(buyer.iface,contract.id,"toggle")
    eq(contract.enabled,false,"pause order")
    F.route_control(buyer.iface,contract.id,"cancel")
    eq(buyer.iface:treasury(),before,"cancel refunds full travelling escrow")
    eq(#F.ships(),0,"cancel returns travelling partner cargo")
    F.route_control(buyer.iface,contract.id,"cancel")
    eq(buyer.iface:treasury(),before,"duplicate cancel cannot refund twice")
    EX=ex
    contract=F.route_create(buyer.iface,c.key,b.key,"grain",70,100)
    TURN=TURN+1; F.routes_turn(buyer.iface); cart=F.ships()[1]
    local captor=faction("route_raider"); local raid=region("route_raid",0,0,1000,{})
    own(captor,raid,true); before=buyer.iface:treasury()
    F.seize(cart,captor.iface); eq(raid.held.grain,70,"seizure transfers actual net cargo")
    eq(buyer.iface:treasury(),before+cart.escrow,"seizure refunds unpaid escrow")
    F.seize(cart,captor.iface); eq(raid.held.grain,70,"duplicate seizure cannot mint cargo")
    TURN=TURN+1; F.routes_turn(buyer.iface); cart=F.ships()[1]
    before=buyer.iface:treasury(); source=c.held.grain
    lose(buyer,b); own(captor,b); TURN=TURN+1; F.ships_turn(buyer.iface)
    eq(c.held.grain,source+cart.n,"captured destination returns net cargo")
    eq(buyer.iface:treasury(),before+cart.escrow,"captured destination refunds buyer")
    lose(captor,b); own(buyer,b)
    local transaction=cm.entity_add_pooled_resource_transaction
    local goldwrite=cm.treasury_mod
    before=buyer.iface:treasury(); source=c.held.grain
    cm.entity_add_pooled_resource_transaction=function() end
    TURN=TURN+1; F.routes_turn(buyer.iface)
    eq(#F.ships(),0,"failed native goods debit publishes no cargo")
    eq(buyer.iface:treasury(),before,"failed goods debit restores escrow")
    cm.entity_add_pooled_resource_transaction=transaction
    cm.treasury_mod=function() end
    TURN=TURN+1; F.routes_turn(buyer.iface)
    eq(#F.ships(),0,"failed native gold debit publishes no cargo")
    eq(c.held.grain,source,"failed gold debit takes no goods")
    cm.treasury_mod=goldwrite
    F.book(seller.name).stop={export={grain=true}}
    TURN=TURN+1; F.routes_turn(buyer.iface); eq(#F.ships(),0,"seller export hold blocks contract")
    F.book(seller.name).stop={}; F.book(buyer.name).stop={import={grain=true}}
    TURN=TURN+1; F.routes_turn(buyer.iface); eq(#F.ships(),0,"buyer import hold blocks contract")
    F.book(buyer.name).stop={}
    eq(F.route_create(buyer.iface,c.key,b.key,"grain",70,100),nil,"duplicate order refused")
    eq(F.route_create(buyer.iface,c.key,b.key,"iron",70,101),nil,"oversized batch refused")
    eq(F.route_edit(buyer.iface,contract.id,"price","1"),false,"price cannot be edited")
    eq(F.route_edit(buyer.iface,contract.id,"target","nan"),false,"malformed target refused")
    eq(F.route_edit(buyer.iface,contract.id,"batch","1"),false,"non-deliverable batch refused")
    local count=#F.routes(buyer.iface)
    F.dispatch(buyer.name,{"route_new",a.key,b.key,"iron","100"})
    eq(#F.routes(buyer.iface),count,"wrong arity refuses route")
    F.state.rates.actions=false
    F.dispatch(buyer.name,{"route_new",a.key,b.key,"iron","100","100"})
    eq(#F.routes(buyer.iface),count,"actions switch blocks creation")
    F.state.rates.actions=true
    F.request(buyer.name,"route_new",a.key,b.key,"iron","100","100")
    eq(#F.routes(buyer.iface),count+1,"synchronized door creates order")
    local internal=F.routes(buyer.iface)[count+1]
    eq(F.route_covers(buyer.iface,b.key,"war"),true,"named order replaces standing category")
    F.route_control(buyer.iface,internal.id,"toggle")
    eq(F.route_covers(buyer.iface,b.key,"war"),true,"paused order still replaces standing category")
    F.state.rates.upkeep=false   -- with upkeep on, a Garrison stocked floor would keep the iron home and hide the guard under test
    a.held.iron=100; b.held.iron=0
    local p={capital=b.iface,regions={a.iface,b.iface}}
    local carts=#F.ships()
    F.standing(buyer.iface,p,{arms=true},4)
    eq(#F.ships(),carts,"standing dispatcher does not compete with paused named route")
    MP=true; SENT={}
    F.request(buyer.name,"route_edit",internal.id,"target","120")
    eq(internal.target,100,"MP click never directly mutates order")
    eq(SENT[1][2],"dmr1|route_edit|"..internal.id.."|target|120","MP terms use existing request channel")
    MP=false
    TURN=TURN+1; F.routes_turn(buyer.iface); cart=F.ships()[1]
    buyer.dead=true; before=F.state.contracts.lost
    F.sweep()
    eq(F.state.contracts.lost,before+cart.escrow,"dead buyer refund is recorded lost")
    eq(#F.ships(),0,"dead buyer cargo retired")
    buyer.dead=false
    F.book(buyer.name).routes.bad={id="bad",target=-2}
    F.sanitize_routes(); eq(F.book(buyer.name).routes.bad,nil,"malformed saved order removed")
    local function add_saved_order(id,extra)
        local o={id=id,from=c.key,to=b.key,stem="grain",seller=seller.name,target=70,batch=100,enabled=true}
        for k,v in pairs(extra) do o[k]=v end
        F.book(buyer.name).routes[id]=o
    end
    add_saved_order("9001",{price=3,last_price_c=82}); add_saved_order("9002",{last_price_c=-1}); add_saved_order("9003",{last_price_c=0.5})
    F.sanitize_routes()
    local kept=F.book(buyer.name).routes
    eq(kept["9001"]~=nil,true,"an old contract that still carries its locked price loads")
    eq(kept["9001"].price,nil,"its locked price is dropped"); eq(kept["9001"].last_price_c,82,"and a whole last price is kept")
    eq(kept["9002"].last_price_c,nil,"a negative last price is dropped"); eq(kept["9003"].last_price_c,nil,"and so is a fractional one")
    F.state,TURN=saved,turn
end)()

-- A PARTNER CART NEVER COSTS LESS THAN ITS GOODS SELL FOR WHERE THEY LAND: buying from a full partner and selling
-- the surplus at the buyer's own store would otherwise make gold. No Exchange; luxuries are 5 gold at their base.
;(function()
    eq(type(F.state),"table","the contract block put the state table back")
    local saved, turn, ex = F.state, TURN, EX
    EX = nil
    F.state = { factions = {}, rates = F.read_rates(), ship_seq = 95000 }
    F.state.rates.upkeep, F.state.rates.supply, F.state.rates.army_provisions, F.state.rates.escort = false, false, false, false
    TURN = 200000
    local buyer = faction("floor_buyer", { human = true, gold = 10000 })
    local seller = faction("floor_seller", { gold = 10000 })
    local src = region("floor_src", 0, 0, 200, { silk = 200 })
    local dst = region("floor_dst", 80, 0, 200, { silk = 110 })
    own(seller, src, true); own(buyer, dst, true)
    buyer.partners, seller.partners = { seller }, { buyer }
    local function price(f, r) return F.local_price(F.stock_view(f.iface, r.iface), "silk", f.name) end
    eq(DERPY_MR_FLOWS_SELL_RATE.luxuries, 5, "a luxury is 5 gold at its base")
    eq(price(seller, src), 125, "the partner's full store: 25% of 5 gold"); eq(F.buy_price(125), 137, "137 to buy")
    eq(price(buyer, dst), 460, "the buyer's store at 110 of 200: 92% of 5 gold"); eq(F.sell_price(460), 418, "it sells for 4.18")
    local quoted = F.cart_price(seller.iface, src.iface, buyer.iface, dst.iface, "silk")
    eq(quoted, 418, "the cart floor is what the goods sell for where they land")
    local contract = F.route_create(buyer.iface, src.key, dst.key, "silk", 200, 100)
    TURN = TURN + 1; F.routes_turn(buyer.iface); local cart = F.ships()[1]
    eq(cart.price_c, 418, "the cart costs 4.18, not the partner's 1.37"); eq(cart.price_c, quoted, "as the price the panel reads says")
    eq(contract.last_price_c, 418, "shown as the last price paid")
    eq(cart.escrow, F.gold(cart.n, 418), "and the escrow is at that price")
    TURN = cart.due; F.arrive(buyer.iface, cart)
    eq(dst.held.silk > 110, true, "the cargo arrives")
    -- the floor never lowers a price: a dear partner store still charges its own buy price
    src.held.silk = 0; dst.held.silk = 200
    eq(F.cart_price(seller.iface, src.iface, buyer.iface, dst.iface, "silk"), F.buy_price(price(seller, src)), "a dear source is its own buy price")
    -- the landing price is the buyer's own: under an Exchange that prices the seller's silk at 1 gold, it would read 0.83
    EX = { lot = function() return 1 end, subject = nil,
           with_player = function(f, fn) EX.subject = f; local ok = pcall(fn); EX.subject = nil; return ok end,
           sell_price = function() return EX.subject == "floor_seller" and 1 or 5 end }
    src.held.silk, dst.held.silk = 200, 110
    eq(F.cart_price(seller.iface, src.iface, buyer.iface, dst.iface, "silk"), 418, "the floor reads the buyer's price at its own store")
    F.state, TURN, EX = saved, turn, ex
end)()

-- Display previews use the allocator without committing its transactions.
;(function()
    local state, reach, ships_to = F.state, F.trade_reach, F.ships_to
    F.state = {factions={}, rates={trade=5,ai=true}}
    local seller, buyer, later = faction("visual_seller",{human=true}), faction("visual_buyer"), faction("visual_later")
    local a, b, c = region("visual_a",0,0,400,{grain=300}), region("visual_b",1,0,200,{grain=0}), region("visual_c",2,0,200,{grain=0})
    own(seller,a,true); own(buyer,b,true); own(later,c,true)
    seller.partners={buyer}
    F.trade_reach=function(_,_,mode) eq(mode,"peek","preview never solves extra roads"); return true end
    F.set_stock_policy(seller.name,"grain","keep","0")
    F.set_stock_policy(buyer.name,"grain","target","100")
    F.set_stock_policy(later.name,"grain","target","100")
    local transactions=#LOG
    local function advertises()
        local goods=F.trade(seller.iface,true)
        eq(#LOG,transactions,"preview must not transact")
        for _,stem in ipairs(goods[buyer.name] or {}) do if stem=="grain" then return true end end
        return false
    end
    eq(advertises(),true,"positive flow advertised")
    eq(a.held.grain,300,"preview keeps sender stock"); eq(b.held.grain,0,"preview keeps receiver stock")
    b.held.grain=200; eq(advertises(),false,"full recipient has no cargo")
    b.held.grain=100; eq(advertises(),false,"target met has no cargo")
    b.held.grain=0; a.held.grain=1; eq(advertises(),false,"rounded zero has no cargo")
    a.held.grain=300; F.state.rates.trade=0; eq(advertises(),false,"zero rate has no cargo")
    F.state.rates.trade=5
    F.set_stock_policy(seller.name,"grain","keep","300"); eq(advertises(),false,"Keep protects cargo")
    F.set_stock_policy(seller.name,"grain","keep","0")
    F.toggle(seller.name,"export","grain"); eq(advertises(),false,"stopped export has no cargo")
    F.toggle(seller.name,"export","grain")
    F.ships_to=function(f,r) if f==buyer.name and r==b.key then return {{stem="grain",n=100,due=TURN+2}} end return {} end
    eq(advertises(),false,"incoming cargo already covers target")
    F.ships_to=ships_to
    a.held.grain=20; seller.partners={later,buyer}
    local goods=F.trade(seller.iface,true)
    eq(goods[buyer.name][1],"grain","first alphabetical partner gets one unit")
    eq((goods[later.name] or {})[1],"grain","later partner gets at least 1 of the 19 left")
    eq(a.held.grain,20,"ordered preview never debits the real sender")
    F.trade_reach=function() return true end
    F.trade(seller.iface)
    eq(a.held.grain,18,"actual allocation agrees with preview debit")
    eq(cargo_to(buyer.name,"grain"),1,"actual first partner agrees with preview")
    eq(cargo_to(later.name,"grain"),1,"actual later partner agrees with preview")
    eq(b.held.grain,0,"and nothing has landed")
    F.state,F.trade_reach,F.ships_to=state,reach,ships_to
end)()

-- SPOILAGE (design 2026-11-01, Part A): the generated tables the rule reads.
eq(DERPY_MR_FLOWS_KIND.spoil, "spoiled", "spoilage books on its own factor")
eq(DERPY_MR_FLOWS_DEFAULTS.spoilage, true, "spoilage is on by default")
do
    local sp = DERPY_MR_FLOWS_SPOIL
    eq(sp.rates.grain .. "," .. sp.rates.beer .. "," .. sp.rates.kvas, "4,2,2", "the three goods that spoil")
    eq(sp.safe .. "," .. sp.granary .. "," .. sp.granary_good, "25,50,grain", "the safe shares")
    local lasting = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do
        if w.kind == "lasting" then lasting[w.key] = true end
    end
    eq(#sp.granary_works, 2, "two Great Granaries: the Chaos Dwarfs' and everyone else's")
    for _, k in ipairs(sp.granary_works) do
        eq(lasting[k], true, k .. " is a lasting work under the key spoilage reads")
    end
end

-- SPOILAGE: the loss, who it applies to, and where it runs in the turn start.
;(function()
    local state = F.state
    F.state = { factions = {}, rates = F.read_rates() }
    F.spoils = SPOILS
    eq(F.spoil_loss(400, 1000, 4, 25), 6, "4% of the 150 above a quarter")
    eq(F.spoil_loss(274, 1000, 4, 25), 0, "24 above loses nothing: it rounds down")
    eq(F.spoil_loss(275, 1000, 4, 25), 1, "25 above loses one")
    eq(F.spoil_loss(250, 1000, 4, 25), 0, "exactly at the safe share loses nothing")
    eq(F.spoil_loss(nil, nil, 4, 25), 0, "no reading loses nothing")
    local function spoiled(r, stem)
        local n = 0
        for _, e in ipairs(LOG) do
            if e[1] == r.key and e[2] == "derpy_mr_store_" .. stem .. "_spoiled" then n = n + e[3] end
        end
        return n
    end
    local p = faction("spoil_player", { human = true })
    local r = region("spoil_a", 0, 0, 1000, { grain = 400, beer = 300, salt = 900 })
    own(p, r, true)
    F.spoil(p.iface)
    eq(r.held.grain .. "," .. r.held.beer .. "," .. r.held.salt, "394,299,900", "grain and beer spoil, salt keeps")
    eq(spoiled(r, "grain") .. "," .. spoiled(r, "beer"), "-6,-1", "booked on the spoiled factor")
    eq(F.book(p.name).now.grain.spoiled_out, 6, "and in the ledger")
    local walks, reads = r.pool_walks or 0, r.pool_reads or 0
    F.spoil(p.iface)
    eq((r.pool_walks or 0) - walks, 0, "a computer round's cost: no store is read whole")
    eq((r.pool_reads or 0) - reads <= 6, true, "at most two reads a good that spoils: its own and the move's")
    F.works_book(p.name).lasting = { [F.SPOIL.granary_works[1]] = 1 }
    r.held.grain, r.held.beer = 400, 300
    F.spoil(p.iface)
    eq(r.held.grain .. "," .. r.held.beer, "400,299", "the Great Granary keeps grain to half, not beer")
    F.spoil_safe("nobody", "grain")
    eq(F.state.factions.nobody, nil, "asking about the Granary writes nothing")
    F.state.rates.spoilage = false
    r.held.beer = 300; F.spoil(p.iface)
    eq(r.held.beer, 300, "the switch off spoils nothing")
    F.state.rates.spoilage = true
    local c = faction("spoil_computer")
    local rc = region("spoil_c", 3, 0, 1000, { grain = 400 })
    own(c, rc, true)
    F.state.rates.ai = false; F.spoil(c.iface)
    eq(rc.held.grain, 400, "a computer's stores keep with other factions' stores off")
    F.state.rates.ai = true; F.spoil(c.iface)
    eq(rc.held.grain, 394, "and spoil with them on")
    local d = faction("spoil_daemons", { sc = "wh3_main_sc_dae_daemons" })
    local rd = region("spoil_d", 5, 0, 1000, { grain = 400 })
    own(d, rd, true); F.spoil(d.iface)
    eq(rd.held.grain, 400, "a race with no stores loses nothing")
    local v = faction("spoil_vampires", { sc = "wh_main_sc_vmp_vampire_counts" })
    local rv = region("spoil_v", 7, 0, 1000, { grain = 400 })
    own(v, rv, true); F.spoil(v.iface)
    eq(rv.held.grain, 394, "the undead eat nothing, but their grain still rots")
    rv.absent = { grain = true }; rv.held.grain = 400
    F.spoil(v.iface)
    eq(rv.held.grain, 400, "a store with no grain pool loses no grain")
    rv.absent = nil
    local old = F.read_rates(); old.spoilage = nil
    F.state.rates = old
    eq(F.rates().spoilage, true, "an old save takes spoilage on")
    F.state.rates = F.read_rates()
    local order, saved = {}, {}
    for _, k in ipairs({ "upkeep", "provisions_turn", "spoil", "economy_turn" }) do
        saved[k] = F[k]
        F[k] = function() order[#order + 1] = k end
    end
    turn_start(c)
    for k, fn in pairs(saved) do F[k] = fn end
    eq(table.concat(order, ","), "upkeep,provisions_turn,spoil,economy_turn", "it spoils after eating, before processing")
    ERRORS = {}
    F.state = state
end)()

-- SPOILAGE ON SCREEN: next turn's loss, the forecast and the tooltip's figures.
;(function()
    local state = F.state
    F.state = { factions = {}, rates = F.read_rates() }
    local p = faction("spoil_viewer", { human = true })
    local r = region("spoil_view", 0, 0, 1000, { grain = 400, beer = 300, salt = 900 })
    own(p, r, true)
    local v = F.stock_view(p.iface, r.iface)
    eq(F.spoil_due(v, "grain") .. "," .. F.spoil_due(v, "salt"), "6,0", "next turn's loss, and none for salt")
    local fc = F.stock_forecast(v).provisions
    eq(fc.spoil, 7, "the forecast counts what will spoil")
    eq(fc.use_per_turn > 0, true, "the settlement eats")
    eq(fc.cover, math.floor(fc.held / fc.use_per_turn), "its cover is the use alone: spoiling stops at the safe share")
    local made = F.stock_forecast(v, { provisions = fc.use_per_turn + 1 }).provisions
    eq(made.mode .. "," .. made.net, "stable," .. (1 - fc.spoil), "made past its use is stable, and the net counts what spoils")
    eq(F.stock_forecast(v, { provisions = 0 }).provisions.cover, fc.cover, "a declining store's cover is the use alone too")
    local info = F.spoil_info(p.iface, r.iface, "grain")
    eq(info.rate .. "," .. info.keep .. "," .. info.due, "4,250,6", "the tooltip's figures")
    eq(F.spoil_info(p.iface, r.iface, "salt"), nil, "salt keeps")
    local tip = DERPY_MR_STORES.forecast_tip(p.iface, r.iface, nil, "provisions", "grain")
    eq(string.find(tip, "\nIt loses 7 to spoiling each turn.\nThat is enough for ", 1, true) ~= nil, true, "the forecast line says so: " .. tip)
    eq(string.find(DERPY_MR_STORES.forecast_tip(p.iface, r.iface, nil, "building"), "spoiling", 1, true), nil,
       "a use with nothing spoiling does not")
    F.state.rates.spoilage = false
    eq(F.spoil_due(v, "grain"), 0, "the switch off: nothing due")
    eq(F.spoil_info(p.iface, r.iface, "grain"), nil, "and nothing to say")
    eq(F.stock_forecast(v).provisions.spoil, 0, "nor forecast")
    ERRORS = {}
    F.state = state
end)()

-- FACTION-SPECIFIC BUFFS (author 2026-11-01): where a work, a stores bonus or an event would do
-- nothing for a race, the race gets its own - Chaos Dwarfs have no growth.
;(function()
    local state = F.state
    F.state = { factions = {}, rates = F.read_rates() }
    local W = {}
    for _, w in ipairs(DERPY_MR_FLOWS_WORKS) do W[w.key] = w end
    local chd = faction("race_chd", { human = true, sc = "wh3_dlc23_sc_chd_chaos_dwarfs" })
    local emp = faction("race_emp", { human = true })
    eq(F.work_open(emp.iface, W.last_granary), true, "the Great Granary is the Empire's")
    eq(F.work_open(chd.iface, W.last_granary), false, "but not the Chaos Dwarfs': growth does nothing for them")
    eq(F.work_open(chd.iface, W.last_granary_chd), true, "theirs feeds the captives")
    eq(F.work_open(emp.iface, W.last_granary_chd), false, "and is theirs alone")
    F.works_book(chd.name).lasting = { last_granary_chd = 1 }
    eq(F.spoil_safe(chd.name, "grain"), F.SPOIL.granary, "and keeps grain to half, like the other")
    -- Well fed: the race's own bundle, never both
    local rc = region("race_rc", 0, 0, 1000, { grain = 200 }); rc.level = 1; own(chd, rc, true)
    local CW = "derpy_mr_well_fed_chd"
    BUNDLES.race_rc = { [WF] = 2 }
    F.bundle("race_rc", rc.iface, "provisions", true)
    eq(BUNDLES.race_rc[CW], 0, "Chaos Dwarfs get their own Well fed, kept on")
    eq(BUNDLES.race_rc[WF], nil, "and a former owner's goes")
    F.bundle("race_rc", rc.iface, "provisions", false)
    eq(next(BUNDLES.race_rc), nil, "unfed, neither")
    local re = region("race_re", 3, 0, 1000, { grain = 200 }); re.level = 1; own(emp, re, true)
    BUNDLES.race_re = { [CW] = 2 }
    F.bundle("race_re", re.iface, "provisions", true)
    eq(BUNDLES.race_re[WF], 0, "everyone else keeps the usual Well fed")
    eq(BUNDLES.race_re[CW], nil, "and a Chaos Dwarf former owner's goes")
    -- the Feast: the race's own, in its own words
    eq(F.event_offer(chd.iface, "feast", F.stocks(chd.iface)), nil, "no Feast for Chaos Dwarfs")
    local o = F.event_offer(chd.iface, "feast_chd", F.stocks(chd.iface))
    eq(o and o.region, "race_rc", "Full Rations in its place")
    eq(F.event_pick(chd.iface, F.event_book(chd.name)).key, "feast_chd", "and in the turn's order")
    eq(F.event_offer(emp.iface, "feast_chd", F.stocks(emp.iface)), nil, "theirs alone")
    eq(F.event_offer(emp.iface, "feast", F.stocks(emp.iface)) ~= nil, true, "everyone else keeps the Feast")
    eq(#ERRORS, 0, "no script errors")
    F.state = state
end)()

-- TRADE EDICTS (design 2026-11-01, Part B): the generated table the rules read.
eq(DERPY_MR_FLOWS_DEFAULTS.edicts, true, "edicts are on by default")
do
    local E = DERPY_MR_FLOWS_EDICTS
    eq(table.concat(E.order, ","), "rations,workshops,roads", "three edicts, in order")
    eq(E.rations.default .. "," .. E.workshops.default .. "," .. E.roads.default, "normal,balanced,tolled", "the defaults")
    eq(E.cooldown, 10, "ten turns between changes")
    eq(E.need.plenty .. "," .. E.need.normal .. "," .. E.need.rationing, "3,2,1", "meals a level")
    eq(E.war_pct .. "," .. E.merchant_trade .. "," .. E.merchant_draw, "150,2,125", "the workshop numbers")
    eq(E.race_bundles.plenty.chd, "derpy_mr_edict_plenty_chd", "Chaos Dwarfs get their own Plenty")
    local outs = {}
    for k in pairs(E.war_outputs) do outs[k] = true end
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do outs[g.stem] = nil end
    eq(next(outs), nil, "every war output is a good")
end

-- TRADE EDICTS: the state, the bundles, the cooldown and the change action.
;(function()
    local state, turn0 = F.state, TURN
    F.state = { factions = {}, rates = F.read_rates() }
    eq(F.edict("e_p", "rations"), "normal", "no entry reads the default")
    eq(F.state.edicts, nil, "and reading writes nothing")
    local p = faction("e_p", { human = true })
    own(p, region("e_pa", 0, 0, 1000, {}), true)
    eq(F.edict_set(p.iface, "rations", "plenty"), true, "a change")
    eq(F.edict("e_p", "rations"), "plenty", "reads back")
    eq(FBUNDLES.e_p.derpy_mr_edict_plenty, 0, "its bundle, for good")
    eq(F.edict_wait("e_p", "rations"), 10, "and ten turns to wait")
    eq(F.edict_set(p.iface, "rations", "rationing"), false, "a second change waits")
    eq(F.edict("e_p", "rations"), "plenty", "and changed nothing")
    TURN = turn0 + 9
    eq(F.edict_set(p.iface, "rations", "rationing"), false, "still waiting a turn before")
    TURN = turn0 + 10
    eq(F.edict_wait("e_p", "rations"), 0, "ready after ten")
    eq(F.edict_set(p.iface, "rations", "rationing"), true, "and changes")
    eq(FBUNDLES.e_p.derpy_mr_edict_plenty, nil, "the old bundle goes")
    eq(FBUNDLES.e_p.derpy_mr_edict_rationing, 0, "the new one comes")
    eq(F.edict_set(p.iface, "rations", "rationing"), false, "the option already in force is no change")
    TURN = turn0 + 11
    eq(F.edict_set(p.iface, "rations", "normal", true), true, "force skips the wait")
    eq(next(FBUNDLES.e_p), nil, "the default has no bundle")
    local c = faction("e_chd", { human = true, sc = "wh3_dlc23_sc_chd_chaos_dwarfs" })
    own(c, region("e_ca", 3, 0, 1000, {}), true)
    F.edict_set(c.iface, "rations", "plenty")
    eq(FBUNDLES.e_chd.derpy_mr_edict_plenty_chd, 0, "Chaos Dwarfs get their own Plenty")
    eq(FBUNDLES.e_chd.derpy_mr_edict_plenty, nil, "and not the growth one")
    eq(F.edict_set(p.iface, "rations", "feast"), false, "an unknown option")
    eq(F.edict_set(p.iface, "feasts", "plenty"), false, "an unknown edict")
    local d = faction("e_dae", { human = true, sc = "wh3_main_sc_dae_daemons" })
    eq(F.edict_set(d.iface, "rations", "plenty"), false, "a race with no stores has no edicts")
    local calls, inv = 0, F.invalidate_reach
    F.invalidate_reach = function() calls = calls + 1 end
    F.edict_set(p.iface, "roads", "closed")
    eq(calls, 1, "closing the roads drops the kept reach answers")
    F.edict_set(p.iface, "workshops", "war")
    eq(calls, 1, "another edict does not")
    F.invalidate_reach = inv
    F.state.rates.edicts = false
    eq(F.edict("e_p", "roads"), "tolled", "the switch off reads the default")
    eq(F.edict_set(p.iface, "workshops", "merchant"), false, "and changes nothing")
    F.edict_bundles(p.iface)
    eq(next(FBUNDLES.e_p), nil, "and takes every edict bundle off")
    F.state.rates.edicts = true
    -- the action: through the trigger in multiplayer, gated on its own switch
    TURN = turn0 + 30
    MP = true
    ui_trigger(p.cqi, "dmr1|edict|workshops|merchant")
    eq(F.edict("e_p", "workshops"), "merchant", "the trigger sets it")
    F.state.rates.actions = false
    TURN = turn0 + 40
    ui_trigger(p.cqi, "dmr1|edict|workshops|balanced")
    eq(F.edict("e_p", "workshops"), "balanced", "Vault actions off still allow an edict")
    F.state.rates.edicts = false
    TURN = turn0 + 50
    ui_trigger(p.cqi, "dmr1|edict|workshops|war")
    F.state.rates.edicts = true
    eq(F.edict("e_p", "workshops"), "balanced", "edicts off: the trigger does nothing")
    MP = false
    F.state.rates.actions = true
    -- the load keeps only well-formed entries
    SAVED.derpy_mr_flows = { factions = {}, edicts = { e_p = { rations = { o = "feast", at = 1 },
        roads = { o = "open", at = "x" }, nope = { o = "open", at = 1 }, workshops = { o = "war", at = 3 } },
        e_x = "junk" } }
    cm.loading_game_callbacks[1]({})
    local kept = {}
    for k in pairs(F.state.edicts.e_p) do kept[#kept + 1] = k end
    eq(table.concat(kept, ","), "workshops", "the load keeps the sound entry alone")
    eq(F.state.edicts.e_x, nil, "and drops a faction's junk")
    -- a save from before edicts: the switch fills in on, every edict at its default
    local old = F.read_rates(); old.edicts = nil
    F.state = { factions = {}, rates = old }
    eq(F.rates().edicts, true, "an older save takes edicts on")
    eq(F.edict("e_p", "rations") .. F.edict("e_p", "workshops") .. F.edict("e_p", "roads"), "normalbalancedtolled",
       "and every edict at its default")
    FBUNDLES.e_p, FBUNDLES.e_chd = nil, nil
    eq(#ERRORS, 0, "no script errors")
    F.state, TURN = state, turn0
end)()

-- TRADE EDICTS IN THE RULES: meals, workshop output, trade share and the recruitment draw.
;(function()
    local state, turn0 = F.state, TURN
    F.state = { factions = {}, rates = F.read_rates() }
    F.spoils = function() return false end
    local p = faction("er_p", { human = true })
    local r = region("er_pa", 0, 0, 1000, { grain = 100 }); r.level = 2
    own(p, r, true)
    local function set(which, option) TURN = TURN + 20; eq(F.edict_set(p.iface, which, option), true, "set " .. option) end
    set("rations", "plenty")
    F.upkeep(p.iface)
    eq(r.held.grain, 94, "Plenty eats 3 a level")
    eq(F.recurring_use(p.iface, r.iface).provisions, 6, "and the forecast knows it")
    set("rations", "rationing")
    r.held.grain = 100; F.upkeep(p.iface)
    eq(r.held.grain, 98, "Rationing eats 1 a level")
    -- WELL FED IS FIVE TURNS OF NORMAL MEALS whatever the edict (final review, 2026-11-02): measured on the edict's
    -- own meals, Rationing reached it on half the food, and the Chaos Dwarfs' +3 control outweighed Rationing's -2
    r.held.grain = 17; F.upkeep(p.iface)
    eq(r.held.grain .. "," .. tostring(has(r, WF)), "15,false", "Rationing: 15 left is under five turns of 4")
    set("rations", "plenty")
    r.held.grain = 30; F.upkeep(p.iface)
    eq(r.held.grain .. "," .. tostring(has(r, WF)), "24,true", "Plenty: 24 left is five turns of 4 and more")
    set("rations", "rationing")
    F.state.rates.edicts = false
    r.held.grain = 100; F.upkeep(p.iface)
    eq(r.held.grain, 96, "the switch off eats the usual 2")
    F.state.rates.edicts = true
    -- War economy: half as much again of a war output, rounded down
    local tools, cloth
    for key, d in pairs(DERPY_MR_FLOWS_ECONOMY) do
        if d.kind == "processing" and d.output and d.output[1] == "tools" then tools = d end
        if d.kind == "processing" and d.output and d.output[1] == "cloth" then cloth = d end
    end
    eq(tools ~= nil and cloth ~= nil, true, "a tools recipe and a cloth recipe")
    eq(F.output_n(p.iface, tools), tools.output[2], "Balanced makes the usual tools")
    set("workshops", "war")
    eq(F.output_n(p.iface, tools), math.floor(tools.output[2] * 3 / 2), "War economy makes half as much again")
    eq(F.output_n(p.iface, cloth), cloth.output[2], "but not of cloth")
    eq(F.output_n(p.iface, { cost = {} }), 0, "a service makes nothing")
    for stem, n in pairs(tools.cost) do r.held[stem] = n * 3 end
    r.held.tools = 0
    eq(F.economy_pay(p.iface, r.iface, tools), true, "a batch")
    eq(r.held.tools, math.floor(tools.output[2] * 3 / 2), "lands the larger amount")
    for stem in pairs(tools.cost) do r.held[stem] = 500 end
    r.held.tools = r.cap - tools.output[2]
    eq(select(2, F.economy_admit(p.iface, r.iface, tools)), "Output store full", "and needs room for it")
    local cells = DERPY_MR_STORES.economy_cells({ definition = tools, made = F.output_n(p.iface, tools) })
    eq(string.find(cells.gives, tostring(math.floor(tools.output[2] * 3 / 2)), 1, true) == 1, true,
       "the Production tab shows what it makes: " .. cells.gives)
    -- Merchant: twice the trade share
    local partner = faction("er_b", { human = true })
    own(partner, region("er_ba", 9, 0, 1000, {}), true)
    p.partners = { partner }
    local reach, share, seen = F.trade_reach, F.share, 0
    F.trade_reach = function() return true end
    F.share = function(h, pct) seen = math.max(seen, pct); return share(h, pct) end
    F.trade(p.iface, true)
    eq(seen, F.rates().trade, "War economy trades the usual share")
    set("workshops", "merchant")
    seen = 0; F.trade(p.iface, true)
    eq(seen, 2 * F.rates().trade, "Merchant sends twice the share")
    F.trade_reach, F.share = reach, share
    p.partners = {}
    -- Merchant: the recruitment draw a quarter more
    local function total(bill) local n = 0; for _, b in ipairs(bill) do n = n + b.n end return n end
    local per = F.rates().recruit_per
    eq(total(F.recruit_bill(p.iface, "melee_infantry", 400)), math.ceil(400 / F.RECRUIT.per * per * 125 / 100),
       "Merchant recruits draw a quarter more")
    set("workshops", "balanced")
    eq(total(F.recruit_bill(p.iface, "melee_infantry", 400)), math.ceil(400 / F.RECRUIT.per * per), "the usual draw")
    eq(#ERRORS, 0, "no script errors")
    F.spoils = SPOILS
    F.state, TURN = state, turn0
end)()

-- TRADE EDICTS: computer factions choose by their situation (spec 5.4), within the cooldown.
;(function()
    local state, turn0, n0 = F.state, TURN, #ERRORS
    F.state = { factions = {}, rates = F.read_rates() }
    local a = faction("ea_c")
    local ra = region("ea_ca", 0, 0, 1000, { grain = 3 }); ra.level = 1
    own(a, ra, true)
    F.edict_ai(a.iface)
    eq(F.edict("ea_c", "rations"), "rationing", "under 2 turns of food: Rationing")
    TURN = TURN + 5; ra.held.grain = 40; F.edict_ai(a.iface)
    eq(F.edict("ea_c", "rations"), "rationing", "a rule inside the cooldown changes nothing")
    TURN = TURN + 5; F.edict_ai(a.iface)
    eq(F.edict("ea_c", "rations"), "plenty", "over 15 turns of food: Plenty")
    TURN = TURN + 10; ra.held.grain = 20; F.edict_ai(a.iface)
    eq(F.edict("ea_c", "rations"), "normal", "in between: Normal")
    eq(F.edict("ea_c", "workshops") .. "," .. F.edict("ea_c", "roads"), "balanced,tolled", "no partners, no wars")
    -- a neighbour at war: War economy
    local n1 = faction("ea_n1")
    local rn1, rn1b = region("ea_n1a", 3, 0, 1000, {}), region("ea_n1b", 3, 3, 1000, {})
    own(n1, rn1, true); own(n1, rn1b)
    ra.adj = { rn1, rn1b }
    war(a, n1)
    TURN = TURN + 10; F.edict_ai(a.iface)
    eq(F.edict("ea_c", "workshops"), "war", "at war with a neighbour: War economy")
    eq(F.edict("ea_c", "roads"), "tolled", "one neighbour at war, two of its regions next door, keeps the roads Tolled")
    -- two neighbours at war: Closed
    local n2 = faction("ea_n2")
    local rn2 = region("ea_n2a", 0, 3, 1000, {}); own(n2, rn2, true)
    ra.adj = { rn1, rn2 }
    war(a, n2)
    TURN = TURN + 10; F.edict_ai(a.iface)
    eq(F.edict("ea_c", "roads"), "closed", "two neighbours at war: Closed")
    -- peace, three partners: Merchant; a rebel neighbour at war is no war
    a.war, n1.war, n2.war = {}, {}, {}
    local reb = faction("ea_reb", { rebel = true })
    local rr = region("ea_rr", 6, 0, 1000, {}); own(reb, rr, true)
    ra.adj = { rr }
    war(a, reb)
    local p1, p2, p3 = faction("ea_p1"), faction("ea_p2"), faction("ea_p3")
    a.partners = { p1, p2 }
    TURN = TURN + 10; F.edict_ai(a.iface)
    eq(F.edict("ea_c", "workshops") .. "," .. F.edict("ea_c", "roads"), "balanced,tolled", "two partners: Balanced, roads open again")
    a.partners = { p1, p2, p3 }
    TURN = TURN + 10; F.edict_ai(a.iface)
    eq(F.edict("ea_c", "workshops"), "merchant", "three partners and only rebels at war: Merchant")
    -- a faction with no regions keeps the defaults and does not throw
    local bare = faction("ea_bare")
    F.edict_ai(bare.iface)
    eq(F.edict("ea_bare", "rations") .. F.edict("ea_bare", "workshops") .. F.edict("ea_bare", "roads"),
       "normalbalancedtolled", "no regions: every default")
    -- THE REBELS (live pass 2026-11-02, 442.5 s into turn 3): CA's factions_trading_with gives false for the rebel
    -- faction, and edict_ai threw at its turn start. A wars list that comes back false is guarded the same way.
    local rebels = faction("ea_rebels", { rebel = true })
    rebels.iface.factions_trading_with = function() return false end
    local okr, er = pcall(F.edict_ai, rebels.iface)
    eq(okr, true, "no trade list: the edicts throw nothing (" .. tostring(er) .. ")")
    eq(F.edict("ea_rebels", "workshops") .. F.edict("ea_rebels", "roads"), "balancedtolled", "no trade list: the defaults")
    local lone = faction("ea_lone")
    lone.partners = { p1, p2, p3 }
    lone.iface.factions_at_war_with = function() return false end
    local okl, el = pcall(F.edict_ai, lone.iface)
    eq(okl, true, "no wars list: the edicts throw nothing (" .. tostring(el) .. ")")
    eq(F.edict("ea_lone", "workshops"), "merchant", "no wars list is no war: three partners make it Merchant")
    -- the turn start: before the convoys, so this turn's meals eat this turn's rations
    local order, saved = {}, {}
    for _, k in ipairs({ "edict_turn", "convoys_turn", "upkeep" }) do
        saved[k] = F[k]
        F[k] = function() order[#order + 1] = k end
    end
    turn_start(a)
    for k, fn in pairs(saved) do F[k] = fn end
    eq(table.concat(order, ","), "edict_turn,convoys_turn,upkeep", "edicts come first in the turn start")
    -- a human's turn start puts on its bundles (an older save catches up); a computer's runs the rules
    local h = faction("ea_h", { human = true })
    own(h, region("ea_ha", 9, 9, 1000, {}), true)
    F.state.edicts.ea_h = { roads = { o = "open", at = 0 } }
    F.edict_turn(h.iface)
    eq(FBUNDLES.ea_h.derpy_mr_edict_open, 0, "a human's edicts get their bundles at the turn start")
    F.state.rates.ai = false
    TURN = TURN + 10; ra.held.grain = 3
    F.edict_turn(a.iface)
    eq(F.edict("ea_c", "rations"), "normal", "other factions' stores off: no computer rules")
    -- a faction that does not eat from the stores has no Rations to choose: Plenty would be free growth
    F.state.rates.ai = true
    local v = faction("ea_vmp", { sc = "wh_main_sc_vmp_vampire_counts" })
    own(v, region("ea_va", 12, 12, 1000, {}), true)
    F.edict_ai(v.iface)
    eq(F.edict("ea_vmp", "rations"), "normal", "a computer that does not eat keeps Normal")
    local vh = faction("ea_vmph", { sc = "wh_main_sc_vmp_vampire_counts", human = true })
    own(vh, region("ea_vha", 15, 15, 1000, {}), true)
    eq(F.edict_set(vh.iface, "rations", "plenty"), false, "nor can a player who does not eat")
    eq(F.edict_set(vh.iface, "workshops", "war"), true, "the other edicts still change")
    eq(#ERRORS, n0, "no script errors")
    FBUNDLES.ea_c, FBUNDLES.ea_h, FBUNDLES.ea_vmph = nil, nil, nil
    F.state, TURN = state, turn0
end)()

F.toll_takers = TOLL_TAKERS   -- the real rule from here on
-- TOLLS (design 2026-11-01, Part C 6.1): the road's regions, who charges and how much.
;(function()
    local state, turn0, n0 = F.state, TURN, #ERRORS
    F.state = { factions = {}, rates = F.read_rates() }
    local Y = 9700
    local A = faction("t_A", { human = true, gold = 59 })   -- the exporter
    local M1, M2, B = faction("t_M1"), faction("t_M2"), faction("t_B")
    own(A, region("t_a", 0, Y, 1000, {}), true)
    own(M1, region("t_m1", 10, Y, 1000, {}), true)
    own(M2, region("t_m2", 20, Y, 1000, {}), true)
    own(B, region("t_b", 30, Y, 1000, {}), true)
    local path = {}
    for x = 0, 30, 2 do path[#path + 1] = { x, Y } end
    eq(table.concat(F.road_regions(path), ","), "t_a,t_m1,t_m2,t_b", "the road's regions in road order, each once")
    local calls = GRLP_CALLS
    F.road_regions(path)
    eq(GRLP_CALLS, calls, "the same road again reads no region")
    eq(#F.road_regions(nil) + #F.road_regions({}), 0, "no road, no regions")
    F.state.rates.toll, F.state.rates.tolls = 3, true
    local function takers() return table.concat(F.toll_takers(A.iface, B.iface, path), ",") end
    eq(takers(), "t_M1,t_M2", "the owners between take tolls, in road order")
    local due, sum = F.tolls(1000, F.toll_takers(A.iface, B.iface, path))
    eq(due.t_M1 .. "," .. due.t_M2 .. "," .. sum, "30,30,60", "3% each of 1000")
    -- six takers: 15% in all, split six ways and rounded down (Review Focus 1)
    due, sum = F.tolls(1000, { "x1", "x2", "x3", "x4", "x5", "x6" })
    eq(due.x1 .. "," .. due.x6 .. "," .. sum, "25,25,150", "six takers share 15%")
    eq(F.toll_pct(6), 15, "never past 15%")
    due, sum = F.tolls(10, { "x1", "x2" })
    eq(next(due) == nil and sum == 0, true, "a toll under a gold is not charged")
    -- no toll from an ally, vassal or master of either side, a rebel, or Open roads (Review Focus 3)
    M1.allies = { t_A = true }; eq(takers(), "t_M2", "a vassal of the exporter charges nothing")
    M1.allies, A.allies = nil, { t_M1 = true }; eq(takers(), "t_M2", "nor does its master")
    A.allies, B.allies = nil, { t_M2 = true }; eq(takers(), "t_M1", "nor the buyer's ally")
    B.allies, M2.rebel = nil, true; eq(takers(), "t_M1", "nor rebels")
    M2.rebel = false
    F.state.edicts = { t_M1 = { roads = { o = "open", at = 0 } } }
    eq(takers(), "t_M2", "nor a faction whose roads are Open")
    F.state.edicts = { t_M1 = { roads = { o = "closed", at = 0 } } }
    eq(takers(), "t_M2", "nor a faction whose roads are Closed: it keeps foreign cargo out, it takes no tolls")
    F.state.edicts = nil
    F.state.rates.toll = 0; eq(takers(), "", "a toll of 0: no takers")
    F.state.rates.toll, F.state.rates.tolls = 3, false; eq(takers(), "", "the switch off: no takers")
    F.state.rates.tolls = true
    -- a taker whose land the road crosses twice is charged once (Review Focus 1); a new road table, not the kept one
    own(M1, region("t_m1b", 25, Y, 1000, {}))
    local path2 = {}
    for i, p in ipairs(path) do path2[i] = p end
    eq(table.concat(F.road_regions(path2), ","), "t_a,t_m1,t_m2,t_m1b,t_b", "the road crosses M1's land twice")
    eq(table.concat(F.toll_takers(A.iface, B.iface, path2), ","), "t_M1,t_M2", "and M1 is charged once")
    eq(F.toll_unit(1000, 2), math.floor(F.sell_price(1000) * 6 / 100), "the toll per unit, in hundredths")
    eq(F.toll_unit(1000, 0), 0, "no takers, no toll per unit")
    -- paying: refused below the sum with nothing moved; else each taker paid and the player's side booked
    due = { t_M1 = 30, t_M2 = 30 }
    eq(F.pay_tolls("t_A", due), false, "59 gold cannot pay 60")
    eq((TREASURY.t_A or 0) .. "," .. (TREASURY.t_M1 or 0), "0,0", "and nothing moved")
    TREASURY.t_A = 1
    eq(F.pay_tolls("t_A", due), true, "60 gold can")
    eq(TREASURY.t_A .. "," .. TREASURY.t_M1 .. "," .. TREASURY.t_M2, "-59,30,30", "the exporter pays 60 and each taker gets 30")
    eq(F.tolls_last("t_A"), nil, "this turn's tolls show next turn")
    TURN = TURN + 1
    local last = F.tolls_last("t_A")
    eq(last.paid .. "," .. last.by.t_M1.paid .. "," .. last.by.t_M2.paid, "60,30,30", "the player's book: paid 60, 30 to each")
    eq(F.tolls_last("t_M1"), nil, "a computer keeps no book")
    eq(F.pay_tolls("t_A", {}), true, "nothing due is paid at once")
    eq(#ERRORS, n0, "tolls: no script errors")
    TREASURY.t_A, TREASURY.t_M1, TREASURY.t_M2 = nil, nil, nil
    F.state, TURN = state, turn0
end)()

-- TOLLS IN THE TRADE (Part C 6.1): an agreement convoy and a partner cart pay the land their road crosses.
;(function()
    local state, turn0, routes, known, price, n0 = F.state, TURN, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.local_price, #ERRORS
    F.state = { factions = {}, rates = F.read_rates() }
    for _, k in ipairs({ "upkeep", "supply", "events", "army_provisions", "escort", "spoilage" }) do F.state.rates[k] = false end
    F.state.rates.toll, F.state.rates.tolls = 3, true
    F.reach_known, TURN, F.state.ship_seq = {}, 320000, 98000   -- cart ids no earlier block used
    local Y = 9800
    local E, M = faction("c2E", { gold = 0 }), faction("c2M")      -- a computer exporter, the land between
    local B, C, D = faction("c2B", { human = true }), faction("c2C", { human = true }), faction("c2D", { human = true })
    local er = region("c2E1", 0, Y, 2000, { coal = 1000 }); own(E, er, true)
    own(M, region("c2M1", 10, Y, 1000, {}), true)
    own(B, region("c2B1", 20, Y, 1000, {}), true)
    own(C, region("c2C1", 0, Y + 30, 1000, {}), true)
    own(D, region("c2D1", 10, Y - 20, 1000, {}), true)
    E.partners, B.partners, C.partners, D.partners = { B, C, D }, { E }, { E }, { E }
    for _, k in ipairs({ "c2B", "c2C", "c2D" }) do F.set_stock_policy(k, "coal", "target", "1000") end
    -- B's road crosses M's land, C's crosses nobody's, D's crosses M's too
    local ROADS = { ["c2B1>c2E1"] = {}, ["c2C1>c2E1"] = {}, ["c2D1>c2E1"] = {} }
    for x = 0, 20, 2 do table.insert(ROADS["c2B1>c2E1"], { x, Y }) end
    for y = Y, Y + 30, 6 do table.insert(ROADS["c2C1>c2E1"], { 0, y }) end
    for x = 0, 10, 2 do table.insert(ROADS["c2D1>c2E1"], { x, Y }) end
    for y = Y - 4, Y - 20, -4 do table.insert(ROADS["c2D1>c2E1"], { 10, y }) end
    local function key(a, b) return a:name() < b:name() and a:name() .. ">" .. b:name() or b:name() .. ">" .. a:name() end
    DERPY_MR_TERRAIN_ROUTES = { reach = function(a, b) return true, nil, ROADS[key(a, b)] end,
                                journey = function(a, b) return ROADS[key(a, b)] or ROADS["c2B1>c2E1"] end }
    local P = { c2E1 = 1000, c2B1 = 5000, c2C1 = 5000, c2D1 = 5000 }
    F.local_price = function(v) return P[v.region:name()] end
    local pct = F.rates().trade
    local share = F.share(F.available_stock(F.stock_view(E.iface, er.iface), "coal"), pct)
    local toll = math.floor(F.gold(share, F.sell_price(1000)) * 3 / 100)
    eq(toll > 0, true, "the fixture's cargo is worth a toll")
    local function sent_to(k)
        for _, c in ipairs(F.convoys()) do if c.buyer == k then return c end end
    end
    local function again(gold)
        F.state.convoys, er.held.coal = {}, 1000
        TREASURY.c2E, TREASURY.c2M = gold, nil
    end
    -- an exporter short of B's toll sends B nothing, and B's plan is put back: C gets its whole share
    E.partners = { B, C }
    again(toll - 1)
    F.trade(E.iface)
    eq(sent_to("c2B"), nil, "an exporter that cannot pay the toll sends nothing to that partner")
    eq(sent_to("c2C").basket.coal, share, "a partner over no one's land gets its whole share")
    eq(sent_to("c2C").tolls, nil, "and pays no toll")
    eq(TREASURY.c2E, toll - 1, "nothing was paid")
    -- exactly enough for one toll: B (first by key) pays and sends, C sends free, D sends nothing (Review Focus 2)
    E.partners = { B, C, D }
    again(toll)
    F.trade(E.iface)
    local cb = sent_to("c2B")
    eq(cb.basket.coal, share, "B's share leaves"); eq(cb.tolls.c2M, toll, "and its convoy records the toll it paid")
    -- saved tolls are checked on load: a convoy whose tolls are not whole gold by faction key is dropped
    eq(F.convoy_sound(cb) ~= nil, true, "a convoy with good tolls loads")
    local good = cb.tolls
    cb.tolls = { c2M = -1 }; eq(F.convoy_sound(cb), nil, "a negative toll does not load")
    cb.tolls = "c2M"; eq(F.convoy_sound(cb), nil, "tolls that are not a table do not load")
    cb.tolls = good
    eq(TREASURY.c2E .. "," .. TREASURY.c2M, "0," .. toll, "the exporter pays the toll to the land between")
    eq(sent_to("c2C") ~= nil, true, "C still trades")
    eq(sent_to("c2D"), nil, "D's toll finds the treasury empty: nothing sent")
    eq(E.iface:treasury() >= 0, true, "and the treasury never goes below 0")
    -- the preview names exactly what the trade sends, on the same fixture (Review Focus 5)
    again(toll)
    local plan = F.trade(E.iface, true)
    eq(#F.convoys(), 0, "a preview sends nothing")
    eq(TREASURY.c2E, toll, "and charges nothing")
    eq(table.concat(plan.c2B or {}, ",") .. "|" .. table.concat(plan.c2C or {}, ",") .. "|" .. tostring(plan.c2D),
       "coal|coal|nil", "the preview: B and C, not D")
    -- AND EARLIER PARTNERS' GUARDS: B's fee leaves D's toll unpaid in the trade, so the preview must not name D
    E.partners = { B, D }
    local bandits0, seen0 = F.state.rates.bandits, F.state.road_seen
    F.state.rates.bandits, F.state.road_seen = true, nil
    again(100000)
    F.trade(E.iface)
    local feeB = math.floor(F.cargo_value_base(sent_to("c2B")) * F.ROAD.guard_pct / 100)
    local tD = sent_to("c2D").tolls.c2M
    eq(feeB > 0 and tD > 0, true, "the fixture's cargo is worth a guards' fee and D's toll")
    F.state.road_seen = { c2E = TURN }   -- a computer with cargo on dangerous land last turn: guards on
    again(toll + feeB + tD - 1)
    F.trade(E.iface)
    eq(sent_to("c2B") ~= nil and sent_to("c2B").guarded, true, "B sends, guarded")
    eq(sent_to("c2D"), nil, "B's toll and guards leave D's toll unpaid")
    again(toll + feeB + tD - 1)
    plan = F.trade(E.iface, true)
    eq(table.concat(plan.c2B or {}, ",") .. "|" .. tostring(plan.c2D), "coal|nil", "the preview counts B's guards: not D")
    F.state.rates.bandits, F.state.road_seen, E.partners = bandits0, seen0, { B, C, D }
    -- uphill: the buyer's price must clear the seller's buy price plus the toll on a unit
    again(100000)
    P.c2B1 = F.buy_price(1000) + F.toll_unit(1000, 1) - 1
    F.trade(E.iface)
    eq(sent_to("c2B"), nil, "a price short of the buy price plus the toll sends nothing")
    again(100000)
    P.c2B1 = F.buy_price(1000) + F.toll_unit(1000, 1)
    F.trade(E.iface)
    eq(sent_to("c2B") ~= nil, true, "a price that clears it does")
    P.c2B1 = 5000
    -- the toll is on what left, not on the plan: the engine refuses the iron, the coal leaves and pays alone
    again(100000)
    er.held.iron = 1000; F.set_stock_policy("c2B", "iron", "target", "1000")
    local real = F.route_goods
    F.route_goods = function(r, stem, n, kind)
        if r:name() == "c2E1" and stem == "iron" then return false end
        return real(r, stem, n, kind)
    end
    F.trade(E.iface)
    F.route_goods = real
    cb = sent_to("c2B")
    eq(cb.basket.iron, nil, "the iron the engine refused did not leave")
    eq(cb.tolls.c2M, math.floor(F.cargo_value(cb.basket, { coal = 1000 }) * 3 / 100), "the toll is on the coal that left")
    er.held.iron = 0
    -- A PARTNER CONTRACT through M's land: the buyer pays the toll on top of the price, at the seller's price
    local Y2 = 9900
    local S, K = faction("c2S"), faction("c2K", { human = true, gold = 0 })
    own(S, region("c2S1", 0, Y2, 1000, { coal = 900 }), true)
    own(M, region("c2M2", 10, Y2, 1000, {}))
    local kr = region("c2K1", 20, Y2, 1000, {}); own(K, kr, true)
    local k2 = region("c2K2", 0, Y2 + 40, 1000, { coal = 300 }); own(K, k2)
    S.partners, K.partners = { K }, { S }
    ROADS["c2K1>c2S1"] = {}
    for x = 0, 20, 2 do table.insert(ROADS["c2K1>c2S1"], { x, Y2 }) end
    ROADS["c2K1>c2K2"] = ROADS["c2K1>c2S1"]                 -- an own cart over the same land
    P.c2S1, P.c2K1, P.c2K2 = 1000, 5000, 1000
    TREASURY.c2K, TREASURY.c2M = 100000, nil
    local o = F.route_create(K.iface, "c2S1", "c2K1", "coal", 70, 100)
    eq(o ~= nil, true, "a contract with the seller")
    TURN = TURN + 1; F.routes_turn(K.iface)
    local cart = F.ships()[1]
    local due = math.floor(F.gold(cart.n, F.sell_price(1000)) * 3 / 100)
    eq(due > 0, true, "the cart is worth a toll")
    eq(cart.tolls.c2M, due, "the cart records its toll")
    -- and a cart's bad tolls are cleared on load, the cart kept
    local good_tolls = cart.tolls
    cart.tolls = { [1] = 5 }; F.sanitize_ships()
    eq(tostring(F.ships()[1] == cart) .. "," .. tostring(cart.tolls), "true,nil", "a cart's bad tolls are cleared on load")
    cart.tolls = good_tolls
    eq(TREASURY.c2K, 100000 - cart.escrow - due, "the buyer pays the price and the toll")
    eq(TREASURY.c2M, due, "the land between is paid")
    local escrow = cart.escrow
    F.drop(cart)
    -- the buyer short of price and toll: no cart
    TREASURY.c2K = escrow + due - 1; TREASURY.c2M = nil
    TURN = TURN + 1; F.routes_turn(K.iface)
    eq(#F.ships(), 0, "a buyer who cannot pay the price and the toll sends for nothing")
    eq(TREASURY.c2M, nil, "and pays no toll")
    -- an own cart over the same land pays nothing
    TREASURY.c2K = 100000
    local own_cart = F.ship(K.iface, k2.iface, kr.iface, "coal", 50)
    eq(own_cart ~= nil and own_cart.tolls == nil, true, "a cart between your own settlements pays no toll")
    eq(TREASURY.c2M, nil, "nobody is paid")
    F.drop(own_cart)
    -- and costs nothing, so a faction in debt still moves its own goods
    TREASURY.c2K = -500
    own_cart = F.ship(K.iface, k2.iface, kr.iface, "coal", 50)
    eq(own_cart ~= nil and TREASURY.c2K, -500, "a faction in debt still sends a cart between its own settlements")
    if own_cart then F.drop(own_cart) end
    eq(#ERRORS, n0, "tolls in trade: no script errors")
    F.local_price, DERPY_MR_TERRAIN_ROUTES, F.reach_known = price, routes, known
    for _, k in ipairs({ "c2E", "c2M", "c2K" }) do TREASURY[k] = nil end
    F.state, TURN = state, turn0
end)()

-- BLOCKADES (Part C 6.2): an enemy army on the road stops the pair's trade, duty and contract carts that turn.
;(function()
    local state, turn0, routes, known, price, n0 = F.state, TURN, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.local_price, #ERRORS
    F.state = { factions = {}, rates = F.read_rates(), ship_seq = 99000 }
    for _, k in ipairs({ "upkeep", "supply", "events", "army_provisions", "escort", "spoilage" }) do F.state.rates[k] = false end
    F.reach_known, TURN, F.enemy_cache, F.blockade_known = {}, 330000, {}, {}
    local Y = 10100
    local E, B = faction("c3E"), faction("c3B", { human = true })
    local X, N = faction("c3X"), faction("c3N")   -- at war with the buyer; at war with neither side
    local er = region("c3E1", 0, Y, 2000, { coal = 1000 }); own(E, er, true)
    local br = region("c3B1", 20, Y, 1000, {}); own(B, br, true)
    own(X, region("c3X1", 60, Y + 60, 1000, {}), true)
    own(N, region("c3N1", 80, Y + 60, 1000, {}), true)
    E.partners, B.partners = { B }, { E }
    F.set_stock_policy("c3B", "coal", "target", "1000")
    war(X, B)
    local road = {}
    for x = 0, 20, 2 do road[#road + 1] = { x, Y } end
    DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, road end, journey = function() return road end }
    local P = { c3E1 = 1000, c3B1 = 5000 }
    F.local_price = function(v) return P[v.region:name()] end
    -- 3 hexes from the road blockades, 4 does not, and an army at war with neither side never does (Review Focus 4)
    X.armies = { field(X, 10, Y + 3, 33001) }
    eq(F.blockade(E.iface, B.iface, road), "c3X", "an army at war with the buyer 3 hexes from the road")
    F.enemy_cache, X.armies = {}, { field(X, 10, Y + 4, 33001) }
    eq(F.blockade(E.iface, B.iface, road), nil, "4 hexes away it is not")
    -- past the road's end the distance decides, not the widened box: 2 along and 3 up is 3.6 away
    F.enemy_cache, X.armies = {}, { field(X, 22, Y + 3, 33001) }
    eq(F.blockade(E.iface, B.iface, road), nil, "an army off the road's corner, outside the radius")
    F.enemy_cache, X.armies, N.armies = {}, {}, { field(N, 10, Y + 1, 33002) }
    eq(F.blockade(E.iface, B.iface, road), nil, "an army at war with neither side never blockades")
    eq(F.blockade(E.iface, B.iface, nil), nil, "no road, no blockade")
    -- the real trade: nothing for the pair, the blocker recorded, the preview empty too (Review Focus 5)
    F.enemy_cache, N.armies, X.armies = {}, {}, { field(X, 10, Y + 3, 33001) }
    F.trade(E.iface)
    eq(#F.convoys() .. "," .. er.held.coal, "0,1000", "a blockaded pair sends nothing")
    eq(F.blockaded("c3E", "c3B") .. "," .. F.blockaded("c3B", "c3E"), "c3X,c3X", "the blocker is recorded, either way round")
    eq(F.trade(E.iface, true).c3B, nil, "the preview sends nothing to a blockaded pair")
    -- no duty for a blockaded pair; the same pair clear of it pays
    F.state.rates.duty, er.made, F.made_cache = 50, { coal = 100 }, nil
    F.duty(B.iface)
    eq(TREASURY.c3B, nil, "a blockaded pair pays no duty")
    local cut = F.cut_off(B.iface)
    eq(#cut .. "," .. cut[1].key .. "," .. cut[1].by .. "," .. tostring(cut[1].why), "1,c3E,c3X,nil",
       "the cut-off list names the blockaded partner and its blocker")
    F.blockade_known, F.made_cache = {}, nil
    F.duty(B.iface)
    eq((TREASURY.c3B or 0) < 0, true, "clear of it, the duty is paid")
    eq(#F.cut_off(B.iface), 0, "and nobody is cut off")
    TREASURY.c3B, TREASURY.c3E, F.state.rates.duty = nil, nil, 0
    -- a partner contract on the blockaded road sends no cart and says why
    local o = F.route_create(B.iface, "c3E1", "c3B1", "coal", 70, 100)
    eq(o ~= nil, true, "a contract with the exporter")
    TURN = TURN + 1; F.enemy_cache = {}; F.routes_turn(B.iface)
    eq(#F.ships() .. "," .. o.status, "0,Blockaded", "no cart leaves a blockaded road, and the contract says so")
    -- a convoy already on the road is untouched: it arrives
    local c = F.convoy_new(E.iface, B.iface, { coal = 10 }, road)
    TURN = c.due; F.enemy_cache = {}; F.convoys_turn(E.iface)
    eq(br.held.coal, 10, "a convoy already on the road arrives through the blockade")
    -- with tolls and blockades off the trade goes as before
    F.state.rates.tolls, F.blockade_known, F.enemy_cache = false, {}, {}
    F.trade(E.iface)
    eq(#F.convoys(), 1, "with the switch off the blockaded pair trades")
    eq(F.blockaded("c3E", "c3B"), nil, "and nothing is recorded")
    eq(#ERRORS, n0, "blockades: no script errors")
    F.local_price, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.blockade_known = price, routes, known, {}
    F.state, TURN = state, turn0
end)()

-- BANDITS ON THE ROADS (Part D 7.1): the stretch a cargo covered, its threat, and the roll.
;(function()
    local state, turn0, n0 = F.state, TURN, #ERRORS
    F.state = { factions = {}, rates = F.read_rates() }
    local Y = 10300
    local A, M1, M2, B = faction("d1A", { human = true }), faction("d1M1"), faction("d1M2"), faction("d1B")
    local ra, rm1 = region("d1a", 0, Y, 1000, {}), region("d1m1", 10, Y, 1000, {})
    own(A, ra, true); own(M1, rm1, true)
    own(M2, region("d1m2", 20, Y, 1000, {}), true)
    own(B, region("d1b", 30, Y, 1000, {}), true)
    local road = {}
    for x = 0, 30, 2 do road[#road + 1] = { x, Y } end
    eq(table.concat(F.stretch(road, { 0, Y }, { 12, Y }), ","), "d1a,d1m1", "the stretch from 0 to 12, each region once")
    eq(table.concat(F.stretch(nil, { 0, Y }, { 12, Y }), ","), "d1m1", "no road: the region it stands in")
    eq(table.concat(F.stretch(road, { 1, Y + 50 }, { 12, Y }), ","), "d1m1", "a start off the road: the same")
    -- the wild-land rule
    local wild = region("d1w", 500, Y, 1000, {})
    eq(F.wild(wild.iface), 100, "an abandoned region is wild")
    local R = faction("d1R", { rebel = true }); own(R, wild)
    eq(F.wild(wild.iface), 100, "so is a rebel one")
    lose(R, wild); own(M1, wild)
    wild.corruption, wild.po = 40, -10; eq(F.wild(wild.iface), 40, "corruption 40 and public order -10")
    wild.corruption, wild.po = 0, -60; eq(F.wild(wild.iface), 60, "unrest 60")
    wild.corruption, wild.po = 0, 50; eq(F.wild(wild.iface), 0, "a contented region is safe")
    wild.corruption, wild.po = 150, 0; eq(F.wild(wild.iface), 100, "never past 100")
    -- CA's banditry first, the wild land's average when it reads 0 or fails
    ra.po, rm1.po = -30, -50
    BANDITRY = function(keys) return #keys == 2 and 90 or 0 end
    eq(F.threat({ "d1a", "d1m1" }), 45, "CA's banditry over two regions")
    BANDITRY = function() return 0 end
    eq(F.threat({ "d1a", "d1m1" }), 40, "CA's 0: the wild land's average")
    BANDITRY = function() error("no caravans here") end
    eq(F.threat({ "d1a", "d1m1" }), 40, "CA's call failing: the same")
    eq(F.threat({}), 0, "no regions, no threat")
    BANDITRY, ra.po, rm1.po = nil, nil, nil
    -- the roll: threat x danger in 10000, halved by guards
    F.state.rates.road_danger = 20
    ROLLQ = { 1000, 1 }; eq(F.road_roll("d1A", 50, false, true), "ambush", "1000 against 50 x 20 is trouble")
    F.state.road_cool = nil
    ROLLQ = { 1000 }; eq(F.road_roll("d1A", 50, true, true), nil, "guarded, the same roll is not")
    ROLLQ = { 1001 }; eq(F.road_roll("d1A", 50, false, true), nil, "1001 is not")
    local calls = #ROLLS
    eq(F.road_roll("d1A", 0, false, true), nil, "threat 0 is never trouble")
    eq(#ROLLS, calls, "and rolls nothing")
    -- which encounters: the pick's range is how many were eligible
    local function pick(fkey, threat, land, n)
        ROLLQ = { 1, n }
        local got = F.road_roll(fkey, threat, false, land)
        return tostring(got) .. "/" .. ROLLS[#ROLLS][1]
    end
    F.state.road_cool = nil
    eq(pick("d1x", 20, true, 1), "highwaymen/2", "threat 20 never offers the ambush")
    eq(pick("d1y", 60, false, 2), "highwaymen/2", "at sea the washout is never offered")
    -- a cooldown blocks an encounter for 5 turns and frees it on the 6th
    TURN = 500; eq(pick("d1c", 60, true, 3), "washout/3", "all three on land at 60")
    TURN = 505; eq(pick("d1c", 60, true, 2), "highwaymen/2", "the washout waits 5 turns")
    TURN = 506; eq(pick("d1c", 60, true, 2), "washout/2", "and is offered on the 6th")
    ROLLQ = nil
    -- a patrol: an army of the owner or the buyer within 3 hexes, never a garrison
    A.armies = { field(A, 10, Y + 3, 34001) }
    eq(F.patrol(A.iface, nil, 10, Y), true, "an army of the owner 3 hexes away")
    A.armies = { field(A, 10, Y + 4, 34001) }
    eq(F.patrol(A.iface, nil, 10, Y), false, "4 is too far")
    A.armies, B.armies = {}, { field(B, 10, Y + 1, 34002) }
    eq(F.patrol(A.iface, B.iface, 10, Y), true, "or the buyer's")
    B.armies = { field(B, 10, Y, 34002, true) }
    eq(F.patrol(A.iface, B.iface, 10, Y), false, "a garrison is no patrol")
    B.armies = {}
    -- the bandits' faction by the land owner's subculture
    local n = 0
    for sc, k in pairs(DERPY_MR_FLOWS_BANDIT_QB) do
        n = n + 1
        eq(string.sub(k, -4), "_qb1", "the bandits of " .. sc)
    end
    eq(n >= 15, true, "a bandit faction for most races")
    eq(DERPY_MR_FLOWS_BANDIT_QB.wh_main_sc_emp_empire, "wh_main_emp_empire_qb1", "the Empire's, not its rebels'")
    eq(#ERRORS, n0, "road threat: no script errors")
    F.state, TURN = state, turn0
end)()

-- BANDITS ON CARGO (Part D 7.2-7.4): the other choices, the hooks, Guards, and load.
F.road_event = ROAD_EVENT   -- the real rule from here on
;(function()
    local state, turn0, routes, known, price, n0 = F.state, TURN, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.local_price, #ERRORS
    local message = cm.show_message_event
    local said = {}
    cm.show_message_event = function(_, fk, title) said[#said + 1] = { fk, title } end
    F.state = { factions = {}, rates = F.read_rates() }
    for _, k in ipairs({ "upkeep", "supply", "events", "army_provisions", "escort", "spoilage", "tolls" }) do
        F.state.rates[k] = false
    end
    F.state.rates.road_danger = 20
    F.reach_known, F.blockade_known, F.enemy_cache, TURN, F.state.ship_seq = {}, {}, {}, 340000, 101000
    local Y = 10500
    local E, M, H = faction("d2E", { gold = 1000 }), faction("d2M"), faction("d2H", { human = true })
    local er = region("d2e", 0, Y, 2000, { coal = 1000 }); own(E, er, true)
    local rm = region("d2m", 20, Y, 1000, {}); own(M, rm, true); rm.po = -60
    local rh = region("d2h", 40, Y, 1000, {}); own(H, rh, true)
    E.partners, H.partners = { H }, { E }
    local road = {}
    for x = 0, 40, 2 do road[#road + 1] = { x, Y } end
    DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, road end, journey = function() return road end }
    -- a computer's convoy to the player, at 24 having come from 16: the stretch is M's land, threat 60
    local function convoy(basket)
        local c = F.convoy_new(E.iface, H.iface, basket, road)
        c.x = 24
        return c
    end
    local function event(c, ...)   -- the queued answers: the roll, then the pick
        ROLLQ, F.state.road_cool = { ... }, nil
        F.road_event(E.iface, "convoy", c, { 16, Y })
        ROLLQ = nil
    end
    -- the ambush, for a computer: no dilemma, half of each good lost, the player told of the import's loss
    local c, dilemmas = convoy({ coal = 100, iron = 31 }), #DILEMMAS
    event(c, 1, 1)
    eq(c.threat, 60, "the stretch's threat is kept on the convoy")
    eq(c.basket.coal .. "," .. c.basket.iron, "50,16", "the bandits take half of each good, rounded down")
    eq(#DILEMMAS, dilemmas, "a computer is offered no dilemma")
    eq(#said .. "," .. said[1][1] .. "," .. said[1][2], "1,d2H,event_feed_strings_text_derpy_mr_road_loss_title",
       "the player hears that an import was robbed")
    eq(F.state.road_seen.d2E, TURN, "dangerous land is remembered for the computer's guards")
    -- highwaymen: a fifth of the value in gold; an empty treasury still lets the cargo pass, whole
    local value = F.cargo_value_base(c)
    eq(value >= 50, true, "the cargo is worth something")
    TREASURY.d2E = nil
    event(c, 1, 2)
    eq(TREASURY.d2E, -math.floor(value * 20 / 100), "the highwaymen take a fifth of its value")
    TREASURY.d2E = -1000
    event(c, 1, 2)
    eq(TREASURY.d2E .. "," .. c.basket.coal, "-1000,50", "with no gold the cargo still passes, whole")
    TREASURY.d2E = nil
    -- the washed-out road: a turn later, nothing lost, nobody told
    local due = c.due
    event(c, 1, 3)
    eq(c.due .. "," .. #said, due + 1 .. ",1", "the washed-out road costs a turn")
    -- no roll: a patrol near, the switch off, safe land, the sea
    local calls = #ROLLS
    E.armies = { field(E, 24, Y + 3, 35001) }
    event(c, 1, 1)
    eq(#ROLLS, calls, "the exporter's army 3 hexes off keeps trouble away")
    E.armies, H.armies = {}, { field(H, 24, Y - 2, 35002) }
    event(c, 1, 1)
    eq(#ROLLS, calls, "and so does the buyer's")
    H.armies = {}
    F.state.rates.bandits = false; event(c, 1, 1); F.state.rates.bandits = true
    eq(#ROLLS, calls, "the switch off: no roll")
    rm.po = 0; event(c, 1, 1); rm.po = -60
    eq(#ROLLS .. "," .. c.threat, calls .. ",0", "safe land: no roll")
    local sea = convoy({ coal = 10 })
    sea.road, sea.x, sea.y = F.pack_road({ { 0, Y + 400 }, { 2, Y + 400 } }), 2, Y + 400
    F.road_event(E.iface, "convoy", sea, { 0, Y + 400 })
    eq(#ROLLS .. "," .. sea.threat, calls .. ",0", "at sea there is no land: no threat and no roll")
    -- out at sea after a stretch over M's dangerous land: the threat is kept, but all three encounters are land ones
    local ashore = convoy({ coal = 10 })
    ashore.road, ashore.x, ashore.y = F.pack_road({ { 16, Y }, { 20, Y }, { 24, Y }, { 26, Y + 400 } }), 26, Y + 400
    ROLLQ, F.state.road_cool = { 1, 1 }, nil   -- a roll, were there one, would be trouble
    F.road_event(E.iface, "convoy", ashore, { 16, Y })
    ROLLQ = nil
    eq(ashore.threat .. "," .. #ROLLS, "60," .. calls, "cargo now at sea meets nothing, whatever the land behind it")
    -- losses round down per good; a basket the loss empties leaves the road
    local ones = convoy({ coal = 1, iron = 1 })
    eq(F.cargo_lose("convoy", ones, 50) .. "|" .. ones.basket.coal .. "," .. ones.basket.iron, "0|1,1", "a lot of 1 loses nothing to half")
    local twos = convoy({ coal = 2, iron = 1 })
    F.cargo_lose("convoy", twos, 50)
    eq(twos.basket.coal .. "," .. twos.basket.iron, "1,1", "a lot of 2 loses 1")
    F.cargo_lose("convoy", twos, 100)
    local left = false
    for _, x in ipairs(F.convoys()) do if x == twos then left = true end end
    eq(left, false, "a basket the loss empties leaves the road")
    local ship = { id = F.SHIP_PREFIX .. "d2", f = "d2E", stem = "coal", n = 7, from = "d2e", to = "d2e", at = TURN,
                   due = TURN + 3, leg = 1, x = 24, y = Y }
    F.state.ships = { ship }
    F.cargo_lose("ship", ship, 50); eq(ship.n, 4, "a shipment loses half, rounded down")
    F.cargo_wait("ship", ship); eq(ship.due, TURN + 4, "and a washed-out road delays it a turn")
    F.cargo_lose("ship", ship, 100); eq(#F.ships(), 0, "all of it ends the shipment")
    -- THE HOOK: a computer convoy still on the road meets trouble after its step; one arriving this turn does not
    F.state.convoys = {}
    local on = F.convoy_new(E.iface, H.iface, { coal = 40 }, road)
    on.due = TURN + 2
    local arriving = F.convoy_new(E.iface, H.iface, { coal = 40 }, road)
    arriving.due = TURN + 1
    TURN = TURN + 1
    F.state.road_cool, ROLLQ = nil, { 1, 3 }
    F.convoys_turn(E.iface)
    ROLLQ = nil
    eq(on.x .. "," .. on.threat .. "," .. on.due, "20,30," .. TURN + 2, "halfway, threat 30 over two regions: a washed-out road")
    eq(arriving.threat, nil, "the convoy that arrived met nothing")
    -- GUARDS: the player's own switch; a computer's while its cargo crossed dangerous land last turn
    eq(F.guards_on("d2H"), false, "no guards to begin with")
    F.dispatch("d2H", { "guards", "on" })
    eq(F.guards_on("d2H"), true, "the player hires guards")
    -- a set, not a toggle: a double click, or a click on a panel not yet redrawn, asks for the same thing twice
    F.dispatch("d2H", { "guards", "on" }); eq(F.guards_on("d2H"), true, "Hire twice: still on")
    F.dispatch("d2H", { "guards", "yes" }); F.dispatch("d2H", { "guards" })
    eq(F.guards_on("d2H"), true, "any other request changes nothing")
    F.dispatch("d2H", { "guards", "off" }); F.dispatch("d2H", { "guards", "off" })
    eq(F.guards_on("d2H"), false, "Dismiss twice: off")
    F.dispatch("d2H", { "guards", "on" })
    F.state.road_seen = { d2E = TURN - 1 }; eq(F.guards_on("d2E"), true, "a computer whose cargo met danger last turn")
    F.state.road_seen = { d2E = TURN - 3 }; eq(F.guards_on("d2E"), false, "not three turns ago")
    -- the fee at dispatch: 5% of the value; the roll is then halved
    F.state.road_seen, F.state.convoys = { d2E = TURN - 1 }, {}
    er.held.coal = 1000; F.set_stock_policy("d2H", "coal", "target", "1000")
    local P = { d2e = 1000, d2h = 5000 }
    F.local_price = function(v) return P[v.region:name()] end
    F.trade(E.iface)
    local ec = F.convoys()[1]
    local fee = math.floor(F.cargo_value_base(ec) * 5 / 100)
    eq(fee > 0, true, "the convoy is worth a fee")
    eq(TREASURY.d2E .. "," .. tostring(ec.guarded), -fee .. ",true", "a computer with guards pays the fee and is guarded")
    ROLLQ = { 1000 }
    eq(F.road_roll("d2E", 50, ec.guarded, true), nil, "and 1000 on threat 50 at 20 is no trouble guarded")
    ROLLQ = nil
    TREASURY.d2E = -1000 - F.cargo_value_base(ec)
    F.state.convoys, F.reach_known = {}, {}
    F.trade(E.iface)
    ec = F.convoys()[1]
    eq(ec ~= nil and ec.guarded, nil, "guards it cannot pay for: the convoy leaves unguarded")
    TREASURY.d2E = nil
    -- the player's contract cart: the buyer pays the price and the fee (no convoy on the way to fill the target)
    TREASURY.d2H, F.state.convoys = 100000, {}
    local o = F.route_create(H.iface, "d2e", "d2h", "coal", 70, 100)
    eq(o ~= nil, true, "a contract with the seller")
    TURN = TURN + 1; F.routes_turn(H.iface)
    local cart = F.ships()[1]
    local cart_fee = math.floor(F.cargo_value_base(cart) * 5 / 100)
    eq(cart_fee > 0 and cart.guarded, true, "the player's cart is guarded")
    eq(TREASURY.d2H, 100000 - cart.escrow - cart_fee, "the buyer pays the price and the fee")
    -- THE CART'S HOOK: halfway after its step, over threat 30, the player is asked; waiting delays it a turn
    cart.at, cart.due = TURN, TURN + 2
    TURN = TURN + 1
    F.state.road_cool, ROLLQ = nil, { 1, 3, 1 }   -- the roll, the washout, the region
    local asked = #DILEMMAS
    F.ships_turn(H.iface)
    ROLLQ = nil
    eq(#DILEMMAS - asked .. "," .. DILEMMAS[#DILEMMAS].key .. "," .. cart.x .. "," .. cart.threat,
       "1," .. DERPY_MR_FLOWS_EVENTS.road_washout.dilemma .. ",20,30", "a cart on the road meets a washed-out road")
    answer(H, DERPY_MR_FLOWS_EVENTS.road_washout.dilemma, "FIRST")
    eq(cart.due, TURN + 2, "and waiting delays it a turn")
    F.drop(cart)
    -- LOAD: a malformed cooldown, guards and danger record are cleaned
    F.state.road_cool = { d2E = { ambush = 5, nope = 3, washout = "x" }, [7] = {}, d2X = "bad" }
    F.state.guards = { d2H = true, d2E = "yes" }
    F.state.road_seen = { d2E = 10, d2X = -1 }
    SAVED = {}; cm.saving_game_callbacks[1]({}); F.state = {}; cm.loading_game_callbacks[1]({})
    eq(F.state.road_cool.d2E.ambush .. "," .. tostring(F.state.road_cool.d2E.nope) .. "," .. tostring(F.state.road_cool.d2E.washout)
       .. "," .. tostring(F.state.road_cool.d2X), "5,nil,nil,nil", "the cooldowns cleaned on load")
    eq(tostring(F.state.guards.d2H) .. "," .. tostring(F.state.guards.d2E), "true,nil", "the guards cleaned")
    eq(F.state.road_seen.d2E .. "," .. tostring(F.state.road_seen.d2X), "10,nil", "the danger record cleaned")
    F.state.road_cool, F.state.guards, F.state.road_seen = "junk", 5, {}
    F.sanitize_road()
    eq(F.state.road_cool == nil and F.state.guards == nil and F.state.road_seen == nil, true, "junk is dropped whole")
    eq(#ERRORS, n0, "bandits on cargo: no script errors")
    cm.show_message_event = message
    F.local_price, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.blockade_known = price, routes, known, {}
    F.state, TURN = state, turn0
end)()

-- BANDITS: THE PLAYER'S DILEMMA AND THE BATTLE (Part D 7.3), as CA's caravans spawn and fight theirs.
;(function()
    local state, turn0, routes, n0 = F.state, TURN, DERPY_MR_TERRAIN_ROUTES, #ERRORS
    F.state = { factions = {}, rates = F.read_rates() }
    for _, k in ipairs({ "upkeep", "supply", "events", "army_provisions", "escort", "spoilage", "tolls" }) do
        F.state.rates[k] = false
    end
    F.state.rates.road_danger, TURN, F.state.fight = 20, 360000, nil
    Forced_Battle_Manager.active_battle = ""
    local Y = 10700
    local H = faction("d3H", { human = true, sc = "wh_main_sc_emp_empire" })
    local M, E = faction("d3M", { sc = "wh_main_sc_dwf_dwarfs" }), faction("d3E")
    own(H, region("d3h", 0, Y, 2000, {}), true)
    local rm = region("d3m", 20, Y, 1000, {}); own(M, rm, true); rm.po = -60
    own(E, region("d3e", 40, Y, 1000, {}), true)
    H.partners, E.partners = { E }, { H }
    local road = {}
    for x = 0, 40, 2 do road[#road + 1] = { x, Y } end
    DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, road end, journey = function() return road end }
    -- CA's calls as the caravans make them, recorded; a spawned force lives in FORCES until its general is killed
    local made, killed, wars, frozen, gone_back, cqi = {}, {}, {}, {}, {}, 61000
    cm.find_valid_spawn_location_for_character_from_position = function(_, fk, x, y, same)
        if type(fk) ~= "string" or same ~= false then error("find_valid_spawn_location_for_character_from_position: bad arguments") end
        if SPAWN_FAIL then return -1, -1 end
        return x + 1, y
    end
    cm.create_force = function(_, fk, units, rk, x, y, no_named, cb)
        if type(units) ~= "string" or units == "" or type(rk) ~= "string" or no_named ~= true then error("create_force: bad arguments") end
        cqi = cqi + 1
        local ch, fc = cqi, cqi + 500
        made[#made + 1] = { f = fk, units = units, ch = ch, fc = fc, x = x, y = y }
        FORCES[fc] = { is_null_interface = function() return false end, has_general = function() return true end,
                       command_queue_index = function() return fc end, has_garrison_residence = function() return false end,
                       general_character = function() return { cqi = function() return ch end } end,
                       active_stance = function() return "MILITARY_FORCE_ACTIVE_STANCE_TYPE_DEFAULT" end }
        cb(ch, fc)
    end
    cm.char_lookup_str = function(_, n) return "character_cqi:" .. n end
    cm.kill_character = function(_, lookup, whole)
        if whole ~= true then error("kill_character: the bandits' force must go with them") end
        killed[#killed + 1] = lookup
        FORCES[tonumber(string.match(lookup, "(%d+)$")) + 500] = nil
    end
    cm.force_declare_war = function(_, a, b) wars[#wars + 1] = a .. ">" .. b end
    cm.disable_movement_for_character = function(_, lookup) frozen[#frozen + 1] = lookup end
    cm.set_force_has_retreated_this_turn = function(_, mf) gone_back[#gone_back + 1] = mf end
    local force_lookup = cm.get_military_force_by_cqi
    cm.get_military_force_by_cqi = function(_, n) return FORCES[n] or false end
    local EV = DERPY_MR_FLOWS_EVENTS
    local function offer(c, pick)   -- the roll, the pick, then the region
        ROLLQ, F.state.road_cool = { 1, pick, 1 }, nil
        F.road_event(H.iface, "convoy", c, { 16, Y })
        ROLLQ = nil
    end
    local function convoy(basket)
        local c = F.convoy_new(H.iface, E.iface, basket, road)
        c.x = 24
        return c
    end
    local function on_road(c)
        for _, x in ipairs(F.convoys()) do if x == c then return true end end
        return false
    end
    local function battle_done(attacker_won)
        local last = FBM_LOG[#FBM_LOG]
        fire("PendingBattle", {})
        BATTLE = { attacker_won = attacker_won, fought = true, involved = { [last.att] = true, [last.escort] = true } }
        fire("BattleCompleted", {})
        if CA_ARMED then ca_handler() end
    end
    local dil0, fbm0 = #DILEMMAS, #FBM_LOG
    -- THE AMBUSH OFFER: the bandits spawn first, for the land owner's race, 8 units at threat 60
    local c = convoy({ coal = 100, iron = 31 })
    offer(c, 1)
    local b = made[1]
    eq(#made .. "," .. b.f, "1,wh_main_dwf_dwarfs_qb1", "one bandit army, of the land owner's race")
    eq(select(2, string.gsub(b.units, ",", ",")) + 1, 8, "8 units at threat 60")
    eq(b.x .. "," .. b.y, 25 .. "," .. Y, "beside the cargo")
    eq(wars[1] .. "|" .. frozen[1] .. "|" .. #gone_back, "wh_main_dwf_dwarfs_qb1>d3H|character_cqi:" .. b.ch .. "|1",
       "at war with the owner, unable to move, and counted as retreated")
    -- THE SPAWN'S CALLBACK keeps the owner's key, not its interface: here the interface is spent once CA has the call
    local spent, cf = false, cm.create_force
    local owner = setmetatable({}, { __index = function(_, k)
        local v = H.iface[k]
        if type(v) ~= "function" then return v end
        return function(_, ...)
            if spent then error("the owner's interface read inside the spawn's callback", 2) end
            return v(H.iface, ...)
        end
    end })
    cm.create_force = function(self, ...) spent = true; return cf(self, ...) end
    local ok, fc = pcall(F.bandit_spawn, "d3m", 24, Y, 60, owner)
    cm.create_force, spent = cf, false
    eq(ok and wars[#wars], "wh_main_dwf_dwarfs_qb1>d3H", "the war is declared on the owner's key (" .. tostring(fc) .. ")")
    F.bandit_kill(fc)
    -- A RACE'S BANDITS THAT NEVER APPEAR (seen 2026-11-03: CA logs the Chaos Dwarf qb1's create_force and makes no army,
    -- so no fight could start on Chaos Dwarf land): CA's Ogre bandits, the caravans' own, come instead
    cm.create_force = function(self, fk, ...)
        if fk == "wh_main_dwf_dwarfs_qb1" then return end
        return cf(self, fk, ...)
    end
    local before = #made
    local ok2, fc2 = pcall(F.bandit_spawn, "d3m", 24, Y, 60, H.iface)
    cm.create_force = cf
    eq(ok2 and (#made - before) .. "," .. made[#made].f .. "," .. tostring(fc2 == made[#made].fc),
       "1,wh3_main_ogr_ogre_kingdoms_qb1,true", "a race's bandits that never appear: CA's Ogre bandits instead")
    eq(wars[#wars], "wh3_main_ogr_ogre_kingdoms_qb1>d3H", "the Ogre bandits at war with the owner")
    F.bandit_kill(fc2)
    local d = DILEMMAS[#DILEMMAS]
    eq(#DILEMMAS - dil0 .. "," .. d.key .. "," .. d.force .. "," .. d.region .. "," .. d.fcqi,
       "1," .. EV.road_ambush.dilemma .. "," .. b.fc .. "," .. rm.iface:cqi() .. "," .. H.cqi, "the ambush asked of the player, naming the bandits and the region")
    eq(F.pending("d3H", "road_ambush") ~= nil and c.basket.coal == 100, true, "one encounter waits, the cargo untouched")
    -- FIRST: the bandits attack the player's guard army through CA's manager
    answer(H, EV.road_ambush.dilemma, "FIRST")
    local fb = FBM_LOG[#FBM_LOG]
    eq(#FBM_LOG - fbm0 .. "," .. fb.att .. "," .. fb.force.f, "1," .. b.fc .. ",d3H", "the bandits attack a guard army of the player's")
    eq(fb.force.units ~= "" and F.state.fight.side .. "," .. tostring(RETREAT_LOCKED), "bandit,true", "a bandit fight, the retreat locked")
    eq(F.pending("d3H", "road_ambush"), nil, "the encounter no longer waits")
    -- the bandits win: the whole cargo is lost; the bandits go either way
    battle_done(true)
    eq(tostring(on_road(c)) .. "," .. killed[#killed] .. "," .. tostring(F.state.fight) .. "," .. tostring(RETREAT_LOCKED),
       "false,character_cqi:" .. b.ch .. ",nil,false", "a lost fight loses the cargo, and the bandits are removed")
    -- the guards win: the cargo goes on whole
    c = convoy({ coal = 100 }); offer(c, 1); b = made[#made]
    answer(H, EV.road_ambush.dilemma, "FIRST"); battle_done(false)
    eq(tostring(on_road(c)) .. "," .. c.basket.coal .. "," .. killed[#killed], "true,100,character_cqi:" .. b.ch, "a won fight: the cargo goes on, the bandits removed")
    -- SECOND: let it go, half lost, the bandits removed and no battle
    local fights = #FBM_LOG
    offer(c, 1); b = made[#made]
    answer(H, EV.road_ambush.dilemma, "SECOND")
    eq(c.basket.coal .. "," .. killed[#killed] .. "," .. #FBM_LOG, "50,character_cqi:" .. b.ch .. "," .. fights, "letting it go loses half")
    -- HIGHWAYMEN: FIRST pays a fifth of the value; SECOND fights
    local value = F.cargo_value_base(c)
    TREASURY.d3H = nil
    offer(c, 2); b = made[#made]
    eq(DILEMMAS[#DILEMMAS].key, EV.road_highwaymen.dilemma, "the highwaymen asked")
    answer(H, EV.road_highwaymen.dilemma, "FIRST")
    eq(TREASURY.d3H .. "," .. killed[#killed] .. "," .. #FBM_LOG, -math.floor(value * 20 / 100) .. ",character_cqi:" .. b.ch .. "," .. fights,
       "paying the highwaymen: a fifth of the value, no battle")
    offer(c, 2)
    answer(H, EV.road_highwaymen.dilemma, "SECOND")
    eq(#FBM_LOG, fights + 1, "refusing them is a battle")
    battle_done(false)
    -- THE WASHOUT: nothing spawns; FIRST waits a turn, SECOND loses a tenth
    local spawned, due = #made, c.due
    offer(c, 3)
    eq(#made .. "," .. DILEMMAS[#DILEMMAS].key .. "," .. DILEMMAS[#DILEMMAS].force, spawned .. "," .. EV.road_washout.dilemma .. ",0", "the washout spawns nobody")
    answer(H, EV.road_washout.dilemma, "FIRST"); eq(c.due, due + 1, "waiting costs a turn")
    offer(c, 3); answer(H, EV.road_washout.dilemma, "SECOND"); eq(c.basket.coal, 45, "pushing on loses a tenth")
    -- ONE ENCOUNTER WAITS AT A TIME (Review Focus 2): a second, while the first waits, is settled at once
    local c2 = convoy({ coal = 100 })
    local asked = #DILEMMAS
    offer(c, 1); b = made[#made]; spawned = #made
    offer(c2, 1)
    eq(#DILEMMAS - asked .. "," .. #made - spawned .. "," .. c2.basket.coal, "1,0,50", "the second ambush is settled: half lost, no army, no dilemma")
    answer(H, EV.road_ambush.dilemma, "SECOND")
    -- A FIGHT CHOSEN WHILE ANOTHER BATTLE WAITS: settled as the other choice, the bandits removed
    c2.basket.coal = 100
    offer(c2, 1); b = made[#made]
    F.state.fight = { id = "other", side = "raid", key = "derpy_mr_escort_other", turn = TURN }
    fights = #FBM_LOG
    answer(H, EV.road_ambush.dilemma, "FIRST")
    eq(#FBM_LOG - fights .. "," .. c2.basket.coal .. "," .. killed[#killed], "0,50,character_cqi:" .. b.ch, "no second battle: half lost, the bandits removed")
    F.state.fight = nil
    -- A SAVE WITH THE DILEMMA OPEN (Review Focus 1): answering after a reload still fights
    c2.basket.coal = 100
    offer(c2, 1); b = made[#made]
    SAVED = {}; cm.saving_game_callbacks[1]({}); F.state = {}; cm.loading_game_callbacks[1]({})
    answer(H, EV.road_ambush.dilemma, "FIRST")
    eq(#FBM_LOG, fights + 1, "the reloaded encounter's fight starts")
    battle_done(false)
    -- ONE LEFT FROM AN EARLIER TURN is cleared at the next turn start and its bandits removed
    local c3 = convoy({ coal = 100 })
    offer(c3, 1); b = made[#made]
    TURN = TURN + 1; F.fight_stale(TURN)
    eq(tostring(F.pending("d3H", "road_ambush")) .. "," .. killed[#killed], "nil,character_cqi:" .. b.ch, "a stale encounter is cleared")
    -- THE CARGO GONE before the answer: the bandits go, nothing else happens
    offer(c3, 1); b = made[#made]
    F.convoy_drop(c3); fights = #FBM_LOG
    answer(H, EV.road_ambush.dilemma, "FIRST")
    eq(#FBM_LOG - fights .. "," .. killed[#killed], "0,character_cqi:" .. b.ch, "no cargo, no battle, the bandits removed")
    -- A SPAWN THAT FAILS, MULTIPLAYER, BATTLES OFF: no dilemma for a fight; the other choice
    local c4 = convoy({ coal = 100 })
    local due4 = c4.due
    asked, spawned = #DILEMMAS, #made
    SPAWN_FAIL = true; offer(c4, 1); SPAWN_FAIL = false
    eq(#DILEMMAS - asked .. "," .. c4.basket.coal, "0,50", "no spot for the bandits: half lost, nothing asked")
    MP = true; offer(c4, 1); offer(c4, 3); MP = false
    eq(#DILEMMAS - asked .. "," .. #made - spawned .. "," .. c4.basket.coal .. "," .. c4.due, "0,0,25," .. due4 + 1,
       "multiplayer: no dilemma and no army, the other choice")
    F.ROAD_BATTLES = false
    offer(c4, 1)
    eq(#DILEMMAS - asked .. "," .. #made - spawned .. "," .. c4.basket.coal, "0,0,13", "battles off: the ambush is settled")
    offer(c4, 3)
    eq(#DILEMMAS - asked .. "," .. DILEMMAS[#DILEMMAS].key, "1," .. EV.road_washout.dilemma, "and the washout still asks")
    answer(H, EV.road_washout.dilemma, "FIRST")
    F.ROAD_BATTLES = true
    eq(#ERRORS, n0, "bandit battles: no script errors")
    for _, k in ipairs({ "find_valid_spawn_location_for_character_from_position", "create_force", "char_lookup_str", "kill_character",
                         "force_declare_war", "disable_movement_for_character", "set_force_has_retreated_this_turn",
                         "get_military_force_by_cqi" }) do cm[k] = nil end
    cm.get_military_force_by_cqi = force_lookup
    DERPY_MR_TERRAIN_ROUTES, F.state, TURN = routes, state, turn0
end)()

-- ====================================================================================================
-- PART E (design 2026-11-01, section 8): six store events that read the stocks, tolls, blockades and roads
-- TASK 1: THE ROWS AND THE GATES. Each event names the parts it needs and whether only a player gets it.
;(function()
    local state, n0 = F.state, #ERRORS
    local EV = DERPY_MR_FLOWS_EVENTS
    local want = { smugglers = ",false", guild = ",false", grain_rot = "spoilage,true", caravan_master = "bandits,true",
                   toll_dispute = "tolls+edicts,true", blockade_runner = "tolls,true" }
    for _, k in ipairs({ "smugglers", "guild", "grain_rot", "caravan_master", "toll_dispute", "blockade_runner" }) do
        local e = EV[k]
        eq(e and e.needs and table.concat(e.needs, "+") .. "," .. tostring(e.human), want[k], k)
    end
    F.state = { factions = {}, rates = F.read_rates() }
    for _, k in ipairs({ "spoilage", "bandits", "tolls", "edicts", "events", "ai" }) do F.state.rates[k] = true end
    local H, A = faction("e1H", { human = true }), faction("e1A")
    eq(F.event_gated(A.iface, EV.grain_rot), false, "Grain rot is never a computer's")
    eq(F.event_gated(H.iface, EV.grain_rot), true, "a player's Grain rot with spoilage on")
    eq(F.event_gated(A.iface, EV.smugglers), true, "Smugglers for a computer with every switch on")
    eq(F.event_gated(H.iface, EV.feast), true, "an older event has no gate")
    F.state.rates.spoilage = false
    eq(F.event_gated(H.iface, EV.grain_rot), false, "no Grain rot with spoilage off")
    F.state.rates.edicts = false
    eq(F.event_gated(H.iface, EV.toll_dispute), false, "Toll dispute needs the edicts as well as the tolls")
    -- AN OLD SAVE (Review Focus 5): its book knew only the feast, and its pending offer is one per faction
    local v = region("e1v", 41000, 0, 400, { grain = 150 }); own(H, v, true)
    F.state.events = { e1H = { at = -1000000, seen = { feast = 3 } } }
    local o = F.event_pick(H.iface, F.event_book("e1H"))
    eq(o and o.key .. "," .. o.region, "feast,e1v", "an old book still picks the feast under the new order")
    F.state.pending = { e1H = { key = "feast", region = "e1v" } }
    answer(H, EV.feast.dilemma, "FIRST")
    eq(v.held.grain, 150 - EV.feast.cost, "and an old save's offer still pays out")
    eq(#ERRORS, n0, "Part E rows and gates: no script errors")
    F.state = state
end)()

-- TASK 2: SMUGGLERS, MERCHANT GUILD AND GRAIN ROT
;(function()
    local state, turn0, n0, roll0 = F.state, TURN, #ERRORS, ROLL
    F.state = { factions = {}, rates = F.read_rates() }
    for _, k in ipairs({ "supply", "army_provisions", "escort", "tolls", "bandits", "edicts" }) do F.state.rates[k] = false end
    for _, k in ipairs({ "upkeep", "events", "ai", "spoilage" }) do F.state.rates[k] = true end
    TURN, DILEMMAS = 380000, {}
    local EV = DERPY_MR_FLOWS_EVENTS
    -- a store whose only provisions are grain and salt: every food has one price here, so the tie goes to grain
    local others = {}
    for _, g in ipairs(DERPY_MR_FLOWS_GOODS) do
        if g.use == "provisions" and g.stem ~= "grain" and g.stem ~= "salt" then others[g.stem] = true end
    end
    local function rate(f, r, stem, pct) return math.floor(F.quote(f.iface, r.iface, stem)[pct == 150 and "buy" or "sell"]) end
    -- SMUGGLERS: a level-2 store eats 4 a turn, so 3 is under 2 turns, and 5 turns less what it holds is 17
    local H = faction("e2H", { human = true })
    local s1 = region("e2s", 42000, 0, 400, { grain = 3 }); s1.level, s1.absent = 2, others; own(H, s1, true)
    local gold = math.ceil(17 * rate(H, s1, "grain", 150) * 150 / 10000)
    local o = F.smuggle_offer(H.iface, F.stocks(H.iface))
    eq(o and table.concat({ o.key, o.region, o.use, o.stem, o.n, o.gold }, ","), "smugglers,e2s,provisions,grain,17," .. gold,
       "a store short of food is offered 5 turns of its cheapest food at half again its buying price")
    -- NO SMUGGLERS IN THE FIRST EVENT_GAP TURNS (Workshop report, 2026-11-07): every store starts empty, so every
    -- faction was short on turn 1
    TURN = F.EVENT_GAP
    eq(F.smuggle_offer(H.iface, F.stocks(H.iface)), nil, "no smugglers while the stores are still filling")
    TURN = F.EVENT_GAP + 1
    eq(F.smuggle_offer(H.iface, F.stocks(H.iface)) ~= nil, true, "the turn after the grace they come")
    TURN = 380000
    F.events(H.iface)
    eq(#DILEMMAS .. "," .. (DILEMMAS[1] and DILEMMAS[1].key or ""), "1," .. EV.smugglers.dilemma, "the player is asked")
    answer(H, EV.smugglers.dilemma, "FIRST")
    eq(tostring(TREASURY.e2H) .. "," .. s1.held.grain .. "," .. tostring((BUNDLES.e2s or {})[EV.smugglers.bundle]),
       -gold .. ",20,5", "Buy from them: paid, the grain arrives, and control -3 there for 5 turns")
    s1.held.grain = 8
    eq(F.smuggle_offer(H.iface, F.stocks(H.iface)), nil, "2 turns of food is not short")
    s1.held.grain, s1.level = 0, 15
    o = F.smuggle_offer(H.iface, F.stocks(H.iface))
    eq(o and o.n, 100, "30 a turn would want 150: at most 100")
    local P = faction("e2P", { human = true, gold = gold - 1 })
    local s2 = region("e2p", 42020, 0, 400, { grain = 3 }); s2.level, s2.absent = 2, others; own(P, s2, true)
    eq(F.smuggle_offer(P.iface, F.stocks(P.iface)), nil, "no offer the treasury cannot pay")
    -- MERCHANT GUILD: iron at 80% of the realm's space for it; coal at 70% is not enough
    local G = faction("e2G", { human = true })
    local g1 = region("e2g", 42040, 0, 1000, { iron = 800, coal = 700 }); g1.level = 0; own(G, g1, true)
    o = F.guild_offer(G.iface, F.stocks(G.iface))
    eq(o and o.key .. "," .. o.stem, "guild,iron", "the good above three quarters of its space is offered")
    local G2 = faction("e2F", { human = true })
    own(G2, region("e2f", 42050, 0, 1000, { coal = 700 }), true)
    eq(F.guild_offer(G2.iface, F.stocks(G2.iface)), nil, "70% of its space is not enough")
    -- CHEAP TO ASK (the 1.0 live pass, 2026-11-02: these two cost 455 ms of the events' 506 a round): F.stocks has
    -- read every store, so neither offer reads one again; a store that is not short is never quoted
    s1.held.grain, s1.level = 8, 2
    local gst, hst, reads, stock0, view0 = F.stocks(G.iface), F.stocks(H.iface), 0, F.stock, F.stock_view
    F.stock = function(...) reads = reads + 1; return stock0(...) end
    F.stock_view = function(...) reads = reads + 1; return view0(...) end
    local og, os_ = F.guild_offer(G.iface, gst), F.smuggle_offer(H.iface, hst)
    F.stock, F.stock_view = stock0, view0
    eq(reads .. "," .. tostring(og and og.stem) .. "," .. tostring(os_), "0,iron,nil",
       "the guild and the smugglers read no store F.stocks has read, and answer as before")
    -- THE GOOD IS NAMED: no dilemma target can be a good, so its name is a script value the text reads, keyed by the
    -- player's faction CQI, and the player rides as the target faction
    local loc0 = common.get_localised_string
    common.get_localised_string = function(k) return k == "pooled_resources_display_name_derpy_mr_store_iron" and "Iron" or "" end
    F.events(G.iface)
    local dl = DILEMMAS[#DILEMMAS]
    eq(dl.key .. "," .. dl.faction .. "," .. tostring(CONTEXT_VALUES["derpy_mr_guild_good_" .. G.cqi]),
       EV.guild.dilemma .. "," .. G.cqi .. ",Iron", "the guild's dilemma names its good")
    -- script values are not saved: a load's first tick, with the offer still waiting, names it again
    CONTEXT_VALUES = {}
    do   -- the first tick's army seeding left out: this block's armies are bare stubs
        local n, seed = #LISTENERS, F.provision_seed_all
        F.provision_seed_all = function() end
        F.started = false; F.init()
        for i = #LISTENERS, n + 1, -1 do LISTENERS[i] = nil end
        F.provision_seed_all = seed
    end
    eq(CONTEXT_VALUES["derpy_mr_guild_good_" .. G.cqi], "Iron", "after a load the waiting offer names its good again")
    -- A LINE BREAK IN THE LOC: RPFM's TSV import keeps \n as two characters, CA's loc holds a real one
    do
        local keys0 = DERPY_MR_LOC_KEYS
        DERPY_MR_LOC_KEYS = { ["Line one\nline two"] = "derpy_mr_ui_test" }
        common.get_localised_string = function(k) return k == "derpy_mr_ui_test" and "Ligne un\\nligne deux" or "" end
        F.T_CACHE["Line one\nline two"] = nil
        eq(F.T("Line one\nline two"), "Ligne un\nligne deux", "a loc line break is a real one on screen")
        F.T_CACHE["Line one\nline two"] = nil
        DERPY_MR_LOC_KEYS = keys0
    end
    common.get_localised_string = loc0
    answer(G, EV.guild.dilemma, "FIRST")
    local sale = F.state.sales and F.state.sales.e2G
    eq(sale and sale.stem .. "," .. sale.per .. "," .. sale.left, "iron,20,10", "Sign the contract: 20 a turn for 10 turns")
    local paid = 0
    for _ = 1, 3 do
        paid = paid + math.floor(20 * math.floor(rate(G, g1, "iron") * 120 / 100) / 100)
        F.sales_turn(G.iface)
    end
    eq(g1.held.iron .. "," .. tostring(TREASURY.e2G) .. "," .. sale.left, "740," .. paid .. ",7",
       "three turns sell 60, paid a fifth above the local selling price")
    -- Review Focus 1: the good runs out - what there is sells, and the sale ends
    g1.held.iron = 5
    paid = paid + math.floor(5 * math.floor(rate(G, g1, "iron") * 120 / 100) / 100)
    F.sales_turn(G.iface)
    eq(g1.held.iron .. "," .. tostring(TREASURY.e2G) .. "," .. tostring(F.state.sales.e2G), "0," .. paid .. ",nil",
       "5 left: 5 sold and paid for, and the sale ends")
    F.state.sales.e2G = { stem = "iron", per = 20, left = 2 }; g1.held.iron = 500
    F.sales_turn(G.iface); F.sales_turn(G.iface); F.sales_turn(G.iface)
    eq(g1.held.iron .. "," .. tostring(F.state.sales.e2G), "460,nil", "a sale ends after its turns")
    F.state.sales.e2G = { stem = "iron", per = 20, left = 5 }; lose(G, g1); paid = TREASURY.e2G
    F.sales_turn(G.iface)
    eq(tostring(F.state.sales.e2G) .. "," .. TREASURY.e2G, "nil," .. paid, "its stores captured: no gold, and the sale ends")
    F.state.sales = { a = { stem = "nope", per = 20, left = 3 }, b = { stem = "iron", per = 20, left = 3 }, c = "x",
                      d = { stem = "iron", per = 20, left = 0 } }
    F.sanitize_sales()
    eq(tostring(F.state.sales.a) .. tostring(F.state.sales.c) .. tostring(F.state.sales.d) .. "," .. F.state.sales.b.left,
       "nilnilnil,3", "a saved sale of an unknown good, a broken one and a finished one are dropped on load")
    -- GRAIN ROT: 250 is the safe share of 1000; 400 is 150 over it and rots, 349 is 99 over and does not
    local R = faction("e2R", { human = true })
    local r1 = region("e2r", 42060, 0, 1000, { grain = 400 }); r1.level = 0; own(R, r1, true)
    local r2 = region("e2q", 42080, 0, 1000, { grain = 349 }); r2.level = 0; own(R, r2)
    o = F.rot_offer(R.iface, F.stocks(R.iface))
    eq(o and o.key .. "," .. o.region, "grain_rot,e2r", "the first store 100 over its safe share is offered")
    local function rot(choice, grain)
        r1.held.grain = grain
        F.set_pending("e2R", { key = "grain_rot", region = "e2r" })
        answer(R, EV.grain_rot.dilemma, choice)
        return r1.held.grain
    end
    eq(rot("FIRST", 400) .. "," .. tostring(TREASURY.e2R), "380,-50", "Clean the granary: 50 gold, a twentieth lost")
    eq(rot("SECOND", 400) .. "," .. TREASURY.e2R, "280,-50", "Let it rot: 30% lost, no gold")
    eq(rot("FIRST", 100), 95, "emptied before the answer: a twentieth of what is there now")
    local R2 = faction("e2Q", { human = true, gold = 49 }); own(R2, region("e2o", 42090, 0, 1000, { grain = 400 }), true)
    F.set_pending("e2Q", { key = "grain_rot", region = "e2o" }); answer(R2, EV.grain_rot.dilemma, "FIRST")
    eq(REGIONS.e2o.held.grain .. "," .. tostring(TREASURY.e2Q), "380,nil", "50 gold paid only when the treasury holds it")
    F.state.rates.spoilage = false
    eq(F.rot_offer(R.iface, F.stocks(R.iface)), nil, "no rot while nothing spoils")
    F.state.rates.spoilage = true
    -- A COMPUTER buys from the smugglers and signs with the guild on a winning roll, and never meets Grain rot
    ROLL, DILEMMAS = 1, {}
    local A = faction("e2A")
    local a1 = region("e2a", 42100, 0, 400, { grain = 3 }); a1.level, a1.absent = 2, others; own(A, a1, true)
    F.events(A.iface)
    eq(#DILEMMAS .. "," .. a1.held.grain, "0,20", "a computer buys from the smugglers, unasked")
    local B = faction("e2B")
    local b1 = region("e2b", 42120, 0, 1000, { iron = 800 }); b1.level = 0; own(B, b1, true)
    F.events(B.iface)
    eq(F.state.sales and F.state.sales.e2B and F.state.sales.e2B.stem, "iron", "and signs with the guild")
    b1.held.grain = 400
    eq(F.event_offer(B.iface, "grain_rot", F.stocks(B.iface)), nil, "Grain rot is never a computer's")
    eq(#ERRORS, n0, "Part E stock events: no script errors")
    F.state, TURN, ROLL = state, turn0, roll0
end)()

-- TASK 3: CARAVAN MASTER, TOLL DISPUTE AND BLOCKADE RUNNER
;(function()
    local state, turn0, routes, known, price, n0 = F.state, TURN, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.local_price, #ERRORS
    F.state = { factions = {}, rates = F.read_rates(), ship_seq = 103000 }
    for _, k in ipairs({ "upkeep", "supply", "army_provisions", "escort", "spoilage", "tolls", "edicts" }) do
        F.state.rates[k] = false
    end
    F.state.rates.bandits, F.state.rates.road_danger, F.state.rates.events = true, 20, true
    F.reach_known, F.enemy_cache, F.blockade_known, TURN, DILEMMAS = {}, {}, {}, 400000, {}
    local EV = DERPY_MR_FLOWS_EVENTS
    local Y = 10900
    local H = faction("e3H", { human = true })
    local M, B = faction("e3M"), faction("e3B", { human = true })   -- a player: only a player sets a stock target
    local hr = region("e3h", 0, Y, 2000, { coal = 1000 }); own(H, hr, true)
    local mr = region("e3m", 20, Y, 1000, {}); own(M, mr, true); mr.po = -60
    local br = region("e3b", 40, Y, 1000, {}); own(B, br, true)
    H.partners, B.partners = { B }, { H }
    local road = {}
    for x = 0, 40, 2 do road[#road + 1] = { x, Y } end
    DERPY_MR_TERRAIN_ROUTES = { reach = function() return true, nil, road end, journey = function() return road end }
    -- CARAVAN MASTER: cargo on a road of threat 30 or more; hired, the player's cargo meets nothing for 10 turns
    local c = F.convoy_new(H.iface, B.iface, { coal = 100 }, road)
    c.x, c.threat = 24, 29
    eq(F.caravan_offer(H.iface), nil, "cargo on a road of threat 29: no caravan master")
    c.threat = 40
    local o = F.caravan_offer(H.iface)
    eq(o and o.key, "caravan_master", "cargo on a road of threat 40 brings him")
    local fee = math.floor(F.cargo_value_base(c) * 5 / 100)
    F.set_pending("e3H", o); answer(H, EV.caravan_master.dilemma, "FIRST")
    eq(tostring(TREASURY.e3H) .. "," .. tostring((F.state.road_safe or {}).e3H), -fee .. "," .. TURN + 10,
       "Hire him: a twentieth of the cargo's value, and safe roads until 10 turns on")
    local function road_trouble()   -- the roll, the washout, the region: asked unless the road is safe
        local asked = #DILEMMAS
        ROLLQ, F.state.road_cool = { 1, 3, 1 }, nil
        F.road_event(H.iface, "convoy", c, { 16, Y })
        ROLLQ = nil
        if #DILEMMAS > asked then answer(H, EV.road_washout.dilemma, "SECOND") end
        return #DILEMMAS - asked
    end
    local t0 = TURN
    TURN = t0 + 10
    eq(road_trouble(), 0, "the 10th turn after: nothing on the road")
    TURN = t0 + 11
    eq(road_trouble(), 1, "the 11th: the road is as before")
    local P = faction("e3P", { human = true, gold = fee - 1 })
    own(P, region("e3p", 0, Y + 200, 1000, {}), true)
    local pc = F.convoy_new(P.iface, B.iface, { coal = 100 }, road)
    pc.threat = 40
    F.set_pending("e3P", { key = "caravan_master" }); answer(P, EV.caravan_master.dilemma, "FIRST")
    eq(tostring(TREASURY.e3P) .. "," .. tostring((F.state.road_safe or {}).e3P), "nil,nil", "no gold, no caravan master")
    F.convoy_drop(c); F.convoy_drop(pc)
    F.state.road_safe = { e3H = 5, x = "bad", [7] = 3 }; F.sanitize_road()
    eq(F.state.road_safe.e3H .. "," .. tostring(F.state.road_safe.x), "5,nil", "a saved safe turn keeps only a number")
    -- TOLL DISPUTE: a neighbour that paid 50 in tolls last turn; 49 is not enough
    F.state.rates.tolls, F.state.rates.edicts = true, true
    local N1, N2 = faction("e3N"), faction("e3O")
    TURN = TURN - 1
    F.book_gold("tolls", "e3H", "e3N", "got", 49)
    TURN = TURN + 1
    eq(F.toll_offer(H.iface), nil, "a neighbour that paid 49: no dispute")
    TURN = TURN - 1
    F.book_gold("tolls", "e3H", "e3N", "got", 1); F.book_gold("tolls", "e3H", "e3O", "got", 80)
    TURN = TURN + 1
    o = F.toll_offer(H.iface)
    eq(o and o.key .. "," .. o.target, "toll_dispute,e3N", "the first by key that paid 50 or more")
    -- roads set Open since, or Closed: the realm takes no tolls now, so there is nothing to dispute
    F.state.edicts = { e3H = { roads = { o = "open", at = TURN - 1 } } }
    eq(F.toll_offer(H.iface), nil, "roads already Open: no dispute")
    F.state.edicts = { e3H = { roads = { o = "closed", at = TURN - 1 } } }
    eq(F.toll_offer(H.iface), nil, "nor Closed")
    F.state.edicts = nil
    -- Review Focus 2: the Roads edict changed 4 turns ago and waits 6 more; accepting opens the roads anyway
    F.state.edicts = { e3H = { roads = { o = "closed", at = TURN - 4 } } }
    eq(F.edict_set(H.iface, "roads", "open"), false, "the edict waits")
    F.set_pending("e3H", o); answer(H, EV.toll_dispute.dilemma, "FIRST")
    local d = DIPLO[#DIPLO]
    eq(F.edict("e3H", "roads") .. "," .. F.edict_wait("e3H", "roads") .. "," .. d[1] .. "," .. d[2] .. "," .. d[3],
       "open,10,e3H,e3N," .. F.DIPLO_BONUS, "Open the roads: the edict is Open, waits 10 turns, and they think better of you")
    F.set_pending("e3H", o); answer(H, EV.toll_dispute.dilemma, "SECOND")
    d = DIPLO[#DIPLO]
    eq(d[1] .. "," .. d[2] .. "," .. d[3], "e3H,e3N," .. -F.DIPLO_BONUS, "Keep the tolls: they think worse of you")
    -- BLOCKADE RUNNER: an enemy army on the road to a partner
    F.state.rates.tolls, F.state.edicts = true, nil
    M.allies = { e3H = true }   -- no toll on the runner's road: the treasury shows the runner's tenth alone
    local X = faction("e3X"); own(X, region("e3x", 60, Y + 60, 1000, {}), true)
    war(X, B)
    X.armies = { field(X, 30, Y + 3, 39001) }
    F.set_stock_policy("e3B", "coal", "target", "1000")
    local PR = { e3h = 1000, e3b = 5000 }
    F.local_price = function(v) return PR[v.region:name()] end
    local cut = TREASURY.e3H or 0
    -- a blockaded pair that would send nothing anyway brings no runner
    PR.e3b = 1000
    F.trade(H.iface)
    eq(tostring(F.blockaded("e3H", "e3B")) .. "," .. tostring(F.runner_offer(H.iface)), "e3X,nil",
       "no price gain, nothing to run: no runner")
    PR.e3b = 5000
    F.trade(H.iface)
    eq(#F.convoys() .. "," .. tostring(F.blockaded("e3H", "e3B")), "0,e3X", "the pair is blockaded: nothing leaves")
    o = F.runner_offer(H.iface)
    eq(o and o.key .. "," .. o.target, "blockade_runner,e3B", "the blockaded partner brings the runner")
    -- the trade agreement ended before the answer: nothing leaves, nothing is paid
    H.partners = {}
    F.set_pending("e3H", o); answer(H, EV.blockade_runner.dilemma, "FIRST")
    eq(#F.convoys() .. "," .. tostring(TREASURY.e3H or 0), "0," .. cut, "a partner that no longer trades with you: no runner")
    H.partners = { B }
    F.set_pending("e3H", o); answer(H, EV.blockade_runner.dilemma, "FIRST")
    local sent = F.convoys()[1]
    local due = sent and math.floor(F.cargo_value_base(sent) * 10 / 100)
    eq(#F.convoys() .. "," .. tostring(sent and sent.buyer) .. "," .. tostring(TREASURY.e3H), "1,e3B," .. cut - (due or 0),
       "Pay the runner: this turn's goods leave, for a tenth of their value")
    eq(tostring(F.blockaded("e3H", "e3B")), "nil", "the goods got through: the panel and the map show no blockade")
    -- Review Focus 3: a second answer the same turn sends nothing and pays nothing
    F.set_pending("e3H", o); answer(H, EV.blockade_runner.dilemma, "FIRST")
    eq(#F.convoys() .. "," .. TREASURY.e3H, "1," .. cut - due, "a second runner the same turn: nothing more")
    -- goods already sent to that partner this turn: a blockade seen after them brings no runner (seen 2026-11-03,
    -- offered and paid for, and its answer sent nothing)
    F.record_blockade("e3H", "e3B", "e3X")
    eq(F.runner_offer(H.iface), nil, "goods already sent this turn: no runner")
    F.record_blockade("e3H", "e3B", nil)
    -- the army gone before the answer: the convoy still leaves, and the tenth is still paid
    TURN = TURN + 1; F.enemy_cache = {}
    F.trade(H.iface)
    eq(#F.convoys(), 1, "blockaded again the next turn")
    -- the turn's blockade is saved: after a reload the panel, the map and the duty still see it
    SAVED = {}; cm.saving_game_callbacks[1]({})
    F.blockade_known = {}; cm.loading_game_callbacks[1]({})
    eq(tostring(F.blockaded("e3H", "e3B")), "e3X", "a reload keeps the turn's blockade")
    local good = SAVED.derpy_mr_flows.blockades
    SAVED.derpy_mr_flows.blockades = { ["e3H>e3B"] = { by = 3, turn = "x" }, [4] = {}, junk = "y" }
    cm.loading_game_callbacks[1]({})
    eq(next(F.blockade_known), nil, "a damaged saved blockade list loads as none")
    SAVED.derpy_mr_flows.blockades = good; cm.loading_game_callbacks[1]({})
    X.armies, F.enemy_cache = {}, {}
    o = F.runner_offer(H.iface)
    F.set_pending("e3H", o); answer(H, EV.blockade_runner.dilemma, "FIRST")
    local sent2 = F.convoys()[2]
    eq(#F.convoys() .. "," .. TREASURY.e3H, "2," .. cut - due - math.floor(F.cargo_value_base(sent2 or {}) * 10 / 100),
       "the army left before the answer: the goods leave and the tenth is paid")
    TURN = TURN + 1
    eq(F.runner_offer(H.iface), nil, "a blockade from last turn brings no runner")
    eq(#ERRORS, n0, "Part E road events: no script errors")
    F.local_price, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.blockade_known = price, routes, known, {}
    F.state, TURN = state, turn0
end)()

-- NOTHING FROM THE ENGINE IS KEPT (the 1.0 live pass, 2026-11-02): a script interface is good for the script entry
-- that asked for it and freed memory after ("Character interfaces are volatile and may not be stored over time", CA's
-- scripting docs). F.enemy_cache kept the turn's enemy factions and forces, and the map's next plan refresh
-- (R.renew_plan > F.trade > F.trade_pair > F.blockade) called e.f:is_null_interface() on one: a native crash at
-- Warhammer3.exe+0x118D937. Here an interface remembers the entry that made it and refuses a call from a later one.
;(function()
    local state, turn0, routes, known, n0 = F.state, TURN, DERPY_MR_TERRAIN_ROUTES, F.reach_known, #ERRORS
    F.state = { factions = {}, rates = F.read_rates(), ship_seq = 99500 }
    F.reach_known, TURN, F.enemy_cache, F.blockade_known = {}, 340000, {}, {}
    local ENTRY = 1
    local function volatile(t, stamp)
        if type(t) ~= "table" then return t end
        return setmetatable({}, { __index = function(_, k)
            local v = t[k]
            if type(v) ~= "function" then return v end
            return function(_, ...)
                if stamp ~= ENTRY then error("an interface from script entry " .. stamp .. " used in entry " .. ENTRY, 2) end
                return volatile(v(t, ...), stamp)
            end
        end })
    end
    local Y = 10300
    local A, B, X = faction("sk1A"), faction("sk1B", { human = true }), faction("sk1X")
    own(A, region("sk1A1", 0, Y, 1000, {}), true)
    own(B, region("sk1B1", 20, Y, 1000, {}), true)
    own(X, region("sk1X1", 60, Y + 60, 1000, {}), true)
    war(X, A)
    X.armies = { field(X, 10, Y + 1, 34001) }
    local road = {}
    for x = 0, 20, 2 do road[#road + 1] = { x, Y } end
    local wars = A.iface.factions_at_war_with
    A.iface.factions_at_war_with = function(self) return volatile(wars(self), ENTRY) end
    eq(F.blockade(A.iface, B.iface, road), "sk1X", "entry 1: the army on the road blockades")
    ENTRY = 2   -- the map's next plan refresh, the same turn
    local ok, by = pcall(F.blockade, A.iface, B.iface, road)
    eq(ok, true, "entry 2 reads no interface entry 1 kept (" .. tostring(by) .. ")")
    eq(by, "sk1X", "entry 2 still sees the army")
    ENTRY = 3   -- a convoy beside the army, at a later turn start
    local ok2, captor, force = pcall(F.captor, A.iface, { x = 10, y = Y + 1 })
    eq(ok2, true, "F.captor reads no kept interface (" .. tostring(captor) .. ")")
    eq(captor and captor:name(), "sk1X", "the captor is the army's faction")
    eq(force and force:command_queue_index(), 35001, "and the force is its army")
    -- a force gone since the list was made is passed over: it is looked up again by its number
    X.armies = {}
    eq(F.captor(A.iface, { x = 10, y = Y + 1 }), nil, "a force destroyed this turn captures nothing")
    A.iface.factions_at_war_with = wars
    eq(#ERRORS, n0, "nothing kept: no script errors")
    F.state, TURN, DERPY_MR_TERRAIN_ROUTES, F.reach_known, F.enemy_cache, F.blockade_known = state, turn0, routes, known, {}, {}
end)()

-- NOTHING KEPT, the whole module: once every test above has run, no engine interface is reachable from F through its
-- tables or its functions' upvalues. A stub interface stands in for the engine's userdata: a table with its own
-- is_null_interface.
;(function()
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
    -- the turn's caches filled first: an enemy army in the field
    local A, X = faction("sk2A"), faction("sk2X")
    own(A, region("sk2A1", 0, 10400, 1000, {}), true); own(X, region("sk2X1", 40, 10400, 1000, {}), true)
    war(A, X); X.armies = { field(X, 20, 10400, 34101) }
    eq(#F.enemy_armies(A.iface), 1, "the walk sees a filled enemy list")
    walk(F, "F")
    table.sort(found)
    eq(table.concat(found, " "), "", "engine interfaces kept in the flows module")
end)()

print("harness ok")
