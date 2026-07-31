--[[
    Short-lived world marks: add, hit offset, expire, cap.
]]

return function(t)
    local Decals = require('meatray.sim.decals')

    ---------------------------------------------------------------------
    t.describe('add and list')

    local marks = Decals.new{ max = 8, defaultLife = 5 }
    t.eq(marks:count(), 0, 'starts empty')

    local d = marks:add{ x = 1.5, y = 2.5, kind = 'scorch', scale = 0.3 }
    t.eq(marks:count(), 1, 'one mark after add')
    t.eq(d.kind, 'scorch', 'kind stored')
    t.eq(d.life, 5, 'default life applied')
    t.eq(d.maxLife, 5, 'maxLife matches for fade')
    t.eq(marks:all()[1], d, 'all() is the live list')

    ---------------------------------------------------------------------
    t.describe('addHit backs off the surface')

    local hit = marks:addHit(4.0, 5.0, 1, 0, { kind = 'bullet', life = 2 })
    t.ok(hit.wall, 'flagged as wall mark')
    t.near(hit.x, 3.96, 1e-6, 'backed off along normal')
    t.eq(hit.y, 5.0, 'y unchanged for pure +x normal')
    t.eq(hit.nx, 1, 'normal stored')

    ---------------------------------------------------------------------
    t.describe('update expires and alpha fades')

    marks:update(1.0)
    t.eq(hit.life, 1.0, 'life ticks down')
    t.near(Decals.alpha(hit), 0.5, 1e-9, 'half life = half alpha')

    marks:update(1.5)
    t.eq(marks:count(), 1, 'expired hit removed, scorch remains')
    t.eq(marks:all()[1].kind, 'scorch', 'scorch still alive')

    ---------------------------------------------------------------------
    t.describe('cap drops oldest')

    local cap = Decals.new{ max = 3, defaultLife = 10 }
    for i = 1, 5 do
        cap:add{ x = i, y = 0, kind = 'k' .. i }
    end
    t.eq(cap:count(), 3, 'capped at max')
    t.eq(cap:all()[1].kind, 'k3', 'oldest two dropped')
    t.eq(cap:all()[3].kind, 'k5', 'newest kept')

    cap:clear()
    t.eq(cap:count(), 0, 'clear empties')
end
