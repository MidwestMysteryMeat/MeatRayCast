--[[
    Gas: activity-proportional cost, and a conservation law that is asserted.

    Two sibling projects supply the two things this file has to prove, and both
    of them shipped their bug.

    The first walked every cell of the world every tick — eighteen thousand
    settled cells producing zero changes — and presented as a NETWORKING TIMEOUT
    rather than as a performance problem, because the tick that should have been
    servicing a socket was busy. So:

        * a settled field must do literally zero work, asserted directly;
        * the same disturbance in a 20x20 world and a 40x40 world must cost the
          SAME, asserted by comparing per-step visit counts step by step. That
          second one is the assertion that would have caught the original bug,
          because it fails the moment cost starts tracking world size.

    The second had a room-atmosphere model whose exchange rules were wrong in a
    way nothing noticed until colonists silently suffocated, with a green suite
    the whole time. So this file asserts the conservation law itself: with no
    decay, the total is invariant; with decay, the decay rate is exact and every
    scrap removed is accounted for in `lost`; and gas does not cross a shut door.
]]

local World    = require('meatray.sim.world')
local Worldgen = require('meatray.sim.worldgen')
local Entity   = require('meatray.sim.entity')
local C        = require('meatray.sim.components')
local Game     = require('meatray.game')

local Gas        = Game.gas
local Effects    = Game.effects
local Attributes = Game.attributes

local STEP = 1 / 60

