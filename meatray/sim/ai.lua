--[[
    meatray.sim.ai — host-side behaviours built on pathfind.

        AI.attach(e, { patrol = { {x,y}, ... }, alertRange = 8 })
        -- each tick, on the host only:
        AI.step(e, dt, { world = world, entities = entities, target = player })

    Pathfind is the primitive; this is the glue games otherwise rewrite. Four
    states, deliberately small:

      idle         face home, repath nothing
      patrol       walk a waypoint list (or a generated box around home)
      chase        path to the target while they stay inside loseRange
      cover        step to a nearby tile that breaks line of sight, then hold
      investigate  lost the target: go to last-known position, look around, then
                   fall back to patrol (classic FPS “search last seen”)

    Entirely host-side. Brain is a local component (no netFields): clients see
    the resulting transform through snapshots and never run these decisions.

    HEADLESS: pure Lua.
]]

local Pathfind = require('meatray.sim.pathfind')
local Collide  = require('meatray.sim.collide')
local Billboard = require('meatray.sim.billboard')

local AI = {}

local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local sqrt, cos, sin, pi = math.sqrt, math.cos, math.sin, math.pi
local huge = math.huge

AI.DEFAULT_SPEED = 2.4
AI.DEFAULT_ALERT = 9
AI.DEFAULT_LOSE  = 14
AI.DEFAULT_REPATH = 0.45
AI.DEFAULT_ARRIVE = 0.4
AI.DEFAULT_COVER_RADIUS = 5
AI.DEFAULT_INVESTIGATE_HOLD = 1.6   -- seconds to linger at last-known
AI.DEFAULT_INVESTIGATE_RANGE = 22   -- how far last-known may be and still path
AI.DEFAULT_HEAR = 13   -- C19: a gunshot is heard farther than a body is seen

---------------------------------------------------------------------------
-- Attach / configure
---------------------------------------------------------------------------

-- Fills a Brain component (or creates one) with defaults a game can override.
function AI.attach(e, opts)
    opts = opts or {}
    local brain = e:get('brain')
    if not brain then
        local C = require('meatray.sim.components')
        e:add(C.Brain{})
        brain = e:get('brain')
    end

    brain.state = opts.state or brain.state or 'patrol'
    brain.homeX = opts.homeX or brain.homeX or e.x
    brain.homeY = opts.homeY or brain.homeY or e.y
    brain.speed = opts.speed or brain.speed or AI.DEFAULT_SPEED
    brain.alertRange = opts.alertRange or brain.alertRange or AI.DEFAULT_ALERT
    brain.loseRange = opts.loseRange or brain.loseRange or AI.DEFAULT_LOSE
    brain.repathEvery = opts.repathEvery or brain.repathEvery or AI.DEFAULT_REPATH
    brain.arrive = opts.arrive or brain.arrive or AI.DEFAULT_ARRIVE
    brain.coverRadius = opts.coverRadius or brain.coverRadius or AI.DEFAULT_COVER_RADIUS
    brain.investigateHold = opts.investigateHold or brain.investigateHold
        or AI.DEFAULT_INVESTIGATE_HOLD
    -- When true, chase players on other floors via STAIRS_UP / STAIRS_DOWN.
    if opts.crossStorey ~= nil then
        brain.crossStorey = opts.crossStorey and true or false
    end
    -- When false, losing a chase target returns straight to patrol (old behaviour).
    if opts.investigate ~= nil then
        brain.investigate = opts.investigate and true or false
    elseif brain.investigate == nil then
        brain.investigate = true
    end
    brain.repathIn = 0
    brain.path = nil
    brain.pathIndex = 1
    brain.patrolIndex = 1
    brain.coverX, brain.coverY = nil, nil
    brain.lastKnownX, brain.lastKnownY, brain.lastKnownStorey = nil, nil, nil
    brain.investigateTimer = 0

    if opts.patrol then
        brain.patrol = opts.patrol
    elseif not brain.patrol then
        -- Default: a small square around home so idle maps still move.
        local hx, hy = brain.homeX, brain.homeY
        local r = opts.patrolRadius or 2.5
        brain.patrol = {
            { x = hx + r, y = hy },
            { x = hx,     y = hy + r },
            { x = hx - r, y = hy },
            { x = hx,     y = hy - r },
        }
    end

    return e
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function dist(ax, ay, bx, by)
    return sqrt(dist2(ax, ay, bx, by))
