--[[
    meatray.render.particles — the sparks, blood and tracers a hit throws off
    (C27).

    Decals are the marks a hit LEAVES; particles are what it THROWS — the spray
    that lives a fraction of a second and is gone. They differ from decals in
    the two ways that matter: they move (velocity, gravity, drag) and they die
    fast, so the model is a moving-point simulation with a hard cap rather than
    a fading stamp.

        local Particles = require('meatray.render.particles')
        local fx = Particles.new{ max = 400 }

        fx:burst('spark', hitX, hitY, { nx = nx, ny = ny })   -- a bullet on stone
        fx:burst('blood', hitX, hitY, { nx = nx, ny = ny })   -- a bullet on flesh
        fx:tracer(fromX, fromY, toX, toY)                     -- the round's streak

        fx:update(dt)                    -- real time; presentation only
        for _, p in ipairs(fx:all()) do draw(p.x, p.y, p.z, p.color, p.alpha) end

    A burst is data — count, speed spread, cone, colour, gravity, life — kept
    in KINDS so a new effect is a table entry, not a new code path, exactly the
    way the brush tools and hazard kinds are. The cone is taken around a
    surface normal when one is given (sparks fly OFF the wall they hit), and
    around a random direction when none is (an air burst).

    A tracer is one long-lived particle drawn as a segment: it carries a second
    point (x2,y2,z2) and a renderer draws a line, where every other particle is
    a point. It is here rather than in its own module because it lives and dies
    on the same clock and under the same cap — a firefight's tracers and sparks
    compete for the same budget, which is the point of a budget.

    Determinism is NOT promised here and deliberately so: particles are pure
    presentation, a dedicated server makes none, and a demo replay does not
    reproduce them (they are not simulation). The spread uses an injectable
    rng for tests and math.random otherwise — the one place in the engine that
    may, because nothing downstream can observe it.

    HEADLESS: pure Lua (a server simply never calls burst).
]]

local Particles = {}
local SetMT = {}
SetMT.__index = SetMT

local cos, sin, sqrt, pi = math.cos, math.sin, math.sqrt, math.pi
local atan2 = math.atan2 or math.atan

---------------------------------------------------------------------------
-- Kinds: each a recipe for a burst
---------------------------------------------------------------------------

-- count       particles per burst
-- speed/spread base speed and +/- variation (world units/sec)
-- cone        half-angle the particles spray within (radians)
-- gravity     downward z acceleration (units/sec^2); 0 = floats
-- drag        velocity retained per second (0.9 = loses 10%/s-ish)
-- life/lifeVar seconds, with variation
-- size        draw radius
-- color / colorVar  base RGB and per-channel jitter
Particles.KINDS = {
    spark = {
        count = 8, speed = 6, spread = 3, cone = 0.9, gravity = 8, drag = 0.86,
        life = 0.35, lifeVar = 0.15, size = 0.03,
        color = { 1.0, 0.85, 0.45 }, colorVar = 0.1,
    },
    blood = {
        count = 10, speed = 4, spread = 2.5, cone = 1.1, gravity = 12, drag = 0.8,
        life = 0.5, lifeVar = 0.2, size = 0.04,
        color = { 0.6, 0.05, 0.05 }, colorVar = 0.08,
    },
    debris = {
        count = 6, speed = 3.5, spread = 2, cone = 1.4, gravity = 14, drag = 0.82,
        life = 0.7, lifeVar = 0.25, size = 0.05,
        color = { 0.4, 0.38, 0.34 }, colorVar = 0.12,
    },
    smoke = {
        count = 5, speed = 1.2, spread = 0.6, cone = 1.2, gravity = -1.5, drag = 0.7,
        life = 0.8, lifeVar = 0.3, size = 0.08,
        color = { 0.5, 0.5, 0.52 }, colorVar = 0.06,
    },
}

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Particles.new(opts)
    opts = opts or {}
    return setmetatable({
        list = {},
        max = opts.max or 400,
        eyeZ = opts.eyeZ or 0.5,          -- default spawn height for air bursts
        -- Tests inject this; production leaves it nil and uses math.random.
        randomSource = opts.randomSource,
    }, SetMT)
end

local function rnd(self)
    if self.randomSource then return self.randomSource() end
    return math.random()
