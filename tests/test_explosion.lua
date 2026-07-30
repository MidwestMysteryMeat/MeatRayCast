--[[
    Explosions: falloff, wall occlusion, and damage that is still an effect.

    The occlusion assertion is the one that matters to a player: "it killed me
    through a wall" is a complaint that gets filed, and the only way to be sure it
    cannot happen is to build a world with a wall in it, put a target on the far
    side, detonate, and assert the target took exactly zero. The suite then opens
    a door in the same wall and asserts it took something, so the test cannot pass
    by accident on a blast that was harmless anyway.
]]

local Entity   = require('meatray.sim.entity')
local C        = require('meatray.sim.components')
local World    = require('meatray.sim.world')
local Worldgen = require('meatray.sim.worldgen')
local Game     = require('meatray.game')

local Explosion  = Game.explosion
local Effects    = Game.effects
local Attributes = Game.attributes

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
    t.describe('falloff curves')

    t.near(Explosion.falloff(0, 4, 'linear'), 1, 1e-12, 'full at the centre')
    t.near(Explosion.falloff(2, 4, 'linear'), 0.5, 1e-12, 'half at half the radius')
    t.eq(Explosion.falloff(4, 4, 'linear'), 0, 'zero at the rim')
    t.eq(Explosion.falloff(9, 4, 'linear'), 0, 'and beyond it')
    t.eq(Explosion.falloff(1, 0, 'linear'), 0, 'a radius of zero reaches nothing')

    t.near(Explosion.falloff(0, 4, 'smooth'), 1, 1e-12, 'smooth is full at the centre')
    t.eq(Explosion.falloff(4, 4, 'smooth'), 0, 'and zero at the rim')
    t.near(Explosion.falloff(2, 4, 'smooth'), 0.5, 1e-12,
           'and crosses linear exactly at the midpoint, as smoothstep must')
    t.ok(Explosion.falloff(1, 4, 'smooth') > Explosion.falloff(1, 4, 'linear'),
         'smooth is more generous near the centre than linear')
    t.ok(Explosion.falloff(2, 4, 'inverse') < Explosion.falloff(2, 4, 'linear'),
         'and inverse is harsher')

    for _, curve in ipairs({ 'linear', 'smooth', 'inverse' }) do
        local previous = 2
        local monotone = true
        for d = 0, 40 do
            local v = Explosion.falloff(d / 10, 4, curve)
            if v > previous + 1e-12 then monotone = false end
            previous = v
        end
        t.ok(monotone, ('%s never increases with distance'):format(curve))
    end

    ---------------------------------------------------------------------
    t.describe('a detonation validates before it touches anything')

    local w = Worldgen.box(24, 24)

    local nope, why = Explosion.detonate{ entities = {}, x = 1, y = 1, radius = 2 }
    t.ok(nope == nil and why == 'an explosion needs a world', 'no world is refused', why)

    nope, why = Explosion.detonate{ world = w, x = 1, y = 1, radius = 2 }
    t.ok(nope == nil and why == 'an explosion needs entities', 'no entity list is refused', why)

    nope, why = Explosion.detonate{ world = w, entities = {}, x = 0 / 0, y = 1, radius = 2 }
    t.ok(nope == nil, 'a NaN centre is refused')
    t.ok(why and why:find('position is unusable'), 'by name', why)

    nope, why = Explosion.detonate{ world = w, entities = {}, x = 1, y = 1, radius = -3 }
    t.ok(nope == nil, 'a negative radius is refused')

    nope, why = Explosion.detonate{ world = w, entities = {}, x = 1, y = 1, radius = 1e12 }
    t.ok(nope == nil, 'an absurd radius is refused rather than walked')

    nope, why = Explosion.detonate{ world = w, entities = {}, x = 1, y = 1,
                                    radius = 2, curve = 'parabolic' }
    t.ok(nope == nil, 'an unknown curve is refused')

    nope, why = Explosion.detonate{ world = w, entities = {}, x = 1, y = 1, use = 'nope' }
    t.ok(nope == nil and why:find('unknown explosion'), 'and an unknown definition', why)

    ---------------------------------------------------------------------
    t.describe('damage falls off with distance')

    local near = dummy(10.0, 10.0)
    local mid  = dummy(12.0, 10.0)
    local far  = dummy(13.9, 10.0)
    local rim  = dummy(14.0, 10.0)     -- exactly at the radius
    local out  = dummy(18.0, 10.0)     -- outside it entirely
    local ents = { near, mid, far, rim, out }

    local result = Explosion.detonate{
        world = w, entities = ents,
        x = 10.0, y = 10.0, radius = 4, damage = 100, curve = 'linear',
    }

    t.ok(result ~= nil, 'the blast goes off')
    t.eq(#result.hits, 3, 'three of the five are actually hit')
    t.eq(result.missed, 1, 'the one exactly on the rim takes nothing and is reported')
    t.eq(hp(rim), 1000, 'the rim is exclusive, not inclusive')

    t.near(1000 - hp(near), 100, 1e-9, 'the one at the centre takes it all')
    t.near(1000 - hp(mid), 50, 1e-9, 'the one at half the radius takes half')
    t.ok((1000 - hp(far)) > 0 and (1000 - hp(far)) < 10,
         'the one at the rim takes almost nothing')
    t.eq(hp(out), 1000, 'and the one outside takes exactly nothing')

    t.ok(result.hits[1].entity == near, 'hits come back nearest first')
    t.near(result.hits[1].scale, 1, 1e-12, 'with the falloff scale that was used')
    t.near(result.hits[2].damage, 50, 1e-9, 'and the damage each took')

    ---------------------------------------------------------------------
    t.describe('A WALL STOPS IT')

    -- A solid column at x = 8, with a door at (8, 6) that starts shut.
    local grid = {}
    for y = 1, 12 do
        grid[y] = {}
        for x = 1, 12 do
            local border = (x == 1 or y == 1 or x == 12 or y == 12)
            grid[y][x] = (border or x == 8) and 1 or World.EMPTY
        end
    end
    local walled = World.new(grid)
    walled:addDoor(8, 6, false)

    -- Both targets are exactly four tiles from the blast, so the ONLY difference
    -- between them is the wall. A test where they were at different ranges could
    -- pass on falloff alone.
    local exposed   = dummy(2.5, 5.5)
    local sheltered = dummy(10.5, 5.5)
    local wallEnts = { exposed, sheltered }

    local blast = Explosion.detonate{
        world = walled, entities = wallEnts,
        x = 6.5, y = 5.5, radius = 6, damage = 200, curve = 'linear',
    }

    t.ok(hp(exposed) < 1000, 'the one in the open is hurt')
    t.eq(hp(sheltered), 1000, 'THE ONE BEHIND THE WALL TAKES EXACTLY NOTHING')
    t.eq(#blast.blocked, 1, 'and is reported as blocked rather than missed')
    t.eq(blast.blocked[1].entity, sheltered, 'naming who was in cover')
    t.eq(#blast.hits, 1, 'so only one entity was hit')

    -- Opening the door in that wall changes the answer, which is what proves the
    -- assertion above was about the wall and not about the blast being feeble.
    walled:setDoorOpen(8, 6, true)
    local doorway = dummy(10.5, 5.5)
    local through = Explosion.detonate{
        world = walled, entities = { doorway },
        x = 6.5, y = 5.5, radius = 6, damage = 200, curve = 'linear',
    }
    t.ok(hp(doorway) < 1000, 'with the door open the same blast reaches through it')
    t.eq(#through.blocked, 0, 'and nothing is in cover')

    -- Occlusion is opt-out for a game that wants concussive damage through cover.
    walled:setDoorOpen(8, 6, false)
    local ignoringWalls = dummy(10.5, 5.5)
    Explosion.detonate{
        world = walled, entities = { ignoringWalls },
        x = 6.5, y = 5.5, radius = 6, damage = 200, occlusion = false,
    }
    t.ok(hp(ignoringWalls) < 1000, 'occlusion = false damages through the wall')

    -- A blast that goes off flush against a wall still works: the tile it sits
    -- in must not block it, or every rocket that hits a wall would be harmless.
    local corridor = dummy(6.5, 5.5)
    Explosion.detonate{
        world = walled, entities = { corridor },
        x = 7.6, y = 5.5, radius = 5, damage = 120,
    }
    t.ok(hp(corridor) < 1000,
         'a blast flush against a wall still damages the room it came from')

    ---------------------------------------------------------------------
    t.describe('explosion damage is an effect, so resistance applies to it too')

    Effects.define('blastward', {
        duration = 'infinite',
        incoming = { { tag = 'damage.type.explosive', magnitude = 0.1 } },
    })

    local plain = dummy(10.0, 10.0)
    local warded = dummy(10.0, 10.0)
    t.ok(Effects.apply(warded, 'blastward'), 'one of them is warded')

    Explosion.detonate{ world = w, entities = { plain, warded },
                        x = 10.0, y = 10.0, radius = 4, damage = 100 }

    t.near(1000 - hp(plain), 100, 1e-9, 'the unwarded one takes the lot')
    t.near(1000 - hp(warded), 10, 1e-9,
           'and the warded one a tenth, from the same call, with nothing in '
           .. 'explosion.lua aware that wards exist')

    -- Armour soaks it too, for the same reason.
    local armoured = dummy(10.0, 10.0)
    Attributes.grant(armoured, 'armourMax', 200)
    Attributes.grant(armoured, 'armour', 200)
    Explosion.detonate{ world = w, entities = { armoured },
                        x = 10.0, y = 10.0, radius = 4, damage = 100 }
    t.eq(hp(armoured), 1000, 'armour absorbed the whole blast')
    t.near(Attributes.get(armoured, 'armour'), 100, 1e-9, 'and lost exactly its size')

    ---------------------------------------------------------------------
    t.describe('an on-hit effect rides along with the damage')

    Effects.define('burning', { duration = 3, period = 1,
                                assetTags = { 'debuff.burning' },
                                modifiers = { { attr = 'health', magnitude = -5 } } })

    local victim = dummy(10.0, 10.0)
    local fire = Explosion.detonate{
        world = w, entities = { victim },
        x = 10.0, y = 10.0, radius = 4, damage = 10, effects = { 'burning' },
    }
    t.ok(fire ~= nil, 'the blast goes off')
    t.eq(Effects.count(victim, 'burning'), 1, 'and left the target on fire')

    ---------------------------------------------------------------------
    t.describe('who is spared')

    local thrower = dummy(10.0, 10.0)
    local other = dummy(10.5, 10.0)
    Explosion.detonate{ world = w, entities = { thrower, other },
                        x = 10.0, y = 10.0, radius = 4, damage = 50,
                        source = thrower, selfDamage = false }
    t.eq(hp(thrower), 1000, 'selfDamage = false spares the source')
    t.ok(hp(other) < 1000, 'but nobody else')

    local jumper = dummy(10.0, 10.0)
    Explosion.detonate{ world = w, entities = { jumper },
                        x = 10.0, y = 10.0, radius = 4, damage = 50, source = jumper }
    t.ok(hp(jumper) < 1000, 'and by default the source is in its own blast')

    local spared = dummy(10.0, 10.0)
    Explosion.detonate{ world = w, entities = { spared },
                        x = 10.0, y = 10.0, radius = 4, damage = 50, ignore = spared }
    t.eq(hp(spared), 1000, 'an explicit ignore is honoured')

    ---------------------------------------------------------------------
    t.describe('the flash is described, and pushed only if there is somewhere to push it')

    local pushed = {}
    local fakeGrid = { addDynamic = function(self, light) pushed[#pushed + 1] = light end }

    local lit = Explosion.detonate{
        world = w, entities = {}, x = 5.5, y = 5.5, radius = 3, damage = 0,
        lighting = fakeGrid,
    }
    t.eq(#pushed, 1, 'a lighting grid is given a dynamic light')
    t.near(pushed[1].x, 5.5, 1e-12, 'at the blast centre')
    t.ok(pushed[1].radius > 3, 'reaching further than the damage did')
    t.eq(pushed[1], lit.light, 'and the caller gets the same table back')

    local viaCallback = nil
    Explosion.detonate{ world = w, entities = {}, x = 1.5, y = 1.5, radius = 3,
                        onLight = function(l) viaCallback = l end }
    t.ok(viaCallback ~= nil, 'or a plain callback, for a host that forwards it as an event')

    local dark = Explosion.detonate{ world = w, entities = {}, x = 5.5, y = 5.5,
                                     radius = 3, light = false }
    t.eq(dark.light, nil, 'light = false suppresses it entirely')

    local headless = Explosion.detonate{ world = w, entities = {}, x = 5.5, y = 5.5,
                                         radius = 3 }
    t.ok(headless ~= nil, 'and a dedicated server that passes no lighting at all is fine')
    t.ok(headless.light ~= nil, 'it just gets the description and ignores it')

    ---------------------------------------------------------------------
    t.describe('named explosions')

    t.ok(Explosion.define('frag', {
        radius = 5, damage = 80, curve = 'smooth',
        tags = { 'damage.type.explosive' },
    }), 'a blast can be named')

    t.eq(Explosion.definition('frag').radius, 5, 'and looked up')
    t.eq(#Explosion.ids(), 1, 'and listed')

    local named = dummy(6.0, 6.0)
    local byName = Explosion.at(6.0, 6.0, 'frag', { world = w, entities = { named } })
    t.ok(byName ~= nil, 'and detonated by name')
    t.near(1000 - hp(named), 80, 1e-9, 'with the definition\'s damage')
    t.eq(byName.curve, 'smooth', 'and its curve')

    local overridden = dummy(6.0, 6.0)
    local custom = Explosion.at(6.0, 6.0, 'frag',
                                { world = w, entities = { overridden }, damage = 10 })
    t.near(1000 - hp(overridden), 10, 1e-9, 'a field given at the call site wins')
    t.eq(custom.radius, 5, 'while the rest comes from the definition')

    t.ok(Explosion.compile({ radius = 0 }) == nil, 'a definition with no radius is refused')
    t.ok(Explosion.compile({ radius = 3, damage = -1 }) == nil,
         'and one with negative damage')

    ---------------------------------------------------------------------
    t.describe('an explosion can seed a gas cloud')

    local field = Game.gas.new{ world = w, name = 'smoke' }
    Explosion.detonate{ world = w, entities = {}, x = 6.5, y = 6.5,
                        radius = 3, damage = 0, gas = field, gasAmount = 20 }
    t.near(field:total(), 20, 1e-9, 'the whole charge went into the field')
    t.ok(field:densityAt(7, 7) > 0, 'centred on the blast')
    t.ok(field:activeCount() > 0, 'and it wakes up ready to spread')

    Game.reset()
    Entity.clearArchetypes()
end
