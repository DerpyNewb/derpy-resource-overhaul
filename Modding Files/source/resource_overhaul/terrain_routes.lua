-- Generated campaign grids precede this source. Rendering never changes stores or shipments.
DERPY_MR_TERRAIN_ROUTES = DERPY_MR_TERRAIN_ROUTES or {}
local R = DERPY_MR_TERRAIN_ROUTES
R.grids = DERPY_MR_ROUTE_GRIDS or {}
R.vehicles = DERPY_MR_VEHICLE_PROFILES or {}
R.vehicle_profiles = {}
R.cache, R.queue, R.scenes, R.bundled = {}, {}, {}, {}
R.traffic, R.cart_scenes, R.icon_scenes, R.CART_LIMIT = {}, {}, {}, 16
R.alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
R.masks = {}
for i = 1, 64 do R.masks[string.byte(R.alphabet, i)] = i - 1 end
R.dirs = {
    { {0,1}, {1,0}, {1,-1}, {0,-1}, {-1,-1}, {-1,0} },
    { {0,1}, {1,1}, {1,0}, {0,-1}, {-1,0}, {-1,1} }
}
R.bits = { 1, 2, 4, 8, 16, 32 }

function R.index(g, x, y)
    if x >= 0 and y >= 0 and x < g.w and y < g.h then return y * g.w + x + 1 end
end

function R.point(g, id)
    return { (id - 1) % g.w, math.floor((id - 1) / g.w) }
end

-- The open list: a binary heap in three arrays (estimate, hex, cost), so a push makes no table.
function R.heap()
    return { n = 0, f = {}, id = {}, cost = {} }
end

function R.push(h, f, id, cost)
    local F, I, C = h.f, h.id, h.cost
    local i = h.n + 1
    h.n = i
    while i > 1 do
        local parent = math.floor(i / 2)
        if F[parent] <= f then break end
        F[i], I[i], C[i] = F[parent], I[parent], C[parent]
        i = parent
    end
    F[i], I[i], C[i] = f, id, cost
end

-- -> the hex and cost of the lowest estimate
function R.pop(h)
    local F, I, C, n = h.f, h.id, h.cost, h.n
    local id, cost = I[1], C[1]
    local lf, li, lc = F[n], I[n], C[n]
    F[n], I[n], C[n] = nil, nil, nil
    n = n - 1
    h.n = n
    if n > 0 then
        local i = 1
        while i * 2 <= n do
            local child = i * 2
            if child < n and F[child + 1] < F[child] then child = child + 1 end
            if lf <= F[child] then break end
            F[i], I[i], C[i] = F[child], I[child], C[child]
            i = child
        end
        F[i], I[i], C[i] = lf, li, lc
    end
    return id, cost
end

-- Enemy or aggressive land costs R.AVOID per hex: a route detours round it where it can and still crosses
-- where it cannot (an island, a besieged pass). Aggressive is the diplomacy screen's "very unfriendly" or worse.
R.AVOID, R.AGGRESSIVE, R.epoch, R.queued = 5, -70, 1, {}
R.SHOW_BUDGET, R.shows, R.show_until = 0.004, 0, 0   -- seconds of new reach answers a map refresh may work out
R.SEARCH_CAP = 200000   -- hexes one search may expand; past it, it gives up with no road

function R.hostile(owner, parties)
    for _, p in ipairs(parties) do
        if owner:name() == p:name() then return false end
    end
    -- CLOSED ROADS (the Roads edict, design 2026-11-01 Part B): the owner's land is hostile to every road but its own
    local F = DERPY_MR_FLOWS
    if F and F.edict and F.edict(owner:name(), 'roads') == 'closed' then return true end
    if owner:is_rebel() then return true end
    for _, p in ipairs(parties) do
        if owner:at_war_with(p) or owner:diplomatic_attitude_towards(p:name()) <= R.AGGRESSIVE then return true end
    end
    return false
end

function R.start(g, a, b, avoid)
    local first, target = R.index(g, a[1], a[2]), R.index(g, b[1], b[2])
    local j = { g = g, target = target, dest = b, open = R.heap(), costs = {}, prev = {}, count = 0, avoid = avoid, seen = {} }
    if first and target then j.costs[first] = 0; R.push(j.open, 0, first, 0) end
    return j
end

