--[[
    Variable wall height and stacked slabs: sim half and screen projection.

    Short walls sit on the floor. Stacked / floating walls are slabs with a
    base z. The ray continues past any tile that does not cover [0, 1], and
    projection places each slab at its vertical range rather than always on
    the floor.
]]

return function(t)
    local World = require('meatray.sim.world')
    local Map = require('meatray.sim.map')
    local Raycaster = require('meatray.render.raycaster')
    local Worldgen = require('meatray.sim.worldgen')
    local floor = math.floor

    ---------------------------------------------------------------------
    t.describe('wall height defaults and setters')

    local w = Worldgen.box(12, 12)
    -- Box borders are solid; interior is open floor.
    t.eq(w:isSolid(1, 6), true, 'fixture: border tile is solid')
    t.eq(w:wallHeightAt(1, 6), 1, 'an unset wall is full height')
    t.eq(w:wallHeightAt(5, 5), 1, 'open floor also answers 1 (nothing special)')

    t.eq(w:setWallHeight(1, 6, 0.5), true, 'a solid wall accepts a short height')
    t.eq(w:wallHeightAt(1, 6), 0.5, 'and returns it')

    t.eq(w:setWallHeight(5, 5, 0.5), false, 'open floor refuses a height')
    t.eq(w:setWallHeight(1, 6, 0), false, 'zero height is refused (nothing to draw)')
    t.eq(w:setWallHeight(1, 6, -1), false, 'negative is refused')
    t.eq(w:wallHeightAt(1, 6), 0.5, 'a refused set leaves the previous height')

    t.eq(w:setWallHeight(1, 6, 1), true, 'setting 1 clears back to default')
    t.eq(w:wallHeightAt(1, 6), 1, 'so the side table no longer carries an entry')
    t.eq(w.wallHeights['1,6'], nil, 'literally absent, not stored as 1.0')

    t.eq(w:setWallHeight(1, 6, 0.25), true)
    t.eq(w:setWallHeight(1, 6, nil), true, 'nil also clears')
    t.eq(w:wallHeightAt(1, 6), 1)

    ---------------------------------------------------------------------
    t.describe('eye occlusion and destruction')

    t.eq(World.occludesEye(1), true, 'a full wall occludes the eye')
    t.eq(World.occludesEye(0.5), true, 'exactly eye height still occludes')
    t.eq(World.occludesEye(0.49), false, 'below the eye does not')
    t.eq(World.occludesEye(nil), true, 'default is full')

    t.eq(World.slabOccludesEye(0, 0.4), false, 'a low slab misses the eye')
    t.eq(World.slabOccludesEye(0, 0.6), true, 'a taller floor slab covers it')
    t.eq(World.slabOccludesEye(0.6, 0.4), false, 'a floating slab above the eye does not')
    t.eq(World.slabOccludesEye(0.3, 0.4), true, 'a mid slab that spans the eye does')

    t.eq(World.slabsBlockRay{ { base = 0, height = 1 } }, true, 'full slab blocks the ray')
    t.eq(World.slabsBlockRay{ { base = 0, height = 0.5 } }, false, 'short slab does not')
    t.eq(World.slabsBlockRay{
            { base = 0, height = 0.4 }, { base = 0.6, height = 0.4 },
         }, false, 'stacked pair with a mid gap does not block')
    t.eq(World.slabsBlockRay{
            { base = 0, height = 0.5 }, { base = 0.5, height = 0.5 },
         }, true, 'two halves that meet cover [0,1]')

    w:setWallHeight(1, 6, 0.4)
    w:setDestructible(1, 6, 1)
    t.eq(w:destroyTile(1, 6), true, 'the wall comes down')
    t.eq(w:wallHeightAt(1, 6), 1, 'and its height entry is gone with it')
    t.eq(w.wallHeights['1,6'], nil, 'not left as a ghost on rubble')

    ---------------------------------------------------------------------
    t.describe('stacked and floating slabs')

    local s = Worldgen.box(12, 12)
    t.eq(s:addWallSlab(2, 1, 0, 0.35), true, 'low slab')
    t.eq(s:addWallSlab(2, 1, 0.65, 0.35), true, 'high slab on the same tile')
    local slabs = s:wallSlabsAt(2, 1)
    t.eq(#slabs, 2, 'both slabs are kept')
    t.eq(slabs[1].base, 0, 'sorted by base, low first')
    t.eq(slabs[2].base, 0.65, 'high second')
    t.eq(World.slabsBlockRay(slabs), false, 'gap at mid-height does not block the ray')
    t.eq(s.wallHeights['2,1'], nil, 'multi-slab form does not use wallHeights')

    t.eq(s:setWallSlabs(3, 1, { { base = 0.6, height = 0.4 } }), true)
    local raised = s:wallSlabsAt(3, 1)
    t.eq(#raised, 1, 'one raised slab')
    t.eq(raised[1].base, 0.6, 'base is above the eye')
    t.eq(World.slabOccludesEye(raised[1].base, raised[1].height), false,
         'eye looks under a slab that starts above mid-height')

    t.eq(s:setWallSlabs(3, 1, nil), true, 'clear restores default')
    t.eq(s:wallHeightAt(3, 1), 1, 'default full height again')

    ---------------------------------------------------------------------
    t.describe('map header round-trip')

    local text = [[
name  short walls
theme dungeon
spawn 2.5 2.5 0
height 1 2 0.5
height 1 3 0.25
slab 1 4 0.6 0.4
slab 1 4 0 0.3
---
######
#....#
#....#
#....#
#....#
######
]]
    local map, err = Map.parse(text)
    t.ok(map ~= nil, 'map with height and slab lines parses', err and err[1])
    t.eq(#(map.wallHeights or {}), 2, 'both height lines are kept')
    t.eq(#(map.wallSlabs or {}), 2, 'both slab lines are kept')

    local world = Map.toWorld(map)
    t.eq(world:isSolid(1, 2), true, 'height lines target solid border tiles')
    t.eq(world:wallHeightAt(1, 2), 0.5, 'toWorld applies the first height')
    t.eq(world:wallHeightAt(1, 3), 0.25, 'and the second')
    t.eq(world:wallHeightAt(1, 1), 1, 'untouched walls stay full')
    local stacked = world:wallSlabsAt(1, 4)
    t.eq(#stacked, 2, 'slab lines land as two slabs on the tile')
    t.ok(stacked[1].base < stacked[2].base, 'sorted by base')

    local back = Map.fromWorld(world)
    t.eq(#back.wallHeights, 2, 'fromWorld captures heights')
    t.eq(#back.wallSlabs, 2, 'and slabs')
    local ser = Map.serialize(back)
    t.ok(ser:find('height 1 2 0.5', 1, true), 'serialize writes the height line')
    t.ok(ser:find('height 1 3 0.25', 1, true), 'and the other')
    t.ok(ser:find('slab 1 4', 1, true), 'and slab lines')

    local again = Map.parse(ser)
    t.ok(again ~= nil, 'serialized map re-parses')
    local world2 = Map.toWorld(again)
    t.eq(world2:wallHeightAt(1, 2), 0.5, 'round-trip preserves height')
    t.eq(world2:wallHeightAt(1, 3), 0.25)
    t.eq(#world2:wallSlabsAt(1, 4), 2, 'and stacked slabs')

    ---------------------------------------------------------------------
    t.describe('screen projection matches the full-wall special case')

    local H, horizon = 600, 300
    local dist = 2.0

    local ds, de, full = Raycaster.projectWall(dist, 1, H, horizon)
    t.near(full, H / dist, 1e-9, 'full projected height is screenH / dist')
    t.eq(ds, floor(-full / 2 + horizon), 'full wall top matches the classic formula')
    t.eq(de, floor(full / 2 + horizon), 'full wall bottom matches the classic formula')

    local halfS, halfE = Raycaster.projectWall(dist, 0.5, H, horizon)
    t.eq(halfE, de, 'a half wall shares the floor line with a full wall')
    t.ok(halfS > ds, 'and its top is lower on screen (larger y)')
    t.near(halfE - halfS, full * 0.5, 1.5,
           'its pixel height is half the full projected height')

    local lowS, lowE = Raycaster.projectWall(dist, 0.25, H, horizon)
    t.eq(lowE, de, 'a quarter wall still sits on the floor')
    t.ok(lowS > halfS, 'and is shorter still')

    -- Camera at mid-height: a wall of height 0.5 reaches exactly the horizon.
    local eyeS, eyeE = Raycaster.projectWall(dist, World.EYE_HEIGHT, H, horizon)
    t.near(eyeS, horizon, 1.5, 'eye-height wall top lands on the horizon')
    t.eq(eyeE, de, 'with the floor line unchanged')

    -- Raised slab: base 0.5, height 0.5 — sits from mid-wall to ceiling.
    local upS, upE = Raycaster.projectWall(dist, 0.5, H, horizon, 0.5)
    t.near(upS, ds, 1.5, 'raised slab top matches a full wall top')
    t.near(upE, horizon, 1.5, 'and its base lands on the horizon')
    t.ok(upE < halfE, 'a raised slab sits higher than a floor short wall')
end