end

-- Nearest living entity with a player component, or opts.target if given.
-- Same-storey by default (AI does not shoot through floors). Overrides:
--   opts.anyStorey / opts.crossStorey  — consider every floor
--   opts.storey                        — filter relative to this layer
function AI.findTarget(e, entities, opts)
    opts = opts or {}
    local any = opts.anyStorey or opts.crossStorey
    local range = opts.alertRange or AI.DEFAULT_ALERT
    local r2 = range * range
    local storey = opts.storey or e.storey or 1

    -- Explicit target still respects range and storey (a "lock" that ignores
    -- distance made investigate impossible: the host always passed last prey).
    if opts.target and not opts.target.dead then
        local o = opts.target
        if not any and (o.storey or 1) ~= storey then return nil end
        local d = dist2(e.x, e.y, o.x, o.y)
        if d <= r2 then return o end
        return nil
    end

    local best, bestD = nil, huge
    for i = 1, #(entities or {}) do
        local o = entities[i]
        if o and o ~= e and not o.dead and o:has('player')
           and (any or (o.storey or 1) == storey) then
            local d = dist2(e.x, e.y, o.x, o.y)
            -- Slight preference for same-floor targets when cross-storey is on.
            if any and (o.storey or 1) ~= storey then
                d = d + 4
            end
            if d < bestD and d <= r2 then
                best, bestD = o, d
            end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- C19: hearing. Sight finds a target you can see; hearing sends you toward a
-- NOISE you cannot — a gunshot in the next room, an explosion down the hall. It
-- drives the same investigate state the lost-a-target search uses, so a heard
-- AI walks to the sound, looks around, and falls back to patrol if nothing is
-- there. What it does NOT do is reveal the target: hearing gives a place to
-- look, not a lock. Sight at that place is what starts a chase.
---------------------------------------------------------------------------

-- One AI hears a sound at (sx,sy). Returns true if it reacted (went to
-- investigate). opts.range overrides the hearing radius; opts.loudness scales it
-- (a rocket carries farther than a footstep); opts.force makes even a
-- non-investigating AI react.
function AI.hear(e, sx, sy, storey, opts)
    opts = opts or {}
    local brain = e and e.get and e:get('brain')
    if not brain or e.dead then return false end

    -- A live lead beats a distant noise: an AI already chasing or taking cover
    -- does not abandon a seen target to wander toward a sound.
    if brain.state == 'chase' or brain.state == 'cover' then return false end
    -- A deaf/non-investigating AI ignores sound unless forced.
    if brain.investigate == false and not opts.force then return false end

    local sStorey = storey or e.storey or 1
    local sameStorey = (e.storey or 1) == sStorey
    if not sameStorey and not (brain.crossStorey or opts.crossStorey) then
        return false
    end

    local range = (opts.range or brain.hearRange or AI.DEFAULT_HEAR)
                  * (opts.loudness or 1)
    -- A sound on another floor is muffled — heard at half the distance.
    if not sameStorey then range = range * 0.5 end
    if dist2(e.x, e.y, sx, sy) > range * range then return false end

    -- Investigate the noise. This is the same machinery a lost target uses, so
    -- the AI paths there, searches, and times out to patrol on its own.
    brain.lastKnownX, brain.lastKnownY, brain.lastKnownStorey = sx, sy, sStorey
    brain.state = 'investigate'
    brain.investigateTimer = 0
    brain.path = nil
    brain.pathIndex = 1
    brain.repathIn = 0
    return true
end

