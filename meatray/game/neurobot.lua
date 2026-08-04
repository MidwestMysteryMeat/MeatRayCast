--[[
    meatray.game.neurobot — a machine-learning agent behind the bot contract.

    Same law as C22: a neurobot produces INPUT, never motion. The difference
    is what fills the intent — where Bot runs hand-written rules, this runs a
    neural net (meatray.sim.neural). Everything around the net is fixed and
    legible; only the mapping from senses to intent is learned.

    Senses (the net's input layer, every value in [-1, 1]):

        whiskers    N ray distances fanned across the facing (walls via
                    Collide.rayTile), 1 = touching, -1 = nothing in range
        goal        bearing (signed, facing-relative) and distance to the
                    current goal point, zeros when there is none
        target      bearing/distance/visibility of the nearest other player,
                    zeros when none — the fighting senses
        bias        constant 1

    Intent (the net's output layer): forward, strafe, turn, fire — the first
    three signed unit values, fire a threshold on the fourth. Turn is a RATE
    (radians/s scaled by turnSpeed), because a net that must output an
    absolute world angle has to learn trigonometry before it can learn play.

    Train it either way the neural module supports: evolve navigation brains
    with scripts/evolve.lua (fitness = progress toward a goal), or imitate a
    recorded demo's input stream with net:train. A brain is a text blob a
    project commits; Neurobot.load reads one back.

    HEADLESS: pure Lua.
]]

local Neural = require('meatray.sim.neural')
local Collide = require('meatray.sim.collide')
local AI = require('meatray.sim.ai')

local cos, sin, sqrt, floor = math.cos, math.sin, math.sqrt, math.floor
local pi = math.pi
local atan2 = math.atan2 or math.atan

local Neurobot = {}
local NeurobotMT = {}
NeurobotMT.__index = NeurobotMT

Neurobot.WHISKERS = 5          -- rays across the fan
Neurobot.FAN = pi * 0.8        -- total fan width, radians
Neurobot.WHISKER_RANGE = 8     -- tiles
Neurobot.SENSES = Neurobot.WHISKERS + 6   -- + goal(2) + target(3) + bias(1)
Neurobot.INTENTS = 4           -- forward, strafe, turn, fire

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts: brain (a Neural net — topology must fit SENSES/INTENTS), seed (fresh
-- random brain when none given), hidden (default 12), turnSpeed rad/s
-- (default 3), fireThreshold (default 0.5), range (target search, default 14)
function Neurobot.new(opts)
    opts = opts or {}
    local brain = opts.brain or Neural.new{
        layers = { Neurobot.SENSES, opts.hidden or 12, Neurobot.INTENTS },
        seed = opts.seed or 1,
    }
    assert(brain.layers[1] == Neurobot.SENSES
           and brain.layers[#brain.layers] == Neurobot.INTENTS,
        'brain topology must be ' .. Neurobot.SENSES .. ' -> ... -> ' .. Neurobot.INTENTS)
    return setmetatable({
        brain = brain,
        turnSpeed = opts.turnSpeed or 3,
        fireThreshold = opts.fireThreshold or 0.5,
        range = opts.range or 14,
        goal = nil,             -- { x, y } — navigation tasks set this
    }, NeurobotMT)
end

function Neurobot.load(text, opts)
    local brain, err = Neural.deserialize(text)
    if not brain then return nil, err end
    opts = opts or {}
    opts.brain = brain
    local ok, botOrErr = pcall(Neurobot.new, opts)
    if not ok then return nil, botOrErr end
    return botOrErr
end

function NeurobotMT:setGoal(x, y)
    self.goal = x and { x = x, y = y } or nil
end

---------------------------------------------------------------------------
-- Senses
---------------------------------------------------------------------------

-- Signed shortest-way bearing from `facing` to the direction of (dx, dy),
-- scaled to [-1, 1] (±pi maps to ±1).
local function bearing(facing, dx, dy)
    local want = atan2(dy, dx)
    local diff = want - facing
    while diff > pi do diff = diff - 2 * pi end
    while diff < -pi do diff = diff + 2 * pi end
    return diff / pi
end

-- The senses vector for an entity in a world. Public so a trainer can call
-- it directly — training must see exactly what play sees.
function NeurobotMT:sense(ent, world, entities)
    local sx, sy = ent.x or 0, ent.y or 0
    local facing = ent.angle or 0
    local storey = ent.storey or 1
    local senses = {}

    -- Whisker fan: nearest wall along each ray, near = high.
    for w = 1, Neurobot.WHISKERS do
        local t = (w - 1) / (Neurobot.WHISKERS - 1) - 0.5    -- -0.5 .. 0.5
        local ang = facing + t * Neurobot.FAN
        local dist = Collide.rayTile(world, sx, sy, cos(ang), sin(ang),
                                     Neurobot.WHISKER_RANGE, storey)
        if dist and dist < Neurobot.WHISKER_RANGE then
            senses[#senses + 1] = 1 - 2 * (dist / Neurobot.WHISKER_RANGE)
        else
            senses[#senses + 1] = -1
        end
    end

    -- Goal bearing and closeness.
    if self.goal then
        local dx, dy = self.goal.x - sx, self.goal.y - sy
        local d = sqrt(dx * dx + dy * dy)
        senses[#senses + 1] = bearing(facing, dx, dy)
        senses[#senses + 1] = 1 - 2 * math.min(d / 20, 1)   -- close = high
    else
        senses[#senses + 1] = 0
        senses[#senses + 1] = 0
    end

    -- Nearest other player: the fighting senses.
    local target = entities and AI.findTarget(ent, entities, {
        alertRange = self.range, storey = storey,
    }) or nil
    if target then
        local dx, dy = target.x - sx, target.y - sy
        local d = sqrt(dx * dx + dy * dy)
        senses[#senses + 1] = bearing(facing, dx, dy)
        senses[#senses + 1] = 1 - 2 * math.min(d / self.range, 1)
        senses[#senses + 1] = AI.hasLineOfSight(world, sx, sy, target.x, target.y, storey)
                              and 1 or -1
    else
        senses[#senses + 1] = 0
        senses[#senses + 1] = 0
        senses[#senses + 1] = -1
    end

    senses[#senses + 1] = 1     -- bias
    return senses
end

---------------------------------------------------------------------------
-- The bot contract
---------------------------------------------------------------------------

-- Same shape Bot:think returns; the host treats the two identically.
function NeurobotMT:think(ent, world, entities, dt)
    dt = math.max(0, tonumber(dt) or 0)
    local out = { input = { forward = 0, strafe = 0, angle = ent.angle or 0 },
                  fire = false, use = false }
    if not world then return out end

    local intents = self.brain:forward(self:sense(ent, world, entities))

    out.input.forward = intents[1]
    out.input.strafe = intents[2]
    out.input.angle = (ent.angle or 0) + intents[3] * self.turnSpeed * dt
    out.fire = intents[4] > self.fireThreshold

    -- One reflex stays wired-in: a shut door dead ahead gets a use request.
    -- Doors are a latch, not a motion skill — making a net learn "press F"
    -- teaches it nothing and makes every training run start with a wall.
    local nx = floor((ent.x or 0) + cos(out.input.angle) * 0.7) + 1
    local ny = floor((ent.y or 0) + sin(out.input.angle) * 0.7) + 1
    local door = world.doorAt and world:doorAt(nx, ny, ent.storey or 1)
    if door and not door.open then
        out.use = true
        out.useDoor = { tx = nx, ty = ny }
    end

    return out
end

return Neurobot