end

-- A signed [-1, 1] from the source.
local function rndSigned(self) return rnd(self) * 2 - 1 end

local function cap(self)
    while #self.list > self.max do table.remove(self.list, 1) end
end

---------------------------------------------------------------------------
-- Bursts
---------------------------------------------------------------------------

-- opts: nx, ny (surface normal the spray flies off; random if absent),
--       z (spawn height; eyeZ if absent), kinds override table, scale.
function SetMT:burst(kind, x, y, opts)
    opts = opts or {}
    local def = (opts.kinds or Particles.KINDS)[kind] or Particles.KINDS.spark
    local z = tonumber(opts.z) or self.eyeZ
    local scale = tonumber(opts.scale) or 1

    -- The centre direction: off the normal, or random for an air burst.
    local baseAng
    if opts.nx and opts.ny and (opts.nx ~= 0 or opts.ny ~= 0) then
        baseAng = atan2(opts.ny, opts.nx)
    else
        baseAng = rnd(self) * 2 * pi
    end

    local n = math.floor((def.count or 6) * scale + 0.5)
    for _ = 1, n do
        local ang = baseAng + rndSigned(self) * (def.cone or 1)
        local speed = ((def.speed or 4) + rndSigned(self) * (def.spread or 0)) * scale
        local c = def.color or { 1, 1, 1 }
        local cv = def.colorVar or 0
        local life = (def.life or 0.4) + rndSigned(self) * (def.lifeVar or 0)
        self.list[#self.list + 1] = {
            x = x, y = y, z = z,
            vx = cos(ang) * speed,
            vy = sin(ang) * speed,
            vz = rnd(self) * speed * 0.4,     -- a little upward pop
            gravity = def.gravity or 8,
            drag = def.drag or 0.85,
            life = life, maxLife = life,
            size = (def.size or 0.03) * scale,
            color = {
                math.max(0, math.min(1, c[1] + rndSigned(self) * cv)),
                math.max(0, math.min(1, c[2] + rndSigned(self) * cv)),
                math.max(0, math.min(1, c[3] + rndSigned(self) * cv)),
            },
        }
    end
    cap(self)
    return n
end

-- A tracer: a bright short-lived line from source to impact. Drawn as a
-- segment (it carries x2,y2,z2), unlike every other particle, which is a point.
function SetMT:tracer(x1, y1, x2, y2, opts)
    opts = opts or {}
    local z = tonumber(opts.z) or self.eyeZ
    local life = tonumber(opts.life) or 0.08
    self.list[#self.list + 1] = {
        tracer = true,
        x = x1, y = y1, z = z,
        x2 = x2, y2 = y2, z2 = tonumber(opts.z2) or z,
        vx = 0, vy = 0, vz = 0, gravity = 0, drag = 1,
        life = life, maxLife = life,
        size = tonumber(opts.size) or 0.02,
        color = opts.color or { 1.0, 0.95, 0.7 },
    }
    cap(self)
    return self.list[#self.list]
end

---------------------------------------------------------------------------
-- Simulation
---------------------------------------------------------------------------

function SetMT:update(dt)
    dt = math.max(0, tonumber(dt) or 0)
    if dt == 0 then return end
    local i = 1
    while i <= #self.list do
        local p = self.list[i]
        p.life = p.life - dt
        if p.life <= 0 then
            table.remove(self.list, i)
        else
            if not p.tracer then
                -- Drag as a per-second retention, framerate-shaped.
                local keep = p.drag ^ dt
                p.vx = p.vx * keep
                p.vy = p.vy * keep
                p.vz = (p.vz - p.gravity * dt) * keep
                p.x = p.x + p.vx * dt
                p.y = p.y + p.vy * dt
                p.z = p.z + p.vz * dt
                if p.z < 0 then p.z = 0; p.vz = 0 end   -- rest on the floor
            end
            i = i + 1
        end
    end
end

function SetMT:clear() self.list = {}; return self end
function SetMT:count() return #self.list end
function SetMT:all() return self.list end

-- Fade alpha for a particle, 0..1, squared so it lingers bright then drops.
function Particles.alpha(p)
    if not p or p.maxLife <= 0 then return 0 end
    local t = p.life / p.maxLife
    return t > 0 and t or 0
end

return Particles
