--[[
    Variable wall height: the sim half and the screen projection.

    Stacked floors are not here. This is the single-floor case: a solid tile
    may be shorter than a full wall, the ray continues past it, and the strip
    it draws sits on the floor rather than being centred on the horizon.
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

    w:setWallHeight(1, 6, 0.4)
    w:setDestructible(1, 6, 1)
    t.eq(w:destroyTile(1, 6), true, 'the wall comes down')
    t.eq(w:wallHeightAt(1, 6), 1, 'and its height entry is gone with it')
    t.eq(w.wallHeights['1,6'], nil, 'not left as a ghost on rubble')

    ---------------------------------------------------------------------
    t.describe('map header round-trip')

    local text = [[
name  short walls
theme dungeon
spawn 2.5 2.5 0
height 1 2 0.5
height 1 3 0.25
---
######
#....#
#....#
#....#
#....#
######
]]
    local map, err = Map.parse(text)
    t.ok(map ~= nil, 'map with height lines parses', err and err[1])
    t.eq(#(map.wallHeights or {}), 2, 'both height lines are kept')

    local world = Map.toWorld(map)
    t.eq(world:isSolid(1, 2), true, 'height lines target solid border tiles')
    t.eq(world:wallHeightAt(1, 2), 0.5, 'toWorld applies the first height')
    t.eq(world:wallHeightAt(1, 3), 0.25, 'and the second')
    t.eq(world:wallHeightAt(1, 1), 1, 'untouched walls stay full')

    local back = Map.fromWorld(world)
    t.eq(#back.wallHeights, 2, 'fromWorld captures both')
    local ser = Map.serialize(back)
    t.ok(ser:find('height 1 2 0.5', 1, true), 'serialize writes the height line')
    t.ok(ser:find('height 1 3 0.25', 1, true), 'and the other')

    local again = Map.parse(ser)
    t.ok(again ~= nil, 'serialized map re-parses')
    local world2 = Map.toWorld(again)
    t.eq(world2:wallHeightAt(1, 2), 0.5, 'round-trip preserves height')
    t.eq(world2:wallHeightAt(1, 3), 0.25)

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
end
