--[[
    meatray.sim.ai — host-side behaviours built on pathfind.

        AI.attach(e, { patrol = { {x,y}, ... }, alertRange = 8 })
        -- each tick, on the host only:
        AI.step(e, dt, { world = world, entities = entities, target = player })

    Pathfind is the primitive; this is the glue games otherwise rewrite. Four
    states, deliberately small:

      idle    face home, repath nothing
      patrol  walk a waypoint list (or a generated box around home)
      chase   path to the target while they stay inside loseRange
      cover   step to a nearby tile that breaks line of sight, then hold

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
    brain.repathIn = 0
    brain.path = nil
    brain.pathIndex = 1
    brain.patrolIndex = 1
    brain.coverX, brain.coverY = nil, nil

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
function AI.findTarget(e, entities, opts)
    opts = opts or {}
    if opts.target and not opts.target.dead then return opts.target end
    local best, bestD = nil, huge
    local range = opts.alertRange or AI.DEFAULT_ALERT
    local r2 = range * range
    for i = 1, #(entities or {}) do
        local o = entities[i]
        if o and o ~= e and not o.dead and o:has('player') then
            local d = dist2(e.x, e.y, o.x, o.y)
            if d < bestD and d <= r2 then
                best, bestD = o, d
            end
        end
    end
    return best
end

-- True when nothing solid blocks the segment from a to b.
function AI.hasLineOfSight(world, ax, ay, bx, by)
    if not world then return true end
    return Collide.lineOfSight(world, ax, ay, bx, by)
end

-- Walkable tile near `near` that breaks LOS to `threat`. Cheap spiral; cover
-- is "something to duck behind", not perfect tactical search.
function AI.findCover(world, nearX, nearY, threatX, threatY, radius)
    if not world then return nil end
    radius = radius or AI.DEFAULT_COVER_RADIUS
    local ctx, cty = floor(nearX) + 1, floor(nearY) + 1
    local best, bestScore = nil, huge

    for r = 1, radius do
        for dy = -r, r do
            for dx = -r, r do
                if abs(dx) == r or abs(dy) == r then
                    local tx, ty = ctx + dx, cty + dy
                    if world:inBounds(tx, ty) and world:isWalkable(tx, ty) then
                        local x, y = tx - 0.5, ty - 0.5
                        if not AI.hasLineOfSight(world, x, y, threatX, threatY) then
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

local function repath(brain, world, fromX, fromY, toX, toY)
    local path = Pathfind.find(world, fromX, fromY, toX, toY)
    if path then
        path = Pathfind.simplify(world, path)
    end
    brain.path = path
    brain.pathIndex = 1
    brain.repathIn = brain.repathEvery or AI.DEFAULT_REPATH
    return path ~= nil
end

local function steer(e, brain, dt, world, goalX, goalY)
    if not world then return false end

    brain.repathIn = (brain.repathIn or 0) - dt
    local need = not brain.path or brain.repathIn <= 0
    if need then
        repath(brain, world, e.x, e.y, goalX, goalY)
    end
    if not brain.path then return false end

    local wx, wy, idx = Pathfind.nextWaypoint(
        brain.path, e.x, e.y, brain.arrive or AI.DEFAULT_ARRIVE, brain.pathIndex)
    if not wx then
        brain.path = nil
        return true -- arrived
    end
    brain.pathIndex = idx

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
end

local function stepIdle(e, brain, dt, ctx)
    e.angle = e.angle or 0
    local target = AI.findTarget(e, ctx.entities, {
        target = ctx.target, alertRange = brain.alertRange,
    })
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
    local target = AI.findTarget(e, ctx.entities, {
        target = ctx.target, alertRange = brain.alertRange,
    })
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
    local arrived = steer(e, brain, dt, ctx.world, goal.x, goal.y)
    if arrived then
        brain.patrolIndex = (i % #pts) + 1
        brain.path = nil
    end
end

local function stepChase(e, brain, dt, ctx)
    local target = AI.findTarget(e, ctx.entities, {
        target = ctx.target,
        alertRange = brain.loseRange or AI.DEFAULT_LOSE,
    })
    if not target then
        setState(brain, 'patrol')
        return
    end

    local d = dist(e.x, e.y, target.x, target.y)
    -- Take cover when hurt and the target can still see us.
    local health = e:get('health')
    local hurt = health and health.max and health.hp < health.max * 0.45
    if hurt and AI.hasLineOfSight(ctx.world, e.x, e.y, target.x, target.y)
       and d < (brain.alertRange or AI.DEFAULT_ALERT) then
        setState(brain, 'cover')
        return
    end

    e.angle = Billboard.bearing(e.x, e.y, target.x, target.y)
    steer(e, brain, dt, ctx.world, target.x, target.y)
end

local function stepCover(e, brain, dt, ctx)
    local target = AI.findTarget(e, ctx.entities, {
        target = ctx.target,
        alertRange = brain.loseRange or AI.DEFAULT_LOSE,
    })
    if not target then
        setState(brain, 'patrol')
        return
    end

    if not brain.coverX then
        local cx, cy = AI.findCover(ctx.world, e.x, e.y, target.x, target.y,
                                    brain.coverRadius)
        if not cx then
            setState(brain, 'chase')
            return
        end
        brain.coverX, brain.coverY = cx, cy
    end

    local arrived = steer(e, brain, dt, ctx.world, brain.coverX, brain.coverY)
    e.angle = Billboard.bearing(e.x, e.y, target.x, target.y)

    if arrived then
        -- Hold cover until healthy enough or target is gone from LOS.
        local health = e:get('health')
        local ok = health and health.max and health.hp >= health.max * 0.7
        local hidden = not AI.hasLineOfSight(ctx.world, e.x, e.y, target.x, target.y)
        if ok or not hidden then
            setState(brain, 'chase')
        end
    end
end

local handlers = {
    idle = stepIdle,
    patrol = stepPatrol,
    chase = stepChase,
    cover = stepCover,
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
