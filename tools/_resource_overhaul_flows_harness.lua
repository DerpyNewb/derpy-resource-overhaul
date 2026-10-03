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
local CCO_MADE = ""
local function pool(r, stem)
    local key = "derpy_mr_store_" .. stem
    return { is_null_interface = function() return false end, key = function() return key end,
             value = function() return r.held[stem] or 0 end,
             maximum_value = function() return r.cap end }
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
                armies = {} }
    f.iface = {
        is_null_interface = function() return false end,
        name = function() return name end,
        command_queue_index = function() return f.cqi end,
        is_human = function() return f.human end,
        subculture = function() return opts.sc or "wh_main_sc_emp_empire" end,
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
REPAIRED = {}                     -- Restore: the slots cm repaired   -- phase 5: the shipment markers on the map; a spot CA cannot find
local FIRST, LISTENERS = {}, {}
cm = {
    saving_game_callbacks = {}, loading_game_callbacks = {},
    add_saving_game_callback = function() error("the save callback must go first in CA's list") end,
    add_loading_game_callback = function() error("the load callback must go first in CA's list") end,
    add_first_tick_callback = function(_, fn) FIRST[#FIRST + 1] = fn end,
    callback = function() end,
    repeat_real_callback = function() end,
    get_local_faction_name = function() return "hum" end,
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
    apply_effect_bundle = function(_, b, fk, turns)
        FBUNDLES[fk] = FBUNDLES[fk] or {}
        FBUNDLES[fk][b] = turns
    end,
    treasury_mod = function(_, fk, n)
        if n <= 0 then error("treasury_mod takes a positive amount") end
        TREASURY[fk] = (TREASURY[fk] or 0) + n
    end,
    -- phase 6: what the events hand the engine, recorded
    trigger_dilemma_with_targets = function(_, fcqi, key, tf, _sf, ch, mf, rg, st, cb)
        if type(cb) ~= "function" then error("trigger_dilemma_with_targets takes its callback") end
        DILEMMAS[#DILEMMAS + 1] = { fcqi = fcqi, key = key, faction = tf, character = ch, force = mf, region = rg }
        return true
    end,
    apply_dilemma_diplomatic_bonus = function(_, a, b, n) DIPLO[#DIPLO + 1] = { a, b, n } end,
    add_experience_to_units_commanded_by_character = function(_, lookup, n) RANKS[#RANKS + 1] = { lookup, n } end,
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
common = {
    get_localised_string = function() return "" end,
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
TURN = 7; turn_start(hum)
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
dofile("__MCT__")
local opt = MCT.derpy_more_resources.options
for k, d in pairs(DERPY_MR_FLOWS_DEFAULTS) do
    eq(opt[k] ~= nil, true, "the MCT file has an option for " .. k)
    eq(opt[k].value, d, "the MCT default for " .. k .. " is the script's")
end
F.state = { factions = {} }
opt.raid.value, opt.ai.value = 30, false
eq(F.rates().raid, 30, "a new campaign takes MCT's raid share")
eq(F.rates().ai, false, "an unticked box stays unticked")
opt.raid.value = 40; eq(F.rates().raid, 30, "frozen: a later MCT change does not reach a running campaign")
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
opt.upkeep.value = false; eq(F.rates().upkeep, true, "and the new one is frozen too")
get_mct = nil; F.state.rates = nil; F.rates()
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
eq(st.wait, 10, "ready in 10 turns")
F.request("oP", "order", "festival"); eq(o1.held.silk, 300, "and a request does nothing")
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
EX = { sell_price = function(res) eq(res, "res_derpy_coal", "asked by resource key"); return 51 end }
eq(F.sale(lP.iface, "coal").gold, 510, "the Exchange's price when it is loaded")
EX = { sell_price = function() error("the Exchange broke") end }
eq(F.sale(lP.iface, "coal").price, 3, "the fixed rate when it errors")
EX = { sell_price = function() return 0 end }; eq(F.sale(lP.iface, "coal").price, 3, "or prices at nothing")
EX = nil
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
local function host(cqi, units, kind)
    local mf = { is_armed_citizenry = function() return kind == "garrison" end,
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
-- a tie by resource key, as F.draw_realm takes them - for the Spending tab's icon
eq(st5.pay.building.stem, "timber", "Materials pays with the fullest building material")
eq(st5.pay.building.n, 30, "and says how much of it there is")
eq(st5.pay.mounts.n, 0, "a use the capital holds none of still names a good")
eq(type(st5.pay.mounts.stem), "string", "so the tab has an icon to grey")
pc.held.marble = 30
eq(F.supply_state(pP.iface, "pc").pay.building.stem, "marble", "a tie goes by resource key, as the payment takes it")
pc.held.marble = 4
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

-- ---- the run-cost counter (Task 7 reads it) --------------------------------------------
local counters = F.cost
turn_start(tA); eq(F.cost, counters, "a computer-run turn start keeps counting into the same round")
turn_start(hum); eq(F.round_cost, counters, "a human's turn start hands the round's counters over")
eq(F.cost.raid, 0, "and starts new ones")

eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))
print("harness ok")
