--[[
    meatray.render.lighting — per-tile light levels, coloured sources, and the
    two floors that keep a level readable.

    A light grid holds one RGB level per tile. Surfaces multiply their own colour
    by the level sampled at their position, so a wall, a floor and a sprite
    standing in the same corner all take the same light and an entity sits *in*
    the scene instead of on it.

    Two kinds of light, because they have completely different costs.

      Static  — a wall torch, a lava pool, a window. Baked into the grid once,
                with line-of-sight so the light stops at walls. Never recomputed
                unless something invalidates it.

      Dynamic — a muzzle flash, an explosion, the torch the player carries. Never
                baked. Sampled analytically at the point being shaded, with the
                line-of-sight test memoised per tile for the frame.

    WHAT A FRAME COSTS
    ------------------
    Sampling is O(1) in the size of the world. `sample()` does a constant number
    of grid reads for the static contribution regardless of how many static lights
    were baked into it, then one loop over the *dynamic* lights only. So a frame
    costs

        O( samples taken  ×  dynamic lights )

    where "samples taken" is one per screen column plus one per visible sprite.
    There is no term for world size, tile count or static light count. A world
    that has not changed does no lighting work at all beyond sampling: `update()`
    returns immediately when the dirty list is empty, and it walks only the cells
    inside dirty rectangles when it is not.

    That is deliberate and load-bearing. The failure this design exists to avoid
    is a relight pass that walks every cell every tick "just in case" — a cost
    that scales with the map rather than with what changed, stays invisible on a
    small test level, and surfaces later as something that does not look like a
    performance bug at all.

    THE READABILITY FLOOR
    ---------------------
    `MIN_VISIBILITY` is the level below which no surface is ever drawn, whatever
    the map asks for. An unlit room is meant to read as dark, not as absent: a
    player who cannot tell a corridor from a wall has a worse problem than one
    looking at a level that is too evenly lit. It is a named constant here, not a
    clamp buried inside a shading expression, so it can be tuned in one place and
    tested by name.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
    It lives under render/ because lighting is a presentation concern — the
    simulation never asks how bright a tile is, and a dedicated server has no use
    for a light grid — but it obeys the same rule the sim does and is tested the
    same way, under plain LuaJIT with no `love` global present. See
    tests/test_lighting.lua, which asserts both halves of that claim.
]]

local Collide = require('meatray.sim.collide')

local Lighting = {}

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt

---------------------------------------------------------------------------
-- The tunable constants. Every magic number that decides how dark the game is
-- allowed to get lives here, with the reason it has the value it has.
---------------------------------------------------------------------------

-- The floor on a sampled light level, per channel. Nothing, anywhere, renders
-- dimmer than this fraction of full brightness.
--
-- 0.45 was arrived at by looking, not by taste. The wall palettes in
-- meatray.render.themes sit around 0.24-0.62, and by the time a surface reaches
-- the framebuffer that base has already been through the theme's ambient, the
-- side shade on half the faces, the distance falloff and the fog tint. Multiply
-- all of that by 0.35 — the first value tried — and a rendered wall in a fully
-- unlit room measures about 0.085: the brick lines survive, but only just, and
-- the frame reads as a fault rather than as darkness. 0.45 measures about 0.13
-- on the same shot, which is dim enough that carrying a light is worth doing and
-- bright enough to navigate by. The comparison shots are in the selftest as
-- shot_light_floor.png against shot_light_corridor.png.
--
-- Erring bright is deliberate. A level that is too evenly lit is a tuning
-- complaint; a level that cannot be read is a bug report.
Lighting.MIN_VISIBILITY = 0.45

-- The floor on distance fog's brightness falloff, shared by walls and sprites so
-- the two agree. Walls used 0.10 and sprites 0.15 before this module existed,
-- which is a mismatch you can see: a sprite at range sat slightly brighter than
-- the wall behind it.
Lighting.MIN_DEPTH_SHADE = 0.10

