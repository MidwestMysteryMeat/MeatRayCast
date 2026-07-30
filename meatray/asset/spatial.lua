--[[
    meatray.asset.spatial — distance to volume, and bearing to stereo pan.

    Positional sound in a raycaster is two numbers: how loud, and how far to one
    side. Both are pure arithmetic over the listener's position and facing, and
    both have a characteristic bug that is silent rather than visible — a rolloff
    that never reaches zero leaves every sound in the level audible at once, and a
    pan with the wrong sign puts the monster on your left when it is on your right.
    Neither shows up in a screenshot. So the maths lives here and is asserted.

    The pan sign follows the renderer's own camera plane, which is the only
    definition of "right" this engine has. `meatray.render.raycaster` builds the
    plane as (-dirY, dirX), so a point is to the viewer's right when the 2D cross
    product `dir x delta` is positive — the same quantity that puts a sprite on the
    right of the screen. Deriving pan from anything else would let audio and video
    disagree about which side something is on.

    HEADLESS: no love.* anywhere in this file.
]]

local Spatial = {}

local cos, sin, sqrt = math.cos, math.sin, math.sqrt
local max, min = math.max, math.min

-- Sensible for a game whose world unit is one tile: full volume within a tile,
-- inaudible about two rooms away.
Spatial.DEFAULTS = {
    ref = 1.0,          -- within this distance, full volume
    max = 24.0,         -- at or beyond this distance, silent
    rolloff = 1.0,      -- how sharply it falls between the two
    curve = 'inverse',  -- 'inverse' or 'linear'
    panWidth = 1.0,     -- 0 disables panning entirely
}

local function opt(opts, key)
    local v = opts and opts[key]
    if v == nil then return Spatial.DEFAULTS[key] end
    return v
end

---------------------------------------------------------------------------
-- Distance -> volume
---------------------------------------------------------------------------

-- Volume in 0..1 for a source `dist` away.
--
-- Reaching exactly zero at `max` is the load-bearing property. An inverse-square
-- curve approaches zero without arriving, so every sound ever started stays
-- faintly mixed forever; scaling it to hit zero at the cutoff means distant
-- sources cost nothing and can be skipped outright.
function Spatial.volume(dist, opts)
    local ref = max(0, opt(opts, 'ref'))
    local far = opt(opts, 'max')
    local rolloff = max(0, opt(opts, 'rolloff'))
    local curve = opt(opts, 'curve')

    dist = max(0, tonumber(dist) or 0)

    if far <= ref then
        -- A degenerate range: audible inside the reference distance, silent
        -- outside it. Better than dividing by zero and returning NaN, which
        -- reaches OpenAL as an invalid gain and silences everything.
        return dist <= ref and 1 or 0
    end

    if dist <= ref then return 1 end
    if dist >= far then return 0 end

    local v
    if curve == 'linear' then
        v = (far - dist) / (far - ref)
    else
        -- Inverse rolloff, then faded to nothing across the whole range so the
        -- cutoff at `max` is not an audible step.
        v = ref / (ref + rolloff * (dist - ref))
        local taper = (far - dist) / (far - ref)
        v = v * taper
    end

    return max(0, min(1, v))
end

function Spatial.audible(dist, opts)
    return Spatial.volume(dist, opts) > 0
end

---------------------------------------------------------------------------
-- Bearing -> pan
---------------------------------------------------------------------------

function Spatial.distance(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return sqrt(dx * dx + dy * dy)
end

-- Stereo pan in -1..1: -1 hard left, 0 centre, +1 hard right.
--
-- `angle` is the listener's facing, in the engine's convention (0 = +x, y grows
-- downward). Directly ahead and directly behind both give 0, which is honest:
-- two speakers cannot express front from back, and faking it with a pan that
-- flips at the halfway point makes a source walking past you snap sides.
function Spatial.pan(listenerX, listenerY, angle, sourceX, sourceY, opts)
    local dx, dy = sourceX - listenerX, sourceY - listenerY
    local len = sqrt(dx * dx + dy * dy)
    if len <= 1e-6 then return 0 end

    local dirX, dirY = cos(angle), sin(angle)

    -- 2D cross product of facing and the direction to the source: positive means
    -- the source is on the side the camera plane points to, i.e. screen right.
    local rightness = (dirX * dy - dirY * dx) / len

    local width = opt(opts, 'panWidth')
    return max(-1, min(1, rightness * width))
end

---------------------------------------------------------------------------
-- Both at once
---------------------------------------------------------------------------

-- The single call playback wants: given a listener {x, y, angle} and a source
-- position, how loud and how far to the side.
--
-- Returns volume, pan, distance. A nil listener means "no listener yet", which
-- plays flat and centred rather than erroring — a sound triggered during loading
-- should be quietly unremarkable, not fatal.
function Spatial.mix(listener, sourceX, sourceY, opts)
    if not listener then return 1, 0, 0 end

    local lx, ly = listener.x or 0, listener.y or 0
    local dist = Spatial.distance(lx, ly, sourceX, sourceY)

    return Spatial.volume(dist, opts),
           Spatial.pan(lx, ly, listener.angle or 0, sourceX, sourceY, opts),
           dist
end

-- The unit vector OpenAL wants for a relative mono source, derived from a pan.
-- Kept here so the geometry is tested even though only the LÖVE side calls it:
-- the listener sits at the origin looking down -z, so a pan of +1 is (1, 0, 0)
-- and a pan of 0 is straight ahead at (0, 0, -1).
function Spatial.toEar(pan)
    pan = max(-1, min(1, tonumber(pan) or 0))
    return pan, 0, -sqrt(max(0, 1 - pan * pan))
end

return Spatial
