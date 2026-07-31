--[[
    BSP generation, and above all its determinism.

    The determinism tests are not pedantry. In a host-authoritative game the host
    and every client generate the world from the same seed; if the generator is
    not bit-identical across runs and across Lua implementations, peers walk
    around in subtly different buildings and nothing can recover from it.
]]

return function(t)
    local Worldgen = require('meatray.sim.worldgen')
    local World = require('meatray.sim.world')

    t.describe('the RNG is explicit and reproducible')
    local a = Worldgen.rng(12345)
    local b = Worldgen.rng(12345)
    for i = 1, 50 do
        t.eq(a:next(), b:next(), 'same seed yields the same stream at step ' .. i)
    end

    local c = Worldgen.rng(999)
    local d = Worldgen.rng(1000)
    t.ok(c:next() ~= d:next(), 'different seeds diverge')

    -- Known-value check: this pins the LCG so a future "optimisation" that
    -- changes the constants or the modulus fails loudly instead of silently
    -- desyncing every networked game built on the engine.
    t.describe('the RNG stream is pinned')
    local pinned = Worldgen.rng(1)
    t.eq(pinned:next(), (1664525 * 1 + 1013904223) % 4294967296, 'first value is the LCG step')

    local r = Worldgen.rng(7)
    for _ = 1, 200 do
        local f = r:float()
        t.ok(f >= 0 and f < 1, 'float stays in [0,1)')
    end

    local ri = Worldgen.rng(3)
    for _ = 1, 200 do
        local v = ri:int(5, 9)
        t.ok(v >= 5 and v <= 9, 'int stays within bounds')
    end
    t.eq(Worldgen.rng(1):int(4, 4), 4, 'a degenerate range returns the bound')

    t.describe('generation produces a usable world')
    local world, rooms = Worldgen.generate{ width = 40, height = 40, seed = 2024 }
    t.eq(world.width, 40, 'width honoured')
    t.eq(world.height, 40, 'height honoured')
    t.ok(#rooms > 1, 'more than one room was placed')
    t.ok(world.spawn ~= nil, 'a spawn point was chosen')
    t.ok(not world:isSolid(math.floor(world.spawn.x), math.floor(world.spawn.y)),
         'the spawn point is not inside a wall')

    -- The border must stay solid or the player walks off the map.
    local borderOpen = false
    for x = 1, world.width do
        if not world:isSolid(x, 1) or not world:isSolid(x, world.height) then borderOpen = true end
    end
    for y = 1, world.height do
        if not world:isSolid(1, y) or not world:isSolid(world.width, y) then borderOpen = true end
    end
    t.ok(not borderOpen, 'the map border is sealed')

    -- There must be somewhere to stand.
    local open = 0
    for y = 1, world.height do
        for x = 1, world.width do
            if not world:isSolid(x, y) then open = open + 1 end
        end
    end
    t.ok(open > 100, 'a decent amount of the map is walkable')

    t.describe('elevation decoration is deterministic and optional')
    local we = Worldgen.generate{ width = 40, height = 40, seed = 7777 }
    local we2 = Worldgen.generate{ width = 40, height = 40, seed = 7777 }
    local elevSame = true
    for key, z in pairs(we.floorHeights or {}) do
        if we2.floorHeights[key] ~= z then elevSame = false end
    end
    for key, z in pairs(we.ceilingHeights or {}) do
        if we2.ceilingHeights[key] ~= z then elevSame = false end
    end
    t.ok(elevSame, 'same seed same elevation side tables')
    local flat = Worldgen.generate{ width = 40, height = 40, seed = 7777, elevation = false }
    local anyCeil = false
    for _ in pairs(flat.ceilingHeights or {}) do anyCeil = true; break end
    t.eq(anyCeil, false, 'elevation = false leaves ceilings default')

    t.describe('the same seed regenerates the same map')
    local w1 = Worldgen.generate{ width = 32, height = 32, seed = 4242 }
    local w2 = Worldgen.generate{ width = 32, height = 32, seed = 4242 }
    local identical = true
    for y = 1, 32 do
        for x = 1, 32 do
            if w1:tileAt(x, y) ~= w2:tileAt(x, y) then identical = false end
        end
    end
    t.ok(identical, 'every tile matches')
    t.eq(w1.spawn.x, w2.spawn.x, 'and so does the spawn')

    local w3 = Worldgen.generate{ width = 32, height = 32, seed = 4243 }
    local differs = false
    for y = 1, 32 do
        for x = 1, 32 do
            if w1:tileAt(x, y) ~= w3:tileAt(x, y) then differs = true end
        end
    end
    t.ok(differs, 'a different seed gives a different map')

    t.describe('doors are placed in doorways, not in the open')
    local dworld = Worldgen.generate{ width = 48, height = 48, seed = 77, doorChance = 1.0 }
    local doorCount, badDoor = 0, nil
    for key, _ in pairs(dworld.doors) do
        doorCount = doorCount + 1
        local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
        local x, y = tonumber(sx), tonumber(sy)
        -- A doorway has walls on exactly one axis. Both axes solid would be a
        -- sealed hole; neither would be a door standing in the middle of a room.
        local solidH = dworld:isSolid(x - 1, y) and dworld:isSolid(x + 1, y)
        local solidV = dworld:isSolid(x, y - 1) and dworld:isSolid(x, y + 1)
        if solidH == solidV then badDoor = key end
    end
    t.ok(doorCount > 0, 'doors were placed at all')
    t.eq(badDoor, nil, 'every door sits in a real doorway')

    t.describe('door state round-trips')
    local dw = Worldgen.generate{ width = 32, height = 32, seed = 5, doorChance = 1.0 }
    local firstKey
    for key in pairs(dw.doors) do firstKey = firstKey or key end
    if firstKey then
        local x, y = firstKey:match('^(%-?%d+),(%-?%d+)$')
        dw:setDoorOpen(tonumber(x), tonumber(y), true)
        local snap = dw:snapshot()
        local other = Worldgen.generate{ width = 32, height = 32, seed = 5, doorChance = 1.0 }
        t.ok(not other:doorAt(tonumber(x), tonumber(y)).open, 'the copy starts shut')
        other:applySnapshot(snap)
        t.ok(other:doorAt(tonumber(x), tonumber(y)).open, 'and the snapshot opens it')
    else
        t.ok(false, 'expected at least one door with doorChance 1.0')
    end

    t.describe('the plain box helper')
    local box = Worldgen.box(10, 8)
    t.eq(box.width, 10, 'box width')
    t.eq(box.height, 8, 'box height')
    t.ok(box:isSolid(1, 1), 'box corner is solid')
    t.ok(not box:isSolid(5, 4), 'box interior is open')
    t.eq(box:tileAt(3, 3), World.EMPTY, 'interior reads as empty')

    ---------------------------------------------------------------------
    t.describe('Delaunay triangulation of a square')

    local sq = {
        { x = 0, y = 0 },
        { x = 1, y = 0 },
        { x = 1, y = 1 },
        { x = 0, y = 1 },
    }
    local tris, edges = Worldgen.delaunay(sq)
    t.eq(#tris, 2, 'square splits into two triangles')
    t.eq(#edges, 5, 'square has five unique edges (4 sides + 1 diagonal)')
    -- Every original point must appear in at least one triangle.
    local seen = {}
    for i = 1, #tris do
        for k = 1, 3 do seen[tris[i][k]] = true end
    end
    t.ok(seen[1] and seen[2] and seen[3] and seen[4], 'all four points used')

    -- Deterministic: same points → same edge list.
    local _, edges2 = Worldgen.delaunay(sq)
    t.eq(#edges2, #edges, 'same edge count on re-run')
    t.eq(edges2[1].i, edges[1].i, 'sorted edge list is stable')
    t.eq(edges2[1].j, edges[1].j, 'sorted edge endpoints stable')

    ---------------------------------------------------------------------
    t.describe('Kruskal MST connects n vertices with n-1 edges')

    local complete = {}
    local nV = 5
    for i = 1, nV do
        for j = i + 1, nV do
            complete[#complete + 1] = { i = i, j = j, w = (j - i) * 1.0 }
        end
    end
    local tree = Worldgen.mst(nV, complete)
    t.eq(#tree, nV - 1, 'tree has n-1 edges')
    -- Union-find reachability from vertex 1.
    local parent = {}
    for i = 1, nV do parent[i] = i end
    local function find(x)
        while parent[x] ~= x do x = parent[x] end
        return x
    end
    for i = 1, #tree do
        local a, b = find(tree[i].i), find(tree[i].j)
        parent[b] = a
    end
    local root = find(1)
    local allReach = true
    for i = 2, nV do
        if find(i) ~= root then allReach = false end
    end
    t.ok(allReach, 'MST connects every vertex')

    ---------------------------------------------------------------------
    t.describe('layout=mst produces a connected dungeon')

    local mw, mrooms = Worldgen.generate{
        width = 48, height = 48, seed = 9001, layout = 'mst', elevation = false,
    }
    t.ok(#mrooms >= 3, 'mst places several rooms', tostring(#mrooms))
    t.ok(mw.spawn ~= nil, 'mst has a spawn')
    t.ok(not mw:isSolid(math.floor(mw.spawn.x), math.floor(mw.spawn.y)),
         'mst spawn is walkable')

    -- Flood-fill from spawn: every room centre must be reachable with doors open.
    for key, door in pairs(mw.doors) do door.open = true end
    local sx = math.floor(mw.spawn.x)
    local sy = math.floor(mw.spawn.y)
    local q, head = { { sx, sy } }, 1
    local vis = { [sx .. ',' .. sy] = true }
    while head <= #q do
        local c = q[head]; head = head + 1
        local cx, cy = c[1], c[2]
        local nbs = { { cx + 1, cy }, { cx - 1, cy }, { cx, cy + 1 }, { cx, cy - 1 } }
        for ni = 1, 4 do
            local nx, ny = nbs[ni][1], nbs[ni][2]
            local k = nx .. ',' .. ny
            if mw:inBounds(nx, ny) and not vis[k] and not mw:isSolid(nx, ny) then
                vis[k] = true
                q[#q + 1] = { nx, ny }
            end
        end
    end
    local unreachable = 0
    for i = 1, #mrooms do
        local r = mrooms[i]
        if not vis[r.cx .. ',' .. r.cy] then unreachable = unreachable + 1 end
    end
    t.eq(unreachable, 0, 'every room centre is reachable via corridors')

    local mw2 = Worldgen.generate{
        width = 48, height = 48, seed = 9001, layout = 'mst', elevation = false,
    }
    local mstSame = true
    for y = 1, 48 do
        for x = 1, 48 do
            if mw:tileAt(x, y) ~= mw2:tileAt(x, y) then mstSame = false end
        end
    end
    t.ok(mstSame, 'mst layout is seed-deterministic')

    -- Default layout must still be BSP (existing seeds unchanged).
    local bspA = Worldgen.generate{ width = 32, height = 32, seed = 4242 }
    local bspB = Worldgen.generate{ width = 32, height = 32, seed = 4242, layout = 'bsp' }
    local bspMatch = true
    for y = 1, 32 do
        for x = 1, 32 do
            if bspA:tileAt(x, y) ~= bspB:tileAt(x, y) then bspMatch = false end
        end
    end
    t.ok(bspMatch, 'default layout matches explicit bsp')
end