-- Every brained non-player entity hears a sound at once — what the game calls
-- on a gunshot or an explosion. Returns how many reacted.
function AI.broadcastSound(entities, sx, sy, storey, opts)
    local reacted = 0
    for i = 1, #(entities or {}) do
        local e = entities[i]
        if e and e.has and e:has('brain') and not e:has('player') then
            if AI.hear(e, sx, sy, storey, opts) then reacted = reacted + 1 end
        end
    end
    return reacted
end

-- True when nothing solid blocks the segment from a to b on the given storey.
function AI.hasLineOfSight(world, ax, ay, bx, by, storey)
    if not world then return true end
    return Collide.lineOfSight(world, ax, ay, bx, by, storey or 1)
end

-- Walkable tile near `near` that breaks LOS to `threat`. Cheap spiral; cover
-- is "something to duck behind", not perfect tactical search.
-- Optional 6th arg storey (or opts table as 6th: { storey = n, radius = r }).
function AI.findCover(world, nearX, nearY, threatX, threatY, radius, storey)
    if not world then return nil end
    if type(radius) == 'table' then
        storey = radius.storey or storey
        radius = radius.radius or AI.DEFAULT_COVER_RADIUS
    end
    radius = radius or AI.DEFAULT_COVER_RADIUS
    storey = storey or 1
    local ctx, cty = floor(nearX) + 1, floor(nearY) + 1
    local best, bestScore = nil, huge

    for r = 1, radius do
        for dy = -r, r do
            for dx = -r, r do
                if abs(dx) == r or abs(dy) == r then
                    local tx, ty = ctx + dx, cty + dy
                    if world:inBounds(tx, ty) and world:isWalkable(tx, ty, storey) then
                        local x, y = tx - 0.5, ty - 0.5
                        if not AI.hasLineOfSight(world, x, y, threatX, threatY, storey) then
                            -- Prefer cover that is close to self and still near threat.
                            local score = dist2(nearX, nearY, x, y)
                                          + 0.35 * dist2(x, y, threatX, threatY)
                            if score < bestScore then
                                bestScore = score
                                best = { x = x, y = y }
                            end
                        end
                    end
                end
            end
        end
        if best then return best.x, best.y end
    end
    return nil
end

---------------------------------------------------------------------------
-- Movement along a path
---------------------------------------------------------------------------

