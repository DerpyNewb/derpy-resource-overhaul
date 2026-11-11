-- Run from the workspace root with Lua 5.1.
math.huge = nil   -- not safe to assume in the game's Lua (2026-10-21 handoff): the runtime must not need it
core = { add_listener = function() end }
-- a map with no regions until a test gives it some: R.advance asks for the model whenever a search has an avoid
local NO_MAP = function() return {} end
cm = { add_first_tick_callback = function() end, model = NO_MAP }
cm.log_to_dis=function(_,x,y) return x,y end
out = function() end
dofile('Modding Files/source/resource_overhaul/terrain_routes.lua')
local R = DERPY_MR_TERRAIN_ROUTES
R.vehicles={
    industrial={land='land_chd',sea='sea_chd'},
    human={land='land_wood',sea='sea_emp'},
    ['*']={land='land_wood',sea='sea_emp'}
}
cm.get_faction=function(_,key) return {is_null_interface=function() return false end,
    culture=function() return key=='seller' and 'industrial' or 'human' end} end
assert(R.vehicle('seller',false)=='land_chd' and R.vehicle('seller',true)=='sea_chd','industrial faction needs its own cart and ship')
assert(R.vehicle('buyer',true)=='sea_emp','incoming traffic must use the supplier culture')
assert(R.vehicle(nil,true)==nil,'missing ownership retains the legacy fallback')
R.vehicles={}
local switches = {route_agreements=false}
DERPY_MR_FLOWS = {mct=function(k) return switches[k] end}
assert(not R.shown('agreements') and R.shown('contracts'), 'route visibility defaults or switches lost')
local stopped = {}
DERPY_MR_FLOWS.stopped=function(f,dir,stem) return stopped[f..dir..stem]==true end
DERPY_MR_FLOWS_GOODS={{stem='grain'},{stem='iron'}}
local goods=R.goods('seller','buyer')
assert(#goods==2 and goods[1]=='grain', 'enabled trade resources must have stable icon order')
stopped.sellerexportgrain=true
goods=R.goods('seller','buyer')
assert(#goods==1 and goods[1]=='iron', 'stopped exports still advertised by carts')
stopped.buyerimportiron=true
assert(#R.goods('seller','buyer')==0, 'stopped imports still advertised by carts')
local reads=0
DERPY_MR_FLOWS.trade=function(f,preview)
    assert(preview,'display must never commit a trade')
    reads=reads+1
    return {buyer={'grain'}}
end
cm.get_faction=function(_,key) return key end
local plans={}
goods=R.carried({'grain','iron'},'seller','buyer',plans)
R.carried({'grain'},'seller','buyer',plans)
assert(#goods==1 and goods[1]=='grain' and reads==1,'icons must use allocator preview once per exporter')
assert(#R.carried({'grain'},'seller','other',plans)==0,'goods must be destined for this recipient')
DERPY_MR_FLOWS=nil
local trunk = {{0,0},{0,1},{0,2},{0,3},{0,4}}
local seen = {}
local visible = R.unshared(trunk, seen)
assert(visible[1] and visible[5], 'first road must retain its complete trunk')
visible = R.unshared({{0,4},{0,3},{0,2},{0,1},{0,0}}, seen)
assert(next(visible)==nil, 'reverse traffic duplicated the shared trunk')
visible = R.unshared({{0,1},{0,2},{0,3},{1,3},{2,3}}, seen)
assert(not visible[1] and not visible[2] and visible[3] and visible[4] and visible[5],
       'offset shared road must merge until its branch')
visible = R.unshared({{-1,2},{0,2},{1,2}}, seen)
assert(visible[2], 'crossing roads must retain their separate directions')
visible = R.unshared({{1,0},{1,1},{1,2}}, seen)
assert(visible[1] and visible[2], 'nearby parallel roads must stay on their own tiles')
local waiting={path=trunk}
local leading={path=trunk,distance=2,active=true}
assert(not R.can_depart(waiting,{leading}), 'never dispatch into an occupied shared road')
local arriving={path=trunk,reverse=true}
assert(R.can_depart(arriving,{leading}),'opposite traffic must use its separate lane')
assert(not R.can_depart({path={{-1,2},{0,2},{1,2}}},{leading}),'crossing junctions must still wait for clearance')
local reversed={trunk[5],trunk[4],trunk[3],trunk[2],trunk[1]}
assert(R.can_depart({path=reversed},{leading}),'physical direction must not depend on path table order')
local tight={{0,0},{1,0},{0,1}}
assert(not R.can_depart({path=tight,reverse=true},{{path=tight,distance=0,active=true}}),
       'opposing carts must take turns through a narrow sharp bend')
assert(R.can_depart({path={{4,0},{4,1}}},{leading}), 'disjoint roads may carry traffic together')
leading.active=false
assert(R.can_depart(waiting,{leading}), 'arrived carts must release their shared road')
-- Spacing in time, not the whole road: a hub every route shares let one cart through at a time.
local long={}
for y=0,19 do long[#long+1]={0,y} end
assert(not R.can_depart({path=long},{{path=long,distance=R.GAP-2,active=true}}),'a follower left inside the gap')
assert(R.can_depart({path=long},{{path=long,distance=R.GAP,active=true}}),'a follower must leave once its leader is the gap ahead')
local function branch(x) local p={} for i=3,1,-1 do p[#p+1]={x*i,0} end for y=0,8 do p[#p+1]={0,y} end return p end
assert(not R.can_depart({path=branch(1)},{{path=branch(-1),distance=0,active=true}}),'two branches reached their junction together')
assert(R.can_depart({path=branch(1)},{{path=branch(-1),distance=R.GAP,active=true}}),'a later branch must merge behind the gap')
local g = { w = 5, h = 5, data = string.rep('/', 25), bridges = {} }
local network = {}
for y=0,4 do network[R.index(g,1,y)]=true end
local parallel = {{2,0},{2,1},{2,2},{2,3},{2,4}}
local bundled = R.bundle(parallel,network,g)
local joined = false
for i=2,#bundled-1 do joined = joined or bundled[i][1]==1 end
assert(joined, 'nearby parallel roads must actually join the shared corridor')
assert(bundled[1][1]==2 and bundled[#bundled][1]==2, 'bundling moved a settlement endpoint')
local blocked = {w=5,h=5,data=string.rep('/',5)..'/AA//'..'/AA//'..'/AA//'..string.rep('/',5),bridges={}}
bundled = R.bundle(parallel,network,blocked)
for _,point in ipairs(bundled) do
    assert(point[1]~=1 or point[2]==0 or point[2]==4, 'bundling crossed an impassable corridor')
end
bundled = R.bundle(parallel,network,g,function(x) return x==1 end)
for _,point in ipairs(bundled) do assert(point[1]~=1,'bundling crossed hostile land') end
-- A trunk four hexes off the raw road sat outside the corridor, so the road ran beside it as a braid.
local wide = { w = 12, h = 20, data = string.rep('/', 240), bridges = {} }
local trunk4, raw4, on = {}, {}, 0
for y=0,19 do trunk4[R.index(wide,5,y)]=true raw4[#raw4+1]={1,y} end
for _,point in ipairs(R.bundle(raw4,trunk4,wide)) do if point[1]==5 then on=on+1 end end
assert(on>=10,'a road four hexes from a trunk must join it, not run beside it')
local fork_grid={w=16,h=40,data=string.rep('/',640),bridges={}}
local fork,trunk6,joined6={},{},0
for y=0,29 do fork[#fork+1]={1,y};trunk6[R.index(fork_grid,7,y)]=true end
for _,point in ipairs(R.bundle(fork,trunk6,fork_grid)) do if point[1]==7 then joined6=joined6+1 end end
assert(joined6>=15,'a shallow fork needs a connected corridor to its nearby trunk')
local function solve(a, b, limit)
    local job = R.start(g, a, b)
    for _ = 1, limit or 100 do
        local done, path = R.advance(job, 2)
        if done then return path end
    end
    error('unbounded route work')
end
local p = solve({1, 2}, {3, 2})
assert(p and p[1][1] == 1 and p[#p][1] == 3)
g.data = string.rep('/', 5) .. '//A//' .. '//A//' .. '//A//' .. '//A//'
p = solve({1, 2}, {3, 2})
local gap = false
for _, point in ipairs(p) do
    assert(not (point[1] == 2 and point[2] ~= 0), 'route crossed blocked terrain')
    gap = gap or (point[1] == 2 and point[2] == 0)
end
assert(gap, 'route did not go around wall')
g.data = string.rep('A', 25)
assert(solve({1, 2}, {3, 2}) == nil)
assert(solve({-1, 2}, {3, 2}) == nil)
assert(solve({1, 2}, {5, 2}) == nil)
g.bridges[12] = {14}
assert(solve({1, 2}, {3, 2}), 'verified bridge was ignored')

-- Hostile land is a cost, not a wall: x = 2 is enemy territory from y = 1 up.
g.data, g.bridges = string.rep('/', 25), {}
local function enemy(x, y) return x == 2 and y >= 1 end
local function crossings(path) local n = 0; for _, q in ipairs(path) do if enemy(q[1], q[2]) then n = n + 1 end end; return n end
local function solve_avoiding(a, b)
    local job = R.start(g, a, b, enemy)
    for _ = 1, 100 do local done, path = R.advance(job, 2); if done then return path end end
end
assert(#solve({1, 1}, {3, 1}) == 3, 'open ground should go straight')
p = solve_avoiding({1, 1}, {3, 1})
assert(p and crossings(p) == 0 and #p == 5, 'route crossed enemy land with a short detour open')
p = solve_avoiding({1, 4}, {3, 4})
assert(p and crossings(p) == 1, 'route should still cross when the detour is far longer')
local function fac(name, war, attitude, rebel)
    return { name = function() return name end, is_null_interface = function() return false end, is_rebel = function() return rebel == true end,
             at_war_with = function() return war == true end, diplomatic_attitude_towards = function() return attitude or 0 end }
end
local trader = fac('trader')
-- a search looks its parties up again by key (R.avoider keeps no interface); as CA's, a faction comes back as it is
cm.get_faction = function(_, key)
    if type(key) ~= 'string' then return key end
    return key == 'trader' and trader or fac(key)
end
assert(R.hostile(fac('trader', true, -500, true), {trader}) == false, 'a party is never hostile to its own route')
assert(R.hostile(fac('x', true), {trader}) and R.hostile(fac('x', false, 0, true), {trader}), 'war and rebels')
assert(R.hostile(fac('x', false, R.AGGRESSIVE), {trader}) and not R.hostile(fac('x', false, R.AGGRESSIVE + 1), {trader}),
       'aggressive starts at very unfriendly')
-- TRADE EDICTS (Part B): a faction whose Roads edict is Closed is hostile land to every road but its own.
assert(not R.hostile(fac('closer'), {trader}), 'no flows script: the edict is not read')
DERPY_MR_FLOWS = { edict = function(f, w) return w == 'roads' and (f == 'closer' and 'closed' or 'tolled') or nil end }
assert(R.hostile(fac('closer'), {trader}), 'Closed roads are hostile to foreign trade')
assert(not R.hostile(fac('closer'), {trader, fac('closer')}), 'but not to its own')
assert(not R.hostile(fac('opener'), {trader}), 'Tolled roads are not')
DERPY_MR_FLOWS = { mct = function() return nil end }
assert(not R.hostile(fac('closer'), {trader}), 'a flows script without edicts reads none')
DERPY_MR_FLOWS = nil

-- TRADE REACH: enemy land is a wall and the road has a length limit. The detour from (1,4) to (3,4) round
-- the enemy column is 10 steps; straight through it is 2.
local function solve_walled(a, b, max)
    local job = R.start(g, a, b, enemy)
    job.wall, job.max = true, max
    local done, path
    repeat done, path = R.advance(job, 1000) until done
    return path
end
p = solve_walled({1, 4}, {3, 4})
assert(p and crossings(p) == 0 and #p == 11, 'a wall must be walked round, however long the way')
assert(solve_walled({1, 4}, {3, 4}, 10) and not solve_walled({1, 4}, {3, 4}, 9), 'a road longer than its limit is no road')
local function settled(x, y) return { owning_faction = function() return trader end, settlement = function()
    return { logical_position_x = function() return x end, logical_position_y = function() return y end } end } end
local enemy_land, open_land = { is_null_interface = function() return false end, name = function() return 'enemy_land' end,
                                owning_faction = function() return fac('x', true) end },
                              { is_null_interface = function() return false end, name = function() return 'open_land' end,
                                owning_faction = function() return trader end }
local lookups = 0   -- hexes asked about: zero means no walled search ran
local ROAD_TURN = 1   -- the turn a kept answer is stamped with (the computers' terms, below)
cm.model = function() return { campaign_name_key = function() return 'test' end, turn_number = function() return ROAD_TURN end,
    get_region_at_logical_position = function(_, x, y) lookups = lookups + 1; return enemy(x, y) and enemy_land or open_land end } end
cm.get_region = function(_, key) return key == 'enemy_land' and enemy_land or open_land end
local saved_grids = R.grids
R.grids = { test = g }
local ok, why, road = R.reach(settled(1, 4), settled(3, 4), 10)
assert(ok and road and crossings(road) == 0, 'a safe road within reach keeps the trade')
local journey = R.journey(settled(1, 1), settled(3, 1))
assert(journey and crossings(journey) == 0, 'cargo must use a solved road round hostile ground')
-- KEPT JOURNEYS (2026-11-08): the same pair again searches nothing while its regions judge the same, and each
-- caller gets its own list, as a cargo keeps it
lookups = 0
local again_journey = R.journey(settled(1, 1), settled(3, 1))
assert(lookups == 0, 'an unchanged journey was searched again: ' .. lookups .. ' hexes')
assert(again_journey ~= journey and #again_journey == #journey, 'a kept journey handed out its own list')
for i = 1, #journey do assert(again_journey[i] == journey[i], 'a kept journey changed at step ' .. i) end
ok, why = R.reach(settled(1, 4), settled(3, 4), 9)
assert(ok == false and why == 'enemy', 'only the enemy stands between them: ' .. tostring(why))
ok, why = R.reach(settled(1, 4), settled(3, 4), 1)
assert(ok == false and why == 'far', 'further apart than the reach, before any search')
g.data = string.rep('/', 5) .. '//A//' .. '//A//' .. '//A//' .. '//A//'   -- mountains, not enemies, in the way
ok, why = R.reach(settled(1, 4), settled(3, 2), 5)
assert(ok == false and why == 'far', 'a long way round with no enemy to blame is too far: ' .. tostring(why))
ok, why = R.reach(settled(1, 4), settled(3, 4), 9)   -- 'enemy' on the open map, kept from above
assert(ok == false and why == 'far', 'a kept answer outlived a change of map: ' .. tostring(why))
R.reach_memo, lookups = {}, 0   -- the kept walled answer gone (a war somewhere on it): terrain alone answers
ok, why = R.reach(settled(1, 4), settled(3, 2), 5)
assert(ok == false and why == 'far' and lookups == 0,
       'no road even through enemy land, yet a walled search asked about ' .. lookups .. ' hexes')
g.data = string.rep('/', 25)
assert(R.reach(settled(1, 4), settled(3, 4), 9) == false, 'the grid restored')
-- KEPT ANSWERS: the same road again searches nothing while its regions judge the same, and searches again
-- (with the new answer) the moment one does not.
ok, why, road = R.reach(settled(1, 4), settled(3, 4), 10)
lookups = 0
local again_ok, _, again = R.reach(settled(1, 4), settled(3, 4), 10)
assert(ok and again_ok and again == road and lookups == 0, 'an unchanged road was searched again: ' .. lookups .. ' hexes')
local trader_land = open_land.owning_faction
open_land.owning_faction = function() return fac('x', true) end   -- the detour's land declares war
ok, why = R.reach(settled(1, 4), settled(3, 4), 10)
assert(ok == false and why == 'enemy', 'a kept road outlived a war on its own land: ' .. tostring(ok))
lookups = 0
R.journey(settled(1, 1), settled(3, 1))
assert(lookups > 0, 'a kept journey outlived a war on its own land')
open_land.owning_faction = function() return fac('y') end   -- taken by a friend: the detour opens
lookups = 0
ok = R.reach(settled(1, 4), settled(3, 4), 10)
assert(ok and lookups > 0, 'peace on the detour must open it again')
open_land.owning_faction = function() return fac('z') end   -- another friend: same verdict, same road
lookups = 0
ok = R.reach(settled(1, 4), settled(3, 4), 10)
assert(ok and lookups == 0, 'land changing hands with no change of verdict searched again')
local get_region = cm.get_region
cm.get_region = function() return false end   -- CA's answer for no such region
lookups = 0
ok = R.reach(settled(1, 4), settled(3, 4), 10)
assert(ok and lookups > 0, 'a region the game no longer knows was taken as unchanged')
cm.get_region = get_region
open_land.owning_faction = trader_land
assert(R.reach(settled(1, 4), settled(3, 4), 9) == false, 'a kept answer ignored a shorter reach')
-- ONE PARTY (supply lines, design 2026-11-08 section 4): an army's road home is judged for its own faction alone,
-- by key; the two-region avoider is the same judge with the parties taken from the two owners
do
    local filed = {}
    local one = R.avoider_for({ 'trader' }, filed)
    assert(one(2, 2) == true and one(0, 0) == false, 'a one-party avoider must wall land at war with its party')
    assert(filed.enemy_land == true and filed.open_land == false, 'a one-party avoider files its verdicts by region')
    local two = R.avoider(settled(1, 4), settled(3, 4), {})
    for _, q in ipairs({ { 2, 2 }, { 0, 0 }, { 2, 4 }, { 4, 4 } }) do
        assert(two(q[1], q[2]) == one(q[1], q[2]), 'the two-region avoider judged a hex differently at ' .. q[1] .. ',' .. q[2])
    end
end
-- A SEARCH KEEPS NOTHING ON THE GRID (2026-11-07): a neighbour table kept per hex searched was 74 MB of the Lua heap
-- by turn 16 of an IE game, never freed, and every garbage collection walked it
-- (a fresh grid: every hex of this 5 x 5 one has been searched already, so a kept table would not grow on it)
local fresh = { w = g.w, h = g.h, data = g.data, bridges = {} }
local function grid_size()
    local n = 0
    for _, v in pairs(fresh) do n = n + 1; if type(v) == 'table' then for _ in pairs(v) do n = n + 1 end end end
    return n
end
local before_size, grids_now = grid_size(), R.grids
R.grids, R.reach_memo, R.free_memo = { test = fresh }, {}, {}   -- the grid is under test here, not the kept answers
assert(R.reach(settled(1,0),settled(3,0),10), 'the road this check searches was not found')
assert(grid_size()==before_size,'a search left '..(grid_size()-before_size)..' entries on the grid')
R.grids = grids_now
-- A SEARCH THAT GAVE UP proves nothing: past R.SEARCH_CAP the road through enemy land was not found, not
-- shown absent, so it must not answer 'far' for a walled search that would find one.
-- 8 x 6, a wall at x = 4 from y = 0 to 4: the only way east is the lane along y = 5.
local rows = {}
for y = 0, 5 do local r = '' for x = 0, 7 do r = r .. ((x == 4 and y <= 4) and 'A' or '/') end rows[#rows + 1] = r end
local lands, hostile = {}, 'lane'
for _, key in ipairs({ 'east', 'lane', 'pocket' }) do
    lands[key] = { is_null_interface = function() return false end, name = function() return key end,
                   owning_faction = function() return key == hostile and fac('x', true) or trader end }
end
cm.model = function() return { campaign_name_key = function() return 'test' end, turn_number = function() return ROAD_TURN end,
    get_region_at_logical_position = function(_, x, y) return lands[x >= 5 and 'east' or y == 5 and 'lane' or 'pocket'] end } end
cm.get_region = function(_, key) return lands[key] end
R.grids, R.SEARCH_CAP = { test = { w = 8, h = 6, data = table.concat(rows), bridges = {} } }, 20   -- open search 30, walled 16
assert(R.reach(settled(0, 5), settled(7, 0), 50) == false, 'the lane is enemy land: no safe road')
hostile = 'pocket'
assert(R.reach(settled(0, 5), settled(7, 0), 50), 'a road search that gave up at its cap was taken for proof of no road')
R.SEARCH_CAP = 200000
R.grids = {}
assert(R.reach(settled(1, 4), settled(3, 4), 1) == true, 'a map with no grid never stops trade')
assert(R.journey(settled(1, 4), settled(3, 4)) == nil, 'unknown maps retain legacy shipment positions')
R.grids, cm.model = saved_grids, NO_MAP

-- THE COMPUTERS' TERMS (IEE, 2026-11-11: one computer turn start spent 4.4 s, and one round 54 s, in road searches):
-- `terms` = { left = hexes still to search, keep = turns a kept answer is trusted }. A search stops when the hexes
-- run out, answers nil, 'pending', and the next ask goes on from where it stopped; a computer's kept answer is given
-- unchecked for `keep` turns while both ends keep their owners.
do
    local turn, all_war = 50, false
    -- 12 x 12, mountains at x = 6 from y = 0 to 9: the one way east is the gap at x = 6, y >= 10
    local rows = {}
    for y = 0, 11 do local r = '' for x = 0, 11 do r = r .. ((x == 6 and y <= 9) and 'A' or '/') end rows[#rows + 1] = r end
    local grid = { w = 12, h = 12, data = table.concat(rows), bridges = {} }
    local grudge, hater = fac('grudge'), fac('hater')
    grudge.at_war_with = function(_, p) return all_war or p:name() == 'hater' end   -- the gap's owner
    local lands = {}
    for _, key in ipairs({ 'home', 'gap' }) do
        lands[key] = { is_null_interface = function() return false end, name = function() return key end,
                       owning_faction = function() return key == 'gap' and grudge or trader end }
    end
    local judged, checks = 0, 0   -- hexes a search judged; regions a kept answer's check looked up
    local saved_model, saved_region, saved_grids2, advance = cm.model, cm.get_region, R.grids, R.advance
    cm.model = function() return { campaign_name_key = function() return 'test' end, turn_number = function() return turn end,
        get_region_at_logical_position = function(_, x, y)
            judged = judged + 1
            return lands[(x == 6 and y >= 10) and 'gap' or 'home']
        end } end
    cm.get_region = function(_, key) checks = checks + 1; return lands[key] end
    local a_owner = trader
    local A = { owning_faction = function() return a_owner end, settlement = function()
        return { logical_position_x = function() return 2 end, logical_position_y = function() return 2 end } end }
    local B = settled(10, 2)
    local function forget() R.reach_memo, R.free_memo, R.reach_jobs, R.journey_memo, R.journey_jobs = {}, {}, {}, {}, {} end
    local function terms(n) return { left = n or 100000, keep = 5 } end
    R.grids = { test = grid }
    forget()
    local whole = terms()
    local ok, _, road = R.reach(A, B, 40, whole)
    local size = 100000 - whole.left
    assert(ok and road and size > 20, 'the detour round the mountains was not found: ' .. size .. ' hexes')
    -- five hexes an ask: under way, then on from where it stopped until done
    forget()
    local most = 0
    R.advance = function(j, budget) most = math.max(most, budget); return advance(j, budget) end
    local first = terms(5)
    local answer, why = R.reach(A, B, 40, first)
    assert(answer == nil and why == 'pending' and first.left == 0, 'a search ran past its allowance: ' .. tostring(answer))
    local asks, again = 1, nil
    repeat
        local t = terms(5)
        answer, why, again = R.reach(A, B, 40, t)
        asks = asks + 1
        assert(answer ~= nil or (why == 'pending' and t.left == 0), 'a search under way said nothing or stopped short')
    until answer ~= nil or asks > size
    assert(answer and #again == #road, 'a search five hexes at a time never finished: it started over at each ask')
    assert(most <= 5, 'an ask searched ' .. most .. ' hexes on an allowance of five')
    assert(next(R.reach_jobs) == nil, 'a finished search was left waiting')
    -- no safe road (the gap's owner is at war with the new owner of A): the road through enemy land within the
    -- allowance too, and the answer the one an unlimited search gives
    a_owner = hater
    forget(); most = 0; asks = 0
    repeat answer, why = R.reach(A, B, 40, terms(5)); asks = asks + 1 until answer ~= nil or asks > 10 * size
    assert(answer == false and why == 'enemy', 'cut off by enemy land, five hexes at a time: ' .. tostring(why))
    assert(most <= 5, 'the road through enemy land was searched ' .. most .. ' hexes on an allowance of five')
    forget()
    answer, why = R.reach(A, B, 40)
    assert(answer == false and why == 'enemy', 'cut off by enemy land, unlimited: ' .. tostring(why))
    R.advance = advance
    -- a search under way starts again when an end changes hands: the new owner judges the land
    a_owner = trader; forget()
    assert(R.reach(A, B, 40, terms(5)) == nil, 'five hexes found the whole detour')
    a_owner = hater
    assert(R.reach(A, B, 40, terms()) == false, 'a search begun for the old owner was finished for the new one')
    -- searches nobody asked about for over a turn are dropped as a new one starts: each holds a table a hex it saw
    a_owner = trader; forget()
    R.reach(A, B, 40, terms(5))
    turn = 52
    R.reach(A, settled(10, 4), 40, terms(5))
    local waiting = 0
    for _ in pairs(R.reach_jobs) do waiting = waiting + 1 end
    assert(waiting == 1, 'a search left two turns ago was kept: ' .. waiting .. ' waiting')
    -- a computer's kept road is trusted for its turns, then checked
    turn = 60; forget()
    assert(R.reach(A, B, 40, terms()), 'the road was not found')
    all_war = true   -- the gap's owner goes to war with everyone: the kept road now crosses enemy land
    turn = 64; judged, checks = 0, 0
    assert(R.reach(A, B, 40, terms()) == true and judged == 0 and checks == 0,
           "a computer's kept road was checked again before its turns were up")
    turn = 65
    assert(R.reach(A, B, 40, terms()) == false, "a computer's kept road was trusted past its turns")
    -- a player's road (no terms) is checked every time
    turn = 70; all_war = false; forget()
    assert(R.reach(A, B, 40), 'the road was not found')
    all_war = true
    assert(R.reach(A, B, 40) == false, "a player's kept road was given unchecked")
    -- an end changing hands ends the trust, even to an owner who judges the land the same
    turn = 80; all_war = false; forget()
    R.reach(A, B, 40, terms())
    a_owner = fac('other'); turn = 81; checks = 0
    R.reach(A, B, 40, terms())
    assert(checks > 0, 'a kept road was trusted after an end changed hands')
    a_owner = trader
    -- a check that finds nothing changed starts its turns again
    turn = 90; forget()
    R.reach(A, B, 40, terms())
    turn = 95; R.reach(A, B, 40, terms())
    turn = 96; checks = 0
    R.reach(A, B, 40, terms())
    assert(checks == 0, 'a kept road found unchanged was checked again the next turn')
    -- a cart's road the same way
    turn = 100; all_war = false; forget()
    local full = R.journey(A, B)
    assert(full and #full > 0, 'the cart road was not found')
    forget()
    local t = terms(5)
    local part
    part, why = R.journey(A, B, t)
    assert(part == nil and why == 'pending' and t.left == 0, "a cart's search ran past its allowance")
    asks = 0
    repeat part = R.journey(A, B, terms(5)); asks = asks + 1 until part or asks > size * 10
    assert(part and #part == #full, "a cart's search five hexes at a time never finished")
    assert(next(R.journey_jobs) == nil, 'a finished cart search was left waiting')
    all_war = true; turn = 101; judged, checks = 0, 0
    part = R.journey(A, B, terms())
    assert(part and #part == #full and judged == 0 and checks == 0,
           "a computer's kept cart road was checked again before its turns were up")
    R.journey(A, B)
    assert(judged > 0, "a player's cart road must be checked every time")
    forget()
    R.grids, cm.model, cm.get_region = saved_grids2, saved_model, saved_region
end

local empty = { num_items = function() return 0 end }
local faction = { culture=function() return 'human' end, name = function() return 'viewer' end, is_null_interface = function() return false end,
                  factions_trading_with = function() return false end, factions_met = function() return empty end,
                  region_list = function() return empty end, get_foreign_visible_regions_for_player = function() return empty end }
local ships = { { f='viewer', from='a', to='b', x=1, y=2 } }
DERPY_MR_FLOWS = { ships = function() return ships end, routes = function() return {} end,
                  capital = function() return nil end, stopped=function() return false end }
R.grid = g
R.cache['a>b'] = { {1,2}, {1,1}, {1,0}, {2,0}, {3,0}, {3,1}, {3,2} }
R.queued['a>b'] = R.epoch
local adds, removes, live_scenes = {}, {}, {}
cm.get_local_faction_name = function() return 'viewer' end
cm.get_faction = function() return faction end
cm.get_camera_position = function() return 0, 0, 20 end
cm.is_local_players_turn = function() return true end
core.get_screen_resolution = function() return 1600, 900 end
cm.log_to_dis = function(_, x, y) return x, y end
cm.get_region=function() return settled(1,2) end
cm.add_scripted_composite_scene_to_logical_position = function(_, id, kind, x,y,fx,fy,once,seen,unseen,viewer)
    assert(not once and not seen and not unseen and viewer == faction, 'fog/owner filter lost')
    adds[#adds+1] = { id=id, kind=kind, x=x, y=y }
    live_scenes[id]=true
    return true
end
cm.remove_scripted_composite_scene = function(_, id) removes[#removes+1] = id;live_scenes[id]=nil end
R.refresh()
local kinds = {}
for _, a in ipairs(adds) do kinds[#kinds+1] = a.x .. ',' .. a.y .. '=' .. a.kind end
table.sort(kinds)
-- every second hex; with no MCT the size is small (0) and the set the default (0), where the owner 'viewer'
-- hashes to colour 2; the bin is the display angle / 15 degrees, folded to 0-165
assert(table.concat(kinds, ' ') == '1,0=derpy_mr_route_dash_0_2_9_b0 1,2=derpy_mr_route_cargo_0 '
    .. '1,2=derpy_mr_route_dash_0_2_6 3,0=derpy_mr_route_dash_0_2_3_b4 3,2=derpy_mr_route_dash_0_2_6', table.concat(kinds, ' '))
R.refresh()
assert(#adds == 5 and #removes == 0, 'unchanged routes recreated scenes')
-- The MCT's line size and colour set pick the scenes: 'large' is size 2 and 'pale' set 2, so 'viewer' is 2 * 4 + 2.
DERPY_MR_FLOWS.mct = function(key) return ({ route_size = 'large', route_colours = 'pale' })[key] end
R.refresh()
kinds = {}
for _, p in pairs(R.scenes) do kinds[#kinds+1] = p.x .. ',' .. p.y .. '=' .. p.scene end
table.sort(kinds)
assert(table.concat(kinds, ' ') == '1,0=derpy_mr_route_dash_2_10_9_b0 1,2=derpy_mr_route_cargo_2 '
    .. '1,2=derpy_mr_route_dash_2_10_6 3,0=derpy_mr_route_dash_2_10_3_b4 3,2=derpy_mr_route_dash_2_10_6', table.concat(kinds, ' '))
assert(#removes == 5 and #adds == 10, 'a new line style left the old scenes up')
DERPY_MR_FLOWS.mct = function() return 'huge' end
local size, set = R.style()
assert(size == 0 and set == 0, 'a choice this build does not know draws as designed')
DERPY_MR_FLOWS.mct = nil
R.refresh()
assert(#removes == 10 and #adds == 15, 'no MCT: back to the default style')
-- Angles come from display positions, not logical ones: a stretched x axis turns the diagonal dashes.
cm.log_to_dis = function(_, x, y) return x * 2, y end
R.refresh()
assert(#removes == 12 and #adds == 17, 'a dash whose direction changed kept its old scene')
cm.log_to_dis = function(_, x, y) return x, y end
ships = {}
R.refresh()
assert(#removes == 17 and next(R.scenes) == nil, 'ended routes left scenes behind')

-- DRAGGING THE MAP (2026-10-29): a camera move places what is near the camera from the last refresh's links;
-- the links (and their trade previews) are worked out again only on a change, or by the timed refresh once the
-- camera is still. A road's display positions are converted once, not on every refresh.
do
    local saved_links, saved_camera, saved_dis, saved_model = R.links, cm.get_camera_position, cm.log_to_dis, cm.model
    -- R.tick runs the carts too, and they ask the model whether a hex is land
    cm.model = function() return { get_region_at_logical_position = function() return { is_null_interface = function() return false end } end } end
    local drag_road = { {0,0}, {1,0}, {2,0}, {3,0}, {4,0}, {5,0}, {6,0}, {7,0}, {8,0} }
    local built, converted, deduped, cx = 0, 0, 0, 0
    local saved_unshared = R.unshared
    R.unshared = function(...) deduped = deduped + 1; return saved_unshared(...) end
    R.links = function() built = built + 1; return { { key = 'drag', owner = 'viewer', path = drag_road } }, {} end
    cm.log_to_dis = function(_, x, y) converted = converted + 1; return x, y end
    cm.get_camera_position = function() return cx, 0, 20 end
    R.drawn, R.dirty, R.stale, R.ticks, R.queue, R.camera = nil, false, false, 2, {}, nil
    R.tick()
    assert(built == 1 and next(R.scenes) ~= nil, 'the first tick must work the links out and draw them')
    cx = 400
    converted, deduped = 0, 0
    R.tick()
    assert(built == 1, 'a camera move worked the links out again')
    assert(next(R.scenes) == nil, 'a camera move left the dashes of the old view up')
    assert(converted == 0, 'a camera move converted a road it had already converted')
    assert(deduped == 0, 'a camera move worked out the shared stretches of the roads again')
    cx = 0
    R.tick()
    assert(built == 1 and next(R.scenes) ~= nil, 'moving back did not place the dashes again')
    -- the timed refresh falls due while the camera moves: it waits, and runs on the first still tick
    R.ticks = R.STALE_EVERY
    cx = 40
    R.tick()
    assert(built == 1 and R.stale, 'the timed refresh ran mid-drag')
    R.tick()
    assert(built == 2 and not R.stale, 'the timed refresh did not run once the camera stopped')
    -- a change is not held back by a moving camera
    R.dirty, cx = true, 80
    R.tick()
    assert(built == 3 and not R.dirty, 'a change waited for the camera to stop')
    -- a full refresh whose network came back unchanged (R.network's cached table) keeps the shared stretches
    local same = { { key = 'drag', owner = 'viewer', path = drag_road } }
    R.links = function() built = built + 1; return same, {} end
    R.dirty = true; R.tick()
    deduped = 0
    R.dirty = true; R.tick()
    assert(deduped == 0, 'an unchanged network had its shared stretches worked out again')
    R.links = function() built = built + 1; return { { key = 'drag', owner = 'viewer', path = drag_road } }, {} end
    R.dirty = true; R.tick()
    local kept_stretches = 0
    for _ in pairs(R.drawn[3]) do kept_stretches = kept_stretches + 1 end
    assert(deduped == 1 and kept_stretches == 1, 'a changed network kept the old shared stretches')
    -- a still camera with nothing changed renews one seller's cart goods every R.PLAN_EVERY ticks
    local renewals, renew = 0, R.renew_plan
    R.renew_plan = function() renewals = renewals + 1 end
    R.ticks, R.stale, R.dirty = 2, false, false
    for _ = 1, R.PLAN_EVERY do R.tick() end
    assert(renewals == 1, 'a still camera never renewed the cart goods')
    R.renew_plan = renew
    assert(not R.failed, 'the tick threw')
    R.links, cm.get_camera_position, cm.log_to_dis, cm.model = saved_links, saved_camera, saved_dis, saved_model
    R.unshared = saved_unshared
    R.drawn, R.camera = nil, nil
    R.clear()
end

-- A new turn re-paths a shown route once, and the old line stays up until the new path lands.
local old = R.cache['a>b']
local function region(x, y) return { is_null_interface = function() return false end, owning_faction = function() return trader end,
    name = function() return x .. ',' .. y end, settlement = function() return { is_null_interface = function() return false end,
        logical_position_x = function() return x end, logical_position_y = function() return y end } end } end
cm.get_region = function(_, key) return key == 'a' and region(1, 2) or region(3, 2) end
cm.model = function() return { get_region_at_logical_position = function() return region(0, 0) end } end
core.trigger_event = function() end
assert(R.path('a', 'b') == old and #R.queue == 0, 'a path already worked out this turn was queued again')
R.epoch = R.epoch + 1
assert(R.path('a', 'b') == old and R.path('a', 'b') == old and #R.queue == 1, 'a new turn should queue one re-path and keep the old line')
R.pump()
assert(#R.queue == 0 and R.cache['a>b'] ~= old and R.cache['a>b'][1][1] == 1, 'the re-path did not replace the old line')
-- KEPT ROADS (2026-10-29): a road whose land judges the same is given back unsearched at the next check; land that
-- judges differently, or a changed map, searches again with the old line up meanwhile
do
    local road_now, get_region = R.cache['a>b'], cm.get_region
    R.epoch = R.epoch + 1
    assert(R.path('a', 'b') == road_now and #R.queue == 0, 'a road whose land judges the same was searched again')
    cm.get_region = function(_, key)
        if key ~= '0,0' then return get_region(cm, key) end
        local land = region(0, 0)
        land.owning_faction = function() return fac('foe', true) end
        return land
    end
    R.epoch = R.epoch + 1
    assert(R.path('a', 'b') == road_now and #R.queue == 1, 'land turned hostile left the road unsearched')
    cm.get_region, R.queue = get_region, {}
    R.kept['a>b'].data = 'another map'
    R.epoch = R.epoch + 1
    assert(R.path('a', 'b') == road_now and #R.queue == 1, 'a kept road outlived its map')
    R.pump()
    assert(R.kept['a>b'].data == R.grid.data and R.kept['a>b'].regions['0,0'] == false, 'a finished search kept no verdicts')
end
-- NOTHING FROM THE ENGINE IS KEPT ACROSS TICKS (the 1.0 live pass, 2026-11-02): a queued search runs over many ticks,
-- each its own script entry, and an interface from an earlier entry is freed memory. Here an interface remembers the
-- entry that made it and refuses a call from a later one: R.path queues on one tick and R.pump works on the next.
do
    local ENTRY = 1
    local function volatile(t, stamp)
        if type(t) ~= 'table' then return t end
        return setmetatable({}, { __index = function(_, k)
            local v = t[k]
            if type(v) ~= 'function' then return v end
            return function(_, ...)
                if stamp ~= ENTRY then error('an interface from script entry ' .. stamp .. ' used in entry ' .. ENTRY, 2) end
                return volatile(v(t, ...), stamp)
            end
        end })
    end
    local get_region, model, get_faction, kept, road = cm.get_region, cm.model, cm.get_faction, R.kept, R.cache['a>b']
    cm.get_region = function(_, key) return volatile(key == 'a' and region(1, 2) or region(3, 2), ENTRY) end
    cm.model = function() return volatile({ get_region_at_logical_position = function() return region(0, 0) end }, ENTRY) end
    cm.get_faction = function(_, key)   -- as CA's: a faction comes back as it is
        if type(key) ~= 'string' then return key end
        return volatile(fac(key), ENTRY)
    end
    R.kept, R.queue = {}, {}
    R.epoch = R.epoch + 1
    R.path('a', 'b')
    assert(#R.queue == 1, 'the search was not queued')
    ENTRY = 2   -- the next tick
    local ok, err = pcall(R.pump)
    assert(ok, 'a queued search used an interface from an earlier tick: ' .. tostring(err))
    assert(#R.queue == 0 and R.cache['a>b'] and R.cache['a>b'][1][1] == 1, 'the search did not finish on the next tick')
    cm.get_region, cm.model, cm.get_faction, R.kept, R.cache['a>b'] = get_region, model, get_faction, kept, road
end
-- THE NETWORK IS BUNDLED AGAIN when a road changes and at the player's turn, not at every war or diplomatic event
do
    local bundles, bundle = 0, R.bundle
    R.bundle = function(path) bundles = bundles + 1; return path end
    local first_road, second_road = { {1,2}, {2,2} }, { {3,2}, {2,2} }
    local function net()
        return { {key='n1', owner='viewer', own=true, path=first_road}, {key='n2', owner='viewer', own=true, path=second_road} }
    end
    R.network_cache = nil
    local first_net = R.network(net())
    assert(bundles == 2, 'the first network was not bundled')
    R.epoch = R.epoch + 1
    -- the same table back: a full refresh then reuses its shared stretches (R.drawn[1] == links)
    assert(R.network(net()) == first_net, 'an unchanged network did not come back as the same table')
    assert(bundles == 2, 'a diplomatic event bundled the unchanged network again')
    second_road = { {3,2}, {3,1}, {2,2} }
    R.network(net())
    assert(bundles == 3, 'a changed road did not bundle itself again, or bundled the unchanged one too')
    -- ONLY A NEW OR CHANGED LINK (2026-11-07: 85 bundles a refresh at 121 links while reach answers came in)
    local third_road = { {4,2}, {2,2} }
    local function more() local n = net(); n[3] = {key='n3', owner='other', own=false, path=third_road}; return n end
    R.network(more())
    assert(bundles == 4, 'a new link bundled more than itself')
    R.network(net())
    assert(bundles == 4, 'a link going away bundled the ones that stayed')
    local n = net(); n[1].owner = 'someone'
    R.network(n)
    assert(bundles == 5, 'a link whose owner changed was not bundled again')
    R.new_turn()
    assert(R.dirty and R.network_cache == nil, "the player's turn did not ask for a new network")
    R.network(net())
    assert(bundles == 7, "the player's turn did not bundle the network again")
    R.bundle, R.network_cache, R.dirty = bundle, nil, false
end
-- THE CART GOODS' PREVIEWS (IEE, 2026-11-11: a partner's preview was 57-85 ms every few seconds, 346 ms at worst):
-- a computer's stores move only at its own turn start, so each computer seller is worked out once a player's turn,
-- in name order; after that only the viewer's own, which a recruit moves and nothing reports, comes round again
do
    local flows, get_faction, made = DERPY_MR_FLOWS, cm.get_faction, {}
    DERPY_MR_FLOWS = { trade = function(f, preview)
        assert(preview, 'a renewal committed a trade')
        made[#made + 1] = f:name()
        return { fresh = { 'grain' } }
    end }
    cm.get_faction = function(_, key) return fac(key) end
    R.plans, R.plan_fresh = { s1 = {}, s2 = {}, viewer = {} }, {}
    R.renew_plan(); R.renew_plan()
    assert(table.concat(made, ',') == 's1,s2' and R.plans.s1.fresh and R.plans.s2.fresh,
           'each computer seller must be renewed in turn: ' .. table.concat(made, ','))
    R.renew_plan(); R.renew_plan()
    assert(table.concat(made, ',') == 's1,s2,viewer,viewer',
           "a computer's preview was worked out twice in one turn: " .. table.concat(made, ','))
    R.new_turn()
    R.renew_plan()
    assert(made[5] == 's1', "a new turn must renew the computers' previews: " .. table.concat(made, ','))
    -- a preview a refresh worked out (R.carried) is this turn's already
    R.new_turn()
    R.plans, made = { viewer = {} }, {}
    R.carried({ 'grain' }, 's3', 'viewer', R.plans)
    R.renew_plan()
    assert(table.concat(made, ',') == 's3,viewer', "a refresh's preview was worked out again: " .. table.concat(made, ','))
    R.new_turn()
    R.plans, made = {}, {}
    R.renew_plan()
    assert(#made == 0, 'a renewal with nothing drawn worked something out')
    DERPY_MR_FLOWS, cm.get_faction, R.plans, R.plan_fresh = flows, get_faction, {}, {}
    R.dirty, R.network_cache = false, nil
end
local function list(items)
    return { num_items=function() return #items end, item_at=function(_, i) return items[i+1] end }
end
local ally = { culture=function() return 'human' end, name=function() return 'ally' end, is_null_interface=function() return false end,
               is_dead=function() return false end, factions_trading_with=function() return false end }
faction.factions_met = function() return list({ally}) end
faction.get_foreign_visible_regions_for_player = function()
    return list({{name=function() return 'a' end},{name=function() return 'b' end}})
end
ships = { {f='ally',from='a',to='b',x=1,y=2}, {f='unknown',from='a',to='b',x=1,y=2} }
local links, cargo = R.links(faction)
assert(#links == 1 and #cargo == 1 and cargo[1].f == 'ally', 'unknown faction routes revealed')
ships[1].road = {{1,2}, {1,1}, {2,1}, {3,2}}
links = R.links(faction)
assert(links[1].path == ships[1].road, 'a shipment line must follow its saved journey')
local checked_mode
DERPY_MR_FLOWS.routes = function() return {{enabled=true, from='a', to='b'}} end
DERPY_MR_FLOWS.route_status = function(_, _, mode) checked_mode = mode; return true end
R.links(faction)
assert(checked_mode == 'show', 'map contract checks must use the multiplayer-safe UI mode')
DERPY_MR_FLOWS.routes = function() return {} end
ships={{f='viewer',from='a',to='b',stem='grain',road=ships[1].road},
       {f='viewer',from='b',to='a',stem='iron'},
       {f='viewer',from='a',to='b',stem='grain'}}
DERPY_MR_FLOWS.routes=function() return {{enabled=true,from='a',to='b',stem='coal'}} end
links,cargo=R.links(faction)
assert(#links==1 and #cargo==3,'shared endpoints must retain individual cargo markers')
assert(table.concat(links[1].goods[1],',')=='grain,coal' and table.concat(links[1].goods[2],',')=='iron',
       'shared routes must merge unique goods in their physical direction')
DERPY_MR_FLOWS.routes=function() return {} end
ships={{f='ally',from='a',to='b',x=1,y=2}}
faction.get_foreign_visible_regions_for_player = function() return empty end
links, cargo = R.links(faction)
assert(#links == 0 and #cargo == 0, 'hidden foreign endpoints revealed')

-- An agreement draws its line only while its trade runs, and along the trade's own road.
ships = {}
local road, verdict, modes, worked = { {1,2}, {2,2}, {3,2} }, false, {}, false
faction.factions_trading_with = function() return list({ally}) end
ally.factions_trading_with = function() return list({faction}) end
DERPY_MR_FLOWS.capital = function(f) return { name = function() return f:name() .. '_home' end } end
-- verdict nil: nothing known yet; 'show' then answers `worked` (false: cut off; nil: a search still under way)
DERPY_MR_FLOWS.reach = function(_, _, mode)
    modes[#modes + 1] = mode
    if verdict == nil then
        if mode == 'peek' then return nil end
        return worked, nil, worked and road or nil
    end
    return verdict, nil, verdict and road or nil
end
links = R.links(faction)
assert(#links == 0, 'a cut-off agreement drew a line')
verdict = true
cm.get_faction=function(_,key) return key=='ally' and ally or faction end
DERPY_MR_FLOWS.trade=function(f,preview)
    assert(preview,'route refresh committed a trade')
    return {[f==faction and 'ally' or 'viewer']={'grain','iron'}}
end
links = R.links(faction)
assert(#links == 1 and links[1].path == road, 'an open agreement should draw its own road')
-- the cart goods' previews are kept between refreshes (R.renew_plan renews them), and dropped once nothing drawn uses them
local previews, preview_trade = 0, DERPY_MR_FLOWS.trade
DERPY_MR_FLOWS.trade = function(...) previews = previews + 1; return preview_trade(...) end
R.links(faction); R.links(faction)
assert(previews == 0 and R.plans.viewer and R.plans.ally, 'a refresh worked the cart goods out again')
DERPY_MR_FLOWS.trade = preview_trade
-- A BLOCKADED agreement (Part C 6.2) draws no line, as a cut-off one does
DERPY_MR_FLOWS.blockaded = function(a, b) return 'raider' end
assert(#R.links(faction) == 0, 'a blockaded agreement drew a line')
DERPY_MR_FLOWS.blockaded = function() return nil end
assert(#R.links(faction) == 1, 'an agreement nobody blockades drew no line')
DERPY_MR_FLOWS.blockaded = nil
DERPY_MR_FLOWS.stopped=function() return true end
assert(#R.links(faction)==0, 'all resources stopped must remove empty agreement roads')
ships={{f='viewer',from='a',to='b',stem='grain',x=1,y=2,road=road}}
assert(#R.links(faction)==1, 'resource switches must not recall travelling cargo')
DERPY_MR_FLOWS.mct=function(k) if k=='route_shipments' then return false end end
local hidden_links,hidden_cargo=R.links(faction)
assert(#hidden_links==0 and #hidden_cargo==0,'hidden shipments left their road or marker behind')
ships={}
DERPY_MR_FLOWS.stopped=function() return false end
DERPY_MR_FLOWS.mct=function(k) if k=='route_agreements' then return false end end
assert(#R.links(faction)==0,'agreement visibility switch was ignored')
assert(next(R.plans)==nil,'cart goods previews outlived the links that used them')
DERPY_MR_FLOWS.mct=nil
adds = {}
R.refresh()
local at = {}
for _, a in ipairs(adds) do at[#at + 1] = a.x .. ',' .. a.y end
table.sort(at)
assert(table.concat(at, ' ') == '1,2 3,2', 'the trade road is the one drawn: ' .. table.concat(at, ' '))
-- unknown: the map peeks, works out at least one per refresh, and comes back for the rest once its time is spent
verdict, modes, R.shows, R.show_until, R.dirty = nil, {}, 0, 0, false
links = R.links(faction)
assert(table.concat(modes, ',') == 'peek,show,peek' and R.dirty == true and R.shows == 1,
       'one new answer once the time is spent: ' .. table.concat(modes, ','))
-- with time left, every unknown pair is worked out in the same refresh (a kept answer costs next to nothing)
verdict, modes, R.shows, R.show_until, R.dirty = nil, {}, 0, os.clock() + 60, false
links = R.links(faction)
assert(table.concat(modes, ',') == 'peek,show,peek,show' and R.dirty == false and R.shows == 2,
       'time left, yet an answer waited for another refresh: ' .. table.concat(modes, ','))
-- an answer still to work out keeps the line it had up, so a diplomatic event does not re-bundle the network for
-- it (2026-10-30: dropped lines came back a few a refresh and every refresh bundled again, up to 400 ms)
verdict = true
R.shows, R.show_until = 0, os.clock() + 60
R.links(faction)
verdict, R.shows, R.show_until, R.dirty = nil, 1, 0, false
links = R.links(faction)
assert(#links == 1 and links[1].path == road and R.dirty == true, 'an agreement still to work out lost its line')
R.reach_shown = {}
R.dirty = false
assert(#R.links(faction) == 0 and R.dirty == true, 'a line with no answer yet was drawn')
-- A SEARCH STILL UNDER WAY (the map's 'show' stops after F.SHOW_HEXES, 2026-11-11): its line stays up and the map
-- comes back for the rest at the next tick
verdict, R.shows, R.show_until = true, 0, os.clock() + 60
R.links(faction)
verdict, worked, modes, R.shows, R.show_until, R.dirty = nil, nil, {}, 0, os.clock() + 60, false
links = R.links(faction)
assert(table.concat(modes, ',') == 'peek,show,peek,show' and #links == 1 and links[1].path == road and R.dirty == true,
       'a search under way dropped its line or was not come back for: ' .. table.concat(modes, ',') .. ' ' .. tostring(R.dirty))
R.reach_shown, R.dirty, worked = {}, false, false
local corner={{0,0},{1,0},{1,1}}
local x,y=R.sample(corner,2)
assert(x==0.875 and y==0.125,'rounded dash must sit on the quadratic cart curve')
assert(R.dash(corner,2,0,0)==R.dash({corner[3],corner[2],corner[1]},2,0,0),
       'reverse traffic must use the same physical rounded line')
assert(R.corner({{0,0},{4,0}},1)==nil,'never round a disconnected bridge span')
local node,next_node,angle=R.corner(corner,2)
assert(node==corner[2] and next_node==corner[3] and math.abs(angle-math.pi/2)<0.001,
       'cart turn must use the same incoming/outgoing edges as its dash')
cm.model = function() return {get_region_at_logical_position=function() return {is_null_interface=function() return false end} end} end
verdict = true
R.refresh()
assert(#R.traffic==2 and not R.traffic[1].reverse and R.traffic[2].reverse,
       'two-way trade must queue carts at both endpoints')
table.remove(R.traffic,2) -- Inspect one cart's icon handoff below; both lanes are checked separately.
adds = {}
-- THE CARTS' CLOCK: each call here is one 100 ms beat of a fake clock
local animate, NOW = R.animate, 0
R.now = function() return NOW end
R.animate = function() NOW = NOW + 100; return animate() end
R.animate()
assert(#adds==2 and adds[1].kind:match('^derpy_mr_route_cart_curve_') and adds[2].kind:match('^derpy_mr_icon_grain_'), 'cart and its resource icon must start together')
local first = adds[1]
local first_icon=adds[2].id
R.animate()
assert(#adds==2, 'a cart or its icon was respawned during its smooth segment')
for i=1,9 do R.animate() end
assert(#adds==4 and (adds[3].x~=first.x or adds[3].y~=first.y), 'cart did not advance to the next segment')
assert(adds[4].id~=first_icon and live_scenes[first_icon], 'retain the previous icon while its replacement starts rendering')
R.animate()
assert(not live_scenes[first_icon] and live_scenes[adds[4].id], 'retire the held icon after the replacement has a render update')
DERPY_MR_FLOWS.mct=function(k) if k=='route_icons' then return false end end
R.animate()
for id in pairs(live_scenes) do assert(not id:match('_icon_'),'hiding icons must remove both buffers immediately') end
DERPY_MR_FLOWS.mct=nil
for i=1,9 do R.animate() end
R.animate()
assert(adds[#adds].x==road[#road][1], 'cart teleported to its origin instead of turning at the destination')
local phase = R.traffic[1].distance
R.refresh()
assert(R.traffic[1].distance==phase, 'redrawing a road restarted its cart')
cm.model = function() return {get_region_at_logical_position=function() return {is_null_interface=function() return true end} end} end
R.clear();R.refresh();adds={}
table.remove(R.traffic,2)
R.animate()
assert(#adds==2 and adds[1].kind:match('^derpy_mr_route_boat_curve_')
    and adds[2].kind:match('^derpy_mr_sea_icon_grain_'),'sea traffic needs a boat and a water-level resource icon')
local first_boat=adds[1].id
R.animate()
assert(#adds==2,'a boat or icon restarted during its curve')
cm.model = function() return {get_region_at_logical_position=function() return {is_null_interface=function() return false end} end} end
R.traffic[1].fresh,R.traffic[1].place=true,nil;R.traffic[1].distance=1;R.traffic[1].steps=1
R.animate()
assert(adds[3].kind:match('^derpy_mr_route_cart_curve_') and adds[4].kind:match('^derpy_mr_icon_grain_'),
       'traffic must switch back to land models and terrain-anchored icons at the coast')
cm.get_camera_position = function() return 10000,10000,20 end
R.refresh(); R.animate()
assert(next(R.cart_scenes)==nil and #R.traffic==0, 'offscreen carts were not culled')
local saved_links = R.links
R.links = function()
    local links = {}
    for i=1,R.CART_LIMIT+4 do links[i]={key='traffic'..i,owner='viewer',path=road} end
    return links,{}
end
cm.get_camera_position = function() return 0,0,20 end
R.refresh()
assert(#R.traffic==R.CART_LIMIT, 'dense networks exceeded the animated cart cap')
local decals = 0
for _ in pairs(R.scenes) do decals = decals + 1 end
assert(decals==2, 'twelve routes sharing one road must draw just one dotted line')
R.clear(); R.refresh()
cm.model=function() return {get_region_at_logical_position=function() return {is_null_interface=function() return false end} end} end
local departures,last_departure={},{}
for tick=1,250 do
    R.animate()
    local active=0
    for _,trip in ipairs(R.traffic) do
        if trip.active then
            active=active+1
            if trip.last_departure==NOW then
                assert(NOW-(last_departure[trip.key] or -6000)>=6000,'a short route departed again too soon')
                if not last_departure[trip.key] then departures[#departures+1]=trip.key end
                last_departure[trip.key]=NOW
            end
        end
    end
    for i,a in ipairs(R.traffic) do for j=i+1,#R.traffic do
        local b=R.traffic[j]
        if a.active and b.active and a.reverse==b.reverse then
            assert(math.abs(a.distance-b.distance)>=R.GAP,'queued routes duplicated carts in one lane')
        end
    end end
end
assert(#departures>=4 and departures[1]=='traffic1' and departures[2]=='traffic2' and departures[3]=='traffic3',
       'shared-road departures must remain in order through arrival and return queues: '..table.concat(departures,','))
local highway={}
for y=0,199 do highway[#highway+1]={0,y} end
R.links=function() return {{key='two_way',from='a',owner='viewer',path=highway,goods={{'grain'},{'iron'}}}},{} end
R.clear();R.refresh()
assert(#R.traffic==2 and R.traffic[2].distance==199,'incoming traffic must start at the far endpoint')
for tick=1,70 do R.animate() end
assert(R.traffic[1].active and R.traffic[2].active,'separate lanes must permit simultaneous imports and exports')
assert(R.traffic[1].stem=='grain' and R.traffic[2].stem=='iron','directional carts must retain their own resources')
R.links=function()
    local links={}
    for k=1,10 do
        local p={}
        for y=0,9 do p[#p+1]={k*3,y} end
        links[k]={key='partner'..string.format('%02d',k),from='a',owner='viewer',path=p,goods={{'grain'},{'iron'}}}
    end
    return links,{}
end
R.clear();R.refresh()
assert(#R.traffic==R.CART_LIMIT,'ten two-way routes must fill the cart cap')
for k=1,10 do assert(R.traffic[k].key==string.format('partner%02d',k),'a route got its return cart before every route had one') end
for k=11,R.CART_LIMIT do assert(R.traffic[k].key:match(':return$'),'return carts must follow the first pass') end
R.animate()
for _,trip in ipairs(R.traffic) do assert(trip.active,'independent roads must depart without a global queue') end
-- Both land and sea traffic repeat within one turn; a one-way route never drives an empty leg.
for _,sea in ipairs({false,true}) do
    cm.model=function() return {get_region_at_logical_position=function() return {is_null_interface=function() return sea end} end} end
    R.links=function() return {{key='loop',from='a',owner='viewer',path=road,goods={{'grain'},{}}}},{} end
    R.clear();R.refresh()
    R.vehicles={supplier={land='land_chd',sea='sea_chd'}}
    local get_faction=cm.get_faction
    cm.get_faction=function(_,key)
        if key=='supplier' then return {is_null_interface=function() return false end,culture=function() return 'supplier' end} end
        return get_faction(cm,key)
    end
    R.traffic[1].factions={'supplier','buyer'}
    local departures=0
    for tick=1,260 do
        if tick%25==0 then R.refresh() end
        R.animate()
        local trip=R.traffic[1]
        if trip.last_departure==NOW then
            departures=departures+1
            assert(not trip.reverse and trip.stem=='grain','a one-way route drove an empty leg')
            assert(trip.vehicle_faction=='supplier','a loop must keep its supplier vehicle')
        end
    end
    assert(departures>=4,'active trade must loop without a faction turn')
    -- An import-only route starts on its loaded leg, not by driving out empty first.
    R.links=function() return {{key='import',from='a',owner='viewer',path=road,goods={{},{'iron'}}}},{} end
    R.clear();R.refresh();R.animate()
    assert(R.traffic[1].active and R.traffic[1].reverse and R.traffic[1].stem=='iron','an import route left on its empty leg')
    cm.get_faction=get_faction;R.vehicles={}
end
R.links=function() return {{key='idle',from='a',owner='viewer',path=road,goods={{},{}}}},{} end
R.clear();R.refresh();R.animate()
assert(#R.traffic==0 and next(R.cart_scenes)==nil and next(R.icon_scenes)==nil,
    'zero-flow agreements must retain their road without advertising active traffic')
assert(next(R.scenes)~=nil,'idle agreement should retain its dotted road')
R.links = saved_links
R.clear()
assert(next(R.cart_scenes)==nil and #R.traffic==0, 'cleanup left animated traffic behind')
assert(next(R.icon_scenes)==nil,'cleanup left resource icons behind')
-- THE CARTS' CLOCK (author, 2026-11-03: the carts stuttered every other second): a step a second of real time
-- whatever the timer's beat, the beat kept through a late frame and started again after a stall, and a frame
-- between steps reads no region
do
    local saved_links, saved_model, saved_camera = R.links, cm.model, cm.get_camera_position
    local reads = 0
    cm.model = function() return { get_region_at_logical_position = function()
        reads = reads + 1; return { is_null_interface = function() return false end } end } end
    local long = {}
    for y = 0, 99 do long[#long + 1] = { 0, y } end
    R.links = function() return { { key = 'clock', from = 'a', owner = 'viewer', path = long, goods = { { 'grain' }, {} } } }, {} end
    for _, beat in ipairs({ 110, 90, 30 }) do
        R.clear(); R.refresh()
        NOW = NOW + beat; animate()
        local trip, t0 = R.traffic[1], NOW
        assert(trip and trip.active, 'the cart did not leave')
        while NOW < t0 + 10000 do NOW = NOW + beat; animate() end
        assert(trip.steps == 10, 'a ' .. beat .. ' ms timer moved the cart ' .. trip.steps .. ' hexes in 10 s')
    end
    -- a stall (a slow redraw, a menu): one step when it ends, and the next a full second later, not a burst
    R.clear(); R.refresh()
    NOW = NOW + 100; animate()
    local trip = R.traffic[1]
    NOW = NOW + 3000; animate()
    assert(trip.steps == 1, 'a stall made the cart catch up in a burst: ' .. trip.steps)
    reads = 0
    NOW = NOW + 900; animate()
    assert(trip.steps == 1, 'the beat after a stall did not start again from it')
    assert(reads == 0, 'a frame with no step read the map ' .. reads .. ' times')
    NOW = NOW + 100; animate()
    assert(trip.steps == 2, 'the step after a stall did not come a second later')
    -- THE ICON'S HANDOFF (author, 2026-11-03: the carried icons twitched once the carts ran smoothly). The old icon
    -- is held at the join only for the new one's first frames: the cart no longer waits there, so a longer hold showed
    -- the old icon left behind while the new one moved on.
    R.clear(); R.refresh()
    NOW = NOW + 16; animate()
    trip = R.traffic[1]
    NOW = trip.due; animate()
    local icon = R.icon_scenes['derpy_mr_traffic_1_icon']
    assert(icon and icon.old, 'the old icon was not held while the new one starts')
    NOW = NOW + 50; animate()
    assert(icon.old == nil, 'the old icon was held past the new one\'s first frames')
    -- THE CAMERA'S VIEW (author, 2026-11-03: carts out of the camera should not be there). Looking north (bearing 0)
    -- at (0, 50) from 20 back and 20 up, the cart leaving (0, 0) is behind the camera, though inside the old circle
    -- around its target; looking south at (0, 40) it is in front, where a camera looking north at (0, 40) would
    -- have it behind.
    cm.get_camera_position = function() return 0, 50, 20, 0, 20 end
    R.clear(); R.refresh(); NOW = NOW + 100; animate()
    assert(R.traffic[1] and R.traffic[1].active and next(R.cart_scenes) == nil, 'a cart behind the camera was drawn')
    assert(R.in_view(0, 50) and not R.in_view(60, 50), 'a point beside the view was drawn')
    cm.get_camera_position = function() return 0, 40, 20, math.pi, 20 end
    R.clear(); R.refresh(); NOW = NOW + 100; animate()
    assert(next(R.cart_scenes) ~= nil, 'a cart in front of a turned camera was not drawn')
    -- turning the camera on the spot is a move: what is in view changed
    local refresh, full, moved, renewals, renew = R.refresh, 0, 0, 0, R.renew_plan
    R.refresh = function(m) if m then moved = moved + 1 else full = full + 1 end; return refresh(m) end
    R.renew_plan = function() renewals = renewals + 1 end
    R.dirty, R.stale, R.ticks = false, false, 2
    cm.get_camera_position = function() return 0, 40, 20, math.pi / 2, 20 end
    R.tick()
    assert(moved == 1, 'turning the camera did not place what came into view')
    -- THE COMPUTERS' TURNS (2026-11-03: 277 redraws, 3.5 s, in one round of them): nothing is worked out or drawn
    -- again until the player's turn, which draws the change that waited
    local mine = false
    cm.is_local_players_turn = function() return mine end
    full, moved, R.dirty, R.ticks = 0, 0, true, 2
    cm.get_camera_position = function() return 0, 60, 20, 0, 20 end
    for _ = 1, R.STALE_EVERY + R.PLAN_EVERY do R.tick() end
    assert(full + moved + renewals == 0, 'the map was worked out in the computers\' turn')
    mine = true; R.tick()
    assert(full == 1 and not R.dirty, 'the change that waited was not drawn in the player\'s turn')
    assert(not R.failed, 'the tick threw')
    cm.is_local_players_turn = function() return true end
    R.refresh, R.renew_plan = refresh, renew
    R.links, cm.model, cm.get_camera_position = saved_links, saved_model, saved_camera
    R.clear()
end
assert(next(live_scenes)==nil,'cleanup left an old icon buffer or scene in the engine')

-- AGREEMENT CARGO (Task 6): a convoy on the road is a cargo marker and nothing else. Its pair's line is the agreement's
-- own, so it keeps its colour and its road while goods are in flight; the viewer's convoys and those both ends of
-- which it can see are drawn, no one else's.
do
    local function convoy(over)
        local c = { id='derpy_mr_cv_1', f='viewer', buyer='ally', from='viewer_home', to='ally_home', x=2, y=2,
                    stem='grain', n=40, basket={grain=40,iron=12}, at=1, due=3, convoy=true }
        for k,v in pairs(over or {}) do c[k]=v end
        return c
    end
    local function seen(...)
        local visible={}
        for _,key in ipairs({...}) do visible[#visible+1]={name=function() return key end} end
        faction.get_foreign_visible_regions_for_player=function() return list(visible) end
    end
    local convoys={}
    verdict=true
    DERPY_MR_FLOWS.stopped=function() return false end
    DERPY_MR_FLOWS.mct=nil
    local base_links,base_cargo=R.links(faction)
    assert(#base_links==1 and #base_cargo==0,'no convoys: the agreement line and no marker, even from a flows script that has no convoy_cargo')
    DERPY_MR_FLOWS.convoy_cargo=function() return convoys end
    convoys={convoy()}
    local links,cargo=R.links(faction)
    assert(#cargo==1 and cargo[1].stem=='grain' and cargo[1].x==2 and cargo[1].y==2,'the viewer\'s own convoy is a cargo marker')
    assert(#links==1 and links[1].path==road and links[1].owner==base_links[1].owner,
           'a convoy adds no line and changes none: the pair keeps the road and the colour the agreement gave it')
    assert(table.concat(links[1].goods[1],',')==table.concat(base_links[1].goods[1],',')
        and table.concat(links[1].goods[2],',')==table.concat(base_links[1].goods[2],','),'a convoy adds no goods to its pair\'s line')
    -- ON THE ROAD THE MAP DRAWS (live check 2026-10-24, 17 hexes off): a convoy keeps the road it left on until its
    -- exporter's turn start moves it, so the marker goes where F.convoy_on puts it on the pair's agreement road, and
    -- is worked out again only when that road, the convoy's own road or its spot changes
    local asked={}
    local function placing(x,y) DERPY_MR_FLOWS.convoy_on=function(c,path) asked[#asked+1]={c.id,path}; return x,y end end
    placing(7,9); R.spots={}
    convoys={convoy({road='2:2;9:9'})}
    links,cargo=R.links(faction)
    assert(#asked==1 and asked[1][1]=='derpy_mr_cv_1' and asked[1][2]==road,'the marker is placed on its pair\'s agreement road')
    assert(cargo[1].x==7 and cargo[1].y==9,'at the spot F.convoy_on gives')
    convoys={convoy({road='2:2;9:9'})}   -- a new list, as F.convoy_cargo gives each time
    cargo=select(2,R.links(faction))
    assert(#asked==1 and cargo[1].x==7 and cargo[1].y==9,'the same road and spot are not worked out again')
    convoys={convoy({road='2:2;9:9',x=3})}
    assert(select(2,R.links(faction))[1].x==7 and #asked==2,'a step is')
    convoys={convoy({road='2:2;8:8',x=3})}
    assert(select(2,R.links(faction))[1].x==7 and #asked==3,'and a road of its own changed at a turn start')
    placing(nil,nil)
    convoys={convoy({road='2:2;9:9'})}
    cargo=select(2,R.links(faction))
    assert(cargo[1].x==2 and cargo[1].y==2,'a road that does not leave where the convoy left keeps its own spot')
    placing(7,9)
    local today=road; road={{1,2},{2,2},{3,2}}   -- the pair's road worked out again: the reach stub gives a new table
    assert(select(2,R.links(faction))[1].x==7 and asked[#asked][2]==road,'a new road for the pair is worked out again')
    road=today
    convoys={convoy({id='derpy_mr_cv_2',f='ally',buyer='viewer',road='2:2;9:9'})}
    assert(select(2,R.links(faction))[1].x==7 and asked[#asked][2]==road,'and so does a convoy coming to the viewer')
    DERPY_MR_FLOWS.convoy_on=nil; R.spots={}
    -- the buyer sees what is coming to it; a stranger sees only what both ends of lets it see
    convoys={convoy({f='ally',buyer='viewer'})}
    assert(#select(2,R.links(faction))==1,'a convoy bound for the viewer is drawn')
    convoys={convoy({f='ally',buyer='other',from='a',to='b'})}
    seen()
    assert(#select(2,R.links(faction))==0,'a known faction\'s convoy between lands the viewer cannot see is not drawn')
    seen('a','b')
    assert(#select(2,R.links(faction))==1,'one between two visible lands is')
    seen('a')
    assert(#select(2,R.links(faction))==0,'one that ends in the fog is not')
    seen('b')
    assert(#select(2,R.links(faction))==0,'nor one that starts in it')
    convoys={convoy({f='stranger',buyer='other',from='a',to='b'})}
    seen('a','b')
    assert(#select(2,R.links(faction))==0,'a faction the viewer has not met is never drawn')
    seen()
    -- a marker needs a place: F.convoy_cargo lists a convoy with no position (the Vault counts it), the map draws none
    local unplaced=convoy(); unplaced.x=nil
    convoys={unplaced}
    assert(#select(2,R.links(faction))==0,'a convoy with no x has no place for a marker')
    unplaced=convoy(); unplaced.y=nil
    convoys={unplaced}
    assert(#select(2,R.links(faction))==0,'nor one with no y')
    -- no agreement, no line: the convoy of a pair whose trade ended is still a marker, on no line
    convoys={convoy()}
    local trading,allied=faction.factions_trading_with,ally.factions_trading_with
    faction.factions_trading_with=function() return false end
    ally.factions_trading_with=function() return false end
    links,cargo=R.links(faction)
    assert(#links==0 and #cargo==1,'a convoy makes no line of its own where no agreement draws one')
    faction.factions_trading_with,ally.factions_trading_with=trading,allied
    -- the shipments switch hides them with the shipments
    DERPY_MR_FLOWS.mct=function(k) if k=='route_shipments' then return false end end
    assert(#select(2,R.links(faction))==0,'hidden shipments hide convoys too')
    DERPY_MR_FLOWS.mct=nil
    -- on the map: one cargo scene at the convoy's spot, over the agreement's own dashes
    local function drawn()
        R.clear(); R.refresh()
        local kinds={}
        for _,p in pairs(R.scenes) do kinds[#kinds+1]=p.x..','..p.y..'='..p.scene end
        table.sort(kinds)
        return kinds
    end
    convoys={}
    local without=drawn()
    convoys={convoy()}
    local with=drawn()
    without[#without+1]='2,2=derpy_mr_route_cargo_0'
    table.sort(without)
    assert(table.concat(with,' ')==table.concat(without,' '),'the convoy\'s marker is one cargo scene at its spot: '..table.concat(with,' '))
    -- THE DECAL BUDGET: 600 convoys far from the camera place no scene, the one near it still draws, and the road's dashes
    -- are not rationed for them
    local crowd={}
    for i=1,600 do crowd[i]=convoy({id='derpy_mr_cv_'..i,x=5000+i,y=5000}) end
    crowd[#crowd+1]=convoy({id='derpy_mr_cv_601'})
    convoys=crowd
    local crowded=drawn()
    assert(table.concat(crowded,' ')==table.concat(with,' '),'600 far convoys must place no marker and leave the dashes alone: '..#crowded..' scenes against '..#with)
    -- a shipment is not rationed by the camera: a far one still gets its marker
    convoys={}
    local kept=ships
    ships={{f='viewer',from='a',to='b',x=5000,y=5000}}
    local far_ship=false
    for _,k in ipairs(drawn()) do if k=='5000,5000=derpy_mr_route_cargo_0' then far_ship=true end end
    ships=kept
    assert(far_ship,'a shipment far from the camera still gets its marker')
    -- THE VIEWER'S SUPPLY CARTS (Task 5): a convoy's marker at the cart, near the camera only; nobody else's
    local carts={}
    DERPY_MR_FLOWS.supply_cargo=function() return carts end
    carts={{id='derpy_mr_supply_1',f='viewer',army='8801',from='viewer_home',x=2,y=2,due=4,basket={grain=15},supply=true}}
    assert(table.concat(drawn(),' ')==table.concat(with,' '),'a supply cart is one cargo scene at its spot, as a convoy\'s')
    for id in pairs(R.scenes) do assert(string.sub(id,1,14)=='derpy_mr_road_','a cart marker in the swept range: '..id) end
    carts[1].f='ally'
    assert(#select(2,R.links(faction))==0,'another faction\'s supply cart is not drawn')
    carts={}
    local bare=drawn()
    carts={{id='derpy_mr_supply_2',f='viewer',army='8801',from='viewer_home',x=5000,y=5000,due=4,basket={grain=15},supply=true}}
    assert(table.concat(drawn(),' ')==table.concat(bare,' '),'a supply cart far from the camera places no marker')
    DERPY_MR_FLOWS.supply_cargo=nil
    DERPY_MR_FLOWS.convoy_cargo=nil
    R.clear()
    assert(next(live_scenes)==nil,'cleanup left a convoy marker in the engine')
end
-- ARMY SUPPLY LINES (Task 4): each army of the local faction draws its supply road in the colour of its line's state,
-- and F.supply_line (flows.lua) is asked again only for an army that has moved, or once the answers were dropped
do
    local saved_links, saved_camera, saved_flows = R.links, cm.get_camera_position, DERPY_MR_FLOWS
    local saved_forces, saved_human = faction.military_force_list, faction.is_human
    local switch, at, lines, calls, armies, listed = {}, {}, {}, 0, {}, 0
    -- THE MAP ASKS AS THE UI (Task 8, multiplayer): drawing runs on one machine only, so it must not fill the enemy
    -- list the model keeps for the turn (flows.lua F.enemy_armies)
    local function ask(_, mf, ui)
        assert(ui == true, 'the map asked F.supply_line not as the UI: it would fill the model\'s enemy list')
        calls = calls + 1; return lines[mf:command_queue_index()]
    end
    DERPY_MR_FLOWS = { mct = function(k) return switch[k] end, supply_line = ask }
    R.links = function() return {}, {} end
    cm.get_camera_position = function() return 0, 0, 20 end
    local function army(cqi)
        return { command_queue_index = function() return cqi end, has_general = function() return true end,
                 general_character = function() return { logical_position_x = function() return at[cqi][1] end,
                                                          logical_position_y = function() return at[cqi][2] end } end }
    end
    faction.military_force_list = function() listed = listed + 1; return list(armies) end
    faction.is_human = function() return true end
    local function row(x0, y0, dx, dy, n)
        local p = {}
        for k = 0, n - 1 do p[#p + 1] = { x0 + k * dx, y0 + k * dy } end
        return p
    end
    local east, north, south = row(0, 0, 1, 0, 9), row(0, 0, 0, 1, 9), row(0, 0, 0, -1, 9)
    local function live()   -- the supply scenes standing in the engine
        local out = {}
        for id in pairs(live_scenes) do if id:match('^derpy_mr_supply_') then out[#out + 1] = id end end
        table.sort(out)
        return out
    end
    local function tally(list_of)   -- of the stub's adds or removes: how many were supply scenes
        local n = 0
        for _, v in ipairs(list_of) do if (v.id or v):match('^derpy_mr_supply_') then n = n + 1 end end
        return n
    end
    assert(R.SUPPLY_INK.supplied == 16 and R.SUPPLY_INK.stretched == 17 and R.SUPPLY_INK.cut == 18,
           'the three supply inks follow the sixteen owner colours')
    -- two armies, one stretched and one at home: one line, in the stretched ink
    armies = { army(9), army(4) }
    at = { [9] = { 0, 0 }, [4] = { 3, 3 } }
    lines = { [9] = { state = 'stretched', source = 'a', path = east, turns = 4 }, [4] = { state = 'home', source = 'b', turns = 0 } }
    local got = R.supply_links(faction)
    assert(#got == 1 and got[1].cqi == 9 and got[1].ink == 17 and got[1].path == east,
           'one stretched army and one at home must give one line in ink 17')
    -- every state with a road, in army-number order; a cut line with no road, and an army with no line, draw nothing
    armies = { army(9), army(6), army(4), army(2), army(1) }
    at[6], at[2], at[1] = { 0, 0 }, { 5, 5 }, { 6, 6 }
    lines = { [9] = { state = 'stretched', path = east, turns = 4 }, [6] = { state = 'cut', path = south, turns = 0 },
              [4] = { state = 'supplied', path = north, turns = 2 }, [2] = { state = 'cut', turns = 0 },
              [1] = { state = 'none', turns = 0 } }
    R.epoch = R.epoch + 1
    got = R.supply_links(faction)
    assert(#got == 3 and got[1].cqi == 4 and got[1].ink == 16 and got[2].cqi == 6 and got[2].ink == 18
        and got[3].cqi == 9 and got[3].ink == 17, 'supplied, cut and stretched lines with a road, in army-number order')
    -- the switch off: no lines, and nobody asked
    switch.route_supply = false
    R.epoch = R.epoch + 1
    local asked = calls
    assert(#R.supply_links(faction) == 0 and calls == asked, 'with the supply lines switched off none are drawn or asked')
    switch.route_supply = nil
    faction.is_human = function() return false end
    assert(#R.supply_links(faction) == 0, 'a faction nobody plays has no supply lines')
    faction.is_human = function() return true end
    -- on the map: a dash on every second hex of each road, under an id of its slot (army-number order: army 4 is slot 0,
    -- army 9 slot 1, whatever order the game lists them in) and hex
    armies = { army(9), army(4) }
    lines = { [9] = { state = 'stretched', path = east, turns = 4 }, [4] = { state = 'supplied', path = north, turns = 2 } }
    R.clear(); R.epoch = R.epoch + 1
    adds, removes = {}, {}
    R.refresh()
    local placed = {}
    for _, a in ipairs(adds) do if a.id:match('^derpy_mr_supply_') then placed[a.id] = a end end
    for _, i in ipairs({ 1, 3, 5, 7, 9 }) do
        local e, n = placed['derpy_mr_supply_1_' .. i], placed['derpy_mr_supply_0_' .. i]
        assert(e and e.x == east[i][1] and e.y == east[i][2] and e.kind == 'derpy_mr_route_dash_0_17_0', 'the stretched road: ' .. i)
        assert(n and n.x == north[i][1] and n.y == north[i][2] and n.kind == 'derpy_mr_route_dash_0_16_6', 'the supplied road: ' .. i)
    end
    assert(tally(adds) == 10 and #live() == 10, 'a dash on every second hex and no more: ' .. tally(adds))
    switch.route_size = 'large'
    R.refresh()
    assert(live_scenes['derpy_mr_supply_1_1'] and R.scenes['derpy_mr_supply_1_1'].scene == 'derpy_mr_route_dash_2_17_0',
           'the line size picks the supply scene too')
    switch.route_size = nil
    R.refresh()
    -- cleared: not one supply scene is left standing, and every one that was placed was taken down
    R.clear()
    adds, removes = {}, {}
    R.refresh()
    local put_up = tally(adds)
    R.clear()
    assert(put_up > 0 and tally(removes) == put_up and #live() == 0, 'R.clear left a supply scene up')
    -- KEPT ANSWERS: an army is asked about when it has moved or the answers were dropped, and not otherwise
    R.epoch = R.epoch + 1
    calls = 0
    R.refresh()
    assert(calls == 2, 'the first refresh asks once for each army: ' .. calls)
    R.refresh(); R.refresh(); R.refresh(true)
    assert(calls == 2, 'refreshes with no army moved asked F.supply_line again: ' .. calls)
    at[9] = { 0, 1 }
    R.refresh()
    assert(calls == 3, 'one army moved, so one question: ' .. calls)
    local steady, read = calls, listed
    cm.get_camera_position = function() return 500, 0, 20 end
    R.refresh(true)
    assert(#live() == 0 and calls == steady, 'a camera move out of sight must take the dashes down without a question')
    cm.get_camera_position = function() return 0, 0, 20 end
    R.refresh(true)
    assert(#live() == 10 and calls == steady, 'a camera move back must place the dashes from the kept answers')
    assert(listed == read, 'a camera move read the army list again, where the last refresh\'s lines still hold')
    R.new_turn()   -- enemy armies moved in between: every answer dropped
    R.refresh()
    assert(calls == steady + 2, 'a turn start must ask each army again: ' .. calls)
    R.epoch = R.epoch + 1   -- F.invalidate_reach moves it too
    R.refresh()
    assert(calls == steady + 4, 'a war or a capture must ask each army again: ' .. calls)
    -- an army that is gone loses its kept answer, and its slot passes to the next army: its dashes are taken down and the
    -- survivor's stand in the slot it has now (army 4 was slot 0, so army 9 takes it over from slot 1)
    assert(#live() == 10 and live_scenes['derpy_mr_supply_1_1'], 'two armies, two slots')
    armies = { army(9) }
    R.refresh()
    assert(R.supply_kept[4] == nil and R.supply_kept[9], 'a dead army\'s answer outlived it')
    local ids = live()
    assert(#ids == 5, 'a dead army\'s dashes outlived it: ' .. table.concat(ids, ' '))
    for _, id in ipairs(ids) do assert(id:match('^derpy_mr_supply_0_%d+$'), 'the survivor kept its old slot: ' .. id) end
    local third = R.scenes['derpy_mr_supply_0_3']
    assert(third.x == east[3][1] and third.y == east[3][2] and third.scene == 'derpy_mr_route_dash_0_17_0',
           'the survivor\'s road was not put where the dead army\'s was')
    -- slots follow the order of the army numbers alive, whatever order the game lists them in, and never the numbers
    -- themselves: an army numbered past the slots still has one, inside the range a loaded game sweeps
    armies = { army(1200), army(9) }
    at[1200] = { 0, 0 }
    lines[1200] = { state = 'supplied', path = north, turns = 2 }
    R.refresh()
    got = R.supply_links(faction)
    assert(#got == 2 and got[1].cqi == 9 and got[1].slot == 0 and got[2].cqi == 1200 and got[2].slot == 1,
           'slots are given in army-number order')
    R.refresh()
    assert(#live() == 10 and R.scenes['derpy_mr_supply_1_3'].y == north[3][2] and R.scenes['derpy_mr_supply_0_3'].y == east[3][2],
           'the lower army number must take slot 0')
    for _, id in ipairs(live()) do
        assert(tonumber(id:match('^derpy_mr_supply_(%d+)_')) < R.SUPPLY_SLOTS, 'an id outside the swept range: ' .. id)
    end
    -- armies past the slots are not drawn: the lowest numbers keep them
    local slots = R.SUPPLY_SLOTS
    R.SUPPLY_SLOTS = 1
    R.epoch = R.epoch + 1
    got = R.supply_links(faction)
    assert(#got == 1 and got[1].cqi == 9 and got[1].slot == 0, 'an army past the last slot was drawn')
    R.SUPPLY_SLOTS = slots
    -- a long road is rationed, from the army outwards
    armies = { army(9) }
    lines = { [9] = { state = 'cut', path = row(0, 0, 1, 0, 1000), turns = 0 } }
    cm.get_camera_position = function() return 0, 0, 1000 end
    R.clear(); R.epoch = R.epoch + 1
    R.refresh()
    assert(#live() == R.SUPPLY_CAP and live_scenes['derpy_mr_supply_0_1'] and live_scenes['derpy_mr_supply_0_511']
        and not live_scenes['derpy_mr_supply_0_513'], 'a long road must keep the dashes nearest its army, to the cap')
    -- a supply line that throws must not stop the trade roads from being drawn
    cm.get_camera_position = function() return 0, 0, 20 end
    DERPY_MR_FLOWS.supply_line = function() error('boom') end
    R.links = function() return { { key = 'trade', owner = 'viewer', own = true, path = east } }, {} end
    R.clear(); R.epoch = R.epoch + 1
    assert(pcall(R.refresh), 'a supply line that threw stopped the map')
    assert(next(R.scenes) ~= nil and #live() == 0 and R.supply_failed, 'the trade road was not drawn, or the throw not noted')
    R.supply_failed = nil
    -- A LOADED GAME (through R.init, as the game starts it): the engine keeps the scenes of a save, the script keeps
    -- nothing, and the army that drew some may have died before the save. The whole fixed range of ids is cleared, slot by
    -- slot and hex by hex up to the longest road a reach can make, whoever is alive.
    DERPY_MR_FLOWS.supply_line = ask
    R.links = function() return {}, {} end
    armies = { army(9), army(1200) }
    lines = { [9] = { state = 'stretched', path = east, turns = 4 }, [1200] = { state = 'supplied', path = north, turns = 2 } }
    R.clear(); R.epoch = R.epoch + 1
    R.refresh()
    assert(#live() == 10, 'two armies must have put their dashes up before the save')
    R.scenes, R.drawn, R.supply_kept, R.supply_epoch, R.traffic = {}, nil, {}, nil, {}   -- a fresh Lua state; live_scenes stays
    armies = {}                                                                       -- both armies died before the save
    local saved_add, saved_mp, saved_model, saved_grids, saved_repeat = core.add_listener, cm.is_multiplayer, cm.model, R.grids, cm.repeat_real_callback
    local listeners = {}
    core.add_listener = function(_, name, event, cond, action) listeners[name] = { event = event, cond = cond, action = action } end
    cm.is_multiplayer = function() return false end
    cm.model = function() return { campaign_name_key = function() return 'test' end } end
    cm.repeat_real_callback = function() end
    R.grids = { test = g }
    removes = {}
    R.started = nil
    R.init()
    assert(#live() == 0, 'a loaded game left a dead army\'s dashes standing: ' .. table.concat(live(), ' '))
    local per = {}
    for _, id in ipairs(removes) do
        local s, i = id:match('^derpy_mr_supply_(%d+)_(%d+)$')
        if s then
            per[tonumber(s)] = (per[tonumber(s)] or 0) + 1
            assert(tonumber(i) % 2 == 1 and tonumber(i) <= 401 and tonumber(s) < R.SUPPLY_SLOTS, 'swept an id no road can have: ' .. id)
        end
    end
    for slot = 0, R.SUPPLY_SLOTS - 1 do assert(per[slot] == 201, 'slot ' .. slot .. ' was swept ' .. tostring(per[slot]) .. ' times, not for each of its 201 hexes') end
    -- a multiplayer game draws nothing, but its saves can hold these scenes as well: swept all the same, and no listener
    local sp_listeners = listeners
    listeners, removes, R.started = {}, {}, nil
    cm.is_multiplayer = function() return true end
    R.init()
    assert(tally(removes) == R.SUPPLY_SLOTS * 201 and next(listeners) == nil, 'a multiplayer start must sweep the supply ids and listen to nothing')
    -- an army that has moved asks for the map to be drawn again at the next tick, and only the player's does
    local moved = sp_listeners['derpy_mr_terrain_routes_moved']
    assert(moved and moved.event == 'CharacterFinishedMovingEvent', 'no listener for an army finishing its move')
    local function mover(fkey)
        return { character = function() return { faction = function() return { name = function() return fkey end } end } end }
    end
    assert(moved.cond(mover('viewer')) == true and moved.cond(mover('other')) == false, 'only the local faction\'s armies count')
    R.dirty = false
    moved.action(mover('viewer'))
    assert(R.dirty == true, 'a move left the map to the timed refresh')
    core.add_listener, cm.is_multiplayer, cm.model, R.grids, cm.repeat_real_callback = saved_add, saved_mp, saved_model, saved_grids, saved_repeat
    R.started = nil
    R.clear()
    R.links, cm.get_camera_position, DERPY_MR_FLOWS = saved_links, saved_camera, saved_flows
    faction.military_force_list, faction.is_human = saved_forces, saved_human
    R.drawn, R.camera, R.dirty, R.supply_kept = nil, nil, false, {}
end
assert(next(live_scenes) == nil, 'cleanup left a supply scene in the engine')

-- NOTHING KEPT, the whole module (the 1.0 live pass, 2026-11-02): once every test above has run, no engine interface
-- is reachable from R through its tables or its functions' upvalues. A stub interface stands in for the engine's
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
    walk(R, "R")
    table.sort(found)
    assert(#found == 0, "engine interfaces kept in the terrain routes module: " .. table.concat(found, " "))
end

print('terrain routes harness ok: routing, corridor merging, rounded geometry, ordered traffic, fog and cleanup')
