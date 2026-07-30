--[[
    meatray.net.lagcomp — rewind the world to what the shooter actually saw.

    A client shoots at where a target appears to be. By the time that shot
    reaches the host, the target has moved: half a round trip, plus the
    interpolation delay the client renders behind by so its view stays smooth.
    At 100 ms ping that is comfortably a body width, and the player experience is
    that shots pass through people. Nobody reads that as physics. They read it as
    the game being broken.

    So the host rewinds: it remembers where everything was, and validates the
    hit against the world as it looked on the shooter's screen.

        history:capture(host.now, host.entities)          -- on a timer
        history:withRewound(when, host.entities, function()
            return Collide.hitscan(world, x, y, dx, dy, host.entities)
        end)

    **Hit validation only.** Movement is never rewound and the host stays
    authoritative over both. Rewinding movement would let a client claim to have
    walked through a door that was open a moment ago.

    THE CLAMP IS A SECURITY BOUNDARY, not a performance guard. `when` is derived
    from a round-trip time, and a round-trip time is partly reported by the peer
    it describes. Unclamped, a client claiming a huge RTT rewinds the world far
    enough to shoot someone who has since left the room, and every shot lands.
    The window is the maximum unfairness a shooter may impose on a target who has
    already moved, so it is small, fixed, and enforced here rather than trusted
    to callers.

    Six captures at 100 ms is a 600 ms window, following Mirror's parameters.
    Deeper is not better. A longer window does not make hits fairer, it makes
    them later: the target is punished for movement they made further in the
    past, and beyond a few hundred milliseconds the person being shot has no way
    to understand what happened to them.

    HEADLESS: no love, no socket, no clock of its own. The caller supplies time.
]]

local LagComp = {}

-- Seconds between captures. Finer sampling buys accuracy that the snapshot rate
-- does not deliver in the first place -- a client is interpolating between
-- 20 Hz snapshots, so it never saw a position more precise than this.
LagComp.CAPTURE_INTERVAL = 0.100

-- How many captures are kept. Window = HISTORY * CAPTURE_INTERVAL.
LagComp.HISTORY = 6

local HistoryMT = {}
HistoryMT.__index = HistoryMT

local min, max, floor = math.min, math.max, math.floor

---------------------------------------------------------------------------

function LagComp.new(opts)
    opts = opts or {}

    local capacity = opts.history or LagComp.HISTORY
    local frames = {}

    -- Preallocated and reused for the life of the process. A per-capture table
    -- at 10 Hz forever is a slow leak of garbage into a loop that is already the
    -- host's hot path.
    for i = 1, capacity do
        frames[i] = { time = nil, count = 0, ids = {}, x = {}, y = {} }
    end

    return setmetatable({
        frames   = frames,
        capacity = capacity,
        newest   = 0,          -- index of the most recent frame, 0 = none yet
        stored   = 0,          -- how many frames hold real data
        interval = opts.interval or LagComp.CAPTURE_INTERVAL,
        accum    = 0,
        lastAt   = nil,

        stats = { captures = 0, rewinds = 0, clamped = 0 },
    }, HistoryMT)
end

function HistoryMT:window()
    return self.capacity * self.interval
end

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

-- Records where everything is. Call on a timer, not every tick: at 60 Hz that
-- is six times the memory for accuracy no client could have observed.
--
-- Only position is kept. Radius is read live at validation time because a hit
-- test against a stale radius would be wrong in the one direction that matters:
-- an entity that grew would be hittable at a size it no longer has.
function HistoryMT:capture(now, entities)
    local index = (self.newest % self.capacity) + 1
    local frame = self.frames[index]

    local ids, xs, ys = frame.ids, frame.x, frame.y
    local n = 0

    for i = 1, #entities do
        local e = entities[i]
        if e and e.id and e.x and e.y then
            n = n + 1
            ids[n], xs[n], ys[n] = e.id, e.x, e.y
        end
    end

    frame.time = now
    frame.count = n

    self.newest = index
    self.stored = min(self.stored + 1, self.capacity)
    self.lastAt = now
    self.stats.captures = self.stats.captures + 1

    return self
end

-- Advances an internal accumulator and captures when due. The host calls this
-- once per update and does not have to own the timer itself.
function HistoryMT:update(now, dt, entities)
    self.accum = self.accum + (dt or 0)
    if self.lastAt == nil or self.accum >= self.interval then
        self.accum = 0
        self:capture(now, entities)
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Rewind
---------------------------------------------------------------------------