local function repath(brain, world, fromX, fromY, toX, toY, fromStorey, toStorey)
    fromStorey = fromStorey or 1
    toStorey = toStorey or fromStorey
    local cross = brain.crossStorey or (fromStorey ~= toStorey)
    local opts = {
        storey = fromStorey,
        fromStorey = fromStorey,
        toStorey = toStorey,
        crossStorey = cross,
    }
    local path = Pathfind.find(world, fromX, fromY, toX, toY, opts)
    if path then
        -- Simplify per storey segment so we do not cut through floors.
        if not cross or fromStorey == toStorey then
            path = Pathfind.simplify(world, path, opts)
        else
            -- Simplify contiguous same-storey runs only.
            local out = {}
            local i = 1
            while i <= #path do
                local s = path[i].storey or 1
                local j = i
                while j <= #path and (path[j].storey or 1) == s do j = j + 1 end
                local segment = {}
                for k = i, j - 1 do segment[#segment + 1] = path[k] end
                local plane = { storey = s }
                segment = Pathfind.simplify(world, segment, plane)
                for k = 1, #segment do out[#out + 1] = segment[k] end
                i = j
            end
            path = out
        end
    end
    brain.path = path
    brain.pathIndex = 1
    brain.repathIn = brain.repathEvery or AI.DEFAULT_REPATH
    brain._goalStorey = toStorey
    return path ~= nil
end

local function steer(e, brain, dt, world, goalX, goalY, goalStorey)
    if not world then return false end

    local fromS = e.storey or 1
    local toS = goalStorey or fromS
    brain.repathIn = (brain.repathIn or 0) - dt
    local need = not brain.path or brain.repathIn <= 0
                 or (brain._goalStorey and brain._goalStorey ~= toS)
    if need then
        repath(brain, world, e.x, e.y, goalX, goalY, fromS, toS)
    end
    if not brain.path then return false end

    local wx, wy, idx, wStorey = Pathfind.nextWaypoint(
        brain.path, e.x, e.y, brain.arrive or AI.DEFAULT_ARRIVE,
        brain.pathIndex, e.storey or 1)
    if not wx then
        brain.path = nil
        return true -- arrived
    end
    brain.pathIndex = idx

    -- Stairs step: waypoint is on another floor (often same xy). Take it when
    -- close enough on this floor, then re-ground.
    if wStorey and wStorey ~= (e.storey or 1) then
        local dx, dy = e.x - wx, e.y - wy
        local arrive = brain.arrive or AI.DEFAULT_ARRIVE
        if dx * dx + dy * dy <= arrive * arrive then
            e.storey = wStorey
            Collide.ground(e, world)
            return false
        end
    end

    local dx, dy = wx - e.x, wy - e.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return false end
    local speed = brain.speed or AI.DEFAULT_SPEED
    local step = min(speed * dt, len)
    dx, dy = dx / len * step, dy / len * step
    Collide.move(e, dx, dy, world)
    e.angle = Billboard.bearing(e.x, e.y, wx, wy)
    return false
end

---------------------------------------------------------------------------
-- State machine
---------------------------------------------------------------------------

local function setState(brain, state)
    if brain.state == state then return end
    brain.state = state
    brain.path = nil
    brain.pathIndex = 1
    brain.repathIn = 0
    if state ~= 'cover' then
        brain.coverX, brain.coverY = nil, nil
    end
    if state ~= 'investigate' then
        brain.investigateTimer = 0
    end
end

local function rememberTarget(brain, target)
    if not target then return end
    brain.lastKnownX = target.x
    brain.lastKnownY = target.y
    brain.lastKnownStorey = target.storey or 1
end

local function loseToInvestigateOrPatrol(brain)
    if brain.investigate ~= false
       and brain.lastKnownX and brain.lastKnownY then
        setState(brain, 'investigate')
    else
        setState(brain, 'patrol')
    end
end

local function targetOpts(e, brain, ctx, range)
    return {
        target = ctx.target,
        alertRange = range or brain.alertRange,
        crossStorey = brain.crossStorey,
    }
end

local function stepIdle(e, brain, dt, ctx)
    e.angle = e.angle or 0
    local target = AI.findTarget(e, ctx.entities, targetOpts(e, brain, ctx))
    if target then
        setState(brain, 'chase')
        return
    end
    -- Idle occasionally returns to patrol so maps stay alive.
    if brain.patrol and #brain.patrol > 0 then
        setState(brain, 'patrol')
    end
end

local function stepPatrol(e, brain, dt, ctx)
    local target = AI.findTarget(e, ctx.entities, targetOpts(e, brain, ctx))
    if target then
        setState(brain, 'chase')
        return
    end

    local pts = brain.patrol
    if not pts or #pts == 0 then
        setState(brain, 'idle')
        return
    end

    local i = brain.patrolIndex or 1
    if i < 1 or i > #pts then i = 1 end
    local goal = pts[i]
    local arrived = steer(e, brain, dt, ctx.world, goal.x, goal.y, goal.storey or e.storey)
    if arrived then
        brain.patrolIndex = (i % #pts) + 1
        brain.path = nil
    end
end

local function stepChase(e, brain, dt, ctx)
    local target = AI.findTarget(e, ctx.entities, targetOpts(e, brain, ctx,
        brain.loseRange or AI.DEFAULT_LOSE))
    if not target then
        loseToInvestigateOrPatrol(brain)
        return
    end

    rememberTarget(brain, target)

    local storey = e.storey or 1
    local tStorey = target.storey or 1
    local d = dist(e.x, e.y, target.x, target.y)
    -- Cover only when we share a floor and the target can still see us.
    local health = e:get('health')
    local hurt = health and health.max and health.hp < health.max * 0.45
    if hurt and tStorey == storey
       and AI.hasLineOfSight(ctx.world, e.x, e.y, target.x, target.y, storey)
       and d < (brain.alertRange or AI.DEFAULT_ALERT) then
        setState(brain, 'cover')
        return
    end

    e.angle = Billboard.bearing(e.x, e.y, target.x, target.y)
    steer(e, brain, dt, ctx.world, target.x, target.y, tStorey)
end

local function stepCover(e, brain, dt, ctx)
    local target = AI.findTarget(e, ctx.entities, targetOpts(e, brain, ctx,
        brain.loseRange or AI.DEFAULT_LOSE))
    if not target then
        loseToInvestigateOrPatrol(brain)
        return
    end

    rememberTarget(brain, target)

    local storey = e.storey or 1
    -- Cover is same-floor only; if the target left the floor, resume chase.
    if (target.storey or 1) ~= storey then
        setState(brain, 'chase')
        return
    end

    if not brain.coverX then
        local cx, cy = AI.findCover(ctx.world, e.x, e.y, target.x, target.y,
                                    brain.coverRadius, storey)
        if not cx then
            setState(brain, 'chase')
            return
        end
        brain.coverX, brain.coverY = cx, cy
    end

    local arrived = steer(e, brain, dt, ctx.world, brain.coverX, brain.coverY, storey)
    e.angle = Billboard.bearing(e.x, e.y, target.x, target.y)

    if arrived then
        -- Hold cover until healthy enough or target is gone from LOS.
        local health = e:get('health')
        local ok = health and health.max and health.hp >= health.max * 0.7
        local hidden = not AI.hasLineOfSight(ctx.world, e.x, e.y, target.x, target.y, storey)
        if ok or not hidden then
            setState(brain, 'chase')
        end
    end
end

-- Walk to last-known player position; re-acquire if they re-enter alert range.
local function stepInvestigate(e, brain, dt, ctx)
    local target = AI.findTarget(e, ctx.entities, targetOpts(e, brain, ctx))
    if target then
        rememberTarget(brain, target)
        setState(brain, 'chase')
        return
    end

    local lx, ly = brain.lastKnownX, brain.lastKnownY
    local ls = brain.lastKnownStorey or e.storey or 1
    if not lx or not ly then
        setState(brain, 'patrol')
        return
    end

    local d = dist(e.x, e.y, lx, ly)
    if d > (brain.loseRange or AI.DEFAULT_INVESTIGATE_RANGE) * 1.5 then
        -- Last known is absurdly far (teleport / storey desync); give up.
        brain.lastKnownX, brain.lastKnownY = nil, nil
        setState(brain, 'patrol')
        return
    end

    if d > (brain.arrive or AI.DEFAULT_ARRIVE) * 1.5 then
        e.angle = Billboard.bearing(e.x, e.y, lx, ly)
        steer(e, brain, dt, ctx.world, lx, ly, ls)
        return
    end

    -- Arrived: scan in place, then return to the beat.
    brain.investigateTimer = (brain.investigateTimer or 0) + dt
    e.angle = (e.angle or 0) + dt * 1.8
    if brain.investigateTimer >= (brain.investigateHold or AI.DEFAULT_INVESTIGATE_HOLD) then
        brain.lastKnownX, brain.lastKnownY, brain.lastKnownStorey = nil, nil, nil
        setState(brain, 'patrol')
    end
end

local handlers = {
    idle = stepIdle,
    patrol = stepPatrol,
    chase = stepChase,
    cover = stepCover,
    investigate = stepInvestigate,
}

-- One simulation step for a single entity that has a brain. No-ops if there is
-- no brain or the entity is dead. ctx: world, entities, target (optional).
function AI.step(e, dt, ctx)
    if not e or e.dead then return end
    local brain = e:get('brain')
    if not brain then return end
    ctx = ctx or {}
    dt = dt or 0

    local state = brain.state or 'idle'
    local fn = handlers[state] or stepIdle
    fn(e, brain, dt, ctx)
end

-- Convenience: step every entity that has a brain.
function AI.stepAll(entities, dt, ctx)
    ctx = ctx or {}
    for i = 1, #(entities or {}) do
        local e = entities[i]
        if e and e:has('brain') then
            AI.step(e, dt, ctx)
        end
    end
end

return AI
