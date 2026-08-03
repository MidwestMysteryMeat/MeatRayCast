--[[
    meatray.game.photo — a detached camera for screenshots and trailers (F10).

    The player's eyes are pinned to the player: bound to a body, stopped by
    walls, bobbing with the walk. Photo mode cuts that tether. The camera
    becomes a free-flying point you push through the level to frame a shot —
    through walls if you want, above the ceiling, nose to a texture — while the
    world holds still and the HUD gets out of the way.

        local Photo = require('meatray.game.photo')
        local cam = Photo.new{ moveSpeed = 4, lookSpeed = 2 }

        cam:enter({ x = p.x, y = p.y, angle = p.angle, storey = 1, z = p.z })
        cam:pan(dt, forward, strafe, rise, { fast = shiftHeld })  -- fly
        cam:look(dyaw, dpitch)                                    -- aim
        local pose = cam:pose()   -- { x, y, angle, pitch, storey, z, fov,
                                  --   mode='photo', hudHidden } or nil

    While active it asks the game to freeze the simulation (`pausesSim()`), so a
    long exposure of a moving scene captures the exact instant you entered — a
    still, not a smear. Toggle the HUD off for a clean frame; nudge the FOV for
    a wide or a telephoto look; the pitch is clamped so you cannot roll past
    straight up or down.

    Movement is FREE — the whole point is to escape collision — so this holds no
    reference to the world and never asks whether a wall is in the way. It is a
    pose and a set of intents; the renderer reads the pose, and the demo decides
    to skip the tick while it is active.

    HEADLESS: pure Lua, no love.*. The caller supplies dt and input intents in
    [-1, 1]; nothing here reads a key or a clock.
]]

local Photo = {}
local PhotoMT = {}
PhotoMT.__index = PhotoMT

local function clamp(v, lo, hi)
    v = tonumber(v) or 0
    if v ~= v then return lo end          -- NaN -> the floor, never propagates
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts.moveSpeed  tiles/second at full stick (default 4)
-- opts.lookSpeed  radians/second scaling for look() deltas (default 1.5)
-- opts.fastMul    multiplier while the fast modifier is held (default 3)
-- opts.riseSpeed  vertical tiles/second (default = moveSpeed)
-- opts.maxPitch   pitch clamp in radians (default 0.99 — just shy of vertical)
-- opts.fov        starting field of view in radians (default 1.05 ~ 60°)
-- opts.fovRange   { min, max } (default { 0.5, 2.2 })
function Photo.new(opts)
    opts = opts or {}
    local move = tonumber(opts.moveSpeed) or 4
    return setmetatable({
        active   = false,
        hudHidden = false,
        moveSpeed = move,
        riseSpeed = tonumber(opts.riseSpeed) or move,
        lookSpeed = tonumber(opts.lookSpeed) or 1.5,
        fastMul   = tonumber(opts.fastMul) or 3,
        maxPitch  = tonumber(opts.maxPitch) or 0.99,
        fov       = tonumber(opts.fov) or 1.05,
        fovMin    = (opts.fovRange and opts.fovRange[1]) or 0.5,
        fovMax    = (opts.fovRange and opts.fovRange[2]) or 2.2,
        freezeSim = opts.freezeSim ~= false,   -- default true
        -- pose, meaningful only while active
        x = 0, y = 0, z = 0, yaw = 0, pitch = 0, storey = 1,
    }, PhotoMT)
end

---------------------------------------------------------------------------
-- Entering and leaving
---------------------------------------------------------------------------

-- Detach the camera, seeding it from wherever the view is right now so it does
-- not jump on entry. `from` is { x, y, angle, storey, z, pitch }.
function PhotoMT:enter(from)
    from = from or {}
    self.active = true
    self.x = tonumber(from.x) or 0
    self.y = tonumber(from.y) or 0
    self.z = tonumber(from.z) or 0
    self.yaw = tonumber(from.angle) or 0
    self.pitch = clamp(from.pitch or 0, -self.maxPitch, self.maxPitch)
    self.storey = tonumber(from.storey) or 1
    return self
