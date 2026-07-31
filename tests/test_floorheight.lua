--[[
    Walkable floor elevation: stand on a raised tile, step up within MAX_STEP,
    and refuse a taller ledge.
]]

return function(t)
    local World = require('meatray.sim.world')
    local Worldgen = require('meatray.sim.worldgen')
    local Collide = require('meatray.sim.collide')
    local Entity = require('meatray.sim.entity')
    local Map = require('meatray.sim.map')
    local Billboard = require('meatray.sim.billboard')
    local Raycaster = require('meatray.render.raycaster')
    local floor = math.floor

    ---------------------------------------------------------------------
    t.describe('floor height defaults and setters')

    local w = Worldgen.box(12, 12)
    t.eq(w:floorHeightAt(5, 5), 0, 'default floor is the classic plane')
    t.eq(w:floorHeightAtPoint(5.2, 5.7), 0, 'and so is a point sample')

    t.eq(w:setFloorHeight(5, 5, 0.3), true, 'a tile accepts a raised floor')
    t.eq(w:floorHeightAt(5, 5), 0.3, 'and returns it')
    t.eq(w:floorHeightAtPoint(4.5, 4.5), 0.3, 'point sample hits the tile')

    t.eq(w:setFloorHeight(5, 5, 0), true, 'zero clears')
    t.eq(w:floorHeightAt(5, 5), 0, 'back to default')
    t.eq(w.floorHeights['5,5'], nil, 'entry is absent, not stored as 0')

    t.eq(w:setFloorHeight(5, 5, -1), false, 'negative is refused')
    t.eq(w:setFloorHeight(99, 99, 0.5), false, 'OOB is refused')

    ---------------------------------------------------------------------
    t.describe('step rules')

    t.eq(Collide.canStep(0, 0.3), true, 'a 0.3 rise is within MAX_STEP')
    t.eq(Collide.canStep(0, Collide.MAX_STEP), true, 'exactly MAX_STEP is allowed')
    t.eq(Collide.canStep(0, Collide.MAX_STEP + 0.05), false, 'higher is not')
    t.eq(Collide.canStep(0.5, 0), true, 'drops are always free')
    t.eq(Collide.canStep(0.5, 0.2), true, 'a small drop is free')

    ---------------------------------------------------------------------
    t.describe('movement steps up and refuses a ledge')

    local room = Worldgen.box(10, 10)
    -- Open floor corridor: raise tiles x=5,y=3..7
    for y = 3, 7 do
        room:setFloorHeight(5, y, 0.25)
    end
    -- A high ledge at x=6 that is too tall to step onto from 0.25
    for y = 3, 7 do
        room:setFloorHeight(6, y, 0.25 + Collide.MAX_STEP + 0.2)
    end

    local e = Entity.new{ x = 3.5, y = 5.5 }
    Collide.ground(e, room)
    t.eq(e.z, 0, 'grounded on the low floor')

    Collide.move(e, 1.2, 0, room)
    t.ok(e.x > 4.5, 'walked onto the raised strip')
    t.near(e.z, 0.25, 1e-9, 'and z followed the floor')

    local beforeX = e.x
    local _, blocked = Collide.move(e, 1.0, 0, room)
    t.eq(blocked, true, 'the tall ledge blocks the step')
    t.eq(e.x, beforeX, 'x did not move onto it')
    t.near(e.z, 0.25, 1e-9, 'z stays on the current surface')

    -- Drop back down is free.
    Collide.move(e, -2.0, 0, room)
    t.ok(e.x < 4.5, 'walked back onto the low floor')
    t.eq(e.z, 0, 'and dropped without a block')

    ---------------------------------------------------------------------
    t.describe('map floor lines round-trip')

    local text = [[
name  raised
theme dungeon
spawn 2.5 2.5 0
floor 3 2 0.4
floor 4 2 0.4
---
######
#....#
#....#
######
]]
    local map, err = Map.parse(text)
    t.ok(map ~= nil, 'parses', err and err[1])
    t.eq(#(map.floorHeights or {}), 2, 'two floor lines')
    local world = Map.toWorld(map)
    t.eq(world:floorHeightAt(3, 2), 0.4, 'toWorld applies floor height')
    t.eq(world:floorHeightAt(2, 2), 0, 'other tiles stay at 0')

    local back = Map.fromWorld(world)
    t.eq(#back.floorHeights, 2, 'fromWorld captures them')
    local ser = Map.serialize(back)
    t.ok(ser:find('floor 3 2 0.4', 1, true), 'serialize writes floor lines')
    local again = Map.toWorld(assert(Map.parse(ser)))
    t.eq(again:floorHeightAt(4, 2), 0.4, 'round-trip preserves')

    ---------------------------------------------------------------------
    t.describe('camera and sprite projection follow eye and feet z')

    local H, horizon = 600, 300
    local dist = 2.0
    local full = H / dist

    -- Raised camera (standing on floor 0.3, eye at 0.8): a z=0 wall base drops
    -- lower on screen than with the default eye.
    local ds0, de0 = Raycaster.projectWall(dist, 1, H, horizon, 0, 0.5)
    local ds1, de1 = Raycaster.projectWall(dist, 1, H, horizon, 0, 0.8)
    t.ok(de1 > de0, 'higher eye puts the floor-line lower on screen')
    t.ok(ds1 > ds0, 'and the wall top lower too')

    -- Sprite feet on a raised floor sit higher than feet at z=0 for the same eye.
    local r0 = Billboard.screenRect(0, dist, 800, H, { eyeZ = 0.5, feetZ = 0 })
    local r1 = Billboard.screenRect(0, dist, 800, H, { eyeZ = 0.5, feetZ = 0.3 })
    t.ok(r1.y < r0.y, 'raised feet draw higher on screen (smaller y)')
    t.near(r0.y + r0.h, horizon + full * 0.5, 2,
           'default feet land on the classic floor line')
end
