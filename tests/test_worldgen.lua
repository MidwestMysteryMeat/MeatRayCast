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
end