end

function PhotoMT:exit()
    self.active = false
    return self
end

-- Enters seeded from `from` if inactive, exits if active. Returns the new state.
function PhotoMT:toggle(from)
    if self.active then self:exit() else self:enter(from) end
    return self.active
end

function PhotoMT:isActive() return self.active end

-- True when the game should freeze its simulation for a clean still. A caller
-- can flip freezeSim off (via new{ freezeSim=false }) to film a live scene.
function PhotoMT:pausesSim()
    return self.active and self.freezeSim
end

---------------------------------------------------------------------------
-- Flying and aiming
---------------------------------------------------------------------------

-- Fly for one frame. forward/strafe/rise are intents in [-1, 1]:
--   forward  along the look direction (ignores pitch — you fly level unless you
--            rise; that is what keeps framing predictable)
--   strafe   to the right of the look direction
--   rise     straight up (+) or down (-)
-- opts.fast applies the fast multiplier (a held shift, typically).
function PhotoMT:pan(dt, forward, strafe, rise, opts)
    if not self.active then return end
    dt = clamp(dt, 0, math.huge)          -- NaN -> 0, never propagates to pose
    local mul = (opts and opts.fast) and self.fastMul or 1
    local d = self.moveSpeed * mul * dt
    forward = clamp(forward, -1, 1)
    strafe  = clamp(strafe, -1, 1)
    rise    = clamp(rise, -1, 1)

    local cosY, sinY = math.cos(self.yaw), math.sin(self.yaw)
    -- forward = (cos,sin); right = forward rotated +90° = (-sin, cos)
    self.x = self.x + (cosY * forward - sinY * strafe) * d
    self.y = self.y + (sinY * forward + cosY * strafe) * d
    self.z = self.z + rise * self.riseSpeed * mul * dt
end

-- Aim. dyaw/dpitch are raw deltas (e.g. mouse pixels × sensitivity, or a stick
-- × dt). Pitch is clamped so the camera never tips past straight up or down.
function PhotoMT:look(dyaw, dpitch)
    if not self.active then return end
    self.yaw = (self.yaw + (tonumber(dyaw) or 0)) % (2 * math.pi)
    self.pitch = clamp(self.pitch + (tonumber(dpitch) or 0),
                       -self.maxPitch, self.maxPitch)
end

-- Raise (+) or lower (-) the camera without a full pan call.
function PhotoMT:nudgeHeight(dz)
    if not self.active then return end
    self.z = self.z + (tonumber(dz) or 0)
end

-- Change storey (which layer the camera renders). No clamp: the caller knows
-- how many storeys the world has; an out-of-range storey simply shows nothing.
function PhotoMT:setStorey(s)
    self.storey = math.floor(tonumber(s) or self.storey)
    return self.storey
end

---------------------------------------------------------------------------
-- Lens and chrome
---------------------------------------------------------------------------

function PhotoMT:setFov(f)
    self.fov = clamp(f, self.fovMin, self.fovMax)
    return self.fov
end

function PhotoMT:adjustFov(df)
    return self:setFov(self.fov + (tonumber(df) or 0))
end

function PhotoMT:toggleHud()
    self.hudHidden = not self.hudHidden
    return self.hudHidden
end

function PhotoMT:hudIsHidden()
    return self.active and self.hudHidden
end

---------------------------------------------------------------------------
-- The pose
---------------------------------------------------------------------------

-- The camera to render from, or nil when photo mode is off (use normal eyes).
function PhotoMT:pose()
    if not self.active then return nil end
    return {
        x = self.x, y = self.y, z = self.z,
        angle = self.yaw, pitch = self.pitch,
        storey = self.storey, fov = self.fov,
        mode = 'photo', hudHidden = self.hudHidden,
    }
end

return Photo
