--[[
    C17: auto-closing doors. An armed door re-closes after its delay; a door with
    someone standing in it waits instead of closing on them; the timer arms on
    every open path and disarms on close.
]]

return function(t)
    local Worldgen = require('meatray.sim.worldgen')

    local function room()
        local w = Worldgen.box(10, 10)
        w:addDoor(5, 5, false)      -- a shut door
        return w
    end

    ---------------------------------------------------------------------
    t.describe('an armed door re-closes after its delay')

    local w = room()
    w:setDoorAutoClose(5, 5, 3)
    t.ok(w:setDoorOpen(5, 5, true), 'door opens')
    t.eq(w:doorAt(5, 5).open, true, 'and is open')
    t.eq(w:doorAt(5, 5).closeIn, 3, 'the re-close timer armed on open')

    t.eq(w:tickDoors(2), 0, 'nothing closes before the delay')
    t.eq(w:doorAt(5, 5).open, true, 'still open at 2s')
    t.eq(w:tickDoors(1.1), 1, 'it closes once the timer runs out')
    t.eq(w:doorAt(5, 5).open, false, 'the door is shut')
    t.eq(w:doorAt(5, 5).closeIn, nil, 'and the timer is cleared')

    ---------------------------------------------------------------------
    t.describe('a blocked doorway waits instead of closing on someone')

    w:setDoorOpen(5, 5, true)
    local blocked = true
    local function isBlocked(tx, ty) return blocked and tx == 5 and ty == 5 end
    w:tickDoors(5, isBlocked)                 -- well past the delay, but blocked
    t.eq(w:doorAt(5, 5).open, true, 'a blocked door stays open')
    t.ok(w:doorAt(5, 5).closeIn and w:doorAt(5, 5).closeIn > 0, 'and keeps a grace timer')
    blocked = false
    w:tickDoors(1, isBlocked)                 -- clear now
    t.eq(w:doorAt(5, 5).open, false, 'it closes once the way is clear')

    ---------------------------------------------------------------------
    t.describe('a door with no auto-close never re-closes')

    local w2 = room()
    w2:setDoorOpen(5, 5, true)                -- opened, but never armed
    t.eq(w2:doorAt(5, 5).closeIn, nil, 'no timer without setDoorAutoClose')
    w2:tickDoors(100)
    t.eq(w2:doorAt(5, 5).open, true, 'stays open forever, as before C17')

    ---------------------------------------------------------------------
    t.describe('toggleDoor arms and disarms the timer too')

    local w3 = room()
    w3:setDoorAutoClose(5, 5, 2)
    w3:toggleDoor(5, 5)                       -- open
    t.eq(w3:doorAt(5, 5).closeIn, 2, 'toggle-open arms it')
    w3:toggleDoor(5, 5)                       -- shut again manually
    t.eq(w3:doorAt(5, 5).open, false, 'shut')
    t.eq(w3:doorAt(5, 5).closeIn, nil, 'manual close disarms the timer')

    ---------------------------------------------------------------------
    t.describe('setAllDoorsAutoClose arms every door')

    local w4 = Worldgen.box(12, 12)
    w4:addDoor(3, 3, false)
    w4:addDoor(8, 8, false)
    w4:setAllDoorsAutoClose(4)
    w4:setDoorOpen(3, 3, true)
    w4:setDoorOpen(8, 8, true)
    t.eq(w4:doorAt(3, 3).closeIn, 4, 'first door armed')
    t.eq(w4:doorAt(8, 8).closeIn, 4, 'second door armed')
    t.eq(w4:tickDoors(5), 2, 'both close together')

    -- Clearing it disarms.
    w4:setDoorOpen(3, 3, true)
    w4:setAllDoorsAutoClose(nil)
    t.eq(w4:doorAt(3, 3).autoClose, nil, 'auto-close cleared')
end
