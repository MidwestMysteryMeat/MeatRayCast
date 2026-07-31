--[[
    Host-side AI: patrol, chase, cover, LOS helpers.
]]

return function(t)
    local Entity = require('meatray.sim.entity')
    local C = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local AI = require('meatray.sim.ai')
    local Collide = require('meatray.sim.collide')

    Entity.clearArchetypes()
    Entity.archetype('mob', function(e)
        e:add(C.Brain{})
        e:add(C.Health{ hp = 100, max = 100 })
        e.radius = 0.25
    end)
    Entity.archetype('hero', function(e)
        e:add(C.Player{ peerId = 1, name = 'p' })
        e:add(C.Health{ hp = 100, max = 100 })
        e.radius = 0.24
    end)

    local world = Worldgen.box(20, 20)
    local step = 1 / 60

    ---------------------------------------------------------------------
    t.describe('attach and patrol')

    local mob = Entity.spawn('mob', 5.5, 5.5)
    AI.attach(mob, {
        state = 'patrol',
        patrol = {
            { x = 5.5, y = 5.5 },
            { x = 8.5, y = 5.5 },
        },
        speed = 4,
        alertRange = 3,
    })
    t.eq(mob:get('brain').state, 'patrol', 'starts on patrol')

    for _ = 1, 180 do
        AI.step(mob, step, { world = world, entities = { mob } })
    end
    t.ok(mob.x > 6.0, 'patrol moves the entity along the route',
         ('x=%.2f'):format(mob.x))

    ---------------------------------------------------------------------
    t.describe('chase when target enters alert range')

    local hunter = Entity.spawn('mob', 4.5, 10.5)
    AI.attach(hunter, {
        state = 'patrol',
        patrol = { { x = 4.5, y = 10.5 }, { x = 5.5, y = 10.5 } },
        alertRange = 8,
        loseRange = 12,
        speed = 5,
    })
    local player = Entity.spawn('hero', 10.5, 10.5)

    for _ = 1, 240 do
        AI.step(hunter, step, {
            world = world,
            entities = { hunter, player },
            target = player,
        })
    end
    t.eq(hunter:get('brain').state, 'chase', 'switches to chase')
    t.ok(Collide.distance(hunter, player) < 6,
         'closes distance on the player',
         ('dist=%.2f'):format(Collide.distance(hunter, player)))

    ---------------------------------------------------------------------
    t.describe('cover when hurt and seen')

    local shy = Entity.spawn('mob', 3.5, 3.5)
    AI.attach(shy, {
        state = 'chase',
        alertRange = 15,
        loseRange = 20,
        speed = 6,
        coverRadius = 6,
    })
    shy:get('health').hp = 20
    -- Open LOS: cover only engages when the threat can still see us.
    local threat = Entity.spawn('hero', 10.5, 3.5)
    t.eq(AI.hasLineOfSight(world, shy.x, shy.y, threat.x, threat.y), true,
         'open floor between shy and threat')

    AI.step(shy, step, {
        world = world, entities = { shy, threat }, target = threat,
    })
    t.eq(shy:get('brain').state, 'cover', 'hurt + LOS -> cover')

    ---------------------------------------------------------------------
    t.describe('findCover prefers broken LOS')

    -- Wall so a broken-LOS tile exists to the west of the threat.
    for y = 2, 8 do world.grid[y][8] = 1 end
    local cx, cy = AI.findCover(world, 3.5, 5.5, 12.5, 5.5, 8)
    t.ok(cx ~= nil, 'finds a cover point')
    t.eq(AI.hasLineOfSight(world, cx, cy, 12.5, 5.5), false,
         'and it breaks line of sight to the threat')

    ---------------------------------------------------------------------
    t.describe('stepAll ignores clientside-empty brains safely')

    local n = 0
    AI.stepAll({ hunter, player, shy }, step, {
        world = world, entities = { hunter, player, shy }, target = player,
    })
    t.ok(true, 'stepAll does not raise')
end