-- The ceiling on a sampled level. Above 1.0 so a muzzle flash or a lava pool can
-- blow a nearby surface out toward white rather than merely reaching the
-- theme's ambient and stopping.
Lighting.MAX_LEVEL = 1.25

-- Per-frame dynamic lights are capped. A frame with a hundred explosions in it
-- is a frame that has already gone wrong; bounding the count means the per-frame
-- cost has a ceiling that does not depend on gameplay going to plan.
Lighting.MAX_DYNAMIC = 64

-- Default radius/intensity for a light that declares neither.
Lighting.DEFAULT_RADIUS = 6
Lighting.DEFAULT_INTENSITY = 1.0

---------------------------------------------------------------------------
-- Falloff curves. Pure functions of (distance, radius), no state, so they are
-- the easiest thing in the engine to test and the first thing to check when the
-- lighting looks wrong.
---------------------------------------------------------------------------

Lighting.curves = {}

-- Straight ramp to zero. Cheap, and reads as a hard-edged pool of light.
function Lighting.curves.linear(t)
    return t
end

-- Smoothstep. Flat at the source and flat at the rim, so a light has no visible
-- edge where it ends. This is the default because a hard rim is the single most
-- obvious tell that a scene is lit by a grid.
function Lighting.curves.smooth(t)
    return t * t * (3 - 2 * t)
end

-- Physically-flavoured inverse square, normalised so it still reaches zero at
-- the radius instead of trailing off forever. Darker in the mid-range than the
-- other two; use it when a source should feel small and local.
function Lighting.curves.inverse(t)
    if t <= 0 then return 0 end
    local d = 1 - t                 -- back to normalised distance
    local a = 1 / (1 + 8 * d * d)
    -- Rescale so a(0)=1 at the source and a(radius)=0 at the rim.
    local aMin = 1 / 9
    return max(0, (a - aMin) / (1 - aMin))
end

Lighting.DEFAULT_CURVE = 'smooth'

-- Attenuation of a light of `radius` at `dist`. Returns 0 at or beyond the
-- radius, 1 at the source, and never anything outside [0, 1].
function Lighting.falloff(dist, radius, curve)
    if not radius or radius <= 0 then return 0 end
    if dist <= 0 then return 1 end
    if dist >= radius then return 0 end

    local fn = Lighting.curves[curve or Lighting.DEFAULT_CURVE] or Lighting.curves.smooth
    local t = 1 - dist / radius
    return max(0, min(1, fn(t)))
end

-- Clamps one channel into the range every sample is promised to be in. Exposed
-- because the floor is the whole point of the module and a caller doing its own
-- accumulation should be able to land in the same place.
function Lighting.clampLevel(v)
    if v < Lighting.MIN_VISIBILITY then return Lighting.MIN_VISIBILITY end
    if v > Lighting.MAX_LEVEL then return Lighting.MAX_LEVEL end
    return v
end

---------------------------------------------------------------------------
-- A light source, normalised. Accepts loose tables so callers can write
-- { x = 3, y = 4 } and get sensible defaults for everything else.
---------------------------------------------------------------------------

local function normaliseLight(def)
    assert(type(def) == 'table', 'a light needs a table')
    assert(type(def.x) == 'number' and type(def.y) == 'number', 'a light needs x and y')

    local color = def.color or { 1, 1, 1 }

    return {
        x = def.x,
        y = def.y,
        radius = def.radius or Lighting.DEFAULT_RADIUS,
        intensity = def.intensity or Lighting.DEFAULT_INTENSITY,
        r = color[1] or 1,
        g = color[2] or 1,
        b = color[3] or 1,
        curve = def.curve or Lighting.DEFAULT_CURVE,
        -- Shadow casting is opt-out. A light meant to represent ambient bounce or
        -- a glow that should not be occluded (a HUD flash, a screen-space
        -- explosion) sets shadows = false and skips every line-of-sight test,
        -- which is also the cheapest kind of light there is.
        shadows = def.shadows ~= false,
        id = def.id,
    }
