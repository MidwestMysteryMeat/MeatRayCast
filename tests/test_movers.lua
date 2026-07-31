--[[
    Elevators: floor height animation + snapshot.
]]

return function(t)
    local Worldgen = require('meatray.sim.worldgen')
    local Movers = require('meatray.sim.movers')
    local Collide = require('meatray.sim.collide')
    local Entity = require('meatray.sim.entity')

    local world = Worldgen.box(12, 12)
    local movers = Movers.new(world)

    ---------------------------------------------------------------------
    t.describe('add and raise a platform')

    local m = movers:add{
        tiles = { { 4, 4 }, { 5, 4 }, { 4, 5 }, { 5, 5 } },
        zDown = 0, zUp = 0.4, speed = 1.0, start = 'down',
    }
    t.ok(m ~= nil, 'mover created')
    t.eq(m.z, 0, 'starts down')
    t.near(world:floorHeightAt(4, 4), 0, 1e-9, 'tiles at ground')

    movers:call(m.id, true)
    for _ = 1, 60 do movers:update(1 / 30) end
    t.near(m.z, 0.4, 0.02, 'reaches top')
    t.near(world:floorHeightAt(4, 4), 0.4, 0.02, 'tiles raised')
    t.eq(m.moving, false, 'stopped at top')

    ---------------------------------------------------------------------
    t.describe('toggle goes back down')

    movers:toggle(m.id)
    for _ = 1, 60 do movers:update(1 / 30) end
    t.near(m.z, 0, 0.02, 'back at bottom')

    ---------------------------------------------------------------------
    t.describe('snapshot round-trips')

    movers:call(m.id, true)
    movers:update(0.1)
    local snap = movers:snapshot()
    t.ok(#snap >= 1, 'snapshot has movers')

    local world2 = Worldgen.box(12, 12)
    local movers2 = Movers.new(world2)
    movers2:add{
        id = m.id,
        tiles = { { 4, 4 }, { 5, 4 }, { 4, 5 }, { 5, 5 } },
        zDown = 0, zUp = 0.4, speed = 1.0,
    }
    movers2:applySnapshot(snap)
    t.near(movers2:get(m.id).z, m.z, 1e-6, 'applied height matches')
    t.near(world2:floorHeightAt(4, 4), m.z, 1e-6, 'and world floor matches')

    ---------------------------------------------------------------------
    t.describe('entity stands on a raised mover')

    movers:call(m.id, true)
    for _ = 1, 60 do movers:update(1 / 30) end
    local e = Entity.new{ x = 4.5, y = 4.5 }
    Collide.ground(e, world)
    t.near(e.z, m.z, 0.05, 'grounded on elevator top')
end
