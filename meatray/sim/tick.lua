--[[
    meatray.sim.tick — fixed-timestep accumulator.

    The simulation advances in fixed steps; rendering happens whenever it
    happens and interpolates between the last two steps. This is a requirement
    for networking (host and client must agree on what a tick is) and it removes
    a whole class of bug: physics written against a variable frame delta drifts
    with framerate, and a constant applied per frame instead of per tick is off
    by however many frames a second the machine happens to manage.

    Usage:
        local clock = Tick.new(60)                  -- 60 Hz simulation
        local alpha = clock:advance(dt, function(step)
            world:update(step)
            updateEntities(step)
        end)
        render(alpha)                               -- alpha is 0..1

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Tick = {}

local TickMT = {}
TickMT.__index = TickMT

-- `rate` is simulation steps per second. `maxCatchUp` caps how many steps a
-- single advance() may run: without it, a machine that stalls (a breakpoint, a
-- dragged window, a long asset load) returns to a huge dt and tries to simulate
-- every missed step at once, which stalls it further. Dropping time is the
-- lesser evil, so the clock reports it instead of hiding it.
function Tick.new(rate, maxCatchUp)
    rate = rate or 60
    assert(rate > 0, 'tick rate must be positive')

    return setmetatable({
        rate = rate,
        step = 1 / rate,
        accumulator = 0,
        tickCount = 0,
        maxCatchUp = maxCatchUp or 5,
        droppedTicks = 0,
    }, TickMT)
end

-- Feeds real elapsed time in and runs `fn(step)` once per whole simulation step.
-- Returns the interpolation alpha for the renderer: how far the current moment
-- sits between the tick just run and the next one.
function TickMT:advance(dt, fn)
    self.accumulator = self.accumulator + dt

    local ran = 0
    while self.accumulator >= self.step do
        if ran >= self.maxCatchUp then
            -- Give up on the backlog rather than spiralling.
            local lost = math.floor(self.accumulator / self.step)
            self.droppedTicks = self.droppedTicks + lost
            self.accumulator = self.accumulator - lost * self.step
            break
        end

        self.accumulator = self.accumulator - self.step
        self.tickCount = self.tickCount + 1
        ran = ran + 1
        if fn then fn(self.step) end
    end

    return self.accumulator / self.step, ran
end

function TickMT:alpha()
    return self.accumulator / self.step
end

function TickMT:reset()
    self.accumulator = 0
    self.tickCount = 0
    self.droppedTicks = 0
    return self
end

-- Simulation time in seconds, derived from whole ticks only. Anything that must
-- match across the network reads this rather than a wall clock.
function TickMT:time()
    return self.tickCount * self.step
end

return Tick
