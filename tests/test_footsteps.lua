--[[
    C30: footsteps + surface materials. The model emits a step every stride of
    travel (one per tick, remainder carried), reads the material under the feet
    through an injected resolver, and falls back to a default on untagged floor.
    The world tags surfaces per tile and a `.map` `surface` directive round-trips.
]]

return function(t)
    local Footsteps = require('meatray.game.footsteps')
    local Game = require('meatray.game')
    local Map = require('meatray.sim.map')
    local Worldgen = require('meatray.sim.worldgen')

    t.eq(Game.footsteps, Footsteps, 'Game.footsteps is the module')

    ---------------------------------------------------------------------
    t.describe('a step lands every stride of travel')

    local steps = Footsteps.new{ stride = 2 }
    local e = { id = 1, x = 1.5, y = 1.5, storey = 1 }

    t.eq(steps:advance(e, 1.0), nil, 'no step after half a stride')
    local s = steps:advance(e, 1.2)   -- total 2.2 >= 2
    t.ok(s, 'a step lands once the stride completes')
    t.eq(s.material, 'stone', 'default material with no resolver')
    t.eq(s.x, 1.5, 'the step is placed at the walker')

    -- Remainder (0.2) carries; another 1.9 reaches 2.1 -> one more step.
    t.eq(steps:advance(e, 1.0), nil, 'still short of the next stride')
    t.ok(steps:advance(e, 1.0), 'the carried remainder makes the next step sooner')

    ---------------------------------------------------------------------
    t.describe('one call makes at most one step, even for a huge move')

    local burst = Footsteps.new{ stride = 1 }
    local b = { id = 2, x = 0, y = 0 }
    local one = burst:advance(b, 100)   -- 100 strides of distance in one tick
    t.ok(one, 'a giant move still makes a step')
    -- The next tiny move should NOT immediately fire (remainder was clamped to
    -- under one stride, not left at 99).
    t.eq(burst:advance(b, 0.1), nil, 'and does not machine-gun steps afterwards')

    ---------------------------------------------------------------------
    t.describe('the material resolver decides the sound')

    local mat = Footsteps.new{ stride = 1 }
    local walker = { id = 3, x = 4.5, y = 4.5, storey = 1 }
    local resolver = function(tx, ty) return (tx == 5 and ty == 5) and 'water' or nil end
    local ws = mat:advance(walker, 1.0, resolver)
    t.eq(ws.material, 'water', 'the resolver names the material under the feet')
    -- Move off the water tile; the default returns.
    walker.x = 8.5
    local ds = mat:advance(walker, 1.0, resolver)
    t.eq(ds.material, 'stone', 'untagged floor falls back to the default')

    ---------------------------------------------------------------------
    t.describe('forget clears an entity so it does not leak')

    mat:advance(walker, 0.5)          -- accumulate a partial
    mat:forget(walker)
    t.eq(mat.walked[3], nil, 'the accumulator is gone')

    ---------------------------------------------------------------------
    t.describe('the world tags surfaces per tile')

    local w = Worldgen.box(10, 10)
    t.eq(w:surfaceAt(5, 5), nil, 'untagged by default')
    w:setSurface(5, 5, 'water')
    t.eq(w:surfaceAt(5, 5), 'water', 'tagged water')
    w:setSurface(5, 5, nil)
    t.eq(w:surfaceAt(5, 5), nil, 'cleared')

    ---------------------------------------------------------------------
    t.describe('the surface directive parses and round-trips')

    local text = table.concat({
        'name Surf', 'theme dungeon', 'spawn 2.5 2.5 0',
        'surface water 3 3 4 3',       -- two tiles, one line
        'surface metal 6 6',
        '---',
        '########',
        '#......#',
        '#......#',
        '#......#',
        '#......#',
        '#......#',
        '########',
    }, '\n')
    local map = assert(Map.parse(text))
    t.eq(#map.surfaces, 3, 'three tagged tiles (two water + one metal)')

    local out = Map.serialize(map)
    local re = assert(Map.parse(out))
    t.eq(out, Map.serialize(re), 'serialisation is byte-stable')

    local world = Map.toWorld(map)
    t.eq(world:surfaceAt(3, 3), 'water', 'toWorld tags the tile')
    t.eq(world:surfaceAt(6, 6), 'metal', 'and the metal one')

    local back = Map.fromWorld(world)
    t.eq(#back.surfaces, 3, 'fromWorld recovers all three')

    -- End to end: a footstep on the tagged tile names its material.
    local fs = Footsteps.new{ stride = 1 }
    local p = { id = 9, x = 2.5, y = 2.5, storey = 1 }   -- tile (3,3) = water
    local step = fs:advance(p, 1.0, function(tx, ty, st) return world:surfaceAt(tx, ty, st) end)
    t.eq(step.material, 'water', 'a step on the water tile sounds like water')
end
