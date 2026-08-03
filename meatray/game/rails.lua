--[[
    meatray.game.rails — a scripted camera move, as a model (C20).

    A cutscene camera and the photo camera (F10) want the same detached view; the
    difference is who is flying it. Photo mode is you. A rail is a SCRIPT: a list
    of waypoints the camera glides through on its own, for an intro fly-through, a
    "look at the boss" beat, or the establishing shot a campaign mission opens on.

        local Rails = require('meatray.game.rails')

        local rail = Rails.new({
            { x = 2,  y = 2,  angle = 0,    hold = 0.5 },   -- start, dwell 0.5s
            { x = 10, y = 2,  angle = 0,    travel = 2.0 }, -- 2s glide to here
            { x = 10, y = 10, angle = 1.57, travel = 1.5 },
        }, { ease = 'smooth' })

        rail:play()
        rail:update(dt)             -- advance along the path
        local pose = rail:pose()    -- { x, y, z, angle, pitch, mode='rail', done }
        rail:isDone()

    Each waypoint after the first carries a `travel` time (seconds to glide there
    from the previous one) and an optional `hold` (seconds to dwell once reached).
    Position and height interpolate linearly or on a smoothstep; angle and pitch
    take the SHORT way round, so a turn from 350° to 10° sweeps 20°, not 340°.

    Deterministic: the only input is dt. Feed it the fixed step and a rail plays
    the same inside a recorded demo as live — the same rule the rest of the sim
    keeps.

    HEADLESS: pure Lua. It produces a pose; the renderer reads it, exactly like
    the spectator (D35) and photo (F10) poses.
]]

local Rails = {}
local RailMT = {}
RailMT.__index = RailMT

local TAU = math.pi * 2

-- The short signed difference from a to b, in (-pi, pi]. A turn takes the near
-- way round, never the long one.
local function angleDelta(a, b)
    local d = (b - a) % TAU
    if d > math.pi then d = d - TAU end
    return d
end

local function smoothstep(u)
    if u < 0 then return 0 elseif u > 1 then return 1 end
    return u * u * (3 - 2 * u)
end

local function lerp(a, b, u) return a + (b - a) * u end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts.ease  'linear' (default) or 'smooth' (smoothstep each segment)
-- opts.loop  true to restart at the first waypoint when the last is reached
-- opts.hideHud  hint for the renderer to hide chrome during the shot
function Rails.new(waypoints, opts)
    opts = opts or {}
    local pts = {}
    for i, w in ipairs(waypoints or {}) do
        pts[i] = {
            x = tonumber(w.x) or 0,
            y = tonumber(w.y) or 0,
            z = tonumber(w.z) or 0,
            angle = tonumber(w.angle) or 0,
            pitch = tonumber(w.pitch) or 0,
            storey = tonumber(w.storey) or 1,
            travel = math.max(0, tonumber(w.travel) or 0),
            hold = math.max(0, tonumber(w.hold) or 0),
        }
    end
    return setmetatable({
        points  = pts,
        ease    = opts.ease == 'smooth' and 'smooth' or 'linear',
        loop    = opts.loop and true or false,
        hideHud = opts.hideHud ~= false,   -- default: a clean shot
        active  = false,
        elapsed = 0,        -- seconds since play() began
        done    = false,
    }, RailMT)
end

function Rails.validate(waypoints)
    if type(waypoints) ~= 'table' then return false, 'waypoints is not a table' end
    if #waypoints < 1 then return false, 'a rail needs at least one waypoint' end
    return true
end

---------------------------------------------------------------------------
-- Playing
---------------------------------------------------------------------------

-- The whole play length: every waypoint's dwell, plus every travel between
-- consecutive waypoints. hold is a dwell AT a waypoint (before moving on); the
-- first waypoint's hold is the opening dwell.
function RailMT:duration()
    local s = 0
    for i = 1, #self.points do
        s = s + self.points[i].hold
        if i >= 2 then s = s + self.points[i].travel end
    end
    return s
end

function RailMT:play()
    self.active = #self.points > 0
    self.done = not self.active
    self.elapsed = 0
    return self
end

function RailMT:stop()
    self.active = false
    return self
end

function RailMT:isActive() return self.active and not self.done end
function RailMT:isDone() return self.done end

-- Advance the play head. Time is a single accumulator mapped to a pose, so a
-- large dt cannot lose a segment and the exact instant a segment ends is not a
-- special case. A non-looping rail finishes when elapsed reaches its duration.
function RailMT:update(dt)
    if not self.active or self.done then return end
    self.elapsed = self.elapsed + math.max(0, tonumber(dt) or 0)
    local total = self:duration()
    if self.loop and total > 0 then
        self.elapsed = self.elapsed % total
    elseif self.elapsed >= total then
        self.elapsed = total
        self.done = true
        self.active = false
    end
end

-- Interpolated pose at `elapsed` seconds into the play. Walks the timeline:
-- dwell at p1, travel to p2, dwell at p2, travel to p3, ... holding the last
-- waypoint once the time runs out.
local function poseAt(self, elapsed)
    local pts = self.points
    local t = elapsed
    if #pts == 1 then return pts[1], pts[1], 1 end

    -- Opening dwell at the first waypoint.
    if t < pts[1].hold then return pts[1], pts[1], 0 end
    t = t - pts[1].hold

    for i = 2, #pts do
        local from, to = pts[i - 1], pts[i]
        if t < to.travel then
            local u = to.travel > 0 and (t / to.travel) or 1
            return from, to, u
        end
        t = t - to.travel
        -- Dwell at this waypoint.
        if t < to.hold then return to, to, 1 end
        t = t - to.hold
    end

    local last = pts[#pts]
    return last, last, 1
end

-- The pose to render from, or nil for an empty rail. Same shape as the
-- spectator (D35) and photo (F10) poses, so the renderer treats them alike.
function RailMT:pose()
    if #self.points == 0 then return nil end
    local from, to, u = poseAt(self, self.elapsed)
    if self.ease == 'smooth' then u = smoothstep(u) end

    return {
        x = lerp(from.x, to.x, u),
        y = lerp(from.y, to.y, u),
        z = lerp(from.z, to.z, u),
        angle = (from.angle + angleDelta(from.angle, to.angle) * u) % TAU,
        pitch = lerp(from.pitch, to.pitch, u),
        storey = (u < 0.5) and from.storey or to.storey,
        mode = 'rail',
        hudHidden = self.hideHud,
        done = self.done,
    }
end

return Rails