-- Walks back from the newest frame. Returns the frame index i steps back, or
-- nil once it runs out of stored frames.
function HistoryMT:frameAt(stepsBack)
    if stepsBack >= self.stored then return nil end
    local index = self.newest - stepsBack
    while index < 1 do index = index + self.capacity end
    return self.frames[index]
end

-- The time a shot fired by `peer` was actually aimed. Both terms are real:
-- half a round trip is the travel, and the interpolation delay is how far behind
-- live the client deliberately renders so its view is smooth.
--
-- rttSeconds comes from the transport, which measures it, rather than from
-- anything the client asserts about itself.
function LagComp.aimTime(now, rttSeconds, interpolationDelay)
    return now - (rttSeconds or 0) * 0.5 - (interpolationDelay or 0)
end

-- Where everything was at `when`, written into `out` as { [id] = {x, y} }.
--
-- `when` is clamped into the stored window before anything is looked up. That
-- clamp is the security boundary described at the top of this file: it is
-- applied here, once, so that no caller can forget it.
function HistoryMT:positionsAt(when, out)
    out = out or {}
    for k in pairs(out) do out[k] = nil end

    if self.stored == 0 then return out, false end

    local newest = self:frameAt(0)
    local oldest = self:frameAt(self.stored - 1)

    local clamped = false
    if when > newest.time then
        when = newest.time
        clamped = true
    elseif when < oldest.time then
        when = oldest.time
        clamped = true
        self.stats.clamped = self.stats.clamped + 1
    end

    -- Find the two frames bracketing `when`, newest first.
    local after, before = newest, nil
    for step = 1, self.stored - 1 do
        local frame = self:frameAt(step)
        if frame.time <= when then before = frame; break end
        after = frame
    end

    if not before then
        for i = 1, after.count do out[after.ids[i]] = { after.x[i], after.y[i] }end
        return out, clamped
    end

    local span = after.time - before.time
    local alpha = span > 0 and ((when - before.time) / span) or 0
    alpha = max(0, min(1, alpha))

    -- Start from the earlier frame so an entity that existed then but not now
    -- is still placed; hit validation asks about the world as it was.
    for i = 1, before.count do
        out[before.ids[i]] = { before.x[i], before.y[i] }
    end

    for i = 1, after.count do
        local id = after.ids[i]
        local from = out[id]
        if from then
            from[1] = from[1] + (after.x[i] - from[1]) * alpha
            from[2] = from[2] + (after.y[i] - from[2]) * alpha
        elseif alpha >= 1 then
            -- Present in the later frame only, and `when` IS that frame's time,
            -- so it did exist by then. This is the boundary case: a rewind that
            -- lands exactly on a capture is common, because a rewind to "now"
            -- clamps to the newest frame.
            out[id] = { after.x[i], after.y[i] }
        end
        -- Otherwise it spawned inside the interval, after `when`. It was not on
        -- the shooter's screen, so it is not hittable in the past.
    end

    -- An entity in the earlier frame but not the later one despawned somewhere
    -- inside the interval. It stays where it was, which favours the shooter --
    -- the same tie-break every shipped FPS makes, because telling a player their
    -- obviously-landed shot missed feels worse than the reverse.

    self.stats.rewinds = self.stats.rewinds + 1
    return out, clamped
end

---------------------------------------------------------------------------
-- Running something against the rewound world
---------------------------------------------------------------------------

-- Moves `entities` back to `when`, calls fn(), and restores them.
--
-- The restore runs whether or not fn raised. A validation function that throws
-- must not leave every entity in the game standing where it was half a second
-- ago -- that is a far worse bug than the one this file exists to fix, and it
-- would be invisible until someone walked into a wall that was not there.
function HistoryMT:withRewound(when, entities, fn)
    local past = self:positionsAt(when)

    local saved = {}
    local moved = 0

    for i = 1, #entities do
        local e = entities[i]
        local at = e and e.id and past[e.id]
        if at then
            moved = moved + 1
            saved[moved] = { e, e.x, e.y }
            e.x, e.y = at[1], at[2]
        end
    end

    local ok, result, extra = pcall(fn)

    for i = 1, moved do
        local record = saved[i]
        record[1].x, record[1].y = record[2], record[3]
    end

    if not ok then error(result, 0) end
    return result, extra
end

LagComp.HistoryMT = HistoryMT

return LagComp
