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
    local r = { key = key, x = x, y = y, cap = cap, held = held or {}, owner = nil, readable = true, level = 1 }
    local settlement = {
        is_null_interface = function() return false end,
        cqi = function() return 0 end,
        logical_position_x = function() return r.x end,
        logical_position_y = function() return r.y end,
        primary_slot = function() return { building = function()
            return { building_level = function() return r.level end } end } end,
    }
    r.iface = {
        __r = r,
        is_null_interface = function() return false end,
        name = function() return key end,
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
                regions = {}, war = {}, partners = {}, has = opts.has or {}, home = nil, cqi = NEXT_CQI }
    f.iface = {
        is_null_interface = function() return false end,
        name = function() return name end,
        command_queue_index = function() return f.cqi end,
        is_human = function() return f.human end,
        subculture = function() return opts.sc or "wh_main_sc_emp_empire" end,
        is_rebel = function() return f.rebel end,
        is_dead = function() return false end,
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
F.rates(); F.state.rates.upkeep = false

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
MP = false; get_mct = nil; F.state.rates = nil; F.rates()

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
F.request("sP", "send", "coal", "s3")
eq(s1.held.coal, 38, "the source loses what was sent"); eq(s3.held.coal, 200, "the target gains what arrived")
eq(F.book("sP").now.coal.moved_out, 12, "booked out"); eq(F.book("sP").now.coal.moved_in, 10, "and in")
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
ui_trigger(sP.cqi, SENT[2][2]); eq(s4.held.brass, 34, "my own does")
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

-- ---- the run-cost counter (Task 7 reads it) --------------------------------------------
local counters = F.cost
turn_start(tA); eq(F.cost, counters, "a computer-run turn start keeps counting into the same round")
turn_start(hum); eq(F.round_cost, counters, "a human's turn start hands the round's counters over")
eq(F.cost.raid, 0, "and starts new ones")

eq(#ERRORS, 0, "script errors: " .. table.concat(ERRORS, "; "))
print("harness ok")
