--[[
    meatray.sim.billboard — the maths behind sprite projection.

    This is deliberately separate from meatray.render.sprites: picking which
    angle bucket a sprite shows, and where on screen it lands, is arithmetic that
    wants unit tests. Drawing it is not. Splitting them means the fiddly part —
    the part where an off-by-one silently shows an enemy's back while it charges
    you — is verified without a window.

    Angle buckets: `angles = 1` means one image that always faces the viewer;
    `angles = 8` means Doom-style, bucket 0 facing the viewer and bucket 4
    facing away. Nothing here hard-codes 8.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Billboard = {}

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local floor, pi, cos, sin = math.floor, math.pi, math.cos, math.sin

local TWO_PI = pi * 2

-- Normalises any angle into [0, 2pi).
function Billboard.normalize(a)
    a = a % TWO_PI
    if a < 0 then a = a + TWO_PI end
    return a
end

-- Which sprite row to draw, given where the entity is facing and where it is
-- being viewed from. Returns a 0-based bucket index.
--
-- The relative angle is the entity's facing minus the direction from the entity
-- to the viewer, so bucket 0 is "looking straight at me". Half a bucket is added
-- before flooring so each bucket is centred on its ideal angle rather than
-- starting at it — without that, a sprite facing you exactly would sit on the
-- boundary and flicker between two rows.
function Billboard.angleBucket(entityAngle, viewerToEntityAngle, angles)
    angles = angles or 1
    if angles <= 1 then return 0 end

    local relative = Billboard.normalize(entityAngle - viewerToEntityAngle + pi)
    local bucket = floor(relative / TWO_PI * angles + 0.5) % angles

    return bucket
end

-- The angle from (fromX, fromY) toward (toX, toY).
function Billboard.bearing(fromX, fromY, toX, toY)
    return atan2(toY - fromY, toX - fromX)
end

-- Which animation frame is showing, given elapsed time. Returns a 0-based index.
-- Frame timing is intentionally derived from a clock rather than stored on the
-- entity: it is presentation state, so it never needs to cross the network.
function Billboard.animFrame(time, frames, fps)
    if not frames or frames <= 1 then return 0 end
    return floor(time * (fps or 8)) % frames
end

-- Projects a world position into the raycaster's view space.
--
-- Returns nil when the sprite is behind the camera or exactly on it. Otherwise
-- returns transformX and transformY, where transformY is depth along the view
-- direction (comparable against the z-buffer) and transformX is lateral offset.
--
-- This is the standard inverse-camera-matrix step: with the camera described by
-- a direction vector and a plane vector, the inverse of [plane | dir] maps a
-- relative world offset into that space.
function Billboard.project(spriteX, spriteY, camX, camY, dirX, dirY, planeX, planeY)
    local relX = spriteX - camX
    local relY = spriteY - camY

    local invDet = planeX * dirY - dirX * planeY
    if invDet == 0 then return nil end
    invDet = 1 / invDet

    local transformX = invDet * (dirY * relX - dirX * relY)
    local transformY = invDet * (-planeY * relX + planeX * relY)

    if transformY <= 0.0001 then return nil end

    return transformX, transformY
end

-- Where a projected sprite lands on screen and how big it is.
--
-- `anchor` is 'feet' (default) so a sprite stands on the floor plane, or
-- 'center' so it hangs at eye level — the difference between a monster and a
-- floating pickup.
function Billboard.screenRect(transformX, transformY, screenW, screenH, opts)
    opts = opts or {}
    local scale = opts.scale or 1
    local anchor = opts.anchor or 'feet'
    local horizonShift = opts.horizonShift or 0

    local screenX = floor((screenW / 2) * (1 + transformX / transformY))

    -- Same projection the wall loop uses, so sprites and walls agree on size.
    local size = floor((screenH / transformY) * scale)
    if size < 1 then return nil end

    local horizon = screenH / 2 + horizonShift
    local top
    if anchor == 'center' then
        top = floor(horizon - size / 2)
    else
        -- Feet sit on the floor line, which is where a wall of height 1 ends.
        local wallHeight = floor(screenH / transformY)
        top = floor(horizon + wallHeight / 2 - size)
    end

    return {
        x = screenX - floor(size / 2),
        y = top,
        w = size,
        h = size,
        centerX = screenX,
        depth = transformY,
    }
end

-- Orders sprites far-to-near so nearer ones paint over farther ones. Painting
-- back to front is what makes overlapping sprites look right; the z-buffer
-- handles walls, but not sprites against each other.
function Billboard.sortByDepth(list)
    table.sort(list, function(a, b) return a.depth > b.depth end)
    return list
end

-- Whether a sprite column is visible at screen column `x`: it must be on screen
-- and nearer than whatever wall the raycaster recorded there.
function Billboard.columnVisible(x, depth, zbuffer, screenW)
    if x < 0 or x >= screenW then return false end
    local wallDepth = zbuffer[x]
    if wallDepth == nil then return true end
    return depth < wallDepth
end

Billboard.TWO_PI = TWO_PI

return Billboard
