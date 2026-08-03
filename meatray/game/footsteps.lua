--[[
    meatray.game.footsteps — when a step lands, and on what (C30).

    A footstep is two questions: HOW OFTEN (you take a step every stride-length of
    travel, faster when you run) and ON WHAT (stone rings, water splashes, metal
    clangs). This model answers both and stops there — it emits a step with a
    material, and the game plays whatever sound it has for that material. It owns
    no audio: the actual splashes and clangs are the game's content, exactly like
    i18n owns no strings.

        local Footsteps = require('meatray.game.footsteps')
        local steps = Footsteps.new{ stride = 1.6 }

        -- each tick, per entity that moved:
        local step = steps:advance(e, moved, function(tx, ty, storey)
            return world:surfaceAt(tx, ty, storey)    -- the material resolver
        end)
        if step then playSound('footstep.' .. step.material, step.x, step.y) end

    `advance` accumulates the distance an entity travelled and returns a step
    only on the tick a stride completes (carrying the remainder, so a long dt
    does not lose or double a step). The step names its material and the world
    position it landed at, so the game can play it positionally.

    The material RESOLVER is injected — the model does not know what a tile is
    made of, the same way the AI's hearing does not know what an inventory is.
    A resolver that returns nil falls back to the default material, so an
    untagged floor still footsteps.

    Deterministic: distance in, steps out. No clock, no rng. A recorded demo
    reproduces the same steps.

    HEADLESS: pure Lua.
]]

local Footsteps = {}
local FootMT = {}
FootMT.__index = FootMT

local floor = math.floor

-- opts.stride    tiles of travel per step (default 1.6)
-- opts.default   material name when the resolver returns nil (default 'stone')
-- opts.runScale  a step lands sooner when moving fast; multiply the accumulated
--                distance by this when opts.running is passed (default 1.0 = off)
function Footsteps.new(opts)
    opts = opts or {}
    return setmetatable({
        stride  = math.max(0.1, tonumber(opts.stride) or 1.6),
        default = tostring(opts.default or 'stone'),
        walked  = {},     -- [entityKey] = distance since last step
    }, FootMT)
end

local function keyOf(e)
    return e.id or e
end

-- The material under an entity's feet, via the resolver, with the default as a
-- floor. `resolver(tx, ty, storey)` returns a material name or nil.
function FootMT:materialUnder(e, resolver)
    local tx, ty = floor(e.x) + 1, floor(e.y) + 1
    local m = resolver and resolver(tx, ty, e.storey or 1)
    return (m and m ~= '') and tostring(m) or self.default
end

-- Feed the distance an entity moved this tick. Returns a step table
-- { material, x, y, storey } on the tick a stride completes, else nil. A step
-- that just landed carries the leftover distance into the next stride.
function FootMT:advance(e, moved, resolver)
    if not e then return nil end
    moved = math.max(0, tonumber(moved) or 0)
    local k = keyOf(e)
    local d = (self.walked[k] or 0) + moved
    if d < self.stride then
        self.walked[k] = d
        return nil
    end
    -- One step per call: even a huge dt makes a single footstep, not a machine-
    -- gun of them. Keep the remainder within one stride so cadence stays steady.
    self.walked[k] = d - self.stride
    if self.walked[k] > self.stride then self.walked[k] = self.walked[k] % self.stride end
    return {
        material = self:materialUnder(e, resolver),
        x = e.x, y = e.y, storey = e.storey or 1,
    }
end

-- Convenience: distance from an entity's previous position, for callers that
-- track (prevX, prevY) rather than a velocity.
function FootMT:advanceFromMove(e, prevX, prevY, resolver)
    local dx, dy = (e.x - (prevX or e.x)), (e.y - (prevY or e.y))
    return self:advance(e, math.sqrt(dx * dx + dy * dy), resolver)
end

-- Forget an entity (died, left) so its accumulator does not leak.
function FootMT:forget(e)
    if e then self.walked[keyOf(e)] = nil end
end

function FootMT:reset()
    self.walked = {}
end

return Footsteps
