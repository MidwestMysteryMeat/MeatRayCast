--[[
    meatray.game.screenfx — timed full-screen tints, layered (C28).

    The HUD's damage flash reads hit points and lives in meatray.game.hud. This
    is the general library beneath that idea: a stack of full-screen effects
    anything can push — a flashbang's white-out, the blue wash of standing in
    water, a green pickup blip, a red pulse while in lava — each with its own
    colour, its own fade timeline, and its own style (a flat fill or an edge
    vignette). A renderer reads the layers and blits them; nothing is drawn
    here, the same split every other model keeps.

        local ScreenFX = require('meatray.game.screenfx')
        local fx = ScreenFX.new()

        fx:flash({ 1, 1, 1 }, { peak = 0.9, hold = 0.1, out = 1.2 })  -- flashbang
        fx:flash({ 0.3, 0.9, 0.4 }, { peak = 0.25, out = 0.4 })       -- pickup blip

        fx:hold('water', { 0.2, 0.4, 0.8 }, { peak = 0.35, style = 'fill' })
        ...  fx:release('water')       -- when the player leaves the water

        fx:update(dt)                  -- real time; this is presentation
        for _, layer in ipairs(fx:layers()) do
            drawFullscreen(layer.color, layer.alpha, layer.style)
        end

    Two kinds of effect, because they end differently:

      * a FLASH is fire-and-forget: it ramps in, holds, fades out on its own
        timeline and is gone. A flashbang, a hit blip, a teleport wash.
      * a HOLD is a condition tint: it ramps in and STAYS at its peak until
        released, then fades. Underwater, in lava, low health. A hold has an
        id so re-asserting it every tick (which is how "am I still in the
        water" reads) does not stack a hundred copies — the same id updates
        the one layer.

    Layers are independent and additive: a green pickup blip over a blue water
    tint is both, and the renderer decides how they combine. There is a cap, so
    a machine gun of flashes cannot grow the stack without bound.

    HEADLESS: pure Lua. The caller hands in dt.
]]

local ScreenFX = {}
local FXMT = {}
FXMT.__index = FXMT

ScreenFX.MAX_LAYERS = 16

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function ScreenFX.new(opts)
    opts = opts or {}
    return setmetatable({
        flashes = {},          -- fire-and-forget effects
        holds = {},            -- [id] = condition tint
        maxFlashes = opts.max or ScreenFX.MAX_LAYERS,
    }, FXMT)
end

---------------------------------------------------------------------------
-- Flash: ramp in, hold, fade out, gone
---------------------------------------------------------------------------

-- opts: peak (max alpha, default 0.5), inTime (ramp-up seconds, default 0.05),
--       hold (seconds at peak, default 0), out (fade-out seconds, default 0.4),
--       style ('fill' | 'vignette', default 'fill'), priority (see below).
function FXMT:flash(color, opts)
    opts = opts or {}
    color = color or { 1, 1, 1 }
    local f = {
        color = { color[1] or 1, color[2] or 1, color[3] or 1 },
        peak = tonumber(opts.peak) or 0.5,
        inTime = math.max(0, tonumber(opts.inTime) or 0.05),
        hold = math.max(0, tonumber(opts.hold) or 0),
        out = math.max(0.01, tonumber(opts.out) or 0.4),
        style = opts.style == 'vignette' and 'vignette' or 'fill',
        t = 0,          -- elapsed
        priority = tonumber(opts.priority) or 1,
    }
    f.total = f.inTime + f.hold + f.out
    self.flashes[#self.flashes + 1] = f

    -- Cap: drop the lowest-priority, then oldest, so a burst of little blips
    -- never buries a big white-out that matters.
    while #self.flashes > self.maxFlashes do
        local worst, worstI = nil, 1
        for i = 1, #self.flashes do
            local fl = self.flashes[i]
            if not worst or fl.priority < worst.priority then worst, worstI = fl, i end
        end
        table.remove(self.flashes, worstI)
    end
    return f
end

---------------------------------------------------------------------------
-- Hold: a condition tint, up until released
---------------------------------------------------------------------------

-- Asserts (or refreshes) a held tint under `id`. Calling it every tick while a
-- condition is true is the intended use — the id keeps it one layer. opts as
-- flash, minus hold (a hold holds until released).
function FXMT:hold(id, color, opts)
    id = tostring(id)
    opts = opts or {}
    color = color or { 1, 1, 1 }
    local h = self.holds[id]
    if not h then
        h = { t = 0, releasing = false }
        self.holds[id] = h
    end
    h.color = { color[1] or 1, color[2] or 1, color[3] or 1 }
    h.peak = tonumber(opts.peak) or 0.35
    h.inTime = math.max(0, tonumber(opts.inTime) or 0.15)
    h.out = math.max(0.01, tonumber(opts.out) or 0.4)
    h.style = opts.style == 'vignette' and 'vignette' or 'fill'
    h.releasing = false          -- re-asserting cancels a pending fade
    return h
end

-- Starts a held tint fading out. It lingers for its `out` seconds, then goes.
function FXMT:release(id)
    local h = self.holds[tostring(id)]
    if h and not h.releasing then
        h.releasing = true
        h.releaseAt = h.t
        -- Fade from wherever the ramp-in got to, not always from full.
        h.releaseAlpha = h.inTime > 0 and math.min(1, h.t / h.inTime) or 1
    end
end

function FXMT:isHeld(id)
    local h = self.holds[tostring(id)]
    return h ~= nil and not h.releasing
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

function FXMT:update(dt)
    dt = math.max(0, tonumber(dt) or 0)

    for i = #self.flashes, 1, -1 do
        local f = self.flashes[i]
        f.t = f.t + dt
        if f.t >= f.total then table.remove(self.flashes, i) end
    end

    for id, h in pairs(self.holds) do
        h.t = h.t + dt
        if h.releasing and (h.t - h.releaseAt) >= h.out then
            self.holds[id] = nil
        end
    end
end

function FXMT:clear()
    self.flashes = {}
    self.holds = {}
end

---------------------------------------------------------------------------
-- Draw-ready layers
---------------------------------------------------------------------------

local function flashAlpha(f)
    if f.t < f.inTime then
        return f.peak * (f.inTime > 0 and (f.t / f.inTime) or 1)
    end
    if f.t < f.inTime + f.hold then
        return f.peak
    end
    local into = f.t - f.inTime - f.hold
    return f.peak * math.max(0, 1 - into / f.out)
end

local function holdAlpha(h)
    if h.releasing then
        -- Fade from where the ramp-in had reached (releaseAlpha, 0..1) down to
        -- nothing over `out` seconds.
        local into = h.t - h.releaseAt
        return h.peak * (h.releaseAlpha or 1) * math.max(0, 1 - into / h.out)
    end
    -- Ramping in, then flat at peak.
    if h.inTime > 0 and h.t < h.inTime then
        return h.peak * (h.t / h.inTime)
    end
    return h.peak
end

-- Every visible layer right now: { color = {r,g,b}, alpha, style }. Holds
-- first (they are the backdrop a flash pops over), then flashes oldest-first.
function FXMT:layers()
    local out = {}
    -- Stable id order so a two-hold frame draws the same way twice.
    local ids = {}
    for id in pairs(self.holds) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local h = self.holds[id]
        local a = holdAlpha(h)
        if a > 0.001 then
            out[#out + 1] = { color = h.color, alpha = a, style = h.style, id = id }
        end
    end
    for i = 1, #self.flashes do
        local a = flashAlpha(self.flashes[i])
        if a > 0.001 then
            out[#out + 1] = { color = self.flashes[i].color, alpha = a,
                              style = self.flashes[i].style }
        end
    end
    return out
end

function FXMT:count()
    return #self.flashes, self:holdCount()
end

function FXMT:holdCount()
    local n = 0
    for _ in pairs(self.holds) do n = n + 1 end
    return n
end

return ScreenFX
