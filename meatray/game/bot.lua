--[[
    meatray.game.bot — a player the computer drives (C22).

    A bot is not an AI monster with a gun. A monster IS its behaviour: the sim
    moves it directly. A bot instead produces the same INPUT a human does —
    `{ forward, strafe, angle }` plus a fire and a use intent — and that input
    goes through the identical Rep.applyInput the keyboard feeds. That is the
    whole design: a bot that plays the game rather than one the game plays. It
    respects walls because collision does, it cannot fire through a cooldown
    because the weapon tick owns the cooldown, and it desyncs no more than a
    real client because it produces nothing a real client could not.

        local Bot = require('meatray.game.bot')
        local b = Bot.new{ seed = 7, range = 12, fireRange = 8 }

        -- on the host tick, once per bot:
        local intent = b:think(self, world, entities, dt)
        Rep.applyInput(self, Rep.sanitiseInput(intent.input), dt, world, opts)
        if intent.fire then resolveFire(world, entities, self, intent.input.angle) end
        if intent.use and intent.useDoor then world:toggleDoor(...) end

    The behaviour is deliberately legible, not clever: find the nearest living
    player; if it can be seen and is close, face it and fire while strafing so
    the bot is not a stationary target; otherwise path to it and walk the
    waypoints, and if a shut door blocks the next step, ask to open it. With no
    target, wander toward a random reachable point. Cleverer tactics are a
    later problem; a bot that fills a lobby and fights is the parity gap, and
    this closes it.

    Determinism: every random choice (a wander goal, a strafe flip) comes from
    the engine LCG seeded per bot, never math.random — a bot on the host is
    inside the demo-recording stream, and a bot that consulted math.random
    would be the one thing a replay could not reproduce.

    HEADLESS: pure Lua.
]]

local Worldgen = require('meatray.sim.worldgen')
local Pathfind = require('meatray.sim.pathfind')
local AI       = require('meatray.sim.ai')
local World    = require('meatray.sim.world')

-- A bot knows it can open doors, so it paths as if they were open — a shut
-- door on the route is a step to take (and doorAhead then asks to open it),
-- not a wall to detour a mile around. Without this a bot on the far side of
-- the only door in a wall finds NO path and freezes.
local function botWalkable(world, tx, ty)
    if world:doorAt(tx, ty) then return true end
    return not world:isSolid(tx, ty)
end

local Bot = {}
local BotMT = {}
BotMT.__index = BotMT

local atan2 = math.atan2 or math.atan
local cos, sin, sqrt = math.cos, math.sin, math.sqrt
local pi = math.pi

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   seed        per-bot LCG seed (default 1) — determinism
--   range       how far it looks for a target (default 14)
--   fireRange   how close before it shoots (default 9)
--   repath      seconds between path recomputes while chasing (default 0.5)
--   strafeFlip  seconds between strafe direction flips in a fight (default 0.8)
function Bot.new(opts)
    opts = opts or {}
    return setmetatable({
        rng = Worldgen.rng(tonumber(opts.seed) or 1),
        range = opts.range or 14,
        fireRange = opts.fireRange or 9,
        repathEvery = opts.repath or 0.5,
        strafeFlipEvery = opts.strafeFlip or 0.8,

        path = nil,
        pathIndex = 1,
        repathIn = 0,
        strafeDir = 1,
        strafeIn = 0,
        wanderGoal = nil,      -- { x, y } when there is no target
    }, BotMT)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function angleTo(fromX, fromY, toX, toY)
    return atan2(toY - fromY, toX - fromX)
end

-- Converts a desired WORLD-space move direction into the (forward, strafe)
-- pair Rep.applyInput reads, given the facing the bot has chosen. This is the
-- step that makes the bot use the same input a human does: a human's W is
-- "forward along my facing", and this projects the world goal onto that frame.
local function moveInput(facing, worldDX, worldDY)
    local len = sqrt(worldDX * worldDX + worldDY * worldDY)
    if len < 1e-6 then return 0, 0 end
    worldDX, worldDY = worldDX / len, worldDY / len
    local fx, fy = cos(facing), sin(facing)
    local sx, sy = -sin(facing), cos(facing)     -- facing's left
    local forward = worldDX * fx + worldDY * fy
    local strafe  = worldDX * sx + worldDY * sy
    return forward, strafe
end

-- A random walkable tile within `radius` of (x,y) on the storey, or nil.
local function wanderPoint(self, world, x, y, storey, radius)
    for _ = 1, 12 do
        local ang = self.rng:float() * 2 * pi
        local d = 2 + self.rng:float() * radius
        local tx = math.floor(x + cos(ang) * d) + 1
        local ty = math.floor(y + sin(ang) * d) + 1
        if tx >= 1 and ty >= 1 and tx <= world.width and ty <= world.height
           and not world:isSolid(tx, ty, storey) then
            return { x = tx - 0.5, y = ty - 0.5 }
        end
    end
    return nil
