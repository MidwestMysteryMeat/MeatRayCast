--[[
    Trigger volumes: enter, stay, exit, once, filters, death cleanup.
]]

return function(t)
    local Triggers = require('meatray.sim.triggers')
    local Entity = require('meatray.sim.entity')

    local function mover(id, x, y)
        return Entity.new{ id = id, x = x, y = y }
    end

    ---------------------------------------------------------------------
    t.describe('enter and exit')

    local box = Triggers.new()
    local log = {}
    box:add{
        name = 'room',
        x1 = 2, y1 = 2, x2 = 5, y2 = 5,
        onEnter = function(e) log[#log + 1] = 'in:' .. e.id end,
        onExit  = function(e, _, reason) log[#log + 1] = 'out:' .. e.id .. ':' .. reason end,
    }

    local a = mover(1, 0.5, 0.5)
    box:update({ a }, 1 / 60)
    t.eq(#log, 0, 'outside: no events')

    a.x, a.y = 3, 3
    local en, ex = box:update({ a }, 1 / 60)
    t.eq(en, 1, 'one enter')
    t.eq(log[1], 'in:1', 'onEnter fired')
    t.eq(box:get('room'):count(), 1, 'one occupant')

    en, ex = box:update({ a }, 1 / 60)
    t.eq(en, 0, 'still inside: no re-enter')
    t.eq(ex, 0, 'and no exit')

    a.x, a.y = 9, 9
    en, ex = box:update({ a }, 1 / 60)
    t.eq(ex, 1, 'one exit')
    t.eq(log[2], 'out:1:leave', 'onExit with leave reason')

    ---------------------------------------------------------------------
    t.describe('stay callback and once')

    local pulses = 0
    local zone = Triggers.new()
    zone:add{
        name = 'pulse',
        x1 = 0, y1 = 0, x2 = 2, y2 = 2,
        onStay = function() pulses = pulses + 1 end,
    }
    local b = mover(2, 1, 1)
    zone:update({ b }, 0.1)
    zone:update({ b }, 0.1)
    zone:update({ b }, 0.1)
    t.eq(pulses, 2, 'onStay fires on steps after enter, not on enter itself')

    local hits = 0
    local once = Triggers.new()
    once:add{
        name = 'trip',
        x1 = 0, y1 = 0, x2 = 1, y2 = 1,
        once = true,
        onEnter = function() hits = hits + 1 end,
    }
    local c = mover(3, 0.5, 0.5)
    once:update({ c }, 0)
    c.x, c.y = 5, 5
    once:update({ c }, 0)
    c.x, c.y = 0.5, 0.5
    once:update({ c }, 0)
    t.eq(hits, 1, 'once trigger only fires the first enter')
    t.eq(once:get('trip').enabled, false, 'and disables itself')

    ---------------------------------------------------------------------
    t.describe('filter and tile helper')

    local filtered = Triggers.new()
    local saw = 0
    filtered:add{
        name = 'players',
        x1 = 0, y1 = 0, x2 = 10, y2 = 10,
        filter = function(e) return e.kind == 'player' end,
        onEnter = function() saw = saw + 1 end,
    }
    local p = mover(10, 1, 1); p.kind = 'player'
    local imp = mover(11, 1, 1); imp.kind = 'imp'
    filtered:update({ p, imp }, 0)
    t.eq(saw, 1, 'filter keeps only matching entities')

    local tiles = Triggers.new()
    local vol = tiles:addTiles{ name = 'cell', tx1 = 3, ty1 = 3, tx2 = 4, ty2 = 4 }
    t.near(vol.x1, 2, 1e-9, 'tile helper maps to world min corner')
    t.near(vol.x2, 4, 1e-9, 'and max corner')
    t.ok(vol:contains(2.5, 2.5), 'covers the first tile centre')
    t.ok(vol:contains(3.5, 3.5), 'and the second')
    t.eq(vol:contains(1.5, 1.5), false, 'not outside')

    ---------------------------------------------------------------------
    t.describe('death while inside fires exit')

    local tomb = Triggers.new()
    local reasons = {}
    tomb:add{
        name = 'grave',
        x1 = 0, y1 = 0, x2 = 5, y2 = 5,
        onExit = function(_, _, reason) reasons[#reasons + 1] = reason end,
    }
    local d = mover(20, 2, 2)
    tomb:update({ d }, 0)
    d.dead = true
    local _, deadExits = tomb:update({ d }, 0)
    t.eq(deadExits, 1, 'dead occupant exits')
    t.eq(reasons[1], 'dead', 'reason is dead')
end
