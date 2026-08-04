--[[
    meatray.sim.env — the engine as a reinforcement-learning environment.

    The ML-Agents / Gym split, honoured with this engine's laws: the SIM
    stays pure and deterministic in here, and the LEARNING happens wherever
    the trainer lives — the in-tree neuroevolution, or PyTorch on another
    machine talking through scripts/env_server.lua. Either way the contract
    is the episodic one every RL stack speaks:

        env:reset()        -> obs
        env:step(action)   -> obs, reward, done, info

    Observations are the neurobot's senses — whisker raycasts plus goal
    bearings — because an agent trained here must be drivable by the same
    brain format the game runs (Neurobot.load a policy trained anywhere,
    exported as neural1 text). Actions are the neurobot's intents
    { forward, strafe, turn, fire }, applied through Rep.applyInput: the
    same call a keyboard feeds, so a learned policy cannot exploit motion a
    player could not perform.

    The built-in task is navigation: reach the goal (default: the reachable
    tile farthest from spawn). Reward is PROGRESS in walking distance
    (Pathfind.distanceField — euclidean is deceptive around walls), an
    arrival bonus, and a small per-tick cost so arriving sooner scores
    higher. Custom tasks override opts.reward.

    Determinism: same actions from a reset, same episode, to the byte.

    HEADLESS: pure Lua.
]]

local Map = require('meatray.sim.map')
local Pathfind = require('meatray.sim.pathfind')
local Collide = require('meatray.sim.collide')
local Neurobot = require('meatray.game.neurobot')
local Rep = require('meatray.net.replication')

local sqrt, floor = math.sqrt, math.floor

local Env = {}
local EnvMT = {}
EnvMT.__index = EnvMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   mapText    the .map source (or pass opts.world + opts.spawn directly)
--   goal       { x, y } | 'farthest' (default)
--   maxTicks   episode cap (default 720 = 12s at 60Hz)
--   dt         seconds per step (default 1/60)
--   reward     function(env, prevDist, newDist, arrived) -> number (override)
function Env.new(opts)
    opts = opts or {}

    local world, spawn, sourceMap = opts.world, opts.spawn, nil
    if not world then
        assert(opts.mapText, 'Env.new needs mapText or a world')
        local map, errs = Map.parse(opts.mapText)
        assert(map, 'map does not parse: ' .. tostring(errs and errs[1]))
        sourceMap = map
        local w, _, s = Map.toWorld(map)
        world, spawn = w, s
    end
    spawn = spawn or { x = 2.5, y = 2.5, angle = 0 }

    local self = setmetatable({
        world = world,
        sourceMap = sourceMap,   -- lets reset() rebuild pristine world state
        spawn = spawn,
        maxTicks = opts.maxTicks or 720,
        dt = opts.dt or 1 / 60,
        rewardFn = opts.reward,
        senser = Neurobot.new{ seed = 1 },   -- senses only; its brain is unused
        ent = nil,
        tick = 0,
        lastDist = nil,
    }, EnvMT)

    local goal = opts.goal
    if goal == nil or goal == 'farthest' then
        local fromSpawn = Pathfind.distanceField(world, spawn.x, spawn.y)
        goal = { x = fromSpawn.farthestX, y = fromSpawn.farthestY }
    end
    self.goal = goal
    -- Distance TO the goal from everywhere: the reward's ruler.
    self.field = Pathfind.distanceField(world, goal.x, goal.y)
    self.senser:setGoal(goal.x, goal.y)
    return self
end

function EnvMT:observationSize() return Neurobot.SENSES end
function EnvMT:actionSize() return Neurobot.INTENTS end

---------------------------------------------------------------------------
-- The episode
---------------------------------------------------------------------------

-- Walking distance from a position to the goal, continuous. The tile field
-- is integer-valued, and a reward built on it alone is zero for every step
-- that stays inside a tile — an agent learns nothing from a signal that
-- only fires on tile crossings. So the sub-tile term measures progress
-- toward the DESCENDING neighbour (the adjacent tile one step closer): at
-- a tile's centre the value equals the field's, and it falls smoothly as
-- the agent moves the right way. On the goal tile it is simply the
-- straight-line remainder.
function EnvMT:distance(x, y)
    local d = self.field:at(x, y)
    if not d then return 4096 end
    if d == 0 then
        return sqrt((self.goal.x - x) ^ 2 + (self.goal.y - y) ^ 2)
    end

    local tx, ty = floor(x) + 1, floor(y) + 1
    local bestD, bestCX, bestCY = nil, nil, nil
    for _, dir in ipairs{ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
        local nd = self.field.dist[(ty + dir[2]) * 4096 + (tx + dir[1])]
        if nd and (not bestD or nd < bestD) then
            bestD = nd
            bestCX, bestCY = (tx + dir[1]) - 0.5, (ty + dir[2]) - 0.5
        end
    end
    if not bestD or bestD >= d then return d end
    return bestD + sqrt((bestCX - x) ^ 2 + (bestCY - y) ^ 2)
end

function EnvMT:observe()
    return self.senser:sense(self.ent, self.world, nil)
end

function EnvMT:reset()
    -- Episodes must be independent: the door reflex in step() mutates the
    -- world, and an agent whose episode 2 starts with episode 1's doors
    -- standing open is training on leaked state. When the env owns its map
    -- it rebuilds the world; the distance field survives (doors count as
    -- walkable either way, so the topology it measured is unchanged). With
    -- an injected world the caller owns that state — documented, not hidden.
    if self.sourceMap then
        self.world = Map.toWorld(self.sourceMap)
    end
    self.ent = { x = self.spawn.x, y = self.spawn.y,
                 angle = self.spawn.angle or 0, storey = 1 }
    Collide.ground(self.ent, self.world)
    self.tick = 0
    self.lastDist = self:distance(self.ent.x, self.ent.y)
    return self:observe()
end

local function defaultReward(_, prevDist, newDist, arrived)
    local r = (prevDist - newDist) - 0.001      -- progress, minus loitering
    if arrived then r = r + 10 end
    return r
end

-- action: { forward, strafe, turn, fire } — array or keyed, each in [-1,1]
-- (sanitiseInput clamps whatever arrives). Returns obs, reward, done, info.
function EnvMT:step(action)
    assert(self.ent, 'call reset() before step()')
    action = action or {}
    local input = Rep.sanitiseInput{
        forward = action.forward or action[1],
        strafe = action.strafe or action[2],
        turn = action.turn or action[3],
    }
    Rep.applyInput(self.ent, input, self.dt, self.world)

    -- The door reflex the neurobot has: doors are latches, not skills.
    local e = self.ent
    local nx = floor(e.x + math.cos(e.angle) * 0.7) + 1
    local ny = floor(e.y + math.sin(e.angle) * 0.7) + 1
    local door = self.world.doorAt and self.world:doorAt(nx, ny, e.storey)
    if door and not door.open and self.world.toggleDoor then
        self.world:toggleDoor(nx, ny, e.storey)
    end

    self.tick = self.tick + 1
    local newDist = self:distance(e.x, e.y)
    local arrived = sqrt((self.goal.x - e.x) ^ 2 + (self.goal.y - e.y) ^ 2) < 0.7
    local reward = (self.rewardFn or defaultReward)(self, self.lastDist, newDist, arrived)
    self.lastDist = newDist

    local done = arrived or self.tick >= self.maxTicks
    return self:observe(), reward, done, {
        tick = self.tick,
        arrived = arrived,
        x = e.x, y = e.y,
        distance = newDist,
    }
end

return Env