function R.advance(j, budget)
    local g, open, costs, prev, seen = j.g, j.open, j.costs, j.prev, j.seen
    local w, all_bridges = g.w, g.bridges
    local floor, abs, max = math.floor, math.abs, math.max
    -- LOCALS AND R.index INLINED (2026-11-08: 10 us a hex, 3.6 s of a computer round at turn 17); the same hexes
    -- in the same order, so the same road
    local h, data, byte, masks, bits, dirs = g.h, g.data, string.byte, R.masks, R.bits, R.dirs
    local neighbours = {}   -- this call's scratch: entries past `near` are stale
    local avoid, wall, corridor, shared, limit, target = j.avoid, j.wall, j.corridor, j.shared, j.max, j.target
    local model = avoid and cm:model()   -- this entry's: a queued job may be many ticks old
    local tx, ty = j.dest[1], j.dest[2]
    for _ = 1, budget do
        if open.n == 0 or j.count >= R.SEARCH_CAP then return true end
        local id, cost = R.pop(open)
        if id == target then
            local reverse, path = {}, {}
            while id do reverse[#reverse + 1] = R.point(g, id); id = prev[id] end
            for i = #reverse, 1, -1 do path[#path + 1] = reverse[i] end
            return true, path
        end
        if costs[id] == cost then
            j.count = j.count + 1
            local x, y = (id - 1) % w, floor((id - 1) / w)
            -- WORKED OUT EACH TIME, NEVER KEPT (Workshop reports, 2026-11-04 to 11-07: stutter that grew the longer a
            -- session ran). A table kept per hex ever searched held 74 MB of the Lua heap by turn 16 of a measured IE
            -- game and was never freed; each garbage collection walked it (294 ms a full collection with it, 48 ms
            -- without). Measured offline on the IE grid, 150 searches: 8.0 us a hex this way, 8.2 for the kept table's
            -- first visit and 5.2 for a repeat visit; the same road in all 150.
            local near, mask = 0, masks[byte(data, id)] or 0
            local ds = dirs[x % 2 + 1]
            for d = 1, 6 do
                if floor(mask / bits[d]) % 2 == 1 then
                    local delta = ds[d]
                    local nx, ny = x + delta[1], y + delta[2]
                    if nx >= 0 and ny >= 0 and nx < w and ny < h then
                        local other = ny * w + nx + 1
                        if floor((masks[byte(data, other)] or 0) / bits[(d + 2) % 6 + 1]) % 2 == 1 then
                            near = near + 1
                            neighbours[near] = other
                        end
                    end
                end
            end
            local bridges = all_bridges[id]
            for n = 1, near + (bridges and #bridges or 0) do
                local other = n <= near and neighbours[n] or bridges[n - near]
                local qx, qy = (other - 1) % w, floor((other - 1) / w)
                local step, walled = max(1, abs(qx - x), abs(qy - y)), false
                if corridor and not corridor[other] then walled = true end
                if avoid then
                    if seen[other] == nil then seen[other] = avoid(qx, qy, model) end
                    if seen[other] then
                        if wall then walled = true else step = step * R.AVOID end
                    end
                end
                if shared and shared[other] then step = step * 0.25 end
                local next_cost = cost + step
                -- the estimate never overstates a hex distance, so a node past j.max cannot lead to a road within it
                local estimate = max(abs(qx - tx), abs(qy - ty))
                if shared then estimate = estimate * 0.25 end
                -- no math.huge here: it is not safe to assume in the game's Lua (2026-10-21 handoff)
                if not walled and (not limit or next_cost + estimate <= limit)
                    and (not costs[other] or next_cost < costs[other]) then
                    costs[other], prev[other] = next_cost, id
                    R.push(open, next_cost + estimate, other, next_cost)
                end
            end
        end
    end
    return false
end

-- Paths are checked again whenever R.epoch moves (each turn, each war or diplomatic event), since wars and
-- attitudes move. A road whose every region still judges the same is the road a new search would find (R.unchanged,
-- as R.reach), so it is given again unsearched; a changed one is searched again and its old line stays up meanwhile
-- (2026-10-29: re-searching every shown road at every diplomatic event was 4 s of each computer round).
R.kept = {}
function R.path(from, to)
    local key = from .. '>' .. to
    if R.queued[key] == R.epoch or not R.grid then return R.cache[key] or nil end
    R.queued[key] = R.epoch
    local a, b = cm:get_region(from), cm:get_region(to)
    if not a or not b or a:is_null_interface() or b:is_null_interface() then return R.cache[key] or nil end
    local kept = R.kept[key]
    if kept and kept.data == R.grid.data and R.unchanged(kept.regions, a, b) then
        R.cache[key] = kept.path
        return kept.path or nil
    end
    local regions = {}
    local avoid = R.avoider(a, b, regions)
    a, b = a:settlement(), b:settlement()
    if a:is_null_interface() or b:is_null_interface() then return R.cache[key] or nil end
    local j = R.start(R.grid, {a:logical_position_x(), a:logical_position_y()},
                               {b:logical_position_x(), b:logical_position_y()}, avoid)
    j.key, j.regions = key, regions
    R.queue[#R.queue + 1] = j
    return R.cache[key] or nil
end

-- (x, y) -> is that hex enemy or aggressive land to the owners of regions a and b; one verdict per owner.
-- A hex's verdict is its region's, worked out once per region and filed in `regions` (key -> verdict).
-- The second result judges a region the same way, for R.unchanged.
-- KEYS, NOT INTERFACES (the 1.0 live pass, 2026-11-02): a queued search runs over many ticks, and an interface kept
-- from an earlier tick is freed memory. The parties are kept by key and looked up again for each new owner, and the
-- model comes from R.advance, once a call.
function R.avoider(a, b, regions)
    local parties = {}
    for _, region in ipairs({a, b}) do
        local owner = region:owning_faction()
        if not owner:is_null_interface() then parties[#parties + 1] = owner:name() end
    end
    return R.avoider_for(parties, regions)
end

-- The same judge for parties named by key: an army's supply road is judged for its own faction alone (flows.lua
-- F.supply_line, design 2026-11-08 section 4).
function R.avoider_for(parties, regions)
    local verdicts = {}
    regions = regions or {}
    local function judge(region)
        local owner = region:owning_faction()
        if owner:is_null_interface() then return false end
        local name = owner:name()
        if verdicts[name] == nil then
            local now = {}
            for _, key in ipairs(parties) do
                local p = cm:get_faction(key)
                if p and not p:is_null_interface() then now[#now + 1] = p end
            end
            verdicts[name] = R.hostile(owner, now)
        end
        return verdicts[name]
    end
    return function(x, y, model)
        local region = (model or cm:model()):get_region_at_logical_position(x, y)
        if region:is_null_interface() then return false end
        local key = region:name()
        if regions[key] == nil then regions[key] = judge(region) end
        return regions[key]
    end, judge
end

-- Would every region a walled search looked at still give it the same verdict? Then it would find the
-- same road: the search is a function of the terrain and those verdicts alone (land changing hands is
-- a region whose verdict is asked again, so no event has to be heard for it).
function R.unchanged(regions, from, to)
    local _, judge = R.avoider(from, to)
    for key, was in pairs(regions) do
        local region = cm:get_region(key)   -- false, not a null interface, for no such region
        if not region or region:is_null_interface() or judge(region) ~= was then return false end
    end
    return true
end

-- THE COMPUTERS' TERMS (Workshop reports 2026-11-08 to 11-10; measured on IEE 2026-11-11: one computer turn start
-- spent 4.4 s, and one round 54 s, searching roads inside single frames). `terms`, nil for no limit, is
-- { left = hexes still to search, keep = turns a kept answer is trusted }, one table a turn start (flows.lua
-- F.search_terms). Counted in hexes, never seconds, so every machine stops at the same hex.
-- The owners of a road's two ends, which a kept answer or a search under way was made for.
function R.owners(from, to)
    local function key(region)
        local f = region:owning_faction()
        return f:is_null_interface() and '' or f:name()
    end
    return key(from) .. '>' .. key(to)
end

-- A kept answer still the answer? Unchecked for terms.keep turns while both ends keep their owners (a war far along a
-- computer's road reaches its trade a few turns late, not for a search of half the map every turn); else while every
-- region its search judged still judges the same, and then trusted again from today.
function R.fresh(memo, g, from, to, owners, turn, terms)
    if not (memo and memo.data == g.data) then return false end
    if terms and memo.owners == owners and turn - memo.checked < terms.keep then return true end
    if not R.unchanged(memo.regions, from, to) then return false end
    memo.owners, memo.checked = owners, turn
    return true
end

-- The search kept under `key`, or a new one (make(regions) starts it) when there is none, its ends have changed hands
-- or the map has. Searches nobody asked about for over a turn are dropped as a new one starts: each holds a table a
-- hex it has seen.
function R.job(jobs, key, owners, g, turn, make)
    local job = jobs[key]
    if not (job and job.owners == owners and job.data == g.data) then
        for k, old in pairs(jobs) do if turn - old.turn > 1 then jobs[k] = nil end end
        job = { owners = owners, data = g.data, regions = {} }
        job.j = make(job.regions)
        jobs[key] = job
    end
    job.turn = turn
    return job
end

-- A search to its end, or until terms.left hexes are spent: false then, and the next call goes on from there.
-- A step it does not finish is charged whole, one it finishes by the hexes it opened, so no step overdraws.
function R.run(j, terms)
    while true do
        local step = terms and math.min(100000, terms.left) or 100000
        if step <= 0 then return false end
        local before = j.count
        local done, path = R.advance(j, step)
        if terms then terms.left = terms.left - (done and j.count - before or step) end
        if done then return true, path end
    end
end

-- TRADE REACH: is there a road between two settlements that stays off land hostile to either owner and is
-- no longer than max hexes (nil: any length)? Returns ok, why ('far' or 'enemy') and the road; nil, 'pending'
-- while a search under the computers' terms is still under way. For the economy at a turn start; enemy land
-- is a wall here, where R.path only charges for it.
-- Answers are kept by road (its two ends and max) and given again while R.fresh holds: with no terms that is
-- R.unchanged, the answer a new search would give. Every machine asks the same questions at the same points,
-- so each keeps the same answers and the same searches under way.
-- ponytail: kept for every pair ever asked; prune by last use if memory shows it.
R.reach_memo, R.free_memo, R.reach_jobs = {}, {}, {}
function R.reach(from, to, max, terms)
    local g = R.grids[cm:model():campaign_name_key()]
    if not g then return true end   -- a map with no grid has nothing to judge by, so trade is never stopped
    local a, b = from:settlement(), to:settlement()
    local first, last = {a:logical_position_x(), a:logical_position_y()}, {b:logical_position_x(), b:logical_position_y()}
    if max and math.max(math.abs(first[1] - last[1]), math.abs(first[2] - last[2])) > max then return false, 'far' end
    local key = first[1] .. ',' .. first[2] .. '>' .. last[1] .. ',' .. last[2] .. '>' .. tostring(max)
    -- the road through enemy land too: terrain alone, so worked out once per road and map, when first needed
    local free = R.free_memo[key]
    if free and free.data ~= g.data then free = nil end
    -- no road even through enemy land, the search having run to its end: a walled one cannot find one either
    if free and not free.open and free.finished then return false, 'far' end
    local turn, owners = cm:model():turn_number(), R.owners(from, to)
    local memo = R.reach_memo[key]
    if R.fresh(memo, g, from, to, owners, turn, terms) then return memo.ok, memo.why, memo.path end
    local job = R.job(R.reach_jobs, key, owners, g, turn, function(regions)
        local j = R.start(g, first, last, R.avoider(from, to, regions))
        j.wall, j.max = true, max
        return j
    end)
    if not job.searched then
        local done, path = R.run(job.j, terms)
        if not done then return nil, 'pending' end
        job.searched, job.path = true, path
    end
    if not job.path and not free then
        if not job.free then
            job.free = R.start(g, first, last)
            job.free.wall, job.free.max = true, max
        end
        local done, road = R.run(job.free, terms)
        if not done then return nil, 'pending' end
        free = { data = g.data, open = road ~= nil, finished = job.free.count < R.SEARCH_CAP }
        R.free_memo[key] = free
    end
    R.reach_jobs[key] = nil
    -- no safe road: the enemy is to blame when a road through their land would have been short enough
    memo = { data = g.data, regions = job.regions, owners = owners, checked = turn, ok = job.path ~= nil, path = job.path,
             why = not job.path and (free.open and 'enemy' or 'far') or nil }
    R.reach_memo[key] = memo
    return memo.ok, memo.why, memo.path
end

-- Computed by the synchronized dispatch, then saved on the cargo; never use the UI's path cache here.
-- KEPT AS R.reach KEEPS ITS ANSWERS (2026-11-08: one search a cart, 0.9 s of a computer round at turn 18), and under
-- the same terms: nil, 'pending' while a computer's search is under way (the cart then leaves with no road).
-- Each caller gets its own copy of the list, as a cargo keeps it.
-- ponytail: kept for every pair ever sent; prune by last use if memory shows it, as R.reach_memo.
R.journey_memo, R.journey_jobs = {}, {}
function R.journey(from, to, terms)
    local g = R.grids[cm:model():campaign_name_key()]
    if not g then return nil end
    local a, b = from:settlement(), to:settlement()
    local first, last = {a:logical_position_x(), a:logical_position_y()}, {b:logical_position_x(), b:logical_position_y()}
    local key = first[1] .. ',' .. first[2] .. '>' .. last[1] .. ',' .. last[2]
    local turn, owners = cm:model():turn_number(), R.owners(from, to)
    local memo = R.journey_memo[key]
    if not R.fresh(memo, g, from, to, owners, turn, terms) then
        local job = R.job(R.journey_jobs, key, owners, g, turn, function(regions)
            return R.start(g, first, last, R.avoider(from, to, regions))
        end)
        local done, path = R.run(job.j, terms)
        if not done then return nil, 'pending' end
        R.journey_jobs[key] = nil
        memo = { data = g.data, regions = job.regions, owners = owners, checked = turn, path = path }
        R.journey_memo[key] = memo
    end
    if not memo.path then return nil end
    local copy = {}
    for i, point in ipairs(memo.path) do copy[i] = point end
    return copy
end

function R.pump()
    local j = R.queue[1]
    if not j then return end
    local done, path = R.advance(j, 1000)
    if done then
        R.cache[j.key] = path or false
        if j.regions then R.kept[j.key] = { path = path or false, regions = j.regions, data = j.g.data } end
        table.remove(R.queue, 1)
        R.dirty = true
        core:trigger_event('DerpyMRTerrainRoutesUpdated')
    end
end

function R.colour(key)
    local n = 0
    for i = 1, string.len(key) do n = (n + string.byte(key, i)) % 4 end
    return n
end

-- THE PLAYER'S CHOICE (MCT, 2026-10-22): line size and colour set, in build_mr_terrain_routes.SIZES and
-- COLOUR_SETS order (its selftest compares them). A scene exists for every size, colour and direction. Not
-- frozen into the save: it moves no trade, so a new choice shows at the next redraw.
R.SIZES = { 'small', 'normal', 'large' }
R.SETS = { 'default', 'bright', 'pale', 'colourblind' }
function R.style()
    local F = DERPY_MR_FLOWS
    local function pick(list, key, fallback)
        for i, k in ipairs(list) do if k == key then return i - 1 end end
        return fallback
    end
    local mct = F and F.mct or function(_) return nil end
    return pick(R.SIZES, mct('route_size'), 0), pick(R.SETS, mct('route_colours'), 0)
end

-- An owner's colour in the chosen set, as an index into the palette (the Vault Map's templates share it).
function R.ink(key, set)
    if not set then set = select(2, R.style()) end
    return set * 4 + R.colour(key)
end

function R.shown(kind)
    local F=DERPY_MR_FLOWS
    return not F or not F.mct or F.mct('route_'..kind)~=false
end

-- Decorative traffic advertises permitted goods; it does not dispatch or debit stock.
function R.goods(seller,buyer)
    local F,goods=DERPY_MR_FLOWS,{}
    for _,g in ipairs(DERPY_MR_FLOWS_GOODS or {}) do
        if not F.stopped(seller,'export',g.stem) and not F.stopped(buyer,'import',g.stem) then
            goods[#goods+1]=g.stem
        end
    end
    return goods
end

function R.vehicle(fkey,sea)
    if not fkey then return nil end
    local profile=R.vehicle_profiles[fkey]
    if not profile then
        local faction=cm:get_faction(fkey)
        if not faction or faction:is_null_interface() then return nil end
        profile=R.vehicles[faction:culture()] or R.vehicles['*']
        R.vehicle_profiles[fkey]=profile
    end
    return profile and profile[sea and 'sea' or 'land']
end

-- THE CART GOODS' PREVIEWS ARE KEPT (2026-10-29): one allocator preview is ~3 ms and a refresh asked for ten, so a
-- still camera's timed refresh stalled a frame. The map keeps them in R.plans and works out one seller again every
-- R.PLAN_EVERY ticks (R.renew_plan), so no frame pays for them all.
-- ONCE A TURN FOR A COMPUTER (IEE, 2026-11-11: a big partner's preview was 57-85 ms every few seconds, 346 ms at
-- worst): a computer's stores move only at its own turn start, so each computer seller is worked out once in the
-- player's turn (R.plan_fresh, emptied by R.new_turn) and after that only the viewer's own comes round again, which a
-- recruit moves and nothing reports. A player's action (flows.lua F.dispatch) drops them all. A partner's carts to the
-- player can lag a recruit of the player's until the next turn.
R.plans, R.plan_fresh, R.reach_shown, R.spots = {}, {}, {}, {}
function R.renew_plan()
    local F = DERPY_MR_FLOWS
    if not F then return end
    local me, stale, seller = cm:get_local_faction_name(true), {}, nil
    for s in pairs(R.plans) do if s ~= me and not R.plan_fresh[s] then stale[#stale + 1] = s end end
    if #stale > 0 then
        table.sort(stale)
        seller = stale[1]
    elseif R.plans[me] then seller = me
    else return end
    local faction = cm:get_faction(seller)
    if faction and not faction:is_null_interface() then R.plans[seller], R.plan_fresh[seller] = F.trade(faction, true), true end
end

function R.carried(goods,seller,buyer,plans)
    local F,stocked=DERPY_MR_FLOWS,{}
    if not plans[seller] then plans[seller]=F.trade(cm:get_faction(seller),true); R.plan_fresh[seller]=true end
    local allowed={}
    for _,stem in ipairs(plans[seller][buyer] or {}) do allowed[stem]=true end
    for _,stem in ipairs(goods) do
        if allowed[stem] then stocked[#stocked+1]=stem end
    end
    return stocked
end

-- Rounded corners run from the incoming edge midpoint through this tile to the outgoing midpoint.
function R.corner(path,i,reverse)
    local p=path[i]
    local a=path[i+(reverse and 1 or -1)] or path[i+(reverse and -1 or 1)]
    local b=path[i+(reverse and -1 or 1)] or a
    if not a or not b then return nil end
    for _,q in ipairs({a,b}) do
        if math.max(math.abs(q[1]-p[1]),math.abs(q[2]-p[2]))>1 then return nil end
    end
    local ax,ay=cm:log_to_dis(a[1],a[2])
    local px,py=cm:log_to_dis(p[1],p[2])
    local bx,by=cm:log_to_dis(b[1],b[2])
    local angle=math.atan2((px-ax)*(by-py)-(py-ay)*(bx-px),(px-ax)*(bx-px)+(py-ay)*(by-py))
    return p,b,angle,ax,ay,px,py,bx,by
end

function R.sample(path,i)
    local p,b,angle,ax,ay,px,py,bx,by=R.corner(path,i)
    if p and i>1 and i<#path then return (ax+px*6+bx)/8,(ay+py*6+by)/8 end
    return cm:log_to_dis(path[i][1],path[i][2])
end

-- Native decals ignore facing: each tangent and signed corner offset has a baked scene.
R.ANGLES = 12
function R.turn(angle)
    return math.floor(math.abs(angle)/math.pi*3+0.5)*(angle<0 and -1 or 1)
end
function R.dash(path, i, ink, size)
    local a, b = path[math.max(1, i - 1)], path[math.min(#path, i + 1)]
    local ax, ay = cm:log_to_dis(a[1], a[2])
    local bx, by = cm:log_to_dis(b[1], b[2])
    local full = math.floor(math.atan2(by - ay, bx - ax) / math.pi * R.ANGLES + 0.5) % (R.ANGLES*2)
    local bend=0
    if i>1 and i<#path then
        local p,q,angle=R.corner(path,i)
        if p then bend=R.turn(angle); if full>=R.ANGLES then bend=-bend end end
    end
    local key='derpy_mr_route_dash_' .. size .. '_' .. ink .. '_' .. (full%R.ANGLES)
    if bend~=0 and math.abs(bend)<3 then key=key..'_b'..(bend+2) end
    return key
end

function R.hide_icon(id)
    cm:remove_scripted_composite_scene(id..'_a')
    cm:remove_scripted_composite_scene(id..'_b')
end

function R.clear()
    for id in pairs(R.scenes) do cm:remove_scripted_composite_scene(id) end
    for id in pairs(R.cart_scenes) do cm:remove_scripted_composite_scene(id) end
    for id in pairs(R.icon_scenes) do R.hide_icon(id) end
    R.scenes = {}
    R.traffic, R.cart_scenes, R.icon_scenes = {}, {}, {}
    R.depart_at = nil
end

-- Every cart moves one hex a second, so a waiting cart leaves only if it would pass each hex it shares with a
-- moving cart at least R.GAP seconds apart; an exactly opposing corridor has its own lane. Reserving the whole
-- remaining road let one cart at a time through a hub every route shares (author, 2026-10-23).
R.GAP = 4
function R.can_depart(trip,traffic)
    if not trip.cells then
        trip.cells={}
        for i,p in ipairs(trip.path) do trip.cells[p[1]..':'..p[2]]=i end
    end
    local function same(a,b) return a==b or (a and b and a[1]==b[1] and a[2]==b[2]) end
    for _,other in ipairs(traffic) do
        if other~=trip and other.active then
            local direction=other.reverse and -1 or 1
            local now=other.distance+1
            local first=math.max(1,math.min(#other.path,now-direction*3))
            local last=other.reverse and 1 or #other.path
            for i=first,last,direction do
                local p=other.path[i]
                local j=trip.cells[p[1]..':'..p[2]]
                if j then
                    local mine=trip.reverse and -1 or 1
                    local bend
                    if j>1 and j<#trip.path then local _,_,angle=R.corner(trip.path,j,trip.reverse);bend=angle end
                    local opposing=same(trip.path[j-mine],other.path[i+direction])
                        and same(trip.path[j+mine],other.path[i-direction])
                        and not (bend and math.abs(bend)>math.pi/2)
                    local ours=trip.reverse and #trip.path-j or j-1
                    if not opposing and math.abs(ours-(i-now)*direction)<R.GAP then return false end
                end
            end
        end
    end
    return true
end

-- THE CARTS' CLOCK (author, 2026-11-03: the carts stuttered every other second). A cart's scene rounds its hex in
-- exactly a second, and a step every tenth 100 ms tick came ~9% late, so every cart sat still at every hex end.
-- Steps follow the real clock (R.now, ms) on a timer of their own that comes round every frame, and keep their beat
-- unless the game stalled past R.STEP_LATE. Departures are looked at every R.DEPART_EVERY.
R.STEP, R.STEP_LATE, R.DEPART_GAP, R.DEPART_EVERY, R.CART_MS = 1000, 250, 6000, 500, 15
-- THE ICON'S HANDOFF: the old icon is held at the join while the new one's emitter makes its first frames, so the
-- icon never blinks out (2026-10-23). R.ICON_HOLD ms is two frames at 60 fps: the 100 ms it was showed the old icon
-- left behind once the carts stopped waiting at the join (author, 2026-11-03: the carried icons twitched).
R.ICON_HOLD = 40
function R.now() return os.clock() * 1000 end
R.CART_IDS = {}
for slot = 1, R.CART_LIMIT do R.CART_IDS[slot] = { 'derpy_mr_traffic_' .. slot, 'derpy_mr_traffic_' .. slot .. '_icon' } end

-- A cart's scene for the hex it is on, worked out once a step: the region read and the strings are what the
-- per-frame timer cannot pay for every frame.
function R.place(trip)
    local pl, i = {}, trip.distance + 1
    trip.place = pl
    local p, b, angle = R.corner(trip.path, i, trip.reverse)
    if not p then return pl end
    local curve = R.turn(angle) % 6
    if trip.steps == 0 then curve = 7 elseif i == 1 or i == #trip.path then curve = 6 end
    local sea = cm:model():get_region_at_logical_position(p[1], p[2]):is_null_interface()
    local scene = (sea and 'derpy_mr_route_boat_curve_' or 'derpy_mr_route_cart_curve_') .. curve
    local vehicle = R.vehicle(trip.vehicle_faction, sea)
    if vehicle then scene = 'derpy_mr_route_vehicle_' .. vehicle .. '_' .. curve end
    pl.x, pl.y, pl.fx, pl.fy, pl.scene, pl.curve, pl.sea = p[1], p[2], b[1], b[2], scene, curve, sea
    pl.dx, pl.dy = cm:log_to_dis(p[1], p[2])
    pl.key = trip.key .. ':' .. tostring(trip.path) .. ':' .. i .. ':' .. tostring(trip.reverse == true) .. ':'
        .. tostring(sea) .. ':' .. scene
    return pl
end

function R.animate()
    if not R.camera then return end
    local now = R.now()
    if now >= (R.depart_at or 0) then
        R.depart_at = now + R.DEPART_EVERY
        while true do
            local next_trip
            for _,trip in ipairs(R.traffic) do
                local g=trip.goods
                -- A one-way route starts its next load from the source instead of driving home empty.
                if not trip.active and g and #g[trip.reverse and 2 or 1]==0 and #g[trip.reverse and 1 or 2]>0 then
                    trip.reverse=not trip.reverse
                    trip.distance=trip.reverse and #trip.path-1 or 0
                end
                if not trip.active and (not trip.last_departure or now-trip.last_departure>=R.DEPART_GAP)
                    and R.can_depart(trip,R.traffic)
                    and (not next_trip or (trip.last_departure or 0)<(next_trip.last_departure or 0)) then next_trip=trip end
            end
            if next_trip then
                next_trip.active,next_trip.steps,next_trip.due,next_trip.fresh,next_trip.place=true,0,now+R.STEP,true,nil
                next_trip.last_departure=now
                local goods=next_trip.goods and next_trip.goods[next_trip.reverse and 2 or 1]
                next_trip.departures=(next_trip.departures or 0)+1
                next_trip.stem=goods and goods[(next_trip.departures-1)%math.max(1,#goods)+1]
                if next_trip.factions and (next_trip.stem or not next_trip.vehicle_faction) then
                    next_trip.vehicle_faction=next_trip.factions[next_trip.reverse and 2 or 1]
                end
            else break end
        end
    end
    local faction
    local icons = R.shown('icons')
    for slot = 1, R.CART_LIMIT do
        local id, icon_id, trip = R.CART_IDS[slot][1], R.CART_IDS[slot][2], R.traffic[slot]
        if trip and trip.active and now >= trip.due then
            -- the scene has rounded its hex: the next one, on the same beat unless the game stalled
            trip.due = now - trip.due > R.STEP_LATE and now + R.STEP or trip.due + R.STEP
            trip.fresh, trip.place = true, nil
            if trip.steps>0 and (trip.distance==0 or trip.distance==#trip.path-1) then
                trip.active,trip.reverse=false,not trip.reverse
            else
                trip.distance=trip.distance+(trip.reverse and -1 or 1)
                trip.steps=trip.steps+1
            end
        end
        local wanted, icon, pl
        if trip and trip.active then
            pl = trip.place or R.place(trip)
            if pl.x and R.in_view(pl.dx, pl.dy) then wanted = pl.key end
            if wanted and icons and trip.stem then
                if pl.stem ~= trip.stem then pl.stem, pl.icon = trip.stem, wanted .. ':' .. trip.stem end
                icon = pl.icon
            end
        end
        if R.cart_scenes[id] ~= wanted then
            if R.cart_scenes[id] then cm:remove_scripted_composite_scene(id); R.cart_scenes[id] = nil end
            faction = faction or cm:get_faction(cm:get_local_faction_name(true))
            if wanted and cm:add_scripted_composite_scene_to_logical_position(id,pl.scene,
                pl.x,pl.y,pl.fx,pl.fy,false,false,false,faction) then R.cart_scenes[id] = wanted end
        end
        local current=R.icon_scenes[icon_id]
        if current and current.old and now>=current.retire then
            cm:remove_scripted_composite_scene(icon_id..'_'..current.old)
            current.old=nil
        end
        if not icon or (current and current.key~=icon and not trip.fresh) then
            if current then R.hide_icon(icon_id);R.icon_scenes[icon_id]=nil end
        elseif (not current or current.key~=icon) and trip.fresh then
            local bank=current and current.bank=='a' and 'b' or 'a'
            faction = faction or cm:get_faction(cm:get_local_faction_name(true))
            -- Keep the previous sprite at the join for R.ICON_HOLD while the new emitter acquires its first frame.
            if cm:add_scripted_composite_scene_to_logical_position(icon_id..'_'..bank,
                (pl.sea and 'derpy_mr_sea_icon_' or 'derpy_mr_icon_')..trip.stem..'_'..pl.curve,pl.x,pl.y,pl.fx,pl.fy,
                false,false,false,faction) then
                R.icon_scenes[icon_id]={key=icon,bank=bank,old=current and current.bank,retire=now+R.ICON_HOLD}
            else
                R.hide_icon(icon_id);R.icon_scenes[icon_id]=nil
            end
        end
        if trip then trip.fresh = nil end
    end
end

function R.links(faction)
    local links, cargo, seen, owned, plans, used = {}, {}, {}, {}, R.plans, {}
    local regions = faction:region_list()
    for i = 0, regions:num_items() - 1 do owned[regions:item_at(i):name()] = true end
    local function add(owner, from, to, road, goods)
        local key = from < to and (from .. '>' .. to) or (to .. '>' .. from)
        if from == to then return end
        local link=seen[key]
        if not link then
            link={owner=owner,from=from,to=to,key=key,path=road,
                  own=owned[from]==true or owned[to]==true,goods={{},{}}}
            seen[key]=link
            links[#links+1]=link
        end
        for direction,stems in ipairs(goods or {}) do
            local target=link.goods[from==link.from and direction or 3-direction]
            for _,stem in ipairs(stems) do
                local found=false
                for _,existing in ipairs(target) do if existing==stem then found=true;break end end
                if not found then target[#target+1]=stem end
            end
        end
    end
    local F = DERPY_MR_FLOWS
    if not F then return links, cargo end
    local known, visible, agreed = { [faction:name()] = faction }, {}, {}
    local met = faction:factions_met()
    for i = 0, met:num_items() - 1 do
        local f = met:item_at(i)
        if not f:is_null_interface() and not f:is_dead() then known[f:name()] = f end
    end
    for _, regions in ipairs({faction:region_list(), faction:get_foreign_visible_regions_for_player()}) do
        for i = 0, regions:num_items() - 1 do visible[regions:item_at(i):name()] = true end
    end
    for _, s in ipairs(R.shown('shipments') and F.ships() or {}) do
        if s.f == faction:name() or s.sender == faction:name() or s.recipient == faction:name()
            or (known[s.f] and visible[s.from] and visible[s.to]) then
            add(s.f, s.from, s.to, s.road, {{s.stem},{}})
            cargo[#cargo + 1] = s
        end
    end
    -- An agreement's convoys are markers and nothing else: the agreement loop below draws the pair's road in its own
    -- colour with its goods, so a convoy in flight changes neither. Shown with the shipments, to the same eyes. A
    -- marker needs a place: a convoy with no position is listed by F.convoy_cargo and drawn by nobody.
    for _, c in ipairs(R.shown('shipments') and F.convoy_cargo and F.convoy_cargo() or {}) do
        if c.x and c.y and (c.f == faction:name() or c.buyer == faction:name() or (known[c.f] and visible[c.from] and visible[c.to])) then
            cargo[#cargo + 1] = c
        end
    end
    -- THE VIEWER'S SUPPLY CARTS (design 2026-11-08, section 5c): a convoy's marker at the cart, with the shipments, and
    -- only its own (its supply roads are its own too). Placed under derpy_mr_road_N with the rest of the cargo, so the
    -- load's sweep of that range takes them down.
    for _, c in ipairs(R.shown('shipments') and F.supply_cargo and F.supply_cargo() or {}) do
        if c.f == faction:name() then cargo[#cargo + 1] = c end
    end
    for _, o in ipairs(R.shown('contracts') and F.routes(faction) or {}) do
        if o.enabled and F.route_status(faction, o, 'show') then add(faction:name(), o.from, o.to,nil,{{o.stem},{}}) end
    end
    local ordered = {}
    for key in pairs(known) do ordered[#ordered + 1] = key end
    table.sort(ordered)
    for _, key in ipairs(R.shown('agreements') and ordered or {}) do
        local owner = known[key]
        local home, partners = F.capital(owner), owner:factions_trading_with()
        if home and type(partners) ~= 'boolean' then
            for i = 0, partners:num_items() - 1 do
                local partner = partners:item_at(i)
                if known[partner:name()] then
                    local dest = F.capital(partner)
                    if dest and (key == faction:name() or partner:name() == faction:name()
                        or (visible[home:name()] and visible[dest:name()])) then
                        local colour_owner = key == faction:name() and partner:name() or key
                        -- An agreement whose trade is cut off draws no line; one that runs draws its own road.
                        -- New reach answers for R.SHOW_BUDGET seconds a refresh, at least one, so a fresh turn or a
                        -- load never stalls a frame for long; a kept answer costs next to nothing, so most come at once.
                        -- One still to work out keeps its last line up: dropping it re-bundled the whole network at
                        -- every diplomatic event, up to 400 ms a refresh (2026-10-30).
                        local open, _, road = true, nil, nil
                        if F.reach then
                            local pair = home:name() .. '>' .. dest:name()
                            open, _, road = F.reach(home, dest, 'peek')
                            if open == nil and (R.shows == 0 or os.clock() < R.show_until) then
                                R.shows = R.shows + 1
                                open, _, road = F.reach(home, dest, 'show')
                            end
                            -- still unknown, or its search still under way ('show' stops after F.SHOW_HEXES hexes): the
                            -- map comes back for it at the next tick
                            if open == nil then
                                R.dirty = true
                                local was = R.reach_shown[pair]
                                if was then open, road = was[1], was[2] end
                            end
                            if open ~= nil then R.reach_shown[pair] = { open, road } end
                        end
                        -- A BLOCKADED agreement (Part C) draws no line either, until its trade runs again
                        if open and F.blockaded and F.blockaded(key, partner:name()) then open = false end
                        if open and road then agreed[key .. '>' .. partner:name()] = road end
                        if open then
                            local goods={R.goods(key,partner:name()),R.goods(partner:name(),key)}
                            if #goods[1]>0 or #goods[2]>0 then
                                used[key], used[partner:name()] = true, true
                                add(colour_owner, home:name(), dest:name(), road,
                                    {R.carried(goods[1],key,partner:name(),plans),R.carried(goods[2],partner:name(),key,plans)})
                            end
                        end
                    end
                end
            end
        end
    end
    -- A convoy keeps the road it left on until its exporter's turn start moves it onto today's (F.convoys_turn), so
    -- its marker goes there now: on its pair's agreement road, at the share of the way it has come. Kept per convoy
    -- while its road and spot hold: working every one out again was 21 ms a refresh at 100 convoys.
    local spots = {}
    for _, c in ipairs(cargo) do
        local road = c.convoy and F.convoy_on and agreed[c.f .. '>' .. c.buyer]
        if road then
            local s = R.spots[c.id]
            if not (s and s[1] == road and s[2] == c.road and s[3] == c.x and s[4] == c.y) then
                s = { road, c.road, c.x, c.y, F.convoy_on(c, road) }
            end
            spots[c.id] = s
            if s[5] then c.x, c.y = s[5], s[6] end
        end
    end
    R.spots = spots
    for seller in pairs(plans) do if not used[seller] then plans[seller] = nil end end   -- renew only what is drawn
    table.sort(links, function(a,b)
        if a.own ~= b.own then return a.own end
        return a.key < b.key
    end)
    return R.network(links), cargo
end

-- A display-only search within six tiles of the real road prefers the existing network.
-- Native grid edges and hostile-land walls still apply; saved cargo journeys never change.
-- Keep the corridor connected: isolated rings round nearby trunks left shallow forks running beside them.
function R.bundle(path, shared, g, avoid)
    if #path < 2 or not next(shared) then return path end
    local j = R.start(g,path[1],path[#path],avoid)
    j.corridor, j.shared, j.wall = {}, shared, true
    for _,p in ipairs(path) do
        for dx=-6,6 do for dy=-6,6 do
            local id=R.index(g,p[1]+dx,p[2]+dy)
            if id then j.corridor[id]=true end
        end end
    end
    -- ponytail: bounded synchronous display search; queue it if crowded networks stall a refresh.
    local done, bundled=R.advance(j,12000)
    if done and bundled and #bundled <= #path+6 then return bundled end
    return path
end

-- Bundled again when a road or a link changes, and at the player's turn (R.new_turn); not at every war or diplomatic
-- event, which re-bundled the whole network dozens of times a computer round. A war that touches only the corridor
-- round a road, and not the road, shows from the next turn.
function R.network(links)
    if not R.grid then return links end
    local cached, same = R.network_cache, true
    if not cached or #cached.raw~=#links then same=false end
    for i,link in ipairs(links) do
        link.path=link.path or R.path(link.from,link.to)
        local old=cached and cached.raw[i]
        if not old or old.path~=link.path or old.key~=link.key or old.owner~=link.owner or old.own~=link.own then same=false end
    end
    if same then
        for i,link in ipairs(links) do cached.links[i].goods=link.goods end
        return cached.links
    end
    -- ONLY A NEW OR CHANGED LINK IS BUNDLED (Workshop reports, 2026-11-04 to 11-07: 1 to 2 frames a second on a
    -- crowded map). Bundling every link whenever one came or went was 85 bundles and 0.6 to 1.1 s a refresh at 121
    -- links (IE turn 16, map revealed), and the set changes on most refreshes while reach answers come in one or two
    -- at a time. A link keeps its bundled road while its own road, owner and side hold; R.new_turn still bundles all.
    local shared, roads, kept = {}, {}, {}
    for _,link in ipairs(links) do
        local road={}
        for k,v in pairs(link) do road[k]=v end
        if link.path then
            local was = R.bundled[link.key]
            if was and was.raw == link.path and was.owner == link.owner and was.own == link.own then
                road.path = was.path
            else
                local avoid
                if next(shared) then avoid=R.avoider(cm:get_region(link.from),cm:get_region(link.to)) end
                road.path=R.bundle(link.path,shared,R.grid,avoid)
            end
            kept[link.key] = { raw = link.path, owner = link.owner, own = link.own, path = road.path }
            for _,p in ipairs(road.path) do shared[R.index(R.grid,p[1],p[2])]=true end
        end
        roads[#roads+1]=road
    end
    R.bundled = kept
    R.network_cache={raw=links,links=roads}
    return roads
end

-- Merge shared edges, not crossings. Earlier links (owned first, then key) supply the trunk colour.
function R.unshared(path, seen)
    local visible = {}
    if #path == 1 then visible[1] = true end
    for i = 1, #path - 1 do
        local a = path[i][1] .. ':' .. path[i][2]
        local b = path[i+1][1] .. ':' .. path[i+1][2]
        local key = a < b and (a .. '>' .. b) or (b .. '>' .. a)
        if not seen[key] then visible[i], visible[i+1] = true, true end
        seen[key] = true
    end
    return visible
end

-- A road's hexes in display coordinates, worked out once per road: a refresh reads every one of them to
-- find what is near the camera, and a road's table is replaced, never edited, when its route changes.
R.shown_at = setmetatable({}, { __mode = 'k' })
function R.display(path)
    local d = R.shown_at[path]
    if not d then
        d = {}
        for i, p in ipairs(path) do
            local x, y = cm:log_to_dis(p[1], p[2])
            d[i] = { x, y }
        end
        R.shown_at[path] = d
    end
    return d
end

-- THE CAMERA'S VIEW (author, 2026-11-03: carts out of the camera should not be there). R.in_view is true for a
-- display point inside the old circle around the camera's target and inside what the camera sees, widened by
-- R.VIEW_MARGIN display units on every side so a pan between ticks shows nothing missing. R.VIEW_TAN is the tangent
-- of half the camera's vertical view angle, and the bearing is a compass bearing (0 looks up the map). Both were
-- measured against CA's own projection (the CCO's WorldSpaceToScreenSpace) on a grid of 625 points at three zooms
-- and a turned camera (2026-11-03): 0.66 dropped points on screen at the far zoom, 0.76 dropped none, so 0.8 for
-- slack. It keeps about a tenth of the off-screen points the circle kept. A camera with no bearing or height is the
-- circle alone.
R.VIEW_TAN, R.VIEW_MARGIN = 0.8, 6
function R.view(cx, cy, d, b, h)
    local v = { cx, cy, d, b = b, r2 = math.max(35, d * 4) ^ 2 }
    if b and h and h > 0 then
        local sw, sh = core:get_screen_resolution()
        local slant = math.sqrt(d * d + h * h)
        v.ux, v.uy = math.sin(b), math.cos(b)
        v.px, v.py, v.cos, v.sin, v.h = cx - d * v.ux, cy - d * v.uy, d / slant, h / slant, h
        v.tv, v.th = R.VIEW_TAN, R.VIEW_TAN * sw / sh
    end
    return v
end
function R.in_view(x, y)
    local v = R.camera
    if (x - v[1]) * (x - v[1]) + (y - v[2]) * (y - v[2]) > v.r2 then return false end
    if not v.ux then return true end
    local rx, ry = x - v.px, y - v.py
    local f, s = rx * v.ux + ry * v.uy, rx * v.uy - ry * v.ux
    local z, up = f * v.cos + v.h * v.sin, f * v.sin - v.h * v.cos
    return z > 0 and math.abs(up) <= z * v.tv + R.VIEW_MARGIN and math.abs(s) <= z * v.th + R.VIEW_MARGIN
end

-- Supply colours follow the sixteen owner colours and stay the same across palettes.
R.SUPPLY_INK = { supplied = 16, stretched = 17, cut = 18 }
-- ponytail: cap visible supply dashes, lowest CQI first; raise the cap if long roads are visibly truncated.
R.SUPPLY_CAP = 256
-- Scene ids are derpy_mr_supply_<slot>_<i>: zero-based army slot by CQI, then every second road hex.
-- Fixed ids allow load cleanup even for dead armies; sweep covers ten turns at forty hexes plus the army hex.
-- ponytail: armies beyond the slot limit draw nothing; raise it if needed, at ceil(SUPPLY_SWEEP / 2) load removals per slot.
R.SUPPLY_SLOTS = 40
R.SUPPLY_SWEEP = 401
R.supply_kept, R.supply_epoch = {}, nil   -- army number -> { x, y, line }: the last answer and the hex it was for

-- Return { cqi, path, ink, slot } in CQI order, capped at SUPPLY_SLOTS; paths are shared and must not be changed.
-- Rescan only after a hex change or epoch invalidation (player turn start, war, diplomacy or capture).
-- Use the UI enemy cache so drawing on one machine cannot affect multiplayer model results.
function R.supply_links(faction)
    local F, out = DERPY_MR_FLOWS, {}
    if not (F and F.supply_line and R.shown('supply') and faction:is_human()) then return out end
    if R.supply_epoch ~= R.epoch then R.supply_kept, R.supply_epoch = {}, R.epoch end
    local forces, was, now = faction:military_force_list(), R.supply_kept, {}
    for i = 0, forces:num_items() - 1 do
        local mf = forces:item_at(i)
        if mf:has_general() then
            local cqi, ch = mf:command_queue_index(), mf:general_character()
            local x, y = ch:logical_position_x(), ch:logical_position_y()
            local kept = was[cqi]
            if not (kept and kept.x == x and kept.y == y) then kept = { x = x, y = y, line = F.supply_line(faction, mf, true) } end
            now[cqi] = kept
            local ink = R.SUPPLY_INK[kept.line.state]
            if ink and kept.line.path then out[#out + 1] = { cqi = cqi, path = kept.line.path, ink = ink } end
        end
    end
    R.supply_kept = now   -- an army that is gone loses its answer
    table.sort(out, function(a, b) return a.cqi < b.cqi end)
    for k = #out, R.SUPPLY_SLOTS + 1, -1 do out[k] = nil end
    for k, line in ipairs(out) do line.slot = k - 1 end
    return out
end

-- Scenes survive saves; sweep every possible id, including roads belonging to dead armies.
function R.hide_supply()
    for slot = 0, R.SUPPLY_SLOTS - 1 do
        for k = 1, R.SUPPLY_SWEEP, 2 do cm:remove_scripted_composite_scene('derpy_mr_supply_' .. slot .. '_' .. k) end
    end
end

-- moved: the camera alone moved, so the links and goods of the last refresh still hold and only what is
-- near the camera is placed again (author, 2026-10-29: a full refresh per tick skipped frames while dragging)
function R.refresh(moved)
    if not R.grid then return end
    local faction = cm:get_faction(cm:get_local_faction_name(true))
    if not faction or faction:is_null_interface() then return end
    local wanted, count = {}, 0
    R.camera = R.view(cm:get_camera_position())
    local cx, cy = R.camera[1], R.camera[2]
    R.shows, R.show_until = 0, os.clock() + R.SHOW_BUDGET
    local size, set = R.style()
    local links, cargo, unshared, supply
    if moved and R.drawn then
        links, cargo, unshared, supply = R.drawn[1], R.drawn[2], R.drawn[3], R.drawn[4]
    else
        links, cargo = R.links(faction)
        -- the same bundled network (R.network gives back its cached table) has the same shared stretches
        unshared = R.drawn and R.drawn[1] == links and R.drawn[3] or {}
        -- the armies' roads fail on their own: a throw there must not stop the trade roads from being drawn
        local ok, found = pcall(R.supply_links, faction)
        supply = ok and found or {}
        if not ok and not R.supply_failed then R.supply_failed = true; pcall(out, '[derpy_mr_routes] ' .. tostring(found)) end
        R.drawn = { links, cargo, unshared, supply }
    end
    local old_traffic, traffic, shared, routes = {}, {}, {}, {}
    for _, t in ipairs(R.traffic) do old_traffic[t.key] = t end
    for _, s in ipairs(cargo) do
        -- a convoy's marker takes a decal only near the camera, as the road dashes do: there can be hundreds
        local near = true
        if s.convoy or s.supply then
            near = R.in_view(cm:log_to_dis(s.x, s.y))
        end
        if near and count < 512 then
            count = count + 1
            wanted['derpy_mr_road_' .. count] = { x = s.x, y = s.y, scene = 'derpy_mr_route_cargo_' .. size }
        end
    end
    for _, link in ipairs(links) do
        local path = link.path or R.path(link.from, link.to)
        if path then
            local visible = unshared[link]
            if not visible then visible = R.unshared(path, shared); unshared[link] = visible end
            local shown = R.display(path)
            local closest, best
            if R.shown('carts') and #path > 1
                and (not link.goods or #link.goods[1]>0 or #link.goods[2]>0) then
                for i,q in ipairs(shown) do
                    local d = (q[1]-cx)*(q[1]-cx)+(q[2]-cy)*(q[2]-cy)
                    if (not best or d < best) and R.in_view(q[1], q[2]) then closest,best = i,d end
                end
                if closest then
                    local goods=link.goods
                    local origins
                    if link.from and link.to then
                        origins={cm:get_region(link.from):owning_faction():name(),cm:get_region(link.to):owning_faction():name()}
                    end
                    if goods then
                        local st=cm:get_region(link.from):settlement()
                        local first,last=path[1],path[#path]
                        local x,y=st:logical_position_x(),st:logical_position_y()
                        if (first[1]-x)^2+(first[2]-y)^2>(last[1]-x)^2+(last[2]-y)^2 then
                            goods={goods[2],goods[1]}
                            if origins then origins={origins[2],origins[1]} end
                        end
                    end
                    routes[#routes+1]={key=link.key,path=path,goods=goods,origins=origins,
                        directions=goods and #goods[1]>0 and #goods[2]>0 and 2 or 1}
                end
            end
            -- ponytail: render at most 512 nearby decals; prioritise selected routes if crowded maps reach the cap.
            for i = 1, #path, 2 do
                if count >= 512 then break end
                local p = path[i]
                local dx, dy = shown[i][1], shown[i][2]
                if visible[i] and R.in_view(dx, dy) then
                    local id = 'derpy_mr_road_' .. (count + 1)
                    wanted[id] = { x = p[1], y = p[2], scene = R.dash(path, i, R.ink(link.owner, set), size) }
                    count = count + 1
                end
            end
        end
    end
    -- Every route in view gets its cart before any route gets a second (author, 2026-10-23: many partners
    -- showed four two-way roads and nothing on the rest).
    for direction=1,2 do
        for _,route in ipairs(routes) do
            if #traffic>=R.CART_LIMIT then break end
            if direction<=route.directions then
                local path,goods=route.path,route.goods
                local key=route.key..(direction==2 and ':return' or '')
                local prior=old_traffic[key]
                local trip=prior and prior.path==path and prior or {key=key,path=path,
                    distance=direction==2 and #path-1 or 0,reverse=direction==2}
                trip.goods=goods
                trip.factions=route.origins or trip.factions
                if trip.stem and goods then
                    local allowed=false
                    for _,stem in ipairs(goods[trip.reverse and 2 or 1]) do if stem==trip.stem then allowed=true end end
                    if not allowed then trip.stem=nil end
                end
                traffic[#traffic+1]=trip
            end
        end
    end
    R.traffic = traffic
    -- Keep a scene's identity while panning so unchanged dashes do not restart their emitters.
    local by_point, aligned, used, pending = {}, {}, {}, {}
    local function point_key(p) return p.x .. ':' .. p.y .. ':' .. p.scene end
    for id, p in pairs(R.scenes) do by_point[point_key(p)] = id end
    for _, p in pairs(wanted) do
        local id = by_point[point_key(p)]
        if id and not used[id] then aligned[id], used[id] = p, true
        else pending[#pending + 1] = p end
    end
    local slot = 1
    for _, p in ipairs(pending) do
        while used['derpy_mr_road_' .. slot] do slot = slot + 1 end
        local id = 'derpy_mr_road_' .. slot
        aligned[id], used[id] = p, true
    end
    wanted = aligned
    -- THE ARMIES' SUPPLY ROADS, after the trade links, a dash on every second hex in view. Their ids are fixed by slot and
    -- hex, so no scene is matched to another's point above: a hex a road leaves is taken down under its own id.
    local supply_placed = 0
    for _, line in ipairs(supply) do
        local path, shown = line.path, R.display(line.path)
        for i = 1, #path, 2 do
            if supply_placed >= R.SUPPLY_CAP then break end
            if R.in_view(shown[i][1], shown[i][2]) then
                supply_placed = supply_placed + 1
                wanted['derpy_mr_supply_' .. line.slot .. '_' .. i] = { x = path[i][1], y = path[i][2],
                                                                      scene = R.dash(path, i, line.ink, size) }
            end
        end
    end
    for id, old in pairs(R.scenes) do
        local new = wanted[id]
        if not new or new.x ~= old.x or new.y ~= old.y or new.scene ~= old.scene then
            cm:remove_scripted_composite_scene(id)
            R.scenes[id] = nil
        end
    end
    for id, p in pairs(wanted) do
        if not R.scenes[id] then
            local ok = cm:add_scripted_composite_scene_to_logical_position(id, p.scene,
                p.x, p.y, p.x, p.y + 1, false, false, false, faction)
            if ok then R.scenes[id] = p end
        end
    end
end

-- The timed refresh every R.STALE_EVERY ticks (10 s) and one seller's cart goods every R.PLAN_EVERY (2 s): at 2.5 s
-- and 0.5 s the map's own redraws were a frame hitch every few seconds (2026-11-03, 22 ms and 8 ms each).
R.STALE_EVERY, R.PLAN_EVERY = 100, 20
function R.tick()
    local ok, err = pcall(function()
        R.pump()
        -- THE COMPUTERS' TURNS (2026-11-03: 277 redraws, 3.5 s, in one round of them): the map is worked out and
        -- drawn again only in the player's turn; the carts go on moving
        if not cm:is_local_players_turn() then return end
        R.ticks = (R.ticks or 0) + 1
        local x, y, zoom, b = cm:get_camera_position()
        local camera = R.camera
        local moved = camera and ((x-camera[1])*(x-camera[1]) + (y-camera[2])*(y-camera[2]) > 16
                                or math.abs(zoom-camera[3]) > 2 or math.abs((b or 0)-(camera.b or 0)) > 0.05)
        -- the timed refresh catches what nothing reports (a sale, a recruit); it waits for the camera to stop
        R.stale = R.stale or R.ticks % R.STALE_EVERY == 1
        if R.dirty or (R.stale and not moved) or not R.drawn then
            R.dirty, R.stale = false, false
            R.refresh()
        elseif moved then
            R.refresh(true)
        elseif R.ticks % R.PLAN_EVERY == 0 then
            R.renew_plan()   -- never on a tick that already refreshed
        end
    end)
    if not ok and not R.failed then R.failed = true; pcall(out, '[derpy_mr_routes] ' .. tostring(err)) end
end

function R.cart_tick()
    local ok, err = pcall(R.animate)
    if not ok and not R.failed then R.failed = true; pcall(out, '[derpy_mr_routes] ' .. tostring(err)) end
end

-- The player's turn: every shown road is checked again and the network bundled again.
function R.new_turn()
    R.epoch, R.dirty, R.network_cache, R.bundled = R.epoch + 1, true, nil, {}
    R.plan_fresh = {}   -- the computers' stores have moved: each preview is worked out again once
end

function R.init()
    if R.started then return end
    R.started = true
    -- Scenes survive saves; a fixed namespace removes old links before rebuilding current ones.
    for i = 1, 512 do cm:remove_scripted_composite_scene('derpy_mr_road_' .. i) end
    for i = 1, R.CART_LIMIT do
        cm:remove_scripted_composite_scene('derpy_mr_traffic_' .. i)
        cm:remove_scripted_composite_scene('derpy_mr_traffic_' .. i..'_icon')
        R.hide_icon('derpy_mr_traffic_'..i..'_icon')
    end
    R.hide_supply()
    if cm:is_multiplayer() then return end
    R.grid = R.grids[cm:model():campaign_name_key()]
    if not R.grid then return end
    R.refresh()
    cm:repeat_real_callback(R.tick, 100, 'derpy_mr_terrain_routes')
    cm:repeat_real_callback(R.cart_tick, R.CART_MS, 'derpy_mr_terrain_carts')
    core:add_listener('derpy_mr_terrain_routes_turn', 'FactionTurnStart',
        function(context) return context:faction():name() == cm:get_local_faction_name(true) end,
        function() R.new_turn() end, true)
    -- An army that has moved has a new supply road: the map is drawn again at the next tick, not at the timed refresh.
    -- A flag and nothing else (CA's own conditions read context:character():faction() the same way).
    core:add_listener('derpy_mr_terrain_routes_moved', 'CharacterFinishedMovingEvent',
        function(context) return context:character():faction():name() == cm:get_local_faction_name(true) end,
        function() R.dirty = true end, true)
end

core:add_listener('derpy_mr_terrain_routes_init', 'ScriptEventFirstTickAfterWorldCreated', true,
    function() local ok, err = pcall(R.init); if not ok then pcall(out, '[derpy_mr_routes] ' .. tostring(err)) end end, true)
cm:add_first_tick_callback(function() local ok, err = pcall(R.init); if not ok then pcall(out, '[derpy_mr_routes] ' .. tostring(err)) end end)
