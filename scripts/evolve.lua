--[[
    Neuroevolution trainer: breed navigation brains for meatray.game.neurobot.

        luajit scripts/evolve.lua [map] [generations] [out]

        map          a .map file (default maps/arena.map)
        generations  how long to train (default 30)
        out          where the best brain lands (default build/brain.txt)

    The task is the honest minimum for "learned to play": spawn at the map's
    spawn point, reach a goal on the far side of the level, seen only through
    the bot's own senses (wall whiskers + goal bearing). Movement goes through
    Rep.applyInput — the same call a human's keyboard feeds — so a brain that
    scores here has learned to drive the actual game, not a simplified copy.

    Fitness is progress: how much closer to the goal the agent ever got, plus
    a bonus for arriving (minus a step penalty so arriving sooner outranks
    arriving eventually). Everything is seeded — population, mutation, the
    whole run — so a training run is reproducible to the byte, and the brain
    it writes is loadable with Neurobot.load or the demo's `neurobot` command.
]]

package.path = package.path .. ';./?.lua;./?/init.lua'

local Map = require('meatray.sim.map')
local Neural = require('meatray.sim.neural')
local Neurobot = require('meatray.game.neurobot')
local Worldgen = require('meatray.sim.worldgen')
local Rep = require('meatray.net.replication')
local Collide = require('meatray.sim.collide')

local mapPath = arg[1] or 'maps/arena.map'
local generations = tonumber(arg[2]) or 30
local outPath = arg[3] or 'build/brain.txt'

local POP = 24
local TICKS = 60 * 12          -- 12 simulated seconds per evaluation
local DT = 1 / 60

---------------------------------------------------------------------------
-- The course
---------------------------------------------------------------------------

local f = io.open(mapPath, 'rb')
if not f then
    io.stderr:write('cannot read ' .. mapPath .. '\n')
    os.exit(1)
end
local mapText = f:read('*a')
f:close()

local map, errs = Map.parse(mapText)
if not map then
    io.stderr:write(mapPath .. ': ' .. tostring(errs and errs[1]) .. '\n')
    os.exit(1)
end
local world, _, spawn = Map.toWorld(map)
spawn = spawn or { x = 2.5, y = 2.5, angle = 0 }

-- The goal: the walkable tile FARTHEST from the spawn by actual walking
-- distance (BFS, doors passable) — the far side of the level as the level
-- defines it, not as the crow flies.
local function farthestTile()
    local sx, sy = math.floor(spawn.x) + 1, math.floor(spawn.y) + 1
    local visited = { [sy * 4096 + sx] = 0 }
    local queue, head = { { sx, sy } }, 1
    local best, bestD = { sx, sy }, 0
    while head <= #queue do
        local cx, cy = queue[head][1], queue[head][2]
        head = head + 1
        local d = visited[cy * 4096 + cx]
        if d > bestD then best, bestD = { cx, cy }, d end
        for _, dir in ipairs{ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
            local nx, ny = cx + dir[1], cy + dir[2]
            local key = ny * 4096 + nx
            if not visited[key]
               and nx >= 1 and ny >= 1 and nx <= world.width and ny <= world.height
               and (world:doorAt(nx, ny) or not world:isSolid(nx, ny)) then
                visited[key] = d + 1
                queue[#queue + 1] = { nx, ny }
            end
        end
    end
    return best[1] - 0.5, best[2] - 0.5, bestD
end

local goalX, goalY, courseLen = farthestTile()
print(('course: %s  spawn %.1f,%.1f -> goal %.1f,%.1f (%d tiles walked)')
    :format(mapPath, spawn.x, spawn.y, goalX, goalY, courseLen))

-- Fitness distance is WALKING distance (BFS from the goal), not euclidean.
-- On any map with interior walls the straight-line distance is deceptive: an
-- agent pressed against the wall nearest the goal scores well and evolution
-- climbs the wrong hill, plateauing forever. The walk field is the honest
-- gradient — every tile closer along an actual route scores better.
local distField = {}
do
    local gx, gy = math.floor(goalX) + 1, math.floor(goalY) + 1
    distField[gy * 4096 + gx] = 0
    local queue, head = { { gx, gy } }, 1
    while head <= #queue do
        local cx, cy = queue[head][1], queue[head][2]
        head = head + 1
        local d = distField[cy * 4096 + cx]
        for _, dir in ipairs{ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
            local nx, ny = cx + dir[1], cy + dir[2]
            local key = ny * 4096 + nx
            if not distField[key]
               and nx >= 1 and ny >= 1 and nx <= world.width and ny <= world.height
               and (world:doorAt(nx, ny) or not world:isSolid(nx, ny)) then
                distField[key] = d + 1
                queue[#queue + 1] = { nx, ny }
            end
        end
    end
end

local function walkDist(x, y)
    local d = distField[(math.floor(y) + 1) * 4096 + (math.floor(x) + 1)]
    if not d then return 4096 end     -- off-field: as bad as it gets
    -- Sub-tile shaping inside the tile, so progress within a tile counts.
    local frac = math.sqrt((goalX - x) ^ 2 + (goalY - y) ^ 2)
    return d + math.min(frac, 1) * 0.5
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

local function evaluate(brain)
    local bot = Neurobot.new{ brain = brain }
    bot:setGoal(goalX, goalY)
    local ent = { x = spawn.x, y = spawn.y, angle = spawn.angle or 0, storey = 1 }
    Collide.ground(ent, world)

    local startD = walkDist(ent.x, ent.y)
    local bestD = startD
    for tick = 1, TICKS do
        local intent = bot:think(ent, world, nil, DT)
        Rep.applyInput(ent, Rep.sanitiseInput(intent.input), DT, world)
        if intent.use and intent.useDoor and world.toggleDoor then
            local d = world:doorAt(intent.useDoor.tx, intent.useDoor.ty, ent.storey)
            if d and not d.open then
                world:toggleDoor(intent.useDoor.tx, intent.useDoor.ty, ent.storey)
            end
        end
        local d = walkDist(ent.x, ent.y)
        if d < bestD then bestD = d end
        if math.sqrt((goalX - ent.x) ^ 2 + (goalY - ent.y) ^ 2) < 0.7 then
            -- Arrived: the bonus shrinks with the ticks it took.
            return (startD - bestD) + 10 + 5 * (1 - tick / TICKS)
        end
    end
    return startD - bestD
end

---------------------------------------------------------------------------
-- The run
---------------------------------------------------------------------------

local rng = Worldgen.rng(1337)
local pool = {}
for i = 1, POP do
    pool[i] = Neural.new{
        layers = { Neurobot.SENSES, 12, Neurobot.INTENTS },
        seed = i * 101,
    }
end

local best, bestScore = nil, -math.huge
for gen = 1, generations do
    local scores = {}
    local genBest, genBestScore = nil, -math.huge
    for i, brain in ipairs(pool) do
        scores[i] = evaluate(brain)
        if scores[i] > genBestScore then genBest, genBestScore = brain, scores[i] end
    end
    if genBestScore > bestScore then best, bestScore = genBest, genBestScore end
    print(('gen %3d  best %.2f  all-time %.2f'):format(gen, genBestScore, bestScore))
    pool = Neural.evolvePool(pool, scores, rng, { elite = 3 })
end

local out = io.open(outPath, 'wb')
if not out then
    io.stderr:write('cannot write ' .. outPath .. '\n')
    os.exit(1)
end
out:write(best:serialize())
out:close()
print(('best brain (fitness %.2f) -> %s'):format(bestScore, outPath))
print('load it in the demo console:  neurobot 1 ' .. outPath)
