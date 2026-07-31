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

    ---------------------------------------------------------------------
    t.describe('floor risers and multi-plane list')

    local plat = Worldgen.box(12, 12)
    -- 2x2 platform at z=0.4 in the open centre
    for y = 5, 6 do
        for x = 5, 6 do
            plat:setFloorHeight(x, y, 0.4, { defer = true })
        end
    end
    plat:rebuildFloorRisers()

    local planes = plat:floorHeightPlanes()
    t.eq(planes[1], 0, 'planes always include the base')
    t.eq(#planes, 2, 'and the raised height once')
    t.eq(planes[2], 0.4, 'the raised plane is listed')

    t.ok(plat:segmentCount() > 0, 'risers were generated at platform edges')
    local autoN = 0
    for i = 1, plat.segments.count do
        local seg = plat.segments.list[i]
        if seg.auto then
            autoN = autoN + 1
            t.near(seg.base, 0, 1e-9, 'riser sits on the lower floor')
            t.near(seg.height, 0.4, 1e-9, 'and rises to the platform top')
        end
    end
    t.ok(autoN >= 4, 'at least the outer edges of a 2x2 platform exist',
         ('got %d auto segments'):format(autoN))

    -- Hand-authored thin wall survives a riser rebuild.
    plat:addSegment(2, 2, 3, 2, { tex = 2 })
    local handCount = 0
    for i = 1, plat.segments.count do
        if not plat.segments.list[i].auto then handCount = handCount + 1 end
    end
    plat:rebuildFloorRisers()
    local handAfter = 0
    for i = 1, plat.segments.count do
        if not plat.segments.list[i].auto then handAfter = handAfter + 1 end
    end
    t.eq(handAfter, handCount, 'rebuildFloorRisers does not wipe hand segments')

    ---------------------------------------------------------------------
    t.describe('map elevation helpers for the editor')

    local m = Map.blank(8, 8)
    t.eq(Map.floorHeight(m, 3, 3), 0, 'blank map has flat floors')
    t.eq(Map.setFloorHeight(m, 3, 3, 0.4), true)
    t.eq(Map.floorHeight(m, 3, 3), 0.4, 'setFloorHeight sticks')
    t.eq(Map.setFloorHeight(m, 3, 3, 0.6), true)
    t.eq(Map.floorHeight(m, 3, 3), 0.6, 'overwrite updates the same entry')
    t.eq(#m.floorHeights, 1, 'still one list entry')

    t.eq(Map.setWallHeight(m, 1, 1, 0.5), true)
    t.eq(Map.wallHeight(m, 1, 1), 0.5, 'short wall height sticks')
    Map.clearElevation(m, 1, 1)
    t.eq(Map.wallHeight(m, 1, 1), 1, 'clearElevation restores full wall')
    Map.clearElevation(m, 3, 3)
    t.eq(Map.floorHeight(m, 3, 3), 0, 'and flat floor')

    local world = Map.toWorld(m)
    t.ok(world ~= nil, 'map with elevation helpers still builds a world')

    ---------------------------------------------------------------------
    t.describe('camera pitch shifts the horizon')

    local H = 600
    t.eq(Raycaster.clampPitch(0), 0, 'zero pitch stays zero')
    t.eq(Raycaster.clampPitch(10), Raycaster.MAX_PITCH, 'pitch clamps high')
    t.eq(Raycaster.clampPitch(-10), -Raycaster.MAX_PITCH, 'and low')
    t.eq(Raycaster.clampPitch(0 / 0), 0, 'NaN becomes zero')

    local up = Raycaster.horizonShiftForPitch(0.5, H)
    local down = Raycaster.horizonShiftForPitch(-0.5, H)
    t.ok(up > 0, 'looking up moves the horizon down the screen')
    t.ok(down < 0, 'looking down moves it up')
    t.near(up, -down, 1e-9, 'symmetric about zero')

    local flat = Raycaster.view(2, 2, 0, { pitch = 0, screenH = H })
    local lookUp = Raycaster.view(2, 2, 0, { pitch = 0.4, screenH = H })
    t.eq(flat.horizonShift, 0, 'flat view has no horizon shift')
    t.ok(lookUp.horizonShift > 0, 'pitched view reports a positive shift')
    t.near(lookUp.horizonShift, Raycaster.horizonShiftForPitch(0.4, H), 1e-9,
           'and matches the helper')
    t.eq(lookUp.pitch, 0.4, 'pitch is stored on the view')
end
