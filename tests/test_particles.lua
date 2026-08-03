--[[
    C27: the particle kit — bursts spray off a normal, obey the cap, move under
    gravity and drag, rest on the floor, fade out, and tracers are segments
    that hold still.
]]

return function(t)
    local Particles = require('meatray.render.particles')
    local MeatRay = require('meatray')

    t.eq(MeatRay.particles, Particles, 'MeatRay.particles is the module')

    -- A deterministic source, so the geometry assertions are not at the mercy
    -- of math.random (production leaves this nil and uses it).
    local seq, seqI = { 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 }, 0
    local function fixed() seqI = seqI % #seq + 1; return seq[seqI] end

    ---------------------------------------------------------------------
    t.describe('a burst makes its kind\'s count of particles')

    local fx = Particles.new{ randomSource = fixed }
    local n = fx:burst('spark', 5, 5, { nx = -1, ny = 0 })
    t.eq(n, Particles.KINDS.spark.count, 'spark burst makes the spark count')
    t.eq(fx:count(), n, 'and they are in the set')

    -- Every particle carries a position, a velocity and a colour.
    for _, p in ipairs(fx:all()) do
        t.ok(p.x == 5 and p.y == 5, 'spawned at the hit point')
        t.ok(type(p.vx) == 'number' and type(p.vy) == 'number', 'with a velocity')
        t.ok(#p.color == 3, 'and an RGB colour')
        t.ok(p.life > 0, 'and life left')
    end

    ---------------------------------------------------------------------
    t.describe('the spray flies off the surface normal')

    -- Normal points -x (out of a wall on the player's right). The particles
    -- should, on average, head -x — sum of vx must be negative.
    local wall = Particles.new{ randomSource = fixed }
    wall:burst('spark', 10, 10, { nx = -1, ny = 0 })
    local sumVX = 0
    for _, p in ipairs(wall:all()) do sumVX = sumVX + p.vx end
    t.ok(sumVX < 0, 'sparks off a -x wall head -x on average (' .. sumVX .. ')')

    ---------------------------------------------------------------------
    t.describe('the cap is hard, oldest dropped first')

    local small = Particles.new{ max = 10, randomSource = fixed }
    for _ = 1, 5 do small:burst('spark', 0, 0) end   -- 40 particles into a cap of 10
    t.eq(small:count(), 10, 'never exceeds the cap')

    ---------------------------------------------------------------------
    t.describe('particles move, drag, gravitate, and rest on the floor')

    local mv = Particles.new{ randomSource = function() return 0.5 end }
    mv:burst('debris', 3, 3, { nx = 1, ny = 0, z = 1 })
    local p = mv:all()[1]
    local x0, sp0 = p.x, math.abs(p.vx)
    mv:update(0.1)
    t.ok(p.x ~= x0, 'a particle moves')
    t.ok(math.abs(p.vx) < sp0, 'and drag has slowed it')

    -- Gravity pulls z down until the floor stops it.
    mv:update(2.0)                              -- long enough to fall and settle
    -- (may have expired by now — check a fresh long-lived one instead)
    local fall = Particles.new{ randomSource = function() return 0.5 end }
    local q = fall:tracer(0, 0, 0, 0)           -- reuse tracer to get one handle... no
    fall:clear()
    fall.list[1] = { x = 0, y = 0, z = 2, vx = 0, vy = 0, vz = 0,
                     gravity = 10, drag = 1, life = 5, maxLife = 5, size = 0.05,
                     color = { 1, 1, 1 } }
    fall:update(1.0)
    t.ok(fall.list[1].z >= 0, 'a falling particle never sinks below the floor')
    t.ok(fall.list[1].z < 2, 'but it did fall')

    ---------------------------------------------------------------------
    t.describe('life runs out and the particle is culled')

    local die = Particles.new{ randomSource = fixed }
    die:burst('spark', 0, 0)
    local before = die:count()
    t.ok(before > 0, 'some sparks')
    die:update(10)                              -- far past any spark's life
    t.eq(die:count(), 0, 'all expired and culled')

    ---------------------------------------------------------------------
    t.describe('alpha fades from 1 to 0 over life')

    local a = Particles.new{}
    a.list[1] = { life = 1, maxLife = 1 }
    t.eq(Particles.alpha(a.list[1]), 1, 'full at spawn')
    a.list[1].life = 0.5
    t.near(Particles.alpha(a.list[1]), 0.5, 1e-9, 'half at half life')
    t.eq(Particles.alpha(nil), 0, 'a nil particle is invisible, not a crash')

    ---------------------------------------------------------------------
    t.describe('a tracer is a still segment that expires')

    local tr = Particles.new{}
    local seg = tr:tracer(1, 1, 8, 5, { z = 0.5 })
    t.eq(seg.tracer, true, 'flagged as a tracer')
    t.eq(seg.x2, 8, 'carries its far point')
    t.eq(seg.y2, 5, 'both coordinates')
    local sx = seg.x
    tr:update(0.04)
    t.eq(seg.x, sx, 'a tracer does not move — it is a line, not a spark')
    tr:update(0.1)
    t.eq(tr:count(), 0, 'and it expires fast')

    ---------------------------------------------------------------------
    t.describe('an air burst (no normal) still sprays')

    local air = Particles.new{ randomSource = fixed }
    local an = air:burst('smoke', 4, 4)         -- no nx/ny
    t.eq(an, Particles.KINDS.smoke.count, 'a normal-less burst still makes its count')
    t.ok(air:count() > 0, 'and they exist')

    t.eq(air:burst('nonexistent', 0, 0), Particles.KINDS.spark.count,
         'an unknown kind falls back to spark rather than making nothing')
end