return function(t)
    Game.reset()
    Entity.clearArchetypes()

    -- Runs a field until it goes quiet. Returns how many steps that took, or nil
    -- if it never did — which would itself be the self-feeding-cascade bug.
    local function settle(f, cap)
        for i = 1, cap or 20000 do
            f:step(STEP)
            if f:activeCount() == 0 then return i end
        end
        return nil
    end

    ---------------------------------------------------------------------
    t.describe('emission is validated, and never creates gas inside a wall')

    local w = Worldgen.box(20, 20)
    local field = Gas.new{ world = w, name = 'smoke', rate = 2 }

    t.eq(field:emit(10, 10, 5), 5, 'five units go into an open tile')
    t.near(field:densityAt(10, 10), 5, 1e-12, 'and are there')
    t.near(field:total(), 5, 1e-12, 'and are all the field holds')

    local none, why = field:emit(1, 1, 5)
    t.eq(none, 0, 'emitting into a wall puts nothing there')
    t.eq(why, 'solid', 'and says why')

    none, why = field:emit(999, 999, 5)
    t.eq(none, 0, 'and neither does emitting off the map')
    t.eq(why, 'out of bounds', 'with its own reason')

    none, why = field:emit(10, 10, 0 / 0)
    t.eq(none, 0, 'a NaN amount is refused before it can poison a cell')
    t.eq(why, 'unusable amount', 'by name')
    t.near(field:densityAt(10, 10), 5, 1e-12, 'and the cell is exactly what it was')

    t.eq(field:densityAt(-4, 0), 0, 'reading off the map is zero, not an error')
    t.near(field:densityAtPoint(9.5, 9.5), 5, 1e-12,
           'and a world position finds the tile under it')

    ---------------------------------------------------------------------
    t.describe('gas spreads, and settles')

    local settled = false
    local stepsToSettle = 0
    for i = 1, 4000 do
        field:step(STEP)
        stepsToSettle = i
        if field:activeCount() == 0 then settled = true break end
    end

    t.ok(settled, ('the field settles, in %d steps'):format(stepsToSettle))
    t.ok(field:densityAt(10, 10) < 5, 'the source tile gave gas away')
    t.ok(field:densityAt(11, 10) > 0, 'to the tile beside it')
    t.ok(field:densityAt(2, 2) > 0, 'and eventually all the way to the far corner')
    t.eq(field:densityAt(1, 1), 0, 'but never into the wall')

    ---------------------------------------------------------------------
    t.describe('A SETTLED FIELD DOES ZERO WORK')

    local visited, flows = field:step(STEP)
    t.eq(visited, 0, 'a settled field visits no cells at all')
    t.eq(flows, 0, 'and performs no exchanges')
    t.eq(field.visited, 0, 'and says so afterwards')

    -- Ten more, in case the first was a fluke of the wake bookkeeping.
    local totalVisited = 0
    for _ = 1, 10 do
        local v = field:step(STEP)
        totalVisited = totalVisited + v
    end
    t.eq(totalVisited, 0, 'ten more steps of a settled field cost nothing either')

    local occupied = field:occupiedCount()
    t.ok(occupied > 100, ('and it is not settled because it is empty: %d cells hold gas')
                         :format(occupied))

    ---------------------------------------------------------------------
    t.describe('COST SCALES WITH ACTIVITY, NOT WITH WORLD SIZE')

    -- The same disturbance, at the same offset from the same corner, in two
    -- worlds four times the area apart. Diffusion spreads one tile per step, so
    -- over eight steps the cloud cannot reach either world's wall and the two
    -- simulations are identical — which means any difference in cost is a
    -- difference that came from the world's SIZE, and that is the bug.
    local function costProfile(size)
        local box = Worldgen.box(size, size)
        local f = Gas.new{ world = box, rate = 2 }
        f:emit(6, 6, 100)

        local profile = {}
        for i = 1, 8 do
            local v, fl = f:step(STEP)
            profile[i] = { visited = v, flows = fl }
        end
        return profile, f
    end

    local small, smallField = costProfile(20)
    local large, largeField = costProfile(40)

    local sameCost, sameFlows = true, true
    local smallTotal, largeTotal = 0, 0
    for i = 1, 8 do
        if small[i].visited ~= large[i].visited then sameCost = false end
        if small[i].flows ~= large[i].flows then sameFlows = false end
        smallTotal = smallTotal + small[i].visited
        largeTotal = largeTotal + large[i].visited
    end

    t.ok(sameCost,
         ('the 20x20 and the 40x40 visit the same cells every step (%d vs %d total)')
         :format(smallTotal, largeTotal))
    t.ok(sameFlows, 'and perform the same number of exchanges')
    t.eq(smallTotal, largeTotal, 'so the totals are equal')

    -- And it is a real cost, not zero on both sides.
    t.ok(smallTotal > 0, ('and it is doing real work: %d cell visits'):format(smallTotal))

    -- The first step is the sharpest form of the claim: one disturbed cell and
    -- its four neighbours, in a world of four hundred cells and in a world of
    -- sixteen hundred, identically.
    t.eq(small[1].visited, 5, 'the first step visits the emitted cell and its neighbours')
    t.eq(large[1].visited, 5, 'in the 40x40 world too, not four times as many')

    -- The 40x40 has four times the cells. If cost tracked world size at all this
    -- would be four times the small world's number rather than the same one.
    t.ok(largeTotal < 40 * 40 / 2,
         ('%d visits over eight steps is a fraction of the 1600 cells it did NOT walk')
         :format(largeTotal))

    -- The clouds are also identical, which is what makes the cost comparison
    -- meaningful rather than a coincidence of two different simulations.
    t.near(smallField:densityAt(6, 6), largeField:densityAt(6, 6), 1e-12,
           'the two clouds are the same cloud')
    t.near(smallField:total(), largeField:total(), 1e-9, 'holding the same gas')

    ---------------------------------------------------------------------
    t.describe('CONSERVATION: with no decay, nothing is lost, ever')

    local sealed = Worldgen.box(24, 24)
    local keeper = Gas.new{ world = sealed, rate = 3, decay = 0 }
    keeper:emit(5, 5, 1000)
    keeper:emit(18, 18, 250)
    keeper:emit(5, 18, 37.5)

    local expectedTotal = 1287.5
    t.near(keeper:total(), expectedTotal, 1e-9, 'the field holds what was put in')
    t.near(keeper.emitted, expectedTotal, 1e-9, 'and the emission ledger agrees')

    local drift = 0
    for _ = 1, 600 do
        keeper:step(STEP)
        local d = math.abs(keeper:total() - expectedTotal)
        if d > drift then drift = d end
    end

    t.ok(drift < 1e-9,
         ('six hundred steps of diffusion drift the total by %g, which is float noise')
         :format(drift))
    t.near(keeper:total(), expectedTotal, 1e-9, 'so the total is exactly what it was')
    t.near(keeper:total() + keeper.lost, keeper.emitted, 1e-9,
           'and total + lost == emitted, which is the ledger this file exists to check')
    t.ok(math.abs(keeper.lost) < 1e-9, 'with nothing actually lost')

    -- No cell ever goes negative, which is how an unstable diffusion sim starts.
    local negative = false
    local overSource = false
    keeper:each(function(_, _, d)
        if d < 0 then negative = true end
        if d > 1000 + 1e-9 then overSource = true end
    end)
    t.ok(not negative, 'and no cell holds a negative amount')
    t.ok(not overSource, 'nor more than was ever put into one place')

    -- An absurd rate is clamped rather than allowed to oscillate.
    local violent = Gas.new{ world = Worldgen.box(12, 12), rate = 1e6 }
    violent:emit(6, 6, 100)
    local wentNegative = false
    for _ = 1, 200 do
        violent:step(STEP)
        violent:each(function(_, _, d) if d < 0 then wentNegative = true end end)
    end
    t.ok(not wentNegative, 'a rate of a million is clamped, not allowed to explode')
    t.near(violent:total(), 100, 1e-9, 'and it still conserves')

    ---------------------------------------------------------------------
    t.describe('DECAY: the rate is exact, and every scrap taken is booked')

    -- A one-tile pocket walled in on every side: no neighbour to diffuse to, so
    -- the only thing that can change the number is decay, and the arithmetic is
    -- checkable by hand.
    local grid = {}
    for y = 1, 5 do
        grid[y] = {}
        for x = 1, 5 do grid[y][x] = 1 end
    end
    grid[3][3] = World.EMPTY
    local pocket = World.new(grid)

    local burning = Gas.new{ world = pocket, rate = 1, decay = 0.5, minimum = 0 }
    burning:emit(3, 3, 100)

    local expected = 100
    local exact = true
    for _ = 1, 30 do
        burning:step(STEP)
        expected = expected * (1 - 0.5 * STEP)
        if math.abs(burning:densityAt(3, 3) - expected) > 1e-9 then exact = false end
    end

    t.ok(exact, 'a decaying cell holds exactly d * (1 - decay*dt) after every step')
    t.near(burning:densityAt(3, 3), expected, 1e-9, 'and lands on the stated value')
    t.near(burning:total() + burning.lost, burning.emitted, 1e-9,
           'with total + lost == emitted the whole way down')
    t.ok(burning.lost > 0, 'and lost is where the decayed gas actually went')
    t.near(burning.lost, 100 - expected, 1e-9, 'to the last unit')

    -- A decaying field does keep working while it has gas to decay, which is
    -- correct: the gas IS still changing. It stops when there is none left.
    t.ok(burning:activeCount() > 0, 'a decaying field stays awake while it holds gas')

    local burnOut = Gas.new{ world = pocket, rate = 1, decay = 4, minimum = 1e-3 }
    burnOut:emit(3, 3, 10)
    local gone = false
    for _ = 1, 4000 do
        burnOut:step(STEP)
        if burnOut:activeCount() == 0 then gone = true break end
    end
    t.ok(gone, 'and once it has burnt out it settles, doing zero work again')
    t.eq(burnOut:step(STEP), 0, 'literally zero')
    t.near(burnOut:total() + burnOut.lost, burnOut.emitted, 1e-9,
           'and the ledger balances even after the culling')
    t.ok(burnOut:total() < 1e-3, 'with nothing meaningful left')

    ---------------------------------------------------------------------
    t.describe('GAS DOES NOT LEAK THROUGH A CLOSED DOOR')

    -- Two rooms, one door. The room divider is solid except for the door tile.
    local rooms = {}
    for y = 1, 11 do
        rooms[y] = {}
        for x = 1, 11 do
            local border = (x == 1 or y == 1 or x == 11 or y == 11)
            rooms[y][x] = (border or x == 6) and 1 or World.EMPTY
        end
    end
    local twoRooms = World.new(rooms)
    twoRooms:addDoor(6, 5, false)

    local air = Gas.new{ world = twoRooms, rate = 15, decay = 0 }
    air:emit(3, 5, 500)

    local shutSteps = settle(air)
    t.ok(shutSteps ~= nil,
         ('the field settled with the door shut, in %s steps'):format(tostring(shutSteps)))

    local left, right = 0, 0
    air:each(function(tx, _, d)
        if tx < 6 then left = left + d elseif tx > 6 then right = right + d end
    end)

    t.near(left, 500, 1e-9, 'all the gas is still in the room it was released in')
    t.eq(right, 0, 'AND EXACTLY ZERO reached the other side of the shut door')
    t.eq(air:densityAt(6, 5), 0, 'not even the door tile itself has any')
    t.near(air:total(), 500, 1e-9, 'and none of it was lost in the process')
    t.eq(air:activeCount(), 0, 'and it is doing no work at all while sealed')
    t.eq(air:step(STEP), 0, 'literally none')

    -- Opening the door changes nothing until someone says so. This is the price
    -- of sleeping and it is a documented contract, so it is a documented test.
    twoRooms:setDoorOpen(6, 5, true)
    for _ = 1, 60 do air:step(STEP) end
    t.eq(air:densityAt(7, 5), 0,
         'opening a door does not wake a settled field by itself: both sides are '
         .. 'asleep and nothing about EITHER of them changed')

    t.ok(air:wake(6, 5) > 0, 'so the caller tells it, which is the documented contract')
    t.ok(settle(air) ~= nil, 'and it settles again once the two rooms have equalised')

    local rightAfter = 0
    air:each(function(tx, _, d) if tx > 6 then rightAfter = rightAfter + d end end)
    t.ok(rightAfter > 0, 'and now the gas comes through')
    t.ok(rightAfter > 200, ('half of it, near enough: %.1f units'):format(rightAfter))
    t.near(air:total(), 500, 1e-9, 'still conserving every unit of it')

    -- And shutting the door again traps what is on each side.
    twoRooms:setDoorOpen(6, 5, false)
    air:wake(6, 5)
    settle(air)
    local sealedRight = 0
    air:each(function(tx, _, d) if tx > 6 then sealedRight = sealedRight + d end end)
    t.ok(math.abs(sealedRight - rightAfter) < 60,
         'shutting it again keeps roughly what was on each side')
    t.near(air:total(), 500, 1e-9, 'and conservation holds through all of it')

    ---------------------------------------------------------------------
    t.describe('emitting a cloud over an area')

    local blastWorld = Worldgen.box(20, 20)
    local cloud = Gas.new{ world = blastWorld, rate = 1 }
    local injected = cloud:emitCircle(10.0, 10.0, 3, 60)
    t.near(injected, 60, 1e-9, 'the whole charge is injected')
    t.near(cloud:total(), 60, 1e-9, 'and is all there')
    t.ok(cloud:densityAt(10, 10) > cloud:densityAt(12, 10),
         'thickest at the centre')
    t.eq(cloud:densityAt(1, 1), 0, 'and never in a wall')

    -- Line of sight: a charge on one side of a wall does not seed the far side.
    local walled = Gas.new{ world = twoRooms, rate = 1 }
    walled:emitCircle(3.5, 5.5, 4, 100)
    local across = 0
    walled:each(function(tx, _, d) if tx > 6 then across = across + d end end)
    t.eq(across, 0, 'and an area emission does not seed through a wall either')

    ---------------------------------------------------------------------
    t.describe('gas damage arrives as an effect')

    Effects.define('fireproof', {
        duration = 'infinite',
        incoming = { { tag = 'damage.type.fire', magnitude = 0.2 } },
    })

    local function dummy(x, y)
        local e = Entity.new{ kind = 'dummy', x = x, y = y }
        e:add(C.Health{ hp = 1000, max = 1000 })
        Game.attach(e, { authority = true })
        return e
    end

    local fireWorld = Worldgen.box(20, 20)
    local fire = Gas.new{ world = fireWorld, rate = 0, decay = 0 }
    fire:emit(10, 10, 1)
    fire:emit(12, 10, 1)

    local burnt   = dummy(9.5, 9.5)      -- tile 10,10
    local warded  = dummy(11.5, 9.5)     -- tile 12,10
    local outside = dummy(5.5, 5.5)      -- no gas
    Effects.apply(warded, 'fireproof')

    local hits, n = Gas.damage(fire, { burnt, warded, outside }, STEP, {
        amount = 60, tags = { 'damage.type.fire' },
    })

    t.eq(n, 2, 'only the two standing in gas are affected')
    t.eq(#hits, 2, 'and both are reported')
    t.near(1000 - Attributes.get(burnt, 'health'), 60 * STEP, 1e-9,
           'the unprotected one takes amount * density * dt')
    t.near(1000 - Attributes.get(warded, 'health'), 60 * STEP * 0.2, 1e-9,
           'and the warded one a fifth, because gas damage is an effect too')
    t.eq(Attributes.get(outside, 'health'), 1000, 'and the one in clean air takes nothing')

    -- Density scales it: half as much gas, half the damage.
    local thin = Gas.new{ world = fireWorld, rate = 0 }
    thin:emit(10, 10, 0.5)
    local half = dummy(9.5, 9.5)
    Gas.damage(thin, { half }, STEP, { amount = 60, tags = { 'damage.type.fire' } })
    t.near(1000 - Attributes.get(half, 'health'), 30 * STEP, 1e-9,
           'half the density does half the damage')

    -- minDensity is a threshold, so a wisp is not lethal.
    local wisp = Gas.new{ world = fireWorld, rate = 0 }
    wisp:emit(10, 10, 0.01)
    local safe = dummy(9.5, 9.5)
    local _, count = Gas.damage(wisp, { safe }, STEP,
                                { amount = 60, minDensity = 0.1 })
    t.eq(count, 0, 'a density below the threshold hurts nobody')
    t.eq(Attributes.get(safe, 'health'), 1000, 'and takes nothing off')

    t.eq(select(2, Gas.damage(fire, { burnt }, 0 / 0, { amount = 10 })), 0,
         'a NaN step does nothing')
    t.eq(select(2, Gas.damage(fire, { burnt }, STEP, { amount = 0 })), 0,
         'and neither does an amount of zero')

    ---------------------------------------------------------------------
    t.describe('a field can be saved and restored')

    local source = Gas.new{ world = sealed, rate = 2 }
    source:emit(4, 4, 40)
    source:emit(9, 9, 12.5)
    for _ = 1, 30 do source:step(STEP) end

    local snap = source:snapshot()
    t.ok(snap ~= nil and #snap.cells > 0, 'a snapshot carries the occupied cells')

    local restored = Gas.new{ world = sealed, rate = 2 }
    t.ok(restored:applySnapshot(snap), 'and applies to a fresh field')
    t.near(restored:total(), source:total(), 1e-12, 'with the same total')
    t.near(restored:densityAt(4, 4), source:densityAt(4, 4), 1e-12,
           'and the same cells')
    t.ok(restored:activeCount() > 0, 'and it wakes up ready to keep spreading')

    local wrongSize = Gas.new{ world = Worldgen.box(10, 10), rate = 2 }
    local ok, sizeWhy = wrongSize:applySnapshot(snap)
    t.ok(not ok, 'a snapshot from a differently-sized world is refused')
    t.ok(sizeWhy and sizeWhy:find('wide'), 'rather than scattered across the wrong tiles',
         sizeWhy)

    t.ok(not restored:applySnapshot('nonsense'), 'and so is a non-table')

    ---------------------------------------------------------------------
    t.describe('housekeeping')

    local temp = Gas.new{ world = sealed, rate = 1 }
    temp:emit(5, 5, 20)
    t.eq(temp:step(0 / 0), 0, 'a NaN step does nothing')
    t.eq(temp:step(-1), 0, 'and neither does a negative one')
    t.near(temp:densityAt(5, 5), 20, 1e-12, 'the gas is untouched by either')

    temp:set(5, 5, 3)
    t.near(temp:densityAt(5, 5), 3, 1e-12, 'set writes an absolute value')
    t.near(temp:total() + temp.lost, temp.emitted, 1e-9, 'and books the difference')

    t.eq(temp:set(1, 1, 5), 0, 'setting gas inside a wall is refused')

    local before = temp:total()
    local lostBefore = temp.lost
    temp:clear()
    t.eq(temp:total(), 0, 'clear empties it')
    t.eq(temp:activeCount(), 0, 'and settles it')
    t.near(temp.lost - lostBefore, before, 1e-9,
           'booking exactly what it threw away, rather than losing it quietly')
    t.near(temp:total() + temp.lost, temp.emitted, 1e-9,
           'so the ledger still balances after a clear')

    local tx, ty = temp:tileOf(temp:index(7, 9))
    t.eq(tx, 7, 'index and tileOf are inverses')
    t.eq(ty, 9, 'in both coordinates')

    Game.reset()
    Entity.clearArchetypes()
end