end

---------------------------------------------------------------------------
-- The grid
---------------------------------------------------------------------------

local Grid = {}
Grid.__index = Grid

-- Builds a light grid over a world.
--
--   Lighting.new{ world = world, baseLevel = 0.45 }
--
-- `baseLevel` is what an unlit tile reads before the floor is applied: 1.0, the
-- default, means "lighting changes nothing" and is what keeps a game that never
-- adds a light rendering exactly as it did before. A map that wants darkness to
-- mean something sets it lower and places lights.
function Lighting.new(opts)
    opts = opts or {}
    local world = opts.world
    assert(world and world.width and world.height, 'a light grid needs a world')

    local baseColor = opts.baseColor or { 1, 1, 1 }
    local baseLevel = opts.baseLevel or 1.0

    local self = setmetatable({
        world = world,
        width = world.width,
        height = world.height,

        baseR = baseLevel * (baseColor[1] or 1),
        baseG = baseLevel * (baseColor[2] or 1),
        baseB = baseLevel * (baseColor[3] or 1),

        statics = {},
        dynamics = {},

        -- Flat RGB triples, index (i-1)*3+1..3 for cell i. One array rather than
        -- three keeps the three channels of a cell adjacent, which is the access
        -- pattern every read here has.
        cells = {},

        dirty = {},              -- pending rectangles, {x1,y1,x2,y2}
        allDirty = true,         -- nothing baked yet

        -- The world revision this grid last baked against. A wall coming down
        -- changes what every light can see past, so a bake made before it is
        -- stale in ways no light footprint describes.
        worldRevision = world.revision or 0,

        frame = 0,
        losCache = {},           -- stamped per frame; see sample()

        stats = {
            bakes = 0,
            cellsBaked = 0,
            cellsBakedLastUpdate = 0,
            losTests = 0,
        },
    }, Grid)

    return self
end

function Grid:index(tx, ty)
    return ((ty - 1) * self.width + (tx - 1)) * 3 + 1
end

function Grid:inBounds(tx, ty)
    return tx >= 1 and ty >= 1 and tx <= self.width and ty <= self.height
end

---------------------------------------------------------------------------
-- Declaring lights
---------------------------------------------------------------------------

