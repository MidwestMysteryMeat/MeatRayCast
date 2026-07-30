--[[
    The fixed-timestep clock. The catch-up cap is the interesting case: without
    it a stalled process comes back to a huge dt and tries to simulate every
    missed step in one frame, which makes the stall worse rather than better.
]]

return function(t)
    local Tick = require('meatray.sim.tick')

    t.describe('rate and step')
    local clock = Tick.new(60)
    t.eq(clock.rate, 60, 'rate is kept')
    t.ok(math.abs(clock.step - 1/60) < 1e-12, 'step is the reciprocal of the rate')

    t.describe('whole steps only')
    local ran = 0
    local alpha = clock:advance(1/60, function() ran = ran + 1 end)
    t.eq(ran, 1, 'exactly one step for exactly one step of time')
    t.ok(alpha < 1e-9, 'nothing left over')

    ran = 0
    clock:advance(1/120, function() ran = ran + 1 end)
    t.eq(ran, 0, 'half a step runs nothing')
    t.ok(math.abs(clock:alpha() - 0.5) < 1e-9, 'and leaves alpha at half')

    ran = 0
    clock:advance(1/120, function() ran = ran + 1 end)
    t.eq(ran, 1, 'the second half completes the step')

    t.describe('the step passed to the callback is always fixed')
    local seen = {}
    local c2 = Tick.new(50)
    c2:advance(3 / 50 + 0.001, function(step) seen[#seen + 1] = step end)
    t.eq(#seen, 3, 'three whole steps ran')
    t.eq(seen[1], seen[3], 'every step is identical')
    t.ok(math.abs(seen[1] - 1/50) < 1e-12, 'and equals 1/rate regardless of dt')

    t.describe('catch-up is capped rather than unbounded')
    local c3 = Tick.new(60, 3)
    local count = 0
    c3:advance(1.0, function() count = count + 1 end)  -- 60 steps' worth
    t.eq(count, 3, 'no more than maxCatchUp steps in one advance')
    t.ok(c3.droppedTicks > 0, 'the dropped time is reported, not hidden')
    t.ok(c3:alpha() < 1, 'and the accumulator is left sane')

    t.describe('tick count and derived time')
    local c4 = Tick.new(60)
    for _ = 1, 60 do c4:advance(1/60, function() end) end
    t.eq(c4.tickCount, 60, 'ticks are counted')
    t.ok(math.abs(c4:time() - 1.0) < 1e-9, 'time derives from whole ticks')

    -- Simulation time must not drift with framerate: the same elapsed wall time
    -- fed in different-sized chunks must produce the same tick count. This is
    -- the property that makes host and client agree.
    t.describe('tick count is framerate-independent')
    local steady, spiky = Tick.new(60), Tick.new(60)
    for _ = 1, 120 do steady:advance(1/120, function() end) end       -- 120 fps
    for _ = 1, 20 do spiky:advance(1/20, function() end) end          -- 20 fps
    t.eq(steady.tickCount, spiky.tickCount,
         'one second of time is 60 ticks whatever the frame size')

    t.describe('reset')
    local c5 = Tick.new(60)
    c5:advance(0.5, function() end)
    c5:reset()
    t.eq(c5.tickCount, 0, 'reset clears the tick count')
    t.eq(c5:alpha(), 0, 'and the accumulator')

    t.describe('advance works with no callback')
    local c6 = Tick.new(60)
    local ok = pcall(function() c6:advance(1/60) end)
    t.ok(ok, 'a missing callback is not an error')
    t.eq(c6.tickCount, 1, 'and the tick still counts')
end
