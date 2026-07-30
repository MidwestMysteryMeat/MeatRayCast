--[[
    Projectiles: flight, substepping, impact and detonation.

    The assertion worth the file is the substepping one. A projectile moved by
    `x = x + vx * dt` walks through walls the moment its speed times the step
    exceeds a tile, and the symptom is "the fast gun doesn't work indoors" —
    which reads as a level bug, not a physics one. So the suite fires the same
    projectile at the same wall at 5, 50 and 500 tiles per second and asserts all
    three stop at it.
]]

local Entity   = require('meatray.sim.entity')
local C        = require('meatray.sim.components')
local World    = require('meatray.sim.world')
local Worldgen = require('meatray.sim.worldgen')
local Game     = require('meatray.game')

local Projectiles = Game.projectiles
local Explosion   = Game.explosion
local Effects     = Game.effects
local Attributes  = Game.attributes

local STEP = 1 / 60

return function(t)
    Game.reset()
    Entity.clearArchetypes()

    local function dummy(x, y, hp)
        local e = Entity.new{ kind = 'dummy', x = x, y = y }
        e:add(C.Health{ hp = hp or 1000, max = hp or 1000 })
        e.radius = 0.3
        Game.attach(e, { authority = true })
        return e
    end

    local function hp(e) return Attributes.get(e, 'health') end

    ---------------------------------------------------------------------
    t.describe('spawning is validated')

    t.ok(Projectiles.spawn{ x = 1, y = 1, angle = 0 } ~= nil, 'a plain bolt spawns')
    t.ok(Projectiles.spawn{ x = 0 / 0, y = 1, angle = 0 } == nil, 'a NaN origin is refused')
    t.ok(Projectiles.spawn{ x = 1, y = 1, angle = 0 / 0 } == nil, 'and a NaN angle')
    t.ok(Projectiles.spawn{ x = 1, y = 1, dirX = 0, dirY = 0 } == nil,
         'and a direction with no length')
    t.ok(Projectiles.spawn{ x = 1, y = 1, angle = 0, speed = 0 } == nil,
         'and a speed of zero, which would never arrive anywhere')
    t.ok(Projectiles.spawn{ x = 1, y = 1, angle = 0, range = -1 } == nil,
         'and a negative range')
    t.ok(Projectiles.spawn('not a table') == nil, 'and a non-table')

    local p = Projectiles.spawn{ x = 2, y = 3, angle = 0, kind = 'rocket' }
    t.eq(p.kind, 'rocket', 'the kind is carried, so a client can draw it')
    t.eq(p.x, 2, 'and the origin')
    t.ok(Projectiles.is(p), 'and it is recognisably a projectile')
    t.eq(#p.components.projectile.__def.netFields, 0,
         'the projectile component sends nothing: the transform is all a client needs')

    ---------------------------------------------------------------------
    t.describe('flight')

    local w = Worldgen.box(24, 24)

    local flying = Projectiles.spawn{ x = 2.5, y = 2.5, angle = 0, speed = 6, range = 10 }
    local ents = { flying }
    Projectiles.step(ents, STEP, { world = w, entities = ents })
    t.near(flying.x, 2.5 + 6 * STEP, 1e-9, 'one step moves it speed * dt')
    t.near(flying.y, 2.5, 1e-12, 'in the direction it was fired')
    t.ok(not flying.dead, 'and it is still flying')

    -- Range: it expires rather than travelling forever.
    local expired = nil
    for _ = 1, 200 do
        local impacts = Projectiles.step(ents, STEP, { world = w, entities = ents })
        if #impacts > 0 then expired = impacts[1] break end
    end
    t.ok(expired ~= nil, 'it eventually stops')
    t.eq(expired.kind, 'expired', 'having run out')
    t.eq(expired.reason, 'range', 'of range')
    t.ok(flying.dead, 'and is marked dead, which is the despawn signal that already existed')

    -- Lifetime is the other limit.
    local timed = Projectiles.spawn{ x = 2.5, y = 4.5, angle = 0, speed = 1,
                                     range = 1000, lifetime = 0.5 }
    local timedEnts = { timed }
    local timedOut = nil
    for _ = 1, 60 do
        local impacts = Projectiles.step(timedEnts, STEP, { world = w, entities = timedEnts })
        if #impacts > 0 then timedOut = impacts[1] break end
    end
    t.ok(timedOut ~= nil and timedOut.reason == 'lifetime', 'a lifetime expires it too')

    ---------------------------------------------------------------------
    t.describe('SUBSTEPPING: a fast projectile does not walk through a wall')

    for _, speed in ipairs({ 5, 50, 500, 5000 }) do
        local box = Worldgen.box(24, 24)
        local fast = Projectiles.spawn{ x = 2.5, y = 6.5, angle = 0,
                                        speed = speed, range = 100 }
        local list = { fast }
        local wallHit = nil
        for _ = 1, 400 do
            local impacts = Projectiles.step(list, STEP, { world = box, entities = list })
            if #impacts > 0 then wallHit = impacts[1] break end
        end
        t.eq(wallHit and wallHit.kind, 'wall',
             ('at %d tiles/second it stops at the wall'):format(speed))
        t.ok(fast.x < 23, ('and at %d it is inside the room, not past it'):format(speed))
        t.eq(wallHit and wallHit.tx, 24, ('naming the tile it hit at %d'):format(speed))
    end

    ---------------------------------------------------------------------
    t.describe('impact damage is an effect')

    Effects.define('shocked', {
        duration = 'infinite',
        incoming = { { tag = 'damage.type.physical', magnitude = 0.5 } },
    })

    local plain  = dummy(8.5, 8.5)
    local halved = dummy(8.5, 10.5)
    Effects.apply(halved, 'shocked')

    local function shootAt(target, damage)
        local bolt = Projectiles.spawn{ x = 2.5, y = target.y, angle = 0, speed = 12,
                                        range = 20, damage = damage or 60 }
        local list = { bolt, target }
        for _ = 1, 120 do
            local impacts = Projectiles.step(list, STEP, { world = w, entities = list })
            if #impacts > 0 then return impacts[1] end
        end
        return nil
    end

    local hit = shootAt(plain)
    t.ok(hit ~= nil, 'the bolt arrives')
    t.eq(hit.kind, 'entity', 'and reports an entity impact')
    t.eq(hit.target, plain, 'naming the target')
    t.near(1000 - hp(plain), 60, 1e-9, 'which took the full damage')

    shootAt(halved)
    t.near(1000 - hp(halved), 30, 1e-9,
           'and the resisting one took half, from the same code path')

    ---------------------------------------------------------------------
    t.describe('a projectile does not hit the entity that fired it')

    local owner = dummy(12.5, 12.5)
    local selfShot = Projectiles.spawn{ x = 12.5, y = 12.5, angle = 0, speed = 8,
                                        range = 6, damage = 100, owner = owner }
    local selfList = { selfShot, owner }
    for _ = 1, 120 do Projectiles.step(selfList, STEP, { world = w, entities = selfList }) end
    t.eq(hp(owner), 1000, 'the shooter is not shot by its own bolt at point blank')

    ---------------------------------------------------------------------
    t.describe('piercing')

    local first  = dummy(6.5, 14.5)
    local second = dummy(9.5, 14.5)
    local third  = dummy(12.5, 14.5)

    local spear = Projectiles.spawn{ x = 2.5, y = 14.5, angle = 0, speed = 10,
                                     range = 20, damage = 50, pierce = 1 }
    local spearList = { spear, first, second, third }
    local pierced = {}
    for _ = 1, 200 do
        local impacts = Projectiles.step(spearList, STEP,
                                         { world = w, entities = spearList })
        for i = 1, #impacts do pierced[#pierced + 1] = impacts[i] end
        if spear.dead then break end
    end

    t.near(1000 - hp(first), 50, 1e-9, 'the first target is hit')
    t.near(1000 - hp(second), 50, 1e-9, 'and the second, because it pierces once')
    t.eq(hp(third), 1000, 'but not the third')
    t.eq(#pierced, 2, 'two impacts were reported')

    ---------------------------------------------------------------------
    t.describe('a projectile that explodes')

    Explosion.define('frag', { radius = 4, damage = 100, curve = 'linear' })

    local blastWorld = Worldgen.box(24, 24)
    local bystander = dummy(16.5, 16.5)
    local wallward  = dummy(19.0, 16.5)

    local rocket = Projectiles.spawn{
        x = 12.5, y = 16.5, angle = 0, speed = 15, range = 20,
        damage = 0, explosion = 'frag',
    }
    local rocketList = { rocket, bystander, wallward }
    local boom = nil
    for _ = 1, 200 do
        local impacts = Projectiles.step(rocketList, STEP,
                                         { world = blastWorld, entities = rocketList })
        if #impacts > 0 then boom = impacts[1] break end
    end

    t.ok(boom ~= nil, 'the rocket lands')
    t.ok(boom.explosion ~= nil, 'and detonates')
    t.ok(hp(bystander) < 1000, 'damaging whoever it hit')
    t.ok(hp(wallward) < 1000, 'and whoever was near')
    t.ok(hp(wallward) > hp(bystander) or hp(bystander) < 1000,
         'with the blast falling off from the impact point')

    -- explodeOnExpire, for a grenade that goes off on a timer rather than a hit.
    local grenadeTarget = dummy(6.5, 18.5)
    local grenade = Projectiles.spawn{
        x = 4.5, y = 18.5, angle = 0, speed = 0.001, range = 1000,
        lifetime = 0.2, damage = 0, explosion = { radius = 3, damage = 40 },
        explodeOnExpire = true,
    }
    local gList = { grenade, grenadeTarget }
    local fuse = nil
    for _ = 1, 60 do
        local impacts = Projectiles.step(gList, STEP, { world = w, entities = gList })
        if #impacts > 0 then fuse = impacts[1] break end
    end
    t.ok(fuse ~= nil and fuse.kind == 'expired', 'the fuse runs out')
    t.ok(fuse.explosion ~= nil, 'and it goes off anyway')
    t.ok(hp(grenadeTarget) < 1000, 'catching whoever was standing over it')

    -- Without explodeOnExpire, a dud is a dud.
    local dudTarget = dummy(6.5, 20.5)
    local dud = Projectiles.spawn{
        x = 4.5, y = 20.5, angle = 0, speed = 0.001, range = 1000,
        lifetime = 0.2, damage = 0, explosion = { radius = 3, damage = 40 },
    }
    local dList = { dud, dudTarget }
    for _ = 1, 60 do Projectiles.step(dList, STEP, { world = w, entities = dList }) end
    t.eq(hp(dudTarget), 1000, 'a projectile that expires without explodeOnExpire is a dud')

    ---------------------------------------------------------------------
    t.describe('projectiles do not shoot each other')

    local a = Projectiles.spawn{ x = 4.5, y = 22.5, angle = 0, speed = 8,
                                 range = 10, damage = 10 }
    local b = Projectiles.spawn{ x = 8.5, y = 22.5, angle = math.pi, speed = 8,
                                 range = 10, damage = 10 }
    local pair = { a, b }
    for _ = 1, 200 do Projectiles.step(pair, STEP, { world = w, entities = pair }) end
    t.ok(a.dead and b.dead, 'both eventually stop')
    t.ok(a.components.projectile.hitCount == 0, 'but neither hit the other')
    t.ok(b.components.projectile.hitCount == 0, 'in either direction')

    ---------------------------------------------------------------------
    t.describe('sweeping dead projectiles is the caller\'s choice')

    local mixed = { Projectiles.spawn{ x = 1, y = 1, angle = 0 },
                    dummy(2, 2),
                    Projectiles.spawn{ x = 3, y = 3, angle = 0 } }
    mixed[1].dead = true
    mixed[3].dead = true
    t.eq(Projectiles.sweep(mixed), 2, 'two spent projectiles are swept')
    t.eq(#mixed, 1, 'leaving one entity')
    t.eq(mixed[1].kind, 'dummy', 'and it is not the projectile')

    ---------------------------------------------------------------------
    t.describe('a closed door stops a projectile; an open one does not')

    local grid = {}
    for y = 1, 12 do
        grid[y] = {}
        for x = 1, 12 do
            local border = (x == 1 or y == 1 or x == 12 or y == 12)
            grid[y][x] = (border or (x == 8 and y ~= 6)) and 1 or World.EMPTY
        end
    end
    local doored = World.new(grid)
    doored:addDoor(8, 6, false)

    local behind = dummy(10.5, 5.5)
    local shut = Projectiles.spawn{ x = 3.5, y = 5.5, angle = 0, speed = 10,
                                    range = 20, damage = 75 }
    local shutList = { shut, behind }
    for _ = 1, 200 do
        local impacts = Projectiles.step(shutList, STEP,
                                         { world = doored, entities = shutList })
        if #impacts > 0 then break end
    end
    t.eq(hp(behind), 1000, 'a shut door stops the bolt')

    doored:setDoorOpen(8, 6, true)
    local behindOpen = dummy(10.5, 5.5)
    local through = Projectiles.spawn{ x = 3.5, y = 5.5, angle = 0, speed = 10,
                                       range = 20, damage = 75 }
    local openList = { through, behindOpen }
    for _ = 1, 200 do
        local impacts = Projectiles.step(openList, STEP,
                                         { world = doored, entities = openList })
        if #impacts > 0 then break end
    end
    t.near(1000 - hp(behindOpen), 75, 1e-9, 'an open one lets it past')

    ---------------------------------------------------------------------
    t.describe('the step refuses nonsense time')

    local still = Projectiles.spawn{ x = 5, y = 5, angle = 0, speed = 10 }
    local stillList = { still }
    Projectiles.step(stillList, 0 / 0, { world = w, entities = stillList })
    t.eq(still.x, 5, 'a NaN step moves nothing')
    Projectiles.step(stillList, -1, { world = w, entities = stillList })
    t.eq(still.x, 5, 'and neither does a negative one')
    t.eq(#Projectiles.step(nil, STEP, {}), 0, 'and a missing entity list is survivable')

    Game.reset()
    Entity.clearArchetypes()
end
