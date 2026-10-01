-- Derpy More Resources' AI builder (derpy_more_resources_ai.lua), run against stub factions and
-- regions. gen_more_resources.py --selftest writes the script to a temp file and puts its path
-- in place of the marker below. Every case is one the game could hand it.
core = nil
out = nil
local TURN = 1
local BUILT, UPGRADED = {}, {}
local REFUSE_ADD = {}            -- region key -> true: the engine finds no slot that takes it

local function slot(name)
    local s = { name_ = name }
    s.has_building = function() return s.name_ ~= nil end
    s.building = function() return { name = function() return s.name_ end } end
    return s
end

local REGIONS = {}
local function region(key, tier, buildings)
    local slots = { slot("primary") }
    for _, b in ipairs(buildings or {}) do slots[#slots + 1] = slot(b) end
    local r = { key = key, slots = slots }
    r.name = function() return key end
    r.settlement = function() return { primary_slot = function() return { building = function()
        return { building_level = function() return tier end } end } end } end
    r.slot_list = function() return {
        num_items = function() return #r.slots end,
        item_at = function(_, i) return r.slots[i + 1] end } end
    REGIONS[key] = r
    return r
end

local function faction(name, culture, gold, regions, human)
    local f = { gold = gold }
    f.name = function() return name end
    f.culture = function() return culture end
    f.treasury = function() return f.gold end
    f.is_human = function() return human == true end
    f.is_dead = function() return false end
    f.region_list = function() return {
        num_items = function() return #regions end,
        item_at = function(_, i) return regions[i + 1] end } end
    return f
end

local FACTIONS = {}
cm = {
    model = function() return { turn_number = function() return TURN end } end,
    add_building_to_settlement = function(_, rkey, building)
        if REFUSE_ADD[rkey] then return end
        local r = REGIONS[rkey]
        r.slots[#r.slots + 1] = slot(building)
        BUILT[#BUILT + 1] = building
    end,
    instantly_upgrade_building_in_region = function(_, s, building)
        s.name_ = building
        UPGRADED[#UPGRADED + 1] = building
    end,
    treasury_mod = function(_, fname, n) FACTIONS[fname].gold = FACTIONS[fname].gold + n end,
}

dofile("__SCRIPT__")

local function first_key(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks[1], ks[2]
end
local G1, G2 = first_key(MR_AI.REGIONS.gromril)
local CH = MR_AI.CHAIN.gromril.wh_main_dwf_dwarfs
assert(G1 and G2 and CH, "the data has no gromril region pair or no dwarf chain")

-- 1. A Dwarf faction with one lore region (tier 2) and one that is not: it builds in the lore
--    region, pays CA's price, and leaves the other alone.
local lore = region(G1, 2)
local plain = region("not_a_lore_region", 5)
local dwf = faction("dwf_a", "wh_main_dwf_dwarfs", 10000, { plain, lore })
FACTIONS.dwf_a = dwf
local did = MR_AI.act(dwf)
assert(did == "build " .. CH .. "_1 " .. G1, "first action: " .. tostring(did))
assert(dwf.gold == 10000 - MR_AI.COST[1], "charged " .. (10000 - dwf.gold))
assert(#plain.slots == 1, "built in a region where the building makes nothing")

-- 2. Next action upgrades it, the tier allowing level 2.
did = MR_AI.act(dwf)
assert(did == "upgrade " .. CH .. "_2 " .. G1, "second action: " .. tostring(did))
assert(dwf.gold == 10000 - MR_AI.COST[1] - MR_AI.COST[2], "upgrade charge")

-- 3. Level 3 needs tier 3; at tier 2 nothing happens and nothing is charged.
local before = dwf.gold
did = MR_AI.act(dwf)
assert(did == nil and dwf.gold == before, "upgraded past the settlement tier: " .. tostring(did))

-- 4. The reserve: 1.5x the price is not enough.
local poor_r = region(G2, 3)
local poor = faction("dwf_poor", "wh_main_dwf_dwarfs", MR_AI.COST[1] * MR_AI.RESERVE - 1, { poor_r })
FACTIONS.dwf_poor = poor
assert(MR_AI.act(poor) == nil and #poor_r.slots == 1, "spent below the reserve")

-- 5. The engine finds no slot: no building, no charge.
poor.gold = 100000
REFUSE_ADD[G2] = true
assert(MR_AI.act(poor) == nil and poor.gold == 100000, "charged for a building that never appeared")
REFUSE_ADD[G2] = nil

-- 6. Another race in a gromril region builds nothing (gromril is Dwarf-only).
local emp_r = region("emp_owned_" .. G2, 3)
MR_AI.REGIONS.gromril["emp_owned_" .. G2] = true
local emp = faction("emp_a", "wh_main_emp_empire", 100000, { emp_r })
FACTIONS.emp_a = emp
assert(MR_AI.act(emp) == nil and #emp_r.slots == 1, "an Empire faction built gromril")

-- 7. Humans are never touched, even on a due turn.
local me = faction("me", "wh_main_dwf_dwarfs", 100000, { region(G2 .. "_h", 3) }, true)
FACTIONS.me = me
MR_AI.REGIONS.gromril[G2 .. "_h"] = true
for t = 1, MR_AI.PACE do
    TURN = t
    assert(MR_AI.turn(me) == nil, "acted for a human")
end

-- 8. The pace: exactly one turn in PACE is due for a faction.
local due = 0
for t = 1, MR_AI.PACE do if MR_AI.due("dwf_a", t) then due = due + 1 end end
assert(due == 1, "due " .. due .. " times in " .. MR_AI.PACE .. " turns")

-- 9. A shared prefix is not a level: black_lotus_def_1 is not black_lotus level "def_1".
assert(MR_AI.level_in("derpy_mr_bld_black_lotus", "derpy_mr_bld_black_lotus_def_1") == nil, "prefix read as level")
assert(MR_AI.level_in("derpy_mr_bld_black_lotus_def", "derpy_mr_bld_black_lotus_def_2") == 2, "level misread")

-- 10. An error inside one faction's action is caught and logged, not thrown into the event.
local broken = faction("broken", "wh_main_dwf_dwarfs", 100000, { lore })
broken.region_list = function() error("boom") end
for t = 1, MR_AI.PACE do TURN = t; MR_AI.turn(broken) end

print(string.format("harness ok: built %d, upgraded %d; reserve, tier, no-slot, wrong race, human, pace, prefix and error cases",
    #BUILT, #UPGRADED))