-- Adds a static light and marks the area it covers for rebaking. Returns the
-- normalised light table, which the caller may keep in order to remove it later.
function Grid:addStatic(def)
    local light = normaliseLight(def)
    self.statics[#self.statics + 1] = light
    self:markLightDirty(light)
    return light
end

-- Removes a previously added static light, by table identity or by `id`.
function Grid:removeStatic(which)
    for i = 1, #self.statics do
        local light = self.statics[i]
        if light == which or (which ~= nil and light.id ~= nil and light.id == which) then
            table.remove(self.statics, i)
            self:markLightDirty(light)
            return true
        end
    end
    return false
end

function Grid:clearStatic()
    for i = 1, #self.statics do self:markLightDirty(self.statics[i]) end
    self.statics = {}
end

-- Starts a frame: forgets last frame's dynamic lights and invalidates the
-- line-of-sight memo without walking it. Call once per frame, before anything
-- samples.
function Grid:beginFrame()
    local n = #self.dynamics
    for i = 1, n do self.dynamics[i] = nil end
    self.frame = self.frame + 1

    -- Notice geometry changes here rather than being told about them. A wall
    -- destroyed during a net apply or a game tick would otherwise invalidate
    -- this cache partway through a frame, and half the screen would be lit
    -- against the old occlusion and half against the new.
    --
    -- The whole bake goes, not a footprint: the counter says something changed,
    -- not what, and a removed wall changes what every light can see past
    -- regardless of how far away it is. Tracking which tiles changed would let
    -- this be precise, but it needs a per-consumer change log -- lighting, a
    -- batched mesh and a navmesh each read at their own pace -- and that is a
    -- lot of machinery for an event as rare as a wall coming down.
    local revision = self.world.revision or 0
    if revision ~= self.worldRevision then
        self.worldRevision = revision
        self:invalidateAll()
    end

    return self
end

-- Adds a light for this frame only. Costs nothing at add time; it is paid for at
-- every sample, which is why the count is capped.
function Grid:addDynamic(def)
    if #self.dynamics >= Lighting.MAX_DYNAMIC then return nil end
    local light = normaliseLight(def)
    self.dynamics[#self.dynamics + 1] = light
    return light
end

function Grid:dynamicCount() return #self.dynamics end
function Grid:staticCount() return #self.statics end

---------------------------------------------------------------------------
-- Dirty regions
---------------------------------------------------------------------------

function Grid:markDirty(x1, y1, x2, y2)
    if self.allDirty then return self end

    x1 = max(1, floor(x1)); y1 = max(1, floor(y1))
    x2 = min(self.width, floor(x2)); y2 = min(self.height, floor(y2))
    if x1 > x2 or y1 > y2 then return self end

    self.dirty[#self.dirty + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    return self
end

function Grid:markLightDirty(light)
    local r = light.radius
    return self:markDirty(light.x - r - 1, light.y - r - 1,
                          light.x + r + 1, light.y + r + 1)
end

-- The geometry at (tx, ty) changed — a door opened, a wall was destroyed. Only
-- the lights that could actually see that tile are affected, so only their
-- footprints are invalidated. A change in a corner of the map that no light
-- reaches costs nothing at all.
function Grid:invalidateTile(tx, ty)
    if self.allDirty then return self end

    for i = 1, #self.statics do
        local light = self.statics[i]
        local r = light.radius
        if tx >= light.x - r - 1 and tx <= light.x + r + 1
           and ty >= light.y - r - 1 and ty <= light.y + r + 1 then
            self:markLightDirty(light)
        end
    end
    return self
end

function Grid:invalidateRect(x1, y1, x2, y2)
    for ty = max(1, floor(y1)), min(self.height, floor(y2)) do
        for tx = max(1, floor(x1)), min(self.width, floor(x2)) do
            self:invalidateTile(tx, ty)
        end
    end
    return self
end

function Grid:invalidateAll()
    self.allDirty = true
    self.dirty = {}
    return self
end

function Grid:isDirty()
    return self.allDirty or #self.dirty > 0
end

---------------------------------------------------------------------------
-- Baking
---------------------------------------------------------------------------

-- Whether a light at (lx, ly) reaches the centre of tile (tx, ty).
function Grid:lightReaches(light, tx, ty)
    if not light.shadows then return true end
    self.stats.losTests = self.stats.losTests + 1
    return Collide.lineOfSight(self.world, light.x, light.y, tx - 0.5, ty - 0.5)
end

-- Recomputes one rectangle of cells from scratch: reset to base, then add every
-- static light whose footprint overlaps it. Returns the number of cells written.
function Grid:bakeRect(x1, y1, x2, y2)
    local cells = self.cells
    local world = self.world
    local written = 0

    for ty = y1, y2 do
        for tx = x1, x2 do
            local i = self:index(tx, ty)
            cells[i]     = self.baseR
            cells[i + 1] = self.baseG
            cells[i + 2] = self.baseB
            written = written + 1
        end
    end

    for n = 1, #self.statics do
        local light = self.statics[n]
        local r = light.radius

        -- Only the overlap of this light's footprint with the rectangle.
        local lx1 = max(x1, floor(light.x - r) + 1)
        local lx2 = min(x2, floor(light.x + r) + 1)
        local ly1 = max(y1, floor(light.y - r) + 1)
        local ly2 = min(y2, floor(light.y + r) + 1)

        for ty = ly1, ly2 do
            for tx = lx1, lx2 do
                -- A solid tile is never sampled directly: the wall loop samples
                -- the open tile in front of the face it is drawing, and sprites
                -- stand in open tiles. Skipping them is a correctness-neutral
                -- saving of the most expensive thing in the bake.
                if not world:isSolid(tx, ty) then
                    local dx = (tx - 0.5) - light.x
                    local dy = (ty - 0.5) - light.y
                    local dist = sqrt(dx * dx + dy * dy)
                    local att = Lighting.falloff(dist, r, light.curve)

                    if att > 0 and self:lightReaches(light, tx, ty) then
                        local amount = att * light.intensity
                        local i = self:index(tx, ty)
                        cells[i]     = cells[i]     + light.r * amount
                        cells[i + 1] = cells[i + 1] + light.g * amount
                        cells[i + 2] = cells[i + 2] + light.b * amount
                    end
                end
            end
        end
    end

    self.stats.cellsBaked = self.stats.cellsBaked + written
    return written
end

-- Brings the grid up to date. O(1) when nothing is dirty — which is the common
-- case, and the reason this is safe to call every frame.
function Grid:update()
    local written = 0

    if self.allDirty then
        self.allDirty = false
        self.dirty = {}
        written = self:bakeRect(1, 1, self.width, self.height)
    elseif #self.dirty > 0 then
        local pending = self.dirty
        self.dirty = {}
        for i = 1, #pending do
            local rect = pending[i]
            written = written + self:bakeRect(rect.x1, rect.y1, rect.x2, rect.y2)
        end
    end

    if written > 0 then self.stats.bakes = self.stats.bakes + 1 end
    self.stats.cellsBakedLastUpdate = written
    return written
end

-- Forces a full rebake. Mostly for tests and for a caller that has changed the
-- world wholesale.
function Grid:bake()
    self:invalidateAll()
    return self:update()
end

---------------------------------------------------------------------------
-- Sampling
---------------------------------------------------------------------------

-- The baked level of one tile, with no dynamic contribution and no floor. Out of
-- bounds reads as base, so a sample that strays off the map does not go black.
function Grid:tileLevel(tx, ty)
    if not self:inBounds(tx, ty) then
        return self.baseR, self.baseG, self.baseB
    end
    local i = self:index(tx, ty)
    local r = self.cells[i]
    if r == nil then
        return self.baseR, self.baseG, self.baseB
    end
    return r, self.cells[i + 1], self.cells[i + 2]
end

-- Memoised line of sight from dynamic light `n` to the centre of tile index
-- `cell`, valid for this frame only.
--
-- The stamp trick avoids clearing the cache: an entry stores frame*2 + visible,
-- so an entry left over from an earlier frame is recognised as stale and
-- recomputed rather than trusted. That turns "invalidate the whole cache" from a
-- walk over every entry into an increment, which matters because this cache is
-- the thing standing between per-column sampling and O(columns × lights × ray)
-- work every frame.
function Grid:dynamicReaches(light, n, cell, tx, ty)
    if not light.shadows then return true end

    -- A sample off the edge of the map has no cell to key on; test it directly
    -- rather than sharing one cache slot between every out-of-bounds point.
    if cell <= 0 then
        self.stats.losTests = self.stats.losTests + 1
        return Collide.lineOfSight(self.world, light.x, light.y, tx - 0.5, ty - 0.5)
    end

    local key = cell * (Lighting.MAX_DYNAMIC + 1) + n
    local cached = self.losCache[key]
    local stamp = self.frame

    if cached and floor(cached / 2) == stamp then
        return cached % 2 == 1
    end

    self.stats.losTests = self.stats.losTests + 1
    local visible = Collide.lineOfSight(self.world, light.x, light.y,
                                        tx - 0.5, ty - 0.5)
    self.losCache[key] = stamp * 2 + (visible and 1 or 0)
    return visible
end

-- The light at a world position, as three channels already clamped into
-- [MIN_VISIBILITY, MAX_LEVEL].
--
-- The static half is bilinear across the four nearest tile centres, so the grid
-- does not show as blocks on a wall — but a neighbour that is solid is dropped
-- and its weight given to the centre tile, because interpolating across a wall
-- is exactly how light leaks into the room next door.
function Grid:sample(x, y)
    if self:isDirty() then self:update() end

    -- Shift by half a tile so integer coordinates land on tile centres.
    local gx, gy = x + 0.5, y + 0.5
    local ix, iy = floor(gx), floor(gy)
    local u, v = gx - ix, gy - iy

    local world = self.world

    -- The tile the sample actually sits in, which is not always `ix, iy`: the
    -- half-tile shift above picks the four centres to interpolate between, and
    -- for a point in the far half of a tile those centres start one tile over.
    local cx, cy = floor(x) + 1, floor(y) + 1
    cx = min(max(cx, 1), self.width)
    cy = min(max(cy, 1), self.height)

    local r, g, b = 0, 0, 0
    local total = 0

    for oy = 0, 1 do
        for ox = 0, 1 do
            local w = (ox == 0 and (1 - u) or u) * (oy == 0 and (1 - v) or v)
            if w > 0 then
                local tx, ty = ix + ox, iy + oy
                -- A solid or out-of-bounds neighbour contributes nothing and its
                -- weight falls back to the tile the sample is actually in.
                if self:inBounds(tx, ty) and not world:isSolid(tx, ty) then
                    local nr, ng, nb = self:tileLevel(tx, ty)
                    r = r + nr * w; g = g + ng * w; b = b + nb * w
                    total = total + w
                end
            end
        end
    end

    if total <= 0 then
        r, g, b = self:tileLevel(cx, cy)
    elseif total < 1 then
        local fr, fg, fb = self:tileLevel(cx, cy)
        local rest = 1 - total
        r = r + fr * rest; g = g + fg * rest; b = b + fb * rest
    end

    -- Dynamic lights, exactly. This is the only loop whose length depends on
    -- anything the caller does per frame.
    local dynamics = self.dynamics
    for n = 1, #dynamics do
        local light = dynamics[n]
        local dx, dy = x - light.x, y - light.y
        local rad = light.radius
        -- Squared-distance reject before anything expensive, so a light on the
        -- other side of the map costs two subtractions and a compare.
        if dx * dx + dy * dy < rad * rad then
            local dist = sqrt(dx * dx + dy * dy)
            local att = Lighting.falloff(dist, rad, light.curve)
            if att > 0 then
                local tx, ty = floor(x) + 1, floor(y) + 1
                local cell = self:inBounds(tx, ty)
                    and ((ty - 1) * self.width + tx) or 0
                if self:dynamicReaches(light, n, cell, tx, ty) then
                    local amount = att * light.intensity
                    r = r + light.r * amount
                    g = g + light.g * amount
                    b = b + light.b * amount
                end
            end
        end
    end

    return Lighting.clampLevel(r), Lighting.clampLevel(g), Lighting.clampLevel(b)
end

-- The same question, ignoring dynamic lights. Useful for gameplay that wants a
-- stable answer ("is this tile in shadow?") rather than a per-frame one.
function Grid:sampleStatic(x, y)
    local dynamics = self.dynamics
    self.dynamics = {}
    local r, g, b = self:sample(x, y)
    self.dynamics = dynamics
    return r, g, b
end

-- A single scalar brightness, for callers that do not want three channels.
function Grid:brightness(x, y)
    local r, g, b = self:sample(x, y)
    return (r + g + b) / 3
end

function Grid:report()
    return {
        width = self.width,
        height = self.height,
        statics = #self.statics,
        dynamics = #self.dynamics,
        dirty = #self.dirty,
        allDirty = self.allDirty,
        bakes = self.stats.bakes,
        cellsBaked = self.stats.cellsBaked,
        cellsBakedLastUpdate = self.stats.cellsBakedLastUpdate,
        losTests = self.stats.losTests,
    }
end

Lighting.Grid = Grid

return Lighting