end

-- The door blocking the step from (x,y) toward (gx,gy), if the next tile that
-- way is a shut door. Returns tx, ty or nil.
local function doorAhead(world, x, y, gx, gy, storey)
    local dx, dy = gx - x, gy - y
    local len = sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return nil end
    local nx = math.floor(x + dx / len * 0.7) + 1
    local ny = math.floor(y + dy / len * 0.7) + 1
    local door = world.doorAt and world:doorAt(nx, ny, storey)
    if door and not door.open then return nx, ny end
    return nil
end

---------------------------------------------------------------------------
-- The one call the host makes
---------------------------------------------------------------------------

-- Returns { input = { forward, strafe, angle }, fire = bool, use = bool,
-- useDoor = { tx, ty } | nil }. The caller feeds input to Rep.applyInput and
-- acts on fire/use — exactly as it would for a network client's command.
function BotMT:think(ent, world, entities, dt)
    dt = math.max(0, tonumber(dt) or 0)
    local sx, sy = ent.x or 0, ent.y or 0
    local storey = ent.storey or 1
    local out = { input = { forward = 0, strafe = 0, angle = ent.angle or 0 },
                  fire = false, use = false }

    if not world then return out end

    -- Who to chase: the nearest living player that is not us.
    local target = AI.findTarget(ent, entities, {
        alertRange = self.range, storey = storey,
    })

    if target then
        self.wanderGoal = nil
        local d = sqrt((target.x - sx) ^ 2 + (target.y - sy) ^ 2)
        local see = AI.hasLineOfSight(world, sx, sy, target.x, target.y, storey)

        if see and d <= self.fireRange then
            -- In the fight: face the target, fire, and strafe so as not to be
            -- a still target. Strafe flips on a timer, deterministically.
            out.input.angle = angleTo(sx, sy, target.x, target.y)
            self.strafeIn = self.strafeIn - dt
            if self.strafeIn <= 0 then
                self.strafeIn = self.strafeFlipEvery
                self.strafeDir = -self.strafeDir
                if self.rng:float() < 0.25 then self.strafeDir = 0 end  -- sometimes hold
            end
            out.input.strafe = self.strafeDir
            -- Close the distance a little if far within fire range.
            if d > self.fireRange * 0.6 then out.input.forward = 0.5 end
            out.fire = true
            self.path = nil
            return out
        end

        -- Seen but far, or not seen: path to the target.
        self.repathIn = self.repathIn - dt
        if not self.path or self.repathIn <= 0 then
            self.repathIn = self.repathEvery
            self.path = Pathfind.find(world, sx, sy, target.x, target.y,
                                      { storey = storey, walkable = botWalkable })
            self.pathIndex = 1
        end
        return self:follow(ent, world, storey, out)
    end

    -- No target: wander. Pick a reachable goal, walk to it, pick another when
    -- close or stuck.
    if not self.wanderGoal
       or ((self.wanderGoal.x - sx) ^ 2 + (self.wanderGoal.y - sy) ^ 2) < 0.5 then
        self.wanderGoal = wanderPoint(self, world, sx, sy, storey, 8)
        self.path = nil
    end
    if self.wanderGoal then
        self.repathIn = self.repathIn - dt
        if not self.path or self.repathIn <= 0 then
            self.repathIn = self.repathEvery
            self.path = Pathfind.find(world, sx, sy,
                                      self.wanderGoal.x, self.wanderGoal.y,
                                      { storey = storey, walkable = botWalkable })
            self.pathIndex = 1
        end
        return self:follow(ent, world, storey, out)
    end

    return out
end

-- Walks the current path: face and move toward the next waypoint, and ask to
-- open a shut door if one is the next step. Shared by chase and wander.
function BotMT:follow(ent, world, storey, out)
    local sx, sy = ent.x or 0, ent.y or 0
    if not self.path or #self.path == 0 then return out end

    local wx, wy, idx = Pathfind.nextWaypoint(self.path, sx, sy, 0.4,
                                              self.pathIndex, storey)
    if not wx then
        self.path = nil
        return out
    end
    self.pathIndex = idx

    out.input.angle = angleTo(sx, sy, wx, wy)
    local f, s = moveInput(out.input.angle, wx - sx, wy - sy)
    out.input.forward = f
    out.input.strafe = s

    local dtx, dty = doorAhead(world, sx, sy, wx, wy, storey)
    if dtx then
        out.use = true
        out.useDoor = { tx = dtx, ty = dty }
    end
    return out
end

return Bot
